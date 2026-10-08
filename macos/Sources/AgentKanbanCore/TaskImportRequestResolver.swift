import Foundation

public struct ResolvedTaskImportRequest: Sendable {
    public let requestMessageID: String
    public let message: String
    public let attachments: [Attachment]
    public var hasSources: Bool { !attachments.isEmpty || TaskImportRequestResolver.hasLink(message) }
}

/// Uses human authorization and sources from this conversation only. Assistant prose is never a board command.
public enum TaskImportRequestResolver {
    public static func hasExplicitImportIntent(_ text: String) -> Bool {
        guard !isCancellation(text) else { return false }
        let value = text.lowercased()
        let target = ["任务", "看板", "issue", "清单", "表格", "task", "board", "spreadsheet", "kanban"].contains { value.contains($0) }
        if target && (value.contains("导入") || value.range(of: #"\bimport\b"#, options: .regularExpression) != nil) { return true }
        if target && ["添加到", "加入", "加到", "放入", "放到", "转成", "转为"].contains(where: { value.contains($0) }) { return true }
        if target && value.range(of: #"\b(add|put)\b.+\b(to|into|on)\b"#, options: .regularExpression) != nil { return true }
        return value.range(of: #"^(请|帮我|现在|开始|继续|直接|再)?\s*导入(吧|一下|它们|这些)?[。！!\s]*$|^import (it|them)[.!\s]*$"#, options: .regularExpression) != nil
    }

    public static func resolve(current: Message, history: [Message], batches: [ImportBatch]) -> ResolvedTaskImportRequest? {
        guard current.role == .user, !isCancellation(current.content) else { return nil }
        let humans = history.filter {
            $0.role == .user && $0.projectID == current.projectID && $0.conversationID == current.conversationID && $0.createdAt <= current.createdAt && $0.id != current.id
        }.sorted { $0.createdAt < $1.createdAt }
        let completed = Set(batches.filter { $0.projectID == current.projectID && $0.conversationID == current.conversationID }.map(\.requestMessageID))
        var request = current
        var context: [Message] = []
        var contextualRequest: Message?
        let explicit = hasExplicitImportIntent(current.content)
        if !explicit || (isContextCommand(current.content) && !hasSource(current)) {
            guard explicit || isContinuation(current) else { return nil }
            for previous in humans.reversed() {
                if completed.contains(previous.id) || isCancellation(previous.content) { return nil }
                if hasExplicitImportIntent(previous.content) {
                    if !isContextCommand(previous.content) || hasSource(previous) { request = previous; break }
                    contextualRequest = previous
                    context.insert(previous, at: 0)
                    continue
                }
                guard isContinuation(previous) else { break }
                context.insert(previous, at: 0)
            }
            if request.id == current.id, let contextualRequest {
                request = contextualRequest
                context.removeAll { $0.createdAt <= contextualRequest.createdAt }
            }
            if request.id == current.id {
                guard explicit else { return nil }
                context = []
            } else { context.append(current) }
        }
        // A completed request must never be retried by a conversational acknowledgement.
        guard !completed.contains(request.id) else { return nil }
        var sources = [request] + context
        if !sources.contains(where: hasSource) {
            for previous in humans.reversed() where previous.createdAt < request.createdAt {
                if completed.contains(previous.id) || isCancellation(previous.content) || hasExplicitImportIntent(previous.content) { break }
                if hasSource(previous) { sources.insert(previous, at: 0); break }
                if !isContinuation(previous) { break }
            }
        }
        // A replacement source after a failed read supersedes the old source, keeping the human scope.
        let sourceMessage = sources.last(where: hasSource)
        var seen = Set<String>()
        let attachments = (sourceMessage?.attachments ?? []).filter { seen.insert($0.sourceIdentity ?? $0.path).inserted }
        let text = sources.map { message in
            message.id == sourceMessage?.id ? message.content : message.content.replacingOccurrences(of: #"https?://[^\s<>"'`，。；！？、（）【】「」『』\p{Han}]+"#, with: "", options: [.regularExpression, .caseInsensitive])
        }.joined(separator: "\n")
        return ResolvedTaskImportRequest(requestMessageID: request.id, message: text, attachments: attachments)
    }

    static func hasLink(_ text: String) -> Bool {
        text.range(of: #"https?://[^\s<>]+"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    private static func hasSource(_ message: Message) -> Bool { !message.attachments.isEmpty || hasLink(message.content) }
    private static func isContextCommand(_ text: String) -> Bool {
        text.range(of: #"^\s*(请|帮我|现在|开始|继续|直接|再)?\s*导入(吧|一下|它们|这些)?[。！!\s]*$|^import (it|them)[.!\s]*$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    private static func isCancellation(_ text: String) -> Bool {
        text.range(of: #"(不要|别|不用|不需要|暂不|先不|暂时不|取消).{0,40}(导入|添加|加入|加到|放入|放到|转成|转为)|不(导入|添加|加入|加到)|^\s*(取消|算了|先等等)[。！!\s]*$|\b(don't|do not|never|cancel)\b.{0,40}\b(import|add)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    private static func isContinuation(_ message: Message) -> Bool {
        let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard text.range(of: #"分析|解释|修复|开发|实现|删除|不要|\b(analy[sz]e|explain|fix|implement|delete|cancel)\b"#, options: .regularExpression) == nil else { return false }
        if text.range(of: #"^(好的?|可以|是的|确认|继续|开始吧|执行吧|已登录|已经登录|已授权|已经授权|重试|再试一次|ok|okay|yes|continue|retry)[，,。！!\s]*(继续|重试|导入|吧)?[。！!\s]*$"#, options: .regularExpression) != nil { return true }
        if text.range(of: #"^(我(是|的用户名是)|用户名[是：:]|指派给|分配给|assignee[:=])\s*[@a-z0-9][a-z0-9-]{0,39}[。.!\s]*$"#, options: .regularExpression) != nil { return true }
        guard hasSource(message) else { return false }
        return true
    }
}
