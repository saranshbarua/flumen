import Foundation
import Darwin

public final class UnixSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (IPCRequest) async -> IPCResponse
    /// Called with the request ID when a client closes its socket before the response is written.
    public typealias DisconnectHandler = @Sendable (String) -> Void

    public let path: String
    private let handler: Handler
    private let onClientDisconnect: DisconnectHandler?
    private let acceptQueue = DispatchQueue(label: "com.flumen.ipc.accept", qos: .userInitiated)
    private let connectionQueue = DispatchQueue(label: "com.flumen.ipc.connections", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var clients: Set<Int32> = []
    private var running = false

    public init(path: String, onClientDisconnect: DisconnectHandler? = nil, handler: @escaping Handler) {
        self.path = path
        self.onClientDisconnect = onClientDisconnect
        self.handler = handler
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }

        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        unlink(path)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw socketError("create listener") }
        do {
            try configure(fd)
            var address = try makeAddress(path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw socketError("bind") }
            guard Darwin.listen(fd, 8) == 0 else { throw socketError("listen") }
            guard chmod(path, 0o600) == 0 else { throw socketError("secure socket") }
        } catch {
            Darwin.close(fd)
            unlink(path)
            throw error
        }

        listener = fd
        running = true
        acceptQueue.async { [weak self] in self?.acceptLoop(fd) }
    }

    public func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        let listener = self.listener
        self.listener = -1
        let clients = self.clients
        lock.unlock()

        if listener >= 0 {
            shutdown(listener, SHUT_RDWR)
            Darwin.close(listener)
        }
        // Only shut clients down here; each serve loop owns closing its own descriptor.
        for client in clients {
            shutdown(client, SHUT_RDWR)
        }
        unlink(path)
    }

    /// Ends every in-flight client connection while the listener keeps accepting new ones.
    public func disconnectClients() {
        lock.lock()
        let clients = self.clients
        lock.unlock()
        for client in clients {
            shutdown(client, SHUT_RDWR)
        }
    }

    deinit { stop() }

    private func acceptLoop(_ fd: Int32) {
        while isRunning {
            let client = Darwin.accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                if isRunning { usleep(20_000) }
                continue
            }

            var peerUID: uid_t = 0
            var peerGID: gid_t = 0
            guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == geteuid() else {
                Darwin.close(client)
                continue
            }
            do {
                try configure(client)
            } catch {
                Darwin.close(client)
                continue
            }
            lock.lock()
            clients.insert(client)
            lock.unlock()
            connectionQueue.async { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        defer {
            lock.lock()
            clients.remove(fd)
            lock.unlock()
            Darwin.close(fd)
        }

        var buffer = Data()
        while isRunning {
            let line: Data
            do {
                guard let next = try readLine(fd: fd, buffer: &buffer) else { return }
                line = next
            } catch let error as IPCStructuredError where error.code == "message_too_large" {
                try? writeAll(IPCCodec.encode(IPCResponse(requestId: "unknown", error: error)), fd: fd)
                return
            } catch {
                logIPC("read failed: \(error.localizedDescription)")
                return
            }

            let request: IPCRequest
            do {
                request = try IPCCodec.decode(IPCRequest.self, from: line)
            } catch {
                let response = IPCResponse(
                    requestId: "unknown",
                    error: IPCStructuredError(code: "invalid_request", message: "Malformed IPC request: \(error.localizedDescription)")
                )
                guard send(response, fd: fd) else { return }
                continue
            }
            guard request.version == FlumenIPC.protocolVersion else {
                let response = IPCResponse(
                    requestId: request.requestId,
                    error: IPCStructuredError(
                        code: "unsupported_version",
                        message: "Unsupported IPC version \(request.version). Expected \(FlumenIPC.protocolVersion)."
                    )
                )
                guard send(response, fd: fd) else { return }
                continue
            }

            let semaphore = DispatchSemaphore(value: 0)
            let box = ResponseBox()
            let handler = self.handler
            Task {
                let value = await handler(request)
                box.value = value
                semaphore.signal()
            }

            // Write requests can wait minutes for a person. Watch the peer so a client that gives up
            // (timeout, cancellation, helper exit) withdraws its pending work instead of leaving it live.
            var peerGone = false
            while semaphore.wait(timeout: .now() + .milliseconds(250)) == .timedOut {
                if !peerGone, peerClosed(fd) {
                    peerGone = true
                    onClientDisconnect?(request.requestId)
                }
            }
            if peerGone { return }

            guard let response = box.value, send(response, fd: fd) else { return }
        }
    }

    private func send(_ response: IPCResponse, fd: Int32) -> Bool {
        do {
            try writeAll(IPCCodec.encode(response), fd: fd)
            return true
        } catch let error as IPCStructuredError where error.code == "message_too_large" {
            let fallback = IPCResponse(requestId: response.requestId, error: error)
            return (try? writeAll(IPCCodec.encode(fallback), fd: fd)) != nil
        } catch {
            logIPC("write failed for \(response.requestId): \(error.localizedDescription)")
            return false
        }
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }
}

public final class UnixSocketClient: @unchecked Sendable {
    public let path: String
    public let metadata: IPCClientMetadata
    public let timeout: TimeInterval

    public init(path: String, metadata: IPCClientMetadata, timeout: TimeInterval = FlumenIPC.defaultTimeout) {
        self.path = path
        self.metadata = metadata
        self.timeout = timeout
    }

    public func send(
        operation: String,
        parameters: [String: JSONValue] = [:],
        idempotencyKey: String? = nil
    ) async throws -> JSONValue {
        let request = IPCRequest(
            idempotencyKey: idempotencyKey,
            client: metadata,
            operation: operation,
            parameters: parameters
        )
        return try await send(request)
    }

    /// Sends one request and waits for its response.
    ///
    /// - Parameters:
    ///   - timeout: Read/write timeout for this request. Defaults to the client timeout.
    ///   - retryAfterSend: When false, a failure after the request reached Flumen is not retried,
    ///     so a write cannot be proposed twice. Connection failures are always retried once.
    public func send(
        _ request: IPCRequest,
        timeout: TimeInterval? = nil,
        retryAfterSend: Bool = true
    ) async throws -> JSONValue {
        let effectiveTimeout = timeout ?? self.timeout
        let cancellation = SocketCancellation()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { [path] in
                var lastError: Error?
                for attempt in 0..<2 {
                    if attempt > 0 { try await Task.sleep(nanoseconds: 100_000_000) }
                    if cancellation.isCancelled { throw CancellationError() }
                    var requestSent = false
                    do {
                        return try Self.sendOnce(
                            request,
                            path: path,
                            timeout: effectiveTimeout,
                            cancellation: cancellation,
                            requestSent: &requestSent
                        )
                    } catch {
                        if cancellation.isCancelled { throw CancellationError() }
                        lastError = error
                        if let structured = error as? IPCStructuredError, structured.code == "ipc_timeout" { break }
                        if requestSent && !retryAfterSend { break }
                    }
                }
                if let error = lastError as? IPCStructuredError { throw error }
                throw IPCStructuredError(
                    code: "app_unavailable",
                    message: "Flumen is not available. Open Flumen on this Mac, turn on Agent Access, and try again.",
                    details: ["socketPath": .string(path)],
                    retryable: true
                )
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func sendOnce(
        _ request: IPCRequest,
        path: String,
        timeout: TimeInterval,
        cancellation: SocketCancellation,
        requestSent: inout Bool
    ) throws -> JSONValue {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw socketError("create client") }
        guard cancellation.attach(fd) else {
            Darwin.close(fd)
            throw CancellationError()
        }
        defer {
            cancellation.detach()
            Darwin.close(fd)
        }
        try configure(fd, timeout: timeout)
        var address = try makeAddress(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw socketError("connect") }

        requestSent = true
        try writeAll(IPCCodec.encode(request), fd: fd)
        var buffer = Data()
        guard let line = try readLine(fd: fd, buffer: &buffer) else {
            throw IPCStructuredError(code: "connection_closed", message: "Flumen closed the IPC connection.", retryable: true)
        }
        let response = try IPCCodec.decode(IPCResponse.self, from: line)
        guard response.requestId == request.requestId else {
            throw IPCStructuredError(code: "response_mismatch", message: "Flumen returned a mismatched response.")
        }
        if let error = response.error { throw error }
        return response.result ?? .null
    }
}

/// Lets an async cancellation close a socket that a detached task is blocked on.
private final class SocketCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func attach(_ fd: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        self.fd = fd
        return true
    }

    func detach() {
        lock.lock()
        fd = -1
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let fd = self.fd
        lock.unlock()
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
    }
}

private final class ResponseBox: @unchecked Sendable {
    var value: IPCResponse?
}

private func peerClosed(_ fd: Int32) -> Bool {
    var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let ready = poll(&descriptor, 1, 0)
    guard ready > 0 else { return ready < 0 && errno != EINTR }
    if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return true }
    guard descriptor.revents & Int16(POLLIN) != 0 else { return false }
    var byte: UInt8 = 0
    let peeked = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
    if peeked == 0 { return true }
    if peeked < 0 { return errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR }
    return false
}

private func makeAddress(_ path: String) throws -> sockaddr_un {
    guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
        throw IPCStructuredError(code: "socket_path_too_long", message: "Unix socket path is too long.")
    }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let maxLength = MemoryLayout.size(ofValue: address.sun_path)
    path.withCString { source in
        withUnsafeMutablePointer(to: &address) { addressPointer in
            let sunPath = UnsafeMutableRawPointer(addressPointer)
                .advanced(by: MemoryLayout<sockaddr_un>.offset(of: \.sun_path)!)
                .assumingMemoryBound(to: CChar.self)
            _ = strlcpy(sunPath, source, maxLength)
        }
    }
    return address
}

private func configure(_ fd: Int32, timeout: TimeInterval? = nil) throws {
    var noSigPipe: Int32 = 1
    guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
        throw socketError("configure socket")
    }
    if let timeout {
        var value = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - floor(timeout)) * 1_000_000)
        )
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw socketError("configure socket timeout")
        }
    }
}

private func readLine(fd: Int32, buffer: inout Data) throws -> Data? {
    while true {
        if let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[...newline])
            buffer.removeSubrange(...newline)
            return line
        }
        guard buffer.count < FlumenIPC.maximumMessageBytes else {
            throw IPCStructuredError(code: "message_too_large", message: "IPC message exceeds the 1 MiB limit.")
        }
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.recv(fd, &chunk, chunk.count, 0)
        if count == 0 { return nil }
        if count < 0 {
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                throw IPCStructuredError(
                    code: "ipc_timeout",
                    message: "Timed out waiting for Flumen to respond.",
                    retryable: true
                )
            }
            throw socketError("read")
        }
        buffer.append(contentsOf: chunk.prefix(count))
    }
}

private func writeAll(_ data: Data, fd: Int32) throws {
    try data.withUnsafeBytes { bytes in
        guard var base = bytes.baseAddress else { return }
        var remaining = bytes.count
        while remaining > 0 {
            let sent = Darwin.send(fd, base, remaining, 0)
            if sent < 0 {
                if errno == EINTR { continue }
                throw socketError("write")
            }
            remaining -= sent
            base = base.advanced(by: sent)
        }
    }
}

private func socketError(_ action: String) -> IPCStructuredError {
    IPCStructuredError(
        code: "ipc_failure",
        message: "Unable to \(action): \(String(cString: strerror(errno))).",
        retryable: true
    )
}

private func logIPC(_ message: String) {
    fputs("FlumenIPC: \(message)\n", stderr)
}
