import Foundation
import XCTest
@testable import AgentKanbanCore

final class GitWorktreeTests: XCTestCase {
    private var fixture: URL!
    private var project: URL!

    override func setUpWithError() throws {
        fixture = FileManager.default.temporaryDirectory.appendingPathComponent("kanban-worktree-tests-\(UUID().uuidString)")
        project = fixture.appendingPathComponent("project with spaces")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        _ = try git(project, ["init", "--quiet"])
    }

    override func tearDownWithError() throws {
        if let fixture { try FileManager.default.removeItem(at: fixture) }
    }

    func testCreationStartsAtCommittedHeadAndPreservesDirtyProject() throws {
        try commitFixture()
        let originalHead = try GitRepository.head(path: project.path)
        let originalBranch = try git(project, ["symbolic-ref", "HEAD"])
        try Data("staged edit\n".utf8).write(to: project.appendingPathComponent("tracked.txt"))
        _ = try git(project, ["add", "tracked.txt"])
        try Data("unstaged edit\n".utf8).write(to: project.appendingPathComponent("tracked.txt"))
        try Data("private draft\n".utf8).write(to: project.appendingPathComponent("untracked.txt"))
        let originalFingerprint = try GitRepository.fingerprint(path: project.path)
        let destination = worktreeURL("task-1")

        let created = try GitRepository.createWorktree(projectPath: project.path, destination: destination.path, branch: "codex/kanban-task-1")

        XCTAssertEqual(created, destination.standardizedFileURL.resolvingSymlinksInPath().path)
        XCTAssertTrue(try GitRepository.isWorktree(path: created, of: project.path))
        XCTAssertEqual(try GitRepository.head(path: created), originalHead)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("tracked.txt"), encoding: .utf8), "committed\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("untracked.txt").path))
        XCTAssertEqual(try GitRepository.fingerprint(path: project.path), originalFingerprint)
        XCTAssertEqual(try git(project, ["symbolic-ref", "HEAD"]), originalBranch)
        XCTAssertEqual(try git(destination, ["status", "--porcelain"]), "")
        try Data("task implementation\n".utf8).write(to: destination.appendingPathComponent("tracked.txt"))
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("tracked.txt"), encoding: .utf8), "unstaged edit\n")
        XCTAssertEqual(try git(project, ["show", ":tracked.txt"]), "staged edit")
    }

    func testRepeatedCreationReusesOnlySameRegisteredBranchWithoutResettingEdits() throws {
        try commitFixture()
        let destination = worktreeURL("repeated")
        let created = try GitRepository.createWorktree(projectPath: project.path, destination: destination.path, branch: "codex/kanban-repeated")
        try Data("unfinished work\n".utf8).write(to: destination.appendingPathComponent("tracked.txt"))
        let reused = try GitRepository.createWorktree(projectPath: project.path, destination: destination.path, branch: "codex/kanban-repeated")
        XCTAssertEqual(reused, created)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("tracked.txt"), encoding: .utf8), "unfinished work\n")
        XCTAssertThrowsError(try GitRepository.createWorktree(projectPath: project.path, destination: destination.path, branch: "codex/kanban-other"))
        XCTAssertEqual(try git(destination, ["symbolic-ref", "HEAD"]), "refs/heads/codex/kanban-repeated")
        let registered = try git(project, ["worktree", "list", "--porcelain"])
            .components(separatedBy: "\n").filter { $0.hasPrefix("worktree ") }
        XCTAssertEqual(registered.count, 2)
    }

    func testValidationRejectsProjectSubdirectoriesAndExternalRepositories() throws {
        try commitFixture()
        let destination = worktreeURL("same-repository")
        _ = try GitRepository.createWorktree(projectPath: project.path, destination: destination.path, branch: "codex/kanban-same-repository")
        let child = destination.appendingPathComponent("nested directory")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let external = fixture.appendingPathComponent("external repository")
        _ = try git(project, ["clone", "--quiet", project.path, external.path])
        XCTAssertEqual(try GitRepository.head(path: external.path), try GitRepository.head(path: project.path))
        XCTAssertFalse(try GitRepository.isWorktree(path: project.path, of: project.path))
        XCTAssertFalse(try GitRepository.isWorktree(path: child.path, of: project.path))
        XCTAssertFalse(try GitRepository.isWorktree(path: external.path, of: project.path))
        XCTAssertFalse(try GitRepository.isWorktree(path: fixture.appendingPathComponent("missing").path, of: project.path))
        XCTAssertThrowsError(try GitRepository.createWorktree(projectPath: project.path, destination: external.path, branch: "codex/kanban-external"))
        XCTAssertThrowsError(try GitRepository.createWorktree(projectPath: project.path, destination: project.path, branch: "codex/kanban-project"))
        XCTAssertTrue(try GitRepository.isWorktree(path: destination.path, of: project.path))
    }

    func testWorktreeRequiresInitialCommitAndDoesNotCreateDestinationOnFailure() throws {
        let destination = worktreeURL("unborn")
        try Data("initial but uncommitted\n".utf8).write(to: project.appendingPathComponent("tracked.txt"))
        _ = try git(project, ["add", "tracked.txt"])
        XCTAssertThrowsError(try GitRepository.createWorktree(projectPath: project.path, destination: destination.path, branch: "codex/kanban-unborn"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try GitRepository.head(path: project.path), "UNBORN")
        XCTAssertEqual(try git(project, ["show", ":tracked.txt"]), "initial but uncommitted")
    }

    func testExistingDirectoriesAndBranchesAreNeverOverwritten() throws {
        try commitFixture()
        let destination = worktreeURL("occupied")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let marker = destination.appendingPathComponent("keep.txt")
        try Data("keep\n".utf8).write(to: marker)
        XCTAssertThrowsError(try GitRepository.createWorktree(projectPath: project.path, destination: destination.path, branch: "codex/kanban-occupied"))
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "keep\n")

        _ = try git(project, ["branch", "codex/kanban-existing"])
        let headBefore = try git(project, ["rev-parse", "codex/kanban-existing"])
        let otherDestination = worktreeURL("existing-branch")
        XCTAssertThrowsError(try GitRepository.createWorktree(projectPath: project.path, destination: otherDestination.path, branch: "codex/kanban-existing"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: otherDestination.path))
        XCTAssertEqual(try git(project, ["rev-parse", "codex/kanban-existing"]), headBefore)
    }

    func testPathsAndBranchNamesArePassedAsArgumentsWithoutShellExpansion() throws {
        try commitFixture()
        let destination = worktreeURL("task folder;literal-$value")
        let branch = "codex/kanban-$literal"
        let created = try GitRepository.createWorktree(projectPath: project.path, destination: destination.path, branch: branch)
        XCTAssertTrue(FileManager.default.fileExists(atPath: created))
        XCTAssertEqual(try git(destination, ["symbolic-ref", "HEAD"]), "refs/heads/\(branch)")
        XCTAssertEqual(try GitRepository.createWorktree(projectPath: project.path, destination: destination.path, branch: branch), created)
        XCTAssertThrowsError(try GitRepository.createWorktree(projectPath: project.path, destination: worktreeURL("bad-branch").path, branch: "--orphan"))
    }

    private func worktreeURL(_ taskID: String) -> URL {
        fixture.appendingPathComponent("App Data/Worktrees/project-id").appendingPathComponent(taskID)
    }

    private func commitFixture() throws {
        try Data("committed\n".utf8).write(to: project.appendingPathComponent("tracked.txt"))
        _ = try git(project, ["add", "tracked.txt"])
        _ = try git(project, ["-c", "user.name=Tests", "-c", "user.email=tests@example.invalid", "commit", "--quiet", "-m", "worktree fixture"])
    }

    @discardableResult
    private func git(_ path: URL, _ arguments: [String]) throws -> String {
        let outputURL = fixture.appendingPathComponent("git-output-\(UUID().uuidString)")
        XCTAssertTrue(FileManager.default.createFile(atPath: outputURL.path, contents: nil))
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close(); try? FileManager.default.removeItem(at: outputURL) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path.path] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment
        try process.run(); process.waitUntilExit()
        let text = String(decoding: try Data(contentsOf: outputURL), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else { throw KanbanError.invalid("Test Git command failed: \(text)") }
        return text
    }
}
