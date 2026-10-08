import Foundation
import Darwin
import AgentKanbanCore

public actor ExecutorRegistry: ExecutorService {
    private struct ActiveRun {
        let request: ExecutorRequest
        let sink: AsyncStream<ExecutorEvent>.Continuation
        var connection: JSONRPCConnection?
        var process: PipeProcess?
        var task: Task<Void, Never>?
        var sessionID: String?
        var turnID: String?
        var output = ""
        var terminal = false
        var finishing = false
        var stopRequested = false
        var activeTools: Set<String> = []
        var activeAgents: Set<String> = []
        var seenAgentActivities: Set<String> = []
        var approvals: [String: (id: JSONValue, method: String, options: JSONValue)] = [:]
        var vendorError: String?
        var cursorVersion: String?
        var claudeChildren = ClaudeChildTracker()
        var claudeTools: [String: String] = [:]
        var claudePendingResult: JSONValue?
    }
    private var runs: [String: ActiveRun] = [:]
    private var catalogs: [ExecutorID: [ExecutorModel]] = [:]
    private var installations: [ExecutorID: ExecutorInstallation] = [:]
    private var barriers: [String: CheckedContinuation<Void, Never>] = [:]
    private var finishWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private let executableOverrides: [ExecutorID: String]
    public init(executableOverrides: [ExecutorID: String] = [:]) { self.executableOverrides = executableOverrides }
    private func executable(_ id: ExecutorID) -> String? { executableOverrides[id] ?? ExecutableLocator.find(id) }

    public func probe(_ executor: ExecutorID) async -> ExecutorInstallation {
        guard let executable = executable(executor) else {
            let value = ExecutorInstallation(id: executor, authentication: .notInstalled, detail: "未找到本机执行器。请在执行器官方客户端安装并登录。")
            installations[executor] = value; return value
        }
        var value = ExecutorInstallation(id: executor, executable: executable)
        do {
            let version = try await ExecutorCommand.run(executable: executable, arguments: ["--version"])
            value.version = String(data: version.output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            switch executor {
            case .codex:
                let connection = try await codexConnection(executable: executable, directory: nil, readOnly: false)
                do {
                    let result = try await connection.call("account/read", params: .object(["refreshToken": .bool(false)]))
                    value.authentication = result["account"] == .null ? .unauthenticated : .authenticated
                    value.detail = result["account"] == .null ? "尚未登录；请使用 codex login。" : "Codex 原生账户状态已确认；模型额度与请求能力需在运行时验证。"
                    await connection.close()
                } catch { await connection.close(); throw error }
            case .claude:
                let result = try await ExecutorCommand.run(executable: executable, arguments: ["auth", "status", "--json"])
                let status = try JSONDecoder().decode(JSONValue.self, from: result.output)
                if status["loggedIn"].bool == true {
                    value.authentication = .authenticated
                    value.detail = "Claude Code 已登录，可使用本机账户。"
                } else if status["authMethod"].string == "api_key" {
                    value.authentication = .configured; value.detail = "CLI 报告已配置凭证，尚未验证模型访问。"
                } else {
                    value.authentication = result.status == 0 ? .unauthenticated : .unknown
                    value.detail = "请在 Claude Code CLI 中检查登录；此检测不调用模型。"
                }
            case .cursor:
                guard value.version?.contains("2026.") == true else { throw ExecutorError.unsupported("无法确认 Cursor CLI 身份；未使用同名 agent") }
                let result = try await ExecutorCommand.run(executable: executable, arguments: ["status", "--format", "json"])
                let status = try JSONDecoder().decode(JSONValue.self, from: result.output)
                let authenticated = status["authenticated"].bool ?? status["isAuthenticated"].bool ?? status["loggedIn"].bool
                value.authentication = authenticated == true ? .authenticated : (authenticated == false ? .unauthenticated : .unknown)
                value.detail = value.authentication == .authenticated ? "Cursor CLI 原生认证已确认；ACP 与模型能力在请求前协商。" : "Cursor 返回的认证状态未明确；请在 Cursor CLI 检查登录。"
            }
        } catch {
            value.authentication = .failed; value.detail = "检测失败：\(error.localizedDescription)"
        }
        value.checkedAt = .now; installations[executor] = value; return value
    }

    public func models(_ executor: ExecutorID) async throws -> [ExecutorModel] {
        guard let executable = executable(executor) else { throw ExecutorError.unavailable("执行器未安装") }
        switch executor {
        case .codex:
            let connection = try await codexConnection(executable: executable, directory: nil, readOnly: false)
            do {
                var models: [ExecutorModel] = [], cursor: JSONValue = .null
                repeat {
                    let result = try await connection.call("model/list", params: .object(["limit": .number(100), "includeHidden": .bool(false), "cursor": cursor]))
                    models.append(contentsOf: Self.parseCodexModels(result["data"]))
                    cursor = result["nextCursor"]
                } while cursor.string != nil
                await connection.close(); catalogs[executor] = models; return models
            } catch { await connection.close(); throw error }
        case .cursor:
            let result = try await ExecutorCommand.run(executable: executable, arguments: ["models"])
            guard result.status == 0, let text = String(data: result.output, encoding: .utf8) else { throw ExecutorError.unavailable("Cursor 模型目录查询失败") }
            let models = Self.parseCursorModels(text)
            guard !models.isEmpty else { throw ExecutorError.protocolError("Cursor 模型目录格式未识别；不把研究快照视为当前账户目录") }
            catalogs[executor] = models; return models
        case .claude:
            // CLI currently has no account-specific non-inference model/list command.
            return ExecutorCatalog.fallback(.claude)
        }
    }

    public func start(_ request: ExecutorRequest) async throws -> ExecutorRun {
        try ExecutionPolicy.validate(request)
        let input = try ExecutionPolicy.prepareAttachmentInput(request)
        guard runs[request.runID] == nil else { throw ExecutorError.invalidRequest("Run ID 已使用；不自动重放请求") }
        guard !runs.values.contains(where: { !$0.terminal && $0.request.conversationID == request.conversationID }) else { throw ExecutorError.invalidRequest("会话已有运行或待恢复运行") }
        guard let executable = executable(request.selection.executor) else { throw ExecutorError.unavailable("执行器未安装") }
        if let model = request.selection.modelID, let catalog = catalogs[request.selection.executor] {
            guard let entry = catalog.first(where: { $0.id == model }) else { throw ExecutorError.invalidRequest("模型不在最新目录中；请重新选择") }
            if let effort = request.selection.effort, !entry.efforts.contains(effort) { throw ExecutorError.invalidRequest("当前模型不支持所选推理强度") }
        }
        let pair = AsyncStream<ExecutorEvent>.makeStream()
        runs[request.runID] = ActiveRun(request: request, sink: pair.continuation)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.execute(request, executable: executable, input: input)
        }
        runs[request.runID]?.task = task
        return ExecutorRun(id: request.runID, events: pair.stream)
    }

    public func respond(runID: String, approvalID: String, decision: ApprovalDecision) async throws {
        guard let run = runs[runID], !run.terminal, let approval = run.approvals[approvalID] else { throw ExecutorError.invalidRequest("审批已失效或不属于当前运行") }
        guard !run.request.readOnly || decision == .deny else { throw ExecutorError.unsupported("讨论/验收阶段不能批准越过只读边界") }
        if run.request.selection.executor == .claude {
            guard let process = run.process else { throw ExecutorError.unavailable("Claude CLI 已断开") }
            let response: JSONValue = decision == .approve ? .object(["behavior": .string("allow"), "updatedInput": approval.options]) : .object(["behavior": .string("deny"), "message": .string("用户拒绝此操作"), "interrupt": .bool(false)])
            try process.send(Self.claudeControlResponse(requestID: approvalID, response: response))
            runs[runID]?.approvals.removeValue(forKey: approvalID)
            run.sink.yield(.approvalResolved(id: approvalID, approved: decision == .approve)); return
        }
        guard let connection = run.connection else { throw ExecutorError.unavailable("执行器协议已断开") }
        let result: JSONValue
        switch run.request.selection.executor {
        case .codex:
            if approval.method == "item/permissions/requestApproval" {
                // Arbitrary additional filesystem/network grants are not represented by the three-row UI.
                guard decision == .deny else { throw ExecutorError.unsupported("此审批包含额外权限范围，当前客户端仅可拒绝") }
                result = .object(["permissions": .object([:]), "scope": .string("turn")])
            } else { result = .object(["decision": .string(decision == .approve ? "accept" : "decline")]) }
        case .cursor:
            let kind = decision == .approve ? "allow_once" : "reject_once"
            guard let option = approval.options.array.first(where: { $0["kind"].string == kind })?["optionId"].string else { throw ExecutorError.unsupported("执行器未提供此次审批的选项") }
            result = .object(["outcome": .object(["outcome": .string("selected"), "optionId": .string(option)])])
        case .claude: throw ExecutorError.unsupported("Claude 审批不使用 JSON-RPC")
        }
        try await connection.respond(id: approval.id, result: result)
        runs[runID]?.approvals.removeValue(forKey: approvalID)
        run.sink.yield(.approvalResolved(id: approvalID, approved: decision == .approve))
    }

    public func cancel(runID: String) async -> CancellationResult {
        guard let run = runs[runID] else { return .unknown("此运行不属于当前执行器进程管理实例，可能来自应用重启；必须核实旧进程及子进程，不能直接释放目录锁。") }
        if run.terminal { return .alreadyFinished }
        runs[runID]?.stopRequested = true
        if run.turnID == nil && (run.request.selection.executor == .codex || run.sessionID == nil) {
            guard let process = run.process else { return .unknown("执行器尚在创建进程；取消标志已记录，启动后会在发送模型请求前停止。") }
            await finishVerified(runID, event: .cancelled)
            return runs[runID]?.terminal == true && process.groupIsEmpty ? .confirmed : .unknown("启动期间的执行器进程组未确认停止")
        }
        do {
            switch run.request.selection.executor {
            case .codex:
                guard let connection = run.connection, let thread = run.sessionID, let turn = run.turnID else { return .unknown("运行正在启动；尚无可核实的 Turn ID。请等待或核实进程。") }
                _ = try await connection.call("turn/interrupt", params: .object(["threadId": .string(thread), "turnId": .string(turn)]), timeout: .seconds(10))
            case .cursor:
                guard let connection = run.connection, let session = run.sessionID else { return .unknown("Cursor 会话仍在启动") }
                try await connection.notify("session/cancel", params: .object(["sessionId": .string(session)]))
            case .claude:
                guard let process = run.process else { return .unknown("Claude 执行器进程身份尚未建立") }
                await finishVerified(runID, event: .cancelled)
                return runs[runID]?.terminal == true && process.groupIsEmpty ? .confirmed : .unknown("Claude 工具进程组仍未确认清空")
            }
            for _ in 0..<100 {
                if runs[runID]?.terminal == true { return .confirmed }
                try await Task.sleep(for: .milliseconds(100))
            }
            // Protocol acknowledgements can be lost. A verified, owned process group is a final stop barrier.
            await finishVerified(runID, event: .cancelled)
            return runs[runID]?.terminal == true ? .confirmed : .unknown("主运行及工具进程组未确认清空；目录锁继续保留。")
        } catch {
            await finishVerified(runID, event: .cancelled)
            return runs[runID]?.terminal == true ? .confirmed : .unknown("取消未确认：\(error.localizedDescription)")
        }
    }

    public func processIdentity(runID: String) -> ManagedProcessIdentity? {
        guard let process = runs[runID]?.process else { return nil }
        return ManagedProcessIdentity(processID: process.processID, processGroupID: process.processID, startedAt: process.startedAt)
    }
    /// Read-only recovery audit. A stale/missing PID without the stored birth time never clears a lease.
    public func verifyRecovery(_ record: RunRecord) async -> CancellationResult {
        if let run = runs[record.id] { return run.terminal ? .confirmed : .unknown("当前运行仍由执行器管理；请先停止运行") }
        guard let pid = record.processID, pid > 1, let birth = record.processStartedAt else { return .unknown("缺少可核实的执行器进程身份；请人工检查运行与工具，不会自动清除目录锁。") }
        if let actual = ManagedProcessIdentity.readStartTime(pid: pid) {
            guard abs(actual.timeIntervalSince(birth)) < 0.000001 else { return .unknown("PID 已被其他进程复用；不能据此终止或接管") }
            return .unknown("原执行器仍存在，请先终止原运行及其工具")
        }
        guard kill(-pid, 0) == -1 && errno == ESRCH else { return .unknown("执行器父进程已退出，但其管理进程组仍存在或无法检查") }
        return .confirmed
    }
    public func stopRecovered(_ record: RunRecord) async -> CancellationResult {
        if runs[record.id] != nil { return await cancel(runID: record.id) }
        guard let pid = record.processID, pid > 1, let birth = record.processStartedAt else { return .unknown("缺少原执行器 PID 与实际启动时间，未发送终止信号") }
        guard let actual = ManagedProcessIdentity.readStartTime(pid: pid) else { return await verifyRecovery(record) }
        guard abs(actual.timeIntervalSince(birth)) < 0.000001, getpgid(pid) == pid else { return .unknown("原执行器身份或独立进程组不匹配，未发送终止信号") }
        // Only the verified old managed group is signalled; unrelated PID reuse is never targeted.
        kill(-pid, SIGTERM)
        for attempt in 0..<50 {
            if kill(-pid, 0) == -1 && errno == ESRCH { return .confirmed }
            if let current = ManagedProcessIdentity.readStartTime(pid: pid), abs(current.timeIntervalSince(birth)) >= 0.000001 { return .unknown("停止期间进程身份变化，停止进一步发送信号") }
            if attempt == 20 { kill(-pid, SIGKILL) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return .unknown("已停止原执行器，但管理进程组尚未确认清空，继续保留目录锁")
    }

    private func execute(_ request: ExecutorRequest, executable: String, input: PreparedAttachmentInput) async {
        do {
            switch request.selection.executor {
            case .codex: try await executeCodex(request, executable: executable, input: input)
            case .cursor: try await executeCursor(request, executable: executable, input: input)
            case .claude: try await executeClaude(request, executable: executable, input: input)
            }
        } catch {
            guard runs[request.runID]?.terminal != true, runs[request.runID]?.finishing != true else { return }
            // Once a process/session has started, an exception cannot establish a safe stop.
            if runs[request.runID]?.sessionID != nil || runs[request.runID]?.process != nil {
                emit(request.runID, .recoveryRequired(error.localizedDescription)); finishStream(request.runID)
            } else {
                emit(request.runID, .failed(error.localizedDescription)); terminal(request.runID)
            }
        }
    }
    private func codexConnection(executable: String, directory: String?, readOnly: Bool, runID: String? = nil) async throws -> JSONRPCConnection {
        // Readonly descendants inherit the same OS boundary. Writable turns cannot delegate.
        let launch = try ExecutionPolicy.launch(executable: executable, arguments: [readOnly ? "--enable" : "--disable", "multi_agent", "--disable", "multi_agent_v2", "app-server", "--stdio"], readOnly: readOnly, projectPath: directory ?? "/nonexistent")
        let connection = try JSONRPCConnection(executable: launch.executable, arguments: launch.arguments, directory: directory)
        if let runID {
            runs[runID]?.connection = connection; runs[runID]?.process = connection.transport
            let identity = ManagedProcessIdentity(processID: connection.transport.processID, processGroupID: connection.transport.processID, startedAt: connection.transport.startedAt)
            try await recordIdentity(runID, identity)
        }
        await connection.begin()
        do {
            _ = try await connection.call("initialize", params: .object(["clientInfo": .object(["name": .string("agent-kanban"), "title": .string("Agent Kanban"), "version": .string("0.1.0")]), "capabilities": .object(["experimentalApi": .bool(true), "explicitGatewayOauth": .bool(true)])]))
            try await connection.notify("initialized")
            return connection
        } catch { await connection.close(); throw error }
    }
    private func executeCodex(_ request: ExecutorRequest, executable: String, input: PreparedAttachmentInput) async throws {
        let connection = try await codexConnection(executable: executable, directory: request.projectPath, readOnly: request.readOnly, runID: request.runID)
        guard runs[request.runID]?.terminal != true else { await connection.close(); return }
        runs[request.runID]?.connection = connection
        runs[request.runID]?.process = connection.transport
        let notifications = connection.notifications
        let listener = Task { [weak self] in
            for await packet in notifications { await self?.codexNotification(request.runID, packet: packet) }
            await self?.connectionLost(request.runID)
        }
        var params = ExecutionPolicy.codexThread(request)
        var nativeConfig = JSONValue.null
        if request.selection.modelID == nil || request.selection.effort == nil || request.selection.permission == nil {
            nativeConfig = try await connection.call("config/read", params: .object(["includeLayers": .bool(false)]))["config"]
            if request.selection.modelID == nil, let model = nativeConfig["model"].string { params["model"] = .string(model) }
            if request.selection.permission == nil && !request.readOnly {
                if let sandbox = nativeConfig["sandbox_mode"].string { params["sandbox"] = .string(sandbox) }
                if nativeConfig["approval_policy"] != .null { params["approvalPolicy"] = nativeConfig["approval_policy"] }
                if let reviewer = nativeConfig["approvals_reviewer"].string { params["approvalsReviewer"] = .string(reviewer) }
            }
        }
        let method: String
        if let session = request.sessionID { method = "thread/resume"; params["threadId"] = .string(session) }
        else { method = "thread/start" }
        let result = try await connection.call(method, params: .object(params))
        guard let session = result["thread"]["id"].string else { listener.cancel(); throw ExecutorError.protocolError("Codex 缺少 Thread ID") }
        if request.readOnly, result["sandbox"]["type"].string != "dangerFullAccess" { throw ExecutorError.unsupported("Codex 未确认宿主隔离接入模式，未发送模型请求") }
        runs[request.runID]?.sessionID = session
        emit(request.runID, .started(sessionID: session, processID: connection.transport.processID, modelID: result["model"].string, effectivePolicy: request.readOnly ? "宿主 Seatbelt 只读 · externalSandbox · 原生网络连接 · never" : result["sandbox"]["type"].string))
        if runs[request.runID]?.stopRequested == true { await finishVerified(request.runID, event: .cancelled); listener.cancel(); return }
        var turnParams = ExecutionPolicy.codexTurn(request, threadID: session)
        turnParams["input"] = .array(input.codexContent)
        if request.selection.modelID == nil, let model = params["model"] { turnParams["model"] = model }
        if request.selection.effort == nil, let effort = nativeConfig["model_reasoning_effort"].string { turnParams["effort"] = .string(effort) }
        if request.selection.permission == nil && !request.readOnly {
            if let approval = params["approvalPolicy"] { turnParams["approvalPolicy"] = approval }
            if let reviewer = params["approvalsReviewer"] { turnParams["approvalsReviewer"] = reviewer }
            // thread/start or resume reports the native effective sandbox; carry it rather than inheriting an earlier turn override.
            if result["sandbox"] != .null { turnParams["sandboxPolicy"] = result["sandbox"] }
        }
        let turn = try await connection.call("turn/start", params: .object(turnParams))
        runs[request.runID]?.turnID = turn["turn"]["id"].string
        // Notifications may arrive before the turn/start response; the reducer also records turn IDs.
    }
    private func codexNotification(_ runID: String, packet: JSONValue) async {
        guard let run = runs[runID], !run.terminal, let method = packet["method"].string else { return }
        let params = packet["params"]
        if let owner = params["threadId"].string, let session = run.sessionID, owner != session { return }
        if let turn = params["turnId"].string { runs[runID]?.turnID = turn }
        if packet["id"] != .null {
            if ["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval"].contains(method) {
                let id = packet["id"].idString ?? UUID().uuidString
                if run.request.readOnly {
                    let response: JSONValue = method == "item/permissions/requestApproval" ? .object(["permissions": .object([:])]) : .object(["decision": .string("decline")])
                    try? await run.connection?.respond(id: packet["id"], result: response)
                    emit(runID, .approvalResolved(id: id, approved: false))
                } else {
                    runs[runID]?.approvals[id] = (packet["id"], method, .null)
                    emit(runID, .approval(ExecutorApproval(id: id, title: method.contains("fileChange") ? "请求修改文件" : "请求执行批准", detail: params["command"].string ?? params["reason"].string ?? "执行器请求额外操作权限", allowsApproval: method != "item/permissions/requestApproval")))
                }
            } else { try? await run.connection?.reject(id: packet["id"], message: "Client capability unavailable") }
            return
        }
        switch method {
        case "item/agentMessage/delta":
            let delta = params["delta"].string ?? ""; runs[runID]?.output += delta; emit(runID, .textDelta(delta))
        case "item/reasoning/textDelta", "item/reasoning/summaryTextDelta": emit(runID, .thinkingDelta(params["delta"].string ?? ""))
        case "turn/started": runs[runID]?.turnID = params["turn"]["id"].string
        case "item/started", "item/completed":
            let item = params["item"], id = item["id"].string ?? "unknown", kind = item["type"].string ?? "tool"
            if ["commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "collabAgentToolCall"].contains(kind) {
                if method == "item/started" { runs[runID]?.activeTools.insert(id) } else { runs[runID]?.activeTools.remove(id) }
                emit(runID, .tool(id: id, name: kind, status: method == "item/started" ? "running" : item["status"].string ?? "completed", detail: item["command"].string ?? ""))
            }
            if kind == "collabAgentToolCall", let states = item["agentsStates"].object {
                for (agentID, state) in states {
                    let status = state["status"].string ?? "unknown"
                    if ["completed", "errored", "interrupted", "shutdown", "notFound"].contains(status) { runs[runID]?.activeAgents.remove(agentID) } else { runs[runID]?.activeAgents.insert(agentID) }
                    emit(runID, .agent(id: agentID, status: status, summary: state["message"].string ?? ""))
                }
            }
            // Current app-server also emits lifecycle-only subAgentActivity items. A wait call
            // can have empty agentsStates; do not lose the independently owned child identity.
            if kind == "subAgentActivity", let agentID = item["agentThreadId"].string, runs[runID]?.seenAgentActivities.contains(id) == false {
                runs[runID]?.seenAgentActivities.insert(id)
                let status = item["kind"].string ?? "unknown"
                if ["completed", "interrupted"].contains(status) { runs[runID]?.activeAgents.remove(agentID) } else { runs[runID]?.activeAgents.insert(agentID) }
                var summary = ""
                if status == "completed", let connection = run.connection {
                    // Read a completed native child only when its recorded parent is this Run's
                    // session. This never resumes a thread or submits another model request.
                    if let child = try? await connection.call("thread/read", params: .object(["threadId": .string(agentID), "includeTurns": .bool(true)]), timeout: .seconds(5))["thread"], child["parentThreadId"].string == run.sessionID {
                        summary = child["turns"].array.last?["items"].array.last(where: { $0["type"].string == "agentMessage" && $0["phase"].string == "final_answer" })?["text"].string ?? ""
                    }
                }
                emit(runID, .agent(id: agentID, status: status, summary: summary))
            }
            if kind == "agentMessage", method == "item/completed", runs[runID]?.output.isEmpty == true, let text = item["text"].string { runs[runID]?.output = text; emit(runID, .textDelta(text)) }
        case "turn/completed":
            let turn = params["turn"], status = turn["status"].string ?? "unknown"
            if !(runs[runID]?.activeTools.isEmpty ?? true) || !(runs[runID]?.activeAgents.isEmpty ?? true) {
                emit(runID, .recoveryRequired("主 Turn 已结束，但已知工具或子 Agent 尚未确认停止")); finishStream(runID); return
            }
            switch status {
            case "completed": await finishVerified(runID, event: .completed(output: runs[runID]?.output ?? ""))
            case "interrupted": await finishVerified(runID, event: .cancelled)
            case "failed": await finishVerified(runID, event: .failed(turn["error"]["message"].string ?? "执行器运行失败"))
            default: emit(runID, .recoveryRequired("未知 Turn 终态：\(status)")); finishStream(runID)
            }
        default: break
        }
    }

    private func executeCursor(_ request: ExecutorRequest, executable: String, input: PreparedAttachmentInput) async throws {
        let versionResult = try await ExecutorCommand.run(executable: executable, arguments: ["--version"])
        runs[request.runID]?.cursorVersion = String(data: versionResult.output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var arguments: [String] = []
        if request.readOnly { arguments += ["--mode", "plan", "--sandbox", "enabled"] }
        else if let permission = request.selection.permission {
            arguments += ["--sandbox", permission == .fullAccess ? "disabled" : "enabled"]
            if permission == .autoReview { arguments.append("--auto-review") }
            if permission == .fullAccess { arguments.append("--force") }
        }
        var requestedModel = request.selection.modelID
        if let effort = request.selection.effort {
            guard let model = catalogs[.cursor]?.first(where: { $0.id == requestedModel }), let variant = model.effortVariants[effort] else {
                throw ExecutorError.unsupported("Cursor 推理强度需要先刷新当前账户目录，使用真实模型变体 ID")
            }
            requestedModel = variant
        }
        if let model = requestedModel { arguments += ["--model", model] }
        arguments.append("acp")
        let launch = try ExecutionPolicy.launch(executable: executable, arguments: arguments, readOnly: request.readOnly, projectPath: request.projectPath)
        let connection = try JSONRPCConnection(executable: launch.executable, arguments: launch.arguments, directory: request.projectPath)
        await connection.begin(); runs[request.runID]?.connection = connection
        runs[request.runID]?.process = connection.transport
        try await recordIdentity(request.runID, ManagedProcessIdentity(processID: connection.transport.processID, processGroupID: connection.transport.processID, startedAt: connection.transport.startedAt))
        let notifications = connection.notifications
        Task { [weak self] in
            for await packet in notifications { await self?.cursorNotification(request.runID, packet: packet) }
            await self?.connectionLost(request.runID)
        }
        let initialization = try await connection.call("initialize", params: .object([
            "protocolVersion": .number(1), "clientInfo": .object(["name": .string("agent-kanban"), "version": .string("0.1.0")]),
            "clientCapabilities": .object(["fs": .object(["readTextFile": .bool(true), "writeTextFile": .bool(false)]), "terminal": .bool(false)])
        ]))
        let promptContent: [JSONValue]
        do { promptContent = try input.cursorContent(initialization: initialization) }
        catch {
            // No user prompt has been submitted. Stop our owned process rather than leaving a phantom active Run.
            await finishVerified(request.runID, event: .failed(error.localizedDescription)); return
        }
        var params: [String: JSONValue] = ["cwd": .string(request.projectPath), "mcpServers": .array([])]
        let method: String
        if let session = request.sessionID { method = "session/load"; params["sessionId"] = .string(session) }
        else { method = "session/new" }
        let result = try await connection.call(method, params: .object(params))
        guard let session = result["sessionId"].string ?? request.sessionID else { throw ExecutorError.protocolError("Cursor 缺少 Session ID") }
        let effective = result["models"]["currentModelId"].string
        if let requestedModel, let effective, !Self.cursorSelectionMatches(requested: requestedModel, effective: effective) {
            // Do not call session/set_model: this CLI version persists it into global preferences.
            throw ExecutorError.unsupported("Cursor 未确认所选模型快照，未发送提示；请在原生 CLI 核实会话模型。")
        }
        runs[request.runID]?.sessionID = session
        emit(request.runID, .started(sessionID: session, processID: connection.transport.processID, modelID: effective, effectivePolicy: request.readOnly ? "plan · sandbox enabled · Seatbelt" : request.selection.permission?.title))
        if runs[request.runID]?.stopRequested == true { await finishVerified(request.runID, event: .cancelled); return }
        let prompt = try await connection.call("session/prompt", params: .object(["sessionId": .string(session), "prompt": .array(promptContent)]), timeout: .seconds(86_400))
        await drainCursorNotifications(connection)
        guard runs[request.runID]?.terminal != true else { return }
        if let error = runs[request.runID]?.vendorError { await finishVerified(request.runID, event: .failed(error)); return }
        guard runs[request.runID]?.activeTools.isEmpty == true else {
            emit(request.runID, .recoveryRequired("Cursor Prompt 已结束，但工具仍未确认停止")); finishStream(request.runID); return
        }
        if prompt["stopReason"].string == "cancelled" { await finishVerified(request.runID, event: .cancelled) }
        else if ["end_turn", "max_tokens", "max_turn_requests"].contains(prompt["stopReason"].string ?? "") {
            await finishVerified(request.runID, event: .completed(output: runs[request.runID]?.output ?? ""))
        } else { emit(request.runID, .recoveryRequired("Cursor 返回未知终态")); finishStream(request.runID) }
    }

    private func cursorNotification(_ runID: String, packet: JSONValue) async {
        if let token = packet["_clientBarrier"].string { barriers.removeValue(forKey: token)?.resume(); return }
        guard let run = runs[runID], !run.terminal, let method = packet["method"].string else { return }
        let params = packet["params"]
        if let owner = params["sessionId"].string, let session = run.sessionID, owner != session { return }
        if packet["id"] != .null {
            guard let connection = run.connection else { return }
            if method == "session/request_permission" {
                let id = packet["id"].idString ?? UUID().uuidString
                if run.request.readOnly {
                    if let reject = params["options"].array.first(where: { $0["kind"].string == "reject_once" })?["optionId"].string {
                        try? await connection.respond(id: packet["id"], result: .object(["outcome": .object(["outcome": .string("selected"), "optionId": .string(reject)])]))
                    } else { try? await connection.respond(id: packet["id"], result: .object(["outcome": .object(["outcome": .string("cancelled")])])) }
                    emit(runID, .approvalResolved(id: id, approved: false))
                } else {
                    runs[runID]?.approvals[id] = (packet["id"], method, params["options"])
                    emit(runID, .approval(ExecutorApproval(id: id, title: params["toolCall"]["title"].string ?? "Cursor 请求批准", detail: params["toolCall"]["kind"].string ?? "工具操作")))
                }
            } else if method == "fs/read_text_file" {
                do {
                    guard let path = params["path"].string else { throw ExecutorError.invalidRequest("缺少文件路径") }
                    let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
                    let root = URL(fileURLWithPath: run.request.projectPath).resolvingSymlinksInPath().standardizedFileURL.path
                    let explicitAttachment = run.request.attachments.contains { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().standardizedFileURL == url }
                    guard explicitAttachment || (url.path.hasPrefix(root + "/") && !url.lastPathComponent.hasPrefix(".env") && !url.path.contains("/.git/")) else { throw ExecutorError.unsupported("文件不在当前项目或所提供附件的可读范围") }
                    let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                    guard size <= 2 * 1_024 * 1_024 else { throw ExecutorError.unsupported("文件超过读取大小上限") }
                    let text = try String(contentsOf: url, encoding: .utf8)
                    try await connection.respond(id: packet["id"], result: .object(["content": .string(text)]))
                } catch { try? await connection.reject(id: packet["id"], message: "File read denied") }
            } else {
                // No host write/terminal capability was advertised. Never execute unknown callbacks.
                try? await connection.reject(id: packet["id"], message: "Client capability unavailable")
            }
            return
        }
        guard method == "session/update" else { return }
        let update = params["update"]
        switch update["sessionUpdate"].string {
        case "agent_message_chunk":
            if let text = update["content"]["text"].string {
                // This vendor version catches structured backend action errors and sends these EXACT
                // constant frames as agent text followed by end_turn (7214.index.js/processPrompt).
                // This is a version-gated wire workaround, not an NLP guess about model prose.
                let vendorActions = ["\n\nPlease sign in to continue", "\n\nUpgrade your plan to continue", "\n\nAdd a payment method to continue", "\n\nCheck your settings to continue"]
                if run.cursorVersion == "2026.09.10-fd3934a", vendorActions.contains(text) {
                    runs[runID]?.vendorError = "Cursor 原生账户/套餐/配置操作阻断（此 CLI 将后端错误映射为文本帧）；请在 Cursor 检查账户。"
                }
                runs[runID]?.output += text; emit(runID, .textDelta(text))
            }
        case "agent_thought_chunk": emit(runID, .thinkingDelta(update["content"]["text"].string ?? ""))
        case "tool_call", "tool_call_update":
            let id = update["toolCallId"].string ?? "unknown", status = update["status"].string ?? "pending"
            if ["completed", "failed"].contains(status) { runs[runID]?.activeTools.remove(id) } else { runs[runID]?.activeTools.insert(id) }
            emit(runID, .tool(id: id, name: update["title"].string ?? update["kind"].string ?? "tool", status: status, detail: ""))
        default: break
        }
    }

    private func executeClaude(_ request: ExecutorRequest, executable: String, input: PreparedAttachmentInput) async throws {
        if request.selection.permission == .autoReview, request.selection.modelID?.contains("haiku") == true { throw ExecutorError.unsupported("Haiku 不支持 Claude auto 权限模式") }
        var arguments = ["--print", "--verbose", "--input-format", "stream-json", "--output-format", "stream-json", "--include-partial-messages", "--forward-subagent-text", "--permission-prompts", "host", "--permission-prompt-tool", "stdio", "--safe-mode", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--prompt-suggestions", "false"]
        if !request.readOnly { arguments += ["--disallowedTools", "Agent,Task"] }
        if let model = request.selection.modelID { arguments += ["--model", model] }
        if let effort = request.selection.effort { arguments += ["--effort", effort] }
        let sandbox: String?
        if request.readOnly {
            arguments += ["--permission-mode", "plan", "--restricted", "--tools", "Read,Glob,Grep,Agent"]
            sandbox = "{\"sandbox\":{\"enabled\":true,\"failIfUnavailable\":true,\"allowUnsandboxedCommands\":false,\"excludedCommands\":[]}}"
        } else if request.selection.permission == .fullAccess {
            arguments.append("--dangerously-skip-permissions")
            sandbox = "{\"sandbox\":{\"enabled\":false}}"
        } else if let permission = request.selection.permission {
            arguments += ["--permission-mode", permission == .autoReview ? "auto" : "manual"]
            sandbox = "{\"sandbox\":{\"enabled\":true,\"failIfUnavailable\":true,\"allowUnsandboxedCommands\":false,\"excludedCommands\":[]}}"
        } else { sandbox = nil }
        if let sandbox { arguments += ["--settings", sandbox] }
        if let session = request.sessionID { arguments += ["--resume", session] }
        else { arguments += ["--session-id", UUID().uuidString] }
        let launch = try ExecutionPolicy.launch(executable: executable, arguments: arguments, readOnly: request.readOnly, projectPath: request.projectPath)
        let process = try PipeProcess(executable: launch.executable, arguments: launch.arguments, directory: request.projectPath)
        runs[request.runID]?.process = process
        try await recordIdentity(request.runID, ManagedProcessIdentity(processID: process.processID, processGroupID: process.processID, startedAt: process.startedAt))
        if runs[request.runID]?.stopRequested == true { await finishVerified(request.runID, event: .cancelled); return }
        // This is the documented control envelope shipped in the installed official SDK 0.3.292.
        // Keep stdin open for approval responses; no user message is sent until initialization succeeds.
        var initialize: [String: JSONValue] = ["subtype": .string("initialize"), "hooks": .object(["PreToolUse": .array([.object(["matcher": .string("Agent|Task"), "hookCallbackIds": .array([.string("kanban-agent-policy")])])])]), "sdkMcpServers": .array([]), "systemPrompt": .array([])]
        if request.readOnly {
            // safe-mode deliberately ignores --agents from the CLI. SDK-owned
            // agents survive it and are confirmed before any user prompt is sent.
            initialize["agents"] = .object(["readonly_analyst": .object([
                "description": .string("Readonly code analysis and independent review"),
                "prompt": .string("Read and analyze this project using Read, Glob and Grep only. Return findings and evidence to the parent. Do not delegate, write files or launch commands."),
                "tools": .array([.string("Read"), .string("Glob"), .string("Grep")])
            ])])
        }
        try process.send(.object(["type": .string("control_request"), "request_id": .string("kanban-init"), "request": .object(initialize)]))
        var initialized = false
        for try await packet in process.messages {
            guard runs[request.runID]?.terminal != true else { break }
            if packet["type"].string == "control_response", packet["response"]["request_id"].string == "kanban-init" {
                guard packet["response"]["subtype"].string == "success" else { throw ExecutorError.protocolError("Claude 控制协议初始化失败；未发送模型请求") }
                if request.readOnly, packet["response"]["response"]["hooks_applied"].bool != true || !packet["response"]["response"]["agents"].array.contains(where: { $0["name"].string == "readonly_analyst" }) {
                    await finishVerified(request.runID, event: .failed("Claude 未确认只读子角色或宿主工具策略；未发送模型请求")); return
                }
                guard !initialized else { continue }; initialized = true
                if runs[request.runID]?.stopRequested == true { await finishVerified(request.runID, event: .cancelled); return }
                try process.send(input.claudeMessage)
                continue
            }
            await claudePacket(request.runID, packet: packet, processID: process.processID)
        }
        if runs[request.runID]?.terminal != true, runs[request.runID]?.finishing != true { emit(request.runID, .recoveryRequired("Claude CLI 退出但未提供可核实的最终结果；工具子进程状态未知")); finishStream(request.runID) }
    }
    private func claudePacket(_ runID: String, packet: JSONValue, processID: Int32) async {
        guard runs[runID]?.terminal == false, runs[runID]?.finishing == false, runs[runID]?.stopRequested == false else { return }
        // Forwarded subagent frames carry their parent's tool ID. They must never
        // overwrite the main session, append to its reply, or finish its Run.
        if packet["parent_tool_use_id"].string != nil, ["assistant", "user", "stream_event", "result"].contains(packet["type"].string ?? "") {
            let events = runs[runID]?.claudeChildren.forwarded(packet) ?? []
            for event in events { emit(runID, event) }
            await finalizeClaudeIfReady(runID)
            return
        }
        switch packet["type"].string {
        case "system":
            if packet["subtype"].string == "init", let session = packet["session_id"].string {
                runs[runID]?.sessionID = session
                let request = runs[runID]?.request
                let policy: String
                if request?.readOnly == true { policy = "Read/Glob/Grep/readonly Agent · Seatbelt" }
                else if request?.selection.permission == .fullAccess { policy = "bypassPermissions · sandbox disabled（按执行器与组织策略生效）" }
                else if request?.selection.permission != nil { policy = "CLI \(request?.selection.permission == .autoReview ? "auto" : "manual") · stdio 宿主审批 · 严格沙箱" }
                else { policy = "CLI 原生默认 · stdio 宿主审批；未将未知沙箱状态标为启用" }
                emit(runID, .started(sessionID: session, processID: processID, modelID: packet["model"].string, effectivePolicy: policy))
            }
            let events = runs[runID]?.claudeChildren.system(packet) ?? []
            for event in events { emit(runID, event) }
        case "stream_event":
            let event = packet["event"]
            if event["type"].string == "content_block_delta" {
                let delta = event["delta"]
                if let text = delta["text"].string { runs[runID]?.output += text; emit(runID, .textDelta(text)) }
                if let thought = delta["thinking"].string { emit(runID, .thinkingDelta(thought)) }
            }
            if event["type"].string == "content_block_start", event["content_block"]["type"].string == "tool_use" {
                let block = event["content_block"], id = block["id"].string ?? "unknown", name = block["name"].string ?? "tool"
                runs[runID]?.activeTools.insert(id); runs[runID]?.claudeTools[id] = name
                emit(runID, .tool(id: id, name: name, status: "running", detail: ""))
            }
        case "assistant":
            for block in packet["message"]["content"].array where block["type"].string == "tool_use" {
                if let id = block["id"].string, runs[runID]?.claudeTools[id] == nil {
                    let name = block["name"].string ?? "tool"
                    runs[runID]?.activeTools.insert(id); runs[runID]?.claudeTools[id] = name
                    emit(runID, .tool(id: id, name: name, status: "running", detail: ""))
                }
            }
            for block in packet["message"]["content"].array where block["type"].string == "text" {
                if runs[runID]?.output.isEmpty == true, let text = block["text"].string { runs[runID]?.output += text; emit(runID, .textDelta(text)) }
            }
        case "user":
            let events = runs[runID]?.claudeChildren.toolResult(packet) ?? []
            for event in events { emit(runID, event) }
            for block in packet["message"]["content"].array where block["type"].string == "tool_result" {
                let id = block["tool_use_id"].string ?? "unknown"
                runs[runID]?.activeTools.remove(id); emit(runID, .tool(id: id, name: runs[runID]?.claudeTools[id] ?? "tool", status: block["is_error"].bool == true ? "failed" : "completed", detail: ""))
            }
        case "control_request":
            guard let run = runs[runID], let process = run.process, let id = packet["request_id"].string else { return }
            let request = packet["request"]
            if request["subtype"].string == "hook_callback", request["callback_id"].string == "kanban-agent-policy" {
                let input = request["input"]
                let safeInput = input["hook_event_name"].string == "PreToolUse" && input["tool_name"].string == "Agent" ? Self.claudeReadonlyAgentInput(input["tool_input"], readOnly: run.request.readOnly) : nil
                var output: [String: JSONValue] = ["hookEventName": .string("PreToolUse"), "permissionDecision": .string(safeInput == nil ? "deny" : "allow"), "permissionDecisionReason": .string("仅允许当前项目的固定只读前台子角色；禁止远端、工作树和写入阶段委派")]
                if let safeInput { output["updatedInput"] = safeInput }
                try? process.send(Self.claudeControlResponse(requestID: id, response: .object(["hookSpecificOutput": .object(output)])))
            } else if request["subtype"].string == "can_use_tool" {
                let name = request["tool_name"].string ?? "tool"
                let safeInput = name == "Agent" ? Self.claudeReadonlyAgentInput(request["input"], readOnly: run.request.readOnly) : nil
                let safeReadonlyAgent = safeInput != nil
                if (run.request.readOnly && !safeReadonlyAgent) || (!run.request.readOnly && ["Agent", "Task"].contains(name)) || request["requires_user_interaction"].bool == true {
                    try? process.send(Self.claudeControlResponse(requestID: id, response: .object(["behavior": .string("deny"), "message": .string("当前阶段或客户端能力不允许此操作"), "interrupt": .bool(false)])))
                    emit(runID, .approvalResolved(id: id, approved: false))
                } else if safeReadonlyAgent {
                    try? process.send(Self.claudeControlResponse(requestID: id, response: .object(["behavior": .string("allow"), "updatedInput": safeInput ?? .null])))
                    emit(runID, .approvalResolved(id: id, approved: true))
                } else {
                    runs[runID]?.approvals[id] = (.string(id), "claude/can_use_tool", request["input"])
                    let detail = request["description"].string ?? request["decision_reason"].string ?? "原生执行器请求一次工具使用权限"
                    emit(runID, .approval(ExecutorApproval(id: id, title: request["title"].string ?? "Claude 请求使用 \(name)", detail: detail)))
                }
            } else {
                try? process.send(.object(["type": .string("control_response"), "response": .object(["subtype": .string("error"), "request_id": .string(id), "error": .string("Client capability unavailable")])]))
            }
        case "control_cancel_request":
            if let id = packet["request_id"].string { runs[runID]?.approvals.removeValue(forKey: id); emit(runID, .approvalResolved(id: id, approved: false)) }
        case "result":
            runs[runID]?.claudePendingResult = packet
        default: break
        }
        await finalizeClaudeIfReady(runID)
    }

    private func finalizeClaudeIfReady(_ runID: String) async {
        guard let run = runs[runID], !run.stopRequested, !run.finishing, !run.terminal,
              let result = run.claudePendingResult, run.activeTools.isEmpty, !run.claudeChildren.hasActiveChildren else { return }
        runs[runID]?.claudePendingResult = nil
        if result["is_error"].bool == true { await finishVerified(runID, event: .failed("Claude CLI 运行失败（\(result["subtype"].string ?? "unknown")）")) }
        else {
            let output = result["result"].string ?? run.output
            if run.output.isEmpty { emit(runID, .textDelta(output)) }
            await finishVerified(runID, event: .completed(output: output))
        }
    }

    static func claudeReadonlyAgentInput(_ input: JSONValue, readOnly: Bool) -> JSONValue? {
        guard readOnly, input["subagent_type"].string == "readonly_analyst", input["isolation"] == .null,
              let description = input["description"].string, let prompt = input["prompt"].string else { return nil }
        // Construct the accepted schema, rather than forwarding extra fields that
        // could acquire new execution semantics in a future CLI release.
        var value: [String: JSONValue] = ["description": .string(description), "prompt": .string(prompt), "subagent_type": .string("readonly_analyst"), "run_in_background": .bool(false)]
        if let model = input["model"].string, ["sonnet", "opus", "haiku", "fable"].contains(model) { value["model"] = .string(model) }
        if let effort = input["effort"].string, ["low", "medium", "high", "xhigh", "max"].contains(effort) { value["effort"] = .string(effort) }
        return .object(value)
    }

    static func claudeControlResponse(requestID: String, response: JSONValue) -> JSONValue {
        .object(["type": .string("control_response"), "response": .object(["subtype": .string("success"), "request_id": .string(requestID), "response": response])])
    }

    private func emit(_ id: String, _ event: ExecutorEvent) { runs[id]?.sink.yield(event) }
    private func recordIdentity(_ id: String, _ identity: ManagedProcessIdentity) async throws {
        do {
            try await runs[id]?.request.identityRecorder?(identity)
            emit(id, .processLaunched(identity))
        } catch {
            await finishVerified(id, event: .failed("执行器进程身份无法持久化；未发送模型请求"))
            throw error
        }
    }
    private func drainCursorNotifications(_ connection: JSONRPCConnection) async {
        let token = UUID().uuidString
        await withCheckedContinuation { continuation in
            barriers[token] = continuation
            Task { await connection.insertNotificationBarrier(token) }
            Task { try? await Task.sleep(for: .seconds(5)); self.barriers.removeValue(forKey: token)?.resume() }
        }
    }
    private func finishVerified(_ id: String, event: ExecutorEvent) async {
        guard runs[id]?.terminal == false else { return }
        if runs[id]?.finishing == true {
            await withCheckedContinuation { finishWaiters[id, default: []].append($0) }
            return
        }
        runs[id]?.finishing = true
        defer {
            runs[id]?.finishing = false
            for waiter in finishWaiters.removeValue(forKey: id) ?? [] { waiter.resume() }
        }
        if let connection = runs[id]?.connection { await connection.close() }
        runs[id]?.process?.terminate()
        if let process = runs[id]?.process {
            for attempt in 0..<50 {
                if process.groupIsEmpty { emit(id, runs[id]?.stopRequested == true ? .cancelled : event); terminal(id); return }
                if attempt == 20 { process.forceTerminate() }
                try? await Task.sleep(for: .milliseconds(100))
            }
            emit(id, .recoveryRequired("主运行结束后执行器进程组仍未清空；目录锁继续保留。")); finishStream(id)
        } else { emit(id, runs[id]?.stopRequested == true ? .cancelled : event); terminal(id) }
    }
    private func finishStream(_ id: String) { runs[id]?.sink.finish() }
    private func terminal(_ id: String) {
        runs[id]?.terminal = true; runs[id]?.sink.finish()
        if let connection = runs[id]?.connection { Task { await connection.close() } }
    }
    private func connectionLost(_ id: String) {
        guard runs[id]?.terminal == false, runs[id]?.finishing != true else { return }
        emit(id, .recoveryRequired("执行器连接中断；未自动重放写操作，目录锁继续保留。")); finishStream(id)
    }
    static func parseCodexModels(_ data: JSONValue) -> [ExecutorModel] {
        data.array.compactMap { item in
            guard let id = item["id"].string, item["hidden"].bool != true else { return nil }
            return ExecutorModel(id: id, displayName: item["displayName"].string ?? id, efforts: item["supportedReasoningEfforts"].array.compactMap { $0["reasoningEffort"].string }, defaultEffort: item["defaultReasoningEffort"].string, isDefault: item["isDefault"].bool ?? false, verified: true, evidence: "当前 Codex app-server model/list；不保证额度")
        }
    }
    static func parseCursorModels(_ text: String) -> [ExecutorModel] {
        let clean = text.replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
        let lines = clean.split(separator: "\n").map(String.init)
        var entries: [(String, String)] = []
        for line in lines {
            // Current CLI emits `id - Display name`; surrounding status/help lines are ignored.
            let fields = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " - ")
            guard fields.count >= 2 else { continue }
            let id = fields[0].trimmingCharacters(in: .whitespaces)
            guard id == "auto" || id.hasPrefix("composer-") || id.contains("grok-") else { continue }
            entries.append((id, fields.dropFirst().joined(separator: " - ")))
        }
        var models = entries.filter { $0.0 == "auto" || $0.0.hasPrefix("composer-") }.map { id, name in
            ExecutorModel(id: id, displayName: name.replacingOccurrences(of: " (default)", with: ""), isDefault: name.contains("(default)"), verified: true, evidence: "当前 Cursor CLI models；Auto 是路由模式")
        }
        let preferredGrok = entries.filter { $0.0.hasPrefix("grok-") && !$0.0.contains("fast") }
        let bases = Set(preferredGrok.map { $0.0.replacingOccurrences(of: "-(low|medium|high|xhigh)$", with: "", options: .regularExpression) })
        for base in bases.sorted().reversed() {
            let variants = preferredGrok.filter { $0.0.hasPrefix(base + "-") }
            var map: [String: String] = [:]
            for effort in ["low", "medium", "high", "xhigh"] { if let item = variants.first(where: { $0.0 == base + "-" + effort }) { map[effort] = item.0 } }
            guard let id = map["high"] ?? variants.first?.0 else { continue }
            models.append(ExecutorModel(id: id, displayName: base.replacingOccurrences(of: "grok-", with: "Grok "), efforts: ["low", "medium", "high", "xhigh"].filter { map[$0] != nil }, verified: true, evidence: "当前 Cursor CLI 原生模型变体", effortVariants: map))
        }
        return models
    }
    static func cursorSelectionMatches(requested: String, effective: String) -> Bool {
        if requested == effective { return true }
        guard let bracket = effective.firstIndex(of: "["), effective.hasSuffix("]") else { return false }
        let nativeBase = String(effective[..<bracket])
        let values = effective[effective.index(after: bracket)..<effective.index(before: effective.endIndex)].split(separator: ",")
        let fields = Dictionary(values.compactMap { value -> (String, String)? in
            let pieces = value.split(separator: "=", maxSplits: 1).map(String.init)
            return pieces.count == 2 ? (pieces[0], pieces[1]) : nil
        }, uniquingKeysWith: { _, last in last })
        let fast = requested.hasSuffix("-fast")
        let noFast = fast ? String(requested.dropLast(5)) : requested
        let knownEffort = ["low", "medium", "high", "xhigh"].first { noFast.hasSuffix("-" + $0) }
        let base = knownEffort.map { String(noFast.dropLast($0.count + 1)) } ?? noFast
        guard base == nativeBase, (fields["fast"] == "true") == fast else { return false }
        return knownEffort == nil || fields["effort"] == knownEffort
    }
}
