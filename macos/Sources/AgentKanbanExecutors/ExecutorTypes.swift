import Foundation
import AgentKanbanCore

public enum AuthenticationState: String, Codable, Sendable { case notInstalled, unknown, unauthenticated, configured, authenticated, failed }
public struct ExecutorInstallation: Sendable, Identifiable {
    public var id: ExecutorID
    public var executable: String?
    public var version: String?
    public var authentication: AuthenticationState
    public var detail: String
    public var checkedAt: Date
    public init(id: ExecutorID, executable: String? = nil, version: String? = nil, authentication: AuthenticationState = .unknown, detail: String = "尚未检测", checkedAt: Date = .now) {
        self.id = id; self.executable = executable; self.version = version; self.authentication = authentication; self.detail = detail; self.checkedAt = checkedAt
    }
}
public struct ExecutorModel: Sendable, Codable, Identifiable, Hashable {
    public var id: String
    public var displayName: String
    public var efforts: [String]
    public var defaultEffort: String?
    public var isDefault: Bool
    public var verified: Bool
    public var evidence: String
    /// Cursor variants are authoritative IDs returned by its directory, never fabricated slugs.
    public var effortVariants: [String: String]
    public init(id: String, displayName: String, efforts: [String] = [], defaultEffort: String? = nil, isDefault: Bool = false, verified: Bool = false, evidence: String = "2026-10-07 研究快照；账户可用性未验证", effortVariants: [String: String] = [:]) {
        self.id = id; self.displayName = displayName; self.efforts = efforts; self.defaultEffort = defaultEffort; self.isDefault = isDefault; self.verified = verified; self.evidence = evidence; self.effortVariants = effortVariants
    }
}
public struct ExecutorRequest: Sendable {
    public let runID: String
    public let conversationID: String
    public let projectPath: String
    public let prompt: String
    /// Local, persisted user attachments. Images are delivered as native image input blocks.
    public let attachments: [Attachment]
    public let selection: ExecutionSelection
    public let phase: TaskPhase?
    public let sessionID: String?
    public let identityRecorder: (@Sendable (ManagedProcessIdentity) async throws -> Void)?
    public var readOnly: Bool { phase == .discussion || phase == .acceptance }
    public init(runID: String, conversationID: String, projectPath: String, prompt: String, selection: ExecutionSelection, phase: TaskPhase? = nil, sessionID: String? = nil, attachments: [Attachment] = [], identityRecorder: (@Sendable (ManagedProcessIdentity) async throws -> Void)? = nil) {
        self.runID = runID; self.conversationID = conversationID; self.projectPath = projectPath; self.prompt = prompt; self.selection = selection; self.phase = phase; self.sessionID = sessionID
        self.identityRecorder = identityRecorder
        self.attachments = attachments
    }
}
public struct ExecutorApproval: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public let allowsApproval: Bool
    public init(id: String, title: String, detail: String, allowsApproval: Bool = true) { self.id = id; self.title = title; self.detail = detail; self.allowsApproval = allowsApproval }
}
public enum ExecutorEvent: Sendable {
    case processLaunched(ManagedProcessIdentity)
    case started(sessionID: String, processID: Int32, modelID: String?, effectivePolicy: String?)
    case textDelta(String)
    case thinkingDelta(String)
    case tool(id: String, name: String, status: String, detail: String)
    case agent(id: String, status: String, summary: String)
    case approval(ExecutorApproval)
    case approvalResolved(id: String, approved: Bool)
    case completed(output: String)
    case cancelled
    case failed(String)
    /// Connection loss is not a completed cancellation, even when the parent process exited.
    case recoveryRequired(String)
}
public struct ExecutorRun: Sendable {
    public let id: String
    public let events: AsyncStream<ExecutorEvent>
    public init(id: String, events: AsyncStream<ExecutorEvent>) { self.id = id; self.events = events }
}
public enum ApprovalDecision: Sendable { case approve, deny }
public enum CancellationResult: Sendable, Equatable { case confirmed, alreadyFinished, unknown(String) }

public protocol ExecutorService: Sendable {
    func probe(_ executor: ExecutorID) async -> ExecutorInstallation
    func models(_ executor: ExecutorID) async throws -> [ExecutorModel]
    func start(_ request: ExecutorRequest) async throws -> ExecutorRun
    func respond(runID: String, approvalID: String, decision: ApprovalDecision) async throws
    func cancel(runID: String) async -> CancellationResult
    func processIdentity(runID: String) async -> ManagedProcessIdentity?
    func verifyRecovery(_ record: RunRecord) async -> CancellationResult
    func stopRecovered(_ record: RunRecord) async -> CancellationResult
}
public extension ExecutorService {
    func processIdentity(runID: String) async -> ManagedProcessIdentity? { nil }
    func verifyRecovery(_ record: RunRecord) async -> CancellationResult { .unknown("此执行器未实现旧进程身份核对") }
    func stopRecovered(_ record: RunRecord) async -> CancellationResult { .unknown("此执行器未实现身份核实后的旧进程停止") }
}

public enum ExecutorCatalog {
    public static func fallback(_ executor: ExecutorID) -> [ExecutorModel] {
        switch executor {
        case .codex:
            return ["gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"].map { id in
                let efforts = ["low", "medium", "high", "xhigh", "max"] + (id.hasSuffix("luna") ? [] : ["ultra"])
                return ExecutorModel(id: id, displayName: id.uppercased().replacingOccurrences(of: "SOL", with: "Sol").replacingOccurrences(of: "ASTRA", with: "Astra").replacingOccurrences(of: "LUNA", with: "Luna").replacingOccurrences(of: "TERRA", with: "Terra"), efforts: efforts, defaultEffort: id == "gpt-6.1-sol" || id == "gpt-5.6-sol" ? "low" : "medium")
            }
        case .claude:
            return [("claude-fable-5-1", "Fable 5.1"), ("claude-opus-5-5", "Opus 5.5"), ("claude-sonnet-5-5", "Sonnet 5.5"), ("claude-haiku-4-5-20251001", "Haiku 4.5")].map { id, name in
                ExecutorModel(id: id, displayName: name, efforts: id.contains("haiku") ? [] : ["low", "medium", "high", "xhigh", "max"])
            }
        case .cursor:
            return [ExecutorModel(id: "auto", displayName: "Auto"), ExecutorModel(id: "composer-2.5", displayName: "Composer 2.5"), ExecutorModel(id: "grok-4.7-high", displayName: "Grok 4.7", efforts: ["low", "medium", "high", "xhigh"], effortVariants: ["low": "grok-4.7-low", "medium": "grok-4.7-medium", "high": "grok-4.7-high", "xhigh": "grok-4.7-xhigh"])]
        }
    }
}
