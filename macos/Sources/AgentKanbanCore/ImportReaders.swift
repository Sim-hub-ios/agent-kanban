import Foundation
import CryptoKit

public struct ImportReadResult: Sendable {
    public var candidates: [ImportCandidate] = []
    public var warnings: [String] = []
    public var failures: [String] = []
    public var sourceRange: String?
    public init(candidates: [ImportCandidate] = [], warnings: [String] = [], failures: [String] = [], sourceRange: String? = nil) {
        self.candidates = candidates; self.warnings = warnings; self.failures = failures
        self.sourceRange = sourceRange
    }
}

public protocol TaskImportReading: Sendable {
    func read(files: [URL], message: String, sourceIdentities: [String: String]) async -> ImportReadResult
}

/// The built-in task-import skill's read-only source readers. No network write API is used.
public actor ImportReader: TaskImportReading {
    private let githubRequest: (@Sendable (String) async throws -> Data)?
    /// A read-only transport seam for deterministic API fixtures. Production uses gh / URLSession.
    public init(githubRequest: (@Sendable (String) async throws -> Data)? = nil) { self.githubRequest = githubRequest }
    public static func isExplicitImport(_ text: String) -> Bool {
        TaskImportRequestResolver.hasExplicitImportIntent(text)
    }

    public func read(files: [URL], message: String, sourceIdentities: [String: String] = [:]) async -> ImportReadResult {
        var result = ImportReadResult()
        var ranges: [String] = []
        for file in files {
            do {
                let rows = try readFile(file, sourceIdentity: sourceIdentities[file.path])
                result.candidates += rows.candidates; result.warnings += rows.warnings
                ranges.append("文件：\(file.lastPathComponent)")
            } catch { result.failures.append("\(file.lastPathComponent)：\(error.localizedDescription)") }
        }
        // Chinese text commonly follows a pasted URL without a space. Stop at it;
        // percent-encoded query values (including Chinese labels) remain intact.
        let pattern = #"https://github\.com/[^\s<>"'`，。；！？、（）【】「」『』\p{Han}]+"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(message.startIndex..<message.endIndex, in: message)
            let punctuation = CharacterSet(charactersIn: ".,!?;）)]}")
            let links = regex.matches(in: message, range: range).compactMap { Range($0.range, in: message).map { String(message[$0]).trimmingCharacters(in: punctuation) } }
            for link in Set(links).sorted() {
                do {
                    let source = try await readGitHub(link, message: message)
                    result.candidates += source.candidates; ranges.append(source.sourceRange)
                }
                catch { result.failures.append("\(link)：\(error.localizedDescription)") }
            }
        }
        result.sourceRange = ranges.isEmpty ? nil : ranges.joined(separator: "\n")
        if result.candidates.isEmpty && result.warnings.isEmpty && ranges.isEmpty {
            result.warnings.append("请在会话附加 .xlsx、.csv、.tsv 任务表，或提供 GitHub Issue / Issues 列表链接。")
        }
        return result
    }

    public func readFile(_ url: URL, sourceIdentity: String? = nil) throws -> ImportReadResult {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 25 * 1024 * 1024 else { throw KanbanError.invalid("文件超过 25 MB，未导入。") }
        let data = try Data(contentsOf: url)
        let snapshotHash = Self.digest(data)
        let sourceIdentity = sourceIdentity ?? url.resolvingSymlinksInPath().standardizedFileURL.path
        switch url.pathExtension.lowercased() {
        case "csv", "tsv":
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
                throw KanbanError.invalid("请将任务表保存为 UTF-8 或 UTF-16。")
            }
            let rows = try Self.delimitedRows(text, delimiter: url.pathExtension.lowercased() == "tsv" ? "\t" : ",")
            return normalize(rows, source: url.lastPathComponent, sourceIdentity: sourceIdentity, snapshotHash: snapshotHash, sheet: "表格")
        case "xlsx":
            let names = try command("/usr/bin/unzip", ["-Z1", url.path], limit: 1_000_000)
                .split(separator: "\n").map(String.init)
            guard !names.contains(where: { $0.hasPrefix("/") || $0.split(separator: "/").contains("..") }), names.count < 5_000 else {
                throw KanbanError.invalid("工作簿包含无效归档路径或过多文件。")
            }
            var strings: [String] = []
            if names.contains("xl/sharedStrings.xml") {
                let parser = SpreadsheetXML(mode: .strings)
                try parser.parse(Data(try command("/usr/bin/unzip", ["-p", url.path, "xl/sharedStrings.xml"], limit: 32_000_000).utf8))
                strings = parser.strings
            }
            let sheets = names.filter { $0.range(of: #"^xl/worksheets/sheet[0-9]+\.xml$"#, options: .regularExpression) != nil }.sorted()
            guard !sheets.isEmpty, sheets.count <= 100 else { throw KanbanError.invalid("工作簿没有可读取工作表，或超过 100 个工作表。") }
            var result = ImportReadResult()
            var remainingBytes = 64_000_000
            for sheet in sheets {
                let xml = try command("/usr/bin/unzip", ["-p", url.path, sheet], limit: min(remainingBytes, 32_000_000))
                remainingBytes -= xml.utf8.count
                let parser = SpreadsheetXML(mode: .worksheet, sharedStrings: strings)
                try parser.parse(Data(xml.utf8))
                let normalized = normalize(parser.rows, source: url.lastPathComponent, sourceIdentity: sourceIdentity, snapshotHash: snapshotHash, sheet: sheet)
                result.candidates += normalized.candidates; result.warnings += normalized.warnings
                guard result.candidates.count <= 10_000 else { throw KanbanError.invalid("单次导入最多 10,000 项任务。") }
            }
            return result
        case "xls": throw KanbanError.invalid("旧版 .xls 暂不支持，请另存为 .xlsx 或 .csv 后导入。")
        default: throw KanbanError.invalid("仅支持 .xlsx、.csv、.tsv 任务表。")
        }
    }

    public static func delimitedRows(_ text: String, delimiter: Character) throws -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], cell = "", quoted = false
        let chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        var index = 0
        while index < chars.count {
            let c = chars[index]
            if c == "\"" {
                if quoted && index + 1 < chars.count && chars[index + 1] == "\"" { cell.append("\""); index += 1 }
                else if quoted || cell.isEmpty { quoted.toggle() }
                else { cell.append(c) }
            } else if c == delimiter && !quoted { row.append(cell); cell = "" }
            else if c == "\n" && !quoted { row.append(cell); rows.append(row); cell = ""; row = [] }
            else { cell.append(c) }
            guard row.count <= 1_024, rows.count <= 10_001, cell.utf8.count < 2_000_000 else { throw KanbanError.invalid("任务表超过行、列或单元格大小上限。") }
            index += 1
        }
        guard !quoted else { throw KanbanError.invalid("CSV 引号没有闭合。") }
        if !cell.isEmpty || !row.isEmpty { row.append(cell); rows.append(row) }
        return rows
    }

    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func normalize(_ rows: [[String]], source: String, sourceIdentity: String, snapshotHash: String, sheet: String) -> ImportReadResult {
        let nonempty = rows.enumerated().filter { $0.element.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
        guard let header = nonempty.first else { return ImportReadResult(warnings: ["\(source) / \(sheet)：空表格。"]) }
        let names = header.element.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{FEFF}", with: "").lowercased() }
        func column(_ keys: [String]) -> Int? { names.firstIndex { keys.contains($0) } }
        guard let titleColumn = column(["title", "task", "name", "任务", "任务标题", "标题", "任务名称"]) else {
            return ImportReadResult(warnings: ["\(source) / \(sheet)：缺少标题列（title / 任务标题）。"])
        }
        let descriptionColumn = column(["description", "body", "notes", "说明", "描述", "说明与备注", "备注"])
        let typeColumn = column(["type", "类型", "任务类型"]), priorityColumn = column(["priority", "优先级"])
        let idColumn = column(["id", "key", "编号", "任务编号"]), linkColumn = column(["url", "link", "链接", "来源链接"])
        var result = ImportReadResult()
        for (rowIndex, row) in nonempty.dropFirst() {
            func value(_ index: Int?) -> String { guard let index, row.indices.contains(index) else { return "" }; return row[index].trimmingCharacters(in: .whitespacesAndNewlines) }
            let title = value(titleColumn)
            guard !title.isEmpty else { result.warnings.append("\(source) / \(sheet) 第 \(rowIndex + 1) 行：缺少标题。"); continue }
            guard title.count <= 500 else { result.warnings.append("\(source) 第 \(rowIndex + 1) 行：标题超过 500 字。"); continue }
            let rawType = value(typeColumn).lowercased(), rawPriority = value(priorityColumn).lowercased()
            let type: TaskType = ["bug", "fix", "问题修复", "缺陷", "修复"].contains(rawType) ? .bug : ["improvement", "优化", "体验优化"].contains(rawType) ? .improvement : ["chore", "其他", "其他任务"].contains(rawType) ? .chore : .feature
            let priority: TaskPriority = ["urgent", "p0", "紧急"].contains(rawPriority) ? .urgent : ["high", "p1", "高"].contains(rawPriority) ? .high : ["low", "p3", "低"].contains(rawPriority) ? .low : .normal
            let sourceID = value(idColumn)
            let link = value(linkColumn)
            let sourceURL = URL(string: link)?.scheme == "https" ? link : nil
            let identity: [String]
            if sourceID.isEmpty {
                // A title alone is not identity. Without a stable row ID, retries are scoped to the exact source snapshot.
                identity = [sourceIdentity, sheet, snapshotHash, title.precomposedStringWithCanonicalMapping, value(descriptionColumn), type.rawValue, priority.rawValue, sourceURL ?? ""]
            } else { identity = [sourceIdentity, sheet, "id", sourceID] }
            let digest = Self.digest((try? JSONEncoder().encode(identity)) ?? Data())
            result.candidates.append(ImportCandidate(sourceKey: "table:\(digest)", sourceURL: sourceURL, sourceDescription: "\(source) / \(sheet) 第 \(rowIndex + 1) 行", title: title, description: value(descriptionColumn), type: type, priority: priority))
        }
        return result
    }

    private struct GitHubRead {
        let candidates: [ImportCandidate]
        let sourceRange: String
    }

    private struct IssueScope {
        var states: [String] = []
        var assignees: [String] = []
        var labels: [String] = []
        var state: String { states.first ?? "open" }
        var assignee: String? { assignees.first }
    }

    private func readGitHub(_ link: String, message: String) async throws -> GitHubRead {
        guard let url = URL(string: link), url.host == "github.com", url.scheme == "https" else { throw KanbanError.invalid("仅支持 github.com Issue 来源。") }
        let repositoryURL = url.path.range(of: #"^/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/?$"#, options: .regularExpression) != nil
        let issueURL = url.path.range(of: #"^/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/issues(?:/[1-9][0-9]*)?/?$"#, options: .regularExpression) != nil
        // A repository URL may denote a project or code source. Expand to Issues
        // only when the user explicitly requests an Issue import into the board.
        let issueContext = message.lowercased().contains("issue") || message.contains("议题")
        guard issueURL || (repositoryURL && issueContext && Self.isExplicitImport(message)) else {
            throw KanbanError.invalid("请提供完整的 GitHub Issue 或 Issues 列表链接；不扩大无效链接的读取范围。")
        }
        let parts = url.path.split(separator: "/").map(String.init)
        guard !parts.prefix(2).contains(where: { $0 == "." || $0 == ".." }) else { throw KanbanError.invalid("无效 GitHub 仓库路径。") }
        let repository = "\(parts[0])/\(parts[1])"
        let scope = try await issueScope(url: url, message: message)
        if parts.count == 4, Int(parts[3]) != nil {
            let data = try await githubData("repos/\(repository)/issues/\(parts[3])")
            let issue = try JSONDecoder().decode(GitHubIssue.self, from: data)
            guard issue.pull_request == nil else { throw KanbanError.invalid("该链接是 Pull Request，不是 Issue。") }
            try validate(issue, against: scope)
            return GitHubRead(candidates: [issue.candidate(repository: repository)], sourceRange: "https://github.com/\(repository)/issues/\(parts[3])" + scopeDescription(scope, includeDefaultState: false))
        }
        var canonical = URLComponents()
        canonical.scheme = "https"; canonical.host = "github.com"; canonical.path = "/\(repository)/issues"
        canonical.queryItems = [URLQueryItem(name: "state", value: scope.state)]
        if let assignee = scope.assignee { canonical.queryItems?.append(URLQueryItem(name: "assignee", value: assignee)) }
        if !scope.labels.isEmpty { canonical.queryItems?.append(URLQueryItem(name: "labels", value: scope.labels.joined(separator: ","))) }
        let sourceRange = canonical.string ?? "https://github.com/\(repository)/issues"
        var result: [ImportCandidate] = []
        for page in 1...100 {
            var components = URLComponents()
            components.queryItems = [URLQueryItem(name: "state", value: scope.state), URLQueryItem(name: "per_page", value: "100"), URLQueryItem(name: "page", value: String(page))]
            if let assignee = scope.assignee { components.queryItems?.append(URLQueryItem(name: "assignee", value: assignee)) }
            if !scope.labels.isEmpty { components.queryItems?.append(URLQueryItem(name: "labels", value: scope.labels.joined(separator: ","))) }
            let endpoint = "repos/\(repository)/issues\(components.string ?? "")"
            let data = try await githubData(endpoint)
            let issues = try JSONDecoder().decode([GitHubIssue].self, from: data)
            let tasks = issues.filter { $0.pull_request == nil }
            for issue in tasks { try validate(issue, against: scope) }
            result += tasks.map { $0.candidate(repository: repository) }
            if issues.count < 100 { return GitHubRead(candidates: result, sourceRange: sourceRange) }
        }
        throw KanbanError.invalid("Issue 超过单次 10,000 条上限；本批未提交，请按状态或标签缩小来源范围。")
    }

    private func issueScope(url: URL, message: String) async throws -> IssueScope {
        var scope = IssueScope()
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            guard ["state", "q", "labels", "assignee"].contains(item.name) else { throw KanbanError.invalid("Issue 查询参数“\(item.name)”尚不支持，本批未提交。") }
            if item.name == "state" {
                guard let value = item.value, ["open", "closed", "all"].contains(value) else { throw KanbanError.invalid("无效的 Issue 状态筛选，本批未提交。") }
                scope.states.append(value)
            }
            if item.name == "assignee" { scope.assignees.append(try Self.validLogin(item.value ?? "")) }
            if item.name == "q" {
                guard let query = item.value, !query.isEmpty, query.filter({ $0 == "\"" }).count.isMultiple(of: 2) else { throw KanbanError.invalid("无效的 Issue 查询，本批未提交。") }
                let tokens = Self.matches(#"(?:[^\s"]+|"[^"]*")+"#, in: query)
                for token in tokens {
                    switch token {
                    case "is:open", "state:open": scope.states.append("open")
                    case "is:closed", "state:closed": scope.states.append("closed")
                    case "is:all", "state:all": scope.states.append("all")
                    case "is:issue", "sort:updated-desc", "sort:created-desc": break
                    default:
                        if token.hasPrefix("label:") {
                            let label = String(token.dropFirst(6)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                            guard !label.isEmpty else { throw KanbanError.invalid("Issue 标签筛选不能为空。") }
                            scope.labels.append(label)
                        } else if token.hasPrefix("assignee:") { scope.assignees.append(try Self.validLogin(String(token.dropFirst(9)))) }
                        else { throw KanbanError.invalid("Issue 查询条件“\(token)”尚不支持，请提供单项链接或仅按状态/标签/受理人筛选的列表。") }
                    }
                }
            }
            if item.name == "labels" {
                guard let value = item.value, !value.isEmpty else { throw KanbanError.invalid("Issue 标签筛选不能为空。") }
                let labels = value.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard labels.allSatisfy({ !$0.isEmpty }) else { throw KanbanError.invalid("Issue 标签筛选不能为空。") }
                scope.labels += labels
            }
        }
        let lower = message.lowercased()
        let namedAssignment = #"(?:指派给|分配给)\s*@?([A-Za-z0-9][A-Za-z0-9-]*)|\bassigned to\s+(@?me|[A-Za-z0-9][A-Za-z0-9-]*)"#
        let namedAssignees = Self.matches(namedAssignment, in: message, capture: 1) + Self.matches(namedAssignment, in: message, capture: 2)
        for assignee in namedAssignees { scope.assignees.append(try Self.validLogin(assignee.lowercased() == "me" ? "@me" : assignee)) }
        if message.range(of: #"(?:指派给|分配给|\bassigned to)\s*@?[A-Za-z0-9][A-Za-z0-9-]*\s*(?:和|或|、|,|\band\b|\bor\b)\s*@?[A-Za-z0-9]"#, options: [.regularExpression, .caseInsensitive]) != nil {
            throw KanbanError.invalid("本次包含多个受理人条件，请明确单个受理人；本批未提交。")
        }
        let assignedToMe = ["指派给我", "分配给我", "assigned to me", "assigned to @me", "my issues"].contains(where: lower.contains)
        if assignedToMe {
            let loginPattern = #"(?:我是|我的\s*(?:github\s*)?(?:账号|账户|用户名)\s*(?:是|为)?|\bi am\b|\bi'm\b|\bmy github (?:username|account) is\b)\s*[:：]?\s*@?([A-Za-z0-9][A-Za-z0-9-]*)"#
            let logins = Self.matches(loginPattern, in: message, capture: 1).map { $0.lowercased() }
            guard Set(logins).count <= 1 else { throw KanbanError.invalid("会话中出现多个 GitHub 用户名，请明确本次指派给谁的 Issue；本批未提交。") }
            scope.assignees.append(try Self.validLogin(logins.first ?? "@me"))
        }
        if lower.contains("所有状态") || lower.contains("包括已关闭") || lower.contains("all states") { scope.states.append("all") }
        else if lower.contains("已关闭的issue") || lower.contains("已关闭的 issue") || lower.contains("closed issues") { scope.states.append("closed") }
        guard Set(scope.states).count <= 1 else { throw KanbanError.invalid("Issue 状态条件冲突，请明确本次读取范围；本批未提交。") }
        // Resolve @me through GitHub itself; never drop a failed identity filter.
        if scope.assignees.contains("@me") {
            let data = try await githubData("user")
            struct CurrentUser: Decodable { let login: String }
            let login = try Self.validLogin(JSONDecoder().decode(CurrentUser.self, from: data).login)
            guard login != "@me" else { throw KanbanError.invalid("无法确认当前 GitHub 账号，本批未提交。") }
            scope.assignees = scope.assignees.map { $0 == "@me" ? login : $0 }
        }
        guard Set(scope.assignees).count <= 1 else { throw KanbanError.invalid("Issue 链接与会话中的受理人条件冲突，请明确本次范围；本批未提交。") }
        scope.states = Array(Set(scope.states)).sorted()
        scope.assignees = Array(Set(scope.assignees)).sorted()
        scope.labels = Array(Set(scope.labels)).sorted()
        return scope
    }

    private func validate(_ issue: GitHubIssue, against scope: IssueScope) throws {
        if !scope.states.isEmpty, scope.state != "all", issue.state != scope.state { throw KanbanError.invalid("Issue #\(issue.number) 与请求的状态筛选不符；本批未提交。") }
        if let assignee = scope.assignee, issue.assignees?.contains(where: { $0.login.lowercased() == assignee }) != true { throw KanbanError.invalid("Issue #\(issue.number) 与请求的受理人筛选不符；本批未提交。") }
        if !scope.labels.isEmpty {
            let labels = Set(issue.labels?.map(\.name) ?? [])
            guard scope.labels.allSatisfy(labels.contains) else { throw KanbanError.invalid("Issue #\(issue.number) 与请求的标签筛选不符；本批未提交。") }
        }
    }

    private func scopeDescription(_ scope: IssueScope, includeDefaultState: Bool) -> String {
        var items: [URLQueryItem] = []
        if includeDefaultState || !scope.states.isEmpty { items.append(URLQueryItem(name: "state", value: scope.state)) }
        if let assignee = scope.assignee { items.append(URLQueryItem(name: "assignee", value: assignee)) }
        if !scope.labels.isEmpty { items.append(URLQueryItem(name: "labels", value: scope.labels.joined(separator: ","))) }
        guard !items.isEmpty else { return "" }
        var components = URLComponents(); components.queryItems = items
        return components.string ?? ""
    }

    private static func validLogin(_ value: String) throws -> String {
        let value = value.lowercased()
        guard value == "@me" || value.range(of: #"^[a-z0-9](?:[a-z0-9-]{0,37}[a-z0-9])?$"#, options: .regularExpression) != nil else { throw KanbanError.invalid("GitHub 受理人必须是明确的用户名或 @me；本批未提交。") }
        return value
    }

    private static func matches(_ pattern: String, in text: String, capture: Int = 0) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).compactMap {
            guard capture < $0.numberOfRanges, let range = Range($0.range(at: capture), in: text) else { return nil }
            return String(text[range])
        }
    }

    private func githubData(_ endpoint: String) async throws -> Data {
        if let githubRequest { return try await githubRequest(endpoint) }
        let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
        if let gh {
            do { return Data(try command(gh, ["api", "--hostname", "github.com", endpoint], limit: 16_000_000).utf8) }
            catch { throw KanbanError.invalid("GitHub 读取失败。请检查 gh auth status、仓库访问权限及 API 额度；本批来源未提交。") }
        }
        guard let url = URL(string: "https://api.github.com/\(endpoint)") else { throw KanbanError.invalid("无效 GitHub 地址。") }
        var request = URLRequest(url: url); request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw KanbanError.invalid("GitHub 读取失败。私有仓库请先安装 gh 并在终端完成 gh auth login。")
        }
        guard data.count <= 16_000_000 else { throw KanbanError.invalid("GitHub 响应超过大小上限。") }
        return data
    }

    private func command(_ executable: String, _ arguments: [String], limit: Int) throws -> String {
        guard limit > 0 else { throw KanbanError.invalid("工作簿解压内容超过 64 MB。") }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["GH_PROMPT_DISABLED"] = "1"; environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: timeout)
        defer { timeout.cancel() }
        var data = Data()
        while let next = try pipe.fileHandleForReading.read(upToCount: 64 * 1024), !next.isEmpty {
            data.append(next)
            if data.count > limit { process.terminate(); process.waitUntilExit(); throw KanbanError.invalid("来源内容超过大小上限。") }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw KanbanError.invalid("无法读取来源文件或 API。") }
        guard let output = String(data: data, encoding: .utf8) else { throw KanbanError.invalid("来源文本编码不受支持。") }
        return output
    }
}

private struct GitHubIssue: Decodable {
    let number: Int; let title: String; let body: String?; let html_url: String; let pull_request: PullRequest?
    let state: String?; let assignees: [Assignee]?; let labels: [Label]?
    struct PullRequest: Decodable { let url: String? }
    struct Assignee: Decodable { let login: String }
    struct Label: Decodable { let name: String }
    func candidate(repository: String) -> ImportCandidate {
        ImportCandidate(sourceKey: "github:\(repository.lowercased())#\(number)", sourceURL: html_url, sourceDescription: "\(repository)#\(number)", title: title, description: body ?? "")
    }
}

private final class SpreadsheetXML: NSObject, XMLParserDelegate {
    enum Mode { case strings, worksheet }
    let mode: Mode; let sharedStrings: [String]
    var strings: [String] = [], rows: [[String]] = []
    private var text = "", shared = "", cellType = "", column = 0, row: [String] = []
    private var capture = false, error: Error?
    init(mode: Mode, sharedStrings: [String] = []) { self.mode = mode; self.sharedStrings = sharedStrings }
    func parse(_ data: Data) throws {
        let parser = XMLParser(data: data); parser.delegate = self; parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw error ?? parser.parserError ?? KanbanError.invalid("无法解析工作簿 XML。") }
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if name == "si" { shared = "" }
        if name == "row" { row = [] }
        if name == "c" {
            text = ""; cellType = attributes["t"] ?? ""
            let ref = attributes["r"] ?? "A"
            column = ref.uppercased().unicodeScalars.prefix { (65...90).contains($0.value) }.reduce(0) { $0 * 26 + Int($1.value) - 64 } - 1
            if column < 0 || column >= 1_024 { error = KanbanError.invalid("工作表超过 1,024 列。") ; parser.abortParsing() }
        }
        if name == "t" || name == "v" { capture = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capture { text += string; if mode == .strings { shared += string } }
        if text.utf8.count > 2_000_000 { error = KanbanError.invalid("单元格内容过大。") ; parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        if name == "t" || name == "v" { capture = false }
        if name == "si" { strings.append(shared); text = "" }
        if name == "c", mode == .worksheet {
            while row.count <= column { row.append("") }
            row[column] = cellType == "s" ? Int(text).flatMap { sharedStrings.indices.contains($0) ? sharedStrings[$0] : nil } ?? "" : text
        }
        if name == "row", mode == .worksheet {
            rows.append(row)
            if rows.count > 10_001 { error = KanbanError.invalid("工作表超过 10,000 项任务。") ; parser.abortParsing() }
        }
    }
}
