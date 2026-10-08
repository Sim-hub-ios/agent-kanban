import Foundation
import Testing
import AgentKanbanCore
@testable import AgentKanbanExecutors

@Suite struct AttachmentProtocolTests {
    // A complete 1 × 1 PNG fixture, unrelated to any user attachment.
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!

    private func fixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kanban-attachment-wire-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func request(_ directory: URL, attachments: [AgentKanbanCore.Attachment] = [], executor: ExecutorID = .codex, prompt: String = "inspect the attachment") -> ExecutorRequest {
        .init(runID: UUID().uuidString, conversationID: UUID().uuidString, projectPath: directory.path, prompt: prompt,
              selection: .init(executor: executor, modelID: executor == .cursor ? "auto" : "fixture-model", effort: executor == .codex ? "high" : nil, permission: .fullAccess), attachments: attachments)
    }
    private func image(in directory: URL, name: String = "fixture.png") throws -> AgentKanbanCore.Attachment {
        let url = directory.appendingPathComponent(name)
        try png.write(to: url)
        return AgentKanbanCore.Attachment(name: name, path: url.path, byteCount: png.count)
    }
    private func executable(in directory: URL, body: String) throws -> URL {
        let executable = directory.appendingPathComponent("fixture-executor")
        try ("#!/bin/sh\n" + body).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }
    private func packets(in directory: URL) throws -> [JSONValue] {
        let data = try Data(contentsOf: directory.appendingPathComponent("wire.jsonl"))
        return try data.split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
    }

    @Test func nativeImageBlocksUseDetectedContentAndKeepOrdinaryFilesReadable() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Detect the actual PNG rather than trusting its extension.
        let picture = try image(in: directory, name: "picture.dat")
        let file = directory.appendingPathComponent("notes.txt")
        try "user supplied context".write(to: file, atomically: true, encoding: .utf8)
        let input = try ExecutionPolicy.prepareAttachmentInput(request(directory, attachments: [picture, picture, AgentKanbanCore.Attachment(name: "notes.txt", path: file.path)]))
        #expect(input.images.count == 1)
        #expect(input.images[0].mimeType == "image/png")
        #expect(input.codexContent[1]["type"].string == "localImage")
        #expect(input.codexContent[1]["path"].string == URL(fileURLWithPath: picture.path).resolvingSymlinksInPath().path)
        let block = input.claudeMessage["message"]["content"].array[0]
        #expect(block["type"].string == "image")
        #expect(block["source"]["type"].string == "base64")
        #expect(block["source"]["media_type"].string == "image/png")
        #expect(block["source"]["data"].string.flatMap { Data(base64Encoded: $0) } == png)
        let cursor = try input.cursorContent(initialization: .object(["protocolVersion": .number(1), "agentCapabilities": .object(["promptCapabilities": .object(["image": .bool(true)])])]))
        #expect(cursor[1]["type"].string == "image")
        #expect(cursor[1]["mimeType"].string == "image/png")
        #expect(cursor[1]["data"].string.flatMap { Data(base64Encoded: $0) } == png)
        #expect(input.text.contains("只读参考"))
        #expect(input.text.contains("notes.txt"))
        #expect(!input.text.contains(png.base64EncodedString()))
    }

    @Test func corruptAndOversizedImagesFailBeforeStartingAnyExecutor() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let corrupt = directory.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: corrupt)
        let registry = ExecutorRegistry(executableOverrides: [.codex: "/does/not/need/to/start"])
        do {
            _ = try await registry.start(request(directory, attachments: [AgentKanbanCore.Attachment(name: "broken.png", path: corrupt.path)]))
            Issue.record("A corrupt image must fail before launching an executor")
        } catch {}
        let large = try image(in: directory, name: "large.png")
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: large.path))
        try handle.truncate(atOffset: UInt64(ExecutionPolicy.maximumImageBytes + 1))
        try handle.close()
        #expect(throws: (any Error).self) { try ExecutionPolicy.prepareAttachmentInput(request(directory, attachments: [large])) }
        let missing = AgentKanbanCore.Attachment(name: "missing.png", path: directory.appendingPathComponent("missing.png").path)
        #expect(throws: (any Error).self) { try ExecutionPolicy.prepareAttachmentInput(request(directory, attachments: [missing])) }
    }

    @Test func noAttachmentRequestsPreserveTextOnlyProtocolCompatibility() throws {
        let input = try ExecutionPolicy.prepareAttachmentInput(request(URL(fileURLWithPath: "/tmp"), prompt: "existing text"))
        let text: JSONValue = .object(["type": .string("text"), "text": .string("existing text")])
        #expect(input.codexContent == [text])
        #expect(input.claudeMessage["message"]["content"].array == [text])
        #expect(try input.cursorContent(initialization: .null) == [text])
    }

    @Test func imageOnlyRequestIsValidButRequiresExplicitCursorImageCapability() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let value = request(directory, attachments: [try image(in: directory)], prompt: "")
        try ExecutionPolicy.validate(value)
        let input = try ExecutionPolicy.prepareAttachmentInput(value)
        let capabilities: [JSONValue] = [.null, .object(["protocolVersion": .number(1)]), .object(["protocolVersion": .number(1), "agentCapabilities": .object(["promptCapabilities": .object(["image": .bool(false)])])])]
        for capability in capabilities {
            #expect(throws: (any Error).self) { try input.cursorContent(initialization: capability) }
        }
    }

    @Test func codexWireReceivesLocalImageRatherThanPathOnlyText() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let picture = try image(in: directory)
        let executable = try executable(in: directory, body: #"""
        while IFS= read -r line; do
          printf '%s\n' "$line" >> wire.jsonl
          case "$line" in
            *'"method":"initialize"'*) printf '%s\n' '{"id":"kanban-1","result":{}}' ;;
            *'"method":"thread/start"'*) printf '%s\n' '{"id":"kanban-2","result":{"thread":{"id":"fixture-thread"},"model":"fixture-model","sandbox":{"type":"dangerFullAccess"}}}' ;;
            *'"method":"turn/start"'*)
              printf '%s\n' '{"id":"kanban-3","result":{"turn":{"id":"fixture-turn"}}}'
              printf '%s\n' '{"method":"turn/completed","params":{"threadId":"fixture-thread","turn":{"id":"fixture-turn","status":"completed"}}}' ;;
          esac
        done
        """#)
        let registry = ExecutorRegistry(executableOverrides: [.codex: executable.path])
        let run = try await registry.start(request(directory, attachments: [picture]))
        var completed = false
        for await event in run.events { if case .completed = event { completed = true } }
        #expect(completed)
        let turn = try #require(packets(in: directory).first { $0["method"].string == "turn/start" })
        #expect(turn["params"]["input"].array.contains { $0["type"].string == "localImage" && $0["path"].string?.hasSuffix("fixture.png") == true })
    }

    @Test func claudeWireReceivesImageBeforeUserText() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try executable(in: directory, body: #"""
        while IFS= read -r line; do
          printf '%s\n' "$line" >> wire.jsonl
          case "$line" in
            *'"request_id":"kanban-init"'*) printf '%s\n' '{"type":"control_response","response":{"subtype":"success","request_id":"kanban-init","response":{}}}' ;;
            *'"type":"user"'*) printf '%s\n' '{"type":"result","is_error":false,"result":"fixture image received"}' ;;
          esac
        done
        """#)
        let registry = ExecutorRegistry(executableOverrides: [.claude: executable.path])
        let run = try await registry.start(request(directory, attachments: [try image(in: directory)], executor: .claude))
        var completed = false
        for await event in run.events { if case .completed(let output) = event { completed = output == "fixture image received" } }
        #expect(completed)
        let user = try #require(packets(in: directory).first { $0["type"].string == "user" })
        let blocks = user["message"]["content"].array
        #expect(blocks[0]["type"].string == "image")
        #expect(blocks[0]["source"]["data"].string.flatMap { Data(base64Encoded: $0) } == png)
        #expect(blocks.last?["type"].string == "text")
    }

    @Test(arguments: [true, false])
    func cursorWireHonorsImageCapabilityBeforeSubmittingPrompt(_ imageSupported: Bool) async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = #"""
        if [ "$1" = "--version" ]; then printf '%s\n' '2026.09.10-fd3934a'; exit 0; fi
        while IFS= read -r line; do
          printf '%s\n' "$line" >> wire.jsonl
          case "$line" in
            *'"method":"initialize"'*) printf '%s\n' '{"id":"kanban-1","result":{"protocolVersion":1,"agentCapabilities":{"promptCapabilities":{"image":IMAGE_CAPABILITY}}}}' ;;
            *'"method":"session/new"'*) printf '%s\n' '{"id":"kanban-2","result":{"sessionId":"fixture-session","models":{"currentModelId":"auto"}}}' ;;
            *'"method":"session/prompt"'*) printf '%s\n' '{"id":"kanban-3","result":{"stopReason":"end_turn"}}' ;;
          esac
        done
        """#.replacingOccurrences(of: "IMAGE_CAPABILITY", with: imageSupported ? "true" : "false")
        let executable = try executable(in: directory, body: body)
        let registry = ExecutorRegistry(executableOverrides: [.cursor: executable.path])
        let run = try await registry.start(request(directory, attachments: [try image(in: directory)], executor: .cursor))
        var completed = false, failed = false, recovery = false
        for await event in run.events {
            if case .completed = event { completed = true }
            if case .failed(let reason) = event { failed = reason.contains("图片未发送") }
            if case .recoveryRequired = event { recovery = true }
        }
        let prompt = try packets(in: directory).first { $0["method"].string == "session/prompt" }
        if imageSupported {
            #expect(completed && !failed)
            let image = try #require(prompt?["params"]["prompt"].array.first { $0["type"].string == "image" })
            #expect(image["mimeType"].string == "image/png")
            #expect(image["data"].string.flatMap { Data(base64Encoded: $0) } == png)
        } else {
            #expect(failed && !completed && !recovery)
            #expect(prompt == nil)
        }
        if let identity = await registry.processIdentity(runID: run.id) { #expect(ManagedProcessIdentity.readStartTime(pid: identity.processID) == nil) }
    }
}
