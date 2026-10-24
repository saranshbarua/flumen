import Foundation
import GRDB

public final class DatabaseManager: @unchecked Sendable {
    public static let shared = DatabaseManager()
    public let dbPool: DatabasePool

    public convenience init() {
        let fileManager = FileManager.default
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "com.saranshbarua.flumen"
        let folder = support.appendingPathComponent(bundleID, isDirectory: true)
        try! fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        self.init(path: folder.appendingPathComponent("db.sqlite").path, migrateLegacy: true)
    }

    public init(path: String, migrateLegacy: Bool = false) {
        do {
            dbPool = try DatabasePool(path: path)
            try Self.migrator.migrate(dbPool)
            if migrateLegacy { try migrateFromUserDefaults() }
        } catch {
            fatalError("DatabaseManager setup failed: \(error)")
        }
    }

    public init(dbPool: DatabasePool) throws {
        self.dbPool = dbPool
        try Self.migrator.migrate(dbPool)
    }

    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "tasks") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("tag", .text)
                t.column("estimated_pomos", .integer).notNull().defaults(to: 1)
                t.column("completed_pomos", .integer).notNull().defaults(to: 0)
                t.column("is_completed", .boolean).notNull().defaults(to: false)
                t.column("created_at", .datetime).notNull()
            }
            try db.create(table: "session_logs") { t in
                t.column("id", .text).primaryKey()
                t.column("task_id", .text).references("tasks", onDelete: .setNull)
                t.column("task_title", .text)
                t.column("tag", .text)
                t.column("duration_seconds", .integer).notNull()
                t.column("is_completion", .boolean).notNull().defaults(to: false)
                t.column("timestamp", .datetime).notNull()
            }
            try db.create(table: "app_settings") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text)
            }
            try db.create(index: "idx_session_logs_timestamp", on: "session_logs", columns: ["timestamp"])
            try db.create(index: "idx_tasks_is_completed", on: "tasks", columns: ["is_completed"])
        }
        migrator.registerMigration("v2") { db in
            try db.create(table: "projects") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("color_hex", .text)
                t.column("is_archived", .boolean).notNull().defaults(to: false)
                t.column("created_at", .datetime).notNull()
            }
            try db.alter(table: "tasks") { t in
                t.add(column: "project_id", .text).references("projects", onDelete: .setNull)
                t.add(column: "status", .integer).notNull().defaults(to: 0)
            }
            try db.execute(sql: "UPDATE tasks SET status = 1 WHERE is_completed = 1")
            try db.alter(table: "session_logs") { t in
                t.add(column: "project_id", .text).references("projects", onDelete: .setNull)
                t.add(column: "timezone_offset", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "idx_logs_reporting_v2", on: "session_logs", columns: ["timestamp", "project_id", "duration_seconds"])
        }
        migrator.registerMigration("v3") { db in
            try db.alter(table: "session_logs") {
                $0.add(column: "estimated_pomos", .integer).notNull().defaults(to: 1)
            }
        }
        migrator.registerMigration("v4") { db in
            try db.alter(table: "session_logs") {
                $0.add(column: "snapshot_focus_duration", .integer).notNull().defaults(to: 1500)
            }
        }
        migrator.registerMigration("v5_agent_access") { db in
            try db.alter(table: "tasks") { t in
                t.add(column: "revision", .integer).notNull().defaults(to: 1)
                t.add(column: "updated_at", .datetime)
            }
            try db.execute(sql: "UPDATE tasks SET updated_at = created_at WHERE updated_at IS NULL")

            try db.alter(table: "session_logs") { t in
                t.add(column: "source", .text).notNull().defaults(to: "timer")
                t.add(column: "duration_origin", .text).notNull().defaults(to: "observed")
                t.add(column: "recorded_at", .datetime)
                t.add(column: "source_client", .text)
                t.add(column: "external_reference", .text)
                t.add(column: "idempotency_key", .text)
                t.add(column: "revision", .integer).notNull().defaults(to: 1)
            }
            try db.execute(sql: "UPDATE session_logs SET recorded_at = timestamp WHERE recorded_at IS NULL")

            try db.create(table: "activity_revisions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("activity_id", .text).notNull().references("session_logs", onDelete: .cascade)
                t.column("revision", .integer).notNull()
                t.column("changed_at", .datetime).notNull()
                t.column("source_client", .text)
                t.column("reason", .text).notNull()
                t.column("prior_values", .text).notNull()
                t.uniqueKey(["activity_id", "revision"])
            }
            try db.create(table: "agent_operation_results") { t in
                t.column("source_client", .text).notNull()
                t.column("idempotency_key", .text).notNull()
                t.column("operation", .text).notNull()
                t.column("response_json", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.primaryKey(["source_client", "idempotency_key", "operation"])
            }
            try db.create(index: "idx_tasks_updated_revision", on: "tasks", columns: ["updated_at", "revision"])
            try db.create(index: "idx_logs_source_recorded", on: "session_logs", columns: ["source", "recorded_at"])
            try db.create(index: "idx_logs_task_timestamp", on: "session_logs", columns: ["task_id", "timestamp"])
            try db.create(index: "idx_activity_revisions_activity", on: "activity_revisions", columns: ["activity_id", "revision"])
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_logs_idempotency
                ON session_logs(source_client, idempotency_key)
                WHERE idempotency_key IS NOT NULL
                """)
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_logs_external_reference
                ON session_logs(source, external_reference)
                WHERE external_reference IS NOT NULL
                """)
        }
        migrator.registerMigration("v6_agent_request_fingerprint") { db in
            try db.alter(table: "agent_operation_results") { t in
                t.add(column: "request_fingerprint", .text)
            }
        }
        return migrator
    }

    private func migrateFromUserDefaults() throws {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "is_migrated_to_sqlite_v1"),
              let state = defaults.string(forKey: "pomodoroState"),
              let data = state.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        try dbPool.write { db in
            if let tasks = (json["tasks"] as? [String: Any])?["tasks"] as? [[String: Any]] {
                for task in tasks {
                    let created = Date(timeIntervalSince1970: (task["createdAt"] as? Double ?? Date().timeIntervalSince1970 * 1000) / 1000)
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO tasks
                        (id, title, tag, estimated_pomos, completed_pomos, is_completed, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [
                            task["id"] as? String ?? UUID().uuidString,
                            task["title"] as? String ?? "Untitled",
                            task["tag"] as? String,
                            task["estimatedPomos"] as? Int ?? 1,
                            task["completedPomos"] as? Int ?? 0,
                            task["isCompleted"] as? Bool ?? false,
                            created, created
                        ])
                }
            }
            if let logs = (json["stats"] as? [String: Any])?["logs"] as? [[String: Any]] {
                for log in logs {
                    let timestamp = Date(timeIntervalSince1970: (log["timestamp"] as? Double ?? Date().timeIntervalSince1970 * 1000) / 1000)
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO session_logs
                        (id, task_id, task_title, tag, duration_seconds, is_completion, timestamp, recorded_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [
                            log["id"] as? String ?? UUID().uuidString,
                            log["taskId"] as? String,
                            log["taskTitle"] as? String,
                            log["tag"] as? String,
                            log["durationSeconds"] as? Int ?? 0,
                            log["isCompletion"] as? Bool ?? false,
                            timestamp, timestamp
                        ])
                }
            }
        }
        defaults.set(true, forKey: "is_migrated_to_sqlite_v1")
    }
}
