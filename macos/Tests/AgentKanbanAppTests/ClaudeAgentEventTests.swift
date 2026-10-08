import Foundation
import Testing
import AgentKanbanCore
import AgentKanbanExecutors
@testable import AgentKanban

/// Drives the same application boundary used by the live Claude adapter without a model request.
private actor ClaudeEventFixture: ExecutorService {
    private var continuations: [String: AsyncStream<ExecutorEvent>.Continuation] = [:]
    private var cancellationGate: CheckedContinuation<Void, Never>?
    private(set) var requests: [ExecutorRequest] = []
    private(set) var cancellationRequests: [String] = []

    func probe(_ executor: ExecutorID) async -> ExecutorInstallation {
        ExecutorInstallation(id: executor, authentication: .authenticated, detail: "Controlled Claude event fixture")
    }
    func models(_ executor: ExecutorID) async throws -> [ExecutorModel] { [] }
    func start(_ request: ExecutorRequest) async throws -> ExecutorRun {
        requests.append(request)
        let pair = AsyncStream<ExecutorEvent>.makeStream()
        continuations[request.runID] = pair.continuation
        return ExecutorRun(id: request.runID, events: pair.stream)
    }
    func emit(_ events: [ExecutorEvent], runID: String, finish: Bool = false) {
        guard let continuation = continuations[runID] else { return }
        for event in events { continuation.yield(event) }
        if finish { continuation.finish(); continuations[runID] = nil }
    }
    func respond(runID: String, approvalID: String, decision: ApprovalDecision) async throws {}
    func cancel(runID: String) async -> CancellationResult {
        guard continuations[runID] != nil else { return .unknown("Fixture does not own this run") }
        cancellationRequests.append(runID)
        await withCheckedContinuation { cancellationGate = $0 }
        return .confirmed
    }
    func confirmCancellation() {
        cancellationGate?.resume()
        cancellationGate = nil
    }
}

@Suite("Claude child events in the application") @MainActor struct ClaudeAgentEventTests {
    private func fixture() throws -> (URL, AppStore, ClaudeEventFixture) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kanban-claude-events-\(UUID().uuidString)")
        let working = directory.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["init", "-q", working.path]
        try git.run(); git.waitUntilExit()
        try #require(git.terminationStatus == 0)
        let executor = ClaudeEventFixture()
        return (directory, AppStore(dataDirectory: directory.appendingPathComponent("data"), executors: executor), executor)
    }

    private func eventually(_ condition: @MainActor () async throws -> Bool) async throws {
        for _ in 0..<300 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(try await condition(), "Application did not consume the controlled Claude events")
    }

    @Test func childSummaryBelongsToParentRunAndSurvivesRepositoryReopen() async throws {
        let (directory, store, executor) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try #require(store.repository)
        let project = try await repository.importProject(path: directory.appendingPathComponent("repo").path, defaultExecutor: .claude)
        let task = try await repository.createTask(projectID: project.id, title: "Claude 只读委派")
        try await repository.transitionTask(id: task.id, to: .discussion)
        try await store.reload(); store.selectTask(task.id)
        store.sendMessage("委派只读分析并返回结论", attachments: [])
        try await eventually { await executor.requests.count == 1 }
        let request = try #require(await executor.requests.first)
        #expect(request.selection.executor == .claude)
        #expect(request.readOnly)
        #expect(request.conversationID == task.mainConversationID)

        let childID = "claude-child-audit-1"
        let childSummary = "子 Agent 证据：README.md 第 1 行包含 fixture 标识。"
        let parentReply = "主 Agent 已完成分析。"
        await executor.emit([
            .started(sessionID: "claude-main-session", processID: 123_456, modelID: "claude-opus-5-5", effectivePolicy: "Readonly fixture"),
            .agent(id: childID, status: "running", summary: "读取项目资料")
        ], runID: request.runID)
        try await eventually { store.snapshot.events.contains { $0.kind == "agent.running" } }
        #expect(store.snapshot.runs.count == 1)
        #expect(store.snapshot.conversations.count == 1)
        #expect(store.snapshot.messages.filter { $0.role == .assistant }.isEmpty)

        await executor.emit([
            .agent(id: childID, status: "completed", summary: childSummary),
            .textDelta(parentReply),
            .completed(output: parentReply)
        ], runID: request.runID, finish: true)
        try await eventually {
            store.snapshot.runs.first?.status == .succeeded && store.snapshot.messages.contains { $0.id == "reply-\(request.runID)" }
        }
        let childEvents = store.snapshot.events.filter { $0.kind.hasPrefix("agent.") }
        #expect(childEvents.map(\.kind) == ["agent.running", "agent.completed"])
        #expect(childEvents.allSatisfy { $0.projectID == project.id && $0.runID == request.runID })
        #expect(childEvents.last?.content == "\(childID)\n\(childSummary)")
        #expect(store.snapshot.runs.count == 1)
        #expect(store.snapshot.runs.first?.parentRunID == nil)
        #expect(store.snapshot.runs.first?.conversationID == task.mainConversationID)
        #expect(store.snapshot.runs.first?.output == parentReply)
        let replies = store.snapshot.messages.filter { $0.role == .assistant }
        #expect(replies.count == 1)
        #expect(replies.first?.content == parentReply)
        #expect(replies.first?.conversationID == task.mainConversationID)
        #expect(replies.first?.runID == request.runID)
        #expect(!replies.contains { $0.content.contains(childSummary) })

        let reopened = try Repository(databaseURL: directory.appendingPathComponent("data/workspace.sqlite"))
        let persisted = try await reopened.snapshot()
        #expect(persisted.events.filter { $0.kind.hasPrefix("agent.") } == childEvents)
        #expect(persisted.runs.count == 1)
        #expect(persisted.conversations.count == 1)
        #expect(persisted.messages.filter { $0.role == .assistant } == replies)
    }

    @Test func stageChangeWaitsForChildStopAndRejectsLateParentReply() async throws {
        let (directory, store, executor) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try #require(store.repository)
        let project = try await repository.importProject(path: directory.appendingPathComponent("repo").path, defaultExecutor: .claude)
        let task = try await repository.createTask(projectID: project.id, title: "停止委派后切换阶段")
        try await repository.transitionTask(id: task.id, to: .discussion)
        try await store.reload(); store.selectTask(task.id)
        store.sendMessage("启动只读子 Agent", attachments: [])
        try await eventually { await executor.requests.count == 1 }
        let request = try #require(await executor.requests.first)
        let childID = "claude-child-still-running"
        await executor.emit([
            .started(sessionID: "claude-cancel-session", processID: 123_457, modelID: "claude-opus-5-5", effectivePolicy: "Readonly fixture"),
            .agent(id: childID, status: "running", summary: "子 Agent 尚在读取")
        ], runID: request.runID)
        try await eventually { store.snapshot.events.contains { $0.kind == "agent.running" } }
        let originalEvents = store.snapshot.events.filter { $0.kind.hasPrefix("agent.") }

        store.transitionTask(task.id, to: .backlog)
        try await eventually {
            await executor.cancellationRequests == [request.runID] && store.snapshot.runs.first?.status == .cancelling
        }
        #expect(store.snapshot.tasks.first?.phase == .discussion, "Stage must remain unchanged until the managed child group is confirmed stopped")
        #expect(store.changingTasks.contains(task.id))
        await executor.confirmCancellation()
        try await eventually { store.snapshot.tasks.first?.phase == .backlog && !store.changingTasks.contains(task.id) }
        #expect(store.snapshot.runs.first?.status == .cancelled)
        #expect(store.snapshot.tasks.first?.phaseVersion == 2)

        // Buffered packets may arrive after cancellation confirmation. Give the finished stream
        // consumer a scheduling turn before reading persistence; terminal runs ignore both packets.
        let childStoppedSummary = "子 Agent 已随原运行停止。"
        await executor.emit([
            .completed(output: "迟到的旧阶段主回复，不应出现在会话里。"),
            .agent(id: childID, status: "stopped", summary: childStoppedSummary)
        ], runID: request.runID, finish: true)
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(100))
        try await store.reload()
        #expect(store.snapshot.runs.count == 1)
        #expect(store.snapshot.runs.first?.status == .cancelled)
        #expect(store.snapshot.runs.first?.output.isEmpty == true)
        #expect(store.snapshot.messages.filter { $0.role == .assistant }.isEmpty)
        #expect(originalEvents.allSatisfy { store.snapshot.events.contains($0) })
        #expect(store.snapshot.events.filter { $0.kind.hasPrefix("agent.") } == originalEvents)
        #expect(store.snapshot.events.filter { $0.kind.hasPrefix("agent.") }.allSatisfy { $0.runID == request.runID })
        #expect(store.snapshot.conversations.count == 1)
        #expect(store.snapshot.tasks.first?.phase == .backlog)

        let reopened = try Repository(databaseURL: directory.appendingPathComponent("data/workspace.sqlite"))
        let persisted = try await reopened.snapshot()
        #expect(persisted.runs.first?.status == .cancelled)
        #expect(persisted.messages.filter { $0.role == .assistant }.isEmpty)
        #expect(originalEvents.allSatisfy { persisted.events.contains($0) })
    }
}
