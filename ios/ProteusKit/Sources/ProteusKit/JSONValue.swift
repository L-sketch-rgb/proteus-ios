import Foundation

/// A minimal, Codable JSON tree. The protocol has several `unknown` payloads
/// (`tool_use.input`, permission input, event data) that are only displayed or
/// summarised by the client, so a typed model would add noise without value.
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        // Strings first: they are nearly every node in a transcript, and each
        // failed `try?` below builds a DecodingError.
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Int.self) {
            self = .int(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .double(value)
            return
        }
        if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
            return
        }
        if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported JSON value"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Builds a tree from `JSONSerialization` output. Orders of magnitude
    /// cheaper than the Codable path for a large history frame.
    public init(any value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            let kind = String(cString: number.objCType)
            if kind == "c" {
                self = .bool(number.boolValue)
            } else if kind == "d" || kind == "f" {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.intValue)
            }
        case let array as [Any]:
            self = .array(array.map { JSONValue(any: $0) })
        case let object as [String: Any]:
            self = .object(object.mapValues { JSONValue(any: $0) })
        default:
            self = .null
        }
    }

    /// The same tree with every string cut to `cap` characters.
    public func cappingStrings(_ cap: Int) -> JSONValue {
        switch self {
        case .string(let value):
            return value.utf8.count > cap ? .string(String(value.prefix(cap))) : self
        case .array(let value):
            return .array(value.map { $0.cappingStrings(cap) })
        case .object(let value):
            return .object(value.mapValues { $0.cappingStrings(cap) })
        default:
            return self
        }
    }

    // MARK: - Convenience

    public subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    public var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null, .array, .object: return nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int(value)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Re-decode this tree into a typed model (event payloads).
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        let data = try JSONEncoder.proteus.encode(self)
        return try JSONDecoder.proteus.decode(T.self, from: data)
    }

    /// Compact JSON text used for one-line tool summaries.
    public func compactJSONString() -> String {
        guard let data = try? JSONEncoder.proteus.encode(self),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
    }

    /// Plain-string rendering for a value that may or may not be a string.
    public var displayString: String {
        switch self {
        case .string(let value): return value
        case .null: return ""
        case .array, .object: return compactJSONString()
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        }
    }
}

public extension JSONEncoder {
    /// Shared encoder: compact keys are not required here (the hub accepts any
    /// key order) but deterministic output makes frame tests robust.
    static let proteus: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

public extension JSONDecoder {
    static let proteus = JSONDecoder()
}
