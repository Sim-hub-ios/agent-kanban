import Foundation

/// Native local-agent state only. Background level snapshots and foreground edge state
/// are deliberately separate: a background snapshot cannot retire a foreground agent.
struct ClaudeChildTracker: Sendable {
    private struct Child: Sendable {
        var runID: String?
        var status = "running"
        var background = false
        var terminal = false
        var summary = ""
        var hasFinalSummary = false
        var toolIDs: Set<String> = []
    }
    private struct Reference: Sendable, Equatable {
        let taskID: String
        let runID: String?
    }
    private var children: [String: Child] = [:]
    private var tools: [String: Reference] = [:]
    private var background: [String: Reference] = [:]
    private var forwardedText: [String: String] = [:]
    private static let maximumSummaryCharacters = 64 * 1_024

    var hasActiveChildren: Bool {
        // Background levels and terminal bookends have no ordering guarantee. An
        // empty level may arrive before the completed AgentOutput/notification, so
        // never let it discard an already observed child or its eventual summary.
        children.values.contains { !$0.terminal }
    }

    mutating func system(_ packet: JSONValue) -> [ExecutorEvent] {
        guard packet["type"].string == "system", let subtype = packet["subtype"].string else { return [] }
        if subtype == "background_tasks_changed" { return replaceBackground(packet["tasks"].array) }
        guard ["task_started", "task_progress", "task_notification", "task_updated"].contains(subtype),
              let taskID = packet["task_id"].string else { return [] }
        let toolID = packet["tool_use_id"].string
        // Progress/notification frames omit task_type, so only an established local
        // agent or a positively typed start can introduce this stable task identity.
        if subtype == "task_started", packet["task_type"].string != "local_agent" { return [] }
        guard children[taskID] != nil || subtype == "task_started" else { return [] }
        guard prepare(taskID: taskID, runID: packet["run_id"].string, toolID: toolID) else { return [] }
        guard var child = children[taskID] else { return [] }
        if subtype == "task_started" {
            guard !child.terminal else { return [] }
            child.background = packet["is_backgrounded"].bool ?? false
        } else if subtype == "task_updated", let backgrounded = packet["patch"]["is_backgrounded"].bool {
            child.background = backgrounded
            if !backgrounded { background.removeValue(forKey: taskID) }
        }
        let incoming = subtype == "task_updated" ? packet["patch"]["status"].string : packet["status"].string
        let status: String
        if let incoming { status = incoming == "killed" ? "stopped" : incoming }
        else if subtype == "task_notification" { return [] }
        else if subtype == "task_updated" { status = child.status }
        else { status = "running" }
        let terminal = Self.isTerminal(status)
        // A duplicate or late progress frame cannot resurrect the same agent run.
        guard !child.terminal || terminal else { return [] }
        if child.terminal, status != child.status { return [] }
        let provided = packet["summary"].string ?? (subtype == "task_updated" ? packet["patch"]["description"].string : packet["description"].string)
        let before = child
        child.status = status
        child.terminal = terminal
        if let provided, !provided.isEmpty, !child.hasFinalSummary {
            child.summary = Self.bounded(provided)
            if subtype == "task_notification", packet["summary"].string?.isEmpty == false { child.hasFinalSummary = true }
        }
        if terminal, !child.hasFinalSummary {
            let text = fallback(child)
            if !text.isEmpty { child.summary = text }
        }
        children[taskID] = child
        if terminal { background.removeValue(forKey: taskID) }
        if before.status == child.status, before.summary == child.summary, subtype != "task_started" { return [] }
        return [.agent(id: taskID, status: child.status, summary: child.summary)]
    }

    /// The caller passes the complete user envelope, including its AgentOutput twin.
    /// Native AgentOutput.agentId is a stable task_id, not its per-resume run_id.
    mutating func toolResult(_ packet: JSONValue) -> [ExecutorEvent] {
        guard packet["type"].string == "user" else { return [] }
        let result = packet["tool_use_result"]
        guard let taskID = result["agentId"].string,
              let status = result["status"].string,
              ["completed", "async_launched"].contains(status) else { return [] }
        let toolIDs = packet["message"]["content"].array.compactMap { block in
            block["type"].string == "tool_result" ? block["tool_use_id"].string : nil
        }
        guard let toolID = toolIDs.first(where: { tools[$0]?.taskID == taskID }) ?? toolIDs.first else { return [] }
        if let reference = tools[toolID] {
            guard reference.taskID == taskID, reference.runID == children[taskID]?.runID else { return [] }
        } else if let current = children[taskID], !current.toolIDs.isEmpty {
            // An uncorrelated old completion must not close a resumed run of this agent.
            return []
        }
        if children[taskID] == nil { children[taskID] = Child(runID: nil) }
        guard var child = children[taskID] else { return [] }
        let before = child
        child.toolIDs.insert(toolID)
        tools[toolID] = Reference(taskID: taskID, runID: child.runID)
        if status == "async_launched" {
            guard !child.terminal else { return [] }
            child.background = true
            child.status = "running"
            if child.summary.isEmpty { child.summary = Self.bounded(result["description"].string ?? "") }
            children[taskID] = child
            return [.agent(id: taskID, status: "running", summary: child.summary)]
        }
        guard !child.terminal || child.status == "completed" else { return [] }
        let summary = result["content"].array.compactMap { block in
            block["type"].string == "text" ? block["text"].string : nil
        }.joined(separator: "\n")
        // The completed tool's structured report wins over progress descriptions and
        // forwarded model prose, even if a terminal notification arrived first.
        child.status = "completed"; child.terminal = true
        if !summary.isEmpty { child.summary = Self.bounded(summary); child.hasFinalSummary = true }
        else if !child.hasFinalSummary {
            let text = fallback(child)
            if !text.isEmpty { child.summary = text }
        }
        children[taskID] = child
        background.removeValue(forKey: taskID)
        if before.status == child.status, before.summary == child.summary, before.hasFinalSummary == child.hasFinalSummary { return [] }
        return [.agent(id: taskID, status: "completed", summary: child.summary)]
    }

    /// Keep child text private until a terminal bookend needs a fallback summary.
    /// This method intentionally never emits a main textDelta or a per-token agent event.
    mutating func forwarded(_ packet: JSONValue) -> [ExecutorEvent] {
        guard let parent = packet["parent_tool_use_id"].string else { return [] }
        if let reference = tools[parent], children[reference.taskID]?.runID != reference.runID { return [] }
        switch packet["type"].string {
        case "assistant":
            let text = packet["message"]["content"].array.compactMap { block in
                block["type"].string == "text" ? block["text"].string : nil
            }.joined(separator: "\n")
            if !text.isEmpty { forwardedText[parent] = Self.bounded(text) }
        case "stream_event":
            let event = packet["event"]
            if event["type"].string == "message_start" { forwardedText[parent] = "" }
            if event["type"].string == "content_block_delta", let delta = event["delta"]["text"].string {
                forwardedText[parent] = Self.bounded((forwardedText[parent] ?? "") + delta)
            }
        default: break
        }
        return []
    }

    private mutating func replaceBackground(_ tasks: [JSONValue]) -> [ExecutorEvent] {
        var replacement: [String: Reference] = [:], events: [ExecutorEvent] = []
        for task in tasks where task["task_type"].string == "local_agent" {
            guard let taskID = task["task_id"].string else { continue }
            let incoming = task["run_id"].string
            guard prepare(taskID: taskID, runID: incoming, toolID: nil) else {
                // A late older-run entry cannot replace membership of a known newer run.
                if let existing = background[taskID] { replacement[taskID] = existing }
                continue
            }
            guard var child = children[taskID], !child.terminal else { continue }
            let wasBackground = child.background
            child.background = true
            if child.summary.isEmpty { child.summary = Self.bounded(task["description"].string ?? "") }
            children[taskID] = child
            replacement[taskID] = Reference(taskID: taskID, runID: child.runID)
            if !wasBackground { events.append(.agent(id: taskID, status: child.status, summary: child.summary)) }
        }
        background = replacement
        return events
    }

    /// Native run IDs are sortable strings. Missing IDs on old producers are supported,
    /// but must not retire a newer explicitly identified run without tool correlation.
    private mutating func prepare(taskID: String, runID: String?, toolID: String?) -> Bool {
        if var child = children[taskID] {
            if let current = child.runID {
                guard let runID else { return false }
                if runID < current { return false }
                if runID > current {
                    child = Child(runID: runID)
                }
            } else if let runID {
                // AgentOutput can precede its first task edge. Learning that run's
                // ID is enrichment, not evidence that a completed child restarted.
                child.runID = runID
                for id in child.toolIDs where tools[id]?.runID == nil {
                    tools[id] = Reference(taskID: taskID, runID: runID)
                }
            }
            if let toolID {
                child.toolIDs.insert(toolID)
                tools[toolID] = Reference(taskID: taskID, runID: child.runID)
            }
            children[taskID] = child
        } else {
            var child = Child(runID: runID)
            if let toolID { child.toolIDs.insert(toolID); tools[toolID] = Reference(taskID: taskID, runID: runID) }
            children[taskID] = child
        }
        return true
    }

    private func fallback(_ child: Child) -> String {
        child.toolIDs.sorted().compactMap { forwardedText[$0] }.last(where: { !$0.isEmpty }) ?? ""
    }
    private static func isTerminal(_ status: String) -> Bool { ["completed", "failed", "stopped"].contains(status) }
    private static func bounded(_ value: String) -> String { String(value.prefix(maximumSummaryCharacters)) }
}
