import Foundation
import GRDB
import FlumenIPC

public final class AppRepository: @unchecked Sendable {
    public let database: DatabaseManager

    public init(database: DatabaseManager = .shared) {
        self.database = database
    }

    public func loadInitialData() throws -> [String: Any] {
        try database.dbPool.read { db in
            let tasks = try Row.fetchAll(db, sql: "SELECT * FROM tasks WHERE status < 2 ORDER BY created_at ASC")
            let projects = try Row.fetchAll(db, sql: "SELECT * FROM projects WHERE is_archived = 0 ORDER BY name COLLATE NOCASE")
            return [
                "tasks": tasks.map(taskDictionary),
                "projects": projects.map(projectDictionary)
            ]
        }
    }

    public func addTask(id: String, title: String, tag: String?, projectId: String?, estimatedPomos: Int) throws {
        let title = try validatedTitle(title)
        guard (1...100).contains(estimatedPomos) else { throw validation("estimatedPomos must be between 1 and 100.") }
        let now = Date()
        try database.dbPool.write { db in
            try ensureProject(projectId, in: db)
            try db.execute(sql: """
                INSERT INTO tasks
                (id, title, tag, project_id, estimated_pomos, completed_pomos, status, created_at, updated_at, revision)
                VALUES (?, ?, ?, ?, ?, 0, 0, ?, ?, 1)
                """, arguments: [id, title, clean(tag), clean(projectId), estimatedPomos, now, now])
        }
    }

    public func updateTaskStatus(id: String, status: Int) throws {
        guard (0...2).contains(status) else { throw validation("Task status must be 0, 1, or 2.") }
        try database.dbPool.write { db in
            try db.execute(
                sql: "UPDATE tasks SET status = ?, is_completed = ?, revision = revision + 1, updated_at = ? WHERE id = ?",
                arguments: [status, status == 1, Date(), id]
            )
        }
    }

    public func updateTask(
        id: String,
        title: String,
        tag: String?,
        projectId: String?,
        estimatedPomos: Int,
        expectedRevision: Int? = nil
    ) throws -> [String: Any] {
        let title = try validatedTitle(title)
        guard (1...100).contains(estimatedPomos) else { throw validation("estimatedPomos must be between 1 and 100.") }
        return try database.dbPool.write { db in
            try ensureProject(projectId, in: db)
            guard let current = try Row.fetchOne(db, sql: "SELECT * FROM tasks WHERE id = ?", arguments: [id]) else {
                throw notFound("task", id)
            }
            let revision: Int = current["revision"]
            if let expectedRevision, expectedRevision != revision {
                throw conflict("Task was changed after the proposal was created.", currentRevision: revision)
            }
            try db.execute(sql: """
                UPDATE tasks SET title = ?, tag = ?, project_id = ?, estimated_pomos = ?,
                    revision = revision + 1, updated_at = ?
                WHERE id = ? AND revision = ?
                """, arguments: [title, clean(tag), clean(projectId), estimatedPomos, Date(), id, revision])
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM tasks WHERE id = ?", arguments: [id]) else {
                throw notFound("task", id)
            }
            return taskDictionary(row)
        }
    }

    public func archiveTask(id: String) throws { try updateTaskStatus(id: id, status: 2) }

    public func clearCompletedTasks() throws {
        try database.dbPool.write { db in
            try db.execute(sql: """
                UPDATE tasks SET status = 2, revision = revision + 1, updated_at = ?
                WHERE status = 1
                """, arguments: [Date()])
        }
    }

    public func incrementTaskPomos(id: String) throws {
        try database.dbPool.write { db in
            try db.execute(sql: """
                UPDATE tasks SET completed_pomos = completed_pomos + 1,
                    revision = revision + 1, updated_at = ? WHERE id = ?
                """, arguments: [Date(), id])
        }
    }

    @discardableResult
    public func logActivity(
        duration: Int,
        taskId: String?,
        taskTitle: String?,
        tag: String?,
        projectId: String?,
        estimatedPomos: Int,
        snapshotFocusDuration: Int,
        isCompletion: Bool,
        timestamp: Date = Date(),
        source: String = "timer",
        durationOrigin: String = "observed",
        sourceClient: String? = nil,
        externalReference: String? = nil,
        idempotencyKey: String? = nil
    ) throws -> [String: Any] {
        guard (1...86_400).contains(duration) else { throw validation("durationSeconds must be between 1 and 86400.") }
        guard ["timer", "manual", "agent"].contains(source) else { throw validation("Invalid activity source.") }
        guard ["observed", "user_supplied", "inferred"].contains(durationOrigin) else { throw validation("Invalid duration origin.") }
        let activityID = UUID().uuidString
        let recordedAt = Date()
        let offset = TimeZone.current.secondsFromGMT(for: timestamp) / 60
        let end = timestamp.addingTimeInterval(TimeInterval(duration))
        // Reject not-yet-started work. Ends may sit slightly ahead of "now" when a
        // caller supplies start=now with a duration (common for immediate logs).
        if timestamp > recordedAt.addingTimeInterval(120) {
            throw validation("Activity cannot start more than two minutes in the future.")
        }
        if end > recordedAt.addingTimeInterval(86_400) {
            throw validation("Activity end time is more than 24 hours in the future.")
        }

        return try database.dbPool.write { db in
            if let idempotencyKey, let sourceClient,
               let row = try Row.fetchOne(
                   db,
                   sql: "SELECT * FROM session_logs WHERE source_client = ? AND idempotency_key = ?",
                   arguments: [sourceClient, idempotencyKey]
               ) {
                return activityDictionary(row)
            }
            try ensureProject(projectId, in: db)
            if let taskId {
                guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasks WHERE id = ?", arguments: [taskId]) == 1 else {
                    throw notFound("task", taskId)
                }
            }

            // Durations are capped at 24h, so only rows starting in the prior day can overlap.
            // The lower bound keeps this an indexed range scan instead of a full-history filter.
            let overlaps = try Row.fetchAll(db, sql: """
                SELECT * FROM session_logs
                WHERE timestamp < ? AND timestamp > ?
                  AND DATETIME(timestamp, '+' || duration_seconds || ' seconds') > ?
                LIMIT 10
                """, arguments: [end, timestamp.addingTimeInterval(-86_400), timestamp])
            if let exact = overlaps.first(where: {
                let existingStart: Date = $0["timestamp"]
                let existingDuration: Int = $0["duration_seconds"]
                let existingTitle: String? = $0["task_title"]
                let existingProject: String? = $0["project_id"]
                return abs(existingStart.timeIntervalSince(timestamp)) < 0.5
                    && existingDuration == duration
                    && existingTitle == clean(taskTitle)
                    && existingProject == clean(projectId)
            }) {
                throw IPCStructuredError(
                    code: "duplicate_activity",
                    message: "An exact duplicate activity already exists.",
                    details: ["activityId": .string(exact["id"] as String)]
                )
            }
            if !overlaps.isEmpty {
                throw IPCStructuredError(
                    code: "activity_overlap",
                    message: "The proposed time overlaps existing recorded activity.",
                    details: ["activityIds": .array(overlaps.map { .string($0["id"] as String) })]
                )
            }

            try db.execute(sql: """
                INSERT INTO session_logs
                (id, task_id, task_title, tag, project_id, estimated_pomos, snapshot_focus_duration,
                 duration_seconds, is_completion, timestamp, timezone_offset, source, duration_origin,
                 recorded_at, source_client, external_reference, idempotency_key, revision)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
                """, arguments: [
                    activityID, clean(taskId), clean(taskTitle), clean(tag), clean(projectId),
                    max(1, estimatedPomos), max(60, snapshotFocusDuration), duration,
                    source == "timer" ? isCompletion : false,
                    timestamp, offset, source, durationOrigin, recordedAt, clean(sourceClient),
                    clean(externalReference), clean(idempotencyKey)
                ])
            let row = try Row.fetchOne(db, sql: "SELECT * FROM session_logs WHERE id = ?", arguments: [activityID])!
            return activityDictionary(row)
        }
    }

    public func upsertProject(id: String?, name: String, color: String?) throws -> [String: Any] {
        let name = try validatedTitle(name)
        let projectID = id ?? UUID().uuidString
        try database.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO projects (id, name, color_hex, is_archived, created_at)
                VALUES (?, ?, ?, 0, ?)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name, color_hex = excluded.color_hex
                """, arguments: [projectID, name, clean(color), Date()])
        }
        return ["id": projectID, "name": name, "color": clean(color) as Any]
    }

    public func listTasks(includeCompleted: Bool = false, limit: Int = 100) throws -> [[String: Any]] {
        let limit = max(1, min(limit, 200))
        return try database.dbPool.read { db in
            let condition = includeCompleted ? "status < 2" : "status = 0"
            return try Row.fetchAll(
                db,
                sql: "SELECT * FROM tasks WHERE \(condition) ORDER BY updated_at DESC, created_at DESC LIMIT ?",
                arguments: [limit]
            ).map(taskDictionary)
        }
    }

    public func listProjects() throws -> [[String: Any]] {
        try database.dbPool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM projects WHERE is_archived = 0 ORDER BY name COLLATE NOCASE")
                .map(projectDictionary)
        }
    }

    public func activity(byId id: String) throws -> [String: Any]? {
        try database.dbPool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM session_logs WHERE id = ?", arguments: [id]) else {
                return nil
            }
            return activityDictionary(row)
        }
    }

    public func queryActivity(
        start: Date,
        end: Date,
        projectId: String? = nil,
        taskId: String? = nil,
        source: String? = nil,
        limit: Int = 200
    ) throws -> [[String: Any]] {
        guard end > start else { throw validation("end must be later than start.") }
        guard end.timeIntervalSince(start) <= 90 * 86_400 else { throw validation("Activity queries are limited to 90 days.") }
        if let source, !["timer", "manual", "agent"].contains(source) {
            throw validation("source must be timer, manual, or agent.")
        }
        let limit = max(1, min(limit, 500))
        return try database.dbPool.read { db in
            var sql = "SELECT * FROM session_logs WHERE timestamp >= ? AND timestamp < ?"
            var arguments: StatementArguments = [start, end]
            if let projectId = clean(projectId) {
                sql += " AND project_id = ?"
                arguments += [projectId]
            }
            if let taskId = clean(taskId) {
                sql += " AND task_id = ?"
                arguments += [taskId]
            }
            if let source = clean(source) {
                sql += " AND source = ?"
                arguments += [source]
            }
            sql += " ORDER BY timestamp DESC LIMIT ?"
            arguments += [limit]
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map(activityDictionary)
        }
    }

    public func focusSummary(start: Date, end: Date) throws -> [String: Any] {
        guard end > start, end.timeIntervalSince(start) <= 366 * 86_400 else {
            throw validation("Summary range must be between 1 second and 366 days.")
        }
        return try database.dbPool.read { db in
            let totals = try Row.fetchOne(db, sql: """
                SELECT COALESCE(SUM(duration_seconds), 0) total_seconds,
                       COUNT(*) activity_count,
                       COALESCE(SUM(CASE WHEN is_completion = 1 THEN 1 ELSE 0 END), 0) completed_cycles
                FROM session_logs WHERE timestamp >= ? AND timestamp < ?
                """, arguments: [start, end])!
            let projects = try Row.fetchAll(db, sql: """
                SELECT COALESCE(p.name, l.tag, 'Untagged') name, SUM(l.duration_seconds) duration_seconds
                FROM session_logs l LEFT JOIN projects p ON p.id = l.project_id
                WHERE l.timestamp >= ? AND l.timestamp < ?
                GROUP BY COALESCE(p.name, l.tag, 'Untagged')
                ORDER BY duration_seconds DESC LIMIT 20
                """, arguments: [start, end])
            return [
                "start": iso8601(start), "end": iso8601(end),
                "totalSeconds": totals["total_seconds"] as Int,
                "activityCount": totals["activity_count"] as Int,
                "completedCycles": totals["completed_cycles"] as Int,
                "projects": projects.map {
                    ["name": $0["name"] as String, "durationSeconds": $0["duration_seconds"] as Int]
                }
            ]
        }
    }

    public func estimationContext(query: String?, projectId: String?, limit: Int = 20) throws -> [String: Any] {
        let limit = max(1, min(limit, 50))
        return try database.dbPool.read { db in
            var sql = """
                SELECT COALESCE(l.task_title, t.title, 'Unselected Activity') AS title,
                       l.task_id, l.project_id, SUM(l.duration_seconds) AS actual_seconds,
                       MAX(COALESCE(t.estimated_pomos, l.estimated_pomos, 1)) AS estimated_pomos,
                       COUNT(*) AS activity_count, MAX(l.timestamp) AS last_active
                FROM session_logs l LEFT JOIN tasks t ON t.id = l.task_id WHERE 1 = 1
                """
            var args = StatementArguments()
            if let query = clean(query) {
                sql += " AND COALESCE(l.task_title, t.title, '') LIKE ?"
                args += ["%\(query)%"]
            }
            if let projectId = clean(projectId) {
                sql += " AND l.project_id = ?"
                args += [projectId]
            }
            // Group by concrete columns — alias `title` collides with tasks.title.
            sql += """
                 GROUP BY COALESCE(l.task_title, t.title, 'Unselected Activity'),
                          l.task_id, l.project_id
                 ORDER BY last_active DESC LIMIT ?
                """
            args += [limit]
            let rows = try Row.fetchAll(db, sql: sql, arguments: args)
            return ["comparables": rows.map {
                [
                    "title": $0["title"] as String,
                    "taskId": ($0["task_id"] as String?) as Any,
                    "projectId": ($0["project_id"] as String?) as Any,
                    "actualSeconds": $0["actual_seconds"] as Int,
                    "estimatedPomos": $0["estimated_pomos"] as Int,
                    "activityCount": $0["activity_count"] as Int,
                    "lastActive": iso8601($0["last_active"] as Date)
                ]
            }]
        }
    }

    public func completeTask(id: String, expectedRevision: Int) throws -> [String: Any] {
        try database.dbPool.write { db in
            guard let current = try Row.fetchOne(db, sql: "SELECT * FROM tasks WHERE id = ?", arguments: [id]) else {
                throw notFound("task", id)
            }
            let revision: Int = current["revision"]
            guard revision == expectedRevision else {
                throw conflict("Task was changed after approval.", currentRevision: revision)
            }
            try db.execute(sql: """
                UPDATE tasks SET status = 1, is_completed = 1, revision = revision + 1, updated_at = ?
                WHERE id = ? AND revision = ?
                """, arguments: [Date(), id, revision])
            return taskDictionary(try Row.fetchOne(db, sql: "SELECT * FROM tasks WHERE id = ?", arguments: [id])!)
        }
    }

    public func reopenTask(id: String, expectedRevision: Int) throws -> [String: Any] {
        try database.dbPool.write { db in
            guard let current = try Row.fetchOne(db, sql: "SELECT * FROM tasks WHERE id = ?", arguments: [id]) else {
                throw notFound("task", id)
            }
            let revision: Int = current["revision"]
            guard revision == expectedRevision else {
                throw conflict("Task was changed after approval.", currentRevision: revision)
            }
            let status: Int = current["status"]
            guard status == 1 else {
                throw validation(status == 2 ? "Archived tasks cannot be reopened." : "Task is already open.")
            }
            try db.execute(sql: """
                UPDATE tasks SET status = 0, is_completed = 0, revision = revision + 1, updated_at = ?
                WHERE id = ? AND revision = ?
                """, arguments: [Date(), id, revision])
            return taskDictionary(try Row.fetchOne(db, sql: "SELECT * FROM tasks WHERE id = ?", arguments: [id])!)
        }
    }

    public func correctTimeEntry(
        id: String,
        expectedRevision: Int,
        duration: Int?,
        timestamp: Date?,
        title: String?,
        projectId: String?,
        reason: String,
        sourceClient: String
    ) throws -> [String: Any] {
        guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw validation("A correction reason is required.")
        }
        if let duration, !(1...86_400).contains(duration) { throw validation("durationSeconds must be between 1 and 86400.") }
        return try database.dbPool.write { db in
            guard let current = try Row.fetchOne(db, sql: "SELECT * FROM session_logs WHERE id = ?", arguments: [id]) else {
                throw notFound("activity", id)
            }
            let revision: Int = current["revision"]
            guard revision == expectedRevision else {
                throw conflict("Activity was changed after approval.", currentRevision: revision)
            }
            try ensureProject(projectId, in: db)
            let prior = activityDictionary(current)
            let priorData = try JSONSerialization.data(withJSONObject: prior)
            let priorJSON = String(decoding: priorData, as: UTF8.self)
            try db.execute(sql: """
                INSERT INTO activity_revisions
                (activity_id, revision, changed_at, source_client, reason, prior_values)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [id, revision, Date(), sourceClient, reason, priorJSON])
            let newDuration = duration ?? (current["duration_seconds"] as Int)
            let newTimestamp = timestamp ?? (current["timestamp"] as Date)
            let newTitle: String?
            if let title {
                newTitle = try validatedTitle(title)
            } else {
                newTitle = current["task_title"] as String?
            }
            let newProject = projectId ?? (current["project_id"] as String?)
            try db.execute(sql: """
                UPDATE session_logs SET duration_seconds = ?, timestamp = ?, task_title = ?, project_id = ?,
                    timezone_offset = ?, revision = revision + 1
                WHERE id = ? AND revision = ?
                """, arguments: [
                    newDuration, newTimestamp, newTitle, clean(newProject),
                    TimeZone.current.secondsFromGMT(for: newTimestamp) / 60, id, revision
                ])
            return activityDictionary(try Row.fetchOne(db, sql: "SELECT * FROM session_logs WHERE id = ?", arguments: [id])!)
        }
    }

    public func reports() throws -> [String: Any] {
        try database.dbPool.read { db in
            let daily = try Row.fetchAll(db, sql: """
                SELECT DATE(timestamp, '+' || timezone_offset || ' minutes') date,
                       SUM(duration_seconds) / 3600.0 hours
                FROM session_logs WHERE timestamp >= DATETIME('now', '-60 days')
                GROUP BY date ORDER BY date
                """)
            let projects = try Row.fetchAll(db, sql: """
                SELECT COALESCE(p.name, l.tag, 'Untagged') AS name,
                       SUM(l.duration_seconds) / 3600.0 AS value
                FROM session_logs l LEFT JOIN projects p ON l.project_id = p.id
                GROUP BY COALESCE(p.name, l.tag, 'Untagged')
                ORDER BY value DESC
                """)
            let breakdown = try fetchReportBreakdown(db)
            let total = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(duration_seconds), 0) FROM session_logs") ?? 0
            let cycles = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_logs WHERE is_completion = 1") ?? 0
            let dateRows = try String.fetchAll(db, sql: """
                SELECT DISTINCT DATE(timestamp, '+' || timezone_offset || ' minutes')
                FROM session_logs ORDER BY 1 DESC
                """)
            return [
                "dailyStats": daily.map { ["date": $0["date"] as String, "hours": $0["hours"] as Double] },
                "projectDistribution": projects.map { ["name": $0["name"] as String, "value": $0["value"] as Double] },
                "totalFocusTime": total,
                "totalSessions": cycles,
                "taskBreakdown": breakdown,
                "streak": calculateStreak(dateRows)
            ]
        }
    }

    public func reportBreakdown() throws -> [[String: Any]] {
        try database.dbPool.read { db in
            try fetchReportBreakdown(db)
        }
    }

    /// Returns the stored result for an idempotency key.
    /// Throws `idempotency_conflict` when the key was first used with different parameters.
    public func cachedOperation(client: String, key: String, operation: String, fingerprint: String) throws -> JSONValue? {
        try database.dbPool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT response_json, request_fingerprint FROM agent_operation_results
                WHERE source_client = ? AND idempotency_key = ? AND operation = ?
                """, arguments: [client, key, operation]) else { return nil }
            let storedFingerprint: String? = row["request_fingerprint"]
            if let storedFingerprint, storedFingerprint != fingerprint {
                throw AgentAccessErrors.idempotencyConflict()
            }
            let json: String = row["response_json"]
            return try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        }
    }

    public func storeOperation(client: String, key: String, operation: String, fingerprint: String, result: JSONValue) throws {
        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        try database.dbPool.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO agent_operation_results
                (source_client, idempotency_key, operation, response_json, created_at, request_fingerprint)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [client, key, operation, json, Date(), fingerprint])
        }
    }
}

private func clean(_ value: String?) -> String? {
    guard let value else { return nil }
    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty || cleaned == "nil" ? nil : cleaned
}

private func validatedTitle(_ value: String) throws -> String {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.count <= 300 else { throw validation("Title must be between 1 and 300 characters.") }
    return value
}

private func ensureProject(_ id: String?, in db: Database) throws {
    guard let id = clean(id) else { return }
    guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM projects WHERE id = ? AND is_archived = 0", arguments: [id]) == 1 else {
        throw notFound("project", id)
    }
}

private func taskDictionary(_ row: Row) -> [String: Any] {
    let status: Int = row["status"]
    let updated: Date? = row["updated_at"]
    return [
        "id": row["id"] as String,
        "title": row["title"] as String,
        "tag": (row["tag"] as String?) as Any,
        "projectId": (row["project_id"] as String?) as Any,
        "estimatedPomos": row["estimated_pomos"] as Int,
        "completedPomos": row["completed_pomos"] as Int,
        "status": status,
        "isCompleted": status == 1,
        "revision": row["revision"] as Int,
        "createdAt": (row["created_at"] as Date).timeIntervalSince1970 * 1000,
        "updatedAt": (updated ?? row["created_at"] as Date).timeIntervalSince1970 * 1000
    ]
}

private func projectDictionary(_ row: Row) -> [String: Any] {
    [
        "id": row["id"] as String,
        "name": row["name"] as String,
        "color": (row["color_hex"] as String?) as Any
    ]
}

private func activityDictionary(_ row: Row) -> [String: Any] {
    [
        "id": row["id"] as String,
        "taskId": (row["task_id"] as String?) as Any,
        "taskTitle": (row["task_title"] as String?) as Any,
        "tag": (row["tag"] as String?) as Any,
        "projectId": (row["project_id"] as String?) as Any,
        "durationSeconds": row["duration_seconds"] as Int,
        "isCompletion": row["is_completion"] as Bool,
        "timestamp": iso8601(row["timestamp"] as Date),
        "recordedAt": iso8601((row["recorded_at"] as Date?) ?? row["timestamp"] as Date),
        "source": row["source"] as String,
        "durationOrigin": row["duration_origin"] as String,
        "sourceClient": (row["source_client"] as String?) as Any,
        "externalReference": (row["external_reference"] as String?) as Any,
        "revision": row["revision"] as Int
    ]
}

private func fetchReportBreakdown(_ db: Database) throws -> [[String: Any]] {
    // Group linked-task logs by task_id so mixed tag/title snapshots on the same
    // task collapse into one row. Ad-hoc logs (no task_id) still group by the
    // displayed title + project/tag label.
    //
    // Avoid GROUP BY on aliases `title`/`tag` — they collide with tasks.title /
    // tasks.tag / session_logs.tag and fail under SQLite's ambiguous-column rules.
    let rows = try Row.fetchAll(db, sql: """
        SELECT COALESCE(MAX(t.title), MAX(l.task_title), 'Unselected Activity') AS title,
               COALESCE(MAX(p.name), MAX(t.tag), MAX(l.tag), 'Untagged') AS tag,
               SUM(l.duration_seconds) AS duration,
               COALESCE(MAX(t.estimated_pomos), MAX(l.estimated_pomos), 1) AS estimated_pomos,
               AVG(l.snapshot_focus_duration) AS avg_snapshot_duration,
               MAX(DATE(l.timestamp, '+' || l.timezone_offset || ' minutes')) AS last_active
        FROM session_logs l
        LEFT JOIN tasks t ON l.task_id = t.id
        LEFT JOIN projects p ON l.project_id = p.id
        GROUP BY COALESCE(l.task_id, ''),
                 CASE WHEN l.task_id IS NULL
                      THEN COALESCE(l.task_title, 'Unselected Activity')
                      ELSE '' END,
                 CASE WHEN l.task_id IS NULL
                      THEN COALESCE(p.name, l.tag, 'Untagged')
                      ELSE '' END
        ORDER BY MAX(l.timestamp) DESC
        """)
    return rows.map {
        [
            "title": $0["title"] as String,
            "tag": $0["tag"] as String,
            "duration": $0["duration"] as Int,
            "estimatedPomos": $0["estimated_pomos"] as Int,
            "avgSnapshotDuration": $0["avg_snapshot_duration"] as Double,
            "date": $0["last_active"] as String
        ]
    }
}

private func calculateStreak(_ dates: [String]) -> Int {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    let calendar = Calendar.current
    var expected = calendar.startOfDay(for: Date())
    var streak = 0
    for value in dates {
        guard let date = formatter.date(from: value) else { continue }
        let days = calendar.dateComponents([.day], from: date, to: expected).day ?? 0
        if days <= 1 {
            streak += 1
            expected = date
        } else { break }
    }
    return streak
}

// ISO8601DateFormatter is thread-safe; reuse one instead of allocating per row.
nonisolated(unsafe) private let iso8601Formatter = ISO8601DateFormatter()

private func iso8601(_ date: Date) -> String { iso8601Formatter.string(from: date) }

private func validation(_ message: String) -> IPCStructuredError {
    IPCStructuredError(code: "validation_error", message: message)
}

private func notFound(_ kind: String, _ id: String) -> IPCStructuredError {
    IPCStructuredError(code: "not_found", message: "No \(kind) exists with id \(id).")
}

private func conflict(_ message: String, currentRevision: Int) -> IPCStructuredError {
    IPCStructuredError(
        code: "revision_conflict",
        message: message,
        details: ["currentRevision": .number(Double(currentRevision))]
    )
}
