import Foundation
import Testing
@testable import AgentKanbanCore

@Suite("Task-import source readers") struct ImportReaderTests {
    @Test func intentRequiresExplicitImport() {
        #expect(!ImportReader.isExplicitImport("这里有一些任务 https://github.com/a/b/issues"))
        #expect(!ImportReader.isExplicitImport("解释这份任务表格"))
        #expect(ImportReader.isExplicitImport("把 Excel 中的任务导入看板"))
        #expect(ImportReader.isExplicitImport("Import these issues to the board"))
        #expect(ImportReader.isExplicitImport("帮我将 https://github.com/SuperIM/bug-tracker 指派给我的Issue 添加到任务看板中。我是 zfsherman"))
        #expect(!ImportReader.isExplicitImport("不要把这些 Issue 导入看板"))
    }

    @Test func repositoryRequestKeepsExplicitAssigneeScope() async throws {
        let fixture = GitHubImportFixture()
        let reader = ImportReader(githubRequest: { try await fixture.request($0) })
        let result = await reader.read(files: [], message: "帮我将 https://github.com/SuperIM/bug-tracker 指派给我的Issue 添加到任务看板中。我是 zfsherman")
        #expect(result.failures.isEmpty)
        #expect(result.candidates.map(\.sourceKey) == ["github:superim/bug-tracker#418"])
        #expect(result.sourceRange == "https://github.com/SuperIM/bug-tracker/issues?state=open&assignee=zfsherman")
        #expect(await fixture.endpoints == ["repos/SuperIM/bug-tracker/issues?state=open&per_page=100&page=1&assignee=zfsherman"])
    }

    @Test func naturalSelfAssigneeResolvesAuthenticatedLogin() async throws {
        let fixture = GitHubImportFixture()
        let reader = ImportReader(githubRequest: { try await fixture.request($0) })
        let result = await reader.read(files: [], message: "把https://github.com/SuperIM/bug-tracker指派给我的Issue导入看板")
        #expect(result.failures.isEmpty)
        #expect(result.candidates.count == 1)
        #expect(await fixture.endpoints == ["user", "repos/SuperIM/bug-tracker/issues?state=open&per_page=100&page=1&assignee=zfsherman"])
        #expect(result.sourceRange?.contains("assignee=zfsherman") == true)
    }

    @Test func URLAndSearchAssigneeFiltersArePreserved() async throws {
        for suffix in ["?assignee=zfsherman", "?q=is%3Aopen%20assignee%3A%40me", "?q=is%3Aopen%20assignee%3Azfsherman%20label%3Abug"] {
            let fixture = GitHubImportFixture()
            let reader = ImportReader(githubRequest: { try await fixture.request($0) })
            let result = await reader.read(files: [], message: "导入这些Issue到看板：https://github.com/SuperIM/bug-tracker/issues\(suffix)")
            #expect(result.failures.isEmpty)
            #expect(result.candidates.count == 1)
            let endpoints = await fixture.endpoints
            #expect(endpoints.last?.contains("assignee=zfsherman") == true)
            if suffix.contains("label") { #expect(endpoints.last?.contains("labels=bug") == true) }
            #expect(result.sourceRange?.contains("assignee=zfsherman") == true)
        }
    }

    @Test func conflictingOrUnsupportedFiltersNeverFallBackToRepositoryWideRead() async throws {
        for message in [
            "将https://github.com/SuperIM/bug-tracker/issues?assignee=other 指派给我的Issue添加到任务看板。我是zfsherman",
            "将https://github.com/SuperIM/bug-tracker/issues?assignee=zfsherman 指派给other的Issue导入看板",
            "导入Issue到看板 https://github.com/SuperIM/bug-tracker/issues?assignee=zfsherman&assignee=other",
            "导入Issue到看板 https://github.com/SuperIM/bug-tracker/issues?q=assignee%3Azfsherman%20milestone%3A1",
            "导入Issue到看板 https://github.com/SuperIM/bug-tracker/issues?author=zfsherman",
            "导入Issue到看板 https://github.com/SuperIM/bug-tracker/issues?state=open&q=is%3Aclosed",
            "导入Issue到看板 https://github.com/SuperIM/bug-tracker/issues/418?author=zfsherman"
        ] {
            let fixture = GitHubImportFixture()
            let reader = ImportReader(githubRequest: { try await fixture.request($0) })
            let result = await reader.read(files: [], message: message)
            #expect(!result.failures.isEmpty)
            #expect(result.candidates.isEmpty)
            #expect(await fixture.endpoints.isEmpty)
        }
    }

    @Test func repositoryURLNeedsExplicitIssueImportContext() async {
        let fixture = GitHubImportFixture()
        let reader = ImportReader(githubRequest: { try await fixture.request($0) })
        for message in ["解释 https://github.com/SuperIM/bug-tracker", "将 https://github.com/SuperIM/bug-tracker 导入项目"] {
            let result = await reader.read(files: [], message: message)
            #expect(!result.failures.isEmpty)
            #expect(result.candidates.isEmpty)
        }
        #expect(await fixture.endpoints.isEmpty)
    }

    @Test func singleIssueRemainsSingleIssueAndChecksExplicitScope() async throws {
        let fixture = GitHubImportFixture()
        let reader = ImportReader(githubRequest: { try await fixture.request($0) })
        let result = await reader.read(files: [], message: "将 https://github.com/SuperIM/bug-tracker/issues/418 导入看板")
        #expect(result.failures.isEmpty)
        #expect(result.candidates.count == 1)
        #expect(result.sourceRange == "https://github.com/SuperIM/bug-tracker/issues/418")
        #expect(await fixture.endpoints == ["repos/SuperIM/bug-tracker/issues/418"])
        let mismatch = await reader.read(files: [], message: "将 https://github.com/SuperIM/bug-tracker/issues/418?assignee=other 导入看板")
        #expect(!mismatch.failures.isEmpty)
        #expect(mismatch.candidates.isEmpty)
    }

    @Test func assigneeFilterSurvivesPagination() async throws {
        let fixture = GitHubImportFixture(paginated: true)
        let reader = ImportReader(githubRequest: { try await fixture.request($0) })
        let result = await reader.read(files: [], message: "把 https://github.com/SuperIM/bug-tracker/issues?assignee=zfsherman 导入看板")
        #expect(result.failures.isEmpty)
        #expect(result.candidates.count == 101)
        let endpoints = await fixture.endpoints
        #expect(endpoints.count == 2)
        #expect(endpoints.allSatisfy { $0.contains("assignee=zfsherman") && $0.contains("state=open") })
        #expect(endpoints.last?.contains("page=2") == true)
    }

    @Test func authenticatedIdentityFailureDoesNotReadUnfilteredIssues() async {
        let fixture = GitHubImportFixture(identityUnavailable: true)
        let reader = ImportReader(githubRequest: { try await fixture.request($0) })
        let result = await reader.read(files: [], message: "将 https://github.com/SuperIM/bug-tracker 指派给我的Issue导入看板")
        #expect(!result.failures.isEmpty)
        #expect(result.candidates.isEmpty)
        #expect(await fixture.endpoints == ["user"])
    }
    @Test func multilineCSVAndBadRow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("tasks.csv")
        try "标题,说明,类型,优先级,id\r\n修复粘贴,\"第一行\n第二行，含\"\"引号\"\"\",bug,高,42\r\n,缺少标题,feature,低,43".write(to: file, atomically: true, encoding: .utf8)
        let result = try await ImportReader().readFile(file)
        #expect(result.candidates.count == 1)
        #expect(result.candidates[0].description == "第一行\n第二行，含\"引号\"")
        #expect(result.candidates[0].type == .bug)
        #expect(result.candidates[0].priority == .high)
        #expect(result.warnings.count == 1)
        let second = try await ImportReader().readFile(file)
        #expect(result.candidates[0].sourceKey == second.candidates[0].sourceKey)
    }
    @Test func invalidCSVRejectsWholeSource() throws {
        #expect(throws: (any Error).self) { try ImportReader.delimitedRows("title\n\"unclosed", delimiter: ",") }
    }
    @Test func sameTitleDoesNotMergeDifferentTasks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("tasks.csv")
        try "标题,说明\n修复粘贴,登录页面\n修复粘贴,聊天页面".write(to: file, atomically: true, encoding: .utf8)
        let reader = ImportReader(), first = try await reader.readFile(file)
        #expect(first.candidates.count == 2)
        #expect(Set(first.candidates.map(\.sourceKey)).count == 2)
        let second = try await reader.readFile(file)
        #expect(first.candidates.map(\.sourceKey) == second.candidates.map(\.sourceKey))
    }
    @Test func stableIDsAreScopedToOriginalSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("tasks.csv"), reader = ImportReader()
        try "id,title\n42,原任务".write(to: file, atomically: true, encoding: .utf8)
        let first = try await reader.readFile(file, sourceIdentity: "/projects/a/tasks.csv")
        try "id,title\n42,更新后的任务".write(to: file, atomically: true, encoding: .utf8)
        let updated = try await reader.readFile(file, sourceIdentity: "/projects/a/tasks.csv")
        let other = try await reader.readFile(file, sourceIdentity: "/projects/b/tasks.csv")
        #expect(first.candidates[0].sourceKey == updated.candidates[0].sourceKey)
        #expect(first.candidates[0].sourceKey != other.candidates[0].sourceKey)
    }
    @Test func malformedIssueLinkDoesNotExpandScope() async {
        let result = await ImportReader().read(files: [], message: "把任务导入看板：https://github.com/acme/app/issuesabc 和 https://github.com/acme/app/issues/12abc")
        #expect(result.candidates.isEmpty)
        #expect(result.failures.count == 2)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENT_KANBAN_PUBLIC_ISSUE_PROBE"] == "1"))
    func optionalPublicGitHubIssueSource() async throws {
        let result = await ImportReader().read(files: [], message: "把 https://github.com/microsoft/vscode/issues/1 导入任务看板")
        #expect(result.failures.isEmpty)
        let issue = try #require(result.candidates.first)
        #expect(result.candidates.count == 1)
        #expect(issue.sourceURL == "https://github.com/microsoft/vscode/issues/1")
        #expect(!issue.title.isEmpty)
        #expect(issue.sourceKey == "github:microsoft/vscode#1")
    }
    @Test func actualXLSXSharedAndInlineStrings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("xl/worksheets"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let strings = "<sst><si><t>任务标题</t></si><si><t>说明</t></si><si><t>导入 Excel</t></si></sst>"
        let sheet = "<worksheet><sheetData><row r='1'><c r='A1' t='s'><v>0</v></c><c r='B1' t='s'><v>1</v></c></row><row r='2'><c r='A2' t='s'><v>2</v></c><c r='B2' t='inlineStr'><is><t>第一行&#10;第二行</t></is></c></row></sheetData></worksheet>"
        try strings.write(to: directory.appendingPathComponent("xl/sharedStrings.xml"), atomically: true, encoding: .utf8)
        try sheet.write(to: directory.appendingPathComponent("xl/worksheets/sheet1.xml"), atomically: true, encoding: .utf8)
        let file = directory.appendingPathComponent("tasks.xlsx")
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.arguments = ["-qr", file.path, "xl"]; zip.currentDirectoryURL = directory
        try zip.run(); zip.waitUntilExit(); #expect(zip.terminationStatus == 0)
        let result = try await ImportReader().readFile(file)
        #expect(result.candidates.count == 1)
        #expect(result.candidates[0].title == "导入 Excel")
        #expect(result.candidates[0].description == "第一行\n第二行")
    }
}

private actor GitHubImportFixture {
    private(set) var endpoints: [String] = []
    let paginated: Bool
    let identityUnavailable: Bool
    init(paginated: Bool = false, identityUnavailable: Bool = false) {
        self.paginated = paginated; self.identityUnavailable = identityUnavailable
    }
    func request(_ endpoint: String) throws -> Data {
        endpoints.append(endpoint)
        if endpoint == "user" {
            if identityUnavailable { throw KanbanError.invalid("Fixture: unauthenticated") }
            return Data(#"{"login":"zfsherman"}"#.utf8)
        }
        func issue(_ number: Int) -> String {
            #"{"number":\#(number),"title":"修复登录粘贴","body":"第一行\n第二行","html_url":"https://github.com/SuperIM/bug-tracker/issues/\#(number)","state":"open","assignees":[{"login":"zfsherman"}],"labels":[{"name":"bug"}]}"#
        }
        if endpoint == "repos/SuperIM/bug-tracker/issues/418" { return Data(issue(418).utf8) }
        guard endpoint.hasPrefix("repos/SuperIM/bug-tracker/issues?") else { throw KanbanError.invalid("Unexpected fixture endpoint") }
        let numbers = paginated && endpoint.contains("page=1&") ? Array(1...100) : [418]
        return Data(("[" + numbers.map(issue).joined(separator: ",") + "]").utf8)
    }
}
