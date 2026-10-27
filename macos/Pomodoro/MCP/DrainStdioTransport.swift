import Foundation
import Logging
import MCP

/// Stdio transport that keeps the process alive until every request has a response.
///
/// The MCP SDK handles each request in a detached task and ends the session when stdin
/// closes. A client that writes `initialize` and `tools/list` and then closes the pipe
/// would otherwise exit before those tasks write JSON, which clients report as an
/// immediate exit with no handshake.
actor DrainStdioTransport: Transport {
    nonisolated let logger: Logger
    private let inner: StdioTransport
    private var outstanding = 0

    init(logger: Logger) {
        self.logger = logger
        self.inner = StdioTransport(logger: logger)
    }

    func connect() async throws {
        try await inner.connect()
    }

    func disconnect() async {
        await inner.disconnect()
    }

    func send(_ data: Data) async throws {
        try await inner.send(data)
        if isResponse(data) {
            outstanding = max(0, outstanding - 1)
        }
    }

    func receive() -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                let stream = await self.inner.receive()
                do {
                    for try await message in stream {
                        if expectsResponse(message) {
                            self.expectResponse()
                        }
                        continuation.yield(compatibleInbound(message))
                    }
                } catch {
                    continuation.finish(throwing: error)
                    return
                }

                let deadline = Date().addingTimeInterval(20)
                while !self.isDrained, Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                continuation.finish()
            }
        }
    }

    private func expectResponse() {
        outstanding += 1
    }

    private var isDrained: Bool {
        outstanding == 0
    }
}

/// The Swift MCP SDK decodes `capabilities.experimental` as `[String: String]` and
/// `icons.sizes` as `[String]`. Codex sends object-valued experimental entries and
/// can send `sizes` as one string. Either mismatch becomes JSON-RPC -32603,
/// "The data couldn’t be read because it isn’t in the correct format.", and Codex
/// drops the server before the initialize hook runs. Drop the unused experimental
/// map and wrap a single size so the rest of the handshake still decodes.
func compatibleInbound(_ data: Data) -> Data {
    guard var object = jsonObject(data),
          object["method"] as? String == "initialize",
          var params = object["params"] as? [String: Any] else {
        return data
    }

    var rewroteExperimental = false
    var rewroteIconSizes = false
    if var capabilities = params["capabilities"] as? [String: Any],
       let experimental = capabilities["experimental"] as? [String: Any],
       experimental.values.contains(where: { !($0 is String) }) {
        capabilities.removeValue(forKey: "experimental")
        params["capabilities"] = capabilities
        rewroteExperimental = true
    }
    if var clientInfo = params["clientInfo"] as? [String: Any],
       var icons = clientInfo["icons"] as? [[String: Any]] {
        for index in icons.indices {
            if let size = icons[index]["sizes"] as? String {
                icons[index]["sizes"] = [size]
                rewroteIconSizes = true
            }
        }
        if rewroteIconSizes {
            clientInfo["icons"] = icons
            params["clientInfo"] = clientInfo
        }
    }
    guard rewroteExperimental || rewroteIconSizes else { return data }
    object["params"] = params
    return (try? JSONSerialization.data(withJSONObject: object)) ?? data
}

/// A JSON-RPC request has both an id and a method. Notifications have a method only.
private func expectsResponse(_ data: Data) -> Bool {
    guard let object = jsonObject(data) else { return false }
    return object["id"] != nil && object["method"] != nil
}

/// A JSON-RPC response has an id and either a result or an error, and no method.
private func isResponse(_ data: Data) -> Bool {
    guard let object = jsonObject(data) else { return false }
    return object["id"] != nil && object["method"] == nil && (object["result"] != nil || object["error"] != nil)
}

private func jsonObject(_ data: Data) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}
