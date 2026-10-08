import XCTest
@testable import AgentKanbanCore

@MainActor
final class OptionalAcceptanceTests: XCTestCase {
    private var directory: URL!
    private var repository: Repository!
    private var project: Project!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("kanban-optional-acceptance-\(UUID().uuidString)")
        let projectURL = directory.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["init", "-q", projectURL.path]
        git.standardOutput = FileHandle.nullDevice; git.standardError = FileHandle.nullDevice
        try git.run(); git.waitUntilExit()
        XCTAssertEqual(git.terminationStatus, 0)
        repository = try Repository(databaseURL: directory.appendingPathComponent("workspace.sqlite"))
        project = try await repository.importProject(path: projectURL.path)
    }

    override func tearDown() async throws {
        repository = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func directTask() async throws -> TaskItem {
        let task = try await repository.createTask(projectID: project.id, title: "手动确认完成")
        let run = try await repository.prepareRun(conversationID: task.mainConversationID, prompt: "直接开发", directImplementation: true)
        try await repository.finishRun(id: run.id, status: .succeeded, stopConfirmed: true)
        return try await repository.task(id: task.id)
    }

    private func expectFailure(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Unfinished work must still block completion", file: file, line: line) } catch { }
    }

    func testManualCompletionFromDevelopmentNeedsNeitherPlanNorReport() async throws {
        let task = try await directTask()
        let before = try await repository.snapshot()
        XCTAssertEqual(task.phase, .development, "Executor completion must not move the task automatically")
        try await repository.transitionTask(id: task.id, to: .completed)
        let state = try await repository.snapshot()
        let completed = try XCTUnwrap(state.tasks.first { $0.id == task.id })
        XCTAssertEqual(completed.phase, .completed)
        XCTAssertEqual(completed.phaseVersion, task.phaseVersion + 1)
        XCTAssertNil(completed.directImplementationPhaseVersion)
        XCTAssertNil(completed.currentRevisionID)
        XCTAssertTrue(state.revisions.isEmpty)
        XCTAssertTrue(state.reports.isEmpty)
        XCTAssertEqual(state.runs, before.runs)
        XCTAssertEqual(state.messages, before.messages)
    }

    func testManualCompletionPreservesUnpassedOutdatedReportWithoutConfirmingIt() async throws {
        let task = try await directTask()
        let revision = try await repository.saveRevision(taskID: task.id, requirement: "需求", plan: "方案", acceptanceCriteria: ["人工核对"])
        try await repository.confirmRevision(id: revision.id)
        try await repository.transitionTask(id: task.id, to: .acceptance)
        let report = AcceptanceReport(projectID: project.id, taskID: task.id, revisionID: revision.id,
                                      codeFingerprint: "old-fingerprint", checkConfiguration: "old-checks",
                                      checks: [.init(title: "人工核对", passed: false, evidence: "尚未执行")], summary: "参考报告")
        try await repository.saveAcceptance(report)
        let changed = try await repository.saveRevision(taskID: task.id, requirement: "更新需求", plan: "待确认的新方案", acceptanceCriteria: [])
        let before = try await repository.snapshot()
        XCTAssertNil(changed.confirmedAt)
        XCTAssertTrue(try XCTUnwrap(before.reports.first).stale)
        try await repository.transitionTask(id: task.id, to: .completed)
        let state = try await repository.snapshot()
        let completed = try await repository.task(id: task.id)
        XCTAssertEqual(completed.phase, .completed)
        XCTAssertEqual(state.reports, before.reports, "Task completion must not rewrite report results or imply report approval")
        XCTAssertEqual(state.revisions, before.revisions)
        XCTAssertNil(state.reports.first?.humanConfirmedAt)
    }

    func testOtherRunInSameProjectAndUncertainStopStillBlockAllCompletionPaths() async throws {
        let task = try await directTask()
        let chat = try await repository.createConversation(projectID: project.id)
        let run = try await repository.prepareRun(conversationID: chat.id, prompt: "Another project writer")
        await expectFailure { try await self.repository.completeTask(id: task.id) }
        await expectFailure { try await self.repository.transitionTask(id: task.id, to: .completed) }
        try await repository.requestStop(id: run.id)
        try await repository.finishRun(id: run.id, status: .cancelled, stopConfirmed: false)
        await expectFailure { try await self.repository.completeTask(id: task.id) }
        let unchanged = try await repository.task(id: task.id)
        XCTAssertEqual(unchanged, task)
        try await repository.finishRun(id: run.id, status: .cancelled, stopConfirmed: true)
        try await repository.completeTask(id: task.id)
        let completed = try await repository.task(id: task.id)
        XCTAssertEqual(completed.phase, .completed)
        try await repository.completeTask(id: task.id)
        let repeated = try await repository.task(id: task.id)
        XCTAssertEqual(repeated, completed, "Repeated user actions must be idempotent")
    }

    func testStageBarrierStillBlocksCompletionAndEnginePreservesReports() async throws {
        let task = try await directTask()
        try await repository.beginStageChange(taskID: task.id)
        let engine = TaskEngine(repository: repository)
        await expectFailure { try await engine.completeTask(id: task.id) }
        await expectFailure { try await self.repository.transitionTask(id: task.id, to: .completed) }
        let unchanged = try await repository.task(id: task.id)
        XCTAssertEqual(unchanged, task)
        try await repository.abandonStageChange(taskID: task.id)
        try await engine.completeTask(id: task.id)
        let completed = try await repository.task(id: task.id)
        let state = try await repository.snapshot()
        XCTAssertEqual(completed.phase, .completed)
        XCTAssertTrue(state.reports.isEmpty && state.revisions.isEmpty)
    }
}
