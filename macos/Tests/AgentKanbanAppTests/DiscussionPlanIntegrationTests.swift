import Foundation
import Testing
import AgentKanbanCore
@testable import AgentKanban

@Suite("Discussion replies become editable plan drafts") @MainActor struct DiscussionPlanIntegrationTests {
    private func fixture() async throws -> (URL, AppStore, TaskItem) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kanban-discussion-plan-\(UUID().uuidString)")
        let working = directory.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["init", "-q", working.path]
        try git.run(); git.waitUntilExit()
        try #require(git.terminationStatus == 0)
        let store = AppStore(dataDirectory: directory.appendingPathComponent("data"))
        let repository = try #require(store.repository)
        let project = try await repository.importProject(path: working.path)
        let task = try await repository.createTask(projectID: project.id, title: "输入框对齐", description: "保留任务说明")
        try await repository.transitionTask(id: task.id, to: .discussion)
        return (directory, store, try await repository.task(id: task.id))
    }

    @Test func historicalReplyIsReadOnlyUntilSavedAndRequiresHumanConfirmation() async throws {
        let (directory, store, task) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try #require(store.repository)
        let run = try await repository.prepareRun(conversationID: task.mainConversationID, prompt: "讨论输入框修复方案")
        let reply = "## 推荐方案\n局部统一 `textContainerInset`，保留会话默认边距。\n\n建议补充这些验收条件：\n\n- 空输入与多行输入基线一致。\n- 图片粘贴正常。\n\n尚未完成原生运行时验证。"
        try await repository.finishRun(id: run.id, status: .succeeded, output: reply, stopConfirmed: true)
        try await repository.appendMessage(conversationID: task.mainConversationID, role: .assistant, content: reply, runID: run.id, id: "reply-\(run.id)")
        try await store.reload()

        let draft = try #require(DiscussionPlanDraft.pending(task: task, snapshot: store.snapshot))
        #expect(draft.content == reply)
        #expect(store.snapshot.revisions.isEmpty)
        try await store.reload()
        #expect(store.snapshot.revisions.isEmpty, "Reading a draft must not create a revision or invalidate reports")

        try await store.saveRevision(taskID: task.id, content: draft.content, sourceMessageID: draft.sourceMessageID, sourceRunID: draft.sourceRunID)
        let revision = try #require(store.snapshot.revisions.first)
        #expect(revision.plan.contains("## 推荐方案"))
        #expect(revision.plan.contains("尚未完成原生运行时验证。"))
        #expect(revision.acceptanceCriteria == ["空输入与多行输入基线一致。", "图片粘贴正常。"])
        #expect(revision.requirement == task.description)
        #expect(revision.sourceMessageID == draft.sourceMessageID)
        #expect(revision.sourceRunID == run.id)
        #expect(revision.confirmedAt == nil)
        #expect(store.snapshot.tasks.first?.phase == .discussion)
        #expect(store.snapshot.runs.count == 1, "Saving a discussion draft must not start a model request")
        let updated = try #require(store.snapshot.tasks.first)
        #expect(DiscussionPlanDraft.pending(task: updated, snapshot: store.snapshot) == nil)
        await #expect(throws: KanbanError.self) { try await repository.transitionTask(id: task.id, to: .development) }
        try await repository.confirmRevision(id: revision.id)
        try await repository.transitionTask(id: task.id, to: .development)

        let reopened = try Repository(databaseURL: directory.appendingPathComponent("data/workspace.sqlite"))
        let persisted = try await reopened.snapshot()
        #expect(persisted.revisions.first?.sourceMessageID == draft.sourceMessageID)
        #expect(persisted.tasks.first?.phase == .development)
    }

    @Test func proseMentionOfAcceptanceDoesNotTruncatePlanOrInventCriteria() async throws {
        let (directory, store, task) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let content = "当前方案还需要讨论验收条件，不能据此丢失后面的内容。\n\n保留风险、范围与代码引用。"
        try await store.saveRevision(taskID: task.id, content: content)
        let revision = try #require(store.snapshot.revisions.first)
        #expect(revision.plan == content)
        #expect(revision.acceptanceCriteria.isEmpty)
        #expect(revision.sourceMessageID == nil)
        let repository = try #require(store.repository)
        await #expect(throws: KanbanError.self) { try await repository.confirmRevision(id: revision.id) }
    }
}
