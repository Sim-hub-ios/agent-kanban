import Darwin
import Foundation

/// Opt-in diagnostics. No observable UI state is changed by the watchdog or logger.
final class HangDiagnostics: @unchecked Sendable {
    static let shared = HangDiagnostics(enabled: configurationEnabled())
    let isEnabled: Bool
    private let queue = DispatchQueue(label: "AgentKanban.diagnostics.watchdog", qos: .utility)
    private let sampler = DispatchQueue(label: "AgentKanban.diagnostics.sample", qos: .utility)
    private let captureOverride: (@Sendable () -> Void)?
    private let admissionLock = NSLock()
    private var admittedRecords = 0
    private var timer: DispatchSourceTimer?
    private var session: HangDiagnosticSession?
    private var state = HangMonitorState()
    private var generation = 0
    private var heartbeatSequence = 0
    private var pendingHeartbeat: Int?

    init(enabled: Bool, capture: (@Sendable () -> Void)? = nil) { isEnabled = enabled; captureOverride = capture }

    /// Test/termination coordination without blocking the main queue.
    func waitForPendingWrites() async {
        guard isEnabled else { return }
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    static func configurationEnabled(environment: [String: String] = ProcessInfo.processInfo.environment,
                                     info: [String: Any]? = Bundle.main.infoDictionary) -> Bool {
        configurationValue(for: "AGENT_KANBAN_DIAGNOSTICS", environment: environment, info: info) == "1"
    }

    /// Finder/LaunchServices may not propagate LSEnvironment. All isolated-run settings use the same fallback.
    /// An explicit environment value (including "0") always wins over the debug bundle's defaults.
    static func configurationValue(for key: String,
                                   environment: [String: String] = ProcessInfo.processInfo.environment,
                                   info: [String: Any]? = Bundle.main.infoDictionary) -> String? {
        guard ["AGENT_KANBAN_DIAGNOSTICS", "AGENT_KANBAN_SCROLL_VARIANT", "AGENT_KANBAN_DATA_DIR"].contains(key) else { return nil }
        if let value = environment[key] { return value }
        #if DEBUG
        return (info?["LSEnvironment"] as? [String: String])?[key]
        #else
        return nil
        #endif
    }

    /// A new, private session subdirectory is created on the background queue only when enabled.
    func start(directory: URL) {
        guard isEnabled else { return }
        queue.async { [self] in
            guard session == nil else { return }
            guard let writer = try? HangDiagnosticSession(directory: directory) else { return }
            session = writer
            generation += 1
            state = HangMonitorState()
            pendingHeartbeat = nil
            writer.record(event: "session-started", fields: ["pid": String(ProcessInfo.processInfo.processIdentifier)])
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(100))
            source.setEventHandler { [weak self] in self?.tick() }
            timer = source
            source.resume()
        }
    }

    /// Nonblocking even when the main thread is hung. Cancels an in-flight sampler, never the app.
    func stop() {
        guard isEnabled else { return }
        queue.async { [self] in
            timer?.cancel(); timer = nil
            session?.record(event: "session-stopped", fields: [:])
            session?.stop(); session = nil
            generation += 1
            pendingHeartbeat = nil
            state = HangMonitorState()
        }
    }

    /// Only known events and metadata values are accepted. Message text, paths and credentials are dropped.
    func record(event: String, fields: [String: String] = [:]) {
        guard isEnabled, HangDiagnosticPrivacy.events.contains(event) else { return }
        let safe = HangDiagnosticPrivacy.sanitize(fields)
        // A pathological event producer cannot enqueue an unbounded number of log writes.
        admissionLock.lock()
        guard admittedRecords < 128 else { admissionLock.unlock(); return }
        admittedRecords += 1
        admissionLock.unlock()
        queue.async { [self] in
            session?.record(event: event, fields: safe)
            admissionLock.lock(); admittedRecords -= 1; admissionLock.unlock()
        }
    }

    private func tick() {
        guard let session else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for action in state.tick(at: now, wallTime: Date.timeIntervalSinceReferenceDate, debuggerAttached: Self.debuggerAttached()) {
            switch action {
            case let .detected(duration, capture):
                session.record(event: "hang-detected", fields: ["duration_ms": Self.milliseconds(duration), "capture": capture ? "1" : "0"])
                if capture {
                    let override = captureOverride
                    sampler.async { if let override { override() } else { session.capture() } }
                }
            case let .observationGap(duration):
                session.record(event: "observation-gap", fields: ["duration_ms": Self.milliseconds(duration)])
            case .recovered: break
            }
        }
        // There is at most ONE outstanding main-queue block, even during a long hang.
        guard pendingHeartbeat == nil else { return }
        heartbeatSequence += 1
        let identifier = heartbeatSequence, currentGeneration = generation
        pendingHeartbeat = identifier
        state.scheduleHeartbeat(at: now)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.queue.async { [self] in
                guard generation == currentGeneration, pendingHeartbeat == identifier else { return }
                pendingHeartbeat = nil
                if case let .recovered(duration)? = state.acknowledge(at: ProcessInfo.processInfo.systemUptime) {
                    self.session?.record(event: "hang-recovered", fields: ["duration_ms": Self.milliseconds(duration)])
                }
            }
        }
    }

    private static func milliseconds(_ seconds: TimeInterval) -> String { String(Int(min(max(seconds * 1_000, 0), 86_400_000))) }

    private static func debuggerAttached() -> Bool {
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let result = name.withUnsafeMutableBufferPointer { sysctl($0.baseAddress, 4, &process, &size, nil, 0) }
        return result == 0 && (process.kp_proc.p_flag & P_TRACED) != 0
    }
}

/// Pure state machine so stalls, recoveries and the capture budget can be tested without real delays.
struct HangMonitorState {
    enum Action: Equatable { case detected(duration: TimeInterval, capture: Bool), recovered(duration: TimeInterval), observationGap(duration: TimeInterval) }
    let threshold: TimeInterval = 2
    let cooldown: TimeInterval = 60
    let captureLimit = 3
    private(set) var captureCount = 0
    private var pendingSince: TimeInterval?
    private var hangSince: TimeInterval?
    private var lastCapture: TimeInterval?
    private var lastTick: TimeInterval?
    private var lastWall: TimeInterval?

    mutating func scheduleHeartbeat(at now: TimeInterval) { if pendingSince == nil { pendingSince = now } }
    mutating func acknowledge(at now: TimeInterval) -> Action? {
        defer { pendingSince = nil; hangSince = nil }
        return hangSince.map { .recovered(duration: max(0, now - $0)) }
    }

    mutating func tick(at now: TimeInterval, wallTime: TimeInterval, debuggerAttached: Bool = false) -> [Action] {
        defer { lastTick = now; lastWall = wallTime }
        // Sleep/App Nap/process-wide debugger suspension delays BOTH queues. Do not call that a UI hang.
        if let lastTick, let lastWall {
            let gap = now - lastTick, wallGap = wallTime - lastWall
            if gap > 2 || gap < 0 || abs(wallGap - gap) > 2 {
                if pendingSince != nil { pendingSince = now }
                hangSince = nil
                return [.observationGap(duration: max(gap, wallGap, 0))]
            }
        }
        // Sampling a paused debugger creates misleading evidence and interferes with debugging.
        if debuggerAttached {
            if pendingSince != nil { pendingSince = now }
            hangSince = nil
            return []
        }
        guard let pendingSince, hangSince == nil, now - pendingSince >= threshold else { return [] }
        hangSince = pendingSince
        let capture = captureCount < captureLimit && (lastCapture.map { now - $0 >= cooldown } ?? true)
        if capture { captureCount += 1; lastCapture = now }
        return [.detected(duration: now - pendingSince, capture: capture)]
    }
}

enum HangDiagnosticPrivacy {
    static let events: Set<String> = ["workspace-reload", "chat-scroll", "chat-stream-appear", "chat-stream-disappear", "chat-autoscroll", "scroll-context", "conversation-appear", "conversation-disappear", "auto-scroll"]
    private static let identifiers: Set<String> = ["project_id", "conversation_id", "task_id", "run_id"]
    private static let numbers: Set<String> = ["project_count", "task_count", "conversation_count", "message_count", "event_count", "active_run_count", "report_count", "run_count", "content_height", "viewport_height", "visible_height", "scroll_y", "scroll_x", "text_utf8_bytes", "code_block_count", "reload_ms"]
    private static let enumerations: [String: Set<String>] = [
        "route": ["board", "chat", "task", "runs"],
        "variant": ["baseline", "no-selection", "eager-stack", "no-autoscroll"],
        "reason": ["message-count", "run-output", "conversation"]
    ]
    static func sanitize(_ fields: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in fields {
            if identifiers.contains(key), let uuid = UUID(uuidString: value) { result[key] = uuid.uuidString }
            else if numbers.contains(key), value.count <= 32, let number = Double(value), number.isFinite { result[key] = String(number) }
            else if enumerations[key]?.contains(value) == true { result[key] = value }
        }
        return result
    }

    /// Preserve module UUIDs, addresses and source line numbers; omit full process/module filesystem paths.
    static func sanitizeSampleLine(_ line: String) -> String {
        if ["Path:", "Parent Process:", "Responsible:"].contains(where: { line.hasPrefix($0) }) { return "[process metadata redacted]\n" }
        guard let slash = line.range(of: " /", options: .backwards) else { return line }
        let suffix = String(line[slash.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if suffix.contains("/") {
            return String(line[..<slash.lowerBound]) + " [module: " + URL(fileURLWithPath: "/" + suffix).lastPathComponent + "]\n"
        }
        return line
    }
}

/// File and Process ownership stays off the main thread. The lock also bounds simultaneous sample/log writes.
final class HangDiagnosticSession: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private let logURL: URL
    private var log: FileHandle?
    private var logBytes = 0
    private var writtenBytes = 0
    private var stopped = false
    private var process: Process?
    private var captureNumber = 0
    private let rotationBytes = 512 * 1_024
    private let sessionBudget = 8 * 1_024 * 1_024
    private let sampleBudget = 2 * 1_024 * 1_024

    init(directory: URL) throws {
        self.directory = directory.appendingPathComponent("session-\(UUID().uuidString)", isDirectory: true)
        logURL = self.directory.appendingPathComponent("events.jsonl")
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        log = try FileHandle(forWritingTo: logURL)
    }

    func record(event: String, fields: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, writtenBytes < sessionBudget else { return }
        let payload: [String: Any] = ["event": event, "wall_time_ms": Int(Date().timeIntervalSince1970 * 1_000), "uptime_ms": Int(ProcessInfo.processInfo.systemUptime * 1_000), "fields": fields]
        guard var data = try? JSONSerialization.data(withJSONObject: payload, options: .sortedKeys), data.count < 16_384 else { return }
        data.append(0x0A)
        guard writtenBytes + data.count <= sessionBudget else { return }
        do {
            if logBytes + data.count > rotationBytes {
                try log?.close()
                let previous = directory.appendingPathComponent("events.previous.jsonl")
                try? FileManager.default.removeItem(at: previous)
                try FileManager.default.moveItem(at: logURL, to: previous)
                FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
                log = try FileHandle(forWritingTo: logURL)
                logBytes = 0
            }
            try log?.write(contentsOf: data)
            logBytes += data.count; writtenBytes += data.count
        } catch { try? log?.close(); log = nil }
    }

    func capture() {
        lock.lock()
        guard !stopped, writtenBytes < sessionBudget, captureNumber < 3 else { lock.unlock(); return }
        captureNumber += 1
        let number = captureNumber
        let destination = directory.appendingPathComponent("hang-\(number)", isDirectory: true)
        lock.unlock()
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let output = destination.appendingPathComponent("sample.txt")
            FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            let command = Process(), pipe = Pipe()
            command.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            command.arguments = [String(ProcessInfo.processInfo.processIdentifier), "3", "1", "-file", "/dev/stdout"]
            command.standardOutput = pipe; command.standardError = FileHandle.nullDevice
            lock.lock()
            guard !stopped else { lock.unlock(); return }
            process = command
            do { try command.run() } catch { process = nil; lock.unlock(); throw error }
            lock.unlock()
            var buffer = Data(), saved = 0
            // A separate queue drains the pipe; sample never blocks the watchdog or UI.
            while let chunk = try pipe.fileHandleForReading.read(upToCount: 32 * 1_024), !chunk.isEmpty {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let row = buffer.prefix(through: newline)
                    let sanitized = Data(HangDiagnosticPrivacy.sanitizeSampleLine(String(decoding: row, as: UTF8.self)).utf8)
                    buffer.removeSubrange(...newline)
                    lock.lock()
                    if !stopped, saved + sanitized.count <= sampleBudget, writtenBytes + sanitized.count <= sessionBudget {
                        try? handle.write(contentsOf: sanitized)
                        saved += sanitized.count; writtenBytes += sanitized.count
                    }
                    lock.unlock()
                }
                // Defensive cap even if a tool unexpectedly emits a very long line.
                if buffer.count > 64 * 1_024 { buffer.removeAll(keepingCapacity: true) }
            }
            command.waitUntilExit()
            lock.lock(); process = nil; lock.unlock()
            record(event: "sample-finished", fields: ["capture_index": String(number), "bytes": String(saved), "exit_status": String(command.terminationStatus)])
        } catch {
            record(event: "sample-failed", fields: ["capture_index": String(number)])
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        if process?.isRunning == true { process?.terminate() }
        process = nil
        try? log?.close(); log = nil
    }
}
