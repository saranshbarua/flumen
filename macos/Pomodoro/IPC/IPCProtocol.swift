import Foundation
import Darwin

public enum FlumenIPC {
    public static let protocolVersion = 1
    public static let maximumMessageBytes = 1_048_576
    public static let defaultTimeout: TimeInterval = 15
    /// How long a person has to approve or decline an agent proposal in Flumen.
    public static let confirmationWindow: TimeInterval = 120
    /// Write requests block on the confirmation, so the socket must outlive the confirmation window.
    public static let mutationTimeout: TimeInterval = confirmationWindow + 15
}

/// Single source of truth for which IPC operations read data and which propose changes.
public enum AgentOperationCatalog {
    /// Session-level checks that expose no focus data and work even when Read Focus Data is off.
    public static let session: Set<String> = ["ping", "get_server_status"]

    public static let reads: Set<String> = [
        "get_focus_status", "get_today_summary", "get_active_task",
        "list_tasks", "list_projects", "query_focus_activity", "get_activity",
        "get_focus_summary", "get_estimation_context"
    ]

    public static let writes: Set<String> = [
        "log_time", "create_task", "update_task", "set_active_task",
        "begin_focus", "resume_focus", "pause_focus", "finish_focus",
        "complete_task", "reopen_task", "correct_time_entry"
    ]

    public static func isWrite(_ operation: String) -> Bool { writes.contains(operation) }
}

public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var intValue: Int? {
        guard case .number(let value) = self, value.rounded() == value else { return nil }
        return Int(value)
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    public static func from(any value: Any) -> JSONValue {
        switch value {
        case is NSNull: return .null
        case let value as Bool: return .bool(value)
        case let value as NSNumber: return .number(value.doubleValue)
        case let value as String: return .string(value)
        case let value as [Any]: return .array(value.map(JSONValue.from))
        case let value as [String: Any]:
            return .object(value.mapValues(JSONValue.from))
        default: return .string(String(describing: value))
        }
    }

    public var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let value): return value.map(\.anyValue)
        case .object(let value): return value.mapValues(\.anyValue)
        }
    }
}

public struct IPCClientMetadata: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let version: String?
    public let processID: Int32?

    public init(id: String, name: String, version: String? = nil, processID: Int32? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.processID = processID
    }
}

public struct IPCRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let requestId: String
    public let idempotencyKey: String?
    public let client: IPCClientMetadata
    public let operation: String
    public let parameters: [String: JSONValue]

    public init(
        requestId: String = UUID().uuidString,
        idempotencyKey: String? = nil,
        client: IPCClientMetadata,
        operation: String,
        parameters: [String: JSONValue] = [:]
    ) {
        version = FlumenIPC.protocolVersion
        self.requestId = requestId
        self.idempotencyKey = idempotencyKey
        self.client = client
        self.operation = operation
        self.parameters = parameters
    }
}

public struct IPCStructuredError: Codable, Error, Equatable, Sendable, LocalizedError {
    public let code: String
    public let message: String
    public let details: [String: JSONValue]?
    public let retryable: Bool

    public init(code: String, message: String, details: [String: JSONValue]? = nil, retryable: Bool = false) {
        self.code = code
        self.message = message
        self.details = details
        self.retryable = retryable
    }

    public var errorDescription: String? { message }
}

public struct IPCResponse: Codable, Equatable, Sendable {
    public let version: Int
    public let requestId: String
    public let result: JSONValue?
    public let error: IPCStructuredError?

    public init(requestId: String, result: JSONValue) {
        version = FlumenIPC.protocolVersion
        self.requestId = requestId
        self.result = result
        error = nil
    }

    public init(requestId: String, error: IPCStructuredError) {
        version = FlumenIPC.protocolVersion
        self.requestId = requestId
        result = nil
        self.error = error
    }
}

public enum IPCCodec {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    public static func encode<T: Encodable>(_ message: T) throws -> Data {
        var data = try encoder.encode(message)
        guard data.count <= FlumenIPC.maximumMessageBytes else {
            throw IPCStructuredError(code: "message_too_large", message: "IPC message exceeds the 1 MiB limit.")
        }
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        guard line.count <= FlumenIPC.maximumMessageBytes else {
            throw IPCStructuredError(code: "message_too_large", message: "IPC message exceeds the 1 MiB limit.")
        }
        let payload = line.last == 0x0A ? line.dropLast() : line[...]
        return try decoder.decode(type, from: Data(payload))
    }
}

public enum FlumenSocketPath {
    public static func path(bundleIdentifier: String) -> String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("agent.sock")
            .path
    }

    public static func current(bundleIdentifier: String? = nil) -> String {
        if let override = ProcessInfo.processInfo.environment["FLUMEN_SOCKET_PATH"], !override.isEmpty {
            return override
        }
        let identifier = bundleIdentifier
            ?? ProcessInfo.processInfo.environment["FLUMEN_BUNDLE_ID"]
            ?? Bundle.main.bundleIdentifier
            ?? "com.saranshbarua.flumen"
        return path(bundleIdentifier: identifier)
    }
}
