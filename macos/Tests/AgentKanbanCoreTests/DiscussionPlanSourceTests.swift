import XCTest
@testable import AgentKanbanCore

@MainActor
final class DiscussionPlanSourceTests: XCTestCase {
    private var directory: URL!
    private var databaseURL: URL!
    private var repository: Repository!
    private var project: Project!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-kanban-plan-source-\(UUID().uuidString)")
        let projectURL = directory.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", projectURL.path, "init", "--quiet"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        databaseURL = directory.appendingPathComponent("data/workspace.sqlite")
        repository = try Repository(databaseURL: databaseURL)
        project = try await repository.importProject(path: projectURL.path)
    }

    override func tearDown() async throws {
        repository = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func discussionTask(_ title: String = "输入框对齐") async throws -> TaskItem {
        let task = try await repository.createTask(projectID: project.id, title: title, description: "保留会话中的修复边界")
        try await repository.transitionTask(id: task.id, to: .discussion)
        return try await repository.task(id: task.id)
    }

    private func completedReply(task: TaskItem, status: RunStatus = .succeeded, role: MessageRole = .assistant, canonical: Bool = true) async throws -> (RunRecord, Message) {
        let run = try await repository.prepareRun(conversationID: task.mainConversationID, prompt: "讨论修复方案")
        try await repository.finishRun(id: run.id, status: status, stopConfirmed: true)
        let message = try await repository.appendMessage(conversationID: task.mainConversationID, role: role, content: "## 方案\n局部统一边距，保留 `textContainerInset` 配置。", runID: run.id, id: canonical ? "reply-\(run.id)" : "progress-\(run.id)")
        return (run, message)
    }

    private func expectFailure(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Invalid source must be rejected", file: file, line: line) } catch { }
    }

    func testSourceSurvivesReopenAndEditsInLaterPhaseCreateUnconfirmedVersion() async throws {
        let task = try await discussionTask()
        let (run, message) = try await completedReply(task: task)
        let first = try await repository.saveRevision(taskID: task.id, requirement: task.description, plan: message.content, acceptanceCriteria: ["光标与占位文字基线对齐"], sourceMessageID: message.id, sourceRunID: run.id)

        XCTAssertEqual(first.sourceMessageID, message.id)
        XCTAssertEqual(first.sourceRunID, run.id)
        XCTAssertEqual(first.plan, message.content)
        XCTAssertNil(first.confirmedAt)
        var current = try await repository.task(id: task.id)
        XCTAssertEqual(current.phase, .discussion)
        XCTAssertEqual(current.phaseVersion, task.phaseVersion)
        await expectFailure { try await self.repository.transitionTask(id: task.id, to: .development) }

        try await repository.confirmRevision(id: first.id)
        try await repository.transitionTask(id: task.id, to: .development)
        try await repository.transitionTask(id: task.id, to: .acceptance)
        current = try await repository.task(id: task.id)
        XCTAssertNotEqual(current.phaseVersion, run.phaseVersion)
        let report = AcceptanceReport(projectID: project.id, taskID: task.id, revisionID: first.id, codeFingerprint: "fixture", checks: [.init(title: "基线对齐", passed: true, evidence: "界面核对")], summary: "通过")
        try await repository.saveAcceptance(report)

        let edited = try await repository.saveRevision(taskID: task.id, requirement: task.description, plan: message.content + "\n补充深色模式验证。", acceptanceCriteria: ["光标与占位文字基线对齐", "深色模式通过"], sourceMessageID: message.id, sourceRunID: run.id)
        XCTAssertEqual(edited.version, 2)
        XCTAssertNil(edited.confirmedAt)
        await expectFailure { try await self.repository.transitionTask(id: task.id, to: .development) }

        let reopened = try Repository(databaseURL: databaseURL)
        let snapshot = try await reopened.snapshot()
        let restored = try XCTUnwrap(snapshot.revisions.first { $0.id == edited.id })
        XCTAssertEqual(restored.id, edited.id)
        XCTAssertEqual(restored.projectID, edited.projectID)
        XCTAssertEqual(restored.taskID, edited.taskID)
        XCTAssertEqual(restored.version, edited.version)
        XCTAssertEqual(restored.requirement, edited.requirement)
        XCTAssertEqual(restored.plan, edited.plan)
        XCTAssertEqual(restored.acceptanceCriteria, edited.acceptanceCriteria)
        XCTAssertEqual(restored.createdAt.timeIntervalSince1970, edited.createdAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNil(restored.confirmedAt)
        XCTAssertEqual(restored.sourceMessageID, message.id)
        XCTAssertEqual(restored.sourceRunID, run.id)
        XCTAssertNotNil(snapshot.revisions.first { $0.id == first.id }?.confirmedAt)
        XCTAssertTrue(try XCTUnwrap(snapshot.reports.first { $0.id == report.id }).stale)
        XCTAssertEqual(snapshot.tasks.first { $0.id == task.id }?.currentRevisionID, edited.id)
        XCTAssertEqual(snapshot.tasks.first { $0.id == task.id }?.phase, .acceptance)
        XCTAssertEqual(snapshot.tasks.first { $0.id == task.id }?.phaseVersion, current.phaseVersion)
        XCTAssertEqual(snapshot.runs.count, 1)
    }

    func testLegacyRevisionPayloadWithoutSourceStillDecodes() throws {
        let original = RequirementRevision(projectID: "project", taskID: "task", version: 3, requirement: "需求", plan: "方案", acceptanceCriteria: ["验收"], sourceMessageID: "reply-run", sourceRunID: "run")
        let data = try JSONEncoder().encode(original)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        payload.removeValue(forKey: "sourceMessageID")
        payload.removeValue(forKey: "sourceRunID")
        let decoded = try JSONDecoder().decode(RequirementRevision.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.plan, original.plan)
        XCTAssertNil(decoded.sourceMessageID)
        XCTAssertNil(decoded.sourceRunID)
    }

    func testManualSaveNeedsNoDiscussionAndKeepsNativeDefaults() async throws {
        let task = try await discussionTask()
        let revision = try await repository.saveRevision(taskID: task.id, requirement: task.description, plan: "手写方案", acceptanceCriteria: ["", "可验证条件", " \n"])
        XCTAssertNil(revision.sourceMessageID)
        XCTAssertNil(revision.sourceRunID)
        XCTAssertNil(revision.confirmedAt)
        XCTAssertEqual(revision.acceptanceCriteria, ["可验证条件"])
        let snapshot = try await repository.snapshot()
        XCTAssertTrue(snapshot.messages.isEmpty)
        XCTAssertTrue(snapshot.runs.isEmpty)
        XCTAssertEqual(snapshot.tasks.first?.phase, .discussion)
    }

    func testIncompleteSourcePairAndMismatchedRunAreRejectedAtomically() async throws {
        let task = try await discussionTask()
        let (run, message) = try await completedReply(task: task)
        let (otherRun, _) = try await completedReply(task: task)
        await expectFailure { _ = try await self.repository.saveRevision(taskID: task.id, requirement: "", plan: "方案", acceptanceCriteria: [], sourceMessageID: message.id) }
        await expectFailure { _ = try await self.repository.saveRevision(taskID: task.id, requirement: "", plan: "方案", acceptanceCriteria: [], sourceRunID: run.id) }
        await expectFailure { _ = try await self.repository.saveRevision(taskID: task.id, requirement: "", plan: "方案", acceptanceCriteria: [], sourceMessageID: message.id, sourceRunID: otherRun.id) }
        let snapshot = try await repository.snapshot()
        XCTAssertTrue(snapshot.revisions.isEmpty)
        XCTAssertNil(snapshot.tasks.first?.currentRevisionID)
    }

    func testSourceFromAnotherTaskOrProjectConversationIsRejected() async throws {
        let target = try await discussionTask()
        let other = try await discussionTask("其他任务")
        let (run, message) = try await completedReply(task: other)
        await expectFailure { _ = try await self.repository.saveRevision(taskID: target.id, requirement: "", plan: message.content, acceptanceCriteria: [], sourceMessageID: message.id, sourceRunID: run.id) }

        let chat = try await repository.createConversation(projectID: project.id)
        let chatRun = try await repository.prepareRun(conversationID: chat.id, prompt: "普通会话")
        try await repository.finishRun(id: chatRun.id, status: .succeeded, stopConfirmed: true)
        let chatMessage = try await repository.appendMessage(conversationID: chat.id, role: .assistant, content: "项目会话内容", runID: chatRun.id, id: "reply-\(chatRun.id)")
        await expectFailure { _ = try await self.repository.saveRevision(taskID: target.id, requirement: "", plan: chatMessage.content, acceptanceCriteria: [], sourceMessageID: chatMessage.id, sourceRunID: chatRun.id) }
        let snapshot = try await repository.snapshot()
        XCTAssertTrue(snapshot.revisions.isEmpty)
    }

    func testNonFinalAndNonAssistantRepliesAreRejected() async throws {
        let task = try await discussionTask()
        for (role, canonical) in [(MessageRole.assistant, false), (.tool, true), (.user, true)] {
            let (run, message) = try await completedReply(task: task, role: role, canonical: canonical)
            await expectFailure { _ = try await self.repository.saveRevision(taskID: task.id, requirement: "", plan: message.content, acceptanceCriteria: [], sourceMessageID: message.id, sourceRunID: run.id) }
        }
        let snapshot = try await repository.snapshot()
        XCTAssertTrue(snapshot.revisions.isEmpty)
    }

    func testFailedCancelledAndDevelopmentRepliesCannotBecomeDiscussionSource() async throws {
        let task = try await discussionTask()
        for status in [RunStatus.failed, .cancelled] {
            let (run, message) = try await completedReply(task: task, status: status)
            await expectFailure { _ = try await self.repository.saveRevision(taskID: task.id, requirement: "", plan: message.content, acceptanceCriteria: [], sourceMessageID: message.id, sourceRunID: run.id) }
        }
        let initial = try await repository.saveRevision(taskID: task.id, requirement: task.description, plan: "人工方案", acceptanceCriteria: ["验收条件"])
        try await repository.confirmRevision(id: initial.id)
        try await repository.transitionTask(id: task.id, to: .development)
        let (developmentRun, developmentMessage) = try await completedReply(task: task)
        await expectFailure { _ = try await self.repository.saveRevision(taskID: task.id, requirement: "", plan: developmentMessage.content, acceptanceCriteria: [], sourceMessageID: developmentMessage.id, sourceRunID: developmentRun.id) }
        let snapshot = try await repository.snapshot()
        XCTAssertEqual(snapshot.revisions.map(\.id), [initial.id])
        XCTAssertEqual(snapshot.tasks.first?.currentRevisionID, initial.id)
    }

    func testSavingWithHistoricalSourceStillWaitsForActiveRunToStop() async throws {
        let task = try await discussionTask()
        let (sourceRun, message) = try await completedReply(task: task)
        let active = try await repository.prepareRun(conversationID: task.mainConversationID, prompt: "继续讨论")
        await expectFailure { _ = try await self.repository.saveRevision(taskID: task.id, requirement: "", plan: message.content, acceptanceCriteria: [], sourceMessageID: message.id, sourceRunID: sourceRun.id) }
        let snapshot = try await repository.snapshot()
        XCTAssertTrue(snapshot.revisions.isEmpty)
        XCTAssertEqual(snapshot.runs.first { $0.id == active.id }?.status, .starting)
        try await repository.finishRun(id: active.id, status: .cancelled, stopConfirmed: true)
    }
}
