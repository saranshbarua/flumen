import Foundation
import AppKit
import UserNotifications
import FlumenIPC
import FlumenCore

final class AgentAccessCoordinator: @unchecked Sendable {
    static let shared = AgentAccessCoordinator()

    /// A live helper heartbeats every 3s; three missed beats means it is gone.
    private static let connectionIdleTimeout: TimeInterval = 10
    private static let timerCommandTimeout: TimeInterval = 10
    private static let selfTestClientID = "flumen-self-test"

    private let repository = AppRepository()
    private let settingsKey = "flumenAgentAccessSettings"
    private let lock = NSLock()
    private let mutationQueue = SerialMutationQueue()
    private let proposals = ProposalRegistry()
    private let inFlight = InFlightRequests()
    private var server: UnixSocketServer?
    private var settings = AgentAccessSettings()
    private var connections: [String: ConnectedClient] = [:]
    private var revokedClientIds: Set<String> = []
    private var pendingTimerCommands: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var connectionMonitor: DispatchSourceTimer?
    private weak var bridge: Bridge?

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
        let processID: Int32?
        let connectedAt: Date
        var lastActivityAt: Date
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode(AgentAccessSettings.self, from: data) {
            settings = decoded
        }
    }

    func attach(bridge: Bridge) {
        self.bridge = bridge
        pushSettings()
        if currentSettings().enabled {
            do {
                try startServer()
                pushConnectionStatus()
            } catch {
                print("AgentAccessCoordinator: Failed to restore listener: \(error)")
                pushConnectionStatus(status: "error", error: error.localizedDescription)
            }
        } else {
            pushConnectionStatus()
        }
    }

    private func currentSettings() -> AgentAccessSettings {
        lock.lock()
        defer { lock.unlock() }
        return settings
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
                pushConnectionStatus()
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
            sendActionResult("addToCursor", success: true, message: "Opened Cursor install link. The configuration was also copied.")
            return true
        case "agentCopyConfiguration":
            copyToPasteboard(mcpConfigurationJSON())
            sendActionResult("copyConfiguration", success: true, message: "MCP configuration copied.")
            return true
        case "agentCopyServerCommand":
            copyToPasteboard(helperPath())
            sendActionResult("copyServerCommand", success: true, message: "Server command copied.")
            return true
        case "agentOpenSetupGuide":
            if let url = URL(string: "https://github.com/saranshbarua/flumen/blob/main/docs/MCP-SETUP.md") {
                NSWorkspace.shared.open(url)
            }
            return true
        case "agentTestConnection":
            pushConnectionDetails()
            testConnection()
            return true
        case "agentDisconnectSessions":
            let count = disconnectSessions()
            sendActionResult(
                "disconnectSessions",
                success: true,
                message: count == 0
                    ? "No agent sessions were connected."
                    : "Disconnected \(count) agent session\(count == 1 ? "" : "s"). Restart Flumen MCP in your agent to reconnect."
            )
            return true
        case "getPendingAgentProposals":
            bridge?.sendToJS(action: "pendingAgentProposals", data: ["proposals": proposals.pending().map(\.summary)])
            return true
        case "agentProposalResult":
            guard let requestId = body["requestId"] as? String else { return true }
            let approved = body["approved"] as? Bool ?? false
            if !proposals.resolve(requestId: requestId, approved: approved, reason: body["reason"] as? String) {
                settleProposalUI(
                    requestId: requestId,
                    outcome: "unavailable",
                    message: "This request is no longer waiting. The agent may have stopped waiting, or Agent Access was turned off."
                )
            }
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
                if previous.allowProposals && !next.allowProposals {
                    failAllPending(code: "permission_denied", message: "Agent proposals were turned off in Flumen.")
                }
                try restartServerIfNeeded()
                pushConnectionStatus()
            }
        } catch {
            pushConnectionStatus(status: "error", error: error.localizedDescription)
        }
        pushSettings()
    }

    private func persistSettings() {
        if let data = try? JSONEncoder().encode(currentSettings()) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
    }

    private func startServer() throws {
        stopServer()
        let path = FlumenSocketPath.current()
        let server = UnixSocketServer(
            path: path,
            onClientDisconnect: { [weak self] requestId in
                self?.proposals.cancel(
                    requestId: requestId,
                    error: IPCStructuredError(code: "client_disconnected", message: "The agent stopped waiting for this confirmation.")
                )
            }
        ) { [weak self] request in
            await self?.handle(request) ?? IPCResponse(
                requestId: request.requestId,
                error: IPCStructuredError(code: "internal_error", message: "Agent Access coordinator unavailable.")
            )
        }
        try server.start()
        self.server = server
        startConnectionMonitor()
    }

    private func restartServerIfNeeded() throws {
        guard currentSettings().enabled else { return }
        if server == nil { try startServer() }
    }

    private func stopServer() {
        stopConnectionMonitor()
        server?.stop()
        server = nil
        lock.lock()
        connections.removeAll()
        revokedClientIds.removeAll()
        lock.unlock()
    }

    // MARK: - IPC handling

    private func handle(_ request: IPCRequest) async -> IPCResponse {
        if isRevoked(request.client.id) {
            return IPCResponse(
                requestId: request.requestId,
                error: IPCStructuredError(
                    code: "session_disconnected",
                    message: "Flumen disconnected this agent session. Restart Flumen MCP in your agent to reconnect."
                )
            )
        }
        if request.client.id != Self.selfTestClientID {
            touchConnection(request.client)
        }
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
        let current = currentSettings()
        guard current.enabled else {
            throw IPCStructuredError(
                code: "agent_access_disabled",
                message: "Agent Access is turned off in Flumen.",
                retryable: false
            )
        }

        let operation = request.operation
        if AgentOperationCatalog.session.contains(operation) {
            return serverStatus(current)
        }

        if AgentOperationCatalog.reads.contains(operation) {
            guard current.readFocusData else {
                throw IPCStructuredError(code: "permission_denied", message: "Read Focus Data is disabled.")
            }
            return try await handleRead(request)
        }

        if AgentOperationCatalog.isWrite(operation) {
            guard current.allowProposals else {
                throw IPCStructuredError(
                    code: "permission_denied",
                    message: "Agent proposals are turned off in Flumen. Enable them in Settings → Agent Access."
                )
            }
            guard let key = request.idempotencyKey else {
                return try await proposeAndExecute(request)
            }
            let client = request.client.name
            let fingerprint = AgentRequestFingerprint.make(operation: operation, parameters: request.parameters)
            if let cached = try repository.cachedOperation(client: client, key: key, operation: operation, fingerprint: fingerprint) {
                return cached
            }
            let inFlightKey = [client, operation, key].joined(separator: "\u{1F}")
            return try await inFlight.run(key: inFlightKey, fingerprint: fingerprint) {
                if let cached = try repository.cachedOperation(client: client, key: key, operation: operation, fingerprint: fingerprint) {
                    return cached
                }
                let result = try await proposeAndExecute(request)
                try? repository.storeOperation(client: client, key: key, operation: operation, fingerprint: fingerprint, result: result)
                return result
            }
        }

        throw IPCStructuredError(code: "unsupported_operation", message: "Unsupported operation: \(operation)")
    }

    private func serverStatus(_ current: AgentAccessSettings) -> JSONValue {
        .object([
            "ok": .bool(true),
            "app": .string("Flumen"),
            "agentAccessEnabled": .bool(current.enabled),
            "readFocusData": .bool(current.readFocusData),
            "allowProposals": .bool(current.allowProposals),
            "confirmationWindowSeconds": .number(FlumenIPC.confirmationWindow),
            "protocolVersion": .string(String(FlumenIPC.protocolVersion)),
            "helperPath": .string(helperPath())
        ])
    }

    private func handleRead(_ request: IPCRequest) async throws -> JSONValue {
        switch request.operation {
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
        case "get_activity":
            let id = try requiredString(request.parameters["id"], name: "id")
            guard let activity = try repository.activity(byId: id) else {
                throw IPCStructuredError(code: "not_found", message: "No activity exists with id \(id).")
            }
            return JSONValue.from(any: activity)
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

    // MARK: - Proposals

    private struct ProposalContext {
        var activeTask: [String: Any]?
        var completion: CompletionPlan?
    }

    /// The exact sessions a `complete_tasks` card shows; execution records this plan, not a recomputed one.
    private struct CompletionPlan: Sendable {
        let items: [AppRepository.TaskCompletionPlanItem]
        let sessionSeconds: Int
        let start: Date
        var sessionCount: Int { items.reduce(0) { $0 + $1.remainingSessions } }
        var totalSeconds: Int { sessionCount * sessionSeconds }
        var end: Date { start.addingTimeInterval(TimeInterval(totalSeconds)) }
    }

    private func proposeAndExecute(_ request: IPCRequest) async throws -> JSONValue {
        let requestId = request.requestId
        let context = try await buildContext(for: request)
        // Refuse anything that cannot apply before asking the person, so an agent retrying an
        // invalid action gets an immediate error instead of a stream of doomed approvals.
        try await preflight(request, context: context)
        let summary = proposalSummary(for: request, context: context)
        let completion = context.completion
        proposals.register(requestId: requestId, summary: summary, window: FlumenIPC.confirmationWindow)

        DispatchQueue.main.async { [weak self] in
            guard let self, self.proposals.isPending(requestId) else { return }
            self.bridge?.sendToJS(action: "agentProposal", data: summary)
            self.notifyProposal(summary)
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.statusBarController?.revealWindow()
            }
        }

        do {
            try await proposals.waitForDecision(requestId: requestId)
        } catch {
            settleProposalUI(requestId: requestId, outcome: Self.outcome(for: error), message: error.localizedDescription)
            throw error
        }

        do {
            let result = try await mutationQueue.run { [self] in
                try await self.executeApproved(request, completion: completion)
            }
            settleProposalUI(requestId: requestId, outcome: "applied", message: nil)
            return result
        } catch {
            settleProposalUI(requestId: requestId, outcome: "failed", message: error.localizedDescription)
            throw error
        }
    }

    private static func outcome(for error: Error) -> String {
        switch (error as? IPCStructuredError)?.code {
        case "user_declined": return "declined"
        case "proposal_expired": return "expired"
        default: return "cancelled"
        }
    }

    /// Tells the window a proposal is finished so it never shows an approvable card for a closed request.
    private func settleProposalUI(requestId: String, outcome: String, message: String?) {
        DispatchQueue.main.async { [weak self] in
            var data: [String: Any] = ["requestId": requestId, "outcome": outcome]
            if let message { data["message"] = message }
            self?.bridge?.sendToJS(action: "agentProposalSettled", data: data)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["agent-proposal-\(requestId)"])
        }
    }

    private func buildContext(for request: IPCRequest) async throws -> ProposalContext {
        var context = ProposalContext()
        switch request.operation {
        case "finish_focus" where request.parameters["completeTask"]?.boolValue == true:
            let status = try? await timerCommand(["command": "get_status", "confirmed": false])
            context.activeTask = status?["activeTask"]?.anyValue as? [String: Any]
        case "complete_tasks":
            context.completion = try await completionPlan(for: request)
        default:
            break
        }
        return context
    }

    private func completionPlan(for request: IPCRequest) async throws -> CompletionPlan {
        guard case .array(let entries)? = request.parameters["tasks"] else {
            throw IPCStructuredError(code: "validation_error", message: "tasks must be an array of { taskId, expectedRevision }.")
        }
        let requests = try entries.map { entry in
            (taskId: try requiredString(entry["taskId"], name: "taskId"),
             expectedRevision: try requiredInt(entry["expectedRevision"], name: "expectedRevision"))
        }
        let items = try repository.planTaskCompletions(requests)
        let status = try? await timerCommand(["command": "get_status", "confirmed": false])
        let sessionSeconds = status?["config"]?["focusDurationSeconds"]?.intValue ?? 1500
        let totalSeconds = items.reduce(0) { $0 + $1.remainingSessions } * sessionSeconds
        let start = request.parameters["startedAt"] == nil
            ? Date().addingTimeInterval(TimeInterval(-totalSeconds))
            : try dateParam(request.parameters["startedAt"], name: "startedAt")
        return CompletionPlan(items: items, sessionSeconds: sessionSeconds, start: start)
    }

    /// Timer command for a timer proposal. Preflight sends it as a dry run; execution sends it for real.
    private func timerPayload(for request: IPCRequest) -> [String: Any]? {
        let params = request.parameters
        switch request.operation {
        case "set_active_task":
            return ["command": "set_active_task", "confirmed": true, "arguments": ["taskId": params["taskId"]?.stringValue as Any]]
        case "begin_focus":
            var arguments: [String: Any] = [:]
            if let taskId = params["taskId"]?.stringValue { arguments["taskId"] = taskId }
            if let title = params["title"]?.stringValue {
                arguments["title"] = title
                arguments["estimatedPomos"] = params["estimatedPomos"]?.intValue ?? 1
                if let projectId = params["projectId"]?.stringValue { arguments["projectId"] = projectId }
                if let tag = params["tag"]?.stringValue { arguments["tag"] = tag }
            }
            return ["command": "begin_focus", "confirmed": true, "arguments": arguments]
        case "resume_focus":
            return ["command": "resume_focus", "confirmed": true]
        case "pause_focus":
            return ["command": "pause_focus", "confirmed": true]
        case "finish_focus":
            return ["command": "finish_focus", "confirmed": true]
        default:
            return nil
        }
    }

    private func preflight(_ request: IPCRequest, context: ProposalContext) async throws {
        let params = request.parameters
        if var payload = timerPayload(for: request) {
            payload["dryRun"] = true
            _ = try await timerCommand(payload)
            if request.operation == "finish_focus", params["completeTask"]?.boolValue == true, context.activeTask?["id"] == nil {
                throw IPCStructuredError(
                    code: "validation_error",
                    message: "No task is selected in Flumen, so finish_focus cannot complete one. Use complete_tasks to complete tasks."
                )
            }
            return
        }
        switch request.operation {
        case "create_task":
            try repository.checkNewTask(
                title: try requiredString(params["title"], name: "title"),
                estimatedPomos: params["estimatedPomos"]?.intValue ?? 1,
                projectId: params["projectId"]?.stringValue
            )
        case "update_task":
            try repository.checkTask(
                id: try requiredString(params["id"], name: "id"),
                expectedRevision: try requiredInt(params["expectedRevision"], name: "expectedRevision")
            )
            try repository.checkNewTask(
                title: try requiredString(params["title"], name: "title"),
                estimatedPomos: try requiredInt(params["estimatedPomos"], name: "estimatedPomos"),
                projectId: params["projectId"]?.stringValue
            )
        case "complete_task":
            try repository.checkTask(
                id: try requiredString(params["taskId"], name: "taskId"),
                expectedRevision: try requiredInt(params["expectedRevision"], name: "expectedRevision"),
                requiredStatus: 0
            )
        case "reopen_task":
            try repository.checkTask(
                id: try requiredString(params["taskId"], name: "taskId"),
                expectedRevision: try requiredInt(params["expectedRevision"], name: "expectedRevision"),
                requiredStatus: 1
            )
        case "correct_time_entry":
            _ = try requiredString(params["reason"], name: "reason")
            if let duration = params["durationSeconds"]?.intValue, !(1...86_400).contains(duration) {
                throw IPCStructuredError(code: "validation_error", message: "durationSeconds must be between 1 and 86400.")
            }
            try repository.checkActivity(
                id: try requiredString(params["id"], name: "id"),
                expectedRevision: try requiredInt(params["expectedRevision"], name: "expectedRevision"),
                projectId: params["projectId"]?.stringValue
            )
        case "log_time":
            let duration = try requiredInt(params["durationSeconds"], name: "durationSeconds")
            let startedAt = (try? dateParam(params["startedAt"], name: "startedAt")) ?? Date().addingTimeInterval(TimeInterval(-duration))
            try repository.checkNewActivity(
                duration: duration,
                timestamp: startedAt,
                taskId: params["taskId"]?.stringValue,
                taskTitle: try requiredString(params["title"], name: "title"),
                projectId: params["projectId"]?.stringValue,
                sourceClient: request.client.name,
                idempotencyKey: request.idempotencyKey
            )
        case "complete_tasks":
            guard let plan = context.completion else { return }
            if plan.end > Date().addingTimeInterval(120) {
                throw IPCStructuredError(code: "validation_error", message: "Logged sessions cannot end in the future. Use an earlier startedAt.")
            }
            if plan.totalSeconds > 86_400 {
                throw IPCStructuredError(code: "validation_error", message: "Logged sessions cannot exceed 24 hours in one request.")
            }
            if plan.totalSeconds > 0 {
                try repository.checkNewActivity(
                    duration: plan.totalSeconds,
                    timestamp: plan.start,
                    taskId: nil,
                    taskTitle: nil,
                    projectId: nil,
                    sourceClient: nil,
                    idempotencyKey: nil
                )
            }
        default:
            break
        }
    }

    private func executeApproved(_ request: IPCRequest, completion: CompletionPlan?) async throws -> JSONValue {
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

        case "set_active_task", "begin_focus", "resume_focus", "pause_focus":
            return try await timerCommand(timerPayload(for: request)!)

        case "finish_focus":
            guard params["completeTask"]?.boolValue == true else {
                return try await timerCommand(timerPayload(for: request)!)
            }
            let status = try await timerCommand(["command": "get_status", "confirmed": false])
            let taskId = status["activeTask"]?["id"]?.stringValue
            let finished = try await timerCommand(["command": "finish_focus", "confirmed": true])
            guard let taskId else {
                throw IPCStructuredError(
                    code: "partial_failure",
                    message: "Focus finished, but no task was selected, so no task was completed.",
                    details: ["timerFinished": .bool(true), "taskCompleted": .bool(false)]
                )
            }
            do {
                let completion = try await timerCommand([
                    "command": "complete_task",
                    "confirmed": true,
                    "arguments": ["taskId": taskId]
                ])
                var merged = finished.objectValue ?? [:]
                merged["completedTask"] = completion
                return .object(merged)
            } catch {
                throw IPCStructuredError(
                    code: "partial_failure",
                    message: "Focus finished, but Flumen could not complete the task: \(error.localizedDescription)",
                    details: ["timerFinished": .bool(true), "taskCompleted": .bool(false), "taskId": .string(taskId)]
                )
            }

        case "complete_task":
            let updated = try repository.completeTask(
                id: try requiredString(params["taskId"], name: "taskId"),
                expectedRevision: try requiredInt(params["expectedRevision"], name: "expectedRevision")
            )
            refreshShelf()
            return JSONValue.from(any: updated)

        case "complete_tasks":
            guard let completion else {
                throw IPCStructuredError(code: "internal_error", message: "The approved completion plan was missing.")
            }
            let result = try repository.completeTasksWithSessions(
                completion.items,
                sessionSeconds: completion.sessionSeconds,
                start: completion.start,
                sourceClient: request.client.name
            )
            refreshShelf()
            refreshReports()
            return JSONValue.from(any: result)

        case "reopen_task":
            let updated = try repository.reopenTask(
                id: try requiredString(params["taskId"], name: "taskId"),
                expectedRevision: try requiredInt(params["expectedRevision"], name: "expectedRevision")
            )
            refreshShelf()
            return JSONValue.from(any: updated)

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
        // The web view refuses a mutating command after this deadline, so a late delivery
        // cannot change the timer after the agent has already been told it timed out.
        command["deadline"] = Date().addingTimeInterval(Self.timerCommandTimeout - 0.5).timeIntervalSince1970 * 1000
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pendingTimerCommands[requestId] = continuation
            lock.unlock()
            DispatchQueue.main.async { [weak self] in
                self?.bridge?.sendToJS(action: "agentCommand", data: command)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.timerCommandTimeout) { [weak self] in
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
        proposals.cancelAll(error: IPCStructuredError(code: code, message: message))
        lock.lock()
        let timers = pendingTimerCommands
        pendingTimerCommands.removeAll()
        lock.unlock()
        for continuation in timers.values {
            continuation.resume(throwing: IPCStructuredError(code: code, message: message))
        }
    }

    // MARK: - Connections

    private func isRevoked(_ clientId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return revokedClientIds.contains(clientId)
    }

    private func touchConnection(_ client: IPCClientMetadata) {
        lock.lock()
        let now = Date()
        let isNew = connections[client.id] == nil
        if var existing = connections[client.id] {
            existing.lastActivityAt = now
            connections[client.id] = existing
        } else {
            connections[client.id] = ConnectedClient(
                id: client.id,
                name: client.name,
                version: client.version,
                processID: client.processID,
                connectedAt: now,
                lastActivityAt: now
            )
        }
        let pruned = pruneStaleConnectionsLocked(now: now)
        lock.unlock()
        if isNew || pruned {
            DispatchQueue.main.async { [weak self] in self?.pushConnectionStatus() }
        }
    }

    /// Returns true when any connection was removed.
    private func pruneStaleConnectionsLocked(now: Date = Date()) -> Bool {
        let before = connections.count
        connections = connections.filter { _, client in
            if let pid = client.processID, pid > 0, kill(pid, 0) != 0, errno == ESRCH { return false }
            return now.timeIntervalSince(client.lastActivityAt) < Self.connectionIdleTimeout
        }
        return connections.count != before
    }

    private func startConnectionMonitor() {
        stopConnectionMonitor()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let pruned = self.pruneStaleConnectionsLocked()
            self.lock.unlock()
            if pruned { self.pushConnectionStatus() }
        }
        timer.resume()
        connectionMonitor = timer
    }

    private func stopConnectionMonitor() {
        connectionMonitor?.cancel()
        connectionMonitor = nil
    }

    /// Revokes every connected helper so its next heartbeat fails and it exits.
    private func disconnectSessions() -> Int {
        lock.lock()
        let ids = Set(connections.keys)
        revokedClientIds.formUnion(ids)
        connections.removeAll()
        lock.unlock()
        server?.disconnectClients()
        failAllPending(code: "session_disconnected", message: "Agent sessions were disconnected in Flumen.")
        pushConnectionStatus()
        return ids.count
    }

    private func testConnection() {
        guard currentSettings().enabled else {
            sendActionResult("testConnection", success: false, message: "Turn on Agent Access before testing.")
            return
        }
        guard server != nil else {
            sendActionResult("testConnection", success: false, message: "Agent Access is not running. Choose Try Again.")
            return
        }
        let client = UnixSocketClient(
            path: FlumenSocketPath.current(),
            metadata: IPCClientMetadata(id: Self.selfTestClientID, name: "Flumen self-test"),
            timeout: 3
        )
        Task {
            let success: Bool
            let message: String
            do {
                _ = try await client.send(operation: "ping")
                success = true
                message = "Agent Access is ready. The local helper socket answered."
            } catch {
                success = false
                message = "Flumen could not reach its local socket: \(error.localizedDescription)"
            }
            DispatchQueue.main.async { [weak self] in
                self?.sendActionResult("testConnection", success: success, message: message)
            }
        }
    }

    // MARK: - UI updates

    private func refreshShelf() {
        do {
            let data = try repository.loadInitialData()
            DispatchQueue.main.async { [weak self] in
                self?.bridge?.sendToJS(action: "db_initialData", data: data)
            }
        } catch {
            print("AgentAccessCoordinator: Failed to refresh shelf: \(error)")
        }
    }

    private func refreshReports() {
        do {
            let data = try repository.reports()
            DispatchQueue.main.async { [weak self] in
                self?.bridge?.sendToJS(action: "db_reportsData", data: data)
            }
        } catch {
            print("AgentAccessCoordinator: Failed to refresh reports: \(error)")
        }
    }

    private func sendActionResult(_ action: String, success: Bool, message: String) {
        bridge?.sendToJS(action: "agentAccessActionResult", data: [
            "action": action,
            "success": success,
            "message": message
        ])
    }

    private func notifyProposal(_ summary: [String: Any]) {
        let title = summary["title"] as? String ?? "Agent proposal"
        let body = summary["summary"] as? String ?? "An agent is waiting for confirmation in Flumen."
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
        let current = currentSettings()
        bridge?.sendToJS(action: "agentAccessSettings", data: [
            "enabled": current.enabled,
            "readFocusData": current.readFocusData,
            "allowProposals": current.allowProposals,
            "privacyAcknowledged": current.privacyAcknowledged,
            "consentVersion": current.consentVersion,
            "skipConsentPrompt": current.skipConsentPrompt
        ])
    }

    private func pushConnectionStatus(status: String? = nil, error: String? = nil) {
        lock.lock()
        let values = connections.values.sorted { $0.connectedAt < $1.connectedAt }
        let enabled = settings.enabled
        lock.unlock()
        let listening = server != nil
        var errorMessage = error
        let inferred: String
        if error != nil { inferred = "error" }
        else if !enabled { inferred = "off" }
        else if !listening {
            inferred = "error"
            errorMessage = "Flumen could not start its local Agent Access socket."
        }
        else if values.isEmpty { inferred = "ready" }
        else { inferred = "connected" }
        let resolved = (status == "ready" && !listening && enabled) ? inferred : (status ?? inferred)
        bridge?.sendToJS(action: "agentConnectionStatus", data: [
            "status": resolved,
            "enabled": enabled,
            "error": (resolved == "error" ? errorMessage : nil) as Any,
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
            "enabled": currentSettings().enabled
        ])
    }

    private func proposalSummary(for request: IPCRequest, context: ProposalContext) -> [String: Any] {
        if let plan = context.completion {
            return completionSummary(for: request, plan: plan)
        }
        let operationTitle = humanTitle(for: request.operation)
        var taskInfo = taskSummary(for: request)
        if taskInfo.isEmpty, let activeTask = context.activeTask {
            if let id = activeTask["id"] as? String { taskInfo["id"] = id }
            if let title = activeTask["title"] as? String { taskInfo["title"] = title }
        }
        let resolvedProjectName = request.parameters["projectId"]?.stringValue.flatMap(projectName(for:))

        var summary: [String: Any] = [
            "requestId": request.requestId,
            "action": request.operation,
            "actionTitle": operationTitle,
            "expiresAt": Date().addingTimeInterval(FlumenIPC.confirmationWindow).timeIntervalSince1970 * 1000,
            "provenance": [
                "source": "agent",
                "origin": request.client.name
            ]
        ]
        if !taskInfo.isEmpty {
            summary["task"] = taskInfo
        }
        let duration = request.parameters["durationSeconds"]?.intValue
        if let duration {
            summary["durationSeconds"] = duration
        }
        if let interval = proposalInterval(for: request, duration: duration) {
            summary["startedAt"] = interval.start.timeIntervalSince1970 * 1000
            summary["endedAt"] = interval.end.timeIntervalSince1970 * 1000
        }
        if let projectId = request.parameters["projectId"]?.stringValue {
            if let resolvedProjectName {
                summary["project"] = ["id": projectId, "name": resolvedProjectName]
            } else {
                summary["project"] = projectId
            }
        }
        if let reason = request.parameters["reason"]?.stringValue {
            summary["reason"] = truncated(reason, maxLength: 240)
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
            durationSeconds: duration,
            reason: request.parameters["reason"]?.stringValue
        )
        summary["sideEffects"] = sideEffects(for: request, taskTitle: taskTitle)
        return summary
    }

    private func completionSummary(for request: IPCRequest, plan: CompletionPlan) -> [String: Any] {
        let client = request.client.name
        let taskCount = plan.items.count
        let minutes = max(1, plan.sessionSeconds / 60)
        var summary: [String: Any] = [
            "requestId": request.requestId,
            "action": request.operation,
            "actionTitle": humanTitle(for: request.operation),
            "expiresAt": Date().addingTimeInterval(FlumenIPC.confirmationWindow).timeIntervalSince1970 * 1000,
            "provenance": ["source": "agent", "origin": client],
            "items": plan.items.map {
                [
                    "title": $0.title,
                    "sessions": $0.remainingSessions,
                    "durationSeconds": $0.remainingSessions * plan.sessionSeconds
                ] as [String: Any]
            }
        ]
        summary["title"] = taskCount == 1
            ? truncated(plan.items[0].title, maxLength: 120)
            : "Complete \(taskCount) tasks"

        var segments = [client, "Complete \(taskCount) task\(taskCount == 1 ? "" : "s")"]
        var effects = ["Marks \(taskCount == 1 ? "the task" : "\(taskCount) tasks") complete"]
        if plan.sessionCount > 0 {
            summary["durationSeconds"] = plan.totalSeconds
            summary["startedAt"] = plan.start.timeIntervalSince1970 * 1000
            summary["endedAt"] = plan.end.timeIntervalSince1970 * 1000
            segments.append("\(plan.sessionCount) session\(plan.sessionCount == 1 ? "" : "s")")
            segments.append(formatProposalDuration(plan.totalSeconds))
            effects.append("Logs \(plan.sessionCount) focus session\(plan.sessionCount == 1 ? "" : "s") of \(minutes) min, back-to-back")
            effects.append("Counts them as completed sessions, recorded as logged by \(client)")
        } else {
            effects.append("Logs no new time; session counts already match the estimates")
        }
        summary["summary"] = segments.joined(separator: " · ")
        summary["sideEffects"] = effects
        return summary
    }

    private func proposalInterval(for request: IPCRequest, duration: Int?) -> (start: Date, end: Date)? {
        let startedAt = try? dateParam(request.parameters["startedAt"], name: "startedAt")
        switch request.operation {
        case "log_time":
            guard let duration else { return nil }
            let start = startedAt ?? Date().addingTimeInterval(TimeInterval(-duration))
            return (start, start.addingTimeInterval(TimeInterval(duration)))
        case "correct_time_entry":
            guard let startedAt, let duration else { return nil }
            return (startedAt, startedAt.addingTimeInterval(TimeInterval(duration)))
        default:
            return nil
        }
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
        guard let tasks = try? repository.listTasks(includeCompleted: true, limit: 200) else { return nil }
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
        case "resume_focus": return "Resume focus"
        case "pause_focus": return "Pause focus"
        case "finish_focus": return "Finish focus"
        case "complete_task": return "Complete task"
        case "complete_tasks": return "Complete tasks"
        case "reopen_task": return "Reopen task"
        case "correct_time_entry": return "Correct time entry"
        default: return operation
        }
    }

    private func sideEffects(for request: IPCRequest, taskTitle: String?) -> [String] {
        switch request.operation {
        case "log_time":
            return ["Adds recorded focus time", "Does not count as a completed focus cycle"]
        case "create_task":
            return ["Adds a task to the Task Shelf"]
        case "update_task":
            return ["Changes the task title, project, or estimate"]
        case "set_active_task":
            return ["Selects the task without starting a timer"]
        case "begin_focus":
            return request.parameters["title"]?.stringValue != nil && request.parameters["taskId"] == nil
                ? ["Adds this task to the Task Shelf", "Starts the Flumen focus timer"]
                : ["Starts the Flumen focus timer"]
        case "resume_focus":
            return ["Resumes the paused focus timer"]
        case "pause_focus":
            return ["Pauses the running focus timer"]
        case "finish_focus":
            var effects = ["Stops the active timer and advances the session"]
            if request.parameters["completeTask"]?.boolValue == true {
                effects.append(taskTitle.map { "Marks “\(truncated($0, maxLength: 80))” complete" } ?? "Marks the active task complete")
            }
            return effects
        case "complete_task":
            return ["Marks the task complete", "Does not log sessions or time; use complete_tasks for that"]
        case "reopen_task":
            return ["Moves the task back to the open Task Shelf"]
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

    private func mcpLaunchSpec() -> [String: Any] {
        [
            "command": helperPath(),
            "args": [] as [String],
            "env": [
                "FLUMEN_BUNDLE_ID": Bundle.main.bundleIdentifier ?? "com.saranshbarua.flumen"
            ]
        ]
    }

    private func mcpConfigurationJSON() -> String {
        let config: [String: Any] = ["mcpServers": ["flumen": mcpLaunchSpec()]]
        let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private func cursorDeeplink() -> String {
        let data = (try? JSONSerialization.data(withJSONObject: mcpLaunchSpec())) ?? Data()
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
