import Foundation
import Testing
@testable import AgentKanban

@Suite("Opt-in hang diagnostics", .serialized)
struct HangDiagnosticsTests {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("kanban-diagnostics-test-\(UUID().uuidString)", isDirectory: true) }

    @Test func disabledDoesNotCreateDirectoriesOrWriteFiles() async {
        let path = directory()
        let diagnostic = HangDiagnostics(enabled: false)
        diagnostic.start(directory: path)
        diagnostic.record(event: "workspace-reload", fields: ["message_count": "3"])
        diagnostic.stop()
        await diagnostic.waitForPendingWrites()
        #expect(!FileManager.default.fileExists(atPath: path.path))
        #expect(!HangDiagnostics.configurationEnabled(environment: [:], info: [:]))
        #expect(!HangDiagnostics.configurationEnabled(environment: ["AGENT_KANBAN_DIAGNOSTICS": "true"], info: [:]))
        #expect(HangDiagnostics.configurationEnabled(environment: ["AGENT_KANBAN_DIAGNOSTICS": "1"], info: [:]))
    }

    @Test func debugBundleConfigurationFallsBackConsistentlyAndExplicitEnvironmentWins() {
        let info: [String: Any] = ["LSEnvironment": [
            "AGENT_KANBAN_DIAGNOSTICS": "1",
            "AGENT_KANBAN_SCROLL_VARIANT": "no-selection",
            "AGENT_KANBAN_DATA_DIR": "/tmp/isolated-kanban-fixture",
            "UNRELATED_SECRET": "must-not-be-read"
        ]]
        #if DEBUG
        #expect(HangDiagnostics.configurationEnabled(environment: [:], info: info))
        #expect(HangDiagnostics.configurationValue(for: "AGENT_KANBAN_SCROLL_VARIANT", environment: [:], info: info) == "no-selection")
        #expect(HangDiagnostics.configurationValue(for: "AGENT_KANBAN_DATA_DIR", environment: [:], info: info) == "/tmp/isolated-kanban-fixture")
        #else
        #expect(!HangDiagnostics.configurationEnabled(environment: [:], info: info))
        #expect(HangDiagnostics.configurationValue(for: "AGENT_KANBAN_DATA_DIR", environment: [:], info: info) == nil)
        #endif
        #expect(!HangDiagnostics.configurationEnabled(environment: ["AGENT_KANBAN_DIAGNOSTICS": "0"], info: info))
        #expect(HangDiagnostics.configurationValue(for: "AGENT_KANBAN_SCROLL_VARIANT", environment: ["AGENT_KANBAN_SCROLL_VARIANT": "baseline"], info: info) == "baseline")
        #expect(HangDiagnostics.configurationValue(for: "AGENT_KANBAN_DATA_DIR", environment: ["AGENT_KANBAN_DATA_DIR": "/tmp/explicit-fixture"], info: info) == "/tmp/explicit-fixture")
        #expect(HangDiagnostics.configurationValue(for: "UNRELATED_SECRET", environment: ["UNRELATED_SECRET": "another-secret"], info: info) == nil)
    }

    @Test func stallsCaptureOnceRecoverAndRespectCooldownAndSessionLimit() {
        var state = HangMonitorState()
        state.scheduleHeartbeat(at: 0)
        #expect(state.tick(at: 0, wallTime: 0).isEmpty)
        #expect(state.tick(at: 1, wallTime: 1).isEmpty)
        #expect(state.tick(at: 2, wallTime: 2) == [.detected(duration: 2, capture: true)])
        #expect(state.tick(at: 3, wallTime: 3).isEmpty)
        #expect(state.tick(at: 4, wallTime: 4).isEmpty)
        #expect(state.acknowledge(at: 4) == .recovered(duration: 4))
        state.scheduleHeartbeat(at: 5)
        #expect(state.tick(at: 5, wallTime: 5).isEmpty)
        #expect(state.tick(at: 7, wallTime: 7) == [.detected(duration: 2, capture: false)])
        #expect(state.acknowledge(at: 8) == .recovered(duration: 3))
        // A timer discontinuity is suppression, then a fresh continuous stall can be observed.
        #expect(state.tick(at: 62, wallTime: 62) == [.observationGap(duration: 55)])
        for start in [62.0, 124.0, 186.0] {
            state.scheduleHeartbeat(at: start)
            _ = state.tick(at: start, wallTime: start)
            _ = state.tick(at: start + 1, wallTime: start + 1)
            let capture = start < 186
            #expect(state.tick(at: start + 2, wallTime: start + 2) == [.detected(duration: 2, capture: capture)])
            #expect(state.acknowledge(at: start + 3) == .recovered(duration: 3))
            _ = state.tick(at: start + 61, wallTime: start + 61)
        }
        #expect(state.captureCount == 3)
    }

    @Test func sleepAppNapAndDebuggerPausesDoNotConsumeCaptureBudget() {
        var state = HangMonitorState()
        state.scheduleHeartbeat(at: 0)
        _ = state.tick(at: 0, wallTime: 0)
        #expect(state.tick(at: 1, wallTime: 120) == [.observationGap(duration: 120)])
        #expect(state.tick(at: 2, wallTime: 121).isEmpty)
        #expect(state.tick(at: 3, wallTime: 122, debuggerAttached: true).isEmpty)
        #expect(state.tick(at: 4, wallTime: 123, debuggerAttached: true).isEmpty)
        #expect(state.captureCount == 0)
        #expect(state.acknowledge(at: 4) == nil)
        state.scheduleHeartbeat(at: 5)
        #expect(state.tick(at: 15, wallTime: 134) == [.observationGap(duration: 11)])
        #expect(state.tick(at: 16, wallTime: 135).isEmpty)
        #expect(state.tick(at: 17, wallTime: 136) == [.detected(duration: 2, capture: true)])
    }

    @Test func metadataWhitelistDropsTextPathsSecretsAndNonfiniteMetrics() {
        let id = UUID().uuidString
        let safe = HangDiagnosticPrivacy.sanitize([
            "conversation_id": id, "message_count": "12", "scroll_y": "-30.5", "reload_ms": "23",
            "variant": "no-selection", "reason": "message-count", "route": "chat",
            "body": "private message", "path": "/Users/private/attachment.png", "token": "secret",
            "task_id": "private task title", "content_height": "nan", "viewport_height": "infinity",
            "reason-extra": "credential", "run_count": "not-a-number"
        ])
        #expect(safe == ["conversation_id": id, "message_count": "12.0", "scroll_y": "-30.5", "reload_ms": "23.0", "variant": "no-selection", "reason": "message-count", "route": "chat"])
        #expect(!HangDiagnosticPrivacy.events.contains("arbitrary message"))
        #expect(HangDiagnosticPrivacy.events.contains("chat-autoscroll"))
    }

    @Test func sampleRedactionKeepsSymbolicationInformationWithoutFullPaths() {
        #expect(!HangDiagnosticPrivacy.sanitizeSampleLine("Path: /Users/private/App.app\n").contains("/Users"))
        let image = HangDiagnosticPrivacy.sanitizeSampleLine("0x1000 - 0x2000 AgentKanban <01234567-89AB-CDEF> /Users/private/App.app/Contents/MacOS/AgentKanban\n")
        #expect(image.contains("0x1000 - 0x2000"))
        #expect(image.contains("<01234567-89AB-CDEF>"))
        #expect(image.contains("AgentKanban"))
        #expect(!image.contains("/Users"))
        let frame = "  92 layout (in SwiftUI) (ChatViews.swift:128)\n"
        #expect(HangDiagnosticPrivacy.sanitizeSampleLine(frame) == frame)
    }

    @Test func loggerRotatesAndBoundsTotalSessionWrites() throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let session = try HangDiagnosticSession(directory: path)
        for _ in 0..<100_000 { session.record(event: "test-fixed-metadata", fields: ["message_count": "2"]) }
        session.stop()
        let root = try #require(FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil).first)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
        #expect(files.count == 2)
        for file in files {
            #expect(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max <= 512 * 1_024)
        }
    }

    // Deliberately blocking the process main queue must be isolated from unrelated timing-sensitive tests.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENT_KANBAN_RUN_DIAGNOSTIC_SMOKE"] == "1")) @MainActor
    func realWatchdogDetectsBlockedMainQueueAndDispatchesOneBackgroundCapture() async throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let probe = CaptureProbe()
        let diagnostic = HangDiagnostics(enabled: true, capture: { probe.captured() })
        diagnostic.start(directory: path)
        // Ensure the startup timer's first heartbeat has completed before deliberately blocking this TEST runner.
        try await Task.sleep(for: .milliseconds(700))
        Self.blockMainForTest()
        try await Task.sleep(for: .milliseconds(700))
        diagnostic.stop()
        await diagnostic.waitForPendingWrites()
        #expect(probe.count == 1)
        #expect(!probe.capturedOnMain)
        let root = try #require(FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil).first)
        let contents = try String(contentsOf: root.appendingPathComponent("events.jsonl"), encoding: .utf8)
        #expect(contents.contains("hang-detected"))
        #expect(contents.contains("hang-recovered"))
    }

    @MainActor private static func blockMainForTest() { Thread.sleep(forTimeInterval: 3.2) }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENT_KANBAN_RUN_DIAGNOSTIC_SMOKE"] == "1")) @MainActor
    func realSystemSamplerWritesBoundedSymbolicatedReport() async throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let diagnostic = HangDiagnostics(enabled: true)
        diagnostic.start(directory: path)
        try await Task.sleep(for: .milliseconds(700))
        Self.blockMainForTest()
        // The real tool runs for 3 seconds, independently of the test main queue's recovery.
        try await Task.sleep(for: .seconds(4))
        diagnostic.stop()
        await diagnostic.waitForPendingWrites()
        let root = try #require(FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil).first)
        let report = root.appendingPathComponent("hang-1/sample.txt")
        let data = try Data(contentsOf: report)
        #expect(!data.isEmpty)
        #expect(data.count <= 2 * 1_024 * 1_024)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("Call graph:"))
        #expect(!text.contains("/Users/"))
        let events = try String(contentsOf: root.appendingPathComponent("events.jsonl"), encoding: .utf8)
        #expect(events.contains("hang-detected"))
        #expect(events.contains("hang-recovered"))
        #expect(events.contains("sample-finished"))
        let records = events.split(separator: "\n").compactMap { line -> [String: Any]? in
            try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        }
        let finished = try #require(records.first { $0["event"] as? String == "sample-finished" })
        let fields = try #require(finished["fields"] as? [String: String])
        #expect(fields["exit_status"] == "0")
        print("diagnostic-smoke sample_exit_status=\(fields["exit_status"] ?? "missing") sample_bytes=\(data.count) call_graph=1 sample_budget_bytes=2097152 session_budget_bytes=8388608")
    }
}

private final class CaptureProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0
    private var storedOnMain = false
    var count: Int { lock.withLock { storedCount } }
    var capturedOnMain: Bool { lock.withLock { storedOnMain } }
    func captured() { lock.withLock { storedCount += 1; storedOnMain = storedOnMain || Thread.isMainThread } }
}
