import XCTest
@testable import AgentKanbanCore

@MainActor
final class DirectImplementationTests: XCTestCase {
    private var directory: URL!
    private var projectURL: URL!
    private var databaseURL: URL!
    private var repository: Repository!
    private var project: Project!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-kanban-direct-\(UUID().uuidString)")
        projectURL = directory.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", projectURL.path, "init", "--quiet"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        databaseURL = directory.appendingPathComponent("data/workspace.sqlite")
        repository = try Repository(databaseURL: databaseURL)
        project = try await repository.importProject(path: projectURL.path, defaultExecutor: .claude)
    }

    override func tearDown() async throws {
        repository = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func expectFailure(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Operation must be rejected", file: file, line: line) } catch { }
    }

    private func newTask(_ title: String = "修复输入框") async throws -> TaskItem {
        try await repository.createTask(projectID: project.id, title: title, description: "根据已有说明直接开发。\n保留原有行为。")
    }

    private func directlyImplement(_ task: TaskItem) async throws -> RunRecord {
        try await repository.prepareRun(conversationID: task.mainConversationID, prompt: "按当前任务说明、备注和附件实施", directImplementation: true)
    }

    private func stop(_ run: RunRecord, status: RunStatus = .succeeded) async throws {
        try await repository.finishRun(id: run.id, status: status, stopConfirmed: true)
    }

    func testAtomicDirectImplementationFreezesDevelopmentRunAndRecordsExplicitAction() async throws {
        let imageURL = directory.appendingPathComponent("reference.png")
        try Data("image fixture".utf8).write(to: imageURL)
        let attachment = Attachment(name: "reference.png", path: imageURL.path, byteCount: 13)
        let task = try await repository.createTask(projectID: project.id, title: "依据截图修复", description: "先检查布局\n再修复边距", attachments: [attachment])
        let note = try await repository.appendMessage(conversationID: task.mainConversationID, role: .user, content: "备注：不要修改会话编辑器。")
        let selection = ExecutionSelection(executor: .cursor, modelID: "fixture-model", effort: "high", permission: .requestApproval)
        try await repository.updateSelection(conversationID: task.mainConversationID, selection: selection)
        let engine = TaskEngine(repository: repository)
        let prompt = "任务：依据截图修复\n先检查布局\n再修复边距\n备注：不要修改会话编辑器。\n附件：\(imageURL.path)"
        let run = try await engine.prepareRun(conversationID: task.mainConversationID, prompt: prompt, directImplementation: true)

        let state = try await repository.snapshot()
        let updated = try XCTUnwrap(state.tasks.first { $0.id == task.id })
        XCTAssertEqual(updated.phase, .development)
        XCTAssertEqual(updated.phaseVersion, task.phaseVersion + 1)
        XCTAssertEqual(updated.directImplementationPhaseVersion, updated.phaseVersion)
        XCTAssertNil(updated.currentRevisionID)
        XCTAssertEqual(run.phase, .development)
        XCTAssertEqual(run.phaseVersion, updated.phaseVersion)
        XCTAssertEqual(run.taskID, task.id)
        XCTAssertEqual(run.conversationID, task.mainConversationID)
        XCTAssertEqual(run.projectID, project.id)
        XCTAssertEqual(run.selection, selection)
        XCTAssertEqual(run.cwd, project.path)
        XCTAssertEqual(run.prompt, prompt)
        XCTAssertTrue(run.writing)
        XCTAssertEqual(run.status, .starting)
        XCTAssertNil(run.revisionID)
        XCTAssertTrue(state.revisions.isEmpty)
        XCTAssertTrue(state.reports.isEmpty)
        XCTAssertEqual(state.runs.count, 1)
        XCTAssertEqual(state.messages.count, 2)
        XCTAssertTrue(state.messages.contains { $0.id == note.id })
        let action = try XCTUnwrap(state.messages.first { $0.id == "direct-implementation-\(run.id)" })
        XCTAssertEqual(action.role, .user)
        XCTAssertEqual(action.runID, run.id)
        XCTAssertEqual(action.conversationID, task.mainConversationID)
        XCTAssertTrue(action.content.contains("直接开发"))
        XCTAssertEqual(action.attachments, [attachment])
    }

    func testLegacyTaskPayloadHasNoDirectAuthorization() throws {
        let original = TaskItem(projectID: "legacy-project", number: 1, title: "旧任务", phase: .development, phaseVersion: 4, directImplementationPhaseVersion: 4)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        payload.removeValue(forKey: "directImplementationPhaseVersion")
        let legacy = try JSONDecoder().decode(TaskItem.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(legacy.phase, .development)
        XCTAssertEqual(legacy.phaseVersion, 4)
        XCTAssertNil(legacy.directImplementationPhaseVersion)
    }

    func testWriterAndReadOnlyContentionQueueAuthorizedDevelopment() async throws {
        for readOnly in [false, true] {
            let task = try await newTask()
            let blocker: RunRecord
            if readOnly {
                let reviewer = try await newTask("另一个只读讨论")
                try await repository.transitionTask(id: reviewer.id, to: .discussion)
                blocker = try await repository.prepareRun(conversationID: reviewer.mainConversationID, prompt: "只读分析")
            } else {
                let chat = try await repository.createConversation(projectID: project.id)
                blocker = try await repository.prepareRun(conversationID: chat.id, prompt: "另一个会话写入")
            }
            let queued = try await directlyImplement(task)
            let updated = try await repository.task(id: task.id)
            let state = try await repository.snapshot()
            XCTAssertEqual(updated.phase, .development)
            XCTAssertEqual(updated.directImplementationPhaseVersion, updated.phaseVersion)
            XCTAssertEqual(queued.status, .queued)
            XCTAssertEqual(queued.includeFullHistory, true)
            XCTAssertEqual(state.messages.filter { $0.runID == queued.id }.count, 1)
            try await stop(blocker)
            let claimed = try await repository.claimNextQueuedRun()
            XCTAssertEqual(claimed?.id, queued.id)
            try await stop(queued)
        }
    }

    func testStageBarrierAndInvalidPromptDoNotPartiallyEnterDevelopment() async throws {
        let task = try await newTask()
        try await repository.beginStageChange(taskID: task.id)
        await expectFailure { _ = try await self.directlyImplement(task) }
        try await repository.abandonStageChange(taskID: task.id)
        await expectFailure { _ = try await self.repository.prepareRun(conversationID: task.mainConversationID, prompt: " \n", directImplementation: true) }
        let current = try await repository.task(id: task.id)
        let state = try await repository.snapshot()
        XCTAssertEqual(current.phase, .backlog)
        XCTAssertEqual(current.phaseVersion, task.phaseVersion)
        XCTAssertNil(current.directImplementationPhaseVersion)
        XCTAssertTrue(state.runs.isEmpty)
        XCTAssertTrue(state.messages.isEmpty)
    }

    func testConcurrentClicksReserveOnlyOneDevelopmentRunAndOneAction() async throws {
        let task = try await newTask()
        let first = try XCTUnwrap(repository)
        let second = try Repository(databaseURL: databaseURL)
        let successes = await withTaskGroup(of: String?.self) { group in
            for repo in [first, second] {
                group.addTask {
                    do { return try await repo.prepareRun(conversationID: task.mainConversationID, prompt: "直接开发", directImplementation: true).id }
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
        try await stop(run, status: .failed)
        await expectFailure { _ = try await self.directlyImplement(task) }
        let after = try await repository.snapshot()
        XCTAssertEqual(after.runs.count, 1)
        XCTAssertEqual(after.messages.count, 1)
    }

    func testOnlyBacklogTaskMainCanUseDirectImplementation() async throws {
        let task = try await newTask()
        let chat = try await repository.createConversation(projectID: project.id)
        await expectFailure { _ = try await self.repository.prepareRun(conversationID: chat.id, prompt: "直接开发", directImplementation: true) }
        try await repository.transitionTask(id: task.id, to: .discussion)
        await expectFailure { _ = try await self.directlyImplement(task) }
        let state = try await repository.snapshot()
        XCTAssertEqual(state.tasks.first?.phase, .discussion)
        XCTAssertNil(state.tasks.first?.directImplementationPhaseVersion)
        XCTAssertTrue(state.runs.isEmpty)
        XCTAssertTrue(state.messages.isEmpty)
    }

    func testOrdinaryDevelopmentStillRequiresConfirmedPlan() async throws {
        let task = try await newTask()
        await expectFailure { _ = try await self.repository.prepareRun(conversationID: task.mainConversationID, prompt: "普通发送") }
        await expectFailure { try await self.repository.transitionTask(id: task.id, to: .development) }
        try await repository.transitionTask(id: task.id, to: .discussion)
        let revision = try await repository.saveRevision(taskID: task.id, requirement: task.description, plan: "真实方案", acceptanceCriteria: ["真实标准"])
        await expectFailure { try await self.repository.transitionTask(id: task.id, to: .development) }
        try await repository.confirmRevision(id: revision.id)
        try await repository.transitionTask(id: task.id, to: .development)
        let current = try await repository.task(id: task.id)
        XCTAssertNil(current.directImplementationPhaseVersion)
        let run = try await repository.prepareRun(conversationID: task.mainConversationID, prompt: "按确认方案实施")
        XCTAssertTrue(run.writing)
        XCTAssertEqual(run.revisionID, revision.id)
    }

    func testAuthorizationSurvivesRestartAndFailedLaunchAllowsOrdinaryRetry() async throws {
        let task = try await newTask()
        let original = try await directlyImplement(task)
        XCTAssertEqual(original.selection, .init(executor: .claude))
        try await stop(original, status: .failed)
        let reopened = try Repository(databaseURL: databaseURL)
        let current = try await reopened.task(id: task.id)
        XCTAssertEqual(current.directImplementationPhaseVersion, current.phaseVersion)
        XCTAssertEqual(current.phase, .development)
        XCTAssertNil(current.currentRevisionID)
        let retry = try await reopened.prepareRun(conversationID: task.mainConversationID, prompt: "登录后继续实施")
        XCTAssertTrue(retry.writing)
        XCTAssertEqual(retry.phaseVersion, original.phaseVersion)
        XCTAssertNil(retry.revisionID)
        let state = try await reopened.snapshot()
        XCTAssertEqual(state.messages.filter { $0.id.hasPrefix("direct-implementation-") }.count, 1)
        XCTAssertTrue(state.revisions.isEmpty)
    }

    func testLeavingDevelopmentRevokesAuthorizationAndReentryNeedsPlan() async throws {
        let task = try await newTask()
        let run = try await directlyImplement(task)
        try await stop(run)
        try await repository.transitionTask(id: task.id, to: .discussion)
        let returned = try await repository.task(id: task.id)
        XCTAssertNil(returned.directImplementationPhaseVersion)
        XCTAssertEqual(returned.phaseVersion, run.phaseVersion! + 1)
        await expectFailure { try await self.repository.transitionTask(id: task.id, to: .development) }
        await expectFailure { _ = try await self.directlyImplement(task) }
        let review = try await repository.prepareRun(conversationID: task.mainConversationID, prompt: "重新讨论")
        XCTAssertFalse(review.writing)
        try await stop(review)
        try await repository.transitionTask(id: task.id, to: .backlog)
        let fresh = try await directlyImplement(task)
        XCTAssertTrue(fresh.writing)
        XCTAssertGreaterThan(try XCTUnwrap(fresh.phaseVersion), try XCTUnwrap(run.phaseVersion))
    }

    func testNewPlanRevokesAuthorizationUntilHumanConfirmation() async throws {
        let task = try await newTask()
        let run = try await directlyImplement(task)
        try await stop(run)
        let revision = try await repository.saveRevision(taskID: task.id, requirement: task.description, plan: "新增实施边界", acceptanceCriteria: ["验证新增边界"])
        let current = try await repository.task(id: task.id)
        XCTAssertNil(current.directImplementationPhaseVersion)
        XCTAssertEqual(current.phase, .development)
        XCTAssertNil(revision.confirmedAt)
        await expectFailure { _ = try await self.repository.prepareRun(conversationID: task.mainConversationID, prompt: "继续写入") }
        try await repository.confirmRevision(id: revision.id)
        let next = try await repository.prepareRun(conversationID: task.mainConversationID, prompt: "按新确认方案实施")
        XCTAssertTrue(next.writing)
        XCTAssertEqual(next.revisionID, revision.id)
    }

    func testRequirementChangesRevokeAuthorizationButSelectionChangesDoNot() async throws {
        for change in ["title", "description", "attachments"] {
            let task = try await newTask("任务 \(change)")
            let run = try await directlyImplement(task)
            try await stop(run)
            let current = try await repository.task(id: task.id)
            let selection = ExecutionSelection(executor: .codex, modelID: "test-model")
            try await repository.updateSelection(conversationID: task.mainConversationID, selection: selection)
            var updated = try await repository.task(id: task.id)
            XCTAssertEqual(updated.directImplementationPhaseVersion, current.phaseVersion)
            let attachment = Attachment(name: "new.txt", path: directory.appendingPathComponent("new.txt").path)
            try await repository.updateTask(id: task.id, title: change == "title" ? "修改标题" : current.title, description: change == "description" ? "修改需求说明" : current.description, type: current.type, priority: current.priority, attachments: change == "attachments" ? [attachment] : nil)
            updated = try await repository.task(id: task.id)
            XCTAssertNil(updated.directImplementationPhaseVersion)
            XCTAssertEqual(updated.selection, selection)
            await expectFailure { _ = try await self.repository.prepareRun(conversationID: task.mainConversationID, prompt: "新需求未经确认不能沿用旧授权") }
        }
    }

    func testDirectImplementationDoesNotBypassRealPlanAndCriteriaForAcceptance() async throws {
        let task = try await newTask()
        let run = try await directlyImplement(task)
        try await stop(run)
        await expectFailure { try await self.repository.transitionTask(id: task.id, to: .acceptance) }
        var current = try await repository.task(id: task.id)
        XCTAssertEqual(current.phase, .development)
        XCTAssertEqual(current.directImplementationPhaseVersion, current.phaseVersion)
        let incomplete = try await repository.saveRevision(taskID: task.id, requirement: task.description, plan: "真实方案但缺少标准", acceptanceCriteria: [])
        await expectFailure { try await self.repository.confirmRevision(id: incomplete.id) }
        await expectFailure { try await self.repository.transitionTask(id: task.id, to: .acceptance) }
        let revision = try await repository.saveRevision(taskID: task.id, requirement: task.description, plan: "真实实施方案", acceptanceCriteria: ["真实验收标准"])
        await expectFailure { try await self.repository.transitionTask(id: task.id, to: .acceptance) }
        try await repository.confirmRevision(id: revision.id)
        try await repository.transitionTask(id: task.id, to: .acceptance)
        current = try await repository.task(id: task.id)
        XCTAssertNil(current.directImplementationPhaseVersion)
        let review = try await repository.prepareRun(conversationID: task.mainConversationID, prompt: "依据已确认标准验收")
        XCTAssertFalse(review.writing)
        XCTAssertEqual(review.revisionID, revision.id)
        try await stop(review)

        // A new version while remaining in acceptance invalidates its old confirmation.
        let changed = try await repository.saveRevision(taskID: task.id, requirement: task.description, plan: "调整后的真实方案", acceptanceCriteria: ["调整后的标准"])
        await expectFailure { _ = try await self.repository.prepareRun(conversationID: task.mainConversationID, prompt: "旧确认不能用于新方案") }
        let report = AcceptanceReport(projectID: project.id, taskID: task.id, revisionID: changed.id, codeFingerprint: "fixture", checks: [.init(title: "调整后的标准", passed: true, evidence: "证据")], summary: "未确认不能保存")
        await expectFailure { try await self.repository.saveAcceptance(report) }
        let state = try await repository.snapshot()
        XCTAssertTrue(state.reports.isEmpty)
        XCTAssertNil(state.revisions.first { $0.id == changed.id }?.confirmedAt)
    }
}
