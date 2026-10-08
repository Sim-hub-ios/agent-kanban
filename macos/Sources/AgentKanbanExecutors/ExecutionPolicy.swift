import Foundation
import ImageIO
import UniformTypeIdentifiers
import AgentKanbanCore

struct LaunchConfiguration: Sendable {
    var executable: String
    var arguments: [String]
}

/// Encodes only bounded, validated user media. No base64 payload is included in diagnostics.
struct PreparedAttachmentInput: Sendable {
    struct Image: Sendable {
        let path: String
        let mimeType: String
        let data: Data
    }
    let text: String
    let images: [Image]

    var codexContent: [JSONValue] {
        [.object(["type": .string("text"), "text": .string(text)])] + images.map {
            .object(["type": .string("localImage"), "path": .string($0.path)])
        }
    }
    var claudeMessage: JSONValue {
        let imageBlocks: [JSONValue] = images.map {
            .object(["type": .string("image"), "source": .object([
                "type": .string("base64"), "media_type": .string($0.mimeType), "data": .string($0.data.base64EncodedString())
            ])])
        }
        return .object(["type": .string("user"), "session_id": .string(""), "parent_tool_use_id": .null,
                        "message": .object(["role": .string("user"), "content": .array(imageBlocks + [.object(["type": .string("text"), "text": .string(text)])])])])
    }
    func cursorContent(initialization: JSONValue) throws -> [JSONValue] {
        // This client speaks ACP v1. Extra input kinds require an explicit agent opt-in.
        if !images.isEmpty {
            guard initialization["protocolVersion"] == .number(1), initialization["agentCapabilities"]["promptCapabilities"]["image"].bool == true else {
                throw ExecutorError.unsupported("当前 Cursor ACP 未确认图片输入能力，图片未发送；请更新执行器或选择 Codex / Claude。")
            }
        }
        return [.object(["type": .string("text"), "text": .string(text)])] + images.map {
            .object(["type": .string("image"), "data": .string($0.data.base64EncodedString()), "mimeType": .string($0.mimeType)])
        }
    }
}

enum ExecutionPolicy {
    // The aggregate bound also leaves room in the existing 8 MiB protocol frame limit after base64 encoding.
    static let maximumImageBytes = 5 * 1_024 * 1_024
    static func prepareAttachmentInput(_ request: ExecutorRequest) throws -> PreparedAttachmentInput {
        var images: [PreparedAttachmentInput.Image] = [], files: [String] = [], imageBytes = 0
        var seen: Set<String> = []
        for attachment in request.attachments {
            guard attachment.path.hasPrefix("/") else { throw ExecutorError.invalidRequest("附件必须是已保存的本地文件：\(attachment.name)") }
            let url = URL(fileURLWithPath: attachment.path).resolvingSymlinksInPath().standardizedFileURL
            guard seen.insert(url.path).inserted else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw ExecutorError.invalidRequest("附件不是可读取的普通文件：\(attachment.name)") }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let header = try handle.read(upToCount: 64 * 1_024) ?? Data()
            let headerSource = CGImageSourceCreateWithData(header as CFData, nil)
            let actualType = headerSource.flatMap(CGImageSourceGetType).flatMap { UTType($0 as String) }
            let declaredImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
            guard actualType?.conforms(to: .image) == true else {
                if declaredImage { throw ExecutorError.invalidRequest("图片内容无效或无法识别：\(attachment.name)") }
                // Explicitly supplied file references grant read access only to these exact source files.
                let encodedPath = String(decoding: try JSONEncoder().encode(url.path), as: UTF8.self)
                files.append(encodedPath)
                continue
            }
            guard let mime = actualType?.preferredMIMEType, ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mime) else {
                throw ExecutorError.unsupported("图片格式暂不支持：\(attachment.name)。请使用 PNG、JPEG、GIF 或 WebP。")
            }
            guard let size = values.fileSize, size > 0, size <= maximumImageBytes, imageBytes + size <= maximumImageBytes else {
                throw ExecutorError.invalidRequest("每次发送的图片总大小不能超过 5 MiB：\(attachment.name)")
            }
            try handle.seek(toOffset: 0)
            let data = try handle.read(upToCount: maximumImageBytes + 1) ?? Data()
            guard data.count == size, data.count <= maximumImageBytes,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetStatus(source) == .statusComplete, CGImageSourceGetCount(source) > 0,
                  let type = CGImageSourceGetType(source), UTType(type as String)?.preferredMIMEType == mime,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 16_000, height <= 16_000, width * height <= 40_000_000 else {
                throw ExecutorError.invalidRequest("图片损坏或尺寸过大：\(attachment.name)")
            }
            imageBytes += data.count
            images.append(.init(path: url.path, mimeType: mime, data: data))
        }
        let context = files.isEmpty ? "" : "\n\n用户提供的本地附件（仅作为只读参考；以下每行是 JSON 编码的绝对路径）：\n" + files.joined(separator: "\n")
        return PreparedAttachmentInput(text: request.prompt + context, images: images)
    }
    static func validate(_ request: ExecutorRequest) throws {
        guard request.phase?.allowsExecution != false else { throw ExecutorError.invalidRequest("待处理和已完成任务不启动执行器") }
        guard request.projectPath.hasPrefix("/"), FileManager.default.fileExists(atPath: request.projectPath) else { throw ExecutorError.invalidRequest("执行目录必须是现有项目的绝对路径") }
        guard !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !request.attachments.isEmpty else { throw ExecutorError.invalidRequest("请输入消息或添加附件") }
    }
    static func codexThread(_ request: ExecutorRequest) -> [String: JSONValue] {
        var fields: [String: JSONValue] = ["cwd": .string(request.projectPath)]
        if let model = request.selection.modelID { fields["model"] = .string(model) }
        if request.readOnly {
            // The enclosing process already has an inherited Seatbelt write-deny boundary.
            // A second sandbox-exec from inside that boundary cannot initialize on macOS.
            // Thread/start has no externalSandbox variant; the turn declares the external boundary below.
            fields["sandbox"] = .string("danger-full-access"); fields["approvalPolicy"] = .string("never")
            fields["approvalsReviewer"] = .string("user")
        } else if let preset = request.selection.permission {
            fields["sandbox"] = .string(preset == .fullAccess ? "danger-full-access" : "workspace-write")
            fields["approvalPolicy"] = .string(preset == .fullAccess ? "never" : "on-request")
            fields["approvalsReviewer"] = .string(preset == .autoReview ? "auto_review" : "user")
        }
        return fields
    }
    static func codexTurn(_ request: ExecutorRequest, threadID: String) -> [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "threadId": .string(threadID), "cwd": .string(request.projectPath),
            "input": .array([.object(["type": .string("text"), "text": .string(request.prompt)])])
        ]
        if let model = request.selection.modelID { fields["model"] = .string(model) }
        if let effort = request.selection.effort { fields["effort"] = .string(effort) }
        if request.readOnly {
            fields["sandboxPolicy"] = .object(["type": .string("externalSandbox"), "networkAccess": .string("enabled")]); fields["approvalPolicy"] = .string("never")
        } else if let preset = request.selection.permission {
            fields["approvalPolicy"] = .string(preset == .fullAccess ? "never" : "on-request")
            fields["approvalsReviewer"] = .string(preset == .autoReview ? "auto_review" : "user")
            fields["sandboxPolicy"] = preset == .fullAccess ? .object(["type": .string("dangerFullAccess")]) : .object([
                "type": .string("workspaceWrite"), "writableRoots": .array([.string(request.projectPath)]),
                "networkAccess": .bool(false), "excludeSlashTmp": .bool(true), "excludeTmpdirEnvVar": .bool(true)
            ])
        }
        return fields
    }
    /// Outer Seatbelt boundary is inherited by executor tools/children; prompt text is not a security boundary.
    /// Runtime state may write only outside the project. Project content remains denied even if it is nested in an allowed state root.
    static func launch(executable: String, arguments: [String], readOnly: Bool, projectPath: String) throws -> LaunchConfiguration {
        guard readOnly else { return LaunchConfiguration(executable: executable, arguments: arguments) }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else { throw ExecutorError.unsupported("只读执行隔离不可用；不会退回仅提示词约束") }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let writable = [NSTemporaryDirectory(), "/private/tmp", "\(home)/.codex", "\(home)/.claude", "\(home)/.cursor", "\(home)/Library/Caches"]
        let allowed = writable.map { "(subpath \(quote($0)))" }.joined(separator: " ")
        let profile = "(version 1)(allow default)(deny file-write*)(allow file-write* \(allowed) (literal \"/dev/null\"))(deny file-write* (subpath \(quote(projectPath))))"
        return LaunchConfiguration(executable: "/usr/bin/sandbox-exec", arguments: ["-p", profile, executable] + arguments)
    }
    private static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

enum ExecutableLocator {
    static func find(_ executor: ExecutorID) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let name: String
        switch executor { case .codex: name = "codex"; case .claude: name = "claude"; case .cursor: name = "cursor-agent" }
        let directories = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return directories.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
