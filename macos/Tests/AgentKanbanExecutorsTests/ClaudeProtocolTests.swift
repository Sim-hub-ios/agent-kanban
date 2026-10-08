import Foundation
import Testing
import AgentKanbanCore
@testable import AgentKanbanExecutors

@Suite struct ClaudeProtocolTests {
    @Test func readonlyDelegationOnlyAcceptsFixedLocalForegroundRole() {
        let input: JSONValue = .object(["subagent_type": .string("readonly_analyst"), "description": .string("check fixture"), "prompt": .string("read fixture"), "run_in_background": .bool(true), "unknown_future_field": .string("must not forward")])
        let safe = ExecutorRegistry.claudeReadonlyAgentInput(input, readOnly: true)
        #expect(safe?["run_in_background"] == .bool(false))
        #expect(safe?["unknown_future_field"] == .null)
        #expect(ExecutorRegistry.claudeReadonlyAgentInput(input, readOnly: false) == nil)
        for isolation in ["remote", "worktree", "future-mode"] {
            var values = input.object!; values["isolation"] = .string(isolation)
            #expect(ExecutorRegistry.claudeReadonlyAgentInput(.object(values), readOnly: true) == nil)
        }
        var values = input.object!; values["subagent_type"] = .string("general-purpose")
        #expect(ExecutorRegistry.claudeReadonlyAgentInput(.object(values), readOnly: true) == nil)
    }

    @Test func readonlyRoleAndHookMustBeConfirmedBeforeUserPrompt() async throws {
        for response in [#"{"hooks_applied":true,"agents":[]}"#, #"{"hooks_applied":false,"agents":[{"name":"readonly_analyst"}]}"#] {
            let directory = try fixtureDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let executable = directory.appendingPathComponent("fixture")
            let script = """
            #!/bin/sh
            while IFS= read -r line; do
              case "$line" in
                *'"request_id":"kanban-init"'*) printf '%s\\n' '{"type":"control_response","response":{"subtype":"success","request_id":"kanban-init","response":\(response)}}' ;;
                *'"type":"user"'*) printf '%s\\n' '{"type":"result","is_error":false,"result":"USER PROMPT MUST NOT BE SENT"}' ;;
              esac
            done
            """
            try writeExecutable(script, to: executable)
            let registry = ExecutorRegistry(executableOverrides: [.claude: executable.path])
            let run = try await registry.start(.init(runID: UUID().uuidString, conversationID: "chat", projectPath: directory.path, prompt: "must not send", selection: .init(executor: .claude), phase: .acceptance))
            var failed = false, completed = false
            for await event in run.events {
                if case .failed = event { failed = true }
                if case .completed = event { completed = true }
            }
            #expect(failed && !completed)
            #expect(await registry.cancel(runID: run.id) == .alreadyFinished)
        }
    }

    @Test func forwardedChildFramesHaveIndependentSummaryAndMainReply() async throws {
        let frames = [
            #"{"type":"system","subtype":"init","session_id":"main-session","model":"fixture-model"}"#,
            #"{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_start","content_block":{"type":"tool_use","id":"agent-tool","name":"Agent"}}}"#,
            #"{"type":"system","subtype":"task_started","task_id":"child-1","run_id":"run-1","task_type":"local_agent","tool_use_id":"agent-tool","description":"readonly fixture","is_backgrounded":false}"#,
            #"{"type":"assistant","parent_tool_use_id":"agent-tool","agent_id":"child-1","message":{"role":"assistant","content":[{"type":"text","text":"private child analysis"}]}}"#,
            #"{"type":"stream_event","parent_tool_use_id":"agent-tool","agent_id":"child-1","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"child text must not appear in parent"}}}"#,
            #"{"type":"user","parent_tool_use_id":null,"tool_use_result":{"status":"completed","agentId":"child-1","content":[{"type":"text","text":"verified child summary"}]},"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"agent-tool","content":"wrapped result"}]}}"#,
            #"{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"parent answer"}}}"#,
            #"{"type":"result","parent_tool_use_id":null,"is_error":false,"result":"parent answer"}"#
        ]
        let result = try await runFixture(frames)
        #expect(result.completed == "parent answer")
        #expect(result.streamed == "parent answer")
        #expect(result.childIDs == ["child-1"])
        #expect(result.summary == "verified child summary")
        #expect(result.failures.isEmpty)
    }

    @Test func parentResultWaitsForLateChildSummaryAndBackgroundDrain() async throws {
        let frames = [
            #"{"type":"system","subtype":"init","session_id":"main-session","model":"fixture-model"}"#,
            #"{"type":"system","subtype":"task_started","task_id":"child-1","run_id":"run-1","task_type":"local_agent","tool_use_id":"agent-tool","description":"fixture","is_backgrounded":true}"#,
            #"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"child-1","run_id":"run-1","task_type":"local_agent"}]}"#,
            #"{"type":"result","is_error":false,"result":"parent finished first"}"#,
            #"{"type":"system","subtype":"task_notification","task_id":"child-1","run_id":"run-1","status":"completed","summary":"late child summary"}"#,
            #"{"type":"system","subtype":"background_tasks_changed","tasks":[]}"#
        ]
        let result = try await runFixture(frames)
        #expect(result.completed == "parent finished first")
        #expect(result.summary == "late child summary")
        #expect(result.failures.isEmpty)
    }

    @Test func nativePreToolUseHookRejectsRemoteDelegation() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fixture")
        let script = #"""
        #!/bin/sh
        while IFS= read -r line; do
          case "$line" in
            *'"request_id":"kanban-init"'*) printf '%s\n' '{"type":"control_response","response":{"subtype":"success","request_id":"kanban-init","response":{"hooks_applied":true,"agents":[{"name":"readonly_analyst"}]}}}' ;;
            *'"type":"user"'*) printf '%s\n' '{"type":"control_request","request_id":"hook-1","request":{"subtype":"hook_callback","callback_id":"kanban-agent-policy","input":{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":"readonly_analyst","description":"test","prompt":"test","isolation":"remote"}}}}' ;;
            *'"permissionDecision":"deny"'*) printf '%s\n' '{"type":"result","is_error":false,"result":"remote denied"}' ;;
          esac
        done
        """#
        try writeExecutable(script, to: executable)
        let registry = ExecutorRegistry(executableOverrides: [.claude: executable.path])
        let run = try await registry.start(.init(runID: UUID().uuidString, conversationID: "chat", projectPath: directory.path, prompt: "fixture", selection: .init(executor: .claude), phase: .acceptance))
        var output: String?
        for await event in run.events { if case .completed(let value) = event { output = value } }
        #expect(output == "remote denied")
    }

    @Test func cancellationDuringCompletionWaitsForSameStopBarrier() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fixture")
        let marker = directory.appendingPathComponent("terminating")
        let script = """
        #!/bin/sh
        trap 'printf stopping > "\(marker.path)"; sleep 0.5; exit 0' TERM
        while IFS= read -r line; do
          case "$line" in
            *'"request_id":"kanban-init"'*) printf '%s\\n' '{"type":"control_response","response":{"subtype":"success","request_id":"kanban-init","response":{}}}' ;;
            *'"type":"user"'*)
              printf '%s\\n' '{"type":"system","subtype":"init","session_id":"fixture-session","model":"fixture-model"}'
              printf '%s\\n' '{"type":"result","is_error":false,"result":"normal completion raced with user stop"}' ;;
          esac
        done
        """
        try writeExecutable(script, to: executable)
        let registry = ExecutorRegistry(executableOverrides: [.claude: executable.path])
        let run = try await registry.start(.init(runID: UUID().uuidString, conversationID: "chat", projectPath: directory.path, prompt: "fixture", selection: .init(executor: .claude)))
        let collector = Task {
            var cancelled = false, completed = false
            for await event in run.events {
                if case .cancelled = event { cancelled = true }
                if case .completed = event { completed = true }
            }
            return (cancelled, completed)
        }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: marker.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(await registry.cancel(runID: run.id) == .confirmed)
        let result = await collector.value
        #expect(result.0 && !result.1)
        if let identity = await registry.processIdentity(runID: run.id) {
            #expect(ManagedProcessIdentity.readStartTime(pid: identity.processID) == nil)
        }
    }

    private struct Result {
        var completed: String?, streamed = "", summary = "", childIDs: Set<String> = [], failures: [String] = []
    }
    private func runFixture(_ frames: [String]) async throws -> Result {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fixture")
        let prints = frames.map { "printf '%s\\n' '" + $0 + "'" }.joined(separator: "\n")
        let script = """
        #!/bin/sh
        while IFS= read -r line; do
          case "$line" in
            *'"request_id":"kanban-init"'*) printf '%s\\n' '{"type":"control_response","response":{"subtype":"success","request_id":"kanban-init","response":{"hooks_applied":true,"agents":[{"name":"readonly_analyst"}]}}}' ;;
            *'"type":"user"'*)
              \(prints) ;;
          esac
        done
        """
        try writeExecutable(script, to: executable)
        let registry = ExecutorRegistry(executableOverrides: [.claude: executable.path])
        let run = try await registry.start(.init(runID: UUID().uuidString, conversationID: "chat", projectPath: directory.path, prompt: "fixture", selection: .init(executor: .claude), phase: .acceptance))
        let timeout = Task { do { try await Task.sleep(for: .seconds(10)) } catch { return }; _ = await registry.cancel(runID: run.id) }
        var result = Result()
        for await event in run.events {
            switch event {
            case .textDelta(let text): result.streamed += text
            case .completed(let text): result.completed = text
            case .agent(let id, let status, let summary): result.childIDs.insert(id); if status == "completed" { result.summary = summary }
            case .failed(let text), .recoveryRequired(let text): result.failures.append(text)
            default: break
            }
        }
        timeout.cancel()
        return result
    }
    private func fixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-protocol-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func writeExecutable(_ script: String, to url: URL) throws {
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
