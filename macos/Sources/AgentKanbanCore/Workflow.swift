import Foundation

/// A business command boundary; external adapters supply facts, never stage decisions.
public actor TaskEngine {
    public let repository: Repository
    public init(repository: Repository) { self.repository = repository }
    public func prepareRun(conversationID: String, prompt: String, directImplementation: Bool = false, includeFullHistory: Bool = false, acceptanceReview: Bool = false) async throws -> RunRecord { try await repository.prepareRun(conversationID: conversationID, prompt: prompt, directImplementation: directImplementation, includeFullHistory: includeFullHistory, acceptanceReview: acceptanceReview) }
    public func claimNextQueuedRun() async throws -> RunRecord? { try await repository.claimNextQueuedRun() }
    public func returnUnstartedRunToQueue(id: String) async throws { try await repository.returnUnstartedRunToQueue(id: id) }
    public func configureTaskWorktree(taskID: String, path: String?) async throws { try await repository.configureTaskWorktree(taskID: taskID, path: path) }
    public func markRunStarted(id: String, sessionID: String? = nil, processID: Int32? = nil, processStartedAt: Date? = nil, effectiveModelID: String? = nil, effectivePolicy: String? = nil) async throws {
        try await repository.markRunStarted(id: id, sessionID: sessionID, processID: processID, processStartedAt: processStartedAt, effectiveModelID: effectiveModelID, effectivePolicy: effectivePolicy)
    }
    public func requestStop(id: String) async throws { try await repository.requestStop(id: id) }
    public func finishRun(id: String, status: RunStatus, output: String? = nil, error: String? = nil, stopConfirmed: Bool) async throws {
        try await repository.finishRun(id: id, status: status, output: output, error: error, stopConfirmed: stopConfirmed)
    }
    public func transitionTask(id: String, to phase: TaskPhase) async throws { try await repository.transitionTask(id: id, to: phase) }
    public func saveRevision(taskID: String, requirement: String, plan: String, acceptanceCriteria: [String]) async throws -> RequirementRevision { try await repository.saveRevision(taskID: taskID, requirement: requirement, plan: plan, acceptanceCriteria: acceptanceCriteria) }
    public func confirmRevision(id: String) async throws { try await repository.confirmRevision(id: id) }
    public func confirmRevisionAndPrepareDevelopmentRun(id: String, prompt: String) async throws -> RunRecord {
        try await repository.confirmRevisionAndPrepareDevelopmentRun(id: id, prompt: prompt)
    }
    public func saveAcceptance(_ report: AcceptanceReport) async throws { try await repository.saveAcceptance(report) }
    public func completeTask(id: String) async throws {
        try await repository.completeTask(id: id)
    }
}
