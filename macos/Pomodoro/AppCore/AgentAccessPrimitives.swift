import Foundation
import CryptoKit
import FlumenIPC

/// Runs approved agent writes one at a time, in the order they were approved.
///
/// A plain actor method that awaits the caller's work is re-entrant at that await,
/// so two approvals could interleave timer and database writes. Chaining each job
/// onto the previous one keeps them strictly serial.
public actor SerialMutationQueue {
    private var tail: Task<Void, Never>?

    public init() {}

    public func run<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let job = Task<T, Error> {
            await previous?.value
            return try await work()
        }
        tail = Task { _ = try? await job.value }
        return try await job.value
    }
}

/// Stable hash of an agent write, used to bind an idempotency key to the exact request it first carried.
public enum AgentRequestFingerprint {
    public static func make(operation: String, parameters: [String: JSONValue]) -> String {
        var canonical = parameters
        canonical.removeValue(forKey: "idempotencyKey")
        let payload: JSONValue = .object(["operation": .string(operation), "parameters": .object(canonical)])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(payload)) ?? Data(operation.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum AgentAccessErrors {
    public static func idempotencyConflict() -> IPCStructuredError {
        IPCStructuredError(
            code: "idempotency_conflict",
            message: "This idempotencyKey was already used for a different request. Use a new key for a new change."
        )
    }
}

/// Coalesces concurrent requests that share an idempotency key, so one key opens one proposal.
public final class InFlightRequests: @unchecked Sendable {
    private struct Entry {
        let fingerprint: String
        var waiters: [CheckedContinuation<JSONValue?, Error>]
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public init() {}

    /// Runs `work` once per key. Later callers with the same key and fingerprint receive the same
    /// result; callers with the same key and a different fingerprint get `idempotency_conflict`.
    public func run(
        key: String,
        fingerprint: String,
        _ work: () async throws -> JSONValue
    ) async throws -> JSONValue {
        let shared: JSONValue? = try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if entries[key] != nil {
                guard entries[key]!.fingerprint == fingerprint else {
                    lock.unlock()
                    continuation.resume(throwing: AgentAccessErrors.idempotencyConflict())
                    return
                }
                entries[key]!.waiters.append(continuation)
                lock.unlock()
            } else {
                entries[key] = Entry(fingerprint: fingerprint, waiters: [])
                lock.unlock()
                continuation.resume(returning: nil)
            }
        }
        if let shared { return shared }

        do {
            let result = try await work()
            finish(key: key, result: .success(result))
            return result
        } catch {
            finish(key: key, result: .failure(error))
            throw error
        }
    }

    private func finish(key: String, result: Result<JSONValue, Error>) {
        lock.lock()
        let waiters = entries.removeValue(forKey: key)?.waiters ?? []
        lock.unlock()
        for waiter in waiters {
            switch result {
            case .success(let value): waiter.resume(returning: value)
            case .failure(let error): waiter.resume(throwing: error)
            }
        }
    }
}

/// Tracks agent proposals that are waiting for a person in Flumen.
///
/// Registration is separate from waiting so a decision that arrives before the caller
/// starts waiting (a very fast click, a disconnect, Agent Access turning off) is not lost.
public final class ProposalRegistry: @unchecked Sendable {
    public struct Pending: @unchecked Sendable {
        public let requestId: String
        public let createdAt: Date
        public let expiresAt: Date
        public let summary: [String: Any]
    }

    private struct Entry {
        let pending: Pending
        var decision: Result<Void, IPCStructuredError>?
        var waiter: CheckedContinuation<Void, Error>?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public init() {}

    public func register(requestId: String, summary: [String: Any], window: TimeInterval) {
        let now = Date()
        lock.lock()
        entries[requestId] = Entry(
            pending: Pending(requestId: requestId, createdAt: now, expiresAt: now.addingTimeInterval(window), summary: summary),
            decision: nil,
            waiter: nil
        )
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + window) { [weak self] in
            _ = self?.resolve(requestId: requestId, approved: false, reason: "expired")
        }
    }

    /// Returns when the person approves. Throws `user_declined`, `proposal_expired`, or the cancel error.
    public func waitForDecision(requestId: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            guard var entry = entries[requestId] else {
                lock.unlock()
                continuation.resume(throwing: IPCStructuredError(code: "proposal_unavailable", message: "The proposal is no longer pending."))
                return
            }
            if let decision = entry.decision {
                entries.removeValue(forKey: requestId)
                lock.unlock()
                continuation.resume(with: decision.mapError { $0 as Error })
                return
            }
            entry.waiter = continuation
            entries[requestId] = entry
            lock.unlock()
        }
    }

    /// Records the person's choice. Returns false when the proposal is no longer pending.
    @discardableResult
    public func resolve(requestId: String, approved: Bool, reason: String?) -> Bool {
        if approved { return decide(requestId: requestId, decision: .success(())) }
        let expired = reason == "expired"
        return decide(requestId: requestId, decision: .failure(IPCStructuredError(
            code: expired ? "proposal_expired" : "user_declined",
            message: expired
                ? "The Flumen confirmation expired before approval."
                : "The user declined the proposal in Flumen."
        )))
    }

    /// Withdraws one undecided proposal. Returns false when it was already decided or unknown.
    @discardableResult
    public func cancel(requestId: String, error: IPCStructuredError) -> Bool {
        decide(requestId: requestId, decision: .failure(error))
    }

    /// Withdraws every undecided proposal and returns their request IDs.
    @discardableResult
    public func cancelAll(error: IPCStructuredError) -> [String] {
        lock.lock()
        let ids = entries.filter { $0.value.decision == nil }.map(\.key)
        lock.unlock()
        return ids.filter { decide(requestId: $0, decision: .failure(error)) }
    }

    public func isPending(_ requestId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[requestId].map { $0.decision == nil } ?? false
    }

    /// Undecided proposals, oldest first.
    public func pending() -> [Pending] {
        lock.lock()
        defer { lock.unlock() }
        return entries.values
            .filter { $0.decision == nil }
            .map(\.pending)
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func decide(requestId: String, decision: Result<Void, IPCStructuredError>) -> Bool {
        lock.lock()
        guard var entry = entries[requestId], entry.decision == nil else {
            lock.unlock()
            return false
        }
        if let waiter = entry.waiter {
            entries.removeValue(forKey: requestId)
            lock.unlock()
            waiter.resume(with: decision.mapError { $0 as Error })
        } else {
            entry.decision = decision
            entries[requestId] = entry
            lock.unlock()
        }
        return true
    }
}
