import Foundation
import Testing
import AgentKanbanCore
import AgentKanbanExecutors
@testable import AgentKanban

private actor CompletionExecutor: ExecutorService {
    private(set) var calls = 0
    func probe(_ executor: ExecutorID) async -> ExecutorInstallation {
        calls += 1
        return .init(id: executor)
    }
    func models(_ executor: ExecutorID) async throws -> [ExecutorModel] { calls += 1; return [] }
    func start(_ request: ExecutorRequest) async throws -> ExecutorRun {
        calls += 1
        throw KanbanError.invalid("Manual completion must not launch an executor")
    }
    func respond(runID: String, approvalID: String, decision: ApprovalDecision) async throws { calls += 1 }
    func cancel(runID: String) async -> CancellationResult { calls += 1; return .unknown("Unexpected cancellation") }
}

@Suite("Manual completion without mandatory acceptance", .serialized) @MainActor
struct ManualCompletionTests {
    private func project(_ repository: Repository, directory: URL, name: String) async throws -> Project {
        let path = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["init", "-q", path.path]
        git.standardOutput = FileHandle.nullDevice; git.standardError = FileHandle.nullDevice
        try git.run(); git.waitUntilExit()
        try #require(git.terminationStatus == 0)
        return try await repository.importProject(path: path.path)
    }

    private func settle(_ store: AppStore, taskID: String) async throws {
        for _ in 0..<250 {
            if store.error != nil || store.snapshot.tasks.first(where: { $0.id == taskID })?.phase == .completed { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Manual completion did not settle")
    }

    @Test(arguments: [false, true])
    func explicitCompletionAndPhaseMenuDoNotRequireReportOrFilesystemChecks(usePhaseMenu: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kanban-manual-completion-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = CompletionExecutor()
        let store = AppStore(dataDirectory: directory.appendingPathComponent("data"), executors: executor)
        let repository = try #require(store.repository)
        let target = try await project(repository, directory: directory, name: "target")
        let other = try await project(repository, directory: directory, name: "other")
        let task = try await repository.createTask(projectID: target.id, title: "User decides completion")
        let run = try await repository.prepareRun(conversationID: task.mainConversationID, prompt: "Direct fixture", directImplementation: true)
        try await repository.finishRun(id: run.id, status: .succeeded, stopConfirmed: true)
        let foreignTask = try await repository.createTask(projectID: other.id, title: "Other project remains pending")
        try await store.reload(); store.selectTask(foreignTask.id)
        let before = store.snapshot
        // Completing a task is a local stage decision, even if its code directory is unavailable.
        try FileManager.default.removeItem(atPath: target.path)
        if usePhaseMenu { store.transitionTask(task.id, to: .completed) }
        else { store.completeTask(task.id) }
        try await settle(store, taskID: task.id)
        #expect(store.error == nil)
        let completed = try await repository.task(id: task.id)
        let untouched = try await repository.task(id: foreignTask.id)
        #expect(completed.phase == .completed)
        #expect(completed.currentRevisionID == nil)
        #expect(untouched.phase == .backlog)
        #expect(store.snapshot.reports.isEmpty && store.snapshot.revisions.isEmpty)
        #expect(store.snapshot.runs == before.runs)
        #expect(store.snapshot.messages == before.messages)
        #expect(await executor.calls == 0)
    }
}
