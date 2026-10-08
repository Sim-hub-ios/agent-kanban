import Foundation
import Testing
import AgentKanbanCore
import AgentKanbanExecutors
@testable import AgentKanban

private actor FixtureExecutor: ExecutorService {
    var requests: [ExecutorRequest] = []
    var hold = false
    var continuations: [String: AsyncStream<ExecutorEvent>.Continuation] = [:]
    func probe(_ executor: ExecutorID) async -> ExecutorInstallation {
        try? await Task.sleep(for: .milliseconds(30))
        return ExecutorInstallation(id: executor, authentication: .authenticated, detail: "Fixture only")
    }
    func models(_ executor: ExecutorID) async throws -> [ExecutorModel] {
        [ExecutorModel(id: "gpt-6.1-sol", displayName: "GPT-6.1 Sol", efforts: ["low", "high"], verified: true), ExecutorModel(id: "gpt-6-astra", displayName: "GPT-6 Astra", efforts: ["low", "high"], verified: true)]
    }
    func setHold() { hold = true }
    func start(_ request: ExecutorRequest) async throws -> ExecutorRun {
        requests.append(request)
        let pair = AsyncStream<ExecutorEvent>.makeStream()
        continuations[request.runID] = pair.continuation
        if !hold { pair.continuation.yield(.textDelta("真实协议 fixture 回复")); pair.continuation.yield(.completed(output: "真实协议 fixture 回复")); pair.continuation.finish() }
        return ExecutorRun(id: request.runID, events: pair.stream)
    }
    func respond(runID: String, approvalID: String, decision: ApprovalDecision) async throws {}
    func cancel(runID: String) async -> CancellationResult {
        guard let continuation = continuations[runID] else { return .unknown("not owned") }
        continuation.yield(.cancelled); continuation.finish(); return .confirmed
    }
}

private actor RetryImportReader: TaskImportReading {
    var messages: [String] = []
    func read(files: [URL], message: String, sourceIdentities: [String: String]) async -> ImportReadResult {
        messages.append(message)
        if messages.count == 1 { return ImportReadResult(failures: ["Fixture: GitHub login required"]) }
        return ImportReadResult(candidates: [.init(sourceKey: "github:superim/bug-tracker#418", sourceURL: "https://github.com/SuperIM/bug-tracker/issues/418", sourceDescription: "Issue #418", title: "Issue 418 regression")], sourceRange: "https://github.com/SuperIM/bug-tracker/issues?state=open&assignee=zfsherman")
    }
}

@Suite("Native application orchestration") @MainActor struct AppStoreTests {
    private func fixture() throws -> (URL, AppStore, FixtureExecutor) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kanban-app-test-\(UUID().uuidString)")
        let repository = directory.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let git = Process(); git.executableURL = URL(fileURLWithPath: "/usr/bin/git"); git.arguments = ["init", "-q", repository.path]
        try git.run(); git.waitUntilExit()
        let executor = FixtureExecutor()
        return (directory, AppStore(dataDirectory: directory.appendingPathComponent("data"), executors: executor), executor)
    }
    private func eventually(_ condition: @MainActor () async throws -> Bool) async throws {
        for _ in 0..<200 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await condition(), "Asynchronous application operation did not finish")
    }
    @Test func backlogSavesNotesWithoutModelRequest() async throws {
        let (directory, store, executor) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try #require(store.repository)
        let project = try await repository.importProject(path: directory.appendingPathComponent("repo").path, defaultExecutor: .cursor)
        let task = try await repository.createTask(projectID: project.id, title: "多行备注", description: "第一行\n第二行")
        try await store.reload(); store.selectTask(task.id)
        store.sendMessage("补充第一行\n补充第二行", attachments: [])
        try await eventually { store.snapshot.messages.count == 1 }
        #expect(store.snapshot.runs.isEmpty)
        #expect(await executor.requests.isEmpty)
        #expect(store.snapshot.messages[0].content.contains("\n"))
        #expect(store.currentSelection == ExecutionSelection(executor: .cursor))
    }
    @Test func addIssuesToBoardCreatesActualTasksInsteadOfModelReply() async throws {
        let (directory, store, executor) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("issues.csv")
        try "title,id\nIssue 418 regression,418".write(to: file, atomically: true, encoding: .utf8)
        let repository = try #require(store.repository)
        let project = try await repository.importProject(path: directory.appendingPathComponent("repo").path)
        let conversation = try await repository.createConversation(projectID: project.id)
        try await store.reload(); store.selectConversation(conversation.id)
        store.sendMessage("帮我将这些 Issue 添加到任务看板中", attachments: [file])
        try await eventually {
            store.snapshot.importBatches.count == 1 || store.snapshot.runs.first?.status.isTerminal == true
        }
        #expect(store.snapshot.tasks.count == 1, "An explicit add-to-board request must create a real task")
        #expect(store.projectTasks.first?.title == "Issue 418 regression")
        #expect(store.snapshot.importBatches.count == 1)
        #expect(await executor.requests.isEmpty, "Import must use the host transaction, not an unconnected model reply")
    }
    @Test func missingSourceContinuesOnAttachmentWithoutEmptyBatch() async throws {
        let (directory, store, executor) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("tasks.csv")
        try "title,id\nFollowup source,418".write(to: file, atomically: true, encoding: .utf8)
        let repository = try #require(store.repository)
        let project = try await repository.importProject(path: directory.appendingPathComponent("repo").path)
        let conversation = try await repository.createConversation(projectID: project.id)
        try await store.reload(); store.selectConversation(conversation.id)
        store.sendMessage("把这些任务导入看板", attachments: [])
        try await eventually { store.snapshot.messages.contains { $0.id.hasPrefix("import-source-") } }
        let requestID = try #require(store.snapshot.messages.first { $0.role == .user }?.id)
        #expect(store.snapshot.importBatches.isEmpty)
        store.sendMessage("文件在这里", attachments: [file])
        try await eventually { store.snapshot.importBatches.count == 1 }
        #expect(store.projectTasks.first?.title == "Followup source")
        #expect(store.snapshot.importBatches.first?.requestMessageID == requestID)
        #expect(await executor.requests.isEmpty)
    }
    @Test func earlierAttachmentIsImportedByLaterInstruction() async throws {
        let (directory, store, executor) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("tasks.csv")
        try "title,id\nEarlier source,418".write(to: file, atomically: true, encoding: .utf8)
        let repository = try #require(store.repository)
        let project = try await repository.importProject(path: directory.appendingPathComponent("repo").path)
        let conversation = try await repository.createConversation(projectID: project.id)
        // Source storage is separate from authorization; no need to invoke a model for this fixture.
        try await repository.appendMessage(conversationID: conversation.id, role: .user, content: "这里是任务清单", attachments: [.init(name: file.lastPathComponent, path: file.path, sourceIdentity: file.path)])
        try await store.reload(); store.selectConversation(conversation.id)
        store.sendMessage("把刚才的任务添加到看板", attachments: [])
        try await eventually { store.snapshot.importBatches.count == 1 }
        #expect(store.projectTasks.first?.title == "Earlier source")
        #expect(await executor.requests.isEmpty)
    }
    @Test func loginRetryCommitsOriginalScopedRequestOnce() async throws {
        let (directory, initial, executor) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = RetryImportReader()
        let store = AppStore(dataDirectory: initial.dataDirectory, executors: executor, reader: reader)
        let repository = try #require(store.repository)
        let project = try await repository.importProject(path: directory.appendingPathComponent("repo").path, defaultExecutor: .claude)
        let conversation = try await repository.createConversation(projectID: project.id)
        try await store.reload(); store.selectConversation(conversation.id)
        store.sendMessage("帮我将 https://github.com/SuperIM/bug-tracker 指派给我的Issue 添加到任务看板中。我是 zfsherman", attachments: [])
        try await eventually { store.snapshot.messages.contains { $0.id.hasPrefix("import-error-") } }
        let requestID = try #require(store.snapshot.messages.first { $0.role == .user }?.id)
        #expect(store.snapshot.tasks.isEmpty)
        #expect(store.snapshot.importBatches.isEmpty)
        store.sendMessage("继续导入", attachments: [])
        try await eventually { store.snapshot.importBatches.count == 1 }
        #expect(store.snapshot.importBatches.first?.requestMessageID == requestID)
        #expect(store.projectTasks.count == 1)
        #expect(store.projectTasks.first?.phase == .backlog)
        #expect(store.projectTasks.first?.selection.executor == .claude)
        #expect(await reader.messages.count == 2)
        #expect(await reader.messages.last?.contains("zfsherman") == true)
        #expect(store.snapshot.messages.contains { $0.id.hasPrefix("import-result-") && $0.content.contains("assignee=zfsherman") && $0.content.contains("AK-") })
        try await store.resumeTaskImport(requestMessageID: requestID)
        #expect(store.projectTasks.count == 1)
        #expect(store.snapshot.importBatches.count == 1)
        #expect(store.snapshot.messages.filter { $0.id.hasPrefix("import-result-") }.count == 1)
        #expect(await reader.messages.count == 2)
        #expect(await executor.requests.isEmpty)
    }
    @Test func savedImportCannotBypassLaterCancellation() async throws {
        let (directory, store, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try #require(store.repository)
        let project = try await repository.importProject(path: directory.appendingPathComponent("repo").path)
        let conversation = try await repository.createConversation(projectID: project.id)
        let request = try await repository.appendMessage(conversationID: conversation.id, role: .user, content: "导入Issue https://github.com/a/b/issues")
        try await repository.appendMessage(conversationID: conversation.id, role: .user, content: "取消")
        await #expect(throws: (any Error).self) { try await store.resumeTaskImport(requestMessageID: request.id) }
        #expect(store.snapshot.tasks.isEmpty)
        #expect(store.snapshot.importBatches.isEmpty)
    }
    @Test func selectionChangedDuringProbeDoesNotChangeFrozenRun() async throws {
        let (directory, store, executor) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try #require(store.repository)
        let project = try await repository.importProject(path: directory.appendingPathComponent("repo").path)
        let conversation = try await repository.createConversation(projectID: project.id)
        try await repository.updateSelection(conversationID: conversation.id, selection: .init(executor: .codex, modelID: "gpt-6.1-sol", effort: "low"))
        try await store.reload(); store.selectConversation(conversation.id)
        store.sendMessage("检查代码", attachments: [])
        try await eventually { try await !repository.snapshot().runs.isEmpty }
        store.updateSelection(.init(executor: .codex, modelID: "gpt-6-astra", effort: "high"))
        try await eventually { store.snapshot.runs.first?.status.isTerminal == true && store.currentSelection.modelID == "gpt-6-astra" }
        #expect(await executor.requests.first?.selection.modelID == "gpt-6.1-sol")
        #expect(store.snapshot.runs.first?.selection.effort == "low")
        #expect(store.snapshot.messages.filter { $0.role == .assistant }.count == 1)
    }
    @Test func chatImportUsesProjectDefaultAndDeduplicates() async throws {
        let (directory, store, executor) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("release.csv")
        try "标题,说明,id\n修复粘贴,\"第一行\n第二行\",a1".write(to: file, atomically: true, encoding: .utf8)
        let repository = try #require(store.repository)
        let project = try await repository.importProject(path: directory.appendingPathComponent("repo").path, defaultExecutor: .claude)
        let conversation = try await repository.createConversation(projectID: project.id)
        try await repository.updateSelection(conversationID: conversation.id, selection: .init(executor: .codex, modelID: "gpt-6-astra", effort: "high", permission: .fullAccess))
        try await store.reload(); store.selectConversation(conversation.id)
        store.sendMessage("把表格任务导入看板", attachments: [file])
        try await eventually { store.snapshot.importBatches.count == 1 }
        #expect(store.snapshot.tasks.count == 1)
        #expect(store.snapshot.tasks[0].selection == ExecutionSelection(executor: .claude))
        #expect(store.snapshot.tasks[0].description == "第一行\n第二行")
        store.sendMessage("再把表格任务导入看板", attachments: [file])
        try await eventually { store.snapshot.importBatches.count == 2 }
        #expect(store.snapshot.tasks.count == 1)
        #expect(store.snapshot.importBatches.last?.duplicateCount == 1)
        #expect(await executor.requests.isEmpty)
        #expect(store.snapshot.messages.filter { $0.id.hasPrefix("import-result-") }.count == 2)
    }
    @Test func phaseChangeStopsBeforeCommit() async throws {
        let (directory, store, executor) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await executor.setHold()
        let repository = try #require(store.repository)
        let project = try await repository.importProject(path: directory.appendingPathComponent("repo").path)
        let task = try await repository.createTask(projectID: project.id, title: "阶段屏障")
        try await repository.transitionTask(id: task.id, to: .discussion)
        try await store.reload(); store.selectTask(task.id)
        store.sendMessage("开始分析", attachments: [])
        try await eventually { await executor.requests.count == 1 }
        store.transitionTask(task.id, to: .backlog)
        try await eventually { store.snapshot.tasks.first?.phase == .backlog }
        #expect(store.snapshot.runs.first?.status == .cancelled)
        #expect(store.snapshot.tasks.first?.phaseVersion == 2)
    }
    @Test func incompleteSourceDoesNotPartiallyImport() async throws {
        let (directory, store, executor) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = directory.appendingPathComponent("good.csv"), bad = directory.appendingPathComponent("broken.csv")
        try "title\n有效任务".write(to: good, atomically: true, encoding: .utf8)
        try "title\n\"未闭合".write(to: bad, atomically: true, encoding: .utf8)
        let repository = try #require(store.repository)
        let project = try await repository.importProject(path: directory.appendingPathComponent("repo").path)
        let conversation = try await repository.createConversation(projectID: project.id)
        try await store.reload(); store.selectConversation(conversation.id)
        store.sendMessage("将这两份表格任务导入看板", attachments: [good, bad])
        try await eventually { store.snapshot.messages.contains { $0.id.hasPrefix("import-error-") } }
        #expect(store.snapshot.tasks.isEmpty)
        #expect(store.snapshot.importBatches.isEmpty)
        #expect(await executor.requests.isEmpty)
        try await repository.removeProject(id: project.id)
    }
    @Test func restartDeliversCommittedImportResultOnce() async throws {
        let (directory, store, executor) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try #require(store.repository)
        let project = try await repository.importProject(path: directory.appendingPathComponent("repo").path)
        let conversation = try await repository.createConversation(projectID: project.id)
        let message = try await repository.appendMessage(conversationID: conversation.id, role: .user, content: "导入任务")
        try await repository.beginImport(conversationID: conversation.id, operationKey: "restart-fixture")
        let batch = try await repository.commitImportBatch(conversationID: conversation.id, requestMessageID: message.id, operationKey: "restart-fixture", candidates: [ImportCandidate(sourceKey: "stable:42", sourceDescription: "fixture", title: "提交后尚未发送结果")])
        await store.boot()
        #expect(store.snapshot.messages.filter { $0.id == "import-result-\(batch.id)" }.count == 1)
        let reopened = AppStore(dataDirectory: directory.appendingPathComponent("data"), executors: executor)
        await reopened.boot()
        #expect(reopened.snapshot.messages.filter { $0.id == "import-result-\(batch.id)" }.count == 1)
        #expect(reopened.snapshot.tasks.count == 1)
        #expect(reopened.snapshot.runs.isEmpty)
    }

    @Test func taskAttachmentsAreCopiedDurablyAndReopenWithoutStartingExecution() async throws {
        let (directory, store, executor) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try #require(store.repository)
        let project = try await repository.importProject(path: directory.appendingPathComponent("repo").path)
        let source = directory.appendingPathComponent("spec.txt")
        try Data("attachment contents".utf8).write(to: source)
        try await store.reload(); store.selectProject(project.id)
        store.createTask(title: "带附件任务", description: "第一行\n第二行", type: .feature, priority: .normal, attachments: [source, source])
        try await eventually { store.snapshot.tasks.count == 1 }
        let task = try #require(store.selectedTask)
        let attachments = try #require(task.attachments)
        #expect(attachments.count == 1)
        let saved = try #require(attachments.first)
        #expect(saved.path != source.path)
        #expect(saved.sourceIdentity == source.resolvingSymlinksInPath().path)
        try FileManager.default.removeItem(at: source)
        #expect(try String(contentsOfFile: saved.path, encoding: .utf8) == "attachment contents")
        let reopened = AppStore(dataDirectory: store.dataDirectory, executors: executor)
        try await reopened.reload()
        #expect(reopened.snapshot.tasks.first?.attachments == attachments)
        #expect(reopened.snapshot.messages.isEmpty)
        #expect(reopened.snapshot.runs.isEmpty)
        #expect(await executor.requests.isEmpty)
    }

    @Test func taskAttachmentEditPreservesIdentityAndSupportsRemovingAll() async throws {
        let (directory, store, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try #require(store.repository)
        let project = try await repository.importProject(path: directory.appendingPathComponent("repo").path)
        let source = directory.appendingPathComponent("spec.txt")
        try Data("spec".utf8).write(to: source)
        try await store.reload(); store.selectProject(project.id)
        store.createTask(title: "编辑附件", description: "v1", type: .feature, priority: .normal, attachments: [source])
        try await eventually { store.snapshot.tasks.count == 1 }
        let task = try #require(store.selectedTask), attachments = try #require(task.attachments)
        store.updateTask(task.id, title: task.title, description: "v2", type: task.type, priority: task.priority, attachments: attachments.map { URL(fileURLWithPath: $0.path) })
        try await eventually { store.selectedTask?.description == "v2" }
        #expect(store.selectedTask?.attachments == attachments)
        store.updateTask(task.id, title: task.title, description: "v3", type: task.type, priority: task.priority)
        try await eventually { store.selectedTask?.description == "v3" }
        #expect(store.selectedTask?.attachments == attachments)
        store.updateTask(task.id, title: task.title, description: "v4", type: task.type, priority: task.priority, attachments: [])
        try await eventually { store.selectedTask?.description == "v4" }
        #expect(store.selectedTask?.attachments?.isEmpty == true)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func firstDiscussionReceivesTaskAndSavedBacklogAttachments() async throws {
        let (directory, store, executor) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try #require(store.repository)
        let project = try await repository.importProject(path: directory.appendingPathComponent("repo").path)
        let spec = directory.appendingPathComponent("spec.txt"), screenshot = directory.appendingPathComponent("screen.png")
        try Data("spec".utf8).write(to: spec)
        try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII=")).write(to: screenshot)
        try await store.reload(); store.selectProject(project.id)
        store.createTask(title: "截图需求", description: "参考附件", type: .feature, priority: .normal, attachments: [spec])
        try await eventually { store.snapshot.tasks.count == 1 }
        let task = try #require(store.selectedTask)
        store.sendMessage("", attachments: [screenshot])
        try await eventually { store.snapshot.messages.count == 1 }
        #expect(store.snapshot.runs.isEmpty)
        #expect(await executor.requests.isEmpty)
        try FileManager.default.removeItem(at: spec); try FileManager.default.removeItem(at: screenshot)
        try await repository.transitionTask(id: task.id, to: .discussion)
        try await store.reload()
        store.sendMessage("结合说明和截图分析", attachments: [])
        try await eventually { store.snapshot.runs.first?.status.isTerminal == true }
        let request = try #require(await executor.requests.first)
        #expect(Set(request.attachments.map(\.name)) == ["spec.txt", "screen.png"])
        #expect(request.attachments.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(request.phase == .discussion)
    }

    @Test func attachmentOnlyProjectMessageStartsWithSavedMediaInput() async throws {
        let (directory, store, executor) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try #require(store.repository)
        let project = try await repository.importProject(path: directory.appendingPathComponent("repo").path)
        let chat = try await repository.createConversation(projectID: project.id)
        let file = directory.appendingPathComponent("reference.txt")
        try Data("reference".utf8).write(to: file)
        try await store.reload(); store.selectConversation(chat.id)
        store.sendMessage("", attachments: [file])
        try await eventually { store.snapshot.runs.first?.status.isTerminal == true }
        let request = try #require(await executor.requests.first)
        #expect(request.prompt.contains("请查看我提供的附件"))
        #expect(request.attachments.count == 1)
        #expect(request.attachments.first == store.snapshot.messages.first?.attachments.first)
    }

    @Test func rejectedAttachmentCleansOnlyNewCopiesAndCreatesNoTask() async throws {
        let (directory, store, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try #require(store.repository)
        let project = try await repository.importProject(path: directory.appendingPathComponent("repo").path)
        let file = directory.appendingPathComponent("valid.txt")
        try Data("untouched".utf8).write(to: file)
        try await store.reload(); store.selectProject(project.id)
        store.createTask(title: "拒绝目录", description: "", type: .feature, priority: .normal, attachments: [file, directory])
        try await eventually { store.error != nil }
        #expect(store.snapshot.tasks.isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "untouched")
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.dataDirectory.appendingPathComponent("Attachments").path).isEmpty)
    }

    @Test func deletingSelectedConversationReturnsToBoardAndKeepsOtherConversation() async throws {
        let (directory, store, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try #require(store.repository)
        let project = try await repository.importProject(path: directory.appendingPathComponent("repo").path)
        let first = try await repository.createConversation(projectID: project.id, title: "删除当前"), second = try await repository.createConversation(projectID: project.id, title: "保留另一段")
        try await store.reload(); store.selectConversation(first.id)
        store.deleteConversation(first.id)
        try await eventually { !store.snapshot.conversations.contains { $0.id == first.id } }
        #expect(store.route == .board)
        #expect(store.selectedConversationID == nil)
        #expect(store.selectedProjectID == project.id)
        #expect(store.snapshot.conversations.map(\.id) == [second.id])
    }

    @Test func secondSendDuringLaunchIsRejectedBeforeSavingItsAttachments() async throws {
        let (directory, store, executor) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try #require(store.repository)
        let project = try await repository.importProject(path: directory.appendingPathComponent("repo").path)
        let chat = try await repository.createConversation(projectID: project.id)
        let file = directory.appendingPathComponent("not-sent.txt")
        try Data("keep in composer".utf8).write(to: file)
        try await store.reload(); store.selectConversation(chat.id)
        #expect(store.sendMessage("first", attachments: []))
        #expect(store.sendingConversations.contains(chat.id))
        #expect(!store.sendMessage("second", attachments: [file]))
        try await eventually { store.snapshot.runs.first?.status.isTerminal == true && store.sendingConversations.isEmpty }
        #expect(await executor.requests.count == 1)
        #expect(store.snapshot.messages.filter { $0.role == .user }.map(\.content) == ["first"])
        #expect(!FileManager.default.fileExists(atPath: store.dataDirectory.appendingPathComponent("Attachments").path))
    }

    @Test func deletingBusyConversationKeepsCurrentViewUntilStopped() async throws {
        let (directory, store, executor) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await executor.setHold()
        let repository = try #require(store.repository)
        let project = try await repository.importProject(path: directory.appendingPathComponent("repo").path)
        let chat = try await repository.createConversation(projectID: project.id)
        try await store.reload(); store.selectConversation(chat.id)
        store.sendMessage("运行中", attachments: [])
        try await eventually { await executor.requests.count == 1 }
        store.deleteConversation(chat.id)
        try await eventually { store.error != nil }
        #expect(store.route == .chat)
        #expect(store.selectedConversationID == chat.id)
        let run = try #require(store.activeRun)
        store.stopRun(run.id)
        try await eventually { store.activeRun == nil }
        store.error = nil; store.deleteConversation(chat.id)
        try await eventually { store.snapshot.conversations.isEmpty }
        #expect(store.route == .board)
    }
}
