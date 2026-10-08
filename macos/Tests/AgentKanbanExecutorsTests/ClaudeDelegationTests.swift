import Foundation
import Darwin
import Testing
import AgentKanbanCore
@testable import AgentKanbanExecutors

@Suite struct ClaudeDelegationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENT_KANBAN_REAL_CLAUDE_DELEGATE"] == "1"))
    func optionalActualClaudeReadonlyDelegation() async throws {
        try await exercise(cancelAfterChildStarts: false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENT_KANBAN_REAL_CLAUDE_CANCEL"] == "1"))
    func optionalActualClaudeChildCancellation() async throws {
        try await exercise(cancelAfterChildStarts: true)
    }

    private func exercise(cancelAfterChildStarts: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-kanban-claude-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await ExecutorCommand.run(executable: "/usr/bin/git", arguments: ["init", "-q", directory.path])
        let phrase = "glass-" + UUID().uuidString.lowercased()
        let readme = "# Claude readonly child fixture\nVerification phrase: \(phrase)\n"
        let readmeURL = directory.appendingPathComponent("README.md")
        try readme.write(to: readmeURL, atomically: true, encoding: .utf8)
        let fingerprint = try GitRepository.fingerprint(path: directory.path)
        let registry: ExecutorRegistry
        // Optional, fixture-only wire capture. The wrapper, native CLI and tee all
        // inherit the managed PGID. No credentials or user repository are read.
        if let traceDirectory = ProcessInfo.processInfo.environment["AGENT_KANBAN_CLAUDE_TRACE_DIR"], let claude = ExecutableLocator.find(.claude) {
            let traceRoot = URL(fileURLWithPath: traceDirectory)
            try FileManager.default.createDirectory(at: traceRoot, withIntermediateDirectories: true)
            let trace = traceRoot.appendingPathComponent(cancelAfterChildStarts ? "cancellation.ndjson" : "delegation.ndjson")
            let wrapper = traceRoot.appendingPathComponent(cancelAfterChildStarts ? "cancel-wrapper" : "delegate-wrapper")
            func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let script = "#!/bin/bash\nset -o pipefail\n\(quote(claude)) \"$@\" | /usr/bin/tee \(quote(trace.path))\n"
            try script.write(to: wrapper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
            registry = ExecutorRegistry(executableOverrides: [.claude: wrapper.path])
        } else { registry = ExecutorRegistry() }
        let prompt: String
        if cancelAfterChildStarts {
            prompt = "Use the Agent tool exactly once with subagent_type readonly_analyst, run_in_background false, no isolation. Ask the child to read README.md repeatedly, one Read call at a time, for 100 iterations before returning its verification phrase. Do not read files yourself. Wait for the child. Do not write files, use other agents, or run commands."
        } else {
            prompt = "Use the Agent tool exactly once with subagent_type readonly_analyst, run_in_background false, no isolation. Ask the child to read README.md with Read and return only its verification phrase. Do not read the file yourself. Wait for the child, then reply only with that phrase. No file writes, commands, other agents or tasks."
        }
        let started = Date()
        let run = try await registry.start(.init(runID: UUID().uuidString, conversationID: UUID().uuidString, projectPath: directory.path, prompt: prompt, selection: .init(executor: .claude), phase: .acceptance))
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            print("Claude child timeout: \(await registry.cancel(runID: run.id))")
        }
        var output = "", childSummary = "", completed = false, cancelled = false
        var childIDs: Set<String> = [], childStatuses: [String] = []
        var identity: ManagedProcessIdentity?, cancellation: CancellationResult?
        var model = "unknown", errors: [String] = []
        for await event in run.events {
            switch event {
            case .processLaunched(let value): identity = value
            case .started(_, _, let value, let policy):
                model = value ?? "unknown"; print("Claude child runtime: \(model), \(policy ?? "unknown")")
            case .agent(let id, let status, let summary):
                childIDs.insert(id); childStatuses.append(status)
                print("Claude child: \(id), \(status), \(summary.prefix(180))")
                if status == "completed" { childSummary = summary }
                if cancelAfterChildStarts && ["running", "started"].contains(status) && cancellation == nil {
                    cancellation = await registry.cancel(runID: run.id)
                    print("Claude child cancellation: \(String(describing: cancellation))")
                }
            case .tool(_, let name, let status, _): print("Claude child tool: \(name), \(status)")
            case .textDelta(let delta): output += delta
            case .completed(let value): completed = true; output = value
            case .cancelled: cancelled = true
            case .approval(let approval): try await registry.respond(runID: run.id, approvalID: approval.id, decision: .deny)
            case .failed(let detail), .recoveryRequired(let detail): errors.append(detail); print("Claude child failure: \(detail)")
            default: break
            }
        }
        timeout.cancel()
        // A failed assertion must never leave an executor behind in a removed cwd.
        let cleanup = await registry.cancel(runID: run.id)
        #expect(cleanup == .confirmed || cleanup == .alreadyFinished)
        #expect(errors.isEmpty)
        #expect(try String(contentsOf: readmeURL, encoding: .utf8) == readme)
        #expect(try GitRepository.fingerprint(path: directory.path) == fingerprint)
        #expect(childIDs.count == 1)
        if cancelAfterChildStarts {
            #expect(cancellation == .confirmed && cancelled && !completed)
        } else {
            #expect(completed && !cancelled && output.trimmingCharacters(in: .whitespacesAndNewlines) == phrase)
            #expect(childStatuses.contains("running") && childStatuses.contains("completed"))
            #expect(childSummary.contains(phrase))
        }
        let process = try #require(identity)
        #expect(ManagedProcessIdentity.readStartTime(pid: process.processID) == nil)
        #expect(kill(-process.processGroupID, 0) == -1 && errno == ESRCH)
        print("Claude child result: cancel=\(cancelAfterChildStarts), model=\(model), completed=\(completed), cancelled=\(cancelled), children=\(childIDs.count), statuses=\(childStatuses), readonlyFingerprintUnchanged=true, groupEmpty=true, seconds=\(Date().timeIntervalSince(started)), output=\(output.prefix(180))")
    }
}
