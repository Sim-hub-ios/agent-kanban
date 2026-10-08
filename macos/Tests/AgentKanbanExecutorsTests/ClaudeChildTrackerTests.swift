import Testing
@testable import AgentKanbanExecutors

@Suite("Claude child lifecycle projection")
struct ClaudeChildTrackerTests {
    private struct ChildEvent: Equatable {
        let id: String
        let status: String
        let summary: String
    }

    private func childEvents(_ events: [ExecutorEvent]) -> [ChildEvent] {
        events.compactMap {
            if case .agent(let id, let status, let summary) = $0 { return ChildEvent(id: id, status: status, summary: summary) }
            return nil
        }
    }

    private func system(_ subtype: String, taskID: String = "child-1", runID: String = "run-002", extra: [String: JSONValue] = [:]) -> JSONValue {
        .object([
            "type": .string("system"), "subtype": .string(subtype),
            "task_id": .string(taskID), "run_id": .string(runID)
        ].merging(extra, uniquingKeysWith: { _, new in new }))
    }

    private func started(taskID: String = "child-1", runID: String = "run-002", toolUseID: String = "tool-agent-1") -> JSONValue {
        system("task_started", taskID: taskID, runID: runID, extra: [
            "task_type": .string("local_agent"), "tool_use_id": .string(toolUseID),
            "is_backgrounded": .bool(false),
            "description": .string("Read-only code analysis")
        ])
    }

    @Test func stableTaskIdentityRejectsOlderRunNotifications() {
        var tracker = ClaudeChildTracker()
        let first = childEvents(tracker.system(started()))
        let retry = childEvents(tracker.system(system("task_progress", runID: "run-010", extra: ["description": .string("new run")])))
        let stale = childEvents(tracker.system(system("task_notification", runID: "run-009", extra: ["status": .string("completed"), "summary": .string("old run result")])))
        #expect(first.contains { $0.id == "child-1" && $0.status == "running" })
        #expect(retry.allSatisfy { $0.id == "child-1" })
        #expect(stale.isEmpty)
        #expect(tracker.hasActiveChildren)
        let final = childEvents(tracker.system(system("task_notification", runID: "run-010", extra: ["status": .string("completed"), "summary": .string("current result")])))
        #expect(final.contains { $0.id == "child-1" && $0.status == "completed" && $0.summary.contains("current result") })
        #expect(!tracker.hasActiveChildren)
    }

    @Test func terminalRunIgnoresLateProgressFromSameRun() {
        var tracker = ClaudeChildTracker()
        _ = tracker.system(started())
        _ = tracker.system(system("task_notification", extra: ["status": .string("completed"), "summary": .string("finished")]))
        let late = childEvents(tracker.system(system("task_progress", extra: ["status": .string("running"), "description": .string("late output")])))
        #expect(late.isEmpty)
        #expect(!tracker.hasActiveChildren)
    }

    @Test func backgroundNotificationPreservesSummaryAndFailureState() {
        var tracker = ClaudeChildTracker()
        _ = tracker.system(started())
        let events = childEvents(tracker.system(system("task_notification", extra: ["status": .string("failed"), "summary": .string("README.md could not be read")])))
        #expect(events.contains { $0.id == "child-1" && $0.status == "failed" && $0.summary == "README.md could not be read" })
        #expect(!tracker.hasActiveChildren)
    }

    @Test func taskUpdatedCanTerminateAnActiveChild() {
        var tracker = ClaudeChildTracker()
        _ = tracker.system(started())
        let events = childEvents(tracker.system(system("task_updated", extra: ["patch": .object(["status": .string("completed")])])))
        #expect(events.contains { $0.id == "child-1" && $0.status == "completed" })
        #expect(!tracker.hasActiveChildren)
    }

    @Test func shellAndRemoteTaskStartsDoNotCreateLocalAgentChildren() {
        var tracker = ClaudeChildTracker()
        let shell = tracker.system(system("task_started", taskID: "shell", extra: ["task_type": .string("local_bash")]))
        let remote = tracker.system(system("task_started", taskID: "remote", extra: ["task_type": .string("remote_agent")]))
        #expect(childEvents(shell).isEmpty)
        #expect(childEvents(remote).isEmpty)
        #expect(!tracker.hasActiveChildren)
    }

    private func foregroundResult(agentID: String = "child-1", toolUseID: String = "tool-agent-1", summary: String = "Structured child summary") -> JSONValue {
        .object([
            "type": .string("user"),
            "message": .object(["content": .array([.object(["type": .string("tool_result"), "tool_use_id": .string(toolUseID)])])]),
            "tool_use_result": .object([
                "status": .string("completed"), "agentId": .string(agentID),
                "content": .array([.object(["type": .string("text"), "text": .string(summary)])])
            ])
        ])
    }

    @Test func foregroundAgentOutputSuppliesCompletionSummary() {
        var tracker = ClaudeChildTracker()
        _ = tracker.system(started())
        let events = childEvents(tracker.toolResult(foregroundResult()))
        #expect(events.contains { $0.id == "child-1" && $0.status == "completed" && $0.summary == "Structured child summary" })
        #expect(!tracker.hasActiveChildren)
    }

    @Test func firstLateRunIDEnrichesCompletedChildWithoutResurrectingIt() {
        var tracker = ClaudeChildTracker()
        _ = tracker.toolResult(foregroundResult())
        #expect(!tracker.hasActiveChildren)
        let progress = tracker.system(system("task_progress", extra: ["description": .string("late running description")]))
        #expect(progress.isEmpty)
        #expect(!tracker.hasActiveChildren)
        _ = tracker.system(.object(["type": .string("system"), "subtype": .string("background_tasks_changed"), "tasks": .array([.object(["task_id": .string("child-1"), "run_id": .string("run-002"), "task_type": .string("local_agent")])])]))
        #expect(!tracker.hasActiveChildren)
        #expect(tracker.toolResult(foregroundResult()).isEmpty)
        let resumed = tracker.system(started(runID: "run-003", toolUseID: "new-agent-tool"))
        #expect(!resumed.isEmpty && tracker.hasActiveChildren)
    }

    @Test func backgroundReplacementCannotClearForegroundChild() {
        var tracker = ClaudeChildTracker()
        _ = tracker.system(started())
        _ = tracker.system(.object([
            "type": .string("system"), "subtype": .string("background_tasks_changed"),
            "tasks": .array([.object([
                "task_id": .string("background-child"), "run_id": .string("run-001"),
                "task_type": .string("local_agent"), "description": .string("Background analysis")
            ])])
        ]))
        let replacement = childEvents(tracker.system(.object([
            "type": .string("system"), "subtype": .string("background_tasks_changed"), "tasks": .array([])
        ])))
        #expect(!replacement.contains { $0.id == "child-1" && ["completed", "failed", "cancelled", "stopped"].contains($0.status) })
        #expect(tracker.hasActiveChildren)
        _ = tracker.toolResult(foregroundResult())
        #expect(tracker.hasActiveChildren)
        _ = tracker.system(system("task_notification", taskID: "background-child", runID: "run-001", extra: [
            "status": .string("completed"), "summary": .string("Background analysis completed")
        ]))
        #expect(!tracker.hasActiveChildren)
    }

    @Test func emptyBackgroundLevelWaitsForExplicitNotification() {
        var tracker = ClaudeChildTracker()
        _ = tracker.system(.object([
            "type": .string("system"), "subtype": .string("background_tasks_changed"),
            "tasks": .array([.object([
                "task_id": .string("background-only"), "run_id": .string("run-001"),
                "task_type": .string("local_agent"), "description": .string("Background analysis")
            ])])
        ]))
        let level = childEvents(tracker.system(.object([
            "type": .string("system"), "subtype": .string("background_tasks_changed"), "tasks": .array([])
        ])))
        #expect(level.isEmpty)
        #expect(tracker.hasActiveChildren)
        let completed = childEvents(tracker.system(system("task_notification", taskID: "background-only", runID: "run-001", extra: [
            "status": .string("completed"), "summary": .string("Final background conclusion")
        ])))
        #expect(completed.contains { $0.id == "background-only" && $0.status == "completed" && $0.summary == "Final background conclusion" })
        #expect(!tracker.hasActiveChildren)
    }

    @Test func taskUpdatedMergesBackgroundFlagWithoutResettingStatusOrToolCorrelation() {
        var tracker = ClaudeChildTracker()
        _ = tracker.system(started())
        let paused = childEvents(tracker.system(system("task_updated", extra: ["patch": .object([
            "status": .string("paused"), "is_backgrounded": .bool(true)
        ])])))
        #expect(paused.contains { $0.id == "child-1" && $0.status == "paused" })
        let foregrounded = childEvents(tracker.system(system("task_updated", extra: ["patch": .object([
            "is_backgrounded": .bool(false)
        ])])))
        #expect(!foregrounded.contains { $0.status != "paused" })
        #expect(tracker.hasActiveChildren)
        let completed = childEvents(tracker.toolResult(foregroundResult(summary: "Resumed child conclusion")))
        #expect(completed.contains { $0.id == "child-1" && $0.status == "completed" && $0.summary == "Resumed child conclusion" })
        #expect(!tracker.hasActiveChildren)
    }

    @Test func forwardedChildTextNeverBecomesMainConversationTextAndStructuredSummaryWins() {
        var tracker = ClaudeChildTracker()
        _ = tracker.system(started())
        let forwarded = tracker.forwarded(.object([
            "type": .string("assistant"), "parent_tool_use_id": .string("tool-agent-1"),
            "message": .object(["content": .array([.object(["type": .string("text"), "text": .string("Forwarded fallback text")])])])
        ]))
        #expect(forwarded.isEmpty)
        #expect(!forwarded.contains { if case .textDelta = $0 { true } else { false } })
        let final = childEvents(tracker.toolResult(foregroundResult(summary: "Authoritative AgentOutput summary")))
        #expect(final.contains { $0.status == "completed" && $0.summary == "Authoritative AgentOutput summary" })
        #expect(!final.contains { $0.summary.contains("Forwarded fallback") })
    }

    @Test func emptyNotificationSummaryFallsBackToCachedForwardedText() {
        var tracker = ClaudeChildTracker()
        _ = tracker.system(started())
        let events = tracker.forwarded(.object([
            "type": .string("stream_event"), "parent_tool_use_id": .string("tool-agent-1"),
            "event": .object(["type": .string("content_block_delta"), "delta": .object(["type": .string("text_delta"), "text": .string("Cached final conclusion")])])
        ]))
        #expect(events.isEmpty)
        let final = childEvents(tracker.system(system("task_notification", extra: ["status": .string("completed"), "summary": .string("")])))
        #expect(final.contains { $0.id == "child-1" && $0.status == "completed" && $0.summary.contains("Cached final conclusion") })
        #expect(!tracker.hasActiveChildren)
    }

    @Test func staleForegroundToolResultCannotFinishNewerRunOfSameChild() {
        var tracker = ClaudeChildTracker()
        _ = tracker.system(started(runID: "run-002", toolUseID: "old-agent-tool"))
        _ = tracker.system(started(runID: "run-010", toolUseID: "new-agent-tool"))
        let stale = childEvents(tracker.toolResult(foregroundResult(toolUseID: "old-agent-tool", summary: "Old attempt")))
        #expect(stale.isEmpty)
        #expect(tracker.hasActiveChildren)
        let final = childEvents(tracker.toolResult(foregroundResult(toolUseID: "new-agent-tool", summary: "New attempt")))
        #expect(final.contains { $0.id == "child-1" && $0.status == "completed" && $0.summary == "New attempt" })
        #expect(!tracker.hasActiveChildren)
    }

    @Test func remoteLaunchDoesNotPretendToBeManagedLocalChild() {
        var tracker = ClaudeChildTracker()
        let events = tracker.toolResult(.object([
            "type": .string("user"),
            "message": .object(["content": .array([.object(["type": .string("tool_result"), "tool_use_id": .string("remote-tool")])])]),
            "tool_use_result": .object(["status": .string("remote_launched"), "taskId": .string("remote-task")])
        ]))
        #expect(childEvents(events).isEmpty)
        #expect(!tracker.hasActiveChildren)
    }

    @Test func asyncLaunchRemainsActiveUntilNativeCompletion() {
        var tracker = ClaudeChildTracker()
        let launched = childEvents(tracker.toolResult(.object([
            "type": .string("user"),
            "message": .object(["content": .array([.object(["type": .string("tool_result"), "tool_use_id": .string("async-tool")])])]),
            "tool_use_result": .object(["status": .string("async_launched"), "agentId": .string("async-child")])
        ])))
        #expect(launched.contains { $0.id == "async-child" && $0.status == "running" })
        #expect(tracker.hasActiveChildren)
        let completed = childEvents(tracker.system(system("task_notification", taskID: "async-child", extra: [
            "status": .string("completed"), "summary": .string("Background result")
        ])))
        #expect(completed.contains { $0.id == "async-child" && $0.status == "completed" && $0.summary == "Background result" })
        #expect(!tracker.hasActiveChildren)
    }

    @Test func structuredCompletionReplacesEarlierNotificationSummary() {
        var tracker = ClaudeChildTracker()
        _ = tracker.system(started())
        _ = tracker.system(system("task_notification", extra: ["status": .string("completed"), "summary": .string("Short notification")]))
        let report = childEvents(tracker.toolResult(foregroundResult(summary: "Detailed structured report")))
        #expect(report.contains { $0.id == "child-1" && $0.status == "completed" && $0.summary == "Detailed structured report" })
        #expect(!tracker.hasActiveChildren)
    }

    @Test func unknownProgressAndNotificationsCannotIntroduceNonLocalChildren() {
        var tracker = ClaudeChildTracker()
        let progress = tracker.system(system("task_progress", taskID: "unknown", extra: ["description": .string("Unknown task")]))
        let notification = tracker.system(system("task_notification", taskID: "unknown", extra: ["status": .string("completed"), "summary": .string("Unknown result")]))
        #expect(childEvents(progress).isEmpty)
        #expect(childEvents(notification).isEmpty)
        #expect(!tracker.hasActiveChildren)
    }
}
