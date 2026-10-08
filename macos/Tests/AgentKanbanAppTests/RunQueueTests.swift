import Foundation
import Testing
import AgentKanbanCore
import AgentKanbanExecutors
@testable import AgentKanban

/// Held event streams make directory occupancy deterministic. No real model process is launched.
private actor RunQueueExecutor: ExecutorService {
    private(set) var requests: [ExecutorRequest] = []
    private(set) var cancellationIDs: [String] = []
    private(set) var verifiedRecoveryIDs: [String] = []
    private var continuations: [String: AsyncStream<ExecutorEvent>.Continuation] = [:]
    private var pauseNextProbe = false
    private var probeContinuation: CheckedContinuation<Void, Never>?
    private(set) var probeWaiting = false

    func holdNextProbe() { pauseNextProbe = true }
    func releaseProbe() {
        pauseNextProbe = false
        probeWaiting = false
        probeContinuation?.resume()
        probeContinuation = nil
    }

    func probe(_ executor: ExecutorID) async -> ExecutorInstallation {
        if pauseNextProbe {
            pauseNextProbe = false
            await withCheckedContinuation { continuation in
                probeContinuation = continuation
                probeWaiting = true
            }
        }
        return .init(id: executor, authentication: .authenticated, detail: "Controlled queue fixture")
    }
    func models(_ executor: ExecutorID) async throws -> [ExecutorModel] {
        [.init(id: "fixture-model", displayName: "Fixture model", efforts: ["low", "high"], verified: true)]
    }
    func start(_ request: ExecutorRequest) async throws -> ExecutorRun {
        requests.append(request)
        let pair = AsyncStream<ExecutorEvent>.makeStream()
        continuations[request.runID] = pair.continuation
        pair.continuation.yield(.started(sessionID: "queue-fixture-\(request.runID)", processID: 0,
                                         modelID: request.selection.modelID, effectivePolicy: "Controlled queue fixture"))
        return .init(id: request.runID, events: pair.stream)
    }
    func complete(_ id: String) {
        continuations[id]?.yield(.completed(output: "Controlled queued implementation completed."))
        continuations[id]?.finish()
        continuations[id] = nil
    }
    func respond(runID: String, approvalID: String, decision: ApprovalDecision) async throws {}
    func cancel(runID: String) async -> CancellationResult {
        cancellationIDs.append(runID)
        guard requests.contains(where: { $0.runID == runID }) else {
            return .unknown("Controlled executor never received this run; no process identity exists")
        }
        continuations[runID]?.yield(.cancelled)
        continuations[runID]?.finish()
        continuations[runID] = nil
        return .confirmed
    }
    func verifyRecovery(_ record: RunRecord) async -> CancellationResult {
        verifiedRecoveryIDs.append(record.id)
        return .confirmed
    }
}

@Suite("Persistent run queue and task worktree orchestration", .serialized) @MainActor
struct RunQueueTests {
    @MainActor private struct Fixture {
        let directory: URL
        let store: AppStore
        let executor: RunQueueExecutor
        var repository: Repository { get throws { try #require(store.repository) } }
    }

    private func fixture() -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kanban-run-queue-\(UUID().uuidString)", isDirectory: true)
        let executor = RunQueueExecutor()
        return .init(directory: directory,
                     store: AppStore(dataDirectory: directory.appendingPathComponent("data"), executors: executor),
                     executor: executor)
    }

    private func git(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        try #require(process.terminationStatus == 0, "Controlled Git fixture command failed")
    }

    private func project(_ fixture: Fixture, committed: Bool = false) async throws -> Project {
        let directory = fixture.directory.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try git(["init", "-q"], at: directory)
        if committed {
            try Data("committed baseline\n".utf8).write(to: directory.appendingPathComponent("fixture.txt"))
            try git(["add", "fixture.txt"], at: directory)
            try git(["-c", "user.name=Queue Fixture", "-c", "user.email=queue-fixture@example.invalid",
                     "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
                     "commit", "-qm", "Controlled baseline"], at: directory)
        }
        return try await fixture.repository.importProject(path: directory.path, name: "Queue fixture", defaultExecutor: .claude)
    }

    private func eventually(_ condition: @MainActor () async throws -> Bool) async throws {
        for _ in 0..<400 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(try await condition(), "The controlled queue operation did not complete")
    }

    private func startWriter(_ fixture: Fixture, project: Project) async throws -> RunRecord {
        let conversation = try await fixture.repository.createConversation(projectID: project.id, title: "Held directory writer")
        try await fixture.store.reload(); fixture.store.selectConversation(conversation.id)
        #expect(fixture.store.sendMessage("Hold this directory until the fixture completes it", attachments: []))
        try await eventually {
            fixture.store.snapshot.runs.contains { $0.conversationID == conversation.id && $0.status == .running }
                && !fixture.store.sendingConversations.contains(conversation.id)
        }
        return try #require(fixture.store.snapshot.runs.first { $0.conversationID == conversation.id })
    }

    private func queueTask(_ fixture: Fixture, project: Project, title: String,
                           selection: ExecutionSelection? = nil) async throws -> (TaskItem, RunRecord) {
        let task = try await fixture.repository.createTask(projectID: project.id, title: title, description: "Explicitly authorized development")
        if let selection { try await fixture.repository.updateSelection(conversationID: task.mainConversationID, selection: selection) }
        try await fixture.store.reload(); fixture.store.selectTask(task.id)
        fixture.store.implementTaskDirectly(task.id)
        try await eventually {
            fixture.store.snapshot.runs.contains { $0.taskID == task.id && $0.status == .queued }
                && !fixture.store.changingTasks.contains(task.id)
        }
        let queued = try #require(fixture.store.snapshot.runs.first { $0.taskID == task.id })
        return (try await fixture.repository.task(id: task.id), queued)
    }

    @Test func heldWriterReleasesQueuedTasksInFIFOOrderWithoutAnotherUserAction() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let project = try await project(fixture)
        let first = try await startWriter(fixture, project: project)
        let frozenSelection = ExecutionSelection(executor: .codex, modelID: "fixture-model", effort: "high", permission: .requestApproval)
        let (secondTask, second) = try await queueTask(fixture, project: project, title: "Second request", selection: frozenSelection)
        let (_, third) = try await queueTask(fixture, project: project, title: "Third request")
        try await fixture.repository.updateSelection(conversationID: secondTask.mainConversationID,
                                                     selection: .init(executor: .cursor, modelID: "fixture-model", effort: "low", permission: .fullAccess))
        #expect(await fixture.executor.requests.map(\.runID) == [first.id])
        #expect(secondTask.phase == .development)
        #expect(fixture.store.error == nil)
        #expect(fixture.store.snapshot.messages.contains { $0.runID == second.id && $0.role == .user })

        await fixture.executor.complete(first.id)
        try await eventually { fixture.store.snapshot.runs.first { $0.id == second.id }?.status == .running }
        #expect(await fixture.executor.requests.map(\.runID) == [first.id, second.id])
        #expect(fixture.store.snapshot.runs.first { $0.id == third.id }?.status == .queued)
        let frozenSecond = try #require(await fixture.executor.requests.first { $0.runID == second.id })
        #expect(frozenSecond.projectPath == project.path && frozenSecond.phase == .development)
        #expect(frozenSecond.selection == frozenSelection && second.selection == frozenSelection)
        #expect(frozenSecond.sessionID == nil && frozenSecond.prompt.contains(secondTask.title))

        await fixture.executor.complete(second.id)
        try await eventually { fixture.store.snapshot.runs.first { $0.id == third.id }?.status == .running }
        #expect(await fixture.executor.requests.map(\.runID) == [first.id, second.id, third.id])
        await fixture.executor.complete(third.id)
        try await eventually { fixture.store.activeRuns.isEmpty }
        try await fixture.store.reload()
        #expect(await fixture.executor.requests.map(\.runID) == [first.id, second.id, third.id])
        #expect(await fixture.executor.cancellationIDs.isEmpty)
        #expect(fixture.store.snapshot.reports.isEmpty)
        #expect(await fixture.store.stopAllForTermination())
    }

    @Test func cancellingQueuedRequestDoesNotContactExecutorOrConsumeTheNextSlot() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let project = try await project(fixture)
        let first = try await startWriter(fixture, project: project)
        let (_, cancelled) = try await queueTask(fixture, project: project, title: "Cancel while queued")
        let (_, next) = try await queueTask(fixture, project: project, title: "Next queued request")

        fixture.store.stopRun(cancelled.id)
        try await eventually { fixture.store.snapshot.runs.first { $0.id == cancelled.id }?.status == .cancelled }
        #expect(await fixture.executor.requests.map(\.runID) == [first.id])
        #expect(await fixture.executor.cancellationIDs.isEmpty, "Never-started queue cancellation must stay local")
        #expect(fixture.store.snapshot.runs.first { $0.id == next.id }?.status == .queued)
        await fixture.executor.complete(first.id)
        try await eventually { fixture.store.snapshot.runs.first { $0.id == next.id }?.status == .running }
        #expect(await fixture.executor.requests.map(\.runID) == [first.id, next.id])
        await fixture.executor.complete(next.id)
        try await eventually { fixture.store.activeRuns.isEmpty }
        #expect(await fixture.store.stopAllForTermination())
    }

    @Test func unavailableQueuedModelFailsBeforeStartAndDoesNotLockTheFollowingRequest() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let project = try await project(fixture)
        let first = try await startWriter(fixture, project: project)
        let (_, invalid) = try await queueTask(fixture, project: project, title: "Missing model",
                                               selection: .init(executor: .claude, modelID: "removed-model-version"))
        let (_, next) = try await queueTask(fixture, project: project, title: "Valid model after failure")

        await fixture.executor.complete(first.id)
        try await eventually {
            fixture.store.snapshot.runs.first { $0.id == invalid.id }?.status == .failed
                && fixture.store.snapshot.runs.first { $0.id == next.id }?.status == .running
        }
        #expect(await fixture.executor.requests.map(\.runID) == [first.id, next.id])
        #expect(fixture.store.snapshot.runs.first { $0.id == invalid.id }?.error?.contains("模型") == true)
        #expect(fixture.store.snapshot.messages.contains { $0.runID == invalid.id && $0.role == .system })
        #expect(fixture.store.error == nil, "Automatic queue failures should remain attached to their run")
        await fixture.executor.complete(next.id)
        try await eventually { fixture.store.activeRuns.isEmpty }
        #expect(await fixture.store.stopAllForTermination())
    }

    @Test func reopeningPreservesQueueUntilPreviousWriterRecoveryIsConfirmedThenStartsOnce() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let repository = try fixture.repository
        let project = try await project(fixture)
        let conversation = try await repository.createConversation(projectID: project.id, title: "Previous application writer")
        let previous = try await repository.prepareRun(conversationID: conversation.id, prompt: "Persisted old request")
        try await repository.markRunStarted(id: previous.id, sessionID: "old-fixture-session", processID: 0)
        let task = try await repository.createTask(projectID: project.id, title: "Authorized before restart")
        let queued = try await repository.prepareRun(conversationID: task.mainConversationID,
                                                      prompt: "Continue this authorized queued task", directImplementation: true)
        #expect(queued.status == .queued)
        // No consumer from the original app remains alive in this simulated persisted state.
        let reopened = AppStore(dataDirectory: fixture.store.dataDirectory, executors: fixture.executor)
        await reopened.boot()
        try await eventually { !reopened.refreshingExecutors }
        #expect(reopened.snapshot.runs.first { $0.id == previous.id }?.status == .recoveryRequired)
        #expect(reopened.snapshot.runs.first { $0.id == queued.id }?.status == .queued)
        #expect(await fixture.executor.requests.isEmpty)

        reopened.recoverRun(previous.id)
        try await eventually { reopened.snapshot.runs.first { $0.id == queued.id }?.status == .running }
        #expect(reopened.snapshot.runs.first { $0.id == previous.id }?.status == .cancelled)
        #expect(await fixture.executor.verifiedRecoveryIDs == [previous.id])
        #expect(await fixture.executor.requests.map(\.runID) == [queued.id])
        reopened.recoverRun(previous.id)
        try await reopened.reload()
        await fixture.executor.complete(queued.id)
        try await eventually { reopened.activeRuns.isEmpty }
        try await reopened.reload()
        #expect(await fixture.executor.requests.map(\.runID) == [queued.id])
        #expect(await fixture.executor.verifiedRecoveryIDs == [previous.id])
        #expect(await reopened.stopAllForTermination())
    }

    @Test func terminationStopsCurrentWriterAndLeavesQueueDurableWithoutStartingIt() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let project = try await project(fixture)
        let first = try await startWriter(fixture, project: project)
        let (_, queued) = try await queueTask(fixture, project: project, title: "Resume on next application launch")

        #expect(await fixture.store.stopAllForTermination())
        try await fixture.store.reload()
        #expect(await fixture.executor.requests.map(\.runID) == [first.id])
        #expect(await fixture.executor.cancellationIDs == [first.id])
        #expect(fixture.store.snapshot.runs.first { $0.id == first.id }?.status == .cancelled)
        #expect(fixture.store.snapshot.runs.first { $0.id == queued.id }?.status == .queued)
        #expect(try await fixture.repository.run(id: queued.id).status == .queued)
    }

    @Test func terminationDuringDequeuedPreflightReturnsRequestToQueueWithoutExecutorHandoff() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        defer { Task { await fixture.executor.releaseProbe() } }
        let project = try await project(fixture)
        let first = try await startWriter(fixture, project: project)
        let (_, queued) = try await queueTask(fixture, project: project, title: "Claimed while shutdown begins")
        await fixture.executor.holdNextProbe()
        await fixture.executor.complete(first.id)
        try await eventually { await fixture.executor.probeWaiting }
        #expect(try await fixture.repository.run(id: queued.id).status == .starting)
        #expect(await fixture.executor.requests.map(\.runID) == [first.id])

        // The same-actor call sets termination before suspending on the queued preflight.
        // This release task can only continue once that suspension lets the actor run it.
        let release = Task { @MainActor in
            await Task.yield()
            await fixture.executor.releaseProbe()
        }
        #expect(await fixture.store.stopAllForTermination())
        await release.value
        try await fixture.store.reload()
        let preserved = try await fixture.repository.run(id: queued.id)
        #expect(preserved.status == .queued)
        #expect(preserved.processID == nil && preserved.executorSessionID == nil)
        #expect(preserved.effectiveModelID == nil && preserved.effectivePolicy == nil)
        #expect(preserved.endedAt == nil && preserved.output.isEmpty)
        #expect(await fixture.executor.requests.map(\.runID) == [first.id])
        #expect(await fixture.executor.cancellationIDs.isEmpty, "The dequeued preflight never reached an executor")
        #expect(!fixture.store.snapshot.runs.contains { $0.status == .recoveryRequired })
        #expect(fixture.store.error == nil)
    }

    @Test func stageChangeCancelsQueuedIntentWithoutStartingItWhenWriterFinishes() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let project = try await project(fixture)
        let first = try await startWriter(fixture, project: project)
        let (task, queued) = try await queueTask(fixture, project: project, title: "Move queued task back to pending")

        fixture.store.transitionTask(task.id, to: .backlog)
        try await eventually {
            fixture.store.snapshot.tasks.first { $0.id == task.id }?.phase == .backlog
                && fixture.store.snapshot.runs.first { $0.id == queued.id }?.status == .cancelled
                && !fixture.store.changingTasks.contains(task.id)
        }
        #expect(await fixture.executor.requests.map(\.runID) == [first.id])
        #expect(await fixture.executor.cancellationIDs.isEmpty)
        await fixture.executor.complete(first.id)
        try await eventually { fixture.store.activeRuns.isEmpty }
        try await fixture.store.reload()
        #expect(await fixture.executor.requests.map(\.runID) == [first.id])
        #expect(try await fixture.repository.task(id: task.id).phase == .backlog)
        #expect(try await fixture.repository.run(id: queued.id).status == .cancelled)
        #expect(!fixture.store.snapshot.runs.contains { $0.status == .recoveryRequired })
        #expect(fixture.store.error == nil)
        #expect(await fixture.store.stopAllForTermination())
    }

    @Test func taskWorktreeUsesCommittedBaselineAndRunsAlongsideMainDirectoryWithItsOwnDiff() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let repository = try fixture.repository
        let project = try await project(fixture, committed: true)
        let root = URL(fileURLWithPath: project.path, isDirectory: true)
        try Data("MAIN_DIRECTORY_UNCOMMITTED\n".utf8).write(to: root.appendingPathComponent("fixture.txt"))
        let task = try await repository.createTask(projectID: project.id, title: "Independent task checkout")
        try await fixture.store.reload(); fixture.store.selectTask(task.id)

        fixture.store.setTaskWorktree(task.id, enabled: true)
        try await eventually {
            fixture.store.snapshot.tasks.first { $0.id == task.id }?.worktreePath != nil
                && !fixture.store.changingTasks.contains(task.id)
        }
        let worktree = try #require(fixture.store.snapshot.tasks.first { $0.id == task.id }?.worktreePath)
        #expect(try GitRepository.isWorktree(path: worktree, of: project.path))
        #expect(worktree != project.path)
        #expect(try String(contentsOfFile: worktree + "/fixture.txt", encoding: .utf8) == "committed baseline\n")
        #expect(try String(contentsOf: root.appendingPathComponent("fixture.txt"), encoding: .utf8) == "MAIN_DIRECTORY_UNCOMMITTED\n")
        #expect(try GitRepository.head(path: worktree) == GitRepository.head(path: project.path))

        let main = try await startWriter(fixture, project: project)
        fixture.store.selectTask(task.id)
        fixture.store.implementTaskDirectly(task.id)
        try await eventually { fixture.store.snapshot.runs.contains { $0.taskID == task.id && $0.status == .running } }
        let independent = try #require(fixture.store.snapshot.runs.first { $0.taskID == task.id })
        let request = try #require(await fixture.executor.requests.first { $0.runID == independent.id })
        #expect(request.projectPath == worktree && independent.cwd == worktree)
        #expect(request.phase == .development && !request.readOnly)
        #expect(fixture.store.snapshot.runs.first { $0.id == main.id }?.status == .running)
        #expect(fixture.store.activeRuns.count == 2, "Independent physical directories can run in parallel")

        try Data("WORKTREE_ONLY_CHANGE\n".utf8).write(to: URL(fileURLWithPath: worktree).appendingPathComponent("fixture.txt"))
        fixture.store.loadChanges(taskID: task.id)
        try await eventually { fixture.store.selectedTaskDiff.contains("WORKTREE_ONLY_CHANGE") }
        #expect(!fixture.store.selectedTaskDiff.contains("MAIN_DIRECTORY_UNCOMMITTED"))
        #expect(fixture.store.error == nil)
        await fixture.executor.complete(main.id)
        await fixture.executor.complete(independent.id)
        try await eventually { fixture.store.activeRuns.isEmpty }

        fixture.store.setTaskWorktree(task.id, enabled: false)
        try await eventually {
            fixture.store.snapshot.tasks.first { $0.id == task.id }?.worktreePath == nil
                && !fixture.store.changingTasks.contains(task.id)
        }
        try await eventually { fixture.store.selectedTaskDiff.contains("MAIN_DIRECTORY_UNCOMMITTED") }
        #expect(FileManager.default.fileExists(atPath: worktree + "/fixture.txt"), "Switching to the project directory must preserve the independent checkout and its edits")
        #expect(try String(contentsOfFile: worktree + "/fixture.txt", encoding: .utf8) == "WORKTREE_ONLY_CHANGE\n")
        #expect(await fixture.store.stopAllForTermination())
    }
}
