import Foundation
import Testing
import AgentKanbanCore
import AgentKanbanExecutors
@testable import AgentKanban

private actor GlobalRunExecutorFixture: ExecutorService {
    private(set) var cancelled: [String] = []
    private(set) var approvals: [[String]] = []
    func probe(_ executor: ExecutorID) async -> ExecutorInstallation { .init(id: executor) }
    func models(_ executor: ExecutorID) async throws -> [ExecutorModel] { [] }
    func start(_ request: ExecutorRequest) async throws -> ExecutorRun { throw KanbanError.invalid("No model calls in monitoring tests") }
    func cancel(runID: String) async -> CancellationResult { cancelled.append(runID); return .confirmed }
    func respond(runID: String, approvalID: String, decision: ApprovalDecision) async throws { approvals.append([runID, approvalID]) }
}

@Suite("Global activity monitoring") @MainActor struct GlobalRunMonitoringTests {
    private func store() -> (URL, AppStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kanban-global-monitor-\(UUID().uuidString)")
        return (directory, AppStore(dataDirectory: directory))
    }
    private func run(_ id: String, project: String, status: RunStatus, task: String? = nil) -> RunRecord {
        RunRecord(id: id, projectID: project, conversationID: "chat-\(project)", taskID: task, selection: .init(), cwd: "/fixture/\(project)", prompt: "monitor", writing: false, status: status)
    }

    @Test func globalActivitiesAndEventsDoNotDependOnSelectedProject() {
        let (directory, store) = store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let states: [RunStatus] = [.queued, .starting, .running, .waitingApproval, .cancelling, .recoveryRequired, .succeeded, .failed, .cancelled]
        let runs = states.enumerated().map { run("run-\($0.offset)", project: $0.offset % 2 == 0 ? "a" : "b", status: $0.element, task: $0.offset % 2 == 0 ? "task-a" : nil) }
        store.snapshot = WorkspaceSnapshot(
            projects: [.init(id: "a", name: "Project A", path: "/a"), .init(id: "b", name: "Project B", path: "/b")],
            runs: runs,
            events: runs.map { .init(id: "event-\($0.id)", projectID: $0.projectID, runID: $0.id, kind: "agent.running", content: "child state") }
        )
        let expected = Set(runs.filter { !$0.status.isTerminal }.map(\.id))
        for selected in ["a", "b", nil] as [String?] {
            store.selectedProjectID = selected
            #expect(Set(store.activeRuns.map(\.id)) == expected)
            #expect(Set(store.activeRunEvents.map(\.runID)) == expected)
            #expect(store.activeRuns.count == 6)
        }
        store.snapshot.runs[2].status = .succeeded
        #expect(store.activeRuns.count == 5)
        #expect(!store.activeRunEvents.contains { $0.runID == "run-2" })
        #expect(store.snapshot.events.count == 9, "History remains stored when activity disappears")
    }

    @Test func openingAnotherProjectsRunRoutesToItsOriginalConversation() {
        let (directory, store) = store()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.snapshot = WorkspaceSnapshot(
            projects: [.init(id: "a", name: "Project A", path: "/a"), .init(id: "b", name: "Project B", path: "/b")],
            conversations: [.init(id: "chat-b", projectID: "b", title: "Project B chat")],
            runs: [run("foreign", project: "b", status: .running)]
        )
        store.selectedProjectID = "a"; store.route = .runs
        store.selectConversation(store.activeRuns[0].conversationID)
        #expect(store.selectedProjectID == "b")
        #expect(store.selectedConversationID == "chat-b")
        #expect(store.route == .chat)
    }

    @Test func crossProjectApprovalAndStopTargetTheOriginalRun() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kanban-global-actions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = GlobalRunExecutorFixture()
        let store = AppStore(dataDirectory: directory.appendingPathComponent("data"), executors: executor)
        let repository = try #require(store.repository)
        var chats: [Conversation] = []
        for name in ["a", "b"] {
            let path = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            let git = Process(); git.executableURL = URL(fileURLWithPath: "/usr/bin/git"); git.arguments = ["init", "-q", path.path]
            try git.run(); git.waitUntilExit(); try #require(git.terminationStatus == 0)
            let project = try await repository.importProject(path: path.path)
            chats.append(try await repository.createConversation(projectID: project.id))
        }
        let first = try await repository.prepareRun(conversationID: chats[0].id, prompt: "Project A work")
        let second = try await repository.prepareRun(conversationID: chats[1].id, prompt: "Project B work")
        try await repository.markRunStarted(id: first.id)
        try await repository.markRunStarted(id: second.id)
        let approval = try await repository.saveApproval(.init(projectID: second.projectID, runID: second.id, requestID: "native-b", title: "Fixture approval", detail: "Controlled request", options: [.init(id: "approve", title: "Allow", allows: true), .init(id: "deny", title: "Deny", allows: false)]))
        try await store.reload(); store.selectProject(first.projectID); store.route = .runs
        #expect(store.activeRuns.count == 2)
        store.resolveApproval(approval.id, approved: false)
        for _ in 0..<100 {
            if await executor.approvals.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await executor.approvals == [[second.id, "native-b"]])
        store.stopRun(second.id)
        for _ in 0..<100 {
            if try await repository.run(id: second.id).status == .cancelled { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await store.reload()
        #expect(await executor.cancelled == [second.id])
        #expect(try await repository.run(id: first.id).status == .running)
        #expect(Set(store.activeRuns.map(\.id)) == [first.id])
        #expect(store.selectedProjectID == first.projectID)
    }
}
