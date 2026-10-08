import Foundation
import CSQLite

private final class SQLiteDatabase: @unchecked Sendable {
    let handle: OpaquePointer
    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw KanbanError.database("无法打开本机数据库。")
        }
        handle = db
        sqlite3_busy_timeout(db, 5000)
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = FULL")
    }
    deinit { sqlite3_close(handle) }
    func execute(_ sql: String, _ values: [String?] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw failure() }
    }
    func rows(_ sql: String, _ values: [String?] = []) throws -> [[String]] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var result: [[String]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw failure() }
            result.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            })
        }
        return result
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let value = try body(); try execute("COMMIT"); return value }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func prepare(_ sql: String, _ values: [String?]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            if let value {
                _ = value.withCString { sqlite3_bind_text(statement, Int32(offset + 1), $0, -1, transient) }
            } else { sqlite3_bind_null(statement, Int32(offset + 1)) }
        }
        return statement
    }
    private func failure() -> KanbanError { .database("本机数据库操作失败：\(String(cString: sqlite3_errmsg(handle)))") }
}

/// The sole database owner. Every command revalidates identity and active project membership.
public actor Repository {
    private let db: SQLiteDatabase
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(databaseURL: URL) throws {
        db = try SQLiteDatabase(url: databaseURL)
        encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970; encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        for sql in Self.schema { try db.execute(sql) }
    }

    private static let schema = [
        "CREATE TABLE IF NOT EXISTS projects (id TEXT PRIMARY KEY, path TEXT NOT NULL, active INTEGER NOT NULL, payload TEXT NOT NULL)",
        "CREATE UNIQUE INDEX IF NOT EXISTS project_active_path ON projects(path) WHERE active = 1",
        "CREATE TABLE IF NOT EXISTS tasks (id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id), number INTEGER NOT NULL, conversation_id TEXT NOT NULL UNIQUE, payload TEXT NOT NULL, UNIQUE(project_id, number))",
        "CREATE TABLE IF NOT EXISTS conversations (id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id), task_id TEXT REFERENCES tasks(id), kind TEXT NOT NULL, payload TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS conversation_deletions (conversation_id TEXT PRIMARY KEY REFERENCES conversations(id), deleted_at TEXT NOT NULL)",
        "CREATE UNIQUE INDEX IF NOT EXISTS one_task_main ON conversations(task_id) WHERE kind = 'taskMain'",
        "CREATE TABLE IF NOT EXISTS messages (id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id), conversation_id TEXT NOT NULL REFERENCES conversations(id), payload TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS runs (id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id), conversation_id TEXT NOT NULL REFERENCES conversations(id), task_id TEXT REFERENCES tasks(id), terminal INTEGER NOT NULL, payload TEXT NOT NULL)",
        "CREATE UNIQUE INDEX IF NOT EXISTS one_active_task_run ON runs(task_id) WHERE terminal = 0 AND task_id IS NOT NULL",
        "CREATE UNIQUE INDEX IF NOT EXISTS one_active_conversation_run ON runs(conversation_id) WHERE terminal = 0",
        "CREATE TABLE IF NOT EXISTS directory_leases (path TEXT PRIMARY KEY, run_id TEXT NOT NULL UNIQUE REFERENCES runs(id))",
        "CREATE TABLE IF NOT EXISTS stage_barriers (task_id TEXT PRIMARY KEY REFERENCES tasks(id), project_id TEXT NOT NULL REFERENCES projects(id))",
        "CREATE TABLE IF NOT EXISTS import_jobs (operation_key TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id), conversation_id TEXT NOT NULL REFERENCES conversations(id))",
        "CREATE TABLE IF NOT EXISTS approvals (id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id), run_id TEXT NOT NULL REFERENCES runs(id), request_id TEXT NOT NULL, payload TEXT NOT NULL, UNIQUE(run_id,request_id))",
        "CREATE TABLE IF NOT EXISTS revisions (id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id), task_id TEXT NOT NULL REFERENCES tasks(id), payload TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS reports (id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id), task_id TEXT NOT NULL REFERENCES tasks(id), payload TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS import_batches (id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id), conversation_id TEXT NOT NULL REFERENCES conversations(id), operation_key TEXT NOT NULL UNIQUE, payload TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS provenance (id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id), task_id TEXT NOT NULL REFERENCES tasks(id), source_key TEXT NOT NULL, payload TEXT NOT NULL, UNIQUE(project_id,source_key))",
        "CREATE TABLE IF NOT EXISTS events (id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id), run_id TEXT NOT NULL REFERENCES runs(id), payload TEXT NOT NULL)",
        "PRAGMA user_version = 1"
    ]

    public func snapshot() throws -> WorkspaceSnapshot {
        let projects = try (all("projects") as [Project]).filter(\.isActive)
        let ids = Set(projects.map(\.id))
        let tasks: [TaskItem] = try all("tasks"); let conversations: [Conversation] = try all("conversations")
        let messages: [Message] = try all("messages"); let runs: [RunRecord] = try all("runs")
        let approvals: [Approval] = try all("approvals"); let revisions: [RequirementRevision] = try all("revisions")
        let reports: [AcceptanceReport] = try all("reports"); let batches: [ImportBatch] = try all("import_batches")
        let sources: [Provenance] = try all("provenance"); let events: [RunEvent] = try all("events")
        let deletedConversationIDs = Set(try db.rows("SELECT conversation_id FROM conversation_deletions").compactMap(\.first))
        let visibleConversations = conversations.filter { ids.contains($0.projectID) && !deletedConversationIDs.contains($0.id) }
        let conversationIDs = Set(visibleConversations.map(\.id))
        let visibleRuns = runs.filter { ids.contains($0.projectID) && conversationIDs.contains($0.conversationID) }
        let runIDs = Set(visibleRuns.map(\.id))
        return .init(projects: projects.sorted { $0.createdAt < $1.createdAt }, tasks: tasks.filter { ids.contains($0.projectID) }.sorted { $0.number < $1.number }, conversations: visibleConversations.sorted { $0.createdAt < $1.createdAt }, messages: messages.filter { ids.contains($0.projectID) && conversationIDs.contains($0.conversationID) }.sorted { $0.createdAt < $1.createdAt }, runs: visibleRuns.sorted { $0.createdAt > $1.createdAt }, approvals: approvals.filter { ids.contains($0.projectID) && runIDs.contains($0.runID) }, revisions: revisions.filter { ids.contains($0.projectID) }, reports: reports.filter { ids.contains($0.projectID) }, importBatches: batches.filter { ids.contains($0.projectID) && conversationIDs.contains($0.conversationID) }, provenance: sources.filter { ids.contains($0.projectID) }, events: events.filter { ids.contains($0.projectID) && runIDs.contains($0.runID) }.sorted { $0.createdAt < $1.createdAt })
    }

    @discardableResult public func importProject(path: String, name: String? = nil, defaultExecutor: ExecutorID = .codex) throws -> Project {
        let root = try GitRepository.canonicalRoot(path: path)
        return try db.transaction {
            if let existing = try (query("projects", where: "path = ? AND active = 1", values: [root]) as [Project]).first { return existing }
            let project = Project(name: name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? URL(fileURLWithPath: root).lastPathComponent, path: root, defaultExecutor: defaultExecutor)
            try writeProject(project)
            return project
        }
    }
    public func project(id: String) throws -> Project { try activeProject(id) }
    public func task(id: String) throws -> TaskItem { try required("tasks", id: id, name: "任务") }
    public func conversation(id: String) throws -> Conversation {
        guard try db.rows("SELECT conversation_id FROM conversation_deletions WHERE conversation_id = ?", [id]).isEmpty else { throw KanbanError.notFound("会话") }
        return try required("conversations", id: id, name: "会话")
    }
    public func run(id: String) throws -> RunRecord { try required("runs", id: id, name: "运行") }
    public func setDefaultExecutor(projectID: String, executor: ExecutorID) throws {
        var project = try activeProject(projectID); project.defaultExecutor = executor; try writeProject(project)
    }
    public func removeProject(id: String) throws {
        try db.transaction {
            var project = try activeProject(id)
            guard try db.rows("SELECT id FROM runs WHERE project_id = ? AND terminal = 0", [id]).isEmpty,
                  try db.rows("SELECT operation_key FROM import_jobs WHERE project_id = ?", [id]).isEmpty,
                  try db.rows("SELECT task_id FROM stage_barriers WHERE project_id = ?", [id]).isEmpty else {
                throw KanbanError.busy("项目仍有运行、停止核对或任务导入，请先结束后移除。")
            }
            project.removedAt = Date(); try writeProject(project)
        }
    }
    @discardableResult public func createTask(projectID: String, title: String, description: String = "", type: TaskType = .feature, priority: TaskPriority = .normal, attachments: [Attachment] = []) throws -> TaskItem {
        try db.transaction { try insertTask(project: activeProject(projectID), title: title, description: description, type: type, priority: priority, attachments: attachments) }
    }
    @discardableResult public func createConversation(projectID: String, title: String = "新会话") throws -> Conversation {
        let project = try activeProject(projectID)
        let conversation = Conversation(projectID: project.id, title: title, selection: .init(executor: project.defaultExecutor))
        try writeConversation(conversation); return conversation
    }
    public func updateTask(id: String, title: String, description: String, type: TaskType, priority: TaskPriority, attachments: [Attachment]? = nil) throws {
        try db.transaction {
            var task = try task(id: id); _ = try activeProject(task.projectID)
            guard let title = title.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else { throw KanbanError.invalid("任务标题不能为空。") }
            guard try db.rows("SELECT id FROM runs WHERE task_id = ? AND terminal = 0", [id]).isEmpty else { throw KanbanError.busy("请先停止任务运行再修改任务。") }
            let attachmentsChanged = attachments.map { $0 != (task.attachments ?? []) } ?? false
            if task.title != title || task.description != description || attachmentsChanged {
                task.currentRevisionID = nil; task.directImplementationPhaseVersion = nil
                try invalidateReports(taskID: id)
            }
            if let attachments { task.attachments = attachments }
            task.title = title; task.description = description; task.type = type; task.priority = priority; task.updatedAt = Date()
            try writeTask(task)
            var conversation = try conversation(id: task.mainConversationID); conversation.title = title; try writeConversation(conversation)
        }
    }
    /// Select an existing linked worktree without changing the imported project or Git state.
    public func configureTaskWorktree(taskID: String, path: String?) throws {
        try db.transaction {
            var task = try task(id: taskID)
            let project = try activeProject(task.projectID)
            guard task.phase != .completed else { throw KanbanError.invalid("请先重新打开任务再切换开发目录。") }
            guard try db.rows("SELECT id FROM runs WHERE task_id = ? AND terminal = 0", [taskID]).isEmpty else { throw KanbanError.busy("请先结束或取消此任务的运行后再切换开发目录。") }
            guard try db.rows("SELECT task_id FROM stage_barriers WHERE task_id = ?", [taskID]).isEmpty else { throw KanbanError.busy("任务正在切换阶段，暂不能修改开发目录。") }
            guard try GitRepository.canonicalRoot(path: project.path) == project.path else { throw KanbanError.invalid("项目目录身份已变化，请重新导入正确的仓库。") }
            let worktree: String?
            if let path {
                let input = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
                let root = try GitRepository.canonicalRoot(path: path)
                guard input == root, try GitRepository.isWorktree(path: root, of: project.path) else { throw KanbanError.invalid("请选择此项目已登记的 Git Worktree 根目录。") }
                worktree = root
            } else { worktree = nil }
            guard task.worktreePath != worktree else { return }
            task.worktreePath = worktree; task.updatedAt = Date()
            try writeTask(task)
            // Identical HEAD/diffs in two directories must never make an old report look current.
            try invalidateReports(taskID: taskID)
        }
    }
    public func renameConversation(id: String, title: String) throws {
        var conversation = try conversation(id: id); _ = try activeProject(conversation.projectID)
        guard let title = title.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else { throw KanbanError.invalid("会话名称不能为空。") }
        conversation.title = title; try writeConversation(conversation)
    }
    /// Hide the conversation durably while preserving task-import provenance and its batch audit.
    public func deleteConversation(id: String) throws {
        try db.transaction {
            let conversation = try conversation(id: id); _ = try activeProject(conversation.projectID)
            guard conversation.kind == .projectChat else { throw KanbanError.invalid("只能删除项目普通会话，任务主会话不能单独删除。") }
            guard try db.rows("SELECT id FROM runs WHERE conversation_id = ? AND terminal = 0", [id]).isEmpty,
                  try db.rows("SELECT operation_key FROM import_jobs WHERE conversation_id = ?", [id]).isEmpty else {
                throw KanbanError.busy("会话仍有运行或任务导入，请先停止运行并等待导入结束后删除。")
            }
            try db.execute("INSERT INTO conversation_deletions(conversation_id,deleted_at) VALUES(?,?)", [id, String(Date().timeIntervalSince1970)])
        }
    }
    @discardableResult public func appendMessage(conversationID: String, role: MessageRole, content: String, runID: String? = nil, attachments: [Attachment] = [], id: String = UUID().uuidString) throws -> Message {
        let conversation = try conversation(id: conversationID); _ = try activeProject(conversation.projectID)
        if let runID { let run = try run(id: runID); guard run.conversationID == conversationID else { throw KanbanError.invalid("消息与运行归属不一致。") } }
        let message = Message(id: id, projectID: conversation.projectID, conversationID: conversationID, role: role, content: content, runID: runID, attachments: attachments)
        try db.execute("INSERT OR IGNORE INTO messages(id,project_id,conversation_id,payload) VALUES(?,?,?,?)", [message.id, message.projectID, conversationID, try encode(message)])
        return message
    }
    public func updateSelection(conversationID: String, selection: ExecutionSelection) throws {
        try db.transaction {
            var conversation = try conversation(id: conversationID); _ = try activeProject(conversation.projectID)
            conversation.savedSelections[conversation.selection.executor] = conversation.selection
            conversation.savedSelections[selection.executor] = selection
            conversation.selection = selection
            try writeConversation(conversation)
            if let taskID = conversation.taskID {
                var task = try task(id: taskID); task.selection = selection; task.updatedAt = Date(); try writeTask(task)
            }
        }
    }
    public func selection(conversationID: String, executor: ExecutorID) throws -> ExecutionSelection {
        let conversation = try conversation(id: conversationID)
        return conversation.savedSelections[executor] ?? (conversation.selection.executor == executor ? conversation.selection : .init(executor: executor))
    }

    /// Persist an authorized request; reserve immediately when its directory is available.
    @discardableResult public func prepareRun(conversationID: String, prompt: String, directImplementation: Bool = false, includeFullHistory: Bool = false, acceptanceReview: Bool = false) throws -> RunRecord {
        try db.transaction {
            try prepareRunInTransaction(conversationID: conversationID, prompt: prompt, directImplementation: directImplementation, includeFullHistory: includeFullHistory, acceptanceReview: acceptanceReview)
        }
    }
    /// Call only from a transaction so phase changes and the directory reservation commit together.
    private func prepareRunInTransaction(conversationID: String, prompt: String, directImplementation: Bool = false, includeFullHistory: Bool = false, acceptanceReview: Bool = false) throws -> RunRecord {
        let conversation = try conversation(id: conversationID); let project = try activeProject(conversation.projectID)
        guard try GitRepository.canonicalRoot(path: project.path) == project.path else {
            throw KanbanError.invalid("项目目录身份已变化，请重新导入正确的仓库后运行。")
        }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw KanbanError.invalid("请输入内容。") }
        guard try db.rows("SELECT id FROM runs WHERE conversation_id = ? AND terminal = 0", [conversationID]).isEmpty else { throw KanbanError.busy("此会话已有运行，请等待或先停止。") }
        var task = try conversation.taskID.map { try self.task(id: $0) }
        if directImplementation {
            guard let task, conversation.kind == .taskMain, task.mainConversationID == conversationID,
                  task.projectID == project.id, task.phase == .backlog else {
                throw KanbanError.invalid("直接开发仅适用于待处理任务的主会话。")
            }
        }
        if var currentTask = task {
            guard currentTask.projectID == project.id, currentTask.mainConversationID == conversationID,
                  conversation.kind == .taskMain else { throw KanbanError.invalid("任务主会话归属已变化，请重新打开任务。") }
            guard try db.rows("SELECT task_id FROM stage_barriers WHERE task_id = ?", [currentTask.id]).isEmpty else { throw KanbanError.busy("任务正在停止并切换阶段，暂不接受新运行。") }
            if directImplementation {
                currentTask.phase = .development; currentTask.phaseVersion += 1
                currentTask.directImplementationPhaseVersion = currentTask.phaseVersion
                currentTask.updatedAt = Date()
            }
            guard currentTask.phase.allowsExecution else { throw KanbanError.invalid("待处理仅保存备注，完成任务不能启动；请先进入讨论或开发阶段。") }
            if currentTask.phase == .development, currentTask.directImplementationPhaseVersion != currentTask.phaseVersion {
                guard try hasConfirmedPlan(currentTask) else { throw KanbanError.invalid("开发前请先确认当前需求与方案版本。") }
            }
            if currentTask.phase == .acceptance {
                guard try hasConfirmedPlan(currentTask) else { throw KanbanError.invalid("验收前请先确认当前方案与验收条件。") }
            }
            task = currentTask
        }
        let writing = task?.phase.allowsWriting ?? true
        if acceptanceReview { guard task?.phase == .acceptance, !writing else { throw KanbanError.invalid("独立验收只能在验收阶段只读执行。") } }
        let cwd = try executionDirectory(project: project, task: task)
        let outstanding: [RunRecord] = try query("runs", where: "terminal = 0", values: [])
        let earlierQueued = outstanding.contains { $0.cwd == cwd && $0.status == .queued }
        let queued = try earlierQueued || directoryOccupied(cwd: cwd, writing: writing, outstanding: outstanding)
        let record = RunRecord(projectID: project.id, conversationID: conversationID, taskID: task?.id, selection: task?.selection ?? conversation.selection, cwd: cwd, phase: task?.phase, phaseVersion: task?.phaseVersion, revisionID: task?.currentRevisionID, prompt: prompt, writing: writing, status: queued ? .queued : .starting, includeFullHistory: includeFullHistory || directImplementation, acceptanceReview: acceptanceReview)
        if directImplementation, let task { try writeTask(task) }
        try writeRun(record)
        if writing && !queued { try db.execute("INSERT INTO directory_leases(path,run_id) VALUES(?,?)", [cwd, record.id]) }
        if queued { try recordEvent(runID: record.id, kind: "run.queued", content: "开发目录正在使用，已加入等待队列；目录可用后自动开始。") }
        if directImplementation {
            try appendMessage(conversationID: conversationID, role: .user, content: "直接开发：跳过讨论，按当前任务说明、备注和附件开始开发。", runID: record.id, attachments: task?.attachments ?? [], id: "direct-implementation-\(record.id)")
        }
        return record
    }
    /// SQLite serializes claims across Repository instances. FIFO applies to each physical cwd.
    /// A blocked directory never holds up independent worktrees or projects.
    @discardableResult public func claimNextQueuedRun() throws -> RunRecord? {
        try db.transaction {
            let outstanding: [RunRecord] = try query("runs", where: "terminal = 0 ORDER BY rowid", values: [])
            var blockedDirectories = Set<String>()
            for var candidate in outstanding where candidate.status == .queued {
                guard !blockedDirectories.contains(candidate.cwd) else { continue }
                guard try isUnstartedQueue(candidate) else { blockedDirectories.insert(candidate.cwd); continue }
                do { try validateQueuedIntent(candidate) }
                catch let error as KanbanError {
                    if case .database = error { throw error }
                    try cancelQueuedIntent(candidate, reason: error.localizedDescription)
                    continue
                } catch {
                    try cancelQueuedIntent(candidate, reason: error.localizedDescription)
                    continue
                }
                if try directoryOccupied(cwd: candidate.cwd, writing: candidate.writing, outstanding: outstanding) {
                    blockedDirectories.insert(candidate.cwd)
                    continue
                }
                candidate.status = .starting; try writeRun(candidate)
                if candidate.writing { try db.execute("INSERT INTO directory_leases(path,run_id) VALUES(?,?)", [candidate.cwd, candidate.id]) }
                try recordEvent(runID: candidate.id, kind: "run.dequeued", content: "开发目录已可用，正在启动排队中的运行。")
                return candidate
            }
            return nil
        }
    }
    /// An app shutdown may pause after claiming but before launching a process.
    /// Retain the original rowid/FIFO position and explicit user intent in that case.
    public func returnUnstartedRunToQueue(id: String) throws {
        try db.transaction {
            var run = try run(id: id)
            guard run.status == .starting, run.processID == nil, run.processStartedAt == nil,
                  run.executorSessionID == nil, run.output.isEmpty else { throw KanbanError.invalid("执行器已经启动或状态已变化，不能退回等待队列。") }
            try db.execute("DELETE FROM directory_leases WHERE run_id = ?", [id])
            run.status = .queued; try writeRun(run)
            try recordEvent(runID: id, kind: "run.queued", content: "启动已暂停，保留原等待顺序。")
        }
    }
    public func markRunStarted(id: String, sessionID: String? = nil, processID: Int32? = nil, processStartedAt: Date? = nil, effectiveModelID: String? = nil, effectivePolicy: String? = nil) throws {
        try db.transaction {
            var run = try run(id: id)
            guard run.status == .starting else { throw KanbanError.invalid("运行尚未领取或状态已变化，不能标记启动。") }
            run.status = .running; run.executorSessionID = sessionID; run.processID = processID; run.processStartedAt = processStartedAt; run.effectiveModelID = effectiveModelID; run.effectivePolicy = effectivePolicy
            try writeRun(run)
        }
    }
    public func updateRunMetadata(id: String, sessionID: String? = nil, processID: Int32? = nil, processStartedAt: Date? = nil, effectiveModelID: String? = nil, effectivePolicy: String? = nil) throws {
        var run = try run(id: id)
        guard run.status != .queued else { throw KanbanError.invalid("排队中的运行必须先领取，才能启动执行器。") }
        if let sessionID { run.executorSessionID = sessionID }; if let processID { run.processID = processID }; if let processStartedAt { run.processStartedAt = processStartedAt }
        if let effectiveModelID { run.effectiveModelID = effectiveModelID }; if let effectivePolicy { run.effectivePolicy = effectivePolicy }
        try writeRun(run)
    }
    public func appendRunOutput(id: String, text: String) throws {
        var run = try run(id: id)
        guard !run.status.isTerminal, run.status != .queued, run.status != .cancelling, run.status != .recoveryRequired else { return }
        run.output += text; try writeRun(run)
    }
    @discardableResult public func recordEvent(runID: String, kind: String, content: String, eventID: String = UUID().uuidString) throws -> RunEvent {
        let run = try run(id: runID)
        let event = RunEvent(id: eventID, projectID: run.projectID, runID: runID, kind: kind, content: content)
        try db.execute("INSERT OR IGNORE INTO events(id,project_id,run_id,payload) VALUES(?,?,?,?)", [event.id, event.projectID, runID, try encode(event)])
        return event
    }
    public func requestStop(id: String, reason: String = "用户停止") throws {
        try db.transaction {
            var run = try run(id: id); guard !run.status.isTerminal else { return }
            if try isUnstartedQueue(run) {
                try cancelQueuedIntent(run, reason: reason)
            } else {
                run.status = .cancelling; run.error = reason; try writeRun(run)
            }
            let approvals: [Approval] = try query("approvals", where: "run_id = ?", values: [id])
            for var approval in approvals where approval.status == .pending { approval.status = .expired; try writeApproval(approval) }
        }
    }
    /// stopConfirmed must mean main/child/tool completion was established by the supervisor.
    public func finishRun(id: String, status: RunStatus, output: String? = nil, error: String? = nil, stopConfirmed: Bool) throws {
        try db.transaction {
            var run = try run(id: id)
            guard !run.status.isTerminal else { return }
            guard status.isTerminal else { throw KanbanError.invalid("需要明确的运行终态。") }
            if let output { run.output = output }; run.error = error
            if stopConfirmed {
                run.status = status; run.endedAt = Date(); try writeRun(run)
                try db.execute("DELETE FROM directory_leases WHERE run_id = ?", [id])
            } else { run.status = .recoveryRequired; run.error = error ?? "无法确认执行器及工具已经停止。"; try writeRun(run) }
            let approvals: [Approval] = try query("approvals", where: "run_id = ?", values: [id])
            for var approval in approvals where approval.status == .pending { approval.status = .expired; try writeApproval(approval) }
        }
    }
    /// Queues with no executor/process/lease remain authorized. Started work requires recovery.
    public func markInterruptedRunsForRecovery() throws {
        try db.transaction {
            let runs: [RunRecord] = try query("runs", where: "terminal = 0", values: [])
            for var run in runs where try !isUnstartedQueue(run) { run.status = .recoveryRequired; run.error = "应用重启，需要核对旧执行器与工具是否已停止。"; try writeRun(run) }
        }
    }
    @discardableResult public func saveApproval(_ approval: Approval) throws -> Approval {
        try db.transaction {
            var run = try run(id: approval.runID)
            guard run.projectID == approval.projectID, run.phaseVersion == approval.phaseVersion else { throw KanbanError.invalid("审批与原运行归属不一致。") }
            guard !run.status.isTerminal && run.status != .queued && run.status != .cancelling && run.status != .recoveryRequired else { throw KanbanError.invalid("原运行尚未启动、已结束或正在停止，审批失效。") }
            if let existing = try (query("approvals", where: "run_id = ? AND request_id = ?", values: [approval.runID, approval.requestID]) as [Approval]).first { return existing }
            try writeApproval(approval); run.status = .waitingApproval; try writeRun(run); return approval
        }
    }
    @discardableResult public func decideApproval(id: String, optionID: String) throws -> Approval {
        try db.transaction {
            var approval: Approval = try required("approvals", id: id, name: "审批")
            var run = try run(id: approval.runID)
            guard approval.status == .pending, run.status == .waitingApproval, run.phaseVersion == approval.phaseVersion, approval.options.contains(where: { $0.id == optionID }) else { throw KanbanError.invalid("审批已失效或选项不属于原请求。") }
            if let taskID = run.taskID { let task = try task(id: taskID); guard task.phaseVersion == approval.phaseVersion else { throw KanbanError.invalid("任务阶段已改变，旧审批不能继续。") } }
            approval.status = .decided; approval.decision = optionID; try writeApproval(approval)
            let otherApprovals: [Approval] = try query("approvals", where: "run_id = ?", values: [run.id])
            run.status = otherApprovals.contains(where: { $0.status == .pending }) ? .waitingApproval : .running
            try writeRun(run); return approval
        }
    }
    public func markApprovalUncertain(id: String) throws {
        try db.transaction {
            var approval: Approval = try required("approvals", id: id, name: "审批"); approval.status = .uncertain; try writeApproval(approval)
            var run = try run(id: approval.runID)
            if !run.status.isTerminal { run.status = .recoveryRequired; run.error = "审批答复的投递结果未知，需要核对，不能自动重发。"; try writeRun(run) }
        }
    }

    public func transitionTask(id: String, to phase: TaskPhase) throws {
        if phase == .completed { try completeTask(id: id); return }
        try db.transaction {
            var task = try task(id: id); _ = try activeProject(task.projectID)
            guard task.phase != phase else { return }
            guard try db.rows("SELECT id FROM runs WHERE task_id = ? AND terminal = 0", [id]).isEmpty else { throw KanbanError.stopRequired("请先停止当前运行；主运行与工具停止确认后才能切换阶段。") }
            if phase == .development {
                guard try hasConfirmedPlan(task) else { throw KanbanError.invalid("请先确认当前方案版本，再进入开发。") }
            }
            if phase == .acceptance {
                guard try hasConfirmedPlan(task) else { throw KanbanError.invalid("请先确认当前方案与验收条件，再进入验收。") }
            }
            task.phase = phase; task.phaseVersion += 1; task.directImplementationPhaseVersion = nil; task.updatedAt = Date(); try writeTask(task)
            try db.execute("DELETE FROM stage_barriers WHERE task_id = ?", [id])
        }
    }
    public func beginStageChange(taskID: String) throws {
        let task = try task(id: taskID); _ = try activeProject(task.projectID)
        guard try db.rows("SELECT task_id FROM stage_barriers WHERE task_id = ?", [taskID]).isEmpty else { throw KanbanError.busy("任务已经在切换阶段。") }
        try db.execute("INSERT INTO stage_barriers(task_id,project_id) VALUES(?,?)", [taskID, task.projectID])
    }
    public func abandonStageChange(taskID: String) throws { try db.execute("DELETE FROM stage_barriers WHERE task_id = ?", [taskID]) }
    /// A crashed idle phase-change kept the previous phase; with no old run there is nothing to stop.
    public func reconcileIdleStageBarriers() throws {
        try db.execute("DELETE FROM stage_barriers WHERE task_id NOT IN (SELECT task_id FROM runs WHERE terminal = 0 AND task_id IS NOT NULL)")
    }
    @discardableResult public func saveRevision(taskID: String, requirement: String, plan: String, acceptanceCriteria: [String], sourceMessageID: String? = nil, sourceRunID: String? = nil) throws -> RequirementRevision {
        try db.transaction {
            var task = try task(id: taskID); _ = try activeProject(task.projectID)
            guard task.phase != .completed else { throw KanbanError.invalid("请先重新打开任务再修改方案。") }
            guard try db.rows("SELECT id FROM runs WHERE task_id = ? AND terminal = 0", [taskID]).isEmpty else { throw KanbanError.stopRequired("请先停止任务运行再修改需求与方案版本。") }
            guard (sourceMessageID == nil) == (sourceRunID == nil) else { throw KanbanError.invalid("方案来源消息与运行必须同时提供。") }
            if let sourceMessageID, let sourceRunID {
                let message: Message = try required("messages", id: sourceMessageID, name: "方案来源消息")
                let sourceRun = try run(id: sourceRunID)
                let conversation = try conversation(id: task.mainConversationID)
                guard conversation.kind == .taskMain, conversation.taskID == task.id, conversation.projectID == task.projectID,
                      message.id == "reply-\(sourceRunID)", message.role == .assistant, message.runID == sourceRunID,
                      message.projectID == task.projectID, message.conversationID == task.mainConversationID,
                      !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      sourceRun.projectID == task.projectID, sourceRun.taskID == task.id,
                      sourceRun.conversationID == task.mainConversationID, sourceRun.parentRunID == nil,
                      sourceRun.status == .succeeded, sourceRun.phase == .discussion,
                      let phaseVersion = sourceRun.phaseVersion, phaseVersion >= 0 else {
                    throw KanbanError.invalid("方案来源必须是此任务主会话中已成功完成的讨论回复。")
                }
            }
            let revisions: [RequirementRevision] = try query("revisions", where: "task_id = ?", values: [taskID])
            let revision = RequirementRevision(projectID: task.projectID, taskID: taskID, version: (revisions.map(\.version).max() ?? 0) + 1, requirement: requirement, plan: plan, acceptanceCriteria: acceptanceCriteria.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }, sourceMessageID: sourceMessageID, sourceRunID: sourceRunID)
            try db.execute("INSERT INTO revisions(id,project_id,task_id,payload) VALUES(?,?,?,?)", [revision.id, task.projectID, taskID, try encode(revision)])
            task.currentRevisionID = revision.id; task.directImplementationPhaseVersion = nil; task.updatedAt = Date(); try writeTask(task); try invalidateReports(taskID: taskID); return revision
        }
    }
    public func confirmRevision(id: String) throws {
        var revision: RequirementRevision = try required("revisions", id: id, name: "方案版本")
        let task = try task(id: revision.taskID); _ = try activeProject(task.projectID)
        guard task.currentRevisionID == id else { throw KanbanError.invalid("只能确认当前方案版本。") }
        guard !revision.plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !revision.acceptanceCriteria.isEmpty else { throw KanbanError.invalid("请补充方案与验收项后确认。") }
        revision.confirmedAt = Date()
        try db.execute("UPDATE revisions SET payload = ? WHERE id = ?", [try encode(revision), id])
    }
    /// The explicit human confirmation also authorizes the first development run for this version.
    @discardableResult public func confirmRevisionAndPrepareDevelopmentRun(id: String, prompt: String) throws -> RunRecord {
        try db.transaction {
            let revision: RequirementRevision = try required("revisions", id: id, name: "方案版本")
            var task = try task(id: revision.taskID); _ = try activeProject(task.projectID)
            guard task.currentRevisionID == id, revision.projectID == task.projectID else { throw KanbanError.invalid("只能确认当前方案版本。") }
            guard revision.confirmedAt == nil else { throw KanbanError.invalid("当前方案已确认，请在主会话中继续开发。") }
            guard task.phase != .completed else { throw KanbanError.invalid("请先重新打开任务再确认方案并开发。") }
            guard try db.rows("SELECT task_id FROM stage_barriers WHERE task_id = ?", [task.id]).isEmpty else { throw KanbanError.busy("任务正在停止并切换阶段，暂不接受确认开发。") }
            guard try db.rows("SELECT id FROM runs WHERE task_id = ? AND terminal = 0", [task.id]).isEmpty else { throw KanbanError.stopRequired("请先停止任务运行并核实工具结束，再确认方案开始开发。") }
            let main = try conversation(id: task.mainConversationID)
            guard main.kind == .taskMain, main.taskID == task.id, main.projectID == task.projectID else { throw KanbanError.invalid("任务主会话归属已变化，请重新打开任务。") }

            try confirmRevision(id: id)
            if task.phase != .development { task.phase = .development; task.phaseVersion += 1 }
            task.directImplementationPhaseVersion = nil
            task.updatedAt = Date(); try writeTask(task)
            let run = try prepareRunInTransaction(conversationID: task.mainConversationID, prompt: prompt, includeFullHistory: true)
            try appendMessage(conversationID: task.mainConversationID, role: .user,
                              content: "确认方案并开始开发：已确认方案 v\(revision.version)，按当前方案、任务说明、备注和附件立即实施并验证结果。",
                              runID: run.id, id: "plan-confirmation-\(run.id)")
            return run
        }
    }
    public func saveAcceptance(_ report: AcceptanceReport, sourceRunID: String? = nil) throws {
        try db.transaction {
            let task = try task(id: report.taskID); _ = try activeProject(task.projectID)
            guard task.phase == .acceptance, task.projectID == report.projectID, task.currentRevisionID == report.revisionID else { throw KanbanError.invalid("验收报告与当前任务版本不一致。") }
            guard try hasConfirmedPlan(task) else { throw KanbanError.invalid("验收前请先确认当前方案与验收条件。") }
            var report = report
            if let sourceRunID = sourceRunID ?? report.sourceRunID {
                let run = try run(id: sourceRunID)
                guard run.taskID == task.id, run.projectID == task.projectID, run.revisionID == report.revisionID,
                      run.phase == .acceptance, run.phaseVersion == task.phaseVersion, !run.writing,
                      !run.status.isTerminal, run.status != .queued, run.status != .cancelling, run.status != .recoveryRequired else {
                    throw KanbanError.invalid("原验收运行已停止、阶段变化或身份不匹配，未保存验收报告。")
                }
                report.sourceRunID = sourceRunID
            }
            try db.execute("INSERT INTO reports(id,project_id,task_id,payload) VALUES(?,?,?,?)", [report.id, report.projectID, report.taskID, try encode(report)])
        }
    }
    public func invalidateAcceptance(taskID: String) throws { try invalidateReports(taskID: taskID) }
    /// Watchers invalidate only the report they examined. A newer matching report must survive.
    public func invalidateAcceptanceReport(id: String, currentFingerprint: String) throws {
        try db.transaction {
            var report: AcceptanceReport = try required("reports", id: id, name: "验收报告")
            guard !report.stale, report.codeFingerprint != currentFingerprint else { return }
            report.stale = true; try writeReport(report)
        }
    }
    /// An explicit human stage decision. Reports remain optional reference material.
    public func completeTask(id: String) throws {
        try db.transaction {
            var task = try task(id: id); let project = try activeProject(task.projectID)
            guard task.phase != .completed else { return }
            guard try db.rows("SELECT task_id FROM stage_barriers WHERE task_id = ?", [id]).isEmpty else { throw KanbanError.busy("任务正在切换阶段，请等待完成后再确认完成。") }
            let outstanding: [RunRecord] = try query("runs", where: "terminal = 0", values: [])
            let cwd = task.worktreePath ?? project.path
            guard !outstanding.contains(where: { $0.taskID == task.id || $0.cwd == cwd }) else { throw KanbanError.stopRequired("请等待此开发目录的运行与工具停止后再确认完成。") }
            task.phase = .completed; task.phaseVersion += 1; task.directImplementationPhaseVersion = nil
            task.updatedAt = Date(); try writeTask(task)
        }
    }

    public func beginImport(conversationID: String, operationKey: String) throws {
        let conversation = try conversation(id: conversationID); _ = try activeProject(conversation.projectID)
        guard conversation.kind == .projectChat else { throw KanbanError.invalid("任务清单导入需要从项目普通会话发起。") }
        if let job = try db.rows("SELECT project_id,conversation_id FROM import_jobs WHERE operation_key = ?", [operationKey]).first {
            guard job == [conversation.projectID, conversationID] else { throw KanbanError.invalid("导入操作归属不一致。") }; return
        }
        try db.execute("INSERT INTO import_jobs(operation_key,project_id,conversation_id) VALUES(?,?,?)", [operationKey, conversation.projectID, conversationID])
    }
    public func endImport(operationKey: String) throws { try db.execute("DELETE FROM import_jobs WHERE operation_key = ?", [operationKey]) }
    @discardableResult public func commitImportBatch(conversationID: String, requestMessageID: String, operationKey: String, candidates: [ImportCandidate], errors: [String] = [], sourceRange: String = "附件与链接") throws -> ImportBatch {
        try db.transaction {
            let conversation = try conversation(id: conversationID); let project = try activeProject(conversation.projectID)
            guard conversation.kind == .projectChat else { throw KanbanError.invalid("仅项目普通会话可导入任务。") }
            if let existing = try (query("import_batches", where: "operation_key = ?", values: [operationKey]) as [ImportBatch]).first {
                guard existing.conversationID == conversationID else { throw KanbanError.invalid("导入操作归属不一致。") }
                try db.execute("DELETE FROM import_jobs WHERE operation_key = ?", [operationKey]); return existing
            }
            guard try db.rows("SELECT operation_key FROM import_jobs WHERE operation_key = ? AND conversation_id = ?", [operationKey, conversationID]).count == 1 else { throw KanbanError.invalid("导入已取消或尚未登记。") }
            let batchID = UUID().uuidString
            var created: [String] = []; var duplicates = 0; var seen = Set<String>(); var rowErrors = errors
            for candidate in candidates {
                guard !candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !candidate.sourceKey.isEmpty else { rowErrors.append("\(candidate.sourceDescription)：标题或稳定来源标识缺失。"); continue }
                guard seen.insert(candidate.sourceKey).inserted, try db.rows("SELECT id FROM provenance WHERE project_id = ? AND source_key = ?", [project.id, candidate.sourceKey]).isEmpty else { duplicates += 1; continue }
                let task = try insertTask(project: project, title: candidate.title, description: candidate.description, type: candidate.type, priority: candidate.priority)
                let source = Provenance(projectID: project.id, batchID: batchID, taskID: task.id, sourceKey: candidate.sourceKey, sourceURL: candidate.sourceURL, sourceDescription: candidate.sourceDescription)
                try db.execute("INSERT INTO provenance(id,project_id,task_id,source_key,payload) VALUES(?,?,?,?,?)", [source.id, project.id, task.id, source.sourceKey, try encode(source)])
                created.append(task.id)
            }
            let batch = ImportBatch(id: batchID, projectID: project.id, conversationID: conversationID, requestMessageID: requestMessageID, operationKey: operationKey, sourceRange: sourceRange, createdTaskIDs: created, duplicateCount: duplicates, errors: rowErrors)
            try db.execute("INSERT INTO import_batches(id,project_id,conversation_id,operation_key,payload) VALUES(?,?,?,?,?)", [batch.id, project.id, conversationID, operationKey, try encode(batch)])
            try db.execute("DELETE FROM import_jobs WHERE operation_key = ?", [operationKey]); return batch
        }
    }
    @discardableResult public func importCandidates(conversationID: String, batchKey: String, candidates: [ImportCandidate], errors: [String] = [], sourceRange: String = "附件与链接", requestMessageID: String = "") throws -> ImportBatch {
        try beginImport(conversationID: conversationID, operationKey: batchKey)
        do { return try commitImportBatch(conversationID: conversationID, requestMessageID: requestMessageID, operationKey: batchKey, candidates: candidates, errors: errors, sourceRange: sourceRange) }
        catch { try? endImport(operationKey: batchKey); throw error }
    }
    public func clearInterruptedImportJobs() throws {
        // Sources are re-read only after a new explicit request. No tasks were written before commit.
        try db.execute("DELETE FROM import_jobs")
    }

    private func activeProject(_ id: String) throws -> Project {
        let project: Project = try required("projects", id: id, name: "项目")
        guard project.isActive else { throw KanbanError.invalid("项目已移除。") }; return project
    }
    private func executionDirectory(project: Project, task: TaskItem?) throws -> String {
        guard try GitRepository.canonicalRoot(path: project.path) == project.path else { throw KanbanError.invalid("项目目录身份已变化，请重新导入正确的仓库后运行。") }
        guard let worktree = task?.worktreePath else { return project.path }
        guard try GitRepository.canonicalRoot(path: worktree) == worktree,
              try GitRepository.isWorktree(path: worktree, of: project.path) else { throw KanbanError.invalid("任务的 Git Worktree 已移动、移除或不再属于此项目，请重新选择开发目录。") }
        return worktree
    }
    private func isUnstartedQueue(_ run: RunRecord) throws -> Bool {
        guard run.status == .queued, run.processID == nil, run.processStartedAt == nil,
              run.executorSessionID == nil, run.effectiveModelID == nil, run.effectivePolicy == nil,
              run.output.isEmpty, run.endedAt == nil else { return false }
        return try db.rows("SELECT run_id FROM directory_leases WHERE run_id = ?", [run.id]).isEmpty
            && db.rows("SELECT id FROM approvals WHERE run_id = ?", [run.id]).isEmpty
    }
    private func directoryOccupied(cwd: String, writing: Bool, outstanding: [RunRecord]) throws -> Bool {
        if try !db.rows("SELECT run_id FROM directory_leases WHERE path = ?", [cwd]).isEmpty { return true }
        for run in outstanding where run.cwd == cwd && !run.status.isTerminal {
            if try isUnstartedQueue(run) { continue }
            if writing || run.writing { return true }
        }
        return false
    }
    private func validateQueuedIntent(_ run: RunRecord) throws {
        let project = try activeProject(run.projectID)
        let conversation = try conversation(id: run.conversationID)
        guard run.parentRunID == nil, conversation.projectID == project.id,
              conversation.taskID == run.taskID, !run.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw KanbanError.invalid("等待中的运行归属或指令已失效。") }
        var task: TaskItem?
        if let taskID = run.taskID {
            let current = try self.task(id: taskID)
            guard current.projectID == project.id, current.mainConversationID == conversation.id,
                  conversation.kind == .taskMain, current.phase.allowsExecution,
                  current.phase == run.phase, current.phaseVersion == run.phaseVersion,
                  current.currentRevisionID == run.revisionID,
                  current.phase.allowsWriting == run.writing else { throw KanbanError.invalid("任务阶段或方案版本已变化，已取消旧的等待请求。") }
            guard try db.rows("SELECT task_id FROM stage_barriers WHERE task_id = ?", [taskID]).isEmpty else { throw KanbanError.invalid("任务正在切换阶段，已取消旧的等待请求。") }
            if current.phase == .development, current.directImplementationPhaseVersion != current.phaseVersion {
                guard try hasConfirmedPlan(current) else { throw KanbanError.invalid("当前开发方案未确认，已取消旧的等待请求。") }
            }
            if current.phase == .acceptance { guard try hasConfirmedPlan(current) else { throw KanbanError.invalid("当前验收方案未确认，已取消旧的等待请求。") } }
            task = current
        } else {
            guard conversation.kind == .projectChat, run.phase == nil, run.phaseVersion == nil,
                  run.revisionID == nil, run.writing else { throw KanbanError.invalid("等待中的会话类型已变化。") }
        }
        guard try executionDirectory(project: project, task: task) == run.cwd else { throw KanbanError.invalid("开发目录已变化，已取消旧的等待请求。") }
        if run.acceptanceReview == true {
            guard run.phase == .acceptance, !run.writing else { throw KanbanError.invalid("验收运行意图与当前任务阶段不一致。") }
        }
    }
    private func cancelQueuedIntent(_ run: RunRecord, reason: String) throws {
        var run = run; run.status = .cancelled; run.error = reason; run.endedAt = Date()
        try writeRun(run)
        try recordEvent(runID: run.id, kind: "run.queue_cancelled", content: reason)
    }
    private func hasConfirmedPlan(_ task: TaskItem) throws -> Bool {
        guard let revisionID = task.currentRevisionID,
              let revision = try (query("revisions", where: "id = ?", values: [revisionID]) as [RequirementRevision]).first,
              revision.projectID == task.projectID, revision.taskID == task.id, revision.confirmedAt != nil,
              !revision.plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !revision.acceptanceCriteria.isEmpty,
              revision.acceptanceCriteria.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return false }
        return true
    }
    private func insertTask(project: Project, title: String, description: String, type: TaskType, priority: TaskPriority, attachments: [Attachment] = []) throws -> TaskItem {
        guard let title = title.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else { throw KanbanError.invalid("任务标题不能为空。") }
        let number = (Int(try db.rows("SELECT COALESCE(MAX(number),0) FROM tasks WHERE project_id = ?", [project.id]).first?.first ?? "0") ?? 0) + 1
        let task = TaskItem(projectID: project.id, number: number, title: title, description: description, type: type, priority: priority, selection: .init(executor: project.defaultExecutor), attachments: attachments)
        try writeTask(task)
        try writeConversation(.init(id: task.mainConversationID, projectID: project.id, kind: .taskMain, taskID: task.id, title: task.title, selection: task.selection))
        return task
    }
    private func writeProject(_ project: Project) throws { try db.execute("INSERT INTO projects(id,path,active,payload) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET active=excluded.active,payload=excluded.payload", [project.id, project.path, project.isActive ? "1" : "0", try encode(project)]) }
    private func writeTask(_ task: TaskItem) throws { try db.execute("INSERT INTO tasks(id,project_id,number,conversation_id,payload) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", [task.id, task.projectID, String(task.number), task.mainConversationID, try encode(task)]) }
    private func writeConversation(_ conversation: Conversation) throws { try db.execute("INSERT INTO conversations(id,project_id,task_id,kind,payload) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", [conversation.id, conversation.projectID, conversation.taskID, conversation.kind.rawValue, try encode(conversation)]) }
    private func writeRun(_ run: RunRecord) throws { try db.execute("INSERT INTO runs(id,project_id,conversation_id,task_id,terminal,payload) VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET terminal=excluded.terminal,payload=excluded.payload", [run.id, run.projectID, run.conversationID, run.taskID, run.status.isTerminal ? "1" : "0", try encode(run)]) }
    private func writeApproval(_ approval: Approval) throws { try db.execute("INSERT INTO approvals(id,project_id,run_id,request_id,payload) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", [approval.id, approval.projectID, approval.runID, approval.requestID, try encode(approval)]) }
    private func writeReport(_ report: AcceptanceReport) throws { try db.execute("UPDATE reports SET payload = ? WHERE id = ?", [try encode(report), report.id]) }
    private func invalidateReports(taskID: String) throws {
        let reports: [AcceptanceReport] = try query("reports", where: "task_id = ?", values: [taskID])
        for var report in reports { report.stale = true; try writeReport(report) }
    }
    private func encode<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
    private func all<T: Decodable>(_ table: String) throws -> [T] { try query(table, where: "1", values: []) }
    private func query<T: Decodable>(_ table: String, where predicate: String, values: [String?]) throws -> [T] { try db.rows("SELECT payload FROM \(table) WHERE \(predicate)", values).map { try decoder.decode(T.self, from: Data($0[0].utf8)) } }
    private func required<T: Decodable>(_ table: String, id: String, name: String) throws -> T {
        guard let value = try (query(table, where: "id = ?", values: [id]) as [T]).first else { throw KanbanError.notFound(name) }; return value
    }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }
