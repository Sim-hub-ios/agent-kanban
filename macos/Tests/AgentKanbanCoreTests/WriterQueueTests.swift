import XCTest
@testable import AgentKanbanCore

@MainActor
final class WriterQueueTests: XCTestCase {
    private var directory: URL!
    private var repoURL: URL!
    private var databaseURL: URL!
    private var repository: Repository!
    private var project: Project!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("kanban-writer-queue-\(UUID().uuidString)")
        repoURL = directory.appendingPathComponent("repo")
        databaseURL = directory.appendingPathComponent("workspace.sqlite")
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try git(["init", "-q"])
        try Data("fixture".utf8).write(to: repoURL.appendingPathComponent("fixture.txt"))
        try git(["add", "fixture.txt"])
        try git(["-c", "user.name=Tests", "-c", "user.email=tests@example.invalid", "commit", "-qm", "fixture"])
        repository = try Repository(databaseURL: databaseURL)
        project = try await repository.importProject(path: repoURL.path)
    }

    override func tearDown() async throws {
        repository = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func git(_ arguments: [String], path: String? = nil) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path ?? repoURL.path] + arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
    }

    /// Deliberately model legacy payloads / stale external state, bypassing normal command guards.
    @discardableResult private func sql(_ statement: String) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        let output = Pipe(); process.arguments = [databaseURL.path, statement]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func expectFailure(_ action: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await action(); XCTFail("Operation must be rejected", file: file, line: line) } catch { }
    }

    private func writer(_ prompt: String, projectID: String? = nil) async throws -> RunRecord {
        let chat = try await repository.createConversation(projectID: projectID ?? project.id)
        return try await repository.prepareRun(conversationID: chat.id, prompt: prompt)
    }

    private func reader(_ title: String) async throws -> RunRecord {
        let task = try await repository.createTask(projectID: project.id, title: title)
        try await repository.transitionTask(id: task.id, to: .discussion)
        return try await repository.prepareRun(conversationID: task.mainConversationID, prompt: title)
    }

    private func finish(_ run: RunRecord, confirmed: Bool = true) async throws {
        try await repository.finishRun(id: run.id, status: .succeeded, stopConfirmed: confirmed)
    }

    private func worktree(_ name: String = "worktree") throws -> String {
        let path = directory.appendingPathComponent(name).path
        try git(["worktree", "add", "--detach", path, "HEAD"])
        return try GitRepository.canonicalRoot(path: path)
    }

    func testWriterFIFOUsesInsertionOrderAndDoesNotReserveQueuedDirectories() async throws {
        let active = try await writer("first")
        let second = try await writer("second")
        let third = try await writer("third")
        XCTAssertEqual(active.status, .starting)
        XCTAssertEqual(second.status, .queued); XCTAssertEqual(third.status, .queued)
        XCTAssertEqual(try sql("SELECT count(*) FROM directory_leases"), "1")
        // Wall-clock changes must not reorder user requests.
        try sql("UPDATE runs SET payload=json_set(payload,'$.createdAt',0) WHERE id='\(third.id)'")
        let blocked = try await repository.claimNextQueuedRun(); XCTAssertNil(blocked)
        try await finish(active)
        let next = try await repository.claimNextQueuedRun(); XCTAssertEqual(next?.id, second.id)
        XCTAssertEqual(next?.status, .starting)
        let stillBlocked = try await repository.claimNextQueuedRun(); XCTAssertNil(stillBlocked)
        try await finish(second)
        let last = try await repository.claimNextQueuedRun(); XCTAssertEqual(last?.id, third.id)
    }

    func testReaderCannotLeapfrogQueuedWriterAndConcurrentReadersStillWork() async throws {
        let firstReader = try await reader("first reader")
        let concurrentReader = try await reader("concurrent reader")
        XCTAssertEqual(concurrentReader.status, .starting)
        let waitingWriter = try await writer("writer")
        let lateReader = try await reader("late reader")
        XCTAssertEqual(waitingWriter.status, .queued); XCTAssertEqual(lateReader.status, .queued)
        let blocked = try await repository.claimNextQueuedRun(); XCTAssertNil(blocked)
        try await finish(firstReader)
        let stillBlocked = try await repository.claimNextQueuedRun(); XCTAssertNil(stillBlocked)
        try await finish(concurrentReader)
        let claimed = try await repository.claimNextQueuedRun(); XCTAssertEqual(claimed?.id, waitingWriter.id)
        try await finish(waitingWriter)
        let claimedReader = try await repository.claimNextQueuedRun(); XCTAssertEqual(claimedReader?.id, lateReader.id)
    }

    func testCancellingUnstartedQueueIsImmediatelyTerminalAndPreservesFIFO() async throws {
        let active = try await writer("active")
        let cancelled = try await writer("cancel")
        let next = try await writer("next")
        try await repository.requestStop(id: cancelled.id)
        let stopped = try await repository.run(id: cancelled.id)
        XCTAssertEqual(stopped.status, .cancelled); XCTAssertNotNil(stopped.endedAt)
        XCTAssertEqual(try sql("SELECT count(*) FROM directory_leases WHERE run_id='\(cancelled.id)'"), "0")
        try await repository.requestStop(id: cancelled.id)
        try await finish(active)
        let claimed = try await repository.claimNextQueuedRun(); XCTAssertEqual(claimed?.id, next.id)
        let snapshot = try await repository.snapshot()
        XCTAssertTrue(snapshot.events.contains { $0.runID == cancelled.id && $0.kind == "run.queue_cancelled" })
    }

    func testQueueSurvivesRestartButUnknownWriterKeepsItsProtection() async throws {
        let active = try await writer("active")
        let chat = try await repository.createConversation(projectID: project.id)
        let selection = ExecutionSelection(executor: .claude, modelID: "fixture-model", effort: "high", permission: .fullAccess)
        try await repository.updateSelection(conversationID: chat.id, selection: selection)
        let queued = try await repository.prepareRun(conversationID: chat.id, prompt: "frozen prompt", includeFullHistory: true)
        try await repository.updateSelection(conversationID: chat.id, selection: .init(executor: .codex))
        let reopened = try Repository(databaseURL: databaseURL)
        try await reopened.markInterruptedRunsForRecovery()
        let saved = try await reopened.run(id: queued.id)
        XCTAssertEqual(saved.status, .queued); XCTAssertEqual(saved.selection, selection)
        XCTAssertEqual(saved.includeFullHistory, true); XCTAssertEqual(saved.acceptanceReview, false)
        XCTAssertEqual(saved.prompt, "frozen prompt")
        let blocked = try await reopened.claimNextQueuedRun(); XCTAssertNil(blocked)
        let uncertain = try await reopened.run(id: active.id); XCTAssertEqual(uncertain.status, .recoveryRequired)
        try await reopened.finishRun(id: active.id, status: .cancelled, stopConfirmed: true)
        let claimed = try await reopened.claimNextQueuedRun(); XCTAssertEqual(claimed?.id, queued.id)
    }

    func testLegacyQueuedRunWithProcessOrLeaseRequiresRecovery() async throws {
        let leased = try await writer("legacy leased")
        let queued = try await writer("legacy process")
        try sql("UPDATE runs SET payload=json_set(payload,'$.status','queued') WHERE id='\(leased.id)'")
        try sql("UPDATE runs SET payload=json_set(payload,'$.processID',999999) WHERE id='\(queued.id)'")
        try await repository.markInterruptedRunsForRecovery()
        let first = try await repository.run(id: leased.id)
        let second = try await repository.run(id: queued.id)
        XCTAssertEqual(first.status, .recoveryRequired); XCTAssertEqual(second.status, .recoveryRequired)
        XCTAssertEqual(try sql("SELECT count(*) FROM directory_leases"), "1")
        let next = try await writer("must wait"); XCTAssertEqual(next.status, .queued)
        let claim = try await repository.claimNextQueuedRun(); XCTAssertNil(claim)
    }

    func testUncertainFinishKeepsQueueBlockedUntilStopConfirmed() async throws {
        let active = try await writer("active")
        let queued = try await writer("queued")
        try await finish(active, confirmed: false)
        XCTAssertEqual(try sql("SELECT count(*) FROM directory_leases"), "1")
        let blocked = try await repository.claimNextQueuedRun(); XCTAssertNil(blocked)
        try await repository.finishRun(id: active.id, status: .cancelled, stopConfirmed: true)
        let claimed = try await repository.claimNextQueuedRun(); XCTAssertEqual(claimed?.id, queued.id)
    }

    func testQueuedRunCannotStartOrAttachExecutorBeforeClaim() async throws {
        _ = try await writer("active")
        let queued = try await writer("queued")
        await expectFailure { try await self.repository.markRunStarted(id: queued.id, processID: 999999) }
        await expectFailure { try await self.repository.updateRunMetadata(id: queued.id, sessionID: "unexpected") }
        await expectFailure {
            _ = try await self.repository.saveApproval(.init(projectID: self.project.id, runID: queued.id, requestID: "unexpected", title: "tool", detail: "tool", options: []))
        }
        let stored = try await repository.run(id: queued.id)
        XCTAssertEqual(stored.status, .queued); XCTAssertNil(stored.processID); XCTAssertNil(stored.executorSessionID)
    }

    func testTwoRepositoriesCanClaimAWaitingWriterOnlyOnce() async throws {
        let active = try await writer("active")
        let queued = try await writer("queued")
        try await finish(active)
        let first = try XCTUnwrap(repository)
        let second = try Repository(databaseURL: databaseURL)
        let claimed = await withTaskGroup(of: String?.self) { group in
            for repo in [first, second] { group.addTask { try? await repo.claimNextQueuedRun()?.id } }
            var ids: [String] = []
            for await id in group { if let id { ids.append(id) } }
            return ids
        }
        XCTAssertEqual(claimed, [queued.id])
        XCTAssertEqual(try sql("SELECT count(*) FROM directory_leases"), "1")
    }

    func testReturningUnstartedClaimRetainsItsOriginalFIFOPosition() async throws {
        let active = try await writer("active")
        let queued = try await writer("queued")
        let later = try await writer("later")
        try await finish(active)
        let first = try await repository.claimNextQueuedRun(); XCTAssertEqual(first?.id, queued.id)
        try await repository.returnUnstartedRunToQueue(id: queued.id)
        XCTAssertEqual(try sql("SELECT count(*) FROM directory_leases"), "0")
        let reclaimed = try await repository.claimNextQueuedRun(); XCTAssertEqual(reclaimed?.id, queued.id)
        try await repository.markRunStarted(id: queued.id, processID: 999999)
        await expectFailure { try await self.repository.returnUnstartedRunToQueue(id: queued.id) }
        let waiting = try await repository.run(id: later.id); XCTAssertEqual(waiting.status, .queued)
    }

    func testInvalidPhaseVersionRevisionAndBarrierCancelStaleIntent() async throws {
        for mutation in ["version", "revision", "barrier"] {
            let active = try await writer("active \(mutation)")
            let task = try await repository.createTask(projectID: project.id, title: mutation)
            let queued = try await repository.prepareRun(conversationID: task.mainConversationID, prompt: mutation, directImplementation: true)
            switch mutation {
            case "version": try sql("UPDATE tasks SET payload=json_set(payload,'$.phaseVersion',2,'$.directImplementationPhaseVersion',2) WHERE id='\(task.id)'")
            case "revision": try sql("UPDATE tasks SET payload=json_set(payload,'$.currentRevisionID','new-revision') WHERE id='\(task.id)'")
            default: try await repository.beginStageChange(taskID: task.id)
            }
            try await finish(active)
            let claim = try await repository.claimNextQueuedRun(); XCTAssertNil(claim)
            let cancelled = try await repository.run(id: queued.id)
            XCTAssertEqual(cancelled.status, .cancelled); XCTAssertNotNil(cancelled.endedAt)
            let snapshot = try await repository.snapshot()
            XCTAssertTrue(snapshot.events.contains { $0.runID == queued.id && $0.kind == "run.queue_cancelled" })
            if mutation == "barrier" { try await repository.abandonStageChange(taskID: task.id) }
        }
    }

    func testDeletedConversationAndRemovedProjectCancelStaleQueue() async throws {
        for mutation in ["conversation", "project"] {
            let active = try await writer("active")
            let queued = try await writer("queued")
            if mutation == "conversation" {
                try sql("INSERT INTO conversation_deletions(conversation_id,deleted_at) VALUES('\(queued.conversationID)','0')")
            } else {
                try sql("UPDATE projects SET active=0,payload=json_set(payload,'$.removedAt',0) WHERE id='\(project.id)'")
            }
            try await finish(active)
            let claim = try await repository.claimNextQueuedRun(); XCTAssertNil(claim)
            let cancelled = try await repository.run(id: queued.id); XCTAssertEqual(cancelled.status, .cancelled)
            if mutation == "project" { try sql("UPDATE projects SET active=1,payload=json_remove(payload,'$.removedAt') WHERE id='\(project.id)'") }
        }
    }

    func testIndependentProjectsClaimWhileEarlierDirectoryIsBlocked() async throws {
        _ = try await writer("active first project")
        _ = try await writer("blocked first project")
        let secondURL = directory.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: secondURL, withIntermediateDirectories: true)
        try git(["init", "-q"], path: secondURL.path)
        let other = try await repository.importProject(path: secondURL.path)
        let active = try await writer("active other", projectID: other.id)
        let queued = try await writer("queued other", projectID: other.id)
        try await finish(active)
        let claim = try await repository.claimNextQueuedRun(); XCTAssertEqual(claim?.id, queued.id)
    }

    func testDifferentWorktreesRunConcurrentlyAndCompleteIndependently() async throws {
        let isolated = try worktree()
        let mainTask = try await repository.createTask(projectID: project.id, title: "main")
        let isolatedTask = try await repository.createTask(projectID: project.id, title: "isolated")
        try await repository.configureTaskWorktree(taskID: isolatedTask.id, path: isolated)
        let main = try await repository.prepareRun(conversationID: mainTask.mainConversationID, prompt: "main", directImplementation: true)
        let independent = try await repository.prepareRun(conversationID: isolatedTask.mainConversationID, prompt: "isolated", directImplementation: true)
        XCTAssertEqual(main.status, .starting); XCTAssertEqual(independent.status, .starting)
        XCTAssertEqual(main.cwd, project.path); XCTAssertEqual(independent.cwd, isolated)
        XCTAssertEqual(try sql("SELECT count(*) FROM directory_leases"), "2")
        try await finish(independent)
        try await repository.completeTask(id: isolatedTask.id)
        let completed = try await repository.task(id: isolatedTask.id); XCTAssertEqual(completed.phase, .completed)
        let mainStillActive = try await repository.run(id: main.id); XCTAssertEqual(mainStillActive.status, .starting)
        await expectFailure { try await self.repository.configureTaskWorktree(taskID: isolatedTask.id, path: nil) }
    }

    func testSameWorktreeQueuesEvenWhenImportedAsAnotherProject() async throws {
        let isolated = try worktree()
        let task = try await repository.createTask(projectID: project.id, title: "linked")
        try await repository.configureTaskWorktree(taskID: task.id, path: isolated)
        let main = try await repository.prepareRun(conversationID: task.mainConversationID, prompt: "isolated", directImplementation: true)
        let imported = try await repository.importProject(path: isolated)
        let queued = try await writer("same physical path", projectID: imported.id)
        XCTAssertEqual(queued.status, .queued)
        try await finish(main)
        let claimed = try await repository.claimNextQueuedRun(); XCTAssertEqual(claimed?.id, queued.id)
    }

    func testWorktreeConfigurationRevalidatesOwnershipAndInvalidatesReports() async throws {
        let isolated = try worktree()
        let task = try await repository.createTask(projectID: project.id, title: "report")
        try await repository.transitionTask(id: task.id, to: .discussion)
        let revision = try await repository.saveRevision(taskID: task.id, requirement: "requirement", plan: "plan", acceptanceCriteria: ["check"])
        try await repository.confirmRevision(id: revision.id)
        try await repository.transitionTask(id: task.id, to: .acceptance)
        let report = AcceptanceReport(projectID: project.id, taskID: task.id, revisionID: revision.id, codeFingerprint: try GitRepository.fingerprint(path: project.path), checks: [.init(title: "check", passed: true, evidence: "fixture")], summary: "fixture")
        try await repository.saveAcceptance(report)
        try await repository.configureTaskWorktree(taskID: task.id, path: isolated)
        let changed = try await repository.task(id: task.id); XCTAssertEqual(changed.worktreePath, isolated)
        let state = try await repository.snapshot(); XCTAssertEqual(state.reports.first?.stale, true)
        let run = try await repository.prepareRun(conversationID: task.mainConversationID, prompt: "review", acceptanceReview: true)
        XCTAssertEqual(run.cwd, isolated); XCTAssertEqual(run.acceptanceReview, true)
        await expectFailure { try await self.repository.configureTaskWorktree(taskID: task.id, path: nil) }
        try await finish(run)
        try await repository.beginStageChange(taskID: task.id)
        await expectFailure { try await self.repository.configureTaskWorktree(taskID: task.id, path: nil) }
        try await repository.abandonStageChange(taskID: task.id)
        await expectFailure { try await self.repository.configureTaskWorktree(taskID: task.id, path: self.project.path) }
        try await repository.configureTaskWorktree(taskID: task.id, path: nil)
        let restored = try await repository.task(id: task.id); XCTAssertNil(restored.worktreePath)
    }

    func testWorktreeRemovalCancelsWaitingIntentWithoutLaunching() async throws {
        let isolated = try worktree()
        let first = try await repository.createTask(projectID: project.id, title: "first")
        let second = try await repository.createTask(projectID: project.id, title: "second")
        for task in [first, second] { try await repository.configureTaskWorktree(taskID: task.id, path: isolated) }
        let active = try await repository.prepareRun(conversationID: first.mainConversationID, prompt: "first", directImplementation: true)
        let queued = try await repository.prepareRun(conversationID: second.mainConversationID, prompt: "second", directImplementation: true)
        XCTAssertEqual(queued.status, .queued)
        try await finish(active)
        try git(["worktree", "remove", isolated])
        let claim = try await repository.claimNextQueuedRun(); XCTAssertNil(claim)
        let cancelled = try await repository.run(id: queued.id); XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertEqual(try sql("SELECT count(*) FROM directory_leases"), "0")
    }

    func testLegacyPayloadsDecodeWithoutNewOptionalFields() throws {
        let task = TaskItem(projectID: "project", number: 1, title: "legacy")
        let run = RunRecord(projectID: "project", conversationID: task.mainConversationID, selection: .init(), cwd: "/fixture", prompt: "legacy", writing: true)
        let decodedTask = try JSONDecoder().decode(TaskItem.self, from: JSONEncoder().encode(task))
        let decodedRun = try JSONDecoder().decode(RunRecord.self, from: JSONEncoder().encode(run))
        XCTAssertNil(decodedTask.worktreePath); XCTAssertNil(decodedRun.includeFullHistory); XCTAssertNil(decodedRun.acceptanceReview)
    }
}
