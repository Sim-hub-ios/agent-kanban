import Foundation
import Testing
@testable import AgentKanbanCore

@Suite("Discussion plan draft source and document boundaries") struct DiscussionPlanDraftTests {
    @Test func editingSavedMultilineCriteriaPreservesItemBoundaries() {
        let original = DiscussionPlanDocument.parse(content: "## 方案\n局部修复。\n\n## 验收条件\n- 首行对齐\n  分别检查中文和英文\n  - 深色模式\n- 图片可粘贴")
        let edited = DiscussionPlanDocument.editingContent(plan: original.plan, acceptanceCriteria: original.acceptanceCriteria)
        #expect(DiscussionPlanDocument.parse(content: edited) == original)
    }
    private let task = TaskItem(id: "task", projectID: "project", number: 1, title: "Test", phase: .discussion, phaseVersion: 3, mainConversationID: "main")

    private func run(_ id: String, status: RunStatus = .succeeded, phase: TaskPhase = .discussion, version: Int = 3, project: String = "project", task: String = "task", conversation: String = "main", parent: String? = nil) -> RunRecord {
        RunRecord(id: id, projectID: project, conversationID: conversation, taskID: task, parentRunID: parent, selection: .init(), cwd: "/fixture", phase: phase, phaseVersion: version, prompt: "fixture", writing: false, status: status)
    }

    private func message(_ runID: String?, time: Double, content: String = "完整方案", project: String = "project", conversation: String = "main", role: MessageRole = .assistant, id: String? = nil) -> Message {
        Message(id: id ?? "reply-\(runID ?? "none")", projectID: project, conversationID: conversation, role: role, content: content, runID: runID, createdAt: Date(timeIntervalSince1970: time))
    }

    private func snapshot(runs: [RunRecord], messages: [Message]) -> WorkspaceSnapshot {
        WorkspaceSnapshot(conversations: [Conversation(id: "main", projectID: "project", kind: .taskMain, taskID: "task", title: "Main")], messages: messages, runs: runs)
    }

    @Test func latestSuccessfulMainReplyPreservesCompleteMarkdown() throws {
        let markdown = "  ## 方案\n\n1. 修改输入框\n\n```swift\nlet inset = 0\n```\n\n**注意事项**\n保留已有会话行为。\n"
        let snapshot = snapshot(runs: [run("older"), run("newer")], messages: [message("newer", time: 20, content: markdown), message("older", time: 10)])
        let draft = try #require(DiscussionPlanDraft.latest(task: task, snapshot: snapshot))
        #expect(draft.content == markdown)
        #expect(draft.sourceMessageID == "reply-newer")
        #expect(draft.sourceRunID == "newer")
        #expect(draft.createdAt == Date(timeIntervalSince1970: 20))
    }

    @Test func failedCancelledActiveOldPhaseAndChildRepliesNeverBecomeDrafts() throws {
        let excludedRuns = [
            run("failed", status: .failed), run("cancelled", status: .cancelled), run("running", status: .running),
            run("approval", status: .waitingApproval), run("old", version: 2), run("future", version: 4),
            run("development", phase: .development), run("child", parent: "valid"),
            run("other-task", task: "other"), run("other-conversation", conversation: "child"), run("other-project", project: "other")
        ]
        let messages = [message("valid", time: 1)] + excludedRuns.enumerated().map { message($0.element.id, time: Double($0.offset + 10)) }
        let result = try #require(DiscussionPlanDraft.latest(task: task, snapshot: snapshot(runs: [run("valid")] + excludedRuns, messages: messages)))
        #expect(result.sourceRunID == "valid")
        #expect(DiscussionPlanDraft.latest(task: task, snapshot: snapshot(runs: excludedRuns, messages: messages)) == nil)
    }

    @Test func unboundProgressToolBlankAndWrongConversationMessagesAreExcluded() throws {
        let messages = [
            message("valid", time: 1), message(nil, time: 20), message("valid", time: 21, role: .tool),
            message("valid", time: 22, role: .user), message("valid", time: 23, id: "progress-valid"),
            message("valid", time: 24, project: "other"), message("valid", time: 25, conversation: "child"),
            message("empty", time: 30, content: " \n\t")
        ]
        let result = try #require(DiscussionPlanDraft.latest(task: task, snapshot: snapshot(runs: [run("valid"), run("empty")], messages: messages)))
        #expect(result.createdAt == Date(timeIntervalSince1970: 1))
    }

    @Test func onlyCurrentDiscussionAndOwnedMainConversationAreEligible() {
        var changed = task
        changed.phase = .development
        var snapshot = snapshot(runs: [run("valid")], messages: [message("valid", time: 1)])
        #expect(DiscussionPlanDraft.latest(task: changed, snapshot: snapshot) == nil)
        snapshot.conversations = [Conversation(id: "main", projectID: "project", kind: .projectChat, title: "Unowned")]
        #expect(DiscussionPlanDraft.latest(task: task, snapshot: snapshot) == nil)
        snapshot.conversations = [Conversation(id: "main", projectID: "project", kind: .taskMain, taskID: "other", title: "Wrong owner")]
        #expect(DiscussionPlanDraft.latest(task: task, snapshot: snapshot) == nil)
    }

    @Test func pendingDraftDoesNotReplaceNewerManualRevision() {
        var savedTask = task
        savedTask.currentRevisionID = "manual"
        var workspace = snapshot(runs: [run("discussion")], messages: [message("discussion", time: 10)])
        workspace.revisions = [RequirementRevision(id: "manual", projectID: "project", taskID: "task", version: 1, requirement: "Requirement", plan: "人工保存的方案", acceptanceCriteria: [], createdAt: Date(timeIntervalSince1970: 20))]
        #expect(DiscussionPlanDraft.pending(task: savedTask, snapshot: workspace) == nil)
        workspace.messages = [message("discussion", time: 20)]
        #expect(DiscussionPlanDraft.pending(task: savedTask, snapshot: workspace) == nil)
    }

    @Test func alreadySavedSourceDoesNotOfferTheSameDraftAgain() {
        var savedTask = task
        savedTask.currentRevisionID = "saved"
        var workspace = snapshot(runs: [run("discussion")], messages: [message("discussion", time: 30)])
        workspace.revisions = [RequirementRevision(id: "saved", projectID: "project", taskID: "task", version: 1, requirement: "Requirement", plan: "已采用讨论", acceptanceCriteria: [], createdAt: Date(timeIntervalSince1970: 20), sourceMessageID: "reply-discussion", sourceRunID: "discussion")]
        #expect(DiscussionPlanDraft.pending(task: savedTask, snapshot: workspace) == nil)
    }

    @Test func laterDiscussionOffersNewDraftAndMissingRevisionAllowsInitialDraft() throws {
        var savedTask = task
        savedTask.currentRevisionID = "saved"
        var workspace = snapshot(runs: [run("old"), run("new")], messages: [message("old", time: 10), message("new", time: 30)])
        workspace.revisions = [RequirementRevision(id: "saved", projectID: "project", taskID: "task", version: 1, requirement: "Requirement", plan: "已保存", acceptanceCriteria: [], createdAt: Date(timeIntervalSince1970: 20), sourceMessageID: "reply-old", sourceRunID: "old")]
        #expect(try #require(DiscussionPlanDraft.pending(task: savedTask, snapshot: workspace)).sourceRunID == "new")
        #expect(try #require(DiscussionPlanDraft.pending(task: task, snapshot: workspace)).sourceRunID == "new")
        savedTask.currentRevisionID = "missing"
        #expect(try #require(DiscussionPlanDraft.pending(task: savedTask, snapshot: workspace)).sourceRunID == "new")
    }

    @Test func acceptanceListStopsAtNextHeadingAndPreservesCaveats() {
        let content = "## 实施方案\n保留 **Markdown** 和 `代码`。\n\n## 建议验收条件\n- 光标与占位提示对齐\n  空输入和多行输入分别检查\n- [ ] 粘贴图片后可创建任务\n\n## 注意事项\n仅修改任务表单，不影响会话编辑器。"
        let parsed = DiscussionPlanDocument.parse(content: content)
        #expect(parsed.acceptanceCriteria == ["光标与占位提示对齐\n空输入和多行输入分别检查", "粘贴图片后可创建任务"])
        #expect(parsed.plan.contains("保留 **Markdown** 和 `代码`。"))
        #expect(parsed.plan.contains("## 注意事项\n仅修改任务表单，不影响会话编辑器。"))
        #expect(!parsed.plan.contains("## 建议验收条件"))
    }

    @Test func boldHeadingNumberedItemsAndOrdinaryClosingParagraph() {
        let content = "先修改内部边距。\n\n**建议补充这些验收条件：**\n1. 空输入框首行对齐。\n2) 多行编辑与附件粘贴正常。\n\n实际基线应通过原生界面核对，尚未完成视觉验收。\n- 下一步再验证其他页面。"
        let parsed = DiscussionPlanDocument.parse(content: content)
        #expect(parsed.acceptanceCriteria == ["空输入框首行对齐。", "多行编辑与附件粘贴正常。"])
        #expect(parsed.plan.contains("实际基线应通过原生界面核对，尚未完成视觉验收。\n- 下一步再验证其他页面。"))
    }

    @Test func englishHeadingAndNestedItemsStayWithParentCriterion() {
        let content = "Plan\n\n### Acceptance Criteria: ###\n* Outer condition\n  - Nested condition\n  Continuation\n+ Second condition\n\n**Caveat**\nKeep this paragraph."
        let parsed = DiscussionPlanDocument.parse(content: content)
        #expect(parsed.acceptanceCriteria == ["Outer condition\n- Nested condition\nContinuation", "Second condition"])
        #expect(parsed.plan.contains("**Caveat**\nKeep this paragraph."))
    }

    @Test func exactStandalonePlainTitlesSupportExistingRepliesAndLegacyTemplates() {
        for title in ["建议补充这些验收条件：", "验收条件", "Acceptance criteria:"] {
            let content = "实施方案\n修改任务表单的内部边距。\n\n\(title)\n\n- 空输入首行对齐。\n- 多行编辑正常。\n- 附件粘贴正常。\n\n目前只完成分析，原生界面验收尚未执行。"
            let parsed = DiscussionPlanDocument.parse(content: content)
            #expect(parsed.acceptanceCriteria == ["空输入首行对齐。", "多行编辑正常。", "附件粘贴正常。"])
            #expect(parsed.plan.contains("实施方案\n修改任务表单的内部边距。"))
            #expect(parsed.plan.contains("目前只完成分析，原生界面验收尚未执行。"))
        }
    }

    @Test func plainKeywordsInlineReferencesFencedExamplesAndAmbiguousSectionsAreLossless() {
        let contents = [
            "方案中提到验收条件，但这不是分隔标题。\n- 保留本条。",
            "建议补充这些验收条件：\n先讨论这段话。\n- 不能越过普通段落识别列表。",
            "## 验收条件\n还需要讨论具体验收范围。\n- 不是已明确的条件。",
            "```markdown\n## 验收条件\n- 示例内容\n```\n\n最终结论全部保留。",
            "    ## 验收条件\n    - 代码示例\n",
            "## 验收条件与风险\n- 不能靠子字符串匹配截断。"
        ]
        for content in contents {
            let parsed = DiscussionPlanDocument.parse(content: content)
            #expect(parsed.plan == content)
            #expect(parsed.acceptanceCriteria.isEmpty)
        }
    }
}
