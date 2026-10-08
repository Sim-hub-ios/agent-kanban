import Foundation

public enum ExecutorID: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, claude, cursor
    public var id: String { rawValue }
    public var title: String { switch self { case .codex: "Codex"; case .claude: "Claude"; case .cursor: "Cursor" } }
}

public enum PermissionPreset: String, Codable, CaseIterable, Sendable, Identifiable {
    case requestApproval, autoReview, fullAccess
    public var id: String { rawValue }
    public var title: String { switch self { case .requestApproval: "请求批准"; case .autoReview: "帮我批准"; case .fullAccess: "完全访问权限" } }
}

/// Overrides for the *next* request. nil is the executor's native default, never the first catalog entry.
public struct ExecutionSelection: Codable, Hashable, Sendable {
    public var executor: ExecutorID
    public var modelID: String?
    public var effort: String?
    public var permission: PermissionPreset?
    public init(executor: ExecutorID = .codex, modelID: String? = nil, effort: String? = nil, permission: PermissionPreset? = nil) {
        self.executor = executor; self.modelID = modelID; self.effort = effort; self.permission = permission
    }
}

public struct Project: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public let path: String
    public var defaultExecutor: ExecutorID
    public let createdAt: Date
    public var removedAt: Date?
    public var isActive: Bool { removedAt == nil }
    public init(id: String = UUID().uuidString, name: String, path: String, defaultExecutor: ExecutorID = .codex, createdAt: Date = Date(), removedAt: Date? = nil) {
        self.id = id; self.name = name; self.path = path; self.defaultExecutor = defaultExecutor; self.createdAt = createdAt; self.removedAt = removedAt
    }
}

public enum TaskPhase: String, Codable, CaseIterable, Identifiable, Sendable {
    case backlog, discussion, development, acceptance, completed
    public var id: String { rawValue }
    public var title: String { switch self { case .backlog: "待处理"; case .discussion: "讨论"; case .development: "开发"; case .acceptance: "验收"; case .completed: "完成" } }
    public var allowsExecution: Bool { self != .backlog && self != .completed }
    public var allowsWriting: Bool { self == .development }
}
public enum TaskType: String, Codable, CaseIterable, Identifiable, Sendable {
    case feature, bug, improvement, chore
    public var id: String { rawValue }
    public var title: String { switch self { case .feature: "新功能"; case .bug: "问题修复"; case .improvement: "体验优化"; case .chore: "其他任务" } }
}
public enum TaskPriority: String, Codable, CaseIterable, Identifiable, Sendable {
    case low, normal, high, urgent
    public var id: String { rawValue }
    public var title: String { switch self { case .low: "低"; case .normal: "普通"; case .high: "高"; case .urgent: "紧急" } }
}
public struct TaskItem: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let projectID: String
    public let number: Int
    public var title: String
    public var description: String
    /// Optional so workspaces created before task attachments remain decodable.
    public var attachments: [Attachment]?
    public var type: TaskType
    public var priority: TaskPriority
    public var phase: TaskPhase
    public var phaseVersion: Int
    /// Explicit direct implementation authorization, limited to one development phase.
    /// Optional so older task payloads keep requiring a confirmed plan.
    public var directImplementationPhaseVersion: Int?
    /// nil uses the imported project directory. Linked worktrees are task scoped.
    public var worktreePath: String?
    public let mainConversationID: String
    public var currentRevisionID: String?
    public var selection: ExecutionSelection
    public let createdAt: Date
    public var updatedAt: Date
    public var displayID: String { "AK-\(String(format: "%03d", number))" }
    public init(id: String = UUID().uuidString, projectID: String, number: Int, title: String, description: String = "", type: TaskType = .feature, priority: TaskPriority = .normal, phase: TaskPhase = .backlog, phaseVersion: Int = 0, mainConversationID: String = UUID().uuidString, currentRevisionID: String? = nil, selection: ExecutionSelection = .init(), createdAt: Date = Date(), updatedAt: Date = Date(), attachments: [Attachment] = [], directImplementationPhaseVersion: Int? = nil, worktreePath: String? = nil) {
        self.id = id; self.projectID = projectID; self.number = number; self.title = title; self.description = description; self.attachments = attachments; self.type = type; self.priority = priority; self.phase = phase; self.phaseVersion = phaseVersion; self.directImplementationPhaseVersion = directImplementationPhaseVersion; self.mainConversationID = mainConversationID; self.currentRevisionID = currentRevisionID; self.selection = selection; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.worktreePath = worktreePath
    }
}
public enum ConversationKind: String, Codable, Sendable { case projectChat, taskMain, agentChild }
public struct Conversation: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let projectID: String
    public let kind: ConversationKind
    public let taskID: String?
    public var title: String
    public var selection: ExecutionSelection
    public var savedSelections: [ExecutorID: ExecutionSelection]
    public let createdAt: Date
    public init(id: String = UUID().uuidString, projectID: String, kind: ConversationKind = .projectChat, taskID: String? = nil, title: String, selection: ExecutionSelection = .init(), savedSelections: [ExecutorID: ExecutionSelection] = [:], createdAt: Date = Date()) {
        self.id = id; self.projectID = projectID; self.kind = kind; self.taskID = taskID; self.title = title; self.selection = selection; self.savedSelections = savedSelections; self.createdAt = createdAt
    }
}
public enum MessageRole: String, Codable, Sendable { case user, assistant, system, tool }
public struct Attachment: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let path: String
    public let byteCount: Int
    public let sourceIdentity: String?
    public init(id: String = UUID().uuidString, name: String, path: String, byteCount: Int = 0, sourceIdentity: String? = nil) { self.id = id; self.name = name; self.path = path; self.byteCount = byteCount; self.sourceIdentity = sourceIdentity }
}
public struct Message: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let projectID: String
    public let conversationID: String
    public let role: MessageRole
    public var content: String
    public let runID: String?
    public let attachments: [Attachment]
    public let createdAt: Date
    public init(id: String = UUID().uuidString, projectID: String, conversationID: String, role: MessageRole, content: String, runID: String? = nil, attachments: [Attachment] = [], createdAt: Date = Date()) {
        self.id = id; self.projectID = projectID; self.conversationID = conversationID; self.role = role; self.content = content; self.runID = runID; self.attachments = attachments; self.createdAt = createdAt
    }
}
public enum RunStatus: String, Codable, CaseIterable, Sendable {
    case queued, starting, running, waitingApproval, cancelling, recoveryRequired, succeeded, failed, cancelled
    public var isTerminal: Bool { self == .succeeded || self == .failed || self == .cancelled }
    public var title: String { switch self { case .queued: "排队中"; case .starting: "启动中"; case .running: "运行中"; case .waitingApproval: "等待批准"; case .cancelling: "正在停止"; case .recoveryRequired: "需要恢复核对"; case .succeeded: "已完成"; case .failed: "失败"; case .cancelled: "已停止" } }
}
public struct RunRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let projectID: String
    public let conversationID: String
    public let taskID: String?
    public let parentRunID: String?
    public let selection: ExecutionSelection
    public let cwd: String
    public let phase: TaskPhase?
    public let phaseVersion: Int?
    public let revisionID: String?
    public let prompt: String
    public let writing: Bool
    /// Persist launch intent so a queued request can safely resume after app restart.
    public let includeFullHistory: Bool?
    public let acceptanceReview: Bool?
    public var status: RunStatus
    public var executorSessionID: String?
    public var processID: Int32?
    public var processStartedAt: Date?
    public var effectiveModelID: String?
    public var effectivePolicy: String?
    public var error: String?
    public var output: String
    public let createdAt: Date
    public var endedAt: Date?
    public init(id: String = UUID().uuidString, projectID: String, conversationID: String, taskID: String? = nil, parentRunID: String? = nil, selection: ExecutionSelection, cwd: String, phase: TaskPhase? = nil, phaseVersion: Int? = nil, revisionID: String? = nil, prompt: String, writing: Bool, status: RunStatus = .starting, executorSessionID: String? = nil, processID: Int32? = nil, processStartedAt: Date? = nil, effectiveModelID: String? = nil, effectivePolicy: String? = nil, error: String? = nil, output: String = "", createdAt: Date = Date(), endedAt: Date? = nil, includeFullHistory: Bool? = nil, acceptanceReview: Bool? = nil) {
        self.id = id; self.projectID = projectID; self.conversationID = conversationID; self.taskID = taskID; self.parentRunID = parentRunID; self.selection = selection; self.cwd = cwd; self.phase = phase; self.phaseVersion = phaseVersion; self.revisionID = revisionID; self.prompt = prompt; self.writing = writing; self.status = status; self.executorSessionID = executorSessionID; self.processID = processID; self.processStartedAt = processStartedAt; self.effectiveModelID = effectiveModelID; self.effectivePolicy = effectivePolicy; self.error = error; self.output = output; self.createdAt = createdAt; self.endedAt = endedAt
        self.includeFullHistory = includeFullHistory; self.acceptanceReview = acceptanceReview
    }
}
public struct ApprovalOption: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let allows: Bool
    public init(id: String, title: String, allows: Bool) { self.id = id; self.title = title; self.allows = allows }
}
public enum ApprovalStatus: String, Codable, Sendable { case pending, decided, expired, uncertain }
public struct Approval: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let projectID: String
    public let runID: String
    public let requestID: String
    public let phaseVersion: Int?
    public let title: String
    public let detail: String
    public let options: [ApprovalOption]
    public var status: ApprovalStatus
    public var decision: String?
    public let createdAt: Date
    public init(id: String = UUID().uuidString, projectID: String, runID: String, requestID: String, phaseVersion: Int? = nil, title: String, detail: String, options: [ApprovalOption], status: ApprovalStatus = .pending, decision: String? = nil, createdAt: Date = Date()) {
        self.id = id; self.projectID = projectID; self.runID = runID; self.requestID = requestID; self.phaseVersion = phaseVersion; self.title = title; self.detail = detail; self.options = options; self.status = status; self.decision = decision; self.createdAt = createdAt
    }
}
public struct RequirementRevision: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let projectID: String
    public let taskID: String
    public let version: Int
    public let requirement: String
    public let plan: String
    public let acceptanceCriteria: [String]
    public let createdAt: Date
    public var confirmedAt: Date?
    /// The completed discussion reply this revision was drafted from, if any.
    /// Optional so existing locally saved revisions remain decodable.
    public let sourceMessageID: String?
    public let sourceRunID: String?
    public init(id: String = UUID().uuidString, projectID: String, taskID: String, version: Int, requirement: String, plan: String, acceptanceCriteria: [String], createdAt: Date = Date(), confirmedAt: Date? = nil, sourceMessageID: String? = nil, sourceRunID: String? = nil) {
        self.id = id; self.projectID = projectID; self.taskID = taskID; self.version = version; self.requirement = requirement; self.plan = plan; self.acceptanceCriteria = acceptanceCriteria; self.createdAt = createdAt; self.confirmedAt = confirmedAt; self.sourceMessageID = sourceMessageID; self.sourceRunID = sourceRunID
    }
}
public struct AcceptanceCheck: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let passed: Bool
    public let evidence: String
    public init(id: String = UUID().uuidString, title: String, passed: Bool, evidence: String) { self.id = id; self.title = title; self.passed = passed; self.evidence = evidence }
}
public struct AcceptanceReport: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let projectID: String
    public let taskID: String
    public var sourceRunID: String?
    public let revisionID: String
    public let codeFingerprint: String
    public let checkConfiguration: String
    public let checks: [AcceptanceCheck]
    public let summary: String
    public var stale: Bool
    public let createdAt: Date
    public var humanConfirmedAt: Date?
    public var passed: Bool { !checks.isEmpty && checks.allSatisfy(\.passed) }
    public init(id: String = UUID().uuidString, projectID: String, taskID: String, revisionID: String, codeFingerprint: String, checkConfiguration: String = "readonly-review-v1", checks: [AcceptanceCheck], summary: String, stale: Bool = false, createdAt: Date = Date(), humanConfirmedAt: Date? = nil, sourceRunID: String? = nil) {
        self.id = id; self.projectID = projectID; self.taskID = taskID; self.sourceRunID = sourceRunID; self.revisionID = revisionID; self.codeFingerprint = codeFingerprint; self.checkConfiguration = checkConfiguration; self.checks = checks; self.summary = summary; self.stale = stale; self.createdAt = createdAt; self.humanConfirmedAt = humanConfirmedAt
    }
}
public struct ImportCandidate: Codable, Hashable, Sendable {
    public let sourceKey: String
    public let sourceURL: String?
    public let sourceDescription: String
    public let title: String
    public let description: String
    public let type: TaskType
    public let priority: TaskPriority
    public init(sourceKey: String, sourceURL: String? = nil, sourceDescription: String, title: String, description: String = "", type: TaskType = .feature, priority: TaskPriority = .normal) { self.sourceKey = sourceKey; self.sourceURL = sourceURL; self.sourceDescription = sourceDescription; self.title = title; self.description = description; self.type = type; self.priority = priority }
}
public struct Provenance: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let projectID: String
    public let batchID: String
    public let taskID: String
    public let sourceKey: String
    public let sourceURL: String?
    public let sourceDescription: String
    public init(id: String = UUID().uuidString, projectID: String, batchID: String, taskID: String, sourceKey: String, sourceURL: String?, sourceDescription: String) { self.id = id; self.projectID = projectID; self.batchID = batchID; self.taskID = taskID; self.sourceKey = sourceKey; self.sourceURL = sourceURL; self.sourceDescription = sourceDescription }
}
public struct ImportBatch: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let projectID: String
    public let conversationID: String
    public let requestMessageID: String
    public let operationKey: String
    public let sourceRange: String
    public let createdTaskIDs: [String]
    public let duplicateCount: Int
    public let errors: [String]
    public let committedAt: Date
    public init(id: String = UUID().uuidString, projectID: String, conversationID: String, requestMessageID: String, operationKey: String, sourceRange: String, createdTaskIDs: [String], duplicateCount: Int, errors: [String], committedAt: Date = Date()) {
        self.id = id; self.projectID = projectID; self.conversationID = conversationID; self.requestMessageID = requestMessageID; self.operationKey = operationKey; self.sourceRange = sourceRange; self.createdTaskIDs = createdTaskIDs; self.duplicateCount = duplicateCount; self.errors = errors; self.committedAt = committedAt
    }
}
public struct RunEvent: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let projectID: String
    public let runID: String
    public let kind: String
    public let content: String
    public let createdAt: Date
    public init(id: String = UUID().uuidString, projectID: String, runID: String, kind: String, content: String, createdAt: Date = Date()) { self.id = id; self.projectID = projectID; self.runID = runID; self.kind = kind; self.content = content; self.createdAt = createdAt }
}
public struct WorkspaceSnapshot: Sendable {
    public var projects: [Project]
    public var tasks: [TaskItem]
    public var conversations: [Conversation]
    public var messages: [Message]
    public var runs: [RunRecord]
    public var approvals: [Approval]
    public var revisions: [RequirementRevision]
    public var reports: [AcceptanceReport]
    public var importBatches: [ImportBatch]
    public var provenance: [Provenance]
    public var events: [RunEvent]
    public init(projects: [Project] = [], tasks: [TaskItem] = [], conversations: [Conversation] = [], messages: [Message] = [], runs: [RunRecord] = [], approvals: [Approval] = [], revisions: [RequirementRevision] = [], reports: [AcceptanceReport] = [], importBatches: [ImportBatch] = [], provenance: [Provenance] = [], events: [RunEvent] = []) {
        self.projects = projects; self.tasks = tasks; self.conversations = conversations; self.messages = messages; self.runs = runs; self.approvals = approvals; self.revisions = revisions; self.reports = reports; self.importBatches = importBatches; self.provenance = provenance; self.events = events
    }
}
public enum KanbanError: LocalizedError, Sendable {
    case notFound(String), invalid(String), busy(String), stopRequired(String), staleAcceptance, database(String)
    public var errorDescription: String? { switch self { case .notFound(let x): "找不到\(x)"; case .invalid(let x), .busy(let x), .stopRequired(let x), .database(let x): x; case .staleAcceptance: "验收报告已过期，请重新验收。" } }
}
