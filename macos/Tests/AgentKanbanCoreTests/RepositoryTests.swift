import XCTest
@testable import AgentKanbanCore

@MainActor
final class RepositoryTests: XCTestCase {
    private var directory: URL!
    private var repoURL: URL!
    private var databaseURL: URL!
    private var repository: Repository!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-kanban-core-tests-\(UUID().uuidString)")
        repoURL = directory.appendingPathComponent("repo")
        databaseURL = directory.appendingPathComponent("data/workspace.sqlite")
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try git(["init", "--quiet"])
        repository = try Repository(databaseURL: databaseURL)
    }
    override func tearDown() async throws {
        repository = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }
    private func git(_ args: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = ["-C", repoURL.path] + args
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
    }
    private func expectFailure(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Operation should have been rejected", file: file, line: line) } catch { }
    }
    private func project(_ executor: ExecutorID = .codex) async throws -> Project { try await repository.importProject(path: repoURL.path, defaultExecutor: executor) }
    private func readyTask(_ project: Project) async throws -> TaskItem {
        let task = try await repository.createTask(projectID: project.id, title: "修复粘贴", description: "第一行\n第二行", type: .bug)
        try await repository.transitionTask(id: task.id, to: .discussion)
        let revision = try await repository.saveRevision(taskID: task.id, requirement: "粘贴可用", plan: "检查并修复输入处理", acceptanceCriteria: ["粘贴验证码成功"])
        try await repository.confirmRevision(id: revision.id)
        return try await repository.task(id: task.id)
    }

    func testCreationIsAtomicAndUsesNativeDefaultsWithoutRuns() async throws {
        let project = try await project(.claude)
        let conversation = try await repository.createConversation(projectID: project.id)
        try await repository.updateSelection(conversationID: conversation.id, selection: .init(executor: .cursor, modelID: "grok", effort: "high", permission: .fullAccess))
        let task = try await repository.createTask(projectID: project.id, title: "新任务", description: "line1\nline2")
        XCTAssertEqual(task.selection, ExecutionSelection(executor: .claude))
        let snapshot = try await repository.snapshot()
        XCTAssertEqual(snapshot.conversations.filter { $0.taskID == task.id }.count, 1)
        XCTAssertEqual(snapshot.conversations.first { $0.id == task.mainConversationID }?.projectID, project.id)
        XCTAssertEqual(task.phase, .backlog); XCTAssertEqual(task.description, "line1\nline2"); XCTAssertTrue(snapshot.runs.isEmpty)
        let reopened = try Repository(databaseURL: databaseURL)
        let restored = try await reopened.snapshot(); XCTAssertEqual(restored.tasks, snapshot.tasks)
    }

    func testActiveCanonicalProjectDedupeAndReimportCreatesFreshIdentity() async throws {
        let first = try await project()
        let second = try await repository.importProject(path: repoURL.appendingPathComponent(".").path)
        XCTAssertEqual(first.id, second.id)
        _ = try await repository.createTask(projectID: first.id, title: "旧历史")
        try await repository.removeProject(id: first.id)
        let reopened = try Repository(databaseURL: databaseURL)
        let empty = try await reopened.snapshot(); XCTAssertTrue(empty.projects.isEmpty); XCTAssertTrue(empty.tasks.isEmpty)
        let imported = try await reopened.importProject(path: repoURL.path)
        XCTAssertNotEqual(imported.id, first.id)
        let fresh = try await reopened.snapshot(); XCTAssertTrue(fresh.tasks.isEmpty); XCTAssertTrue(fresh.runs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repoURL.appendingPathComponent(".git").path))
    }

    func testImportActivityBlocksRemovalAndBatchIsIdempotent() async throws {
        let project = try await project(.claude)
        let chat = try await repository.createConversation(projectID: project.id)
        try await repository.updateSelection(conversationID: chat.id, selection: .init(executor: .cursor, modelID: "composer-2.5", permission: .fullAccess))
        try await repository.beginImport(conversationID: chat.id, operationKey: "instruction-1")
        await expectFailure { try await self.repository.removeProject(id: project.id) }
        let candidate = ImportCandidate(sourceKey: "github:123:456", sourceURL: "https://github.com/a/b/issues/1", sourceDescription: "Issue #1", title: "导入任务", description: "多行\n说明", type: .bug, priority: .high)
        let batch = try await repository.commitImportBatch(conversationID: chat.id, requestMessageID: "msg-1", operationKey: "instruction-1", candidates: [candidate, candidate], errors: ["row 3: 标题为空"])
        XCTAssertEqual(batch.createdTaskIDs.count, 1); XCTAssertEqual(batch.duplicateCount, 1); XCTAssertEqual(batch.errors.count, 1)
        let retry = try await repository.importCandidates(conversationID: chat.id, batchKey: "instruction-1", candidates: [candidate])
        XCTAssertEqual(retry.id, batch.id)
        let second = try await repository.importCandidates(conversationID: chat.id, batchKey: "instruction-2", candidates: [candidate])
        XCTAssertTrue(second.createdTaskIDs.isEmpty); XCTAssertEqual(second.duplicateCount, 1)
        let snapshot = try await repository.snapshot(); XCTAssertEqual(snapshot.tasks.count, 1); XCTAssertTrue(snapshot.runs.isEmpty)
        XCTAssertEqual(snapshot.tasks[0].selection, .init(executor: .claude)); XCTAssertEqual(snapshot.tasks[0].phase, .backlog)
        XCTAssertEqual(snapshot.provenance[0].sourceURL, candidate.sourceURL)
        // Completed retry must not leave an import activity lease behind.
        try await repository.removeProject(id: project.id)
    }

    func testExclusiveWriterAlsoQueuesReadOnlyReview() async throws {
        let project = try await project()
        let task = try await readyTask(project)
        let chat = try await repository.createConversation(projectID: project.id)
        let review = try await repository.prepareRun(conversationID: task.mainConversationID, prompt: "分析问题")
        XCTAssertFalse(review.writing)
        let waitingWriter = try await repository.prepareRun(conversationID: chat.id, prompt: "修改代码")
        XCTAssertEqual(waitingWriter.status, .queued)
        try await repository.finishRun(id: review.id, status: .succeeded, stopConfirmed: true)
        let claimedWriter = try await repository.claimNextQueuedRun()
        let writer = try XCTUnwrap(claimedWriter)
        XCTAssertEqual(writer.id, waitingWriter.id)
        XCTAssertTrue(writer.writing)
        let waitingReview = try await repository.prepareRun(conversationID: task.mainConversationID, prompt: "分析问题")
        XCTAssertEqual(waitingReview.status, .queued)
        try await repository.finishRun(id: writer.id, status: .cancelled, stopConfirmed: true)
        let claimedReview = try await repository.claimNextQueuedRun()
        XCTAssertEqual(claimedReview?.id, waitingReview.id)
    }

    func testStopBarrierAndRestartNeverReleaseUncertainWriter() async throws {
        let project = try await project()
        let task = try await readyTask(project)
        try await repository.transitionTask(id: task.id, to: .development)
        let run = try await repository.prepareRun(conversationID: task.mainConversationID, prompt: "开发")
        try await repository.markRunStarted(id: run.id, sessionID: "native-session", processID: 999999, processStartedAt: Date())
        try await repository.beginStageChange(taskID: task.id)
        try await repository.requestStop(id: run.id)
        await expectFailure { try await self.repository.transitionTask(id: task.id, to: .acceptance) }
        try await repository.finishRun(id: run.id, status: .cancelled, stopConfirmed: false)
        let uncertain = try await repository.run(id: run.id); XCTAssertEqual(uncertain.status, .recoveryRequired)
        let reopened = try Repository(databaseURL: databaseURL)
        try await reopened.markInterruptedRunsForRecovery()
        let chat = try await reopened.createConversation(projectID: project.id)
        let queued = try await reopened.prepareRun(conversationID: chat.id, prompt: "第二写入")
        XCTAssertEqual(queued.status, .queued)
        let blocked = try await reopened.claimNextQueuedRun()
        XCTAssertNil(blocked)
        let preserved = try await reopened.task(id: task.id); XCTAssertEqual(preserved.phase, .development)
        try await reopened.finishRun(id: run.id, status: .cancelled, stopConfirmed: true)
        try await reopened.transitionTask(id: task.id, to: .acceptance)
        let changed = try await reopened.task(id: task.id); XCTAssertEqual(changed.phase, .acceptance)
    }

    func testPhaseBarrierReservesIdleTaskAndSelectionDoesNotMutateRun() async throws {
        let project = try await project()
        let task = try await readyTask(project)
        try await repository.beginStageChange(taskID: task.id)
        await expectFailure { _ = try await self.repository.prepareRun(conversationID: task.mainConversationID, prompt: "讨论") }
        await expectFailure { try await self.repository.removeProject(id: project.id) }
        try await repository.abandonStageChange(taskID: task.id)
        let run = try await repository.prepareRun(conversationID: task.mainConversationID, prompt: "讨论")
        try await repository.updateSelection(conversationID: task.mainConversationID, selection: .init(executor: .claude, modelID: "claude-opus-5-5", effort: "max"))
        let stored = try await repository.run(id: run.id); XCTAssertEqual(stored.selection, run.selection); XCTAssertEqual(stored.selection.executor, .codex)
        try await repository.finishRun(id: run.id, status: .succeeded, stopConfirmed: true)
    }

    func testApprovalKeepsOtherPendingRequestAndRejectsAfterStop() async throws {
        let project = try await project(); let chat = try await repository.createConversation(projectID: project.id)
        let run = try await repository.prepareRun(conversationID: chat.id, prompt: "工作")
        let options = [ApprovalOption(id: "allow-once", title: "允许一次", allows: true), ApprovalOption(id: "deny", title: "拒绝", allows: false)]
        let first = try await repository.saveApproval(.init(projectID: project.id, runID: run.id, requestID: "request1", title: "命令", detail: "tool", options: options))
        let second = try await repository.saveApproval(.init(projectID: project.id, runID: run.id, requestID: "request2", title: "文件", detail: "file", options: options))
        _ = try await repository.decideApproval(id: first.id, optionID: "allow-once")
        let waiting = try await repository.run(id: run.id); XCTAssertEqual(waiting.status, .waitingApproval)
        try await repository.requestStop(id: run.id)
        await expectFailure { _ = try await self.repository.decideApproval(id: second.id, optionID: "allow-once") }
        let snapshot = try await repository.snapshot(); XCTAssertEqual(snapshot.approvals.first { $0.id == second.id }?.status, .expired)
    }

    func testNewRequirementAndCodeChangesInvalidateAcceptance() async throws {
        let project = try await project(); let task = try await readyTask(project)
        try await repository.transitionTask(id: task.id, to: .acceptance)
        let fingerprint = try GitRepository.fingerprint(path: project.path)
        let report = AcceptanceReport(projectID: project.id, taskID: task.id, revisionID: try XCTUnwrap(task.currentRevisionID), codeFingerprint: fingerprint, checks: [.init(title: "粘贴可用", passed: true, evidence: "manual proof")], summary: "通过")
        try await repository.saveAcceptance(report)
        try Data("new code".utf8).write(to: repoURL.appendingPathComponent("untracked.swift"))
        let changed = try GitRepository.fingerprint(path: project.path)
        try await repository.invalidateAcceptanceReport(id: report.id, currentFingerprint: changed)
        let snapshot = try await repository.snapshot(); XCTAssertTrue(try XCTUnwrap(snapshot.reports.first).stale)
        XCTAssertEqual(snapshot.tasks[0].phase, .acceptance)
        let revision = try await repository.saveRevision(taskID: task.id, requirement: "新需求", plan: "新方案", acceptanceCriteria: ["新标准"])
        XCTAssertNil(revision.confirmedAt)
        await expectFailure { try await self.repository.transitionTask(id: task.id, to: .development) }
        try await repository.confirmRevision(id: revision.id)
        let newReport = AcceptanceReport(projectID: project.id, taskID: task.id, revisionID: revision.id, codeFingerprint: changed, checks: [.init(title: "新标准", passed: true, evidence: "new proof")], summary: "通过")
        try await repository.saveAcceptance(newReport)
        try await repository.completeTask(id: task.id)
        let completed = try await repository.task(id: task.id); XCTAssertEqual(completed.phase, .completed)
    }

    func testFingerprintIncludesStagedUnstagedAndUntrackedContents() throws {
        try Data("initial\n".utf8).write(to: repoURL.appendingPathComponent("tracked.txt"))
        try git(["add", "tracked.txt"]); try git(["-c", "user.name=Tests", "-c", "user.email=tests@example.invalid", "commit", "--quiet", "-m", "test fixture"])
        let initial = try GitRepository.fingerprint(path: repoURL.path)
        try Data("unstaged\n".utf8).write(to: repoURL.appendingPathComponent("tracked.txt"))
        let unstaged = try GitRepository.fingerprint(path: repoURL.path); XCTAssertNotEqual(initial, unstaged)
        try git(["add", "tracked.txt"])
        let staged = try GitRepository.fingerprint(path: repoURL.path); XCTAssertNotEqual(unstaged, staged)
        try Data("new A".utf8).write(to: repoURL.appendingPathComponent("new.txt"))
        let first = try GitRepository.fingerprint(path: repoURL.path)
        try Data("new B".utf8).write(to: repoURL.appendingPathComponent("new.txt"))
        let second = try GitRepository.fingerprint(path: repoURL.path); XCTAssertNotEqual(first, second)
    }

    func testDelimitedReaderPreservesQuotesBOMAndEmbeddedNewlines() throws {
        let text = "\u{feff}标题,说明\r\n\"修复,输入\",\"第一行\n第二行 \"\"引用\"\"\"\r\n"
        let rows = try TaskImport.parseDelimited(text)
        XCTAssertEqual(rows, [["标题", "说明"], ["修复,输入", "第一行\n第二行 \"引用\""]])
        XCTAssertThrowsError(try TaskImport.parseDelimited("title\n\"unclosed"))
        XCTAssertTrue(TaskImport.hasImportIntent("把附件中的任务导入看板")); XCTAssertFalse(TaskImport.hasImportIntent("看看这个附件"))
    }

    func testFingerprintTracksDifferentDirtySubmoduleContents() throws {
        let submoduleSource = directory.appendingPathComponent("module-source")
        try FileManager.default.createDirectory(at: submoduleSource, withIntermediateDirectories: true)
        func moduleGit(_ args: [String]) throws {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = ["-C", submoduleSource.path] + args
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        }
        try moduleGit(["init", "--quiet"])
        try Data("initial".utf8).write(to: submoduleSource.appendingPathComponent("source.swift"))
        try moduleGit(["add", "source.swift"])
        try moduleGit(["-c", "user.name=Tests", "-c", "user.email=tests@example.invalid", "commit", "--quiet", "-m", "module fixture"])
        try git(["-c", "protocol.file.allow=always", "submodule", "add", "--quiet", submoduleSource.path, "module"])
        try git(["-c", "user.name=Tests", "-c", "user.email=tests@example.invalid", "commit", "--quiet", "-m", "parent fixture"])
        let initial = try GitRepository.fingerprint(path: repoURL.path)
        let moduleFile = repoURL.appendingPathComponent("module/source.swift")
        try Data("dirty A".utf8).write(to: moduleFile)
        let firstDirty = try GitRepository.fingerprint(path: repoURL.path)
        try Data("dirty B".utf8).write(to: moduleFile)
        let secondDirty = try GitRepository.fingerprint(path: repoURL.path)
        XCTAssertNotEqual(initial, firstDirty); XCTAssertNotEqual(firstDirty, secondDirty)
        try git(["submodule", "deinit", "--force", "--all"])
        XCTAssertThrowsError(try GitRepository.fingerprint(path: repoURL.path))
    }

    func testSQLiteSerializesConcurrentWritersAcrossRepositoryInstances() async throws {
        let project = try await project()
        let firstChat = try await repository.createConversation(projectID: project.id)
        let secondChat = try await repository.createConversation(projectID: project.id)
        let firstRepository = try XCTUnwrap(repository)
        let secondRepository = try Repository(databaseURL: databaseURL)
        let winners = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                do { return try await firstRepository.prepareRun(conversationID: firstChat.id, prompt: "writer1").id }
                catch { return nil }
            }
            group.addTask {
                do { return try await secondRepository.prepareRun(conversationID: secondChat.id, prompt: "writer2").id }
                catch { return nil }
            }
            var ids: [String] = []
            for await value in group { if let value { ids.append(value) } }
            return ids
        }
        XCTAssertEqual(winners.count, 2, "Both requests persist; only one reserves the directory")
        let snapshot = try await repository.snapshot()
        XCTAssertEqual(snapshot.runs.filter { $0.status == .starting }.count, 1)
        XCTAssertEqual(snapshot.runs.filter { $0.status == .queued }.count, 1)
        for run in snapshot.runs { try await repository.finishRun(id: run.id, status: .cancelled, stopConfirmed: true) }
    }

    func testDirectoryIdentityChangeRejectsNewExecution() async throws {
        let project = try await project()
        let chat = try await repository.createConversation(projectID: project.id)
        let moved = directory.appendingPathComponent("moved-repo")
        try FileManager.default.moveItem(at: repoURL, to: moved)
        try FileManager.default.createSymbolicLink(at: repoURL, withDestinationURL: moved)
        await expectFailure { _ = try await self.repository.prepareRun(conversationID: chat.id, prompt: "write") }
        let snapshot = try await repository.snapshot(); XCTAssertTrue(snapshot.runs.isEmpty)
    }

    func testWatcherInvalidatesOnlyObservedReportAndPreservesNewMatchingReport() async throws {
        let project = try await project(); let task = try await readyTask(project)
        try await repository.transitionTask(id: task.id, to: .acceptance)
        let old = AcceptanceReport(projectID: project.id, taskID: task.id, revisionID: try XCTUnwrap(task.currentRevisionID), codeFingerprint: "old-code", checks: [.init(title: "check", passed: true, evidence: "old")], summary: "old")
        try await repository.saveAcceptance(old)
        // A watcher captured old.id, then a new report committed while fingerprint I/O awaited.
        let fresh = AcceptanceReport(projectID: project.id, taskID: task.id, revisionID: try XCTUnwrap(task.currentRevisionID), codeFingerprint: "current-code", checks: [.init(title: "check", passed: true, evidence: "fresh")], summary: "fresh")
        try await repository.saveAcceptance(fresh)
        try await repository.invalidateAcceptanceReport(id: old.id, currentFingerprint: "current-code")
        try await repository.invalidateAcceptanceReport(id: fresh.id, currentFingerprint: "current-code")
        let state = try await repository.snapshot()
        XCTAssertTrue(try XCTUnwrap(state.reports.first { $0.id == old.id }).stale)
        XCTAssertFalse(try XCTUnwrap(state.reports.first { $0.id == fresh.id }).stale)
    }

    func testCancelledAcceptanceCannotCommitReportFromLateCompletion() async throws {
        let project = try await project(); let task = try await readyTask(project)
        try await repository.transitionTask(id: task.id, to: .acceptance)
        let run = try await repository.prepareRun(conversationID: task.mainConversationID, prompt: "验收")
        let report = AcceptanceReport(projectID: project.id, taskID: task.id, revisionID: try XCTUnwrap(task.currentRevisionID), codeFingerprint: "code", checks: [.init(title: "check", passed: true, evidence: "proof")], summary: "通过")
        try await repository.requestStop(id: run.id)
        await expectFailure { try await self.repository.saveAcceptance(report, sourceRunID: run.id) }
        try await repository.finishRun(id: run.id, status: .cancelled, stopConfirmed: true)
        await expectFailure { try await self.repository.saveAcceptance(report, sourceRunID: run.id) }
        let state = try await repository.snapshot(); XCTAssertTrue(state.reports.isEmpty)
        let fresh = try await repository.prepareRun(conversationID: task.mainConversationID, prompt: "重新验收")
        try await repository.saveAcceptance(report, sourceRunID: fresh.id)
        let committed = try await repository.snapshot()
        XCTAssertEqual(committed.reports.first?.sourceRunID, fresh.id)
    }

    func testReportCommittedBeforeCancellationRemainsReferenceForManualCompletion() async throws {
        let project = try await project(); let task = try await readyTask(project)
        try await repository.transitionTask(id: task.id, to: .acceptance)
        let run = try await repository.prepareRun(conversationID: task.mainConversationID, prompt: "验收")
        let report = AcceptanceReport(projectID: project.id, taskID: task.id, revisionID: try XCTUnwrap(task.currentRevisionID), codeFingerprint: "code", checks: [.init(title: "check", passed: true, evidence: "proof")], summary: "通过")
        try await repository.saveAcceptance(report, sourceRunID: run.id)
        // Cancellation arrived between report commit and the completed-event finalizer.
        try await repository.requestStop(id: run.id)
        try await repository.finishRun(id: run.id, status: .cancelled, stopConfirmed: true)
        let before = try await repository.snapshot()
        try await repository.completeTask(id: task.id)
        let completed = try await repository.task(id: task.id); XCTAssertEqual(completed.phase, .completed)
        let after = try await repository.snapshot()
        XCTAssertEqual(after.reports, before.reports)
        XCTAssertNil(after.reports.first?.humanConfirmedAt)
    }
}
