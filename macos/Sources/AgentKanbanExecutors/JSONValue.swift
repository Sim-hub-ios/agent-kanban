import Foundation

/// A Sendable JSON representation. Protocol payloads never retain authentication headers.
public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSONValue { object?[key] ?? .null }
    public var object: [String: JSONValue]? { if case .object(let v) = self { v } else { nil } }
    public var array: [JSONValue] { if case .array(let v) = self { v } else { [] } }
    public var string: String? { if case .string(let v) = self { v } else { nil } }
    public var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    public var idString: String? {
        switch self { case .string(let v): v; case .number(let v): String(Int(v)); default: nil }
    }
}

public enum ExecutorError: Error, LocalizedError, Sendable, Equatable {
    case unavailable(String), unsupported(String), invalidRequest(String), protocolError(String), timeout(String), processExited(Int32)
    public var errorDescription: String? {
        switch self {
        case .unavailable(let v), .unsupported(let v), .invalidRequest(let v), .protocolError(let v), .timeout(let v): v
        case .processExited(let code): "执行器意外退出（\(code)）；停止状态需要核实。"
        }
    }
}

/// Bounded decoder rejects an oversized frame instead of retaining unbounded tool output.
struct JSONLineDecoder: Sendable {
    private var buffer = Data()
    let maximumFrameSize: Int
    init(maximumFrameSize: Int = 8 * 1_024 * 1_024) { self.maximumFrameSize = maximumFrameSize }
    mutating func append(_ data: Data) throws -> [JSONValue] {
        buffer.append(data)
        var result: [JSONValue] = []
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard line.count <= maximumFrameSize else { throw ExecutorError.protocolError("执行器事件超出大小上限") }
            if !line.isEmpty { result.append(try JSONDecoder().decode(JSONValue.self, from: line)) }
        }
        guard buffer.count <= maximumFrameSize else { throw ExecutorError.protocolError("执行器事件缺少换行或超出大小上限") }
        return result
    }
}
