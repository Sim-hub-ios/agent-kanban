import Foundation
import Testing
import AgentKanbanCore
import AgentKanbanExecutors
@testable import AgentKanban

/// Opt-in: creates only a disposable Git repository; uses the user's existing Codex login.
@Suite("Real native task workflow") @MainActor struct NativeEndToEndTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENT_KANBAN_REAL_APP_FLOW"] == "1"))
    func developmentAcceptanceAndHumanCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kanban-real-flow-\(UUID().uuidString)")
        let working = directory.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func git(_ args: [String]) throws {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", working.path] + args
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit(); try #require(process.terminationStatus == 0)
        }
        try git(["init", "-q"])
        try "Temporary native integration fixture.\n".write(to: working.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try git(["add", "README.md"])
        try git(["-c", "user.name=Fixture", "-c", "user.email=fixture@localhost", "commit", "-qm", "Fixture"])
        let store = AppStore(dataDirectory: directory.appendingPathComponent("data"))
        let repository = try #require(store.repository)
        let project = try await repository.importProject(path: working.path, defaultExecutor: .codex)
        let task = try await repository.createTask(projectID: project.id, title: "Native disposable workflow", description: "Create ready.txt with exactly ready followed by one newline. No other project files should change.", type: .chore)
        let revision = try await repository.saveRevision(taskID: task.id, requirement: task.description, plan: "Create only ready.txt; verify the exact text by reading it.", acceptanceCriteria: ["ready.txt contains exactly ready followed by one newline."])
        try await repository.confirmRevision(id: revision.id)
        try await repository.transitionTask(id: task.id, to: .discussion)
        try await repository.transitionTask(id: task.id, to: .development)
        try await repository.updateSelection(conversationID: task.mainConversationID, selection: .init(executor: .codex, modelID: "gpt-6.1-sol", effort: "low", permission: .requestApproval))
        try await store.reload(); store.selectTask(task.id)
        do {
            store.sendMessage("Implement the confirmed plan now. Create only ready.txt with the exact bytes ready\\n, then read it to verify. Do not commit or run other commands.", attachments: [])
            try await waitForRun(store, count: 1)
            let development = try #require(store.snapshot.runs.first)
            #expect(development.status == .succeeded)
            #expect(development.processID != nil && development.processStartedAt != nil)
            #expect(try Data(contentsOf: working.appendingPathComponent("ready.txt")) == Data("ready\n".utf8))
            store.transitionTask(task.id, to: .acceptance)
            try await waitUntil { store.snapshot.tasks.first?.phase == .acceptance }
            store.runAcceptance(taskID: task.id)
            try await waitForRun(store, count: 2)
            let report = try #require(store.snapshot.reports.first)
            #expect(report.passed && !report.stale)
            #expect(report.sourceRunID != nil)
            #expect(store.snapshot.tasks.first?.phase == .acceptance, "AI does not complete a task")
            store.completeTask(task.id)
            try await waitUntil { store.snapshot.tasks.first?.phase == .completed }
            #expect(store.snapshot.reports.first == report, "Task completion preserves the optional report without implying report approval")
            #expect(try GitRepository.diff(path: working.path).contains("ready.txt"))
            let result: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date()), "executor": "codex", "model": development.effectiveModelID ?? "unknown", "development": development.status.rawValue, "acceptance": "passed", "completion": "human_command", "processIdentityPersisted": true, "temporaryRepositoryOnly": true, "runCount": store.snapshot.runs.count]
            let validation = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("validation/real-app-flow.json")
            try FileManager.default.createDirectory(at: validation.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: validation)
        } catch {
            _ = await store.stopAllForTermination()
            throw error
        }
        #expect(await store.stopAllForTermination())
    }
    private func waitForRun(_ store: AppStore, count: Int) async throws {
        try await waitUntil {
            if let error = store.error { throw KanbanError.invalid(error) }
            return store.snapshot.runs.count >= count && store.snapshot.runs.allSatisfy { $0.status.isTerminal }
        }
    }
    private func waitUntil(_ condition: @MainActor () async throws -> Bool) async throws {
        for _ in 0..<1_200 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw KanbanError.invalid("Native integration workflow timed out")
    }
}
