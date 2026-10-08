import Foundation
import Testing
import AgentKanbanCore
import AgentKanbanExecutors
@testable import AgentKanban

enum PlanConfirmationFailure: String, CaseIterable, Sendable {
    case authentication, startup
    var detail: String { "Controlled plan confirmation \(rawValue) failure" }
}

enum PlanConfirmationBlocker: String, CaseIterable, Sendable {
    case directoryWriter, directoryReader, taskActive, recoveryRequired, stageBarrier
}

enum InvalidPlanConfirmation: String, CaseIterable, Sendable {
    case missingRevision, missingCriteria, alreadyConfirmed, completed
}

/// Every executor probe and launch is local and controlled; this fixture never runs a model CLI.
private actor PlanConfirmationExecutor: ExecutorService {
    private(set) var requests: [ExecutorRequest] = []
    private var failure: PlanConfirmationFailure?
    private var hold = false
    private var continuations: [String: AsyncStream<ExecutorEvent>.Continuation] = [:]
    private var pauseProbe = false
    private var probeContinuation: CheckedContinuation<Void, Never>?
    private(set) var probeWaiting = false

    init(failure: PlanConfirmationFailure? = nil) { self.failure = failure }
    func setFailure(_ failure: PlanConfirmationFailure?) { self.failure = failure }
    func setHold() { hold = true }
    func setPauseProbe() { pauseProbe = true }
    func releaseProbe() {
        pauseProbe = false; probeWaiting = false
        probeContinuation?.resume(); probeContinuation = nil
    }
    func probe(_ executor: ExecutorID) async -> ExecutorInstallation {
        await Task.yield()
        if pauseProbe {
            await withCheckedContinuation { continuation in
                probeContinuation = continuation; probeWaiting = true
            }
        }
        return .init(id: executor, authentication: failure == .authentication ? .unauthenticated : .authenticated,
                     detail: failure == .authentication ? PlanConfirmationFailure.authentication.detail : "Controlled fixture")
    }
    func models(_ executor: ExecutorID) async throws -> [ExecutorModel] {
        [.init(id: "fixture-model", displayName: "Fixture model", efforts: ["low", "high"], verified: true)]
    }
    func start(_ request: ExecutorRequest) async throws -> ExecutorRun {
        requests.append(request)
        if failure == .startup { throw KanbanError.invalid(PlanConfirmationFailure.startup.detail) }
        let pair = AsyncStream<ExecutorEvent>.makeStream()
        continuations[request.runID] = pair.continuation
        pair.continuation.yield(.started(sessionID: "confirmed-fixture-\(request.runID)", processID: 0,
                                         modelID: request.selection.modelID, effectivePolicy: "Controlled fixture policy"))
        if !hold {
            pair.continuation.yield(.completed(output: "Controlled implementation completed; no project files changed."))
            pair.continuation.finish()
        }
        return .init(id: request.runID, events: pair.stream)
    }
    func respond(runID: String, approvalID: String, decision: ApprovalDecision) async throws {}
    func cancel(runID: String) async -> CancellationResult {
        continuations[runID]?.yield(.cancelled)
        continuations[runID]?.finish()
        return .confirmed
    }
}

@Suite("Human plan confirmation starts implementation", .serialized) @MainActor
struct PlanConfirmationTests {
    @MainActor private struct Fixture {
        let directory: URL
        let store: AppStore
        let executor: PlanConfirmationExecutor
        var repository: Repository { get throws { try #require(store.repository) } }
    }

    private func fixture(failure: PlanConfirmationFailure? = nil) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kanban-confirm-plan-\(UUID().uuidString)", isDirectory: true)
        let executor = PlanConfirmationExecutor(failure: failure)
        return .init(directory: directory,
                     store: AppStore(dataDirectory: directory.appendingPathComponent("data"), executors: executor),
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
        try #require(try await condition(), "The controlled plan confirmation did not finish")
    }

    private func attachment(_ fixture: Fixture, name: String) throws -> AgentKanbanCore.Attachment {
        let path = fixture.directory.appendingPathComponent(name)
        let bytes = Data("Controlled attachment: \(name)".utf8)
        try bytes.write(to: path)
        return .init(name: name, path: path.path, byteCount: bytes.count)
    }

    private func discussionTask(_ fixture: Fixture, project: Project, title: String = "确认后开发") async throws -> TaskItem {
        let repository = try fixture.repository
        let task = try await repository.createTask(projectID: project.id, title: title, description: "保留任务说明和已有行为")
        try await repository.transitionTask(id: task.id, to: .discussion)
        return try await repository.task(id: task.id)
    }

    private func revision(_ fixture: Fixture, task: TaskItem, plan: String = "局部修复并验证结果", criteria: [String] = ["保留原有行为"]) async throws -> RequirementRevision {
        try await fixture.repository.saveRevision(taskID: task.id, requirement: task.description, plan: plan, acceptanceCriteria: criteria)
    }

    @Test func oneConfirmationStartsDevelopmentWithConfirmedVersionLatestNoteAndAttachments() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let repository = try fixture.repository
        let project = try await project(fixture)
        let specification = try attachment(fixture, name: "task-spec.txt")
        let reference = try attachment(fixture, name: "note-reference.txt")
        let task = try await repository.createTask(projectID: project.id, title: "确认后立即修复", description: "按当前任务说明修复\n保留键盘快捷键", attachments: [specification])
        try await repository.transitionTask(id: task.id, to: .discussion)
        let discussion = try await repository.prepareRun(conversationID: task.mainConversationID, prompt: "分析方案")
        let plan = "统一局部边距。历史讨论原文：本次仅做分析，保留在讨论阶段。"
        try await repository.finishRun(id: discussion.id, status: .succeeded, output: plan, stopConfirmed: true)
        let reply = try await repository.appendMessage(conversationID: task.mainConversationID, role: .assistant, content: plan,
                                                       runID: discussion.id, id: "reply-\(discussion.id)")
        let note = try await repository.appendMessage(conversationID: task.mainConversationID, role: .user,
                                                      content: "最新备注：只修改任务表单，保留会话默认行为。", attachments: [reference])
        let revision = try await repository.saveRevision(taskID: task.id, requirement: task.description, plan: plan,
                                                        acceptanceCriteria: ["任务表单基线一致"], sourceMessageID: reply.id, sourceRunID: discussion.id)
        try await fixture.store.reload(); fixture.store.selectTask(task.id)

        fixture.store.confirmRevision(taskID: task.id)

        try await eventually {
            fixture.store.snapshot.runs.contains { $0.phase == .development && $0.status == .succeeded }
                && !fixture.store.changingTasks.contains(task.id)
        }
        let request = try #require(await fixture.executor.requests.first)
        let state = try await repository.snapshot()
        let run = try #require(state.runs.first { $0.id == request.runID })
        let current = try await repository.task(id: task.id)
        let confirmed = try #require(state.revisions.first { $0.id == revision.id })
        #expect(await fixture.executor.requests.count == 1)
        #expect(current.phase == .development && current.currentRevisionID == revision.id)
        #expect(current.directImplementationPhaseVersion == nil)
        #expect(confirmed.confirmedAt != nil && confirmed.plan == plan)
        #expect(confirmed.sourceMessageID == reply.id && confirmed.sourceRunID == discussion.id)
        #expect(run.phase == .development && run.writing && run.revisionID == revision.id)
        #expect(run.taskID == task.id && run.conversationID == task.mainConversationID && run.cwd == project.path)
        #expect(request.phase == .development && !request.readOnly && request.sessionID == nil)
        #expect(request.prompt.contains(task.title) && request.prompt.contains(task.description))
        #expect(request.prompt.contains(plan) && request.prompt.contains(note.content))
        #expect(Set(request.attachments.map(\.path)) == [specification.path, reference.path])
        let explicitRequest = try #require(request.prompt.components(separatedBy: "本次请求：").last)
        #expect(explicitRequest.contains("实施"), "Confirmation must expressly authorize implementation despite historical analysis-only text")
        #expect(explicitRequest.contains("实际变更") && explicitRequest.contains("验证"))
        #expect(state.revisions.count == 1 && state.reports.isEmpty)
        #expect(state.messages.contains { $0.id == note.id })
    }

    @Test func repeatedConfirmationCannotLaunchAgainDuringOrAfterImplementation() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let repository = try fixture.repository
        let project = try await project(fixture)
        let task = try await discussionTask(fixture, project: project)
        let revision = try await revision(fixture, task: task)
        await fixture.executor.setHold()
        try await fixture.store.reload(); fixture.store.selectTask(task.id)

        fixture.store.confirmRevision(taskID: task.id)
        fixture.store.confirmRevision(taskID: task.id)
        do {
            try await eventually {
                let state = try await repository.snapshot()
                try await fixture.store.reload()
                return state.runs.first?.status == .running && !fixture.store.changingTasks.contains(task.id)
            }
        } catch {
            let state = try await repository.snapshot()
            let starts = await fixture.executor.requests.count
            throw KanbanError.invalid("Duplicate-confirmation launch checkpoint: status=\(state.runs.first?.status.rawValue ?? "none"), starts=\(starts), changing=\(fixture.store.changingTasks.contains(task.id))")
        }
        let confirmedAt = try #require(fixture.store.snapshot.revisions.first?.confirmedAt)
        fixture.store.confirmRevision(taskID: task.id)
        try await eventually {
            try await fixture.store.reload()
            return !fixture.store.changingTasks.contains(task.id)
        }
        let duringImplementation = try await repository.snapshot()
        let run = try #require(duringImplementation.runs.first)
        #expect(await fixture.executor.requests.count == 1)
        #expect(duringImplementation.runs.count == 1 && run.revisionID == revision.id)
        #expect(await fixture.store.stopAllForTermination())
        do {
            try await eventually {
                let state = try await repository.snapshot()
                try await fixture.store.reload()
                return state.runs.first?.status.isTerminal == true
            }
        } catch {
            let state = try await repository.snapshot()
            throw KanbanError.invalid("Duplicate-confirmation stop checkpoint: status=\(state.runs.first?.status.rawValue ?? "none")")
        }

        fixture.store.confirmRevision(taskID: task.id)
        try await eventually {
            try await fixture.store.reload()
            return !fixture.store.changingTasks.contains(task.id)
        }
        let afterImplementation = try await repository.snapshot()
        #expect(await fixture.executor.requests.count == 1)
        #expect(afterImplementation.runs.count == 1)
        #expect(afterImplementation.revisions.first?.confirmedAt == confirmedAt)
        #expect(try await repository.task(id: task.id).phase == .development)
        #expect(afterImplementation.reports.isEmpty)
    }

    @Test func newPlanConfirmedDuringDevelopmentStartsFreshSessionWithAllSavedContext() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let repository = try fixture.repository
        let project = try await project(fixture)
        let task = try await discussionTask(fixture, project: project)
        let originalRevision = try await revision(fixture, task: task, plan: "上次已确认方案")
        try await repository.confirmRevision(id: originalRevision.id)
        try await repository.transitionTask(id: task.id, to: .development)
        let earlierAttachment = try attachment(fixture, name: "earlier-note.txt")
        let earlierNote = try await repository.appendMessage(conversationID: task.mainConversationID, role: .user,
                                                             content: "上次会话保存的上下文仍要保留", attachments: [earlierAttachment])
        let previous = try await repository.prepareRun(conversationID: task.mainConversationID, prompt: "实施上次方案")
        try await repository.markRunStarted(id: previous.id, sessionID: "prior-development-session", processID: 0)
        try await repository.finishRun(id: previous.id, status: .succeeded, output: "上次开发的实际变更", stopConfirmed: true)
        let previousReply = try await repository.appendMessage(conversationID: task.mainConversationID, role: .assistant,
                                                               content: "上次开发的实际变更", runID: previous.id, id: "reply-\(previous.id)")
        let newRevision = try await revision(fixture, task: task, plan: "本次修复新的边界情况")
        let latestAttachment = try attachment(fixture, name: "latest-note.txt")
        let latestNote = try await repository.appendMessage(conversationID: task.mainConversationID, role: .user,
                                                            content: "最新备注：按新方案继续修复", attachments: [latestAttachment])
        let before = try await repository.task(id: task.id)
        try await fixture.store.reload(); fixture.store.selectTask(task.id)

        fixture.store.confirmRevision(taskID: task.id)

        try await eventually { fixture.store.snapshot.runs.count == 2 && fixture.store.snapshot.runs.first?.status == .succeeded }
        let request = try #require(await fixture.executor.requests.first)
        let run = try #require(fixture.store.snapshot.runs.first { $0.id == request.runID })
        #expect(request.sessionID == nil, "A newly confirmed plan must not resume the previous development session")
        #expect(run.revisionID == newRevision.id && run.phaseVersion == before.phaseVersion)
        #expect(request.prompt.contains(earlierNote.content) && request.prompt.contains(latestNote.content))
        #expect(request.prompt.contains(previousReply.content) && request.prompt.contains(newRevision.plan))
        #expect(Set(request.attachments.map(\.path)) == [earlierAttachment.path, latestAttachment.path])
        #expect(fixture.store.snapshot.revisions.count == 2)
        #expect(fixture.store.snapshot.revisions.allSatisfy { $0.confirmedAt != nil })
        #expect(try await repository.task(id: task.id).phase == .development)
        #expect(fixture.store.snapshot.reports.isEmpty)
    }

    @Test(arguments: PlanConfirmationBlocker.allCases)
    func directoryContentionQueuesButTaskAndStageBlockersPreserveTheOriginalState(_ blocker: PlanConfirmationBlocker) async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let repository = try fixture.repository
        let project = try await project(fixture)
        let task = try await discussionTask(fixture, project: project)
        _ = try await revision(fixture, task: task)
        var blockingRun: RunRecord?
        switch blocker {
        case .directoryWriter:
            let conversation = try await repository.createConversation(projectID: project.id)
            blockingRun = try await repository.prepareRun(conversationID: conversation.id, prompt: "Controlled other writer")
        case .directoryReader:
            let otherTask = try await discussionTask(fixture, project: project, title: "另一个只读任务")
            blockingRun = try await repository.prepareRun(conversationID: otherTask.mainConversationID, prompt: "Controlled directory reader")
        case .taskActive, .recoveryRequired:
            blockingRun = try await repository.prepareRun(conversationID: task.mainConversationID, prompt: "Controlled active task discussion")
            if blocker == .recoveryRequired, let blockingRun {
                try await repository.finishRun(id: blockingRun.id, status: .failed, stopConfirmed: false)
            }
        case .stageBarrier:
            try await repository.beginStageChange(taskID: task.id)
        }
        try await fixture.store.reload(); fixture.store.selectTask(task.id)
        let before = try await repository.snapshot()

        fixture.store.confirmRevision(taskID: task.id)

        try await eventually { !fixture.store.changingTasks.contains(task.id) && !fixture.store.sendingConversations.contains(task.mainConversationID) }
        let after = try await repository.snapshot()
        if blocker == .directoryWriter || blocker == .directoryReader {
            let current = try #require(after.tasks.first { $0.id == task.id })
            let queued = try #require(after.runs.first { $0.taskID == task.id })
            #expect(current.phase == .development && current.phaseVersion == task.phaseVersion + 1)
            #expect(after.revisions.first { $0.id == current.currentRevisionID }?.confirmedAt != nil)
            #expect(queued.status == .queued && queued.cwd == project.path && queued.writing)
            #expect(queued.revisionID == current.currentRevisionID)
            #expect(after.runs.count == before.runs.count + 1)
            #expect(after.messages.contains { $0.runID == queued.id && $0.role == .user && $0.content.contains("确认方案并开始开发") })
            #expect(fixture.store.error == nil)
        } else {
            #expect(after.tasks == before.tasks, "A rejected confirmation must preserve phase, version and current plan")
            #expect(after.revisions == before.revisions, "A task or stage blocker must not leave a confirmed version")
            #expect(after.runs == before.runs && after.messages == before.messages)
        }
        #expect(after.reports == before.reports)
        #expect(await fixture.executor.requests.isEmpty)
        #expect(await fixture.store.stopAllForTermination())
        if let blockingRun { try await repository.finishRun(id: blockingRun.id, status: .cancelled, stopConfirmed: true) }
        if blocker == .stageBarrier { try await repository.abandonStageChange(taskID: task.id) }
    }

    @Test(arguments: PlanConfirmationFailure.allCases)
    func launchFailuresKeepConfirmedDevelopmentAndAllowExplicitRetry(_ failure: PlanConfirmationFailure) async throws {
        let fixture = try fixture(failure: failure)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let repository = try fixture.repository
        let project = try await project(fixture)
        let task = try await discussionTask(fixture, project: project)
        let revision = try await revision(fixture, task: task)
        try await fixture.store.reload(); fixture.store.selectTask(task.id)

        fixture.store.confirmRevision(taskID: task.id)

        try await eventually {
            fixture.store.snapshot.runs.first?.status == .failed && fixture.store.error != nil && !fixture.store.changingTasks.contains(task.id)
        }
        let failed = try #require(fixture.store.snapshot.runs.first)
        let current = try await repository.task(id: task.id)
        #expect(current.phase == .development && current.directImplementationPhaseVersion == nil)
        #expect(failed.writing && failed.phase == .development && failed.revisionID == revision.id)
        #expect(failed.error?.contains(failure.detail) == true)
        #expect(fixture.store.snapshot.revisions.first?.confirmedAt != nil)
        let failedStartCount = failure == .authentication ? 0 : 1
        #expect(await fixture.executor.requests.count == failedStartCount)

        await fixture.executor.setFailure(nil)
        let reopened = AppStore(dataDirectory: fixture.store.dataDirectory, executors: fixture.executor)
        await reopened.boot()
        try await eventually { !reopened.refreshingExecutors }
        #expect(reopened.snapshot.runs.count == 1 && reopened.snapshot.runs.first?.id == failed.id)
        #expect(await fixture.executor.requests.count == failedStartCount, "Reopening must not replay the failed request")
        reopened.selectTask(task.id)
        #expect(reopened.sendMessage("继续实施已确认方案，汇报实际变更和验证结果", attachments: []))
        try await eventually {
            reopened.snapshot.runs.count == 2 && reopened.snapshot.runs.first?.status == .succeeded
                && !reopened.sendingConversations.contains(task.mainConversationID)
        }
        let retry = try #require(reopened.snapshot.runs.first)
        #expect(retry.revisionID == revision.id && retry.phaseVersion == failed.phaseVersion && retry.writing)
        #expect(await fixture.executor.requests.count == failedStartCount + 1, "A new successful reservation proves the failed launch released its directory lease")
        #expect(reopened.snapshot.runs.contains { $0.id == failed.id && $0.status == .failed })
        #expect(reopened.snapshot.tasks.first?.phase == .development && reopened.snapshot.reports.isEmpty)
    }

    @Test(arguments: InvalidPlanConfirmation.allCases)
    func invalidOrPreviouslyConfirmedPlansDoNotLaunch(_ invalid: InvalidPlanConfirmation) async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let repository = try fixture.repository
        let project = try await project(fixture)
        let task = try await discussionTask(fixture, project: project)
        if invalid != .missingRevision {
            let revision = try await revision(fixture, task: task, criteria: invalid == .missingCriteria ? [] : ["保留原有行为"])
            if invalid == .alreadyConfirmed { try await repository.confirmRevision(id: revision.id) }
        }
        if invalid == .completed { try await repository.completeTask(id: task.id) }
        try await fixture.store.reload(); fixture.store.selectTask(task.id)
        let before = try await repository.snapshot()

        fixture.store.confirmRevision(taskID: task.id)

        try await eventually { !fixture.store.changingTasks.contains(task.id) }
        let after = try await repository.snapshot()
        #expect(after.tasks == before.tasks && after.revisions == before.revisions)
        #expect(after.runs.isEmpty && after.reports.isEmpty)
        #expect(await fixture.executor.requests.isEmpty)
    }

    @Test func reservedSelectionAndTargetSurviveAnotherTaskBeingSelectedWhileStarting() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        defer { Task { await fixture.executor.releaseProbe() } }
        let repository = try fixture.repository
        let targetProject = try await project(fixture, name: "target", executor: .claude)
        let otherProject = try await project(fixture, name: "other", executor: .cursor)
        let task = try await discussionTask(fixture, project: targetProject)
        let revision = try await revision(fixture, task: task)
        let chosen = ExecutionSelection(executor: .codex, modelID: "fixture-model", effort: "high", permission: .requestApproval)
        try await repository.updateSelection(conversationID: task.mainConversationID, selection: chosen)
        let other = try await discussionTask(fixture, project: otherProject, title: "其他项目禁止串入")
        let otherNote = try await repository.appendMessage(conversationID: other.mainConversationID, role: .user, content: "OTHER_PROJECT_CONTEXT_ONLY")
        await fixture.executor.setPauseProbe()
        try await fixture.store.reload(); fixture.store.selectTask(task.id)

        fixture.store.confirmRevision(taskID: task.id)
        fixture.store.selectTask(other.id)
        try await eventually { await fixture.executor.probeWaiting }
        try await repository.updateSelection(conversationID: task.mainConversationID,
                                             selection: .init(executor: .cursor, modelID: "fixture-model", effort: "low", permission: .fullAccess))
        await fixture.executor.releaseProbe()

        try await eventually { fixture.store.snapshot.runs.first?.status == .succeeded && !fixture.store.changingTasks.contains(task.id) }
        let request = try #require(await fixture.executor.requests.first)
        let run = try #require(fixture.store.snapshot.runs.first)
        #expect(request.selection == chosen && run.selection == chosen)
        #expect(request.projectPath == targetProject.path && request.conversationID == task.mainConversationID)
        #expect(run.taskID == task.id && run.projectID == targetProject.id && run.revisionID == revision.id)
        #expect(!request.prompt.contains(otherNote.content) && !request.prompt.contains(other.title))
        #expect(fixture.store.selectedTaskID == other.id)
        #expect(try await repository.task(id: other.id).phase == .discussion)
        #expect(fixture.store.snapshot.runs.count == 1 && fixture.store.snapshot.reports.isEmpty)
    }
}
