import XCTest
import GRDB
@testable import FlumenCore
import FlumenIPC

final class ProposalRegistryTests: XCTestCase {
    func testApprovalReturnsNormally() async throws {
        let registry = ProposalRegistry()
        registry.register(requestId: "p1", summary: [:], window: 5)
        Task { registry.resolve(requestId: "p1", approved: true, reason: nil) }
        try await registry.waitForDecision(requestId: "p1")
        XCTAssertFalse(registry.isPending("p1"))
    }

    func testDeclineThrowsUserDeclined() async {
        let registry = ProposalRegistry()
        registry.register(requestId: "p1", summary: [:], window: 5)
        XCTAssertTrue(registry.resolve(requestId: "p1", approved: false, reason: "user_declined"))
        await XCTAssertThrowsCode("user_declined") { try await registry.waitForDecision(requestId: "p1") }
    }

    func testExpiryThrowsProposalExpired() async {
        let registry = ProposalRegistry()
        registry.register(requestId: "p1", summary: [:], window: 0.05)
        await XCTAssertThrowsCode("proposal_expired") { try await registry.waitForDecision(requestId: "p1") }
    }

    func testDecisionBeforeWaitIsNotLost() async throws {
        let registry = ProposalRegistry()
        registry.register(requestId: "p1", summary: [:], window: 5)
        registry.resolve(requestId: "p1", approved: true, reason: nil)
        try await registry.waitForDecision(requestId: "p1")
    }

    func testCancelOnlyAffectsUndecidedProposals() async throws {
        let registry = ProposalRegistry()
        registry.register(requestId: "p1", summary: [:], window: 5)
        registry.resolve(requestId: "p1", approved: true, reason: nil)
        XCTAssertFalse(registry.cancel(requestId: "p1", error: IPCStructuredError(code: "client_disconnected", message: "gone")))
        try await registry.waitForDecision(requestId: "p1")

        registry.register(requestId: "p2", summary: [:], window: 5)
        XCTAssertTrue(registry.cancel(requestId: "p2", error: IPCStructuredError(code: "client_disconnected", message: "gone")))
        await XCTAssertThrowsCode("client_disconnected") { try await registry.waitForDecision(requestId: "p2") }
    }

    func testResolveUnknownProposalReturnsFalse() {
        let registry = ProposalRegistry()
        XCTAssertFalse(registry.resolve(requestId: "missing", approved: true, reason: nil))
    }

    func testPendingIsOldestFirstAndCancelAllClearsIt() async throws {
        let registry = ProposalRegistry()
        registry.register(requestId: "a", summary: ["n": 1], window: 5)
        try await Task.sleep(nanoseconds: 10_000_000)
        registry.register(requestId: "b", summary: ["n": 2], window: 5)
        XCTAssertEqual(registry.pending().map(\.requestId), ["a", "b"])
        let cancelled = registry.cancelAll(error: IPCStructuredError(code: "agent_access_disabled", message: "off"))
        XCTAssertEqual(Set(cancelled), ["a", "b"])
        XCTAssertTrue(registry.pending().isEmpty)
        await XCTAssertThrowsCode("agent_access_disabled") { try await registry.waitForDecision(requestId: "a") }
    }
}

final class SerialMutationQueueTests: XCTestCase {
    func testJobsNeverOverlap() async throws {
        let queue = SerialMutationQueue()
        let tracker = OverlapTracker()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    _ = try await queue.run {
                        await tracker.enter()
                        try await Task.sleep(nanoseconds: 5_000_000)
                        await tracker.exit()
                        return 0
                    }
                }
            }
            try await group.waitForAll()
        }
        let maxConcurrent = await tracker.maxConcurrent
        XCTAssertEqual(maxConcurrent, 1)
    }

    func testFailureDoesNotBlockLaterJobs() async throws {
        let queue = SerialMutationQueue()
        do {
            _ = try await queue.run { () async throws -> Int in throw IPCStructuredError(code: "boom", message: "boom") }
            XCTFail("Expected failure")
        } catch {}
        let value = try await queue.run { 42 }
        XCTAssertEqual(value, 42)
    }
}

final class InFlightRequestsTests: XCTestCase {
    func testConcurrentSameKeyRunsWorkOnce() async throws {
        let inFlight = InFlightRequests()
        let counter = Counter()
        let gate = Gate()
        async let first = inFlight.run(key: "k", fingerprint: "f") {
            await counter.increment()
            await gate.wait()
            return JSONValue.string("done")
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        async let second = inFlight.run(key: "k", fingerprint: "f") {
            await counter.increment()
            return JSONValue.string("second")
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        await gate.open()
        let results = try await [first, second]
        XCTAssertEqual(results, [.string("done"), .string("done")])
        let count = await counter.value
        XCTAssertEqual(count, 1)
    }

    func testSameKeyDifferentFingerprintConflicts() async throws {
        let inFlight = InFlightRequests()
        let gate = Gate()
        async let first = inFlight.run(key: "k", fingerprint: "f1") {
            await gate.wait()
            return JSONValue.null
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        await XCTAssertThrowsCode("idempotency_conflict") {
            _ = try await inFlight.run(key: "k", fingerprint: "f2") { .null }
        }
        await gate.open()
        _ = try await first
    }
}

final class AgentRequestFingerprintTests: XCTestCase {
    func testIgnoresKeyOrderAndIdempotencyKey() {
        let a = AgentRequestFingerprint.make(operation: "log_time", parameters: [
            "title": .string("Standup"), "durationSeconds": .number(900), "idempotencyKey": .string("one")
        ])
        let b = AgentRequestFingerprint.make(operation: "log_time", parameters: [
            "durationSeconds": .number(900), "idempotencyKey": .string("two"), "title": .string("Standup")
        ])
        XCTAssertEqual(a, b)
    }

    func testDiffersWhenParametersDiffer() {
        let a = AgentRequestFingerprint.make(operation: "log_time", parameters: ["durationSeconds": .number(900)])
        let b = AgentRequestFingerprint.make(operation: "log_time", parameters: ["durationSeconds": .number(1800)])
        XCTAssertNotEqual(a, b)
    }
}

final class AgentRepositoryTests: XCTestCase {
    private var repository: AppRepository!

    override func setUpWithError() throws {
        let path = NSTemporaryDirectory().appending("flumen-agent-test-\(UUID().uuidString).sqlite")
        let pool = try DatabasePool(path: path)
        repository = AppRepository(database: try DatabaseManager(dbPool: pool))
    }

    func testCachedOperationRejectsDifferentParameters() throws {
        try repository.storeOperation(client: "cursor", key: "k1", operation: "create_task", fingerprint: "f1", result: .object(["id": .string("t1")]))
        XCTAssertEqual(
            try repository.cachedOperation(client: "cursor", key: "k1", operation: "create_task", fingerprint: "f1"),
            .object(["id": .string("t1")])
        )
        XCTAssertThrowsError(try repository.cachedOperation(client: "cursor", key: "k1", operation: "create_task", fingerprint: "f2")) { error in
            XCTAssertEqual((error as? IPCStructuredError)?.code, "idempotency_conflict")
        }
        XCTAssertNil(try repository.cachedOperation(client: "cursor", key: "other", operation: "create_task", fingerprint: "f1"))
    }

    func testCompleteTaskRejectsStaleRevision() throws {
        try repository.addTask(id: "t1", title: "Ship", tag: nil, projectId: nil, estimatedPomos: 1)
        _ = try repository.updateTask(id: "t1", title: "Ship v2", tag: nil, projectId: nil, estimatedPomos: 1, expectedRevision: 1)
        XCTAssertThrowsError(try repository.completeTask(id: "t1", expectedRevision: 1)) { error in
            XCTAssertEqual((error as? IPCStructuredError)?.code, "revision_conflict")
        }
        let completed = try repository.completeTask(id: "t1", expectedRevision: 2)
        XCTAssertEqual(completed["isCompleted"] as? Bool, true)
    }

    func testReopenTaskRestoresCompletedTask() throws {
        try repository.addTask(id: "t1", title: "Ship", tag: nil, projectId: nil, estimatedPomos: 1)
        XCTAssertThrowsError(try repository.reopenTask(id: "t1", expectedRevision: 1)) { error in
            XCTAssertEqual((error as? IPCStructuredError)?.code, "validation_error")
        }
        let completed = try repository.completeTask(id: "t1", expectedRevision: 1)
        let revision = try XCTUnwrap(completed["revision"] as? Int)
        XCTAssertThrowsError(try repository.reopenTask(id: "t1", expectedRevision: revision - 1)) { error in
            XCTAssertEqual((error as? IPCStructuredError)?.code, "revision_conflict")
        }
        let reopened = try repository.reopenTask(id: "t1", expectedRevision: revision)
        XCTAssertEqual(reopened["isCompleted"] as? Bool, false)
        XCTAssertEqual(reopened["status"] as? Int, 0)
    }

    func testCorrectTimeEntryRejectsStaleRevision() throws {
        let activity = try logManual(title: "Review", at: Date().addingTimeInterval(-7_200), duration: 600)
        let id = try XCTUnwrap(activity["id"] as? String)
        _ = try repository.correctTimeEntry(id: id, expectedRevision: 1, duration: 900, timestamp: nil, title: nil, projectId: nil, reason: "fix", sourceClient: "cursor")
        XCTAssertThrowsError(try repository.correctTimeEntry(id: id, expectedRevision: 1, duration: 300, timestamp: nil, title: nil, projectId: nil, reason: "again", sourceClient: "cursor")) { error in
            XCTAssertEqual((error as? IPCStructuredError)?.code, "revision_conflict")
        }
    }

    func testOverlapStillDetectedWithBoundedScan() throws {
        let start = Date().addingTimeInterval(-10_800)
        _ = try logManual(title: "Long block", at: start, duration: 7_200)
        XCTAssertThrowsError(try logManual(title: "Inside", at: start.addingTimeInterval(3_600), duration: 600)) { error in
            XCTAssertEqual((error as? IPCStructuredError)?.code, "activity_overlap")
        }
        XCTAssertNoThrow(try logManual(title: "After", at: start.addingTimeInterval(7_300), duration: 600))
    }

    func testCompleteTasksFillsSessionsAndLogsBackToBack() throws {
        try repository.addTask(id: "a", title: "Smoke-test build", tag: nil, projectId: nil, estimatedPomos: 3)
        try repository.addTask(id: "b", title: "Draft notes", tag: nil, projectId: nil, estimatedPomos: 2)
        try repository.incrementTaskPomos(id: "b")
        let plan = try repository.planTaskCompletions([(taskId: "a", expectedRevision: 1), (taskId: "b", expectedRevision: 2)])
        XCTAssertEqual(plan.map(\.remainingSessions), [3, 1])

        let start = Date().addingTimeInterval(-4 * 1500)
        let result = try repository.completeTasksWithSessions(plan, sessionSeconds: 1500, start: start, sourceClient: "cursor")

        let tasks = try XCTUnwrap(result["tasks"] as? [[String: Any]])
        XCTAssertEqual(tasks.map { $0["completedPomos"] as? Int }, [3, 2])
        XCTAssertTrue(tasks.allSatisfy { $0["isCompleted"] as? Bool == true })

        let sessions = try XCTUnwrap(result["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.count, 4)
        XCTAssertTrue(sessions.allSatisfy {
            $0["durationSeconds"] as? Int == 1500 && $0["isCompletion"] as? Bool == true
                && $0["source"] as? String == "agent" && $0["sourceClient"] as? String == "cursor"
        })
        XCTAssertEqual(sessions.map { $0["taskId"] as? String }, ["a", "a", "a", "b"])
        let formatter = ISO8601DateFormatter()
        let starts = sessions.compactMap { ($0["timestamp"] as? String).flatMap(formatter.date(from:)) }
        for (earlier, later) in zip(starts, starts.dropFirst()) {
            XCTAssertEqual(later.timeIntervalSince(earlier), 1500, accuracy: 1)
        }

        let reports = try repository.reports()
        XCTAssertEqual(reports["totalSessions"] as? Int, 4)
        XCTAssertEqual(reports["totalFocusTime"] as? Int, 6000)
    }

    func testCompleteTasksRefusesOverlapAndChangesNothing() throws {
        try repository.addTask(id: "a", title: "Task", tag: nil, projectId: nil, estimatedPomos: 2)
        _ = try logManual(title: "Meeting", at: Date().addingTimeInterval(-1_200), duration: 600)
        let plan = try repository.planTaskCompletions([(taskId: "a", expectedRevision: 1)])
        XCTAssertThrowsError(try repository.completeTasksWithSessions(plan, sessionSeconds: 1500, start: Date().addingTimeInterval(-3_000), sourceClient: "cursor")) { error in
            XCTAssertEqual((error as? IPCStructuredError)?.code, "activity_overlap")
        }
        XCTAssertThrowsError(try repository.checkNewActivity(duration: 3_000, timestamp: Date().addingTimeInterval(-3_000), taskId: nil, taskTitle: nil, projectId: nil, sourceClient: nil, idempotencyKey: nil))
        let task = try XCTUnwrap(try repository.listTasks().first)
        XCTAssertEqual(task["completedPomos"] as? Int, 0)
        XCTAssertEqual(task["isCompleted"] as? Bool, false)
    }

    func testCompleteTasksDetectsChangeAfterApproval() throws {
        try repository.addTask(id: "a", title: "Task", tag: nil, projectId: nil, estimatedPomos: 2)
        let plan = try repository.planTaskCompletions([(taskId: "a", expectedRevision: 1)])
        try repository.incrementTaskPomos(id: "a")
        XCTAssertThrowsError(try repository.completeTasksWithSessions(plan, sessionSeconds: 1500, start: Date().addingTimeInterval(-3_000), sourceClient: "cursor")) { error in
            XCTAssertEqual((error as? IPCStructuredError)?.code, "revision_conflict")
        }
    }

    func testCompleteTasksRefusesFutureAndAlreadyCompleteWork() throws {
        try repository.addTask(id: "a", title: "Task", tag: nil, projectId: nil, estimatedPomos: 1)
        let plan = try repository.planTaskCompletions([(taskId: "a", expectedRevision: 1)])
        XCTAssertThrowsError(try repository.completeTasksWithSessions(plan, sessionSeconds: 1500, start: Date(), sourceClient: "cursor")) { error in
            XCTAssertEqual((error as? IPCStructuredError)?.code, "validation_error")
        }
        _ = try repository.completeTask(id: "a", expectedRevision: 1)
        XCTAssertThrowsError(try repository.planTaskCompletions([(taskId: "a", expectedRevision: 2)])) { error in
            XCTAssertEqual((error as? IPCStructuredError)?.code, "validation_error")
        }
        XCTAssertThrowsError(try repository.planTaskCompletions([(taskId: "a", expectedRevision: 2), (taskId: "a", expectedRevision: 2)]))
    }

    func testCheckTaskEnforcesRevisionAndStatus() throws {
        try repository.addTask(id: "a", title: "Task", tag: nil, projectId: nil, estimatedPomos: 1)
        XCTAssertNoThrow(try repository.checkTask(id: "a", expectedRevision: 1, requiredStatus: 0))
        XCTAssertThrowsError(try repository.checkTask(id: "a", expectedRevision: 1, requiredStatus: 1))
        XCTAssertThrowsError(try repository.checkTask(id: "a", expectedRevision: 9)) { error in
            XCTAssertEqual((error as? IPCStructuredError)?.code, "revision_conflict")
        }
        XCTAssertThrowsError(try repository.checkTask(id: "missing", expectedRevision: 1)) { error in
            XCTAssertEqual((error as? IPCStructuredError)?.code, "not_found")
        }
    }

    @discardableResult
    private func logManual(title: String, at timestamp: Date, duration: Int) throws -> [String: Any] {
        try repository.logActivity(
            duration: duration,
            taskId: nil,
            taskTitle: title,
            tag: nil,
            projectId: nil,
            estimatedPomos: 1,
            snapshotFocusDuration: 1500,
            isCompletion: false,
            timestamp: timestamp,
            source: "manual",
            durationOrigin: "user_supplied"
        )
    }
}

final class UnixSocketBehaviorTests: XCTestCase {
    private var socketPath: String!

    override func setUp() {
        socketPath = "/tmp/flumen-test-\(UUID().uuidString.prefix(8)).sock"
    }

    override func tearDown() {
        unlink(socketPath)
    }

    func testServerReportsClientThatStopsWaiting() async throws {
        let disconnected = expectation(description: "disconnect reported")
        let recorder = StringRecorder()
        let server = UnixSocketServer(path: socketPath, onClientDisconnect: { requestId in
            recorder.append(requestId)
            disconnected.fulfill()
        }) { request in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return IPCResponse(requestId: request.requestId, result: .null)
        }
        try server.start()
        defer { server.stop() }

        let client = UnixSocketClient(path: socketPath, metadata: IPCClientMetadata(id: "c", name: "test"), timeout: 0.4)
        let request = IPCRequest(requestId: "slow-write", client: client.metadata, operation: "log_time")
        do {
            _ = try await client.send(request, retryAfterSend: false)
            XCTFail("Expected timeout")
        } catch let error as IPCStructuredError {
            XCTAssertEqual(error.code, "ipc_timeout")
        }
        await fulfillment(of: [disconnected], timeout: 2)
        XCTAssertEqual(recorder.values, ["slow-write"])
    }

    func testWriteIsNotResentAfterReachingServer() async throws {
        let counter = LockedCounter()
        let server = UnixSocketServer(path: socketPath) { request in
            counter.increment()
            try? await Task.sleep(nanoseconds: 800_000_000)
            return IPCResponse(requestId: request.requestId, result: .null)
        }
        try server.start()
        defer { server.stop() }

        let client = UnixSocketClient(path: socketPath, metadata: IPCClientMetadata(id: "c", name: "test"), timeout: 0.3)
        let request = IPCRequest(client: client.metadata, operation: "create_task")
        _ = try? await client.send(request, retryAfterSend: false)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(counter.value, 1)
    }

    func testCancellationClosesSocketAndReportsDisconnect() async throws {
        let disconnected = expectation(description: "disconnect reported")
        let server = UnixSocketServer(path: socketPath, onClientDisconnect: { _ in disconnected.fulfill() }) { request in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return IPCResponse(requestId: request.requestId, result: .null)
        }
        try server.start()
        defer { server.stop() }

        let client = UnixSocketClient(path: socketPath, metadata: IPCClientMetadata(id: "c", name: "test"), timeout: 30)
        let task = Task {
            try await client.send(IPCRequest(client: client.metadata, operation: "log_time"), retryAfterSend: false)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        let result = await task.result
        if case .success = result { XCTFail("Expected cancellation") }
        await fulfillment(of: [disconnected], timeout: 2)
    }

    func testRoundTripStillWorks() async throws {
        let server = UnixSocketServer(path: socketPath) { request in
            IPCResponse(requestId: request.requestId, result: .object(["op": .string(request.operation)]))
        }
        try server.start()
        defer { server.stop() }
        let client = UnixSocketClient(path: socketPath, metadata: IPCClientMetadata(id: "c", name: "test"))
        let result = try await client.send(operation: "ping")
        XCTAssertEqual(result["op"]?.stringValue, "ping")
    }
}

final class AgentOperationCatalogTests: XCTestCase {
    func testCatalogPartitionsOperations() {
        XCTAssertTrue(AgentOperationCatalog.reads.isDisjoint(with: AgentOperationCatalog.writes))
        XCTAssertTrue(AgentOperationCatalog.session.isDisjoint(with: AgentOperationCatalog.writes))
        XCTAssertTrue(AgentOperationCatalog.isWrite("complete_task"))
        XCTAssertTrue(AgentOperationCatalog.isWrite("resume_focus"))
        XCTAssertFalse(AgentOperationCatalog.isWrite("get_server_status"))
        XCTAssertGreaterThan(FlumenIPC.mutationTimeout, FlumenIPC.confirmationWindow)
    }
}

// MARK: - Helpers

private func XCTAssertThrowsCode(
    _ code: String,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        XCTFail("Expected \(code)", file: file, line: line)
    } catch let error as IPCStructuredError {
        XCTAssertEqual(error.code, code, file: file, line: line)
    } catch {
        XCTFail("Unexpected error \(error)", file: file, line: line)
    }
}

private actor OverlapTracker {
    private var current = 0
    private(set) var maxConcurrent = 0
    func enter() { current += 1; maxConcurrent = max(maxConcurrent, current) }
    func exit() { current -= 1 }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

private final class StringRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return items }
    func append(_ value: String) { lock.lock(); items.append(value); lock.unlock() }
}
