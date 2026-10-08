import Foundation
import CryptoKit

/// Git access without shell interpolation. Reading diffs and fingerprints never mutates the
/// repository; worktree creation is explicit and leaves the project's checkout untouched.
public enum GitRepository {
    public static let fingerprintVersion = "v2:head+binary-diffs+untracked-sha256+recursive-submodules;exclude=.git,git-ignored"

    public static func canonicalRoot(path: String) throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { throw KanbanError.invalid("所选项目目录不存在。") }
        let root = try git(path: url.path, arguments: ["rev-parse", "--show-toplevel"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { throw KanbanError.invalid("请选择已有的本机 Git 仓库。") }
        return URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Creates a separate checkout from the project's current committed HEAD. Uncommitted
    /// changes remain in the project directory and are never copied, stashed, or committed.
    /// Repeating the same request only reuses a registered worktree on the requested branch.
    public static func createWorktree(projectPath: String, destination: String, branch: String) throws -> String {
        let projectRoot = try canonicalRoot(path: projectPath)
        let destinationURL = canonicalURL(path: destination)
        guard destinationURL.path != projectRoot else { throw KanbanError.invalid("Git Worktree 必须使用独立目录。") }
        let validBranch = try git(path: projectRoot, arguments: ["check-ref-format", "--branch", branch], allowedFailure: true)
        guard validBranch.status == 0, !branch.isEmpty,
              validBranch.text.trimmingCharacters(in: .whitespacesAndNewlines) == branch,
              branch == branch.trimmingCharacters(in: .whitespacesAndNewlines), !branch.hasPrefix("-") else {
            throw KanbanError.invalid("Git Worktree 分支名称无效。")
        }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            guard try isWorktree(path: destinationURL.path, of: projectRoot) else {
                throw KanbanError.invalid("Git Worktree 目标目录已存在，且不是本项目登记的独立工作区；不会覆盖。")
            }
            let reference = try git(path: destinationURL.path, arguments: ["symbolic-ref", "--quiet", "HEAD"], allowedFailure: true)
            guard reference.status == 0,
                  reference.text.trimmingCharacters(in: .whitespacesAndNewlines) == "refs/heads/\(branch)" else {
                throw KanbanError.invalid("已有 Git Worktree 的分支与任务分支不一致；不会切换或覆盖。")
            }
            return destinationURL.path
        }

        guard try head(path: projectRoot) != "UNBORN" else {
            throw KanbanError.invalid("项目尚无初始提交，请先创建 Git 提交再使用 Worktree。")
        }
        let existingBranch = try git(path: projectRoot, arguments: ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], allowedFailure: true)
        guard existingBranch.status == 1 else {
            throw KanbanError.invalid(existingBranch.status == 0
                ? "Git Worktree 任务分支已存在；不会覆盖或重置已有分支。"
                : "无法核对 Git Worktree 分支，请检查仓库引用。")
        }
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try git(path: projectRoot, arguments: ["worktree", "add", "-b", branch, "--", destinationURL.path, "HEAD"])
        guard try isWorktree(path: destinationURL.path, of: projectRoot) else {
            throw KanbanError.invalid("Git Worktree 创建后未通过同仓库登记校验。")
        }
        return destinationURL.path
    }

    /// Accepts only another registered root checkout of the same repository. A subdirectory,
    /// a different repository, and the project directory itself are not independent worktrees.
    public static func isWorktree(path: String, of projectPath: String) throws -> Bool {
        let projectRoot = try canonicalRoot(path: projectPath)
        let candidateURL = canonicalURL(path: path)
        guard let candidateRoot = try? canonicalRoot(path: candidateURL.path),
              candidateRoot == candidateURL.path, candidateRoot != projectRoot else { return false }
        guard try commonGitDirectory(path: projectRoot) == commonGitDirectory(path: candidateRoot) else { return false }
        let entries = try git(path: projectRoot, arguments: ["worktree", "list", "--porcelain", "-z"]).data
        return entries.split(separator: 0).contains { entry in
            let field = String(decoding: entry, as: UTF8.self)
            guard field.hasPrefix("worktree ") else { return false }
            return canonicalURL(path: String(field.dropFirst("worktree ".count))).path == candidateRoot
        }
    }

    private static func canonicalURL(path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func commonGitDirectory(path: String) throws -> String {
        let value = try git(path: path, arguments: ["rev-parse", "--git-common-dir"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw KanbanError.invalid("无法读取 Git 仓库公共目录。") }
        return URL(fileURLWithPath: value, relativeTo: URL(fileURLWithPath: path, isDirectory: true))
            .standardizedFileURL.resolvingSymlinksInPath().path
    }

    public static func head(path: String) throws -> String {
        let result = try git(path: path, arguments: ["rev-parse", "--verify", "HEAD"], allowedFailure: true)
        if result.status == 0 { return result.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let branch = try git(path: path, arguments: ["symbolic-ref", "--quiet", "HEAD"], allowedFailure: true)
        if branch.status == 0 {
            let reference = branch.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let exists = try git(path: path, arguments: ["show-ref", "--verify", "--quiet", reference], allowedFailure: true)
            if exists.status == 1 { return "UNBORN" }
        }
        throw KanbanError.invalid("仓库 HEAD 无法读取；请先检查仓库引用，不能生成可靠验收指纹。")
    }

    public static func diff(path: String) throws -> String {
        let staged = try git(path: path, arguments: ["diff", "--cached", "--no-ext-diff", "--no-textconv", "--stat"]).text
        let unstaged = try git(path: path, arguments: ["diff", "--no-ext-diff", "--no-textconv"]).text
        let stagedBody = try git(path: path, arguments: ["diff", "--cached", "--no-ext-diff", "--no-textconv"]).text
        let untracked = try git(path: path, arguments: ["ls-files", "--others", "--exclude-standard"]).text
        let result = [staged.isEmpty ? "" : "已暂存\n\(staged)\n\(stagedBody)", unstaged.isEmpty ? "" : "未暂存\n\(unstaged)", untracked.isEmpty ? "" : "未跟踪文件\n\(untracked)"].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return result.isEmpty ? "工作目录没有变更。" : result
    }

    public static func fingerprint(path: String) throws -> String {
        try fingerprint(path: path, visited: [])
    }

    private static func fingerprint(path: String, visited: Set<String>) throws -> String {
        let root = try canonicalRoot(path: path)
        guard !visited.contains(root) else { throw KanbanError.invalid("子模块目录形成循环，无法生成可靠验收指纹。") }
        var visited = visited; visited.insert(root)
        var digest = SHA256()
        func include(_ data: Data) {
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { digest.update(data: Data($0)) }
            digest.update(data: data)
        }
        include(Data(fingerprintVersion.utf8)); include(Data(try head(path: root).utf8))
        include(try git(path: root, arguments: ["diff", "--cached", "--binary", "--full-index", "--no-ext-diff", "--no-textconv"]).data)
        include(try git(path: root, arguments: ["diff", "--binary", "--full-index", "--no-ext-diff", "--no-textconv"]).data)
        let names = try git(path: root, arguments: ["ls-files", "--others", "--exclude-standard", "-z"]).data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.sorted()
        for name in names {
            include(Data(name.utf8))
            let url = URL(fileURLWithPath: root).appendingPathComponent(name)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                include(Data("symlink:".utf8)); include(Data(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8))
            } else if attributes[.type] as? FileAttributeType == .typeRegular {
                include(Data("file:".utf8))
                let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
                var fileDigest = SHA256()
                while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty { fileDigest.update(data: chunk) }
                include(Data(fileDigest.finalize()))
                include(Data(String((attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0).utf8))
            } else { throw KanbanError.invalid("无法对未跟踪文件取指纹：\(name)") }
        }
        // A parent Git diff only says "-dirty". Hash the actual nested working tree so
        // two different dirty states cannot reuse one acceptance report.
        let index = try git(path: root, arguments: ["ls-files", "--stage", "-z"]).data
        let submodules = index.split(separator: 0).compactMap { entry -> String? in
            let text = String(decoding: entry, as: UTF8.self)
            guard text.hasPrefix("160000 "), let tab = text.firstIndex(of: "\t") else { return nil }
            return String(text[text.index(after: tab)...])
        }.sorted()
        for name in submodules {
            let modulePath = URL(fileURLWithPath: root).appendingPathComponent(name).standardizedFileURL.resolvingSymlinksInPath().path
            guard modulePath.hasPrefix(root + "/"),
                  FileManager.default.fileExists(atPath: URL(fileURLWithPath: modulePath).appendingPathComponent(".git").path) else {
                throw KanbanError.invalid("子模块未初始化或目录无效：\(name)。请先准备好本机子模块再验收。")
            }
            include(Data("submodule:\(name)".utf8))
            include(Data(try fingerprint(path: modulePath, visited: visited).utf8))
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private struct Result { let data: Data; let status: Int32; var text: String { String(decoding: data, as: UTF8.self) } }
    private static func git(path: String, arguments: [String], allowedFailure: Bool = false) throws -> Result {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-kanban-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("stdout"), errorURL = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil); FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL), error = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? error.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = ["-C", path] + arguments
        process.standardOutput = output; process.standardError = error; process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"; environment["GIT_TERMINAL_PROMPT"] = "0"; environment["LC_ALL"] = "C"
        process.environment = environment
        try process.run(); process.waitUntilExit()
        let result = Result(data: try Data(contentsOf: outputURL), status: process.terminationStatus)
        guard allowedFailure || result.status == 0 else {
            let detail = String(decoding: try Data(contentsOf: errorURL), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw KanbanError.invalid("Git 校验失败：\(detail.prefix(700))")
        }
        return result
    }
}
