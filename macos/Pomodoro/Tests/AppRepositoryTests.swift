import XCTest
import GRDB
@testable import FlumenCore
import FlumenIPC

final class AppRepositoryTests: XCTestCase {
    private var dbPool: DatabasePool!
    private var repository: AppRepository!

    override func setUpWithError() throws {
        let path = NSTemporaryDirectory().appending("flumen-test-\(UUID().uuidString).sqlite")
        dbPool = try DatabasePool(path: path)
        try DatabaseManager.migrator.migrate(dbPool)
        let manager = try DatabaseManager(dbPool: dbPool)
        repository = AppRepository(database: manager)
    }

    func testAddAndListTasks() throws {
        try repository.addTask(id: "t1", title: "Ship MCP", tag: nil, projectId: nil, estimatedPomos: 2)
        let tasks = try repository.listTasks()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0]["title"] as? String, "Ship MCP")
        XCTAssertEqual(tasks[0]["revision"] as? Int, 1)
    }

    func testUpdateTaskRejectsStaleRevision() throws {
        try repository.addTask(id: "t1", title: "Ship MCP", tag: nil, projectId: nil, estimatedPomos: 2)
        _ = try repository.updateTask(id: "t1", title: "Ship MCP v2", tag: nil, projectId: nil, estimatedPomos: 3, expectedRevision: 1)
        do {
            _ = try repository.updateTask(id: "t1", title: "Stale", tag: nil, projectId: nil, estimatedPomos: 1, expectedRevision: 1)
            XCTFail("Expected revision conflict")
        } catch let error as IPCStructuredError {
            XCTAssertEqual(error.code, "revision_conflict")
        }
    }

    func testAdHocLogIsNotCompletion() throws {
        let activity = try repository.logActivity(
            duration: 600,
            taskId: nil,
            taskTitle: "Design review",
            tag: nil,
            projectId: nil,
            estimatedPomos: 1,
            snapshotFocusDuration: 1500,
            isCompletion: true,
            source: "manual",
            durationOrigin: "user_supplied"
        )
        XCTAssertEqual(activity["isCompletion"] as? Bool, false)
        XCTAssertEqual(activity["source"] as? String, "manual")
        XCTAssertEqual(activity["durationSeconds"] as? Int, 600)
    }

    func testIdempotentLogReturnsSameActivity() throws {
        let first = try repository.logActivity(
            duration: 300,
            taskId: nil,
            taskTitle: "Quick fix",
            tag: nil,
            projectId: nil,
            estimatedPomos: 1,
            snapshotFocusDuration: 1500,
            isCompletion: false,
            source: "agent",
            durationOrigin: "user_supplied",
            sourceClient: "cursor",
            idempotencyKey: "key-1"
        )
        let second = try repository.logActivity(
            duration: 300,
            taskId: nil,
            taskTitle: "Quick fix",
            tag: nil,
            projectId: nil,
            estimatedPomos: 1,
            snapshotFocusDuration: 1500,
            isCompletion: false,
            source: "agent",
            durationOrigin: "user_supplied",
            sourceClient: "cursor",
            idempotencyKey: "key-1"
        )
        XCTAssertEqual(first["id"] as? String, second["id"] as? String)
    }

    func testCorrectTimeEntryKeepsRevisionHistory() throws {
        let activity = try repository.logActivity(
            duration: 900,
            taskId: nil,
            taskTitle: "Meeting",
            tag: nil,
            projectId: nil,
            estimatedPomos: 1,
            snapshotFocusDuration: 1500,
            isCompletion: false,
            source: "manual",
            durationOrigin: "user_supplied"
        )
        let id = activity["id"] as! String
        let corrected = try repository.correctTimeEntry(
            id: id,
            expectedRevision: 1,
            duration: 1200,
            timestamp: nil,
            title: "Design meeting",
            projectId: nil,
            reason: "Forgot break",
            sourceClient: "manual"
        )
        XCTAssertEqual(corrected["durationSeconds"] as? Int, 1200)
        XCTAssertEqual(corrected["revision"] as? Int, 2)
        XCTAssertEqual(corrected["taskTitle"] as? String, "Design meeting")
    }

    func testRejectsFarFutureActivity() throws {
        let future = Date().addingTimeInterval(3600)
        do {
            _ = try repository.logActivity(
                duration: 600,
                taskId: nil,
                taskTitle: "Future work",
                tag: nil,
                projectId: nil,
                estimatedPomos: 1,
                snapshotFocusDuration: 1500,
                isCompletion: false,
                timestamp: future,
                source: "agent",
                durationOrigin: "user_supplied"
            )
            XCTFail("Expected future validation failure")
        } catch let error as IPCStructuredError {
            XCTAssertEqual(error.code, "validation_error")
            XCTAssertTrue(error.message.lowercased().contains("future"))
        }
    }

    func testQueryActivityFiltersBySource() throws {
        _ = try repository.logActivity(
            duration: 300,
            taskId: nil,
            taskTitle: "Timer session",
            tag: nil,
            projectId: nil,
            estimatedPomos: 1,
            snapshotFocusDuration: 1500,
            isCompletion: true,
            timestamp: Date().addingTimeInterval(-3600),
            source: "timer",
            durationOrigin: "observed"
        )
        _ = try repository.logActivity(
            duration: 300,
            taskId: nil,
            taskTitle: "Agent session",
            tag: nil,
            projectId: nil,
            estimatedPomos: 1,
            snapshotFocusDuration: 1500,
            isCompletion: false,
            timestamp: Date().addingTimeInterval(-1800),
            source: "agent",
            durationOrigin: "user_supplied",
            sourceClient: "cursor"
        )
        let start = Date().addingTimeInterval(-7200)
        let end = Date().addingTimeInterval(60)
        let agentOnly = try repository.queryActivity(start: start, end: end, source: "agent")
        XCTAssertEqual(agentOnly.count, 1)
        XCTAssertEqual(agentOnly[0]["taskTitle"] as? String, "Agent session")
    }

    func testReportBreakdownSurvivesAmbiguousTitleAndTagColumns() throws {
        // Joining tasks (title/tag) + session_logs (tag) used to make
        // `GROUP BY title, tag` fail with "ambiguous column name".
        try repository.addTask(
            id: "t-efs",
            title: "EFS Architecture brainstorm",
            tag: "Meeting",
            projectId: nil,
            estimatedPomos: 2
        )
        _ = try repository.logActivity(
            duration: 27,
            taskId: "t-efs",
            taskTitle: "EFS Architecture brainstorm",
            tag: "Meeting",
            projectId: nil,
            estimatedPomos: 2,
            snapshotFocusDuration: 1500,
            isCompletion: false,
            timestamp: Date().addingTimeInterval(-7200),
            source: "timer",
            durationOrigin: "observed"
        )

        let reports = try repository.reports()
        let breakdown = reports["taskBreakdown"] as? [[String: Any]]
        XCTAssertEqual(breakdown?.count, 1)
        XCTAssertEqual(breakdown?[0]["title"] as? String, "EFS Architecture brainstorm")
        XCTAssertEqual(breakdown?[0]["tag"] as? String, "Meeting")
        XCTAssertEqual(breakdown?[0]["duration"] as? Int, 27)
        XCTAssertEqual(breakdown?[0]["estimatedPomos"] as? Int, 2)
    }

    func testReportBreakdownMergesSameTaskAcrossTagSnapshots() throws {
        try repository.addTask(
            id: "t-efs",
            title: "EFS Architecture brainstorm",
            tag: "Meeting",
            projectId: nil,
            estimatedPomos: 2
        )
        // Short timer session carried the Meeting tag.
        _ = try repository.logActivity(
            duration: 27,
            taskId: "t-efs",
            taskTitle: "EFS Architecture brainstorm",
            tag: "Meeting",
            projectId: nil,
            estimatedPomos: 2,
            snapshotFocusDuration: 1500,
            isCompletion: false,
            timestamp: Date().addingTimeInterval(-10_000),
            source: "timer",
            durationOrigin: "observed"
        )
        // Later agent logs omitted the tag — still the same task.
        // Non-overlapping windows: [-8000, -5000) and [-4000, -2500).
        _ = try repository.logActivity(
            duration: 3000,
            taskId: "t-efs",
            taskTitle: "EFS Architecture brainstorm",
            tag: nil,
            projectId: nil,
            estimatedPomos: 2,
            snapshotFocusDuration: 1500,
            isCompletion: false,
            timestamp: Date().addingTimeInterval(-8000),
            source: "agent",
            durationOrigin: "user_supplied",
            sourceClient: "cursor"
        )
        _ = try repository.logActivity(
            duration: 1500,
            taskId: "t-efs",
            taskTitle: "EFS Architecture brainstorm",
            tag: nil,
            projectId: nil,
            estimatedPomos: 2,
            snapshotFocusDuration: 1500,
            isCompletion: false,
            timestamp: Date().addingTimeInterval(-4000),
            source: "agent",
            durationOrigin: "user_supplied",
            sourceClient: "cursor"
        )

        let breakdown = try repository.reportBreakdown()
        XCTAssertEqual(breakdown.count, 1)
        XCTAssertEqual(breakdown[0]["title"] as? String, "EFS Architecture brainstorm")
        XCTAssertEqual(breakdown[0]["tag"] as? String, "Meeting")
        XCTAssertEqual(breakdown[0]["duration"] as? Int, 4527)
        XCTAssertEqual(breakdown[0]["estimatedPomos"] as? Int, 2)
    }

    func testReportBreakdownKeepsAdHocRowsSeparateByTitleAndTag() throws {
        _ = try repository.logActivity(
            duration: 600,
            taskId: nil,
            taskTitle: "Standup",
            tag: "Meeting",
            projectId: nil,
            estimatedPomos: 1,
            snapshotFocusDuration: 1500,
            isCompletion: false,
            timestamp: Date().addingTimeInterval(-3600),
            source: "manual",
            durationOrigin: "user_supplied"
        )
        _ = try repository.logActivity(
            duration: 900,
            taskId: nil,
            taskTitle: "Standup",
            tag: nil,
            projectId: nil,
            estimatedPomos: 1,
            snapshotFocusDuration: 1500,
            isCompletion: false,
            timestamp: Date().addingTimeInterval(-1800),
            source: "manual",
            durationOrigin: "user_supplied"
        )
        _ = try repository.logActivity(
            duration: 300,
            taskId: nil,
            taskTitle: "Inbox zero",
            tag: nil,
            projectId: nil,
            estimatedPomos: 1,
            snapshotFocusDuration: 1500,
            isCompletion: false,
            timestamp: Date().addingTimeInterval(-900),
            source: "manual",
            durationOrigin: "user_supplied"
        )

        let breakdown = try repository.reportBreakdown()
        XCTAssertEqual(breakdown.count, 3)

        let byKey = Dictionary(uniqueKeysWithValues: breakdown.map {
            ("\($0["title"] as! String)|\($0["tag"] as! String)", $0["duration"] as! Int)
        })
        XCTAssertEqual(byKey["Standup|Meeting"], 600)
        XCTAssertEqual(byKey["Standup|Untagged"], 900)
        XCTAssertEqual(byKey["Inbox zero|Untagged"], 300)
    }

    func testReportBreakdownPrefersCurrentTaskTitleAfterRename() throws {
        try repository.addTask(
            id: "t1",
            title: "Old title",
            tag: "Work",
            projectId: nil,
            estimatedPomos: 1
        )
        _ = try repository.logActivity(
            duration: 1200,
            taskId: "t1",
            taskTitle: "Old title",
            tag: "Work",
            projectId: nil,
            estimatedPomos: 1,
            snapshotFocusDuration: 1500,
            isCompletion: false,
            timestamp: Date().addingTimeInterval(-3600),
            source: "timer",
            durationOrigin: "observed"
        )
        _ = try repository.updateTask(
            id: "t1",
            title: "New title",
            tag: "Work",
            projectId: nil,
            estimatedPomos: 3,
            expectedRevision: 1
        )

        let breakdown = try repository.reportBreakdown()
        XCTAssertEqual(breakdown.count, 1)
        XCTAssertEqual(breakdown[0]["title"] as? String, "New title")
        XCTAssertEqual(breakdown[0]["estimatedPomos"] as? Int, 3)
        XCTAssertEqual(breakdown[0]["duration"] as? Int, 1200)
    }

    func testReportBreakdownUsesLocalDateFromTimezoneOffset() throws {
        try repository.addTask(
            id: "t1",
            title: "Late night",
            tag: nil,
            projectId: nil,
            estimatedPomos: 1
        )
        // 2026-07-20 22:30 UTC + 330 minutes (IST) => local date 2026-07-21
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let startedAt = formatter.date(from: "2026-07-20T22:30:00Z")!

        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO session_logs
                (id, task_id, task_title, tag, project_id, estimated_pomos, snapshot_focus_duration,
                 duration_seconds, is_completion, timestamp, timezone_offset, source, duration_origin,
                 recorded_at, revision)
                VALUES (?, ?, ?, NULL, NULL, 1, 1500, 600, 0, ?, 330, 'timer', 'observed', ?, 1)
                """, arguments: [
                    UUID().uuidString, "t1", "Late night", startedAt, startedAt
                ])
        }

        let breakdown = try repository.reportBreakdown()
        XCTAssertEqual(breakdown.count, 1)
        XCTAssertEqual(breakdown[0]["date"] as? String, "2026-07-21")
        XCTAssertEqual(breakdown[0]["duration"] as? Int, 600)
    }
}
