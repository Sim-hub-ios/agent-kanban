import Foundation
import Testing
import AgentKanbanCore
import AgentKanbanExecutors
@testable import AgentKanban

enum DirectImplementationFailure: String, CaseIterable, Sendable {
    case authentication, startup
    var detail: String { "Fixture direct implementation \(rawValue) failed" }
}

/// No external executors or account access. Every launch and probe is controlled by this fixture.
private actor DirectImplementationExecutor: ExecutorService {
    private(set) var requests: [ExecutorRequest] = []
    private var failure: DirectImplementationFailure?
    init(failure: DirectImplementationFailure? = nil) { self.failure = failure }
    func setFailure(_ failure: DirectImplementationFailure?) { self.failure = failure }
    func probe(_ executor: ExecutorID) async -> ExecutorInstallation {
        await Task.yield()
        return .init(id: executor, authentication: failure == .authentication ? .unauthenticated : .authenticated,
                     detail: failure == .authentication ? DirectImplementationFailure.authentication.detail : "Controlled direct implementation fixture")
    }
    func models(_ executor: ExecutorID) async throws -> [ExecutorModel] {
        [.init(id: "fixture-model", displayName: "Fixture model", efforts: ["low", "high"], verified: true)]
    }
    func start(_ request: ExecutorRequest) async throws -> ExecutorRun {
        requests.append(request)
        if failure == .startup { throw KanbanError.invalid(DirectImplementationFailure.startup.detail) }
        let pair = AsyncStream<ExecutorEvent>.makeStream()
        pair.continuation.yield(.started(sessionID: "direct-fixture-\(request.runID)", processID: 0,
                                         modelID: request.selection.modelID, effectivePolicy: "Fixture policy"))
        pair.continuation.yield(.completed(output: "Controlled implementation completed; no project files changed."))
        pair.continuation.finish()
        return .init(id: request.runID, events: pair.stream)
    }
    func respond(runID: String, approvalID: String, decision: ApprovalDecision) async throws {}
    func cancel(runID: String) async -> CancellationResult { .confirmed }
}

@Suite("Direct implementation application orchestration", .serialized) @MainActor
struct DirectImplementationTests {
    @MainActor private struct Fixture {
        let directory: URL
        let store: AppStore
        let executor: DirectImplementationExecutor
        var repository: Repository { get throws { try #require(store.repository) } }
    }

    private func fixture(failure: DirectImplementationFailure? = nil) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kanban-direct-app-\(UUID().uuidString)", isDirectory: true)
        let executor = DirectImplementationExecutor(failure: failure)
        return Fixture(directory: directory,
                       store: AppStore(dataDirectory: directory.appendingPathComponent("data", isDirectory: true), executors: executor),
                       executor: executor)
    }

    private func project(_ fixture: Fixture, name: String = "target", executor: ExecutorID = .claude) async throws -> Project {
        let path = fixture.directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["init", "-q", path.path]
        git.standardOutput = FileHandle.nullDevice; git.standardError = FileHandle.nullDevice
        try git.run(); git.waitUntilExit()
        try #require(git.terminationStatus == 0)
        return try await fixture.repository.importProject(path: path.path, name: name, defaultExecutor: executor)
    }

    private func eventually(_ condition: @MainActor () async throws -> Bool) async throws {
        for _ in 0..<250 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(try await condition(), "The controlled asynchronous operation did not complete")
    }

    private func attachment(_ fixture: Fixture, name: String, text: String) throws -> AgentKanbanCore.Attachment {
        let file = fixture.directory.appendingPathComponent(name)
        let bytes = Data(text.utf8)
        try bytes.write(to: file)
        return .init(name: name, path: file.path, byteCount: bytes.count)
    }

    @Test func savingBacklogTaskAndNotesDoesNotLaunchUntilUserChoosesDirectImplementation() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let repository = try fixture.repository
        let project = try await project(fixture)
        let task = try await repository.createTask(projectID: project.id, title: "Preserve backlog", description: "Only explicit direct implementation can launch")
        try await fixture.store.reload(); fixture.store.selectTask(task.id)
        #expect(fixture.store.sendMessage("Save this implementation note", attachments: []))
        try await eventually { fixture.store.snapshot.messages.count == 1 && !fixture.store.sendingConversations.contains(task.mainConversationID) }
        try await fixture.store.reload()
        #expect(await fixture.executor.requests.isEmpty)
        #expect(fixture.store.snapshot.runs.isEmpty)
        #expect(fixture.store.snapshot.tasks.first?.phase == .backlog)
        #expect(fixture.store.snapshot.tasks.first?.directImplementationPhaseVersion == nil)
        #expect(fixture.store.snapshot.revisions.isEmpty)
    }

    @Test func directImplementationCarriesRealTaskNotesAttachmentsAndProjectDefaultsWithoutInventingAPlan() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let repository = try fixture.repository
        let project = try await project(fixture)
        let specification = try attachment(fixture, name: "task-spec.txt", text: "Task fixture attachment")
        let reference = try attachment(fixture, name: "note-reference.txt", text: "Note fixture attachment")
        let task = try await repository.createTask(projectID: project.id, title: "Fix screenshot paste", description: "Line one\nPreserve existing editor text", attachments: [specification])
        let note = try await repository.appendMessage(conversationID: task.mainConversationID, role: .user,
                                                       content: "Keep the current keyboard shortcuts and attachment preview", attachments: [reference])
        try await fixture.store.reload(); fixture.store.selectTask(task.id)
        fixture.store.implementTaskDirectly(task.id)
        try await eventually { fixture.store.snapshot.runs.first?.status == .succeeded && !fixture.store.changingTasks.contains(task.id) }
        let request = try #require(await fixture.executor.requests.first)
        let run = try #require(fixture.store.snapshot.runs.first)
        let current = try await repository.task(id: task.id)
        #expect(await fixture.executor.requests.count == 1)
        #expect(run.taskID == task.id && run.projectID == project.id)
        #expect(run.conversationID == task.mainConversationID)
        #expect(run.phase == .development && run.writing)
        #expect(run.cwd == project.path && request.projectPath == project.path)
        #expect(request.phase == .development && !request.readOnly)
        #expect(request.selection == ExecutionSelection(executor: .claude))
        #expect(run.selection == request.selection)
        #expect(request.sessionID == nil)
        #expect(request.prompt.contains(task.title))
        #expect(request.prompt.contains(task.description))
        #expect(request.prompt.contains(note.content))
        #expect(Set(request.attachments.map(\.path)) == [specification.path, reference.path])
        #expect(request.attachments.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(current.phase == .development && current.phaseVersion == 1)
        #expect(current.directImplementationPhaseVersion == run.phaseVersion)
        #expect(current.currentRevisionID == nil && fixture.store.snapshot.revisions.isEmpty)
        let explicitRequest = try #require(fixture.store.snapshot.messages.first { $0.role == .user && $0.runID == run.id })
        #expect(explicitRequest.content.contains("直接") && explicitRequest.content.contains("跳过讨论"))
        #expect(fixture.store.snapshot.messages.contains { $0.id == note.id })
        #expect(fixture.store.snapshot.reports.isEmpty, "Implementation success must not imply acceptance or completion")

        // A later development cycle must bring new backlog notes, rather than resume the old native session.
        try await repository.transitionTask(id: task.id, to: .backlog)
        let latestAttachment = try attachment(fixture, name: "later-cycle.txt", text: "New development cycle fixture")
        let latestNote = try await repository.appendMessage(conversationID: task.mainConversationID, role: .user,
                                                            content: "Latest backlog note must be included in the new direct implementation", attachments: [latestAttachment])
        try await fixture.store.reload()
        fixture.store.implementTaskDirectly(task.id)
        try await eventually { fixture.store.snapshot.runs.count == 2 && fixture.store.snapshot.runs.first?.status == .succeeded }
        let next = try #require(await fixture.executor.requests.last)
        #expect(await fixture.executor.requests.count == 2)
        #expect(next.sessionID == nil, "The previous development executor session must not bypass the new backlog context")
        #expect(next.prompt.contains(latestNote.content))
        #expect(Set(next.attachments.map(\.path)) == [specification.path, reference.path, latestAttachment.path])
        #expect(fixture.store.snapshot.revisions.isEmpty)
    }

    @Test func selectedModelEffortAndPermissionAreFrozenIntoDirectRun() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let repository = try fixture.repository
        let project = try await project(fixture)
        let task = try await repository.createTask(projectID: project.id, title: "Retain selection")
        let chosen = ExecutionSelection(executor: .codex, modelID: "fixture-model", effort: "high", permission: .fullAccess)
        try await repository.updateSelection(conversationID: task.mainConversationID, selection: chosen)
        try await fixture.store.reload(); fixture.store.selectTask(task.id)
        fixture.store.implementTaskDirectly(task.id)
        try await eventually { fixture.store.snapshot.runs.first?.status == .succeeded }
        #expect(await fixture.executor.requests.first?.selection == chosen)
        #expect(fixture.store.snapshot.runs.first?.selection == chosen)
        #expect(try await repository.task(id: task.id).selection == chosen)
    }

    @Test func repeatedDirectClicksReserveAndLaunchExactlyOneRun() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let repository = try fixture.repository
        let project = try await project(fixture)
        let task = try await repository.createTask(projectID: project.id, title: "Double click")
        try await fixture.store.reload(); fixture.store.selectTask(task.id)
        fixture.store.implementTaskDirectly(task.id)
        fixture.store.implementTaskDirectly(task.id)
        try await eventually { fixture.store.snapshot.runs.first?.status == .succeeded && !fixture.store.changingTasks.contains(task.id) }
        // A delayed duplicate after completion also cannot reuse the backlog-only action.
        fixture.store.implementTaskDirectly(task.id)
        try await fixture.store.reload()
        #expect(await fixture.executor.requests.count == 1)
        #expect(fixture.store.snapshot.runs.count == 1)
        #expect(fixture.store.snapshot.messages.filter { $0.role == .user && $0.runID != nil }.count == 1)
        #expect(try await repository.task(id: task.id).phaseVersion == 1)
    }

    @Test func selectedOtherProjectCannotRedirectDirectImplementationOrLeakItsContext() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let repository = try fixture.repository
        let target = try await project(fixture, name: "target", executor: .claude)
        let other = try await project(fixture, name: "other", executor: .cursor)
        let task = try await repository.createTask(projectID: target.id, title: "Implement target project")
        let otherTask = try await repository.createTask(projectID: other.id, title: "Other task remains pending")
        try await repository.appendMessage(conversationID: otherTask.mainConversationID, role: .user, content: "Foreign context must not enter target request")
        try await fixture.store.reload(); fixture.store.selectTask(otherTask.id)
        #expect(fixture.store.selectedProjectID == other.id)
        fixture.store.implementTaskDirectly(task.id)
        try await eventually { fixture.store.snapshot.runs.first?.status == .succeeded }
        let request = try #require(await fixture.executor.requests.first)
        let run = try #require(fixture.store.snapshot.runs.first)
        #expect(run.projectID == target.id && run.taskID == task.id)
        #expect(run.cwd == target.path && request.projectPath == target.path)
        #expect(request.conversationID == task.mainConversationID)
        #expect(request.selection.executor == .claude)
        #expect(!request.prompt.contains("Foreign context"))
        #expect(try await repository.task(id: otherTask.id).phase == .backlog)
        #expect(try await repository.task(id: task.id).phase == .development)
        #expect(fixture.store.snapshot.runs.allSatisfy { $0.projectID == target.id })
    }

    @Test func directoryBusyKeepsAuthorizedDevelopmentVisibleAndQueuedWithoutLaunching() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let repository = try fixture.repository
        let project = try await project(fixture)
        let task = try await repository.createTask(projectID: project.id, title: "Wait for directory writer")
        let writer = try await repository.createConversation(projectID: project.id, title: "Existing writer")
        let blockingRun = try await repository.prepareRun(conversationID: writer.id, prompt: "Controlled existing directory reservation")
        try await fixture.store.reload(); fixture.store.selectTask(task.id)
        let originalMessages = fixture.store.snapshot.messages.filter { $0.conversationID == task.mainConversationID }
        fixture.store.implementTaskDirectly(task.id)
        try await eventually { fixture.store.snapshot.runs.contains { $0.taskID == task.id && $0.status == .queued } && !fixture.store.changingTasks.contains(task.id) }
        let current = try await repository.task(id: task.id)
        let queued = try #require(fixture.store.snapshot.runs.first { $0.taskID == task.id })
        #expect(current.phase == .development && current.phaseVersion == 1)
        #expect(current.directImplementationPhaseVersion == queued.phaseVersion)
        #expect(queued.status == .queued && queued.cwd == project.path && queued.writing)
        #expect(fixture.store.snapshot.runs.contains { $0.id == blockingRun.id })
        #expect(fixture.store.snapshot.messages.filter { $0.conversationID == task.mainConversationID }.count == originalMessages.count + 1)
        #expect(fixture.store.snapshot.messages.contains { $0.role == .user && $0.runID == queued.id && $0.content.contains("直接开发") })
        #expect(fixture.store.error == nil)
        #expect(await fixture.executor.requests.isEmpty)
        #expect(await fixture.store.stopAllForTermination())
        try await repository.finishRun(id: blockingRun.id, status: .cancelled, stopConfirmed: true)
    }

    @Test(arguments: DirectImplementationFailure.allCases)
    func authenticationAndStartupFailuresKeepVisibleFailedRunAndRequireExplicitChatRetry(_ failure: DirectImplementationFailure) async throws {
        let fixture = try fixture(failure: failure)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let repository = try fixture.repository
        let project = try await project(fixture)
        let task = try await repository.createTask(projectID: project.id, title: "Explicit recovery", description: "Implementation still requires the user's next request")
        try await fixture.store.reload(); fixture.store.selectTask(task.id)
        fixture.store.implementTaskDirectly(task.id)
        try await eventually { fixture.store.snapshot.runs.first?.status == .failed && fixture.store.error != nil && !fixture.store.changingTasks.contains(task.id) }
        let failed = try #require(fixture.store.snapshot.runs.first)
        let expectedFailedStarts = failure == .authentication ? 0 : 1
        #expect(failed.phase == .development && failed.writing)
        #expect(failed.error?.contains(failure.detail) == true)
        #expect(fixture.store.error?.contains(failure.detail) == true)
        #expect(try await repository.task(id: task.id).phase == .development)
        #expect(try await repository.task(id: task.id).directImplementationPhaseVersion == failed.phaseVersion)
        #expect(await fixture.executor.requests.count == expectedFailedStarts)
        #expect(fixture.store.snapshot.revisions.isEmpty)
        #expect(fixture.store.snapshot.messages.filter { $0.role == .user && $0.runID == failed.id }.count == 1)

        await fixture.executor.setFailure(nil)
        let reopened = AppStore(dataDirectory: fixture.store.dataDirectory, executors: fixture.executor)
        await reopened.boot()
        try await eventually { !reopened.refreshingExecutors }
        #expect(reopened.snapshot.runs.count == 1)
        #expect(reopened.snapshot.runs.first?.id == failed.id && reopened.snapshot.runs.first?.status == .failed)
        #expect(await fixture.executor.requests.count == expectedFailedStarts, "Opening the workspace must not replay a failed request")
        reopened.selectTask(task.id)
        #expect(reopened.sendMessage("继续实施这个任务，并验证结果", attachments: []))
        try await eventually { reopened.snapshot.runs.count == 2 && reopened.snapshot.runs.first?.status == .succeeded && !reopened.sendingConversations.contains(task.mainConversationID) }
        #expect(await fixture.executor.requests.count == expectedFailedStarts + 1)
        #expect(reopened.snapshot.runs.first?.phase == .development && reopened.snapshot.runs.first?.writing == true)
        #expect(reopened.snapshot.runs.first?.taskID == task.id)
        #expect(reopened.snapshot.runs.contains { $0.id == failed.id && $0.status == .failed })
        #expect(try await repository.task(id: task.id).phaseVersion == failed.phaseVersion)
        #expect(reopened.snapshot.revisions.isEmpty)
    }
}
