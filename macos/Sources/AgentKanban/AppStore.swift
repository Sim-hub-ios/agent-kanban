import AppKit
import Foundation
import Observation
import AgentKanbanCore
import AgentKanbanExecutors

enum AppRoute: String { case board, chat, task, runs }

@MainActor @Observable final class AppStore {
    var snapshot = WorkspaceSnapshot()
    var selectedProjectID: String?
    var selectedConversationID: String?
    var selectedTaskID: String?
    var route: AppRoute = .board
    var error: String?
    var selectedTaskDiff = ""
    var catalogs: [ExecutorID: [ExecutorModel]] = [:]
    var probes: [ExecutorID: ExecutorInstallation] = [:]
    var refreshingExecutors = false
    var importingConversations: Set<String> = []
    var sendingConversations: Set<String> = []
    var changingTasks: Set<String> = []
    @ObservationIgnored let repository: Repository?
    @ObservationIgnored let engine: TaskEngine?
    @ObservationIgnored let executors: any ExecutorService
    @ObservationIgnored private let reader: any TaskImportReading
    @ObservationIgnored private var consumers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var acceptanceContexts: [String: AcceptanceContext] = [:]
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var booted = false
    @ObservationIgnored private var drainingQueue = false
    @ObservationIgnored private var queueTask: Task<Void, Never>?
    @ObservationIgnored private var queueWakeVersion: UInt = 0
    @ObservationIgnored private var queueSuspensions = 0
    @ObservationIgnored private var terminating = false
    @ObservationIgnored private var preflightingRuns: Set<String> = []
    @ObservationIgnored let dataDirectory: URL

    init(dataDirectory: URL? = nil, executors: any ExecutorService = ExecutorRegistry(), reader: any TaskImportReading = ImportReader()) {
        self.executors = executors
        self.reader = reader
        let override = HangDiagnostics.configurationValue(for: "AGENT_KANBAN_DATA_DIR").map { URL(fileURLWithPath: $0) }
        self.dataDirectory = dataDirectory ?? override ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AgentKanban", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.dataDirectory, withIntermediateDirectories: true)
            let repository = try Repository(databaseURL: self.dataDirectory.appendingPathComponent("workspace.sqlite"))
            self.repository = repository; self.engine = TaskEngine(repository: repository)
        } catch { repository = nil; engine = nil; self.error = "无法打开本地工作空间：\(error.localizedDescription)" }
        selectedProjectID = UserDefaults.standard.string(forKey: "selectedProjectID")
        for executor in ExecutorID.allCases {
            catalogs[executor] = ExecutorCatalog.fallback(executor)
            probes[executor] = ExecutorInstallation(id: executor)
        }
    }

    var activeProject: Project? { snapshot.projects.first { $0.id == selectedProjectID } }
    var selectedProject: Project? { activeProject }
    var selectedTask: TaskItem? { snapshot.tasks.first { $0.id == selectedTaskID } }
    var selectedConversation: Conversation? { snapshot.conversations.first { $0.id == selectedConversationID } }
    var currentSelection: ExecutionSelection { selectedConversation?.selection ?? .init(executor: activeProject?.defaultExecutor ?? .codex) }
    var projectTasks: [TaskItem] { snapshot.tasks.filter { $0.projectID == selectedProjectID } }
    var projectRuns: [RunRecord] { snapshot.runs.filter { $0.projectID == selectedProjectID } }
    var activeProjectRuns: [RunRecord] { projectRuns.filter { !$0.status.isTerminal } }
    var activeRuns: [RunRecord] { snapshot.runs.filter { !$0.status.isTerminal } }
    var activeRunEvents: [RunEvent] {
        let activeIDs = Set(activeRuns.map(\.id))
        return snapshot.events.filter { activeIDs.contains($0.runID) }
    }
    var conversationMessages: [Message] { snapshot.messages.filter { $0.conversationID == selectedConversationID } }
    var activeRun: RunRecord? { snapshot.runs.first { $0.conversationID == selectedConversationID && !$0.status.isTerminal } }

    func boot() async {
        guard !booted, let repository else { return }; booted = true
        do {
            try await repository.markInterruptedRunsForRecovery()
            try await repository.clearInterruptedImportJobs()
            try await repository.reconcileIdleStageBarriers()
            try await reload()
            try await reconcileImportResults()
        } catch { self.error = error.localizedDescription }
        refreshExecutors()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { break }
                await self.checkAcceptanceFreshness()
            }
        }
    }

    func reload(scheduleQueue: Bool = true) async throws {
        guard let repository else { throw KanbanError.database("本地数据库不可用。") }
        let diagnosticStart = HangDiagnostics.shared.isEnabled ? ProcessInfo.processInfo.systemUptime : nil
        snapshot = try await repository.snapshot()
        if !snapshot.projects.contains(where: { $0.id == selectedProjectID }) {
            selectedProjectID = snapshot.projects.first?.id; selectedConversationID = nil; selectedTaskID = nil; route = .board
        }
        UserDefaults.standard.set(selectedProjectID, forKey: "selectedProjectID")
        if scheduleQueue { scheduleQueuedRuns() }
        if let diagnosticStart {
            HangDiagnostics.shared.record(event: "workspace-reload", fields: [
                "route": route.rawValue,
                "project_id": selectedProjectID ?? "",
                "conversation_id": selectedConversationID ?? "",
                "task_id": selectedTaskID ?? "",
                "project_count": String(snapshot.projects.count),
                "task_count": String(snapshot.tasks.count),
                "conversation_count": String(snapshot.conversations.count),
                "message_count": String(snapshot.messages.count),
                "event_count": String(snapshot.events.count),
                "active_run_count": String(snapshot.runs.filter { !$0.status.isTerminal }.count),
                "report_count": String(snapshot.reports.count),
                "reload_ms": String(Int((ProcessInfo.processInfo.systemUptime - diagnosticStart) * 1_000))
            ])
        }
    }
    private func perform(_ body: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await body(); try await reload() }
            catch { self.error = error.localizedDescription; try? await reload() }
        }
    }

    /// The repository claims one immutable request at a time; UI reloads only wake the scheduler.
    private func scheduleQueuedRuns() {
        queueWakeVersion &+= 1
        guard !terminating, queueSuspensions == 0, !drainingQueue,
              snapshot.runs.contains(where: { $0.status == .queued }), let repository else { return }
        drainingQueue = true
        queueTask = Task { [weak self] in
            guard let self else { return }
            defer { self.drainingQueue = false }
            do {
                while !self.terminating && self.queueSuspensions == 0 {
                    let wakeVersion = self.queueWakeVersion
                    guard let run = try await repository.claimNextQueuedRun() else {
                        try await self.reload(scheduleQueue: false)
                        // A completion/reload during the claim must not lose its wake-up.
                        if self.queueWakeVersion != wakeVersion { continue }
                        break
                    }
                    // A stop/phase change may have begun while the database claim was awaiting.
                    if self.terminating || self.queueSuspensions > 0 {
                        try await repository.returnUnstartedRunToQueue(id: run.id)
                        try await self.reload(scheduleQueue: false)
                        break
                    }
                    do { try await self.launchRun(run) }
                    catch {
                        // Automatic dispatch failures belong to this run, rather than a recurring modal.
                        _ = try? await repository.appendMessage(conversationID: run.conversationID, role: .system,
                                                            content: error.localizedDescription, runID: run.id)
                    }
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    func setTaskWorktree(_ id: String, enabled: Bool) {
        guard !changingTasks.contains(id), let task = snapshot.tasks.first(where: { $0.id == id }),
              task.phase != .completed,
              !snapshot.runs.contains(where: { $0.taskID == id && !$0.status.isTerminal }),
              !sendingConversations.contains(task.mainConversationID) else { return }
        changingTasks.insert(id)
        perform { [self] in
            defer { self.changingTasks.remove(id) }
            guard let repository else { throw KanbanError.database("本地数据库不可用。") }
            let current = try await repository.task(id: id)
            let project = try await repository.project(id: current.projectID)
            let path: String?
            if enabled {
                let destination = dataDirectory.appendingPathComponent("Worktrees", isDirectory: true)
                    .appendingPathComponent(project.id, isDirectory: true).appendingPathComponent(id, isDirectory: true).path
                path = try await Task.detached(priority: .userInitiated) {
                    try GitRepository.createWorktree(projectPath: project.path, destination: destination,
                                                     branch: "codex/kanban-\(id.lowercased())")
                }.value
            } else { path = nil }
            try await repository.configureTaskWorktree(taskID: id, path: path)
            try await reload()
            if selectedTaskID == id { loadChanges(taskID: id) }
        }
    }
    func selectProject(_ id: String) {
        guard snapshot.projects.contains(where: { $0.id == id }) else { return }
        selectedProjectID = id; selectedTaskID = nil; selectedConversationID = nil; route = .board
        UserDefaults.standard.set(id, forKey: "selectedProjectID")
    }
    func selectConversation(_ id: String) {
        guard let conversation = snapshot.conversations.first(where: { $0.id == id }) else { return }
        selectedProjectID = conversation.projectID; selectedConversationID = id; selectedTaskID = conversation.taskID
        route = conversation.taskID == nil ? .chat : .task
        if let taskID = conversation.taskID { loadChanges(taskID: taskID) }
    }
    func selectTask(_ id: String) {
        guard let task = snapshot.tasks.first(where: { $0.id == id }) else { return }
        selectedProjectID = task.projectID; selectedTaskID = id; selectedConversationID = task.mainConversationID; route = .task
        loadChanges(taskID: id)
    }
    func importProject(directory: URL, name: String, executor: ExecutorID) {
        perform { [self] in
            guard let repository = self.repository else { return }
            let project = try await repository.importProject(path: directory.path, name: name, defaultExecutor: executor)
            try await self.reload(); self.selectProject(project.id)
        }
    }
    func createTask(title: String, description: String, type: TaskType, priority: TaskPriority, attachments: [URL] = []) {
        guard let projectID = selectedProjectID else { return }
        perform { [self] in
            guard let repository = self.repository else { return }
            let copied = try self.copyAttachments(attachments)
            let task: TaskItem
            do { task = try await repository.createTask(projectID: projectID, title: title, description: description, type: type, priority: priority, attachments: copied) }
            catch { self.discardCopiedAttachments(copied); throw error }
            try await self.reload(); self.selectTask(task.id)
        }
    }
    func updateTask(_ id: String, title: String, description: String, type: TaskType, priority: TaskPriority, attachments: [URL]? = nil) {
        perform { [self] in
            guard let repository else { return }
            let existing = try await repository.task(id: id).attachments ?? []
            let copied = try attachments.map { try self.copyAttachments($0, keeping: existing) }
            do { try await repository.updateTask(id: id, title: title, description: description, type: type, priority: priority, attachments: copied) }
            catch { self.discardCopiedAttachments((copied ?? []).filter { !existing.contains($0) }); throw error }
        }
    }
    func createConversation() {
        guard let projectID = selectedProjectID else { return }
        perform { [self] in
            guard let conversation = try await self.repository?.createConversation(projectID: projectID) else { return }
            try await self.reload(); self.selectConversation(conversation.id)
        }
    }
    func removeProject(_ id: String) {
        perform { try await self.repository?.removeProject(id: id) }
    }
    func deleteConversation(_ id: String) {
        perform { [self] in
            guard let repository else { return }
            guard !sendingConversations.contains(id) else { throw KanbanError.busy("会话正在发送，请等待结束后再删除。") }
            try await repository.deleteConversation(id: id)
            if selectedConversationID == id {
                selectedConversationID = nil; selectedTaskID = nil; route = .board
            }
        }
    }
    func setDefaultExecutor(_ executor: ExecutorID) {
        guard let projectID = selectedProjectID else { return }
        perform { try await self.repository?.setDefaultExecutor(projectID: projectID, executor: executor) }
    }
    func updateSelection(_ selection: ExecutionSelection) {
        guard let conversationID = selectedConversationID else { return }
        perform { [self] in
            guard let repository = self.repository else { return }
            let current = try await repository.conversation(id: conversationID)
            var next = selection
            if current.selection.executor != selection.executor && selection.modelID == nil && selection.effort == nil && selection.permission == nil {
                next = try await repository.selection(conversationID: conversationID, executor: selection.executor)
            }
            if let modelID = next.modelID, let model = self.catalogs[next.executor]?.first(where: { $0.id == modelID }), let effort = next.effort, !model.efforts.contains(effort) {
                throw KanbanError.invalid("所选模型不支持这个推理强度。")
            }
            try await repository.updateSelection(conversationID: conversationID, selection: next)
            if current.selection.executor != next.executor {
                let installation = await self.executors.probe(next.executor)
                self.probes[next.executor] = installation
                if let catalog = try? await self.executors.models(next.executor) { self.catalogs[next.executor] = catalog }
            }
        }
    }

    @discardableResult func sendMessage(_ text: String, attachments: [URL]) -> Bool {
        guard let conversationID = selectedConversationID,
              !sendingConversations.contains(conversationID), !importingConversations.contains(conversationID),
              !snapshot.runs.contains(where: { $0.conversationID == conversationID && !$0.status.isTerminal }),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return false }
        sendingConversations.insert(conversationID)
        perform { [self] in
            defer { self.sendingConversations.remove(conversationID) }
            guard let repository = self.repository else { return }
            let conversation = try await repository.conversation(id: conversationID)
            guard !self.importingConversations.contains(conversationID) else { throw KanbanError.busy("任务清单正在导入，请等待完成。") }
            let copied = try self.copyAttachments(attachments)
            let message: Message
            do { message = try await repository.appendMessage(conversationID: conversationID, role: .user, content: text, attachments: copied) }
            catch { self.discardCopiedAttachments(copied); throw error }
            if conversation.title == "新会话", !text.isEmpty { try await repository.renameConversation(id: conversationID, title: String(text.prefix(24))) }
            try await self.reload()
            if let taskID = conversation.taskID {
                let task = try await repository.task(id: taskID)
                if task.phase == .backlog { return }
                guard task.phase != .completed else { throw KanbanError.invalid("任务已完成；请先选择其他阶段再继续运行。") }
            }
            if conversation.kind == .projectChat, let request = TaskImportRequestResolver.resolve(current: message, history: self.snapshot.messages, batches: self.snapshot.importBatches) {
                try await self.executeTaskImport(request, conversationID: conversationID, responseMessageID: message.id)
                return
            }
            let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "请查看我提供的附件。" : text
            try await self.beginRun(conversationID: conversationID, prompt: prompt)
        }
        return true
    }

    /// Replays a saved human request through the same transaction used by chat. No model or phase changes.
    func resumeTaskImport(requestMessageID: String) async throws {
        try await reload()
        guard let message = snapshot.messages.first(where: { $0.id == requestMessageID && $0.role == .user }),
              let conversation = snapshot.conversations.first(where: { $0.id == message.conversationID && $0.projectID == message.projectID && $0.kind == .projectChat }) else {
            throw KanbanError.invalid("只能继续项目会话中的用户导入请求。")
        }
        if let batch = snapshot.importBatches.first(where: { $0.requestMessageID == requestMessageID && $0.conversationID == conversation.id }) {
            try await appendImportResult(batch)
        } else {
            let latest = snapshot.messages.filter { $0.role == .user && $0.conversationID == conversation.id }.max { $0.createdAt < $1.createdAt } ?? message
            guard let request = TaskImportRequestResolver.resolve(current: latest, history: snapshot.messages, batches: snapshot.importBatches), request.requestMessageID == requestMessageID else { throw KanbanError.invalid("该导入请求已结束、取消或不再是当前会话请求。") }
            try await executeTaskImport(request, conversationID: conversation.id, responseMessageID: message.id)
        }
        try await reload()
    }

    private func executeTaskImport(_ request: ResolvedTaskImportRequest, conversationID: String, responseMessageID: String) async throws {
        guard let repository else { throw KanbanError.database("本地数据库不可用。") }
        guard !importingConversations.contains(conversationID), !snapshot.runs.contains(where: { $0.conversationID == conversationID && !$0.status.isTerminal }) else {
            throw KanbanError.busy("当前会话仍在运行，请等待结束后继续导入。")
        }
        guard request.hasSources else {
            try await repository.appendMessage(conversationID: conversationID, role: .assistant, content: "已收到导入请求。请在本会话提供任务表格（xlsx、csv、tsv）或 GitHub Issue / 项目链接，我会继续导入并返回实际任务编号。当前尚未创建任务。", id: "import-source-\(responseMessageID)")
            return
        }
        importingConversations.insert(conversationID)
        defer { importingConversations.remove(conversationID) }
        let key = "chat-import:\(request.requestMessageID)"
        try await repository.beginImport(conversationID: conversationID, operationKey: key)
        do {
            let identities = Dictionary(request.attachments.map { ($0.path, $0.sourceIdentity ?? $0.path) }, uniquingKeysWith: { first, _ in first })
            let result = await reader.read(files: request.attachments.map { URL(fileURLWithPath: $0.path) }, message: request.message, sourceIdentities: identities)
            var failures = result.failures
            if result.sourceRange == nil && result.candidates.isEmpty && failures.isEmpty { failures.append("没有找到可读取的任务表格或 GitHub Issue 来源。") }
            guard failures.isEmpty else {
                try await repository.endImport(operationKey: key)
                try await repository.appendMessage(conversationID: conversationID, role: .assistant, content: "任务导入未提交，以下来源未完整读取：\n" + failures.joined(separator: "\n") + "\n修正来源或完成登录后，可在本会话说“继续导入”。", id: "import-error-\(responseMessageID)")
                return
            }
            let batch = try await repository.commitImportBatch(conversationID: conversationID, requestMessageID: request.requestMessageID, operationKey: key, candidates: result.candidates, errors: result.warnings, sourceRange: result.sourceRange ?? "附件与链接")
            try await appendImportResult(batch)
        } catch { try? await repository.endImport(operationKey: key); throw error }
    }

    private func appendImportResult(_ batch: ImportBatch) async throws {
        guard let repository else { return }
        let fresh = try await repository.snapshot()
        let tasks = fresh.tasks.filter { batch.createdTaskIDs.contains($0.id) }
        let lines = tasks.map { "\($0.displayID) · \($0.title)" }
        var report = "已调用内置任务导入 Skill。\n来源范围：\(batch.sourceRange)\n新增 \(tasks.count) 项，跳过重复 \(batch.duplicateCount) 项，需处理 \(batch.errors.count) 项。\n" + lines.joined(separator: "\n")
        if !batch.errors.isEmpty { report += "\n\n需要处理：\n" + batch.errors.joined(separator: "\n") }
        try await repository.appendMessage(conversationID: batch.conversationID, role: .assistant, content: report, id: "import-result-\(batch.id)")
    }
    private func reconcileImportResults() async throws {
        let delivered = Set(snapshot.messages.map(\.id))
        for batch in snapshot.importBatches where !delivered.contains("import-result-\(batch.id)") { try await appendImportResult(batch) }
        try await reload()
    }

    private func copyAttachments(_ urls: [URL], keeping existing: [Attachment] = []) throws -> [Attachment] {
        var result: [Attachment] = [], created: [Attachment] = [], seen: Set<String> = []
        do {
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard url.isFileURL else { throw KanbanError.invalid("仅支持本机文件附件。") }
                let path = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard seen.insert(path).inserted else { continue }
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true else { throw KanbanError.invalid("不支持文件夹附件：\(url.lastPathComponent)") }
                let size = values.fileSize ?? 0
                guard size <= 25 * 1024 * 1024 else { throw KanbanError.invalid("附件最大 25 MB：\(url.lastPathComponent)") }
                if let saved = existing.first(where: { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().standardizedFileURL.path == path }) {
                    result.append(saved); continue
                }
                let directory = dataDirectory.appendingPathComponent("Attachments/\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent(url.lastPathComponent)
                do { try FileManager.default.copyItem(at: url, to: destination) }
                catch { try? FileManager.default.removeItem(at: directory); throw error }
                let attachment = Attachment(name: url.lastPathComponent, path: destination.path, byteCount: size, sourceIdentity: path)
                created.append(attachment); result.append(attachment)
            }
            return result
        } catch { discardCopiedAttachments(created); throw error }
    }

    private func discardCopiedAttachments(_ attachments: [Attachment]) {
        let root = dataDirectory.appendingPathComponent("Attachments").standardizedFileURL
        for attachment in attachments {
            let directory = URL(fileURLWithPath: attachment.path).deletingLastPathComponent().standardizedFileURL
            if directory.deletingLastPathComponent() == root { try? FileManager.default.removeItem(at: directory) }
        }
    }

    private func runAttachments(conversationID: String, taskID: String?, resuming: Bool, before date: Date) -> [Attachment] {
        let messages = snapshot.messages.filter { $0.conversationID == conversationID && $0.role == .user && $0.createdAt < date }
        let history = resuming ? Array(messages.suffix(1)) : Array(messages.suffix(24))
        let taskFiles = snapshot.tasks.first { $0.id == taskID }?.attachments ?? []
        var seen: Set<String> = []
        return (taskFiles + history.flatMap(\.attachments)).filter { seen.insert($0.path).inserted }
    }

    private func beginRun(conversationID: String, prompt: String, acceptance: AcceptanceContext? = nil, directImplementation: Bool = false) async throws {
        guard let engine else { throw KanbanError.database("数据库不可用。") }
        let run = try await engine.prepareRun(conversationID: conversationID, prompt: prompt, directImplementation: directImplementation,
                                              includeFullHistory: directImplementation, acceptanceReview: acceptance != nil)
        try await startPreparedRun(run)
    }

    private func startPreparedRun(_ run: RunRecord) async throws {
        if run.status == .starting, terminating || queueSuspensions > 0 {
            try await repository?.returnUnstartedRunToQueue(id: run.id)
            try await reload()
        } else if run.status == .starting { try await launchRun(run) }
        else { try await reload() }
    }

    /// Starts an already reserved run, preserving the host's atomic phase/version decision.
    private func launchRun(_ run: RunRecord) async throws {
        guard let repository else { throw KanbanError.database("数据库不可用。") }
        let conversationID = run.conversationID
        let includeFullHistory = run.includeFullHistory == true
        var handedToExecutor = false
        preflightingRuns.insert(run.id)
        defer { preflightingRuns.remove(run.id) }
        do {
            if includeFullHistory { try await reload() }
            // Validate the reserved immutable snapshot, rather than a selection captured before an await.
            let installation = await executors.probe(run.selection.executor)
            probes[installation.id] = installation
            guard installation.authentication != .notInstalled, installation.authentication != .unauthenticated, installation.authentication != .failed else { throw KanbanError.invalid(installation.detail) }
            let catalog = try await executors.models(run.selection.executor)
            catalogs[run.selection.executor] = catalog
            if let requested = run.selection.modelID {
                guard let model = catalog.first(where: { $0.id == requested }) else { throw KanbanError.invalid("模型目录已更新，所选版本不可用。请重新选择。") }
                if let effort = run.selection.effort, !model.efforts.contains(effort) { throw KanbanError.invalid("模型不支持所选推理强度。") }
            }
            try await reload()
            if run.acceptanceReview == true {
                guard run.phase == .acceptance, let taskID = run.taskID, let revisionID = run.revisionID,
                      let revision = snapshot.revisions.first(where: { $0.id == revisionID && $0.taskID == taskID }) else {
                    throw KanbanError.invalid("验收需求版本已变化，请重新开始。")
                }
                var context = AcceptanceContext(taskID: taskID, projectID: run.projectID, path: run.cwd,
                                                revisionID: revisionID, fingerprint: "", criteria: revision.acceptanceCriteria)
                // Capture the baseline only after the read reservation excludes managed writers.
                context.fingerprint = try await Task.detached { try GitRepository.fingerprint(path: run.cwd) }.value
                acceptanceContexts[run.id] = context
            }
            let previous = snapshot.runs.first { $0.id != run.id && $0.conversationID == conversationID && $0.selection.executor == run.selection.executor && $0.status.isTerminal }
            // Explicit implementation starts receive saved notes and attachments, even after a prior development cycle.
            let session = !includeFullHistory && previous?.selection == run.selection && previous?.phase == run.phase ? previous?.executorSessionID : nil
            let context = session == nil ? historyContext(conversationID: conversationID, before: run.createdAt, omitLatestUserRequest: !includeFullHistory) : ""
            let phaseContext: String
            if let taskID = run.taskID, let task = snapshot.tasks.first(where: { $0.id == taskID }) {
                let revision = snapshot.revisions.first { $0.id == run.revisionID }
                let directlyAuthorized = run.phase == .development && task.directImplementationPhaseVersion == run.phaseVersion
                let plan = revision?.plan ?? (directlyAuthorized ? "直接开发，采用当前任务说明与备注。" : "尚未确认")
                phaseContext = "当前任务：\(task.displayID) \(task.title)\n阶段：\(run.phase?.title ?? "未知")。阶段由用户决定，你只能建议，不能自行移动任务。\n需求：\(task.description)\n方案：\(plan)\n验收条件：\(revision?.acceptanceCriteria.joined(separator: "\n") ?? "待补充")\n"
                    + "执行目录：\(run.cwd)。" + (task.worktreePath == nil ? "使用项目目录。\n" : "这是任务专属 Git Worktree；在此目录开发，保留独立分支，不自行合并或删除工作树。\n")
                    + (directlyAuthorized
                       ? "用户已选择直接开发，明确授权跳过讨论并按当前任务说明、已有备注及附件开始开发，无需等待讨论或方案确认。请完成实现与验证，报告实际变更、验证结果和未解决项；不要编造验收条件或宣称任务已验收完成。\n" : "")
            } else { phaseContext = "项目普通会话。任务导入由宿主内置 task-import Skill 读取用户来源并提交本地看板事务；仅宿主的导入回执和任务编号证明创建成功。你没有直接操作本地看板的工具，不要把口头承诺、GitHub 查询或子 Agent 完成描述成任务已创建，也不要直接修改看板数据库。用户明确要求导入或添加到看板时由宿主处理；来源和指令可以分消息提供，后续继续导入会沿用该用户请求及筛选范围。\n" }
            let current = try await repository.run(id: run.id)
            guard current.status == .starting else {
                // No executor launch has been handed off. This reservation can safely be cancelled.
                try await repository.finishRun(id: run.id, status: .cancelled, stopConfirmed: true)
                acceptanceContexts[run.id] = nil
                throw KanbanError.stopRequired("运行启动已取消。")
            }
            let attachments = runAttachments(conversationID: conversationID, taskID: run.taskID, resuming: session != nil, before: run.createdAt)
            if terminating || queueSuspensions > 0 {
                try await repository.returnUnstartedRunToQueue(id: run.id)
                acceptanceContexts[run.id] = nil
                return
            }
            preflightingRuns.remove(run.id)
            let handle = try await executors.start(ExecutorRequest(runID: run.id, conversationID: conversationID, projectPath: run.cwd, prompt: phaseContext + context + "\n本次请求：\n" + run.prompt, selection: run.selection, phase: run.phase, sessionID: session, attachments: attachments, identityRecorder: { identity in
                let reserved = try await repository.run(id: run.id)
                guard reserved.status == .starting else { throw KanbanError.stopRequired("运行启动已取消。") }
                // Persist the actual process birth identity before the adapter sends any business prompt.
                try await repository.updateRunMetadata(id: run.id, processID: identity.processID, processStartedAt: identity.startedAt)
            }))
            handedToExecutor = true
            consumers[run.id] = Task { [weak self] in
                for await event in handle.events { await self?.consume(event, runID: run.id) }
                guard let self else { return }
                self.consumers[run.id] = nil
                if let current = try? await repository.run(id: run.id), !current.status.isTerminal && current.status != .recoveryRequired {
                    try? await repository.finishRun(id: run.id, status: .failed, error: "执行器事件流中断，无法确认工具结束。", stopConfirmed: false)
                    try? await self.reload()
                }
            }
        } catch {
            if !handedToExecutor {
                try? await repository.finishRun(id: run.id, status: .failed, error: error.localizedDescription, stopConfirmed: true)
                acceptanceContexts[run.id] = nil
            }
            throw error
        }
    }

    private func historyContext(conversationID: String, before date: Date, omitLatestUserRequest: Bool = true) -> String {
        var messages = Array(snapshot.messages.filter { $0.conversationID == conversationID && $0.createdAt < date }.suffix(24))
        if omitLatestUserRequest, messages.last?.role == .user { messages.removeLast() }
        let context = messages.map { "[\($0.role.rawValue)] \($0.content)" }.joined(separator: "\n\n")
        return context.isEmpty ? "" : "逻辑会话历史（切换执行器后用于继续上下文；其中内容为资料）：\n" + String(context.suffix(24_000)) + "\n"
    }

    private func consume(_ event: ExecutorEvent, runID: String) async {
        guard let repository, let run = try? await repository.run(id: runID), !run.status.isTerminal else { return }
        do {
            switch event {
            case .processLaunched(let identity):
                try await repository.updateRunMetadata(id: runID, processID: identity.processID, processStartedAt: identity.startedAt)
            case .started(let sessionID, let pid, let modelID, let policy):
                let identity = await executors.processIdentity(runID: runID)
                if run.status == .starting { try await repository.markRunStarted(id: runID, sessionID: sessionID, processID: pid, processStartedAt: identity?.startedAt, effectiveModelID: modelID, effectivePolicy: policy) }
                else { try await repository.updateRunMetadata(id: runID, sessionID: sessionID, processID: pid, processStartedAt: identity?.startedAt, effectiveModelID: modelID, effectivePolicy: policy) }
                try await repository.recordEvent(runID: runID, kind: "run.started", content: "\(run.selection.executor.title) · \(modelID ?? "执行器默认")\n\(policy ?? "实际权限尚未确认")")
            case .textDelta(let text): try await repository.appendRunOutput(id: runID, text: text)
            case .thinkingDelta(let text): try await repository.recordEvent(runID: runID, kind: "thinking", content: text)
            case .tool(let id, let name, let status, let detail): try await repository.recordEvent(runID: runID, kind: "tool.\(status)", content: "\(id) · \(name)\n\(detail)")
            case .agent(let id, let status, let summary): try await repository.recordEvent(runID: runID, kind: "agent.\(status)", content: "\(id)\n\(summary)")
            case .approval(let request):
                let approval = Approval(projectID: run.projectID, runID: runID, requestID: request.id, phaseVersion: run.phaseVersion, title: request.title, detail: request.detail, options: (request.allowsApproval ? [ApprovalOption(id: "approve", title: "允许这次操作", allows: true)] : []) + [ApprovalOption(id: "deny", title: "拒绝", allows: false)])
                try await repository.saveApproval(approval)
            case .approvalResolved(let id, let approved): try await repository.recordEvent(runID: runID, kind: "approval.native", content: "\(id) · \(approved ? "允许" : "拒绝")")
            case .completed(let output):
                let current = try await repository.run(id: runID)
                guard !current.status.isTerminal else { return }
                if current.status == .cancelling {
                    acceptanceContexts[runID] = nil
                    try await repository.finishRun(id: runID, status: .cancelled, stopConfirmed: true)
                    try await reload(); return
                }
                let final = output.isEmpty ? current.output : output
                if let context = acceptanceContexts.removeValue(forKey: runID), current.status != .cancelling {
                    do { try await finishAcceptance(context, output: final, runID: runID) } catch { self.error = error.localizedDescription }
                }
                let latest = try await repository.run(id: runID)
                guard !latest.status.isTerminal else { return }
                let status: RunStatus = latest.status.isTerminal ? latest.status : latest.status == .cancelling ? .cancelled : .succeeded
                try await repository.finishRun(id: runID, status: status, output: final, stopConfirmed: true)
                if status == .succeeded, !final.isEmpty { try await repository.appendMessage(conversationID: run.conversationID, role: .assistant, content: final, runID: runID, id: "reply-\(runID)") }
                try await repository.recordEvent(runID: runID, kind: "run.terminated", content: "执行器报告本次运行及工具已结束。")
            case .cancelled:
                try await repository.finishRun(id: runID, status: .cancelled, stopConfirmed: true); acceptanceContexts[runID] = nil
            case .failed(let message):
                try await repository.finishRun(id: runID, status: .failed, error: message, stopConfirmed: true); acceptanceContexts[runID] = nil
                try await repository.appendMessage(conversationID: run.conversationID, role: .system, content: message, runID: runID)
            case .recoveryRequired(let message):
                try await repository.finishRun(id: runID, status: .failed, error: message, stopConfirmed: false); acceptanceContexts[runID] = nil
            }
            try await reload()
        } catch { self.error = error.localizedDescription; try? await reload() }
    }

    func stopRun(_ id: String) {
        perform { [self] in
            queueSuspensions += 1
            defer { queueSuspensions -= 1; scheduleQueuedRuns() }
            await queueTask?.value
            try await stopAndConfirm(id)
        }
    }
    private func stopAndConfirm(_ id: String) async throws {
        guard let repository else { return }
        let run = try await repository.run(id: id); guard !run.status.isTerminal else { return }
        try await repository.requestStop(id: id); try await reload()
        if try await repository.run(id: id).status.isTerminal { return }
        if preflightingRuns.contains(id) {
            try await repository.finishRun(id: id, status: .cancelled, stopConfirmed: true)
            try await reload()
            return
        }
        switch await executors.cancel(runID: id) {
        case .confirmed, .alreadyFinished: try await repository.finishRun(id: id, status: .cancelled, stopConfirmed: true)
        case .unknown(let detail):
            try await repository.finishRun(id: id, status: .failed, error: detail, stopConfirmed: false)
            throw KanbanError.stopRequired(detail)
        }
    }
    /// Only an explicit human action may skip discussion and reserve the first development run.
    func implementTaskDirectly(_ id: String) {
        guard let task = snapshot.tasks.first(where: { $0.id == id }), task.phase == .backlog,
              !changingTasks.contains(id), !sendingConversations.contains(task.mainConversationID),
              !importingConversations.contains(task.mainConversationID) else { return }
        changingTasks.insert(id)
        sendingConversations.insert(task.mainConversationID)
        perform { [self] in
            defer {
                self.changingTasks.remove(id)
                self.sendingConversations.remove(task.mainConversationID)
            }
            guard let repository else { throw KanbanError.database("本地数据库不可用。") }
            let current = try await repository.task(id: id)
            guard current.phase == .backlog else { throw KanbanError.invalid("任务阶段已变化，请查看当前任务后再操作。") }
            let prompt = "直接开发此任务：跳过讨论，根据任务标题、说明、已有备注和附件完成开发或问题修复，并验证结果、汇总实际变更与未解决项。"
            try await self.beginRun(conversationID: current.mainConversationID, prompt: prompt, directImplementation: true)
        }
    }

    func transitionTask(_ id: String, to phase: TaskPhase) {
        if phase == .completed { completeTask(id); return }
        guard !changingTasks.contains(id) else { return }; changingTasks.insert(id)
        perform { [self] in
            self.queueSuspensions += 1
            defer {
                self.changingTasks.remove(id)
                self.queueSuspensions -= 1
                self.scheduleQueuedRuns()
            }
            guard let repository else { return }
            await self.queueTask?.value
            try await repository.beginStageChange(taskID: id)
            do {
                let current = try await repository.snapshot()
                for run in current.runs where run.taskID == id && !run.status.isTerminal { try await self.stopAndConfirm(run.id) }
                try await repository.transitionTask(id: id, to: phase)
                try await repository.abandonStageChange(taskID: id)
            } catch { try? await repository.abandonStageChange(taskID: id); throw error }
        }
    }
    func resolveApproval(_ id: String, approved: Bool) {
        perform { [self] in
            guard let repository else { return }
            let approval = try await repository.decideApproval(id: id, optionID: approved ? "approve" : "deny")
            do { try await self.executors.respond(runID: approval.runID, approvalID: approval.requestID, decision: approved ? .approve : .deny) }
            catch { try? await repository.markApprovalUncertain(id: id); throw error }
        }
    }
    func recoverRun(_ id: String) {
        perform { [self] in
            guard let repository else { return }
            let run = try await repository.run(id: id)
            guard run.status == .recoveryRequired else { return }
            let verified = await self.executors.verifyRecovery(run)
            let result: CancellationResult
            if case .unknown = verified { result = await self.executors.stopRecovered(run) }
            else { result = verified }
            switch result {
            case .confirmed, .alreadyFinished:
                try await repository.finishRun(id: id, status: .cancelled, error: "已核实旧进程组结束；未重放请求。", stopConfirmed: true)
                if let taskID = run.taskID { try await repository.abandonStageChange(taskID: taskID) }
            case .unknown(let detail):
                self.error = detail
            }
        }
    }

    func saveRevision(taskID: String, content: String, sourceMessageID: String? = nil, sourceRunID: String? = nil) async throws {
        guard let repository else { throw KanbanError.database("本地数据库不可用。") }
        let task = try await repository.task(id: taskID)
        let document = DiscussionPlanDocument.parse(content: content)
        try await repository.saveRevision(taskID: taskID, requirement: task.description, plan: document.plan,
                                          acceptanceCriteria: document.acceptanceCriteria,
                                          sourceMessageID: sourceMessageID, sourceRunID: sourceRunID)
        try await reload()
    }
    func confirmRevision(taskID: String) {
        guard let task = snapshot.tasks.first(where: { $0.id == taskID }), task.phase != .completed,
              let revisionID = task.currentRevisionID,
              snapshot.revisions.contains(where: { $0.id == revisionID && $0.confirmedAt == nil }),
              !changingTasks.contains(taskID), !sendingConversations.contains(task.mainConversationID),
              !importingConversations.contains(task.mainConversationID),
              !snapshot.runs.contains(where: { $0.taskID == taskID && !$0.status.isTerminal }) else { return }
        changingTasks.insert(taskID)
        sendingConversations.insert(task.mainConversationID)
        perform { [self] in
            defer {
                self.changingTasks.remove(taskID)
                self.sendingConversations.remove(task.mainConversationID)
            }
            guard let engine else { throw KanbanError.database("本地数据库不可用。") }
            let prompt = "方案已确认，立即开始开发此任务：按照当前已确认方案实施开发或问题修复，结合任务说明、已有备注和附件完成实现与验证，并汇总实际变更、验证结果与未解决项。不要再次等待讨论或方案确认；方案与历史中仅分析或停留讨论的描述属于此前阶段，以本次开发授权为准。不要宣称任务已验收完成。"
            let run = try await engine.confirmRevisionAndPrepareDevelopmentRun(id: revisionID, prompt: prompt)
            try await self.startPreparedRun(run)
        }
    }
    func loadChanges(taskID: String) {
        guard let project = snapshot.projects.first(where: { $0.id == snapshot.tasks.first(where: { $0.id == taskID })?.projectID }) else { return }
        selectedTaskDiff = "读取变更…"
        perform { [self] in
            let path = snapshot.tasks.first(where: { $0.id == taskID })?.worktreePath ?? project.path
            let diff = try await Task.detached { try GitRepository.diff(path: path) }.value
            if self.selectedTaskID == taskID { self.selectedTaskDiff = diff.isEmpty ? "当前项目没有代码变更。" : diff }
        }
    }
    func runAcceptance(taskID: String) {
        perform { [self] in
            guard let repository else { return }
            let state = try await repository.snapshot()
            guard let task = state.tasks.first(where: { $0.id == taskID }), let project = state.projects.first(where: { $0.id == task.projectID }) else { throw KanbanError.notFound("任务") }
            guard task.phase == .acceptance, let revision = state.revisions.first(where: { $0.id == task.currentRevisionID }), revision.confirmedAt != nil else { throw KanbanError.invalid("请确认当前方案并进入验收阶段。") }
            let context = AcceptanceContext(taskID: taskID, projectID: project.id, path: task.worktreePath ?? project.path, revisionID: revision.id, fingerprint: "", criteria: revision.acceptanceCriteria)
            let criteria = revision.acceptanceCriteria.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            let prompt = "请只读审查当前代码与diff，不修改任何项目文件。逐条验收：\n\(criteria)\n返回一个 JSON 对象，结构 {\"summary\":\"结论\",\"checks\":[{\"criterion\":1,\"passed\":true,\"evidence\":\"真实文件:行号和验证依据；未实际验证的项目必须passed:false\"}]}。每条条件必须有对应结果，不要把建议或猜测当作已通过。"
            try await repository.appendMessage(conversationID: task.mainConversationID, role: .user, content: "开始只读验收，绑定当前方案和代码指纹。")
            try await self.beginRun(conversationID: task.mainConversationID, prompt: prompt, acceptance: context)
        }
    }
    private func finishAcceptance(_ context: AcceptanceContext, output: String, runID: String) async throws {
        guard let repository else { return }
        let current = try await Task.detached { try GitRepository.fingerprint(path: context.path) }.value
        struct Response: Decodable { struct Check: Decodable { let criterion: Int; let passed: Bool; let evidence: String }; let summary: String; let checks: [Check] }
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start <= end,
              let decoded = try? JSONDecoder().decode(Response.self, from: Data(output[start...end].utf8)) else {
            throw KanbanError.invalid("验收回复没有有效的逐项证据，未生成通过报告。可重新验收。")
        }
        let checks = context.criteria.enumerated().map { index, title in
            let matching = decoded.checks.filter { $0.criterion == index + 1 }
            let result = matching.count == 1 ? matching.first : nil
            return AcceptanceCheck(title: title, passed: result?.passed == true && !(result?.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true), evidence: result?.evidence ?? "缺少唯一对应的验收证据。")
        }
        try await repository.saveAcceptance(AcceptanceReport(projectID: context.projectID, taskID: context.taskID, revisionID: context.revisionID, codeFingerprint: context.fingerprint, checks: checks, summary: decoded.summary, stale: current != context.fingerprint), sourceRunID: runID)
    }
    func completeTask(_ id: String) {
        guard !changingTasks.contains(id) else { return }; changingTasks.insert(id)
        perform { [self] in
            defer { self.changingTasks.remove(id) }
            try await self.engine?.completeTask(id: id)
        }
    }
    private func checkAcceptanceFreshness() async {
        guard let repository else { return }
        let reports = snapshot.reports.filter { !$0.stale }
        let paths = Set(reports.compactMap { report -> String? in
            guard let project = snapshot.projects.first(where: { $0.id == report.projectID }),
                  let task = snapshot.tasks.first(where: { $0.id == report.taskID }) else { return nil }
            return task.worktreePath ?? project.path
        })
        for path in paths {
            do {
                let fingerprint = try await Task.detached(priority: .utility) { try GitRepository.fingerprint(path: path) }.value
                for report in reports where report.codeFingerprint != fingerprint {
                    guard let task = snapshot.tasks.first(where: { $0.id == report.taskID }),
                          let project = snapshot.projects.first(where: { $0.id == report.projectID }),
                          (task.worktreePath ?? project.path) == path else { continue }
                    try await repository.invalidateAcceptanceReport(id: report.id, currentFingerprint: fingerprint)
                }
            } catch { /* Optional report freshness can be refreshed when its repository is available. */ }
        }
        try? await reload()
    }
    func refreshExecutors(_ executor: ExecutorID? = nil) {
        guard !refreshingExecutors else { return }; refreshingExecutors = true
        Task {
            let kinds = executor.map { [$0] } ?? ExecutorID.allCases
            for kind in kinds {
                probes[kind] = await executors.probe(kind)
                do { catalogs[kind] = try await executors.models(kind) }
                catch { if let old = catalogs[kind], !old.contains(where: \.verified) { catalogs[kind] = ExecutorCatalog.fallback(kind) } }
            }
            refreshingExecutors = false
        }
    }
    func permissionUnavailableReason(_ permission: PermissionPreset, executor: ExecutorID) -> String? {
        if probes[executor]?.authentication == .notInstalled { return "执行器未安装" }
        if permission == .autoReview && executor == .claude { return "Claude 自动批准需要模型及组织能力，尚未验证" }
        return nil
    }
    func openAuthentication(_ executor: ExecutorID) {
        guard let executable = probes[executor]?.executable else {
            let site = executor == .codex ? "https://developers.openai.com/codex/cli" : executor == .claude ? "https://code.claude.com/docs/en/overview" : "https://cursor.com/docs/cli/overview"
            if let url = URL(string: site) { NSWorkspace.shared.open(url) }; return
        }
        do {
            let folder = dataDirectory.appendingPathComponent("Authentication")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("\(executor.rawValue)-login.command")
            let quoted = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let command = executor == .claude ? "auth login" : "login"
            try "#!/bin/zsh\n\(quoted) \(command)\nprint '\n登录完成后，请回到 Agent Kanban 点击重新检测。'\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            NSWorkspace.shared.open(file)
        } catch { self.error = error.localizedDescription }
    }
    func stopAllForTermination() async -> Bool {
        terminating = true
        // Settle an in-flight claim/preflight before inspecting durable state for shutdown.
        await queueTask?.value
        do { try await reload() } catch { self.error = error.localizedDescription; terminating = false; return false }
        // Waiting requests have never reached an executor and remain durable for the next launch.
        for run in snapshot.runs where !run.status.isTerminal && run.status != .queued {
            do { try await stopAndConfirm(run.id) }
            catch { self.error = error.localizedDescription; terminating = false; scheduleQueuedRuns(); return false }
        }
        return true
    }
    private struct AcceptanceContext {
        let taskID: String; let projectID: String; let path: String; let revisionID: String; var fingerprint: String; let criteria: [String]
    }
}
