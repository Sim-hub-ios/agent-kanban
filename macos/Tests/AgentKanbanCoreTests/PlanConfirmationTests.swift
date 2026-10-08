import XCTest
@testable import AgentKanbanCore

@MainActor
final class PlanConfirmationTests: XCTestCase {
    private var directory: URL!
    private var databaseURL: URL!
    private var repository: Repository!
    private var project: Project!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-kanban-plan-confirmation-\(UUID().uuidString)")
        let working = directory.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", working.path, "init", "--quiet"]
        git.standardOutput = FileHandle.nullDevice; git.standardError = FileHandle.nullDevice
        try git.run(); git.waitUntilExit()
        XCTAssertEqual(git.terminationStatus, 0)
        databaseURL = directory.appendingPathComponent("data/workspace.sqlite")
        repository = try Repository(databaseURL: databaseURL)
        project = try await repository.importProject(path: working.path, defaultExecutor: .claude)
    }

    override func tearDown() async throws {
        repository = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func expectFailure(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Confirmation must be rejected", file: file, line: line) } catch { }
    }

    private func discussionTask(_ title: String = "确认后开始开发") async throws -> TaskItem {
        let task = try await repository.createTask(projectID: project.id, title: title, description: "任务说明与已有备注必须保留")
        try await repository.transitionTask(id: task.id, to: .discussion)
        return try await repository.task(id: task.id)
    }

    private func revision(_ task: TaskItem, plan: String = "局部修复流程", criteria: [String] = ["点击确认后调用开发执行器"]) async throws -> RequirementRevision {
        try await repository.saveRevision(taskID: task.id, requirement: task.description, plan: plan, acceptanceCriteria: criteria)
    }

    private func assertUnchanged(_ task: TaskItem, revision: RequirementRevision, runs: Int = 0, messages: Int = 0, file: StaticString = #filePath, line: UInt = #line) async throws {
        let state = try await repository.snapshot()
        let current = try XCTUnwrap(state.tasks.first { $0.id == task.id }, file: file, line: line)
        let saved = try XCTUnwrap(state.revisions.first { $0.id == revision.id }, file: file, line: line)
        XCTAssertEqual(current.phase, task.phase, file: file, line: line)
        XCTAssertEqual(current.phaseVersion, task.phaseVersion, file: file, line: line)
        XCTAssertNil(saved.confirmedAt, file: file, line: line)
        XCTAssertEqual(state.runs.count, runs, file: file, line: line)
        XCTAssertEqual(state.messages.count, messages, file: file, line: line)
        XCTAssertTrue(state.reports.isEmpty, file: file, line: line)
    }

    func testAtomicConfirmationReservesDevelopmentRunAndRecordsHumanAction() async throws {
        let task = try await discussionTask()
        let draft = try await revision(task)
        let note = try await repository.appendMessage(conversationID: task.mainConversationID, role: .user, content: "最新备注：保留输入框光标样式。")
        let selection = ExecutionSelection(executor: .cursor, modelID: "fixture-model", effort: "high", permission: .requestApproval)
        try await repository.updateSelection(conversationID: task.mainConversationID, selection: selection)
        let engine = TaskEngine(repository: repository)
        let prompt = "确认当前方案并立即实施，完成验证后报告实际结果。"
        let run = try await engine.confirmRevisionAndPrepareDevelopmentRun(id: draft.id, prompt: prompt)

        let state = try await repository.snapshot()
        let current = try XCTUnwrap(state.tasks.first { $0.id == task.id })
        let confirmed = try XCTUnwrap(state.revisions.first { $0.id == draft.id })
        XCTAssertNotNil(confirmed.confirmedAt)
        XCTAssertEqual(current.phase, .development)
        XCTAssertEqual(current.phaseVersion, task.phaseVersion + 1)
        XCTAssertEqual(current.currentRevisionID, draft.id)
        XCTAssertNil(current.directImplementationPhaseVersion)
        XCTAssertEqual(run.phase, .development)
        XCTAssertEqual(run.phaseVersion, current.phaseVersion)
        XCTAssertEqual(run.revisionID, draft.id)
        XCTAssertEqual(run.taskID, task.id)
        XCTAssertEqual(run.projectID, project.id)
        XCTAssertEqual(run.conversationID, task.mainConversationID)
        XCTAssertEqual(run.selection, selection)
        XCTAssertEqual(run.cwd, project.path)
        XCTAssertEqual(run.prompt, prompt)
        XCTAssertEqual(run.status, .starting)
        XCTAssertTrue(run.writing)
        XCTAssertEqual(state.runs.count, 1)
        XCTAssertEqual(state.messages.count, 2)
        XCTAssertTrue(state.messages.contains { $0.id == note.id && $0.content == note.content })
        let action = try XCTUnwrap(state.messages.first { $0.role == .user && $0.runID == run.id })
        XCTAssertEqual(action.conversationID, task.mainConversationID)
        XCTAssertTrue(action.content.contains("确认") && action.content.contains("开发"))
        XCTAssertTrue(state.reports.isEmpty, "Reserving implementation is not acceptance or task completion")
    }

    func testNewPlanWhileAlreadyDevelopingUsesCurrentRevisionWithoutDirectBypass() async throws {
        let task = try await repository.createTask(projectID: project.id, title: "直接开发后补充真实方案")
        let direct = try await repository.prepareRun(conversationID: task.mainConversationID, prompt: "直接开发", directImplementation: true)
        try await repository.finishRun(id: direct.id, status: .succeeded, stopConfirmed: true)
        let draft = try await revision(task)
        let before = try await repository.task(id: task.id)
        XCTAssertNil(before.directImplementationPhaseVersion)
        let run = try await repository.confirmRevisionAndPrepareDevelopmentRun(id: draft.id, prompt: "按新确认方案继续开发")
        let current = try await repository.task(id: task.id)
        XCTAssertEqual(current.phase, .development)
        XCTAssertEqual(current.phaseVersion, before.phaseVersion)
        XCTAssertEqual(run.phaseVersion, before.phaseVersion)
        XCTAssertEqual(run.revisionID, draft.id)
        XCTAssertNil(current.directImplementationPhaseVersion)
        XCTAssertTrue(run.writing)
    }

    func testWriterAndReadOnlyContentionQueueConfirmedDevelopment() async throws {
        for readOnly in [false, true] {
            let task = try await discussionTask()
            let draft = try await revision(task)
            let blocker: RunRecord
            if readOnly {
                let other = try await discussionTask("另一只读讨论")
                blocker = try await repository.prepareRun(conversationID: other.mainConversationID, prompt: "只读讨论")
            } else {
                let chat = try await repository.createConversation(projectID: project.id)
                blocker = try await repository.prepareRun(conversationID: chat.id, prompt: "其他会话写入")
            }
            let queued = try await repository.confirmRevisionAndPrepareDevelopmentRun(id: draft.id, prompt: "确认开发")
            let current = try await repository.task(id: task.id)
            let state = try await repository.snapshot()
            XCTAssertEqual(queued.status, .queued)
            XCTAssertEqual(queued.includeFullHistory, true)
            XCTAssertEqual(current.phase, .development)
            XCTAssertNotNil(state.revisions.first { $0.id == draft.id }?.confirmedAt)
            try await repository.finishRun(id: blocker.id, status: .succeeded, stopConfirmed: true)
            let claimed = try await repository.claimNextQueuedRun()
            XCTAssertEqual(claimed?.id, queued.id)
            try await repository.finishRun(id: queued.id, status: .succeeded, stopConfirmed: true)
        }
    }

    func testTaskActiveAndRecoveryRequiredRunsCannotBeConfirmedOrStoppedImplicitly() async throws {
        let task = try await discussionTask()
        let draft = try await revision(task)
        let discussion = try await repository.prepareRun(conversationID: task.mainConversationID, prompt: "仍在讨论")
        await expectFailure { _ = try await self.repository.confirmRevisionAndPrepareDevelopmentRun(id: draft.id, prompt: "确认开发") }
        try await assertUnchanged(task, revision: draft, runs: 1)
        let stillStarting = try await repository.run(id: discussion.id)
        XCTAssertEqual(stillStarting.status, .starting)
        try await repository.finishRun(id: discussion.id, status: .failed, stopConfirmed: false)
        await expectFailure { _ = try await self.repository.confirmRevisionAndPrepareDevelopmentRun(id: draft.id, prompt: "确认开发") }
        try await assertUnchanged(task, revision: draft, runs: 1)
        let uncertain = try await repository.run(id: discussion.id)
        XCTAssertEqual(uncertain.status, .recoveryRequired)
    }

    func testStageBarrierAndInvalidPromptLeavePlanAndTaskUnchanged() async throws {
        let task = try await discussionTask()
        let draft = try await revision(task)
        try await repository.beginStageChange(taskID: task.id)
        await expectFailure { _ = try await self.repository.confirmRevisionAndPrepareDevelopmentRun(id: draft.id, prompt: "确认开发") }
        try await assertUnchanged(task, revision: draft)
        try await repository.abandonStageChange(taskID: task.id)
        await expectFailure { _ = try await self.repository.confirmRevisionAndPrepareDevelopmentRun(id: draft.id, prompt: " \n") }
        try await assertUnchanged(task, revision: draft)
    }

    func testIncompletePlansAndStaleRevisionCannotBeConfirmedForDevelopment() async throws {
        let task = try await discussionTask()
        for (plan, criteria) in [("", ["真实验收项"]), ("真实方案", []), ("真实方案", [" \n"])] {
            let draft = try await revision(task, plan: plan, criteria: criteria)
            await expectFailure { _ = try await self.repository.confirmRevisionAndPrepareDevelopmentRun(id: draft.id, prompt: "确认开发") }
            try await assertUnchanged(task, revision: draft)
        }
        let stale = try await revision(task, plan: "旧版本")
        let current = try await revision(task, plan: "当前版本")
        await expectFailure { _ = try await self.repository.confirmRevisionAndPrepareDevelopmentRun(id: stale.id, prompt: "确认过期方案") }
        try await assertUnchanged(task, revision: stale)
        try await assertUnchanged(task, revision: current)
        let state = try await repository.snapshot()
        XCTAssertEqual(state.tasks.first?.currentRevisionID, current.id)
    }

    func testCompletedTaskCannotBeReopenedByConfirmingItsPlan() async throws {
        let task = try await discussionTask()
        let draft = try await revision(task)
        try await repository.completeTask(id: task.id)
        let completed = try await repository.task(id: task.id)
        await expectFailure { _ = try await self.repository.confirmRevisionAndPrepareDevelopmentRun(id: draft.id, prompt: "确认开发") }
        try await assertUnchanged(completed, revision: draft)
    }

    func testConcurrentAndDelayedDuplicateConfirmationsReserveOnlyOneRun() async throws {
        let task = try await discussionTask()
        let draft = try await revision(task)
        let first = try XCTUnwrap(repository)
        let second = try Repository(databaseURL: databaseURL)
        let successes = await withTaskGroup(of: String?.self) { group in
            for repo in [first, second] {
                group.addTask {
                    do { return try await repo.confirmRevisionAndPrepareDevelopmentRun(id: draft.id, prompt: "确认并开发").id }
                    catch { return nil }
                }
            }
            var ids: [String] = []
            for await id in group { if let id { ids.append(id) } }
            return ids
        }
        let state = try await repository.snapshot()
        XCTAssertEqual(successes.count, 1)
        XCTAssertEqual(state.runs.count, 1)
        XCTAssertEqual(state.messages.count, 1)
        XCTAssertEqual(state.tasks.first?.phaseVersion, task.phaseVersion + 1)
        let run = try XCTUnwrap(state.runs.first)
        let confirmation = try XCTUnwrap(state.revisions.first?.confirmedAt)
        try await repository.finishRun(id: run.id, status: .succeeded, stopConfirmed: true)
        await expectFailure { _ = try await self.repository.confirmRevisionAndPrepareDevelopmentRun(id: draft.id, prompt: "延迟重复点击") }
        let after = try await repository.snapshot()
        XCTAssertEqual(after.runs.count, 1)
        XCTAssertEqual(after.messages.count, 1)
        XCTAssertEqual(after.revisions.first?.confirmedAt, confirmation)
        XCTAssertEqual(after.tasks.first?.phaseVersion, task.phaseVersion + 1)
    }

    func testPlainConfirmationAndManualPhaseChangeStillDoNotLaunchRuns() async throws {
        let task = try await discussionTask()
        let draft = try await revision(task)
        try await repository.confirmRevision(id: draft.id)
        var state = try await repository.snapshot()
        XCTAssertEqual(state.tasks.first?.phase, .discussion)
        XCTAssertTrue(state.runs.isEmpty)
        XCTAssertTrue(state.messages.isEmpty)
        try await repository.transitionTask(id: task.id, to: .development)
        state = try await repository.snapshot()
        XCTAssertEqual(state.tasks.first?.phase, .development)
        XCTAssertTrue(state.runs.isEmpty)
        XCTAssertTrue(state.messages.isEmpty)
    }
}
