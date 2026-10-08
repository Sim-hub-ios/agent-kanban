import Foundation
import Darwin

/// Process is confined to this transport. Output callbacks enter the owning actor before state mutation.
final class PipeProcess: @unchecked Sendable {
    private let input: FileHandle
    private let output: FileHandle
    private let errors: FileHandle
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var exited = false
    private var exitStatus: Int32 = 0
    let processID: Int32
    let startedAt: Date
    let messages: AsyncThrowingStream<JSONValue, any Error>
    private let continuation: AsyncThrowingStream<JSONValue, any Error>.Continuation

    init(executable: String, arguments: [String], directory: String?, environment: [String: String]? = nil) throws {
        let pair = AsyncThrowingStream<JSONValue, any Error>.makeStream()
        messages = pair.stream; continuation = pair.continuation
        var inFD: [Int32] = [0, 0], outFD: [Int32] = [0, 0], errFD: [Int32] = [0, 0]
        guard pipe(&inFD) == 0, pipe(&outFD) == 0, pipe(&errFD) == 0 else { throw ExecutorError.unavailable("无法创建执行器管道") }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, inFD[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, outFD[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errFD[1], STDERR_FILENO)
        for fd in inFD + outFD + errFD { posix_spawn_file_actions_addclose(&actions, fd) }
        if let directory { posix_spawn_file_actions_addchdir(&actions, directory) }
        // Each executor gets its own process group. Ordinary inherited tool children share it.
        var mask = sigset_t(), defaults = sigset_t()
        sigemptyset(&mask); sigemptyset(&defaults)
        for signal in [SIGTERM, SIGINT, SIGHUP, SIGPIPE] { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = (environment ?? Self.runtimeEnvironment).map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for item in argv + envp { free(item) } }
        var pid: pid_t = 0
        let result = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                posix_spawn(&pid, executable, &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        close(inFD[0]); close(outFD[1]); close(errFD[1])
        guard result == 0 else {
            close(inFD[1]); close(outFD[0]); close(errFD[0])
            throw ExecutorError.unavailable("执行器启动失败（POSIX \(result)）")
        }
        guard let birth = ManagedProcessIdentity.readStartTime(pid: pid) else {
            // Never persist a guessed birth time: a later recovery must distinguish PID reuse.
            kill(-pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            close(inFD[1]); close(outFD[0]); close(errFD[0])
            throw ExecutorError.unavailable("无法核实执行器启动身份；进程已停止，未发送模型请求")
        }
        processID = pid
        startedAt = birth
        input = FileHandle(fileDescriptor: inFD[1], closeOnDealloc: true)
        output = FileHandle(fileDescriptor: outFD[0], closeOnDealloc: true)
        errors = FileHandle(fileDescriptor: errFD[0], closeOnDealloc: true)
        let sink = continuation, reader = output
        DispatchQueue.global(qos: .userInitiated).async {
            var decoder = JSONLineDecoder()
            do {
                while true {
                    let data = reader.availableData
                    if data.isEmpty { break }
                    for message in try decoder.append(data) { sink.yield(message) }
                }
                sink.finish()
            } catch { sink.finish(throwing: error) }
        }
        let errorReader = errors
        DispatchQueue.global(qos: .utility).async { while !errorReader.availableData.isEmpty {} }
        let childPID = pid
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var status: Int32 = 0
            while waitpid(childPID, &status, 0) == -1 && errno == EINTR {}
            self?.recordExit(status)
        }
    }

    static var runtimeEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let prefix = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        environment["PATH"] = (prefix + [environment["PATH"] ?? ""]).joined(separator: ":")
        return environment
    }
    var isRunning: Bool { stateLock.withLock { !exited } }
    var groupIsEmpty: Bool { kill(-processID, 0) == -1 && errno == ESRCH }
    private func recordExit(_ value: Int32) { stateLock.withLock { exited = true; exitStatus = value } }
    func send(_ message: JSONValue) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(message) + Data([10])
        writeLock.lock(); defer { writeLock.unlock() }
        guard isRunning else { throw ExecutorError.processExited(stateLock.withLock { exitStatus }) }
        try input.write(contentsOf: data)
    }
    private var identityMatches: Bool {
        guard let actual = ManagedProcessIdentity.readStartTime(pid: processID) else { return true }
        return abs(actual.timeIntervalSince(startedAt)) < 0.000001
    }
    func terminate() { if identityMatches && !groupIsEmpty { kill(-processID, SIGTERM) } }
    func forceTerminate() { if identityMatches && !groupIsEmpty { kill(-processID, SIGKILL) } }
    func closeInput() { try? input.close() }
    deinit { terminate() }
}

public struct ManagedProcessIdentity: Sendable, Equatable {
    public let processID: Int32
    public let processGroupID: Int32
    public let startedAt: Date
    static func readStartTime(pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }
}

actor JSONRPCConnection {
    let transport: PipeProcess
    let notifications: AsyncStream<JSONValue>
    private let notificationSink: AsyncStream<JSONValue>.Continuation
    private var pending: [String: CheckedContinuation<JSONValue, any Error>] = [:]
    private var nextID = 0
    private var reader: Task<Void, Never>?
    private var closed = false

    init(executable: String, arguments: [String], directory: String?) throws {
        transport = try PipeProcess(executable: executable, arguments: arguments, directory: directory)
        let pair = AsyncStream<JSONValue>.makeStream()
        notifications = pair.stream; notificationSink = pair.continuation
    }
    func begin() {
        guard reader == nil else { return }
        let stream = transport.messages
        reader = Task { [weak self] in
            do {
                for try await packet in stream { await self?.receive(packet) }
                await self?.ended(nil)
            } catch { await self?.ended(error) }
        }
    }
    func call(_ method: String, params: JSONValue = .object([:]), timeout: Duration = .seconds(20)) async throws -> JSONValue {
        guard !closed else { throw ExecutorError.unavailable("执行器连接已关闭") }
        nextID += 1; let id = "kanban-\(nextID)"
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                do {
                    try transport.send(.object(["jsonrpc": .string("2.0"), "id": .string(id), "method": .string(method), "params": params]))
                    Task { [weak self] in
                        try? await Task.sleep(for: timeout)
                        await self?.expire(id, method: method)
                    }
                } catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
            }
        } onCancel: { Task { await self.expire(id, method: method) } }
    }
    func notify(_ method: String, params: JSONValue = .object([:])) throws {
        try transport.send(.object(["jsonrpc": .string("2.0"), "method": .string(method), "params": params]))
    }
    func respond(id: JSONValue, result: JSONValue) throws {
        try transport.send(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }
    func reject(id: JSONValue, message: String) throws {
        try transport.send(.object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(-32601), "message": .string(message)])]))
    }
    func close() { transport.terminate(); ended(ExecutorError.unavailable("执行器连接已关闭")); reader?.cancel() }
    func insertNotificationBarrier(_ token: String) { notificationSink.yield(.object(["_clientBarrier": .string(token)])) }
    private func receive(_ packet: JSONValue) {
        if let id = packet["id"].idString, packet["method"].string == nil, let continuation = pending.removeValue(forKey: id) {
            if packet["error"] != .null {
                // Generic remote errors may include authentication material. Expose code, not arbitrary message.
                continuation.resume(throwing: ExecutorError.protocolError("执行器协议请求失败（\(packet["error"]["code"].idString ?? "未知")）"))
            } else { continuation.resume(returning: packet["result"]) }
        } else { notificationSink.yield(packet) }
    }
    private func expire(_ id: String, method: String) {
        pending.removeValue(forKey: id)?.resume(throwing: ExecutorError.timeout("\(method) 请求超时；未自动重放"))
    }
    private func ended(_ error: (any Error)?) {
        guard !closed else { return }; closed = true
        for continuation in pending.values { continuation.resume(throwing: error ?? ExecutorError.unavailable("执行器协议连接中断")) }
        pending.removeAll(); notificationSink.finish()
    }
}

struct CommandResult: Sendable { var status: Int32; var output: Data }

enum ExecutorCommand {
    /// Used only for version/catalog/auth probes. Callers parse status fields and discard raw output.
    static func run(executable: String, arguments: [String], timeout: Duration = .seconds(15)) async throws -> CommandResult {
        try await Task.detached {
            let process = Process(), output = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            process.environment = PipeProcess.runtimeEnvironment
            process.standardOutput = output; process.standardError = errors
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let task = Task { try? await Task.sleep(for: timeout); if process.isRunning { process.terminate() } }
            defer { task.cancel() }
            DispatchQueue.global(qos: .utility).async { while !errors.fileHandleForReading.availableData.isEmpty {} }
            var data = Data()
            while true {
                let part = output.fileHandleForReading.availableData
                if part.isEmpty { break }
                if data.count + part.count > 2 * 1_024 * 1_024 { process.terminate(); throw ExecutorError.protocolError("探测结果超出大小上限") }
                data.append(part)
            }
            process.waitUntilExit()
            return CommandResult(status: process.terminationStatus, output: data)
        }.value
    }
}
