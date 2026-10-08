import Foundation
import CryptoKit

public enum TaskImport {
    /// Explicit intent is checked only in the human message, never attachment contents.
    public static func hasImportIntent(_ message: String) -> Bool {
        TaskImportRequestResolver.hasExplicitImportIntent(message)
    }

    /// RFC 4180-style quoted fields, CRLF, BOM, embedded delimiters and newlines.
    public static func parseDelimited(_ text: String, delimiter: Character = ",") throws -> [[String]] {
        // Swift treats CRLF as one extended grapheme; normalize it before Character iteration.
        let withoutBOM = text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text
        let input = withoutBOM.replacingOccurrences(of: "\r\n", with: "\n")
        let characters = Array(input); var rows: [[String]] = []; var row: [String] = []; var field = ""; var quoted = false; var afterQuote = false; var index = 0
        while index < characters.count {
            let character = characters[index]
            if quoted {
                if character == "\"" {
                    if index + 1 < characters.count && characters[index + 1] == "\"" { field.append("\""); index += 1 }
                    else { quoted = false; afterQuote = true }
                } else { field.append(character) }
            } else if character == delimiter {
                row.append(field); field = ""; afterQuote = false
            } else if character == "\n" || character == "\r" {
                if character == "\r", index + 1 < characters.count, characters[index + 1] == "\n" { index += 1 }
                row.append(field); rows.append(row); row = []; field = ""; afterQuote = false
            } else if character == "\"" {
                guard field.isEmpty && !afterQuote else { throw KanbanError.invalid("CSV 引号格式损坏。") }; quoted = true
            } else {
                guard !afterQuote || character.isWhitespace else { throw KanbanError.invalid("CSV 闭合引号后有无效字符。") }
                if !afterQuote { field.append(character) }
            }
            index += 1
        }
        guard !quoted else { throw KanbanError.invalid("CSV 包含未闭合的引号。") }
        if !field.isEmpty || !row.isEmpty || afterQuote { row.append(field); rows.append(row) }
        return rows
    }
    public static func sourceDigest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
