import XCTest
@testable import AgentKanbanCore

@MainActor
final class ConversationDeletionTests: XCTestCase {
    private var directory: URL!
    private var databaseURL: URL!
    private var repository: Repository!
    private var project: Project!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-kanban-conversation-deletion-\(UUID().uuidString)")
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

    private func expectFailure(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Operation should have been rejected", file: file, line: line) } catch { }
    }

    func testDeletionPersistsAndHidesOnlyItsMessagesRunsEventsAndApprovals() async throws {
        let deleted = try await repository.createConversation(projectID: project.id, title: "将删除")
        let kept = try await repository.createConversation(projectID: project.id, title: "保留")
        let originalFile = directory.appendingPathComponent("user-original.txt")
        try Data("用户原文件".utf8).write(to: originalFile)
        _ = try await repository.appendMessage(conversationID: deleted.id, role: .user, content: "有附件", attachments: [.init(name: originalFile.lastPathComponent, path: originalFile.path)])
        let keptMessage = try await repository.appendMessage(conversationID: kept.id, role: .user, content: "另一会话")
        let run = try await repository.prepareRun(conversationID: deleted.id, prompt: "分析")
        _ = try await repository.recordEvent(runID: run.id, kind: "status", content: "运行事件")
        _ = try await repository.saveApproval(.init(projectID: project.id, runID: run.id, requestID: "request", title: "审批", detail: "文件操作", options: [.init(id: "allow", title: "允许", allows: true)]))
        try await repository.finishRun(id: run.id, status: .succeeded, stopConfirmed: true)
        let keptRun = try await repository.prepareRun(conversationID: kept.id, prompt: "保留运行")
        let keptEvent = try await repository.recordEvent(runID: keptRun.id, kind: "status", content: "保留事件")
        try await repository.finishRun(id: keptRun.id, status: .succeeded, stopConfirmed: true)

        try await repository.deleteConversation(id: deleted.id)
        let reopened = try Repository(databaseURL: databaseURL)
        let snapshot = try await reopened.snapshot()
        XCTAssertEqual(snapshot.conversations.map(\.id), [kept.id])
        XCTAssertEqual(snapshot.messages.map(\.id), [keptMessage.id])
        XCTAssertEqual(snapshot.runs.map(\.id), [keptRun.id])
        XCTAssertEqual(snapshot.events.map(\.id), [keptEvent.id])
        XCTAssertTrue(snapshot.approvals.isEmpty)
        XCTAssertEqual(try Data(contentsOf: originalFile), Data("用户原文件".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: project.path).appendingPathComponent(".git").path))
    }

    func testDeletedConversationCannotBeReadRenamedRunOrReusedForImport() async throws {
        let chat = try await repository.createConversation(projectID: project.id)
        try await repository.deleteConversation(id: chat.id)

        await expectFailure { _ = try await self.repository.conversation(id: chat.id) }
        await expectFailure { try await self.repository.renameConversation(id: chat.id, title: "恢复") }
        await expectFailure { _ = try await self.repository.appendMessage(conversationID: chat.id, role: .user, content: "新消息") }
        await expectFailure { _ = try await self.repository.prepareRun(conversationID: chat.id, prompt: "继续") }
        await expectFailure { try await self.repository.updateSelection(conversationID: chat.id, selection: .init(executor: .claude)) }
        await expectFailure { _ = try await self.repository.selection(conversationID: chat.id, executor: .codex) }
        await expectFailure { try await self.repository.beginImport(conversationID: chat.id, operationKey: "late-import") }
        let snapshot = try await repository.snapshot()
        XCTAssertTrue(snapshot.conversations.isEmpty)
        XCTAssertTrue(snapshot.messages.isEmpty)
        XCTAssertTrue(snapshot.runs.isEmpty)
    }

    func testActiveApprovalCancellationAndRecoveryRunsBlockDeletionUntilTerminal() async throws {
        let chat = try await repository.createConversation(projectID: project.id)
        let run = try await repository.prepareRun(conversationID: chat.id, prompt: "运行")
        await expectFailure { try await self.repository.deleteConversation(id: chat.id) }
        _ = try await repository.saveApproval(.init(projectID: project.id, runID: run.id, requestID: "pending", title: "审批", detail: "操作", options: [.init(id: "allow", title: "允许", allows: true)]))
        await expectFailure { try await self.repository.deleteConversation(id: chat.id) }
        try await repository.requestStop(id: run.id)
        await expectFailure { try await self.repository.deleteConversation(id: chat.id) }
        try await repository.finishRun(id: run.id, status: .cancelled, stopConfirmed: false)
        await expectFailure { try await self.repository.deleteConversation(id: chat.id) }
        let retained = try await repository.conversation(id: chat.id)
        XCTAssertEqual(retained.id, chat.id)
        try await repository.finishRun(id: run.id, status: .cancelled, stopConfirmed: true)
        try await repository.deleteConversation(id: chat.id)
        let snapshot = try await repository.snapshot()
        XCTAssertTrue(snapshot.conversations.isEmpty)
    }

    func testImportActivityBlocksDeletionWithoutLosingConversation() async throws {
        let chat = try await repository.createConversation(projectID: project.id)
        try await repository.beginImport(conversationID: chat.id, operationKey: "in-progress")
        await expectFailure { try await self.repository.deleteConversation(id: chat.id) }
        let retained = try await repository.conversation(id: chat.id)
        XCTAssertEqual(retained.id, chat.id)
        try await repository.endImport(operationKey: "in-progress")
        try await repository.deleteConversation(id: chat.id)
    }

    func testDeletionRetainsImportedTaskSourceAuditAndAcceptanceAndDedupesFutureImports() async throws {
        let chat = try await repository.createConversation(projectID: project.id)
        let candidate = ImportCandidate(sourceKey: "github:example/repo#418", sourceURL: "https://github.com/example/repo/issues/418", sourceDescription: "Issue #418", title: "导入任务")
        let batch = try await repository.importCandidates(conversationID: chat.id, batchKey: "original-import", candidates: [candidate])
        let taskID = try XCTUnwrap(batch.createdTaskIDs.first)
        let task = try await repository.task(id: taskID)
        try await repository.transitionTask(id: taskID, to: .discussion)
        let revision = try await repository.saveRevision(taskID: taskID, requirement: "需求", plan: "方案", acceptanceCriteria: ["标准"])
        try await repository.confirmRevision(id: revision.id)
        try await repository.transitionTask(id: taskID, to: .acceptance)
        let report = AcceptanceReport(projectID: project.id, taskID: taskID, revisionID: revision.id, codeFingerprint: "fixture", checks: [.init(title: "标准", passed: true, evidence: "验收")], summary: "通过")
        try await repository.saveAcceptance(report)

        try await repository.deleteConversation(id: chat.id)
        let reopened = try Repository(databaseURL: databaseURL)
        var snapshot = try await reopened.snapshot()
        XCTAssertEqual(snapshot.tasks.map(\.id), [taskID])
        XCTAssertEqual(snapshot.conversations.map(\.id), [task.mainConversationID])
        XCTAssertTrue(snapshot.importBatches.isEmpty)
        XCTAssertEqual(snapshot.provenance.first?.batchID, batch.id)
        XCTAssertEqual(snapshot.provenance.first?.sourceURL, candidate.sourceURL)
        XCTAssertEqual(snapshot.revisions.map(\.id), [revision.id])
        XCTAssertEqual(snapshot.reports.map(\.id), [report.id])
        XCTAssertFalse(try XCTUnwrap(snapshot.reports.first).stale)

        let replacement = try await reopened.createConversation(projectID: project.id)
        // The original batch stays bound to its original conversation for audit and retry identity.
        await expectFailure { _ = try await reopened.importCandidates(conversationID: replacement.id, batchKey: "original-import", candidates: [candidate]) }
        let retry = try await reopened.importCandidates(conversationID: replacement.id, batchKey: "new-import", candidates: [candidate])
        XCTAssertTrue(retry.createdTaskIDs.isEmpty)
        XCTAssertEqual(retry.duplicateCount, 1)
        snapshot = try await reopened.snapshot()
        XCTAssertEqual(snapshot.tasks.count, 1)
        XCTAssertEqual(snapshot.provenance.count, 1)
    }

    func testTaskMainAndRemovedProjectConversationCannotBeDeleted() async throws {
        let task = try await repository.createTask(projectID: project.id, title: "保留任务")
        await expectFailure { try await self.repository.deleteConversation(id: task.mainConversationID) }
        let main = try await repository.conversation(id: task.mainConversationID)
        XCTAssertEqual(main.kind, .taskMain)
        let chat = try await repository.createConversation(projectID: project.id)
        try await repository.removeProject(id: project.id)
        await expectFailure { try await self.repository.deleteConversation(id: chat.id) }
        let snapshot = try await repository.snapshot()
        XCTAssertTrue(snapshot.conversations.isEmpty)
        XCTAssertTrue(snapshot.tasks.isEmpty)
    }
}
