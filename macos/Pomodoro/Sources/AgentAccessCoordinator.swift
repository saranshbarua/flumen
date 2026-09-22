import Foundation
import AppKit
import UserNotifications
import FlumenIPC
import FlumenCore

final class AgentAccessCoordinator: @unchecked Sendable {
    static let shared = AgentAccessCoordinator()

    private let repository = AppRepository()
    private let settingsKey = "flumenAgentAccessSettings"
    private let lock = NSLock()
    private let mutationGate = MutationGate()
    private var server: UnixSocketServer?
    private var settings = AgentAccessSettings()
    private var connections: [String: ConnectedClient] = [:]
    private var pendingProposals: [String: PendingProposal] = [:]
    private var pendingTimerCommands: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private weak var bridge: Bridge?

    private actor MutationGate {
        func run<T: Sendable>(_ work: @Sendable () async throws -> T) async rethrows -> T {
            try await work()
        }
    }

    struct AgentAccessSettings: Codable, Equatable {
        var enabled = false
        var readFocusData = true
        var allowProposals = true
        var privacyAcknowledged = false
        var consentVersion = 0
        var skipConsentPrompt = false
    }

    private struct ConnectedClient {
        let id: String
        let name: String
        let version: String?
        let connectedAt: Date
        var lastActivityAt: Date
    }

    private struct PendingProposal {
        let request: IPCRequest
        let createdAt: Date
        let expiresAt: Date
        let continuation: CheckedContinuation<JSONValue, Error>
        let summary: [String: Any]
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode(AgentAccessSettings.self, from: data) {
            settings = decoded
        }
    }

    func attach(bridge: Bridge) {
        self.bridge = bridge
        if settings.enabled {
            do { try startServer() } catch {
                print("AgentAccessCoordinator: Failed to restore listener: \(error)")
            }
        }
        pushSettings()
        pushConnectionStatus()
    }

    // MARK: - Bridge-facing API

    func handleBridgeAction(_ action: String, body: [String: Any]) -> Bool {
        switch action {
        case "getAgentAccessSettings":
            pushSettings()
            return true
        case "setAgentAccessSettings":
            let payload = body["settings"] as? [String: Any] ?? body
            applySettings(payload)
            return true
        case "getAgentConnectionStatus":
            pushConnectionStatus()
            return true
        case "getAgentConnectionDetails":
            pushConnectionDetails()
            return true
        case "retryAgentAccess":
            do {
                try restartServerIfNeeded()
                pushConnectionStatus(status: settings.enabled ? "ready" : "off")
            } catch {
                pushConnectionStatus(status: "error", error: error.localizedDescription)
            }
            return true
        case "agentAddToCursor":
            let link = cursorDeeplink()
            copyToPasteboard(link)
            if let url = URL(string: link) {
                NSWorkspace.shared.open(url)
            }
            bridge?.sendToJS(action: "agentAccessActionResult", data: [
                "action": "addToCursor",
                "success": true,
                "message": "Opened Cursor install link. The configuration was also copied."
            ])
            return true
        case "agentCopyConfiguration":
            copyToPasteboard(mcpConfigurationJSON())
            bridge?.sendToJS(action: "agentAccessActionResult", data: [
                "action": "copyConfiguration",
                "success": true,
                "message": "MCP configuration copied."
            ])
            return true
        case "agentCopyServerCommand":
            copyToPasteboard(helperPath())
            bridge?.sendToJS(action: "agentAccessActionResult", data: [
                "action": "copyServerCommand",
                "success": true,
                "message": "Server command copied."
            ])
            return true
        case "agentOpenSetupGuide":
            if let url = URL(string: "https://github.com/saranshbarua/flumen/blob/main/docs/MCP-SETUP.md") {
                NSWorkspace.shared.open(url)
            }
            return true
        case "agentTestConnection":
            pushConnectionDetails()
            bridge?.sendToJS(action: "agentAccessActionResult", data: [
                "action": "testConnection",
                "success": settings.enabled && server != nil,
                "message": settings.enabled
                    ? "Agent Access is ready. Connect your MCP client using the copied configuration."
                    : "Turn on Agent Access before testing."
            ])
            return true
        case "agentDisconnectSessions":
            disconnectSessions()
            bridge?.sendToJS(action: "agentAccessActionResult", data: [
                "action": "disconnectSessions",
                "success": true,
                "message": "Active agent sessions were cleared."
            ])
            return true
        case "getPendingAgentProposals":
            let summaries = pendingProposals.values.map(\.summary)
            bridge?.sendToJS(action: "pendingAgentProposals", data: ["proposals": summaries])
            return true
        case "agentProposalResult":
            guard let requestId = body["requestId"] as? String else { return true }
            let approved = body["approved"] as? Bool ?? false
            resolveProposal(requestId: requestId, approved: approved, reason: body["reason"] as? String)
            return true
        case "agentCommandResult":
            guard let requestId = body["requestId"] as? String else { return true }
            completeTimerCommand(requestId: requestId, body: body)
            return true
        default:
            return false
        }
    }

    // MARK: - Settings / server lifecycle

    private func applySettings(_ payload: [String: Any]) {
        lock.lock()
        var next = settings
        if let enabled = payload["enabled"] as? Bool { next.enabled = enabled }
        if let read = payload["readFocusData"] as? Bool { next.readFocusData = read }
        if let proposals = payload["allowProposals"] as? Bool { next.allowProposals = proposals }
        if let privacy = payload["privacyAcknowledged"] as? Bool { next.privacyAcknowledged = privacy }
        if let consentVersion = payload["consentVersion"] as? Int { next.consentVersion = consentVersion }
        else if let consentVersion = payload["consentVersion"] as? Double { next.consentVersion = Int(consentVersion) }
        if let skip = payload["skipConsentPrompt"] as? Bool { next.skipConsentPrompt = skip }
        let previous = settings
        settings = next
        lock.unlock()
        persistSettings()

        do {
            if next.enabled && !previous.enabled {
                try startServer()
                pushConnectionStatus(status: "ready")
            } else if !next.enabled && previous.enabled {
                stopServer()
                failAllPending(code: "agent_access_disabled", message: "Agent Access was turned off.")
                pushConnectionStatus(status: "off")
            } else if next.enabled {
                try restartServerIfNeeded()
                pushConnectionStatus()
            }
        } catch {
            pushConnectionStatus(status: "error", error: error.localizedDescription)
        }
        pushSettings()
    }

    private func persistSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
    }

    private func startServer() throws {
        stopServer()
        let path = FlumenSocketPath.current()
        let server = UnixSocketServer(path: path) { [weak self] request in
            await self?.handle(request) ?? IPCResponse(
                requestId: request.requestId,
                error: IPCStructuredError(code: "internal_error", message: "Agent Access coordinator unavailable.")
            )
        }
        try server.start()
        self.server = server
    }

    private func restartServerIfNeeded() throws {
        guard settings.enabled else { return }
        if server == nil { try startServer() }
    }

    private func stopServer() {
        server?.stop()
        server = nil
        lock.lock()
        connections.removeAll()
        lock.unlock()
    }

    // MARK: - IPC handling

    private func handle(_ request: IPCRequest) async -> IPCResponse {
        touchConnection(request.client)
        do {
            let result = try await dispatch(request)
            return IPCResponse(requestId: request.requestId, result: result)
        } catch let error as IPCStructuredError {
            return IPCResponse(requestId: request.requestId, error: error)
        } catch {
            return IPCResponse(
                requestId: request.requestId,
                error: IPCStructuredError(code: "internal_error", message: error.localizedDescription)
            )
        }
    }

    private func dispatch(_ request: IPCRequest) async throws -> JSONValue {
        guard settings.enabled else {
            throw IPCStructuredError(
                code: "agent_access_disabled",
                message: "Agent Access is turned off in Flumen.",
                retryable: false
            )
        }

        let readOps: Set<String> = [
            "get_focus_status", "get_today_summary", "get_active_task", "get_server_status",
            "list_tasks", "list_projects", "query_focus_activity",
            "get_focus_summary", "get_estimation_context", "ping"
        ]
        let writeOps: Set<String> = [
            "log_time", "create_task", "update_task", "set_active_task",
            "begin_focus", "pause_focus", "finish_focus", "complete_task", "correct_time_entry"
        ]

        if readOps.contains(request.operation) {
            guard settings.readFocusData else {
                throw IPCStructuredError(code: "permission_denied", message: "Read Focus Data is disabled.")
            }
            return try await handleRead(request)
        }

        if writeOps.contains(request.operation) {
            guard settings.allowProposals else {
                throw IPCStructuredError(
                    code: "permission_denied",
                    message: "Agent proposals are turned off in Flumen. Enable them in Settings → Agent Access."
                )
            }
            if let key = request.idempotencyKey,
               let cached = try repository.cachedOperation(client: request.client.name, key: key, operation: request.operation) {
                return cached
            }
            return try await proposeAndExecute(request)
        }

        throw IPCStructuredError(code: "unsupported_operation", message: "Unsupported operation: \(request.operation)")
    }

    private func handleRead(_ request: IPCRequest) async throws -> JSONValue {
        switch request.operation {
        case "ping", "get_server_status":
            return .object([
                "ok": .bool(true),
                "app": .string("Flumen"),
                "agentAccessEnabled": .bool(settings.enabled),
                "protocolVersion": .string(String(FlumenIPC.protocolVersion)),
                "helperPath": .string(helperPath())
            ])
        case "get_focus_status":
            return try await timerCommand(["command": "get_status", "confirmed": false])
        case "get_active_task":
            let status = try await timerCommand(["command": "get_status", "confirmed": false])
            return status["activeTask"] ?? .null
        case "get_today_summary":
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: Date())
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? Date()
            return JSONValue.from(any: try repository.focusSummary(start: start, end: end))
        case "list_tasks":
            let includeCompleted = request.parameters["includeCompleted"]?.boolValue ?? false
            let limit = request.parameters["limit"]?.intValue ?? 100
            return .array(try repository.listTasks(includeCompleted: includeCompleted, limit: limit).map(JSONValue.from(any:)))
        case "list_projects":
            return .array(try repository.listProjects().map(JSONValue.from(any:)))
        case "query_focus_activity":
            let start = try dateParam(request.parameters["start"], name: "start")
            let end = try dateParam(request.parameters["end"], name: "end")
            let rows = try repository.queryActivity(
                start: start,
                end: end,
                projectId: request.parameters["projectId"]?.stringValue,
                taskId: request.parameters["taskId"]?.stringValue,
                source: request.parameters["source"]?.stringValue,
                limit: request.parameters["limit"]?.intValue ?? 200
            )
            return .array(rows.map(JSONValue.from(any:)))
        case "get_focus_summary":
            let start = try dateParam(request.parameters["start"], name: "start")
            let end = try dateParam(request.parameters["end"], name: "end")
            return JSONValue.from(any: try repository.focusSummary(start: start, end: end))
        case "get_estimation_context":
            return JSONValue.from(any: try repository.estimationContext(
                query: request.parameters["query"]?.stringValue,
                projectId: request.parameters["projectId"]?.stringValue,
                limit: request.parameters["limit"]?.intValue ?? 20
            ))
        default:
            throw IPCStructuredError(code: "unsupported_operation", message: request.operation)
        }
    }

    private func proposeAndExecute(_ request: IPCRequest) async throws -> JSONValue {
        let summary = proposalSummary(for: request)
        return try await withCheckedThrowingContinuation { continuation in
            let expiresAt = Date().addingTimeInterval(120)
            lock.lock()
            pendingProposals[request.requestId] = PendingProposal(
                request: request,
                createdAt: Date(),
                expiresAt: expiresAt,
                continuation: continuation,
                summary: summary
            )
            lock.unlock()

            DispatchQueue.main.async { [weak self] in
                self?.bridge?.sendToJS(action: "agentProposal", data: summary)
                self?.notifyProposal(summary)
                if let appDelegate = NSApp.delegate as? AppDelegate {
                    appDelegate.statusBarController?.toggleWindow(nil)
                }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + 120) { [weak self] in
                self?.resolveProposal(requestId: request.requestId, approved: false, reason: "expired")
            }
        }
    }

    private func resolveProposal(requestId: String, approved: Bool, reason: String?) {
        lock.lock()
        guard let pending = pendingProposals.removeValue(forKey: requestId) else {
            lock.unlock()
            return
        }
        lock.unlock()

        guard approved else {
            pending.continuation.resume(throwing: IPCStructuredError(
                code: reason == "expired" ? "proposal_expired" : "user_declined",
                message: reason == "expired"
                    ? "The Flumen confirmation expired before approval."
                    : "The user declined the proposal in Flumen."
            ))
            return
        }

        Task {
            do {
                let result = try await mutationGate.run {
                    try await self.executeApproved(pending.request)
                }
                if let key = pending.request.idempotencyKey {
                    try? repository.storeOperation(
                        client: pending.request.client.name,
                        key: key,
                        operation: pending.request.operation,
                        result: result
                    )
                }
                pending.continuation.resume(returning: result)
            } catch {
                pending.continuation.resume(throwing: error)
            }
        }
    }

    private func executeApproved(_ request: IPCRequest) async throws -> JSONValue {
        let params = request.parameters
        switch request.operation {
        case "log_time":
            let title = try requiredString(params["title"], name: "title")
            let duration = try requiredInt(params["durationSeconds"], name: "durationSeconds")
            let startedAt = (try? dateParam(params["startedAt"], name: "startedAt")) ?? Date().addingTimeInterval(TimeInterval(-duration))
            let result = try repository.logActivity(
                duration: duration,
                taskId: params["taskId"]?.stringValue,
                taskTitle: title,
                tag: params["tag"]?.stringValue,
                projectId: params["projectId"]?.stringValue,
                estimatedPomos: params["estimatedPomos"]?.intValue ?? 1,
                snapshotFocusDuration: params["snapshotFocusDuration"]?.intValue ?? 1500,
                isCompletion: false,
                timestamp: startedAt,
                source: "agent",
                durationOrigin: params["durationOrigin"]?.stringValue ?? "user_supplied",
                sourceClient: request.client.name,
                externalReference: params["externalReference"]?.stringValue,
                idempotencyKey: request.idempotencyKey
            )
            refreshReports()
            return JSONValue.from(any: result)

        case "create_task":
            let id = UUID().uuidString
            try repository.addTask(
                id: id,
                title: try requiredString(params["title"], name: "title"),
                tag: params["tag"]?.stringValue,
                projectId: params["projectId"]?.stringValue,
                estimatedPomos: params["estimatedPomos"]?.intValue ?? 1
            )
            refreshShelf()
            return .object(["id": .string(id)])

        case "update_task":
            let updated = try repository.updateTask(
                id: try requiredString(params["id"], name: "id"),
                title: try requiredString(params["title"], name: "title"),
                tag: params["tag"]?.stringValue,
                projectId: params["projectId"]?.stringValue,
                estimatedPomos: try requiredInt(params["estimatedPomos"], name: "estimatedPomos"),
                expectedRevision: try requiredInt(params["expectedRevision"], name: "expectedRevision")
            )
            refreshShelf()
            return JSONValue.from(any: updated)

        case "set_active_task":
            return try await timerCommand([
                "command": "set_active_task",
                "confirmed": true,
                "arguments": ["taskId": params["taskId"]?.stringValue as Any]
            ])

        case "begin_focus":
            var arguments: [String: Any] = [:]
            if let taskId = params["taskId"]?.stringValue { arguments["taskId"] = taskId }
            if let title = params["title"]?.stringValue {
                arguments["title"] = title
                arguments["estimatedPomos"] = params["estimatedPomos"]?.intValue ?? 1
                if let projectId = params["projectId"]?.stringValue { arguments["projectId"] = projectId }
                if let tag = params["tag"]?.stringValue { arguments["tag"] = tag }
            }
            return try await timerCommand([
                "command": "begin_focus",
                "confirmed": true,
                "arguments": arguments
            ])

        case "pause_focus":
            return try await timerCommand(["command": "pause_focus", "confirmed": true])

        case "finish_focus":
            let result = try await timerCommand(["command": "finish_focus", "confirmed": true])
            if params["completeTask"]?.boolValue == true {
                _ = try? await timerCommand(["command": "complete_task", "confirmed": true])
            }
            return result

        case "complete_task":
            if let revision = params["expectedRevision"]?.intValue {
                let updated = try repository.completeTask(
                    id: try requiredString(params["taskId"], name: "taskId"),
                    expectedRevision: revision
                )
                refreshShelf()
                return JSONValue.from(any: updated)
            }
            let result = try await timerCommand([
                "command": "complete_task",
                "confirmed": true,
                "arguments": ["taskId": params["taskId"]?.stringValue as Any]
            ])
            refreshShelf()
            return result

        case "correct_time_entry":
            let updated = try repository.correctTimeEntry(
                id: try requiredString(params["id"], name: "id"),
                expectedRevision: try requiredInt(params["expectedRevision"], name: "expectedRevision"),
                duration: params["durationSeconds"]?.intValue,
                timestamp: try? dateParam(params["startedAt"], name: "startedAt"),
                title: params["title"]?.stringValue,
                projectId: params["projectId"]?.stringValue,
                reason: try requiredString(params["reason"], name: "reason"),
                sourceClient: request.client.name
            )
            refreshReports()
            return JSONValue.from(any: updated)

        default:
            throw IPCStructuredError(code: "unsupported_operation", message: request.operation)
        }
    }

    // MARK: - Timer bridge

    private func timerCommand(_ payload: [String: Any]) async throws -> JSONValue {
        let requestId = UUID().uuidString
        var command = payload
        command["requestId"] = requestId
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pendingTimerCommands[requestId] = continuation
            lock.unlock()
            DispatchQueue.main.async { [weak self] in
                self?.bridge?.sendToJS(action: "agentCommand", data: command)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.failTimerCommand(requestId: requestId, message: "Timed out waiting for Flumen timer state.")
            }
        }
    }

    private func completeTimerCommand(requestId: String, body: [String: Any]) {
        lock.lock()
        guard let continuation = pendingTimerCommands.removeValue(forKey: requestId) else {
            lock.unlock()
            return
        }
        lock.unlock()

        let resultPayload = body["result"] as? [String: Any] ?? body
        if let ok = resultPayload["ok"] as? Bool, ok == false {
            let error = resultPayload["error"] as? [String: Any]
            continuation.resume(throwing: IPCStructuredError(
                code: error?["code"] as? String ?? "timer_command_failed",
                message: error?["message"] as? String ?? "Timer command failed."
            ))
            return
        }
        let data = resultPayload["data"] as? [String: Any] ?? resultPayload
        continuation.resume(returning: JSONValue.from(any: data))
    }

    private func failTimerCommand(requestId: String, message: String) {
        lock.lock()
        guard let continuation = pendingTimerCommands.removeValue(forKey: requestId) else {
            lock.unlock()
            return
        }
        lock.unlock()
        continuation.resume(throwing: IPCStructuredError(code: "timer_unavailable", message: message, retryable: true))
    }

    private func failAllPending(code: String, message: String) {
        lock.lock()
        let proposals = pendingProposals
        pendingProposals.removeAll()
        let timers = pendingTimerCommands
        pendingTimerCommands.removeAll()
        lock.unlock()
        for proposal in proposals.values {
            proposal.continuation.resume(throwing: IPCStructuredError(code: code, message: message))
        }
        for continuation in timers.values {
            continuation.resume(throwing: IPCStructuredError(code: code, message: message))
        }
    }

    // MARK: - UI updates

    private func touchConnection(_ client: IPCClientMetadata) {
        lock.lock()
        let now = Date()
        pruneStaleConnectionsLocked(now: now)
        if var existing = connections[client.id] {
            existing.lastActivityAt = now
            connections[client.id] = existing
        } else {
            connections[client.id] = ConnectedClient(
                id: client.id,
                name: client.name,
                version: client.version,
                connectedAt: now,
                lastActivityAt: now
            )
        }
        let snapshot = Array(connections.values)
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.pushConnectionStatus(status: snapshot.isEmpty ? "ready" : "connected", connections: snapshot)
        }
    }

    private func pruneStaleConnectionsLocked(now: Date = Date()) {
        connections = connections.filter { _, client in
            now.timeIntervalSince(client.lastActivityAt) < 90
        }
    }

    private func disconnectSessions() {
        lock.lock()
        connections.removeAll()
        lock.unlock()
        failAllPending(code: "session_disconnected", message: "Agent sessions were disconnected in Flumen.")
        pushConnectionStatus(status: settings.enabled ? "ready" : "off")
    }

    private func refreshShelf() {
        do {
            let data = try repository.loadInitialData()
            bridge?.sendToJS(action: "db_initialData", data: data)
        } catch {
            print("AgentAccessCoordinator: Failed to refresh shelf: \(error)")
        }
    }

    private func refreshReports() {
        do {
            let data = try repository.reports()
            bridge?.sendToJS(action: "db_reportsData", data: data)
        } catch {
            print("AgentAccessCoordinator: Failed to refresh reports: \(error)")
        }
    }

    private func notifyProposal(_ summary: [String: Any]) {
        let title = summary["title"] as? String ?? "Agent proposal"
        let body = summary["summary"] as? String ?? "An agent is waiting for confirmation in Flumen."
        bridge?.sendToJS(action: "showNotification", data: ["title": title, "body": body])
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "agent-proposal-\(summary["requestId"] as? String ?? UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private func pushSettings() {
        bridge?.sendToJS(action: "agentAccessSettings", data: [
            "enabled": settings.enabled,
            "readFocusData": settings.readFocusData,
            "allowProposals": settings.allowProposals,
            "privacyAcknowledged": settings.privacyAcknowledged,
            "consentVersion": settings.consentVersion,
            "skipConsentPrompt": settings.skipConsentPrompt
        ])
    }

    private func pushConnectionStatus(status: String? = nil, error: String? = nil, connections override: [ConnectedClient]? = nil) {
        lock.lock()
        let values = override ?? Array(connections.values)
        let enabled = settings.enabled
        lock.unlock()
        let inferred: String
        if error != nil { inferred = "error" }
        else if !enabled { inferred = "off" }
        else if values.isEmpty { inferred = "ready" }
        else { inferred = "connected" }
        bridge?.sendToJS(action: "agentConnectionStatus", data: [
            "status": status ?? inferred,
            "enabled": enabled,
            "error": error as Any,
            "connections": values.map {
                [
                    "id": $0.id,
                    "name": $0.name,
                    "version": $0.version as Any,
                    "connectedAt": $0.connectedAt.timeIntervalSince1970 * 1000,
                    "active": true
                ]
            }
        ])
    }

    private func pushConnectionDetails() {
        bridge?.sendToJS(action: "agentConnectionDetails", data: [
            "transport": "Local stdio",
            "server": "Flumen MCP",
            "availability": "While Flumen is open",
            "helperPath": helperPath(),
            "socketPath": FlumenSocketPath.current(),
            "protocolVersion": FlumenIPC.protocolVersion,
            "enabled": settings.enabled
        ])
    }

    private func proposalSummary(for request: IPCRequest) -> [String: Any] {
        let operationTitle = humanTitle(for: request.operation)
        let taskInfo = taskSummary(for: request)
        let resolvedProjectName = request.parameters["projectId"]?.stringValue.flatMap(projectName(for:))

        var summary: [String: Any] = [
            "requestId": request.requestId,
            "action": request.operation,
            "expiresAt": Date().addingTimeInterval(120).timeIntervalSince1970 * 1000,
            "provenance": [
                "source": "agent",
                "origin": request.client.name
            ]
        ]
        if !taskInfo.isEmpty {
            summary["task"] = taskInfo
        }
        if let duration = request.parameters["durationSeconds"]?.intValue {
            summary["durationSeconds"] = duration
        }
        if let projectId = request.parameters["projectId"]?.stringValue {
            if let resolvedProjectName {
                summary["project"] = ["id": projectId, "name": resolvedProjectName]
            } else {
                summary["project"] = projectId
            }
        }
        let taskTitle = taskInfo["title"] as? String
        summary["title"] = proposalNotificationTitle(
            operationTitle: operationTitle,
            taskTitle: taskTitle
        )
        summary["summary"] = proposalNotificationBody(
            clientName: request.client.name,
            operation: request.operation,
            operationTitle: operationTitle,
            projectName: resolvedProjectName ?? taskInfo["projectName"] as? String,
            durationSeconds: request.parameters["durationSeconds"]?.intValue,
            reason: request.parameters["reason"]?.stringValue
        )
        summary["sideEffects"] = sideEffects(for: request.operation)
        return summary
    }

    private func taskSummary(for request: IPCRequest) -> [String: Any] {
        var info: [String: Any] = [:]
        if let title = request.parameters["title"]?.stringValue {
            info["title"] = title
        }

        switch request.operation {
        case "correct_time_entry":
            if let activityId = request.parameters["id"]?.stringValue {
                info["id"] = activityId
                if info["title"] == nil, let activity = try? repository.activity(byId: activityId) {
                    info["title"] = activity["taskTitle"] as? String
                    if let projectId = activity["projectId"] as? String {
                        info["projectName"] = projectName(for: projectId)
                    }
                }
            }
        case "update_task":
            if let taskId = request.parameters["id"]?.stringValue {
                info["id"] = taskId
                if info["title"] == nil {
                    info["title"] = taskTitle(for: taskId)
                }
            }
        default:
            if let taskId = request.parameters["taskId"]?.stringValue {
                info["id"] = taskId
                if info["title"] == nil {
                    info["title"] = taskTitle(for: taskId)
                }
            }
        }
        return info
    }

    private func taskTitle(for id: String) -> String? {
        guard let tasks = try? repository.listTasks(includeCompleted: true, limit: 500) else { return nil }
        return tasks.first(where: { ($0["id"] as? String) == id })?["title"] as? String
    }

    private func projectName(for id: String) -> String? {
        guard let projects = try? repository.listProjects() else { return nil }
        return projects.first(where: { ($0["id"] as? String) == id })?["name"] as? String
    }

    private func proposalNotificationTitle(operationTitle: String, taskTitle: String?) -> String {
        if let taskTitle, !taskTitle.isEmpty {
            return truncated(taskTitle, maxLength: 120)
        }
        return operationTitle
    }

    private func proposalNotificationBody(
        clientName: String,
        operation: String,
        operationTitle: String,
        projectName: String?,
        durationSeconds: Int?,
        reason: String? = nil
    ) -> String {
        var segments = [clientName, operationTitle]
        if let projectName, !projectName.isEmpty {
            segments.append(projectName)
        }
        if let durationSeconds, durationSeconds > 0 {
            let duration = formatProposalDuration(durationSeconds)
            segments.append(operation == "correct_time_entry" ? "→ \(duration)" : duration)
        }
        if operation == "correct_time_entry", let reason {
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                segments.append(truncated(trimmed, maxLength: 72))
            }
        }
        return segments.joined(separator: " · ")
    }

    private func formatProposalDuration(_ seconds: Int) -> String {
        let minutes = max(1, Int(round(Double(seconds) / 60)))
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private func truncated(_ string: String, maxLength: Int) -> String {
        guard string.count > maxLength else { return string }
        return String(string.prefix(maxLength - 1)) + "…"
    }

    private func humanTitle(for operation: String) -> String {
        switch operation {
        case "log_time": return "Log time"
        case "create_task": return "Create task"
        case "update_task": return "Update task"
        case "set_active_task": return "Set active task"
        case "begin_focus": return "Begin focus"
        case "pause_focus": return "Pause focus"
        case "finish_focus": return "Finish focus"
        case "complete_task": return "Complete task"
        case "correct_time_entry": return "Correct time entry"
        default: return operation
        }
    }

    private func sideEffects(for operation: String) -> [String] {
        switch operation {
        case "log_time":
            return ["Adds recorded focus time", "Does not count as a completed focus cycle"]
        case "begin_focus":
            return ["Starts the Flumen focus timer"]
        case "finish_focus":
            return ["Stops the active timer and advances the session"]
        case "correct_time_entry":
            return ["Updates a completed activity", "Keeps revision history"]
        default:
            return ["Requires your confirmation before changing Flumen"]
        }
    }

    // MARK: - Setup helpers

    private func helperPath() -> String {
        if let url = Bundle.main.builtInPlugInsURL?
            .deletingLastPathComponent()
            .appendingPathComponent("Helpers/flumen-mcp") {
            let path = url.path
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        let fallback = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/flumen-mcp")
            .path
        if FileManager.default.isExecutableFile(atPath: fallback) { return fallback }
        return "/Applications/Flumen.app/Contents/Helpers/flumen-mcp"
    }

    private func mcpConfigurationJSON() -> String {
        let config: [String: Any] = [
            "mcpServers": [
                "flumen": [
                    "command": helperPath(),
                    "args": [] as [String],
                    "env": [
                        "FLUMEN_BUNDLE_ID": Bundle.main.bundleIdentifier ?? "com.saranshbarua.flumen"
                    ]
                ]
            ]
        ]
        let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private func cursorDeeplink() -> String {
        let config: [String: Any] = [
            "command": helperPath(),
            "args": [] as [String],
            "env": [
                "FLUMEN_BUNDLE_ID": Bundle.main.bundleIdentifier ?? "com.saranshbarua.flumen"
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: config)
        let encoded = data.base64EncodedString()
        return "cursor://anysphere.cursor-deeplink/mcp/install?name=flumen&config=\(encoded)"
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

private func dateParam(_ value: JSONValue?, name: String) throws -> Date {
    guard let raw = value?.stringValue else {
        throw IPCStructuredError(code: "validation_error", message: "\(name) is required.")
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: raw) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: raw) else {
        throw IPCStructuredError(code: "validation_error", message: "\(name) must be an ISO-8601 timestamp.")
    }
    return date
}

private func requiredString(_ value: JSONValue?, name: String) throws -> String {
    guard let value = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        throw IPCStructuredError(code: "validation_error", message: "\(name) is required.")
    }
    return value
}

private func requiredInt(_ value: JSONValue?, name: String) throws -> Int {
    guard let value = value?.intValue else {
        throw IPCStructuredError(code: "validation_error", message: "\(name) is required.")
    }
    return value
}
