import Foundation
import Testing
import AgentKanbanCore
@testable import AgentKanbanExecutors

@Suite struct ExecutorTests {
    @Test func fragmentedJSONFramesAndSizeLimit() throws {
        var decoder = JSONLineDecoder(maximumFrameSize: 128)
        #expect(try decoder.append(Data("{\"method\":\"a".utf8)).isEmpty)
        let values = try decoder.append(Data("\"}\n{\"id\":1}\n".utf8))
        #expect(values.count == 2)
        #expect(values[0]["method"].string == "a")
        #expect(throws: (any Error).self) { try decoder.append(Data(repeating: 65, count: 129)) }
    }
    @Test func readOnlyPhaseCannotEscalateFullAccess() {
        let request = ExecutorRequest(runID: "run", conversationID: "chat", projectPath: "/tmp", prompt: "review", selection: .init(permission: .fullAccess), phase: .acceptance)
        let thread = ExecutionPolicy.codexThread(request)
        let turn = ExecutionPolicy.codexTurn(request, threadID: "thread")
        #expect(thread["sandbox"] == .string("danger-full-access")) // No nested Seatbelt; actual OS boundary is tested below.
        #expect(thread["approvalPolicy"] == .string("never"))
        #expect(turn["sandboxPolicy"]?["type"] == .string("externalSandbox"))
        #expect(turn["approvalPolicy"] == .string("never"))
    }
    @Test func permissionMappingDoesNotTreatNeverAsSandboxOff() {
        let request = ExecutorRequest(runID: "run", conversationID: "chat", projectPath: "/tmp", prompt: "work", selection: .init(permission: .autoReview), phase: .development)
        let thread = ExecutionPolicy.codexThread(request)
        #expect(thread["sandbox"] == .string("workspace-write"))
        #expect(thread["approvalsReviewer"] == .string("auto_review"))
        #expect(thread["approvalPolicy"] == .string("on-request"))
    }
    @Test func missingRuntimeHandleNeverConfirmsRecovery() async {
        let registry = ExecutorRegistry()
        let result = await registry.cancel(runID: "a-run-from-before-restart")
        if case .unknown = result {} else { Issue.record("A missing runtime handle cannot prove the old process or tools ended") }
    }
    @Test func cursorDirectoryUsesActualVariants() {
        let text = "auto - Auto (default)\ncomposer-2.5 - Composer 2.5\ngrok-4.7-low - Grok 4.7 Low\ngrok-4.7-high - Grok 4.7 High\ngrok-4.7-xhigh - Grok 4.7 Extra High\nother-model - Other\n"
        let models = ExecutorRegistry.parseCursorModels(text)
        #expect(models.count == 3)
        #expect(models[0].isDefault)
        #expect(models[1].efforts.isEmpty)
        #expect(models[2].efforts == ["low", "high", "xhigh"])
        #expect(models[2].effortVariants["medium"] == nil)
        #expect(models[2].verified)
        #expect(ExecutorRegistry.cursorSelectionMatches(requested: "grok-4.7-high", effective: "grok-4.7[effort=high,fast=false]"))
        #expect(!ExecutorRegistry.cursorSelectionMatches(requested: "grok-4.7-high", effective: "grok-4.7[effort=low,fast=false]"))
    }
    @Test func cachedCatalogIsNotAccountVerificationOrDefault() {
        for executor in ExecutorID.allCases {
            let models = ExecutorCatalog.fallback(executor)
            #expect(!models.isEmpty)
            #expect(models.allSatisfy { !$0.verified && !$0.isDefault })
        }
        #expect(ExecutorCatalog.fallback(.claude).first(where: { $0.id.contains("haiku") })?.efforts.isEmpty == true)
    }
    @Test func readonlySeatbeltDeniesProjectWritesIncludingChildProcesses() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let protected = directory.appendingPathComponent("protected.txt")
        try "original".write(to: protected, atomically: true, encoding: .utf8)
        let command = "/bin/sh -c 'echo modified > \(protected.path)' 2>/dev/null; printf '%s\\n' '{\"finished\":true}'"
        let launch = try ExecutionPolicy.launch(executable: "/bin/sh", arguments: ["-c", command], readOnly: true, projectPath: directory.path)
        let process = try PipeProcess(executable: launch.executable, arguments: launch.arguments, directory: directory.path)
        process.closeInput()
        for try await _ in process.messages {}
        #expect(try String(contentsOf: protected, encoding: .utf8) == "original")
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENT_KANBAN_READ_ONLY_PROBES"] == "1"))
    func optionalInstalledExecutorAuthenticationAndCatalogProbe() async throws {
        let registry = ExecutorRegistry()
        for id in ExecutorID.allCases {
            let installation = await registry.probe(id)
            print("Read-only probe: \(id.rawValue) \(installation.version ?? "missing") \(installation.authentication.rawValue)")
            #expect(installation.authentication != .failed)
        }
        let models = try await registry.models(.codex)
        #expect(!models.isEmpty && models.allSatisfy(\.verified))
        let cursor = try await registry.models(.cursor)
        #expect(cursor.contains { $0.id == "auto" } && cursor.allSatisfy(\.verified))
    }
    @Test func codexProtocolFixtureStreamsCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fixture")
        let script = """
        #!/bin/sh
        while IFS= read -r line; do
          case "$line" in
            *'"method":"initialize"'*) printf '%s\\n' '{"jsonrpc":"2.0","id":"kanban-1","result":{}}' ;;
            *'"method":"thread/start"'*) printf '%s\\n' '{"id":"kanban-2","result":{"thread":{"id":"thread-1"},"model":"fixture-model","sandbox":{"type":"dangerFullAccess"}}}' ;;
            *'"method":"thread/read"'*) printf '%s\\n' '{"id":"kanban-4","result":{"thread":{"id":"child-1","parentThreadId":"thread-1","turns":[{"items":[{"type":"agentMessage","phase":"final_answer","text":"independent child summary"}]}]}}}' ;;
            *'"method":"turn/start"'*)
              printf '%s\\n' '{"id":"kanban-3","result":{"turn":{"id":"turn-1"}}}'
              printf '%s\\n' '{"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","item":{"id":"child-start","type":"subAgentActivity","kind":"started","agentThreadId":"child-1","agentPath":"/root/fixture"}}}'
              printf '%s\\n' '{"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","item":{"id":"child-complete","type":"subAgentActivity","kind":"completed","agentThreadId":"child-1","agentPath":"/root/fixture"}}}'
              printf '%s\\n' '{"method":"item/agentMessage/delta","params":{"threadId":"thread-1","turnId":"turn-1","delta":"hello"}}'
              printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","status":"completed"}}}' ;;
          esac
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let registry = ExecutorRegistry(executableOverrides: [.codex: executable.path])
        let run = try await registry.start(.init(runID: "run-1", conversationID: "chat-1", projectPath: directory.path, prompt: "fixture only", selection: .init(modelID: "fixture-model", effort: "low", permission: .requestApproval), phase: .acceptance))
        var output = "", completed = false, childSummary = ""
        for await event in run.events {
            if case .textDelta(let text) = event { output += text }
            if case .completed(let text) = event { completed = text == "hello" }
            if case .agent("child-1", "completed", let text) = event { childSummary = text }
        }
        #expect(output == "hello")
        #expect(completed)
        #expect(childSummary == "independent child summary")
        #expect(await registry.cancel(runID: "run-1") == .alreadyFinished)
    }

    @Test func identityPersistenceFailureStopsBeforeProtocolOrModelRequests() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fixture"), log = directory.appendingPathComponent("calls")
        let script = "#!/bin/sh\nwhile IFS= read -r line; do printf '%s\\n' \"$line\" >> '\(log.path)'; done\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let registry = ExecutorRegistry(executableOverrides: [.codex: executable.path])
        let run = try await registry.start(.init(runID: "persistence-failure", conversationID: "chat", projectPath: directory.path, prompt: "must not be sent", selection: .init(), identityRecorder: { _ in throw ExecutorError.invalidRequest("fixture database failure") }))
        var failed = false, started = false
        for await event in run.events {
            if case .failed = event { failed = true }
            if case .started = event { started = true }
        }
        #expect(failed && !started)
        #expect((try? String(contentsOf: log, encoding: .utf8))?.isEmpty ?? true)
        if let identity = await registry.processIdentity(runID: run.id) { #expect(ManagedProcessIdentity.readStartTime(pid: identity.processID) == nil) }
    }

    @Test func claudeControlProtocolDenialIsSentToOriginalRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fixture")
        let script = """
        #!/bin/sh
        while IFS= read -r line; do
          case "$line" in
            *'"request_id":"kanban-init"'*) printf '%s\\n' '{"type":"control_response","response":{"subtype":"success","request_id":"kanban-init","response":{}}}' ;;
            *'"type":"user"'*)
              printf '%s\\n' '{"type":"system","subtype":"init","session_id":"session-1","model":"fixture-model"}'
              printf '%s\\n' '{"type":"control_request","request_id":"approval-1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"fixture only"}}}' ;;
            *'"behavior":"deny"'*) printf '%s\\n' '{"type":"result","is_error":false,"result":"denial received"}' ;;
          esac
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let registry = ExecutorRegistry(executableOverrides: [.claude: executable.path])
        let run = try await registry.start(.init(runID: "claude-fixture", conversationID: "chat", projectPath: directory.path, prompt: "fixture", selection: .init(executor: .claude, permission: .requestApproval)))
        var completed = false, approved = true
        for await event in run.events {
            switch event {
            case .approval(let item): try await registry.respond(runID: run.id, approvalID: item.id, decision: .deny)
            case .approvalResolved(_, let value): approved = value
            case .completed(let output): completed = output == "denial received"
            default: break
            }
        }
        #expect(completed)
        #expect(!approved)
        await #expect(throws: (any Error).self) { try await registry.respond(runID: run.id, approvalID: "approval-1", decision: .approve) }
    }

    @Test func executorOwnsAndTerminatesItsToolProcessGroup() async throws {
        let command = "sleep 60 & printf '{\"child\":%s}\\n' \"$!\"; wait"
        let process = try PipeProcess(executable: "/bin/sh", arguments: ["-c", command], directory: nil)
        var child: Int32?
        for try await packet in process.messages {
            child = packet["child"].idString.flatMap(Int32.init)
            break
        }
        #expect(child != nil)
        process.terminate()
        for attempt in 0..<40 {
            if process.groupIsEmpty { break }
            if attempt == 20 { process.forceTerminate() }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(process.groupIsEmpty)
    }
    @Test func recoveryStopRequiresOriginalBirthTimeAndDedicatedGroup() async throws {
        let process = try PipeProcess(executable: "/bin/sh", arguments: ["-c", "sleep 60"], directory: nil)
        let registry = ExecutorRegistry()
        var record = RunRecord(projectID: "project", conversationID: "chat", selection: .init(), cwd: "/tmp", prompt: "fixture", writing: false, status: .recoveryRequired, processID: process.processID, processStartedAt: process.startedAt.addingTimeInterval(-5))
        if case .unknown = await registry.stopRecovered(record) {} else { Issue.record("Wrong birth time must not signal a process") }
        #expect(process.isRunning)
        record.processStartedAt = process.startedAt.addingTimeInterval(0.001)
        if case .unknown = await registry.stopRecovered(record) {} else { Issue.record("A one millisecond birth mismatch must not signal a process") }
        #expect(process.isRunning)
        record.processStartedAt = process.startedAt
        #expect(await registry.stopRecovered(record) == .confirmed)
        #expect(process.groupIsEmpty)
    }
    @Test func cursorKnownVersionBackendActionFrameIsFailureDespiteEndTurn() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fixture")
        let script = #"""
        #!/bin/sh
        if [ "$1" = "--version" ]; then printf '%s\n' '2026.09.10-fd3934a'; exit 0; fi
        while IFS= read -r line; do
          case "$line" in
            *'"method":"initialize"'*) printf '%s\n' '{"id":"kanban-1","result":{"protocolVersion":1}}' ;;
            *'"method":"session/new"'*) printf '%s\n' '{"id":"kanban-2","result":{"sessionId":"session-1","models":{"currentModelId":"auto"}}}' ;;
            *'"method":"session/prompt"'*)
              printf '%s\n' '{"method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\n\nUpgrade your plan to continue"}}}}'
              printf '%s\n' '{"id":"kanban-3","result":{"stopReason":"end_turn"}}' ;;
          esac
        done
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let registry = ExecutorRegistry(executableOverrides: [.cursor: executable.path])
        let run = try await registry.start(.init(runID: "cursor-plan-error", conversationID: "chat", projectPath: directory.path, prompt: "fixture", selection: .init(executor: .cursor, modelID: "auto"), phase: .discussion))
        var failed = false, completed = false
        for await event in run.events {
            if case .failed = event { failed = true }
            if case .completed = event { completed = true }
        }
        #expect(failed && !completed)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENT_KANBAN_REAL_READONLY_RUNS"] == "1"))
    func optionalActualReadonlyExecutorRunsInTemporaryRepository() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-kanban-live-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await ExecutorCommand.run(executable: "/usr/bin/git", arguments: ["init", "-q", directory.path])
        try "# Agent Kanban fixture\nThe verification phrase is ocean-glass-42.\n".write(to: directory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let registry = ExecutorRegistry()
        let selected = ProcessInfo.processInfo.environment["AGENT_KANBAN_PROBE_EXECUTORS"]
        for id in ExecutorID.allCases where selected == nil || selected!.split(separator: ",").contains(Substring(id.rawValue)) {
            let started = Date()
            let run = try await registry.start(.init(runID: UUID().uuidString, conversationID: UUID().uuidString, projectPath: directory.path, prompt: "Read README.md with a readonly tool. Reply only with the verification phrase it contains. Do not change files or run any other command.", selection: .init(executor: id), phase: .discussion))
            let timeout = Task { do { try await Task.sleep(for: .seconds(120)) } catch { return }; let status = await registry.cancel(runID: run.id); print("Live timeout cancellation: \(id.rawValue) \(status)") }
            var output = "", completed = false, model = "unknown", policy = "unknown"
            for await event in run.events {
                switch event {
                case .started(_, _, let value, let security): model = value ?? "native-default"; policy = security ?? "unresolved"
                case .textDelta(let delta): output += delta
                case .approval(let approval): try await registry.respond(runID: run.id, approvalID: approval.id, decision: .deny)
                case .completed: completed = true
                case .tool(_, let name, let status, let detail): print("Live tool: \(id.rawValue) \(name) \(status) \(detail.prefix(180))")
                case .failed(let detail), .recoveryRequired(let detail): print("Live runtime failure: \(id.rawValue) \(detail)")
                default: break
                }
            }
            timeout.cancel()
            print("Live readonly result: \(id.rawValue), completed=\(completed), model=\(model), policy=\(policy), seconds=\(Date().timeIntervalSince(started))")
            print("Live fixture reply: \(id.rawValue) \(output.prefix(350))")
            #expect(completed && output.contains("ocean-glass-42"))
            #expect(try String(contentsOf: directory.appendingPathComponent("README.md"), encoding: .utf8).contains("ocean-glass-42"))
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENT_KANBAN_REAL_READONLY_DELEGATE"] == "1"))
    func optionalActualCodexReadonlyDelegation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-kanban-delegate-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await ExecutorCommand.run(executable: "/usr/bin/git", arguments: ["init", "-q", directory.path])
        let readme = "# Readonly delegation fixture\nThe verification phrase is ocean-glass-42.\n"
        try readme.write(to: directory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let registry = ExecutorRegistry(), started = Date()
        let run = try await registry.start(.init(runID: UUID().uuidString, conversationID: UUID().uuidString, projectPath: directory.path, prompt: "Use spawn_agent exactly once to delegate an independent readonly check: the child reads README.md using a readonly tool and returns only its verification phrase. Do not read the file yourself. Wait for the child, close it, and reply only with that phrase. No file writes or other tasks. Keep the reply under 200 characters.", selection: .init(), phase: .acceptance))
        let timeout = Task { do { try await Task.sleep(for: .seconds(120)) } catch { return }; print("Delegate timeout: \(await registry.cancel(runID: run.id))") }
        var output = "", completed = false, states: [String] = []
        for await event in run.events {
            switch event {
            case .started(_, _, let model, let policy): print("Delegate runtime: \(model ?? "unknown"), \(policy ?? "unknown")")
            case .agent(let id, let status, let summary): states.append(status); print("Delegate child: \(id), \(status), \(summary.prefix(100))")
            case .tool(_, let name, let status, _): print("Delegate tool: \(name), \(status)")
            case .textDelta(let delta): output += delta
            case .completed(let value): completed = true; output = value
            case .approval(let approval): try await registry.respond(runID: run.id, approvalID: approval.id, decision: .deny)
            case .failed(let detail), .recoveryRequired(let detail): print("Delegate failure: \(detail)")
            default: break
            }
        }
        timeout.cancel()
        print("Delegate result: completed=\(completed), statuses=\(states), seconds=\(Date().timeIntervalSince(started)), output=\(output.prefix(200))")
        #expect(completed && output.contains("ocean-glass-42"))
        #expect(states.contains("completed"))
        #expect(try String(contentsOf: directory.appendingPathComponent("README.md"), encoding: .utf8) == readme)
        if let identity = await registry.processIdentity(runID: run.id) { #expect(ManagedProcessIdentity.readStartTime(pid: identity.processID) == nil) }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENT_KANBAN_REAL_CODEX_CANCEL"] == "1"))
    func optionalActualCodexCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-kanban-cancel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await ExecutorCommand.run(executable: "/usr/bin/git", arguments: ["init", "-q", directory.path])
        try "# Readonly cancellation fixture\nUse this file only.\n".write(to: directory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let registry = ExecutorRegistry()
        let run = try await registry.start(.init(runID: UUID().uuidString, conversationID: UUID().uuidString, projectPath: directory.path, prompt: "Read README.md with a readonly command and reply with its heading. Do not modify files.", selection: .init(), phase: .discussion))
        var result: CancellationResult?, identity: ManagedProcessIdentity?, wasCancelled = false
        for await event in run.events {
            switch event {
            case .processLaunched(let value): identity = value
            case .tool(_, _, let status, _) where status == "running" && result == nil:
                result = await registry.cancel(runID: run.id)
                print("Live Codex cancellation after tool started: \(String(describing: result))")
            case .cancelled: wasCancelled = true
            default: break
            }
        }
        #expect(result == .confirmed)
        #expect(wasCancelled)
        if let identity {
            #expect(ManagedProcessIdentity.readStartTime(pid: identity.processID) == nil)
        }
    }
}
