import Foundation
import Testing
@testable import AgentKanbanCore

@Suite("Conversational task import authorization") struct TaskImportRequestResolverTests {
    private func message(_ content: String, _ time: Double, project: String = "p", conversation: String = "c", role: MessageRole = .user, attachments: [AgentKanbanCore.Attachment] = []) -> Message {
        Message(id: "\(project)-\(conversation)-\(time)-\(role.rawValue)", projectID: project, conversationID: conversation, role: role, content: content, attachments: attachments, createdAt: Date(timeIntervalSince1970: time))
    }
    private func resolve(_ messages: [Message], batches: [ImportBatch] = []) -> ResolvedTaskImportRequest? {
        TaskImportRequestResolver.resolve(current: messages.last!, history: messages, batches: batches)
    }
    @Test func originalSentenceAndContextualConfirmationKeepHumanScope() throws {
        let request = message("帮我将 https://github.com/SuperIM/bug-tracker 指派给我的Issue 添加到任务看板中。我是 zfsherman", 1)
        let assistant = message("可以导入 https://github.com/unrelated/repo/issues", 2, role: .assistant)
        for text in ["好的", "继续导入", "已登录，继续"] {
            let resolved = try #require(resolve([request, assistant, message(text, 3)]))
            #expect(resolved.requestMessageID == request.id)
            #expect(resolved.message.contains("zfsherman"))
            #expect(!resolved.message.contains("unrelated"))
            #expect(resolved.hasSources)
        }
    }
    @Test func sourceAndInstructionMayBeSeparateInEitherOrder() throws {
        let file = AgentKanbanCore.Attachment(name: "tasks.csv", path: "/private/copy.csv", sourceIdentity: "/original/tasks.csv")
        let source = message("文件在这里", 1, attachments: [file])
        let command = message("把这些任务导入看板", 2)
        #expect(try #require(resolve([source, command])).attachments == [file])
        let initial = message("把这些任务导入看板", 1)
        #expect(try #require(resolve([initial])).hasSources == false)
        let followup = try #require(resolve([initial, message("文件在这里", 2, attachments: [file])]))
        #expect(followup.requestMessageID == initial.id)
        #expect(followup.attachments == [file])
    }
    @Test func replacementSourceDoesNotReReadBrokenSource() throws {
        let request = message("导入Issue到看板 https://github.com/a/old/issues?assignee=me", 1)
        let replacement = message("https://github.com/a/new/issues?assignee=me", 2)
        let result = try #require(resolve([request, replacement, message("继续导入", 3)]))
        #expect(result.message.contains("a/new"))
        #expect(!result.message.contains("a/old"))
        let adjacent = message("导入Issue https://github.com/a/old/issues指派给我，我是zfsherman", 1)
        let scoped = try #require(resolve([adjacent, replacement]))
        #expect(scoped.message.contains("指派给我"))
        #expect(scoped.message.contains("我是zfsherman"))
    }
    @Test func noAuthorizationFromLinksAssistantOrOtherConversation() {
        #expect(resolve([message("https://github.com/a/b/issues", 1)]) == nil)
        #expect(resolve([message("把这些Issue导入看板 https://github.com/a/b/issues", 1, role: .assistant), message("好的", 2)]) == nil)
        #expect(resolve([message("导入Issue https://github.com/a/b/issues", 1, conversation: "other"), message("好的", 2)]) == nil)
        #expect(resolve([message("导入Issue https://github.com/a/b/issues", 1, project: "other"), message("好的", 2)]) == nil)
    }
    @Test func cancellationUnrelatedRequestAndSuccessfulBatchEndContinuation() {
        let request = message("导入Issue到看板 https://github.com/a/b/issues", 1)
        for text in ["不要导入", "不导入这些Issue", "暂时不导入这个任务", "取消", "先别把这些任务添加到看板", "先分析一下这个项目", "我是说先分析这个Issue https://github.com/a/b/issues/419"] {
            #expect(resolve([request, message(text, 2), message("好的", 3)]) == nil)
            #expect(!TaskImportRequestResolver.hasExplicitImportIntent(text))
        }
        let batch = ImportBatch(projectID: "p", conversationID: "c", requestMessageID: request.id, operationKey: "key", sourceRange: "fixture", createdTaskIDs: [], duplicateCount: 0, errors: [])
        #expect(resolve([request, message("好的", 3)], batches: [batch]) == nil)
        #expect(resolve([request, message("继续导入", 3)], batches: [batch]) == nil)
    }
    @Test func repeatedContinuationKeepsOriginalOperationIdentity() throws {
        let request = message("把 https://github.com/a/b/issues 导入看板", 1)
        #expect(try #require(resolve([request, message("继续导入", 2), message("已登录", 3)])).requestMessageID == request.id)
        let short = message("导入", 1)
        #expect(try #require(resolve([short, message("https://github.com/a/b/issues/418", 2), message("继续导入", 3), message("继续导入", 4)])).requestMessageID == short.id)
    }
    @Test func splitSourcesAndRetriesNeverCrossCompletedRequest() throws {
        let request = message("导入任务", 1)
        let history = [request, message("https://github.com/a/b/issues/418", 2), message("继续导入", 3)]
        #expect(try #require(resolve(history + [message("继续导入", 4)])).requestMessageID == request.id)
        let batch = ImportBatch(projectID: "p", conversationID: "c", requestMessageID: request.id, operationKey: "key", sourceRange: "fixture", createdTaskIDs: [], duplicateCount: 0, errors: [])
        for text in ["好的", "继续导入"] { #expect(resolve(history + [message(text, 4)], batches: [batch]) == nil) }
    }
    @Test func legacyAttachmentDecodesWithoutIdentity() throws {
        let old = Data(#"{"id":"a","name":"tasks.csv","path":"/copy.csv","byteCount":2}"#.utf8)
        #expect(try JSONDecoder().decode(AgentKanbanCore.Attachment.self, from: old).sourceIdentity == nil)
    }
}
