import Foundation

/// A completed discussion reply that can be copied into the task's editable plan.
public struct DiscussionPlanDraft: Equatable, Sendable {
    public let sourceMessageID: String
    public let sourceRunID: String
    public let createdAt: Date
    public let content: String

    /// Saved manual edits and an already adopted reply take precedence over older discussion.
    public static func pending(task: TaskItem, snapshot: WorkspaceSnapshot) -> DiscussionPlanDraft? {
        guard let draft = latest(task: task, snapshot: snapshot) else { return nil }
        guard let revision = snapshot.revisions.first(where: {
            $0.id == task.currentRevisionID && $0.projectID == task.projectID && $0.taskID == task.id
        }) else { return draft }
        guard draft.createdAt > revision.createdAt, draft.sourceMessageID != revision.sourceMessageID else { return nil }
        return draft
    }

    public static func latest(task: TaskItem, snapshot: WorkspaceSnapshot) -> DiscussionPlanDraft? {
        guard task.phase == .discussion,
              snapshot.conversations.contains(where: {
                  $0.id == task.mainConversationID && $0.projectID == task.projectID &&
                      $0.kind == .taskMain && $0.taskID == task.id
              }) else { return nil }

        let runs = snapshot.runs.filter {
            $0.projectID == task.projectID && $0.taskID == task.id &&
                $0.conversationID == task.mainConversationID && $0.parentRunID == nil &&
                $0.phase == .discussion && $0.phaseVersion == task.phaseVersion && $0.status == .succeeded
        }
        let runIDs = Set(runs.map(\.id))
        let message = snapshot.messages.filter {
            guard let runID = $0.runID else { return false }
            // Executor deltas and tool/child activity are not completed main replies. AppStore
            // persists the final successful reply with this stable ID, once per run.
            return $0.id == "reply-\(runID)" && runIDs.contains(runID) &&
                $0.projectID == task.projectID && $0.conversationID == task.mainConversationID &&
                $0.role == .assistant && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.max {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
        }
        guard let message, let runID = message.runID else { return nil }
        return DiscussionPlanDraft(sourceMessageID: message.id, sourceRunID: runID, createdAt: message.createdAt, content: message.content)
    }
}

/// Separates explicitly headed acceptance lists while preserving the rest of the reply.
public struct DiscussionPlanDocument: Equatable, Sendable {
    public let plan: String
    public let acceptanceCriteria: [String]

    public static func editingContent(plan: String, acceptanceCriteria: [String]) -> String {
        let list = acceptanceCriteria.map { "- " + $0.replacingOccurrences(of: "\n", with: "\n  ") }.joined(separator: "\n")
        return plan + "\n\n## 验收条件\n" + list
    }

    public static func parse(content: String) -> DiscussionPlanDocument {
        let lines = content.components(separatedBy: "\n")
        var fence: Character?
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if let marker = fenceMarker(line) {
                if fence == marker { fence = nil } else if fence == nil { fence = marker }
                index += 1
                continue
            }
            guard fence == nil, let title = headingTitle(line), isAcceptanceTitle(title) else {
                index += 1
                continue
            }

            if let section = acceptanceList(lines: lines, after: index) {
                var remaining = lines
                remaining.removeSubrange(index...section.lastLine)
                return DiscussionPlanDocument(
                    plan: remaining.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                    acceptanceCriteria: section.criteria
                )
            }
            index += 1
        }
        // An ambiguous heading or prose is not permission to discard or invent content.
        return DiscussionPlanDocument(plan: content, acceptanceCriteria: [])
    }

    private struct ListItem {
        let indentation: Int
        let content: String
    }

    private static func acceptanceList(lines: [String], after heading: Int) -> (criteria: [String], lastLine: Int)? {
        var criteria: [String] = []
        var indentation: Int?
        var lastLine = heading
        for index in (heading + 1)..<lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if headingTitle(line) != nil || fenceMarker(line) != nil { break }
            if let item = listItem(line) {
                if let indentation, item.indentation > indentation, !criteria.isEmpty {
                    criteria[criteria.count - 1] += "\n" + trimmed
                } else {
                    if let indentation, item.indentation < indentation { break }
                    indentation = item.indentation
                    criteria.append(item.content)
                }
                lastLine = index
                continue
            }
            let leading = line.prefix { $0 == " " || $0 == "\t" }.count
            if let indentation, leading > indentation, !criteria.isEmpty {
                criteria[criteria.count - 1] += "\n" + trimmed
                lastLine = index
                continue
            }
            // A normal paragraph ends the list. In particular, a closing caveat is not
            // another acceptance item and remains part of the plan.
            break
        }
        return criteria.isEmpty ? nil : (criteria, lastLine)
    }

    private static func listItem(_ line: String) -> ListItem? {
        guard let range = line.range(of: #"^[ \t]*(?:[-+*]|[0-9]+[.)])[ \t]+"#, options: .regularExpression) else { return nil }
        let indentation = line.prefix { $0 == " " || $0 == "\t" }.count
        let content = String(line[range.upperBound...])
            .replacingOccurrences(of: #"^\[[ xX]\][ \t]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }
        return ListItem(indentation: indentation, content: content)
    }

    private static func headingTitle(_ line: String) -> String? {
        guard line.prefix(while: { $0 == " " }).count <= 3, !line.hasPrefix("\t") else { return nil }
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: #"^#{1,6}[ \t]+"#, options: .regularExpression) {
            text = String(text[range.upperBound...])
                .replacingOccurrences(of: #"[ \t]+#+[ \t]*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return stripBold(stripColon(text))
        }
        text = stripColon(text)
        if (text.hasPrefix("**") && text.hasSuffix("**")) || (text.hasPrefix("__") && text.hasSuffix("__")) {
            return stripColon(String(text.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // Older hand-edited plans and executor replies use an exact standalone plain
        // title. The caller still requires an immediate list (apart from blank lines).
        if isAcceptanceTitle(text) { return text }
        return nil
    }

    private static func stripBold(_ text: String) -> String {
        if (text.hasPrefix("**") && text.hasSuffix("**")) || (text.hasPrefix("__") && text.hasSuffix("__")) {
            return stripColon(String(text.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return text
    }

    private static func stripColon(_ text: String) -> String {
        text.replacingOccurrences(of: #"[：:][ \t]*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isAcceptanceTitle(_ title: String) -> Bool {
        let normalized = title.lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return [
            "验收条件", "建议验收条件", "建议补充这些验收条件", "验收标准", "建议验收标准",
            "acceptance criteria", "suggested acceptance criteria", "recommended acceptance criteria"
        ].contains(normalized)
    }

    private static func fenceMarker(_ line: String) -> Character? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") { return "`" }
        if text.hasPrefix("~~~") { return "~" }
        return nil
    }
}
