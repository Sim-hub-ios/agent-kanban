import XCTest
@testable import AgentKanbanCore

@MainActor
final class TaskAttachmentTests: XCTestCase {
    private var directory: URL!
    private var databaseURL: URL!
    private var repository: Repository!
    private var project: Project!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-kanban-task-attachments-\(UUID().uuidString)")
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
        project = try await repository.importProject(path: projectURL.path, defaultExecutor: .claude)
    }

    override func tearDown() async throws {
        repository = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func attachment(_ name: String) throws -> Attachment {
        let url = directory.appendingPathComponent(name)
        let bytes = Data("attachment: \(name)".utf8)
        try bytes.write(to: url)
        return Attachment(name: name, path: url.path, byteCount: bytes.count, sourceIdentity: "fixture:\(name)")
    }

    private func update(_ task: TaskItem, attachments: [Attachment]? = nil) async throws {
        try await repository.updateTask(id: task.id, title: task.title, description: task.description, type: task.type, priority: task.priority, attachments: attachments)
    }

    func testCreatedAttachmentsSurviveReopenWithoutStartingRunOrInventingMessage() async throws {
        let image = try attachment("screenshot.png")
        let document = try attachment("requirements.pdf")
        let task = try await repository.createTask(projectID: project.id, title: "使用附件创建任务", description: "第一行\n第二行", attachments: [image, document])

        let reopened = try Repository(databaseURL: databaseURL)
        let restored = try await reopened.task(id: task.id)
        let snapshot = try await reopened.snapshot()
        XCTAssertEqual(restored.attachments, [image, document])
        XCTAssertEqual(restored.description, "第一行\n第二行")
        XCTAssertEqual(restored.phase, .backlog)
        XCTAssertEqual(restored.selection, .init(executor: .claude))
        XCTAssertEqual(snapshot.conversations.filter { $0.taskID == task.id }.map(\.id), [task.mainConversationID])
        XCTAssertTrue(snapshot.messages.isEmpty)
        XCTAssertTrue(snapshot.runs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: image.path)), Data("attachment: screenshot.png".utf8))
    }

    func testEditingAttachmentsAddsRemovesAndPreservesWhenArgumentOmitted() async throws {
        let image = try attachment("image.png")
        let document = try attachment("notes.txt")
        let task = try await repository.createTask(projectID: project.id, title: "任务", attachments: [image])

        try await update(task, attachments: [image, document])
        var restored = try await repository.task(id: task.id)
        XCTAssertEqual(restored.attachments, [image, document])
        try await update(restored)
        restored = try await repository.task(id: task.id)
        XCTAssertEqual(restored.attachments, [image, document])

        try await update(restored, attachments: [document])
        restored = try await repository.task(id: task.id)
        XCTAssertEqual(restored.attachments, [document])
        try await update(restored, attachments: [])

        let reopened = try Repository(databaseURL: databaseURL)
        restored = try await reopened.task(id: task.id)
        XCTAssertEqual(restored.attachments, [])
        XCTAssertEqual(restored.mainConversationID, task.mainConversationID)
        XCTAssertEqual(restored.phaseVersion, task.phaseVersion)
    }

    func testLegacyTaskJSONWithoutAttachmentsStillDecodes() throws {
        let original = TaskItem(projectID: "legacy-project", number: 3, title: "旧任务")
        let encoded = try JSONEncoder().encode(original)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "attachments")
        let legacy = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(TaskItem.self, from: legacy)

        XCTAssertNil(decoded.attachments)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.mainConversationID, original.mainConversationID)
        XCTAssertEqual(decoded.phase, .backlog)
    }

    func testAttachmentChangesInvalidateRequirementAndAcceptanceButUnchangedFilesDoNot() async throws {
        let image = try attachment("evidence.png")
        let task = try await repository.createTask(projectID: project.id, title: "验收任务", attachments: [image])
        try await repository.transitionTask(id: task.id, to: .discussion)
        let revision = try await repository.saveRevision(taskID: task.id, requirement: "依据截图修复", plan: "修复输入", acceptanceCriteria: ["截图问题已修复"])
        try await repository.confirmRevision(id: revision.id)
        try await repository.transitionTask(id: task.id, to: .acceptance)
        let report = AcceptanceReport(projectID: project.id, taskID: task.id, revisionID: revision.id, codeFingerprint: "fixture", checks: [.init(title: "问题修复", passed: true, evidence: "人工验证")], summary: "通过")
        try await repository.saveAcceptance(report)

        var current = try await repository.task(id: task.id)
        try await update(current, attachments: [image])
        current = try await repository.task(id: task.id)
        var snapshot = try await repository.snapshot()
        XCTAssertEqual(current.currentRevisionID, revision.id)
        XCTAssertFalse(try XCTUnwrap(snapshot.reports.first).stale)

        try await update(current, attachments: [])
        current = try await repository.task(id: task.id)
        snapshot = try await repository.snapshot()
        XCTAssertNil(current.currentRevisionID)
        XCTAssertTrue(try XCTUnwrap(snapshot.reports.first).stale)
        XCTAssertEqual(current.phase, .acceptance)
        XCTAssertEqual(current.mainConversationID, task.mainConversationID)
    }

    func testAttachmentEditingCannotBypassActiveRunGuard() async throws {
        let task = try await repository.createTask(projectID: project.id, title: "运行中的任务")
        try await repository.transitionTask(id: task.id, to: .discussion)
        let run = try await repository.prepareRun(conversationID: task.mainConversationID, prompt: "讨论")
        let image = try attachment("new-evidence.png")
        do {
            try await update(task, attachments: [image])
            XCTFail("Editing task attachments must wait until its active run stops")
        } catch { }
        let unchanged = try await repository.task(id: task.id)
        XCTAssertEqual(unchanged.attachments, [])
        try await repository.finishRun(id: run.id, status: .succeeded, stopConfirmed: true)
    }
}
