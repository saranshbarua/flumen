import Foundation
import Logging
import MCP
import FlumenIPC

@main
struct FlumenMCPMain {
    static func main() async {
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            let level = ProcessInfo.processInfo.environment["FLUMEN_MCP_LOG_LEVEL"] ?? "error"
            handler.logLevel = Logger.Level(rawValue: level) ?? .error
            return handler
        }

        let logger = Logger(label: "com.flumen.mcp")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.4.0"
        let clientName = ProcessInfo.processInfo.environment["FLUMEN_MCP_CLIENT_NAME"] ?? "flumen-mcp"
        let clientVersion = ProcessInfo.processInfo.environment["FLUMEN_MCP_CLIENT_VERSION"] ?? version
        let bundleID = ProcessInfo.processInfo.environment["FLUMEN_BUNDLE_ID"] ?? "com.saranshbarua.flumen"
        let socketPath = FlumenSocketPath.current(bundleIdentifier: bundleID)
        let metadata = IPCClientMetadata(
            id: UUID().uuidString,
            name: clientName,
            version: clientVersion,
            processID: ProcessInfo.processInfo.processIdentifier
        )
        let ipc = UnixSocketClient(path: socketPath, metadata: metadata)
        let proxy = FlumenIPCProxy(client: ipc)

        // Refuse to run as a healthy MCP server unless Flumen has authorized Agent Access.
        // This keeps Cursor from showing a calm green "connected" state while access is off.
        do {
            try await requireAuthorizedAccess(proxy: proxy)
        } catch {
            fputs("\(authorizationMessage(for: error))\n", stderr)
            Foundation.exit(1)
        }

        let server = Server(
            name: "Flumen",
            version: version,
            capabilities: .init(
                prompts: .init(listChanged: true),
                resources: .init(subscribe: false, listChanged: true),
                tools: .init(listChanged: true)
            )
        )

        await registerTools(on: server, proxy: proxy)
        await registerResources(on: server, proxy: proxy)
        await registerPrompts(on: server)

        do {
            let transport = IconInjectingStdioTransport(logger: logger)
            try await server.start(transport: transport) { clientInfo, _ in
                logger.info("MCP client connected: \(clientInfo.name) \(clientInfo.version)")
                await proxy.updateClient(name: clientInfo.name, version: clientInfo.version)
                try await requireAuthorizedAccess(proxy: proxy)
            }

            let heartbeat = Task {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(3))
                    do {
                        try await requireAuthorizedAccess(proxy: proxy)
                    } catch {
                        logger.error("Flumen Agent Access unavailable; exiting helper.")
                        fputs("\(authorizationMessage(for: error))\n", stderr)
                        await server.stop()
                        Foundation.exit(1)
                    }
                }
            }

            await server.waitUntilCompleted()
            heartbeat.cancel()
        } catch {
            logger.error("Flumen MCP helper failed: \(error.localizedDescription)")
            Foundation.exit(1)
        }
    }
}

actor FlumenIPCProxy {
    private let client: UnixSocketClient
    private var clientName: String
    private var clientVersion: String?

    init(client: UnixSocketClient) {
        self.client = client
        self.clientName = client.metadata.name
        self.clientVersion = client.metadata.version
    }

    func updateClient(name: String, version: String?) {
        clientName = name
        clientVersion = version
    }

    func call(
        _ operation: String,
        parameters: [String: JSONValue] = [:],
        idempotencyKey: String? = nil
    ) async throws -> JSONValue {
        let metadata = IPCClientMetadata(
            id: client.metadata.id,
            name: clientName,
            version: clientVersion,
            processID: ProcessInfo.processInfo.processIdentifier
        )
        let request = IPCRequest(
            idempotencyKey: idempotencyKey,
            client: metadata,
            operation: operation,
            parameters: parameters
        )
        // Writes wait for a person to approve in Flumen. Keep the socket open for the whole
        // confirmation window and never resend, or one tool call could open two proposals.
        if AgentOperationCatalog.isWrite(operation) {
            return try await client.send(request, timeout: FlumenIPC.mutationTimeout, retryAfterSend: false)
        }
        return try await client.send(request)
    }
}

private func requireAuthorizedAccess(proxy: FlumenIPCProxy) async throws {
    do {
        let status = try await proxy.call("get_server_status")
        guard status["ok"]?.boolValue == true,
              status["agentAccessEnabled"]?.boolValue == true else {
            throw MCPError.invalidRequest(
                "Agent Access is off in Flumen. Turn it on in Settings → Agent Access."
            )
        }
    } catch let error as MCPError {
        throw error
    } catch let error as IPCStructuredError {
        throw MCPError.invalidRequest(authorizationMessage(for: error))
    } catch {
        throw MCPError.invalidRequest(
            "Flumen is not available. Open Flumen on this Mac, turn on Agent Access, and try again."
        )
    }
}

private func authorizationMessage(for error: Error) -> String {
    if let error = error as? IPCStructuredError {
        switch error.code {
        case "agent_access_disabled":
            return "Agent Access is off in Flumen. Turn it on in Settings → Agent Access."
        case "session_disconnected":
            return "Flumen disconnected this agent session. Restart Flumen MCP in your agent to reconnect."
        case "app_unavailable", "ipc_failure", "connection_closed":
            return "Flumen is not available. Open Flumen on this Mac, turn on Agent Access, and try again."
        default:
            return error.message
        }
    }
    if let error = error as? MCPError {
        return error.localizedDescription
    }
    return error.localizedDescription
}

private func registerTools(on server: Server, proxy: FlumenIPCProxy) async {
    let tools: [Tool] = [
        tool("get_server_status", "Return whether Flumen Agent Access is available. approvalsRequired false means writes apply immediately and return autoApplied; true means each write waits for the person."),
        tool("get_focus_status", "Return the authoritative Flumen focus timer status."),
        tool("list_tasks", "List Flumen Task Shelf items.", [
            "includeCompleted": .object(["type": .string("boolean")]),
            "limit": .object(["type": .string("integer")])
        ]),
        tool("list_projects", "List active Flumen projects."),
        tool("query_focus_activity", "Query bounded focus activity history.", [
            "start": .object(["type": .string("string"), "description": .string("ISO-8601 start")]),
            "end": .object(["type": .string("string"), "description": .string("ISO-8601 end")]),
            "projectId": .object(["type": .string("string")]),
            "taskId": .object(["type": .string("string")]),
            "source": .object(["type": .string("string"), "description": .string("timer, manual, or agent")]),
            "limit": .object(["type": .string("integer")])
        ], required: ["start", "end"]),
        tool("get_activity", "Return one focus activity by id, including its current revision for correct_time_entry.", [
            "id": .object(["type": .string("string")])
        ], required: ["id"]),
        tool("get_focus_summary", "Return aggregated focus totals for a date range.", [
            "start": .object(["type": .string("string")]),
            "end": .object(["type": .string("string")])
        ], required: ["start", "end"]),
        tool("get_estimation_context", "Return comparable historical duration facts.", [
            "query": .object(["type": .string("string")]),
            "projectId": .object(["type": .string("string")]),
            "limit": .object(["type": .string("integer")])
        ]),
        tool("log_time", proposalDescription("Propose logging ad-hoc focus time."), [
            "title": .object(["type": .string("string")]),
            "durationSeconds": .object(["type": .string("integer")]),
            "startedAt": .object(["type": .string("string"), "description": .string("ISO-8601 start. Defaults to now minus durationSeconds.")]),
            "taskId": .object(["type": .string("string")]),
            "projectId": .object(["type": .string("string")]),
            "tag": .object(["type": .string("string")]),
            "estimatedPomos": .object(["type": .string("integer")]),
            "durationOrigin": .object(["type": .string("string")]),
            "externalReference": .object(["type": .string("string")]),
            "idempotencyKey": .object(["type": .string("string")])
        ], required: ["title", "durationSeconds"]),
        tool("create_task", proposalDescription("Propose creating a Flumen task."), [
            "title": .object(["type": .string("string")]),
            "estimatedPomos": .object(["type": .string("integer")]),
            "projectId": .object(["type": .string("string")]),
            "tag": .object(["type": .string("string")]),
            "idempotencyKey": .object(["type": .string("string")])
        ], required: ["title"]),
        tool("update_task", proposalDescription("Propose updating a task. Requires expectedRevision from list_tasks."), [
            "id": .object(["type": .string("string")]),
            "title": .object(["type": .string("string")]),
            "estimatedPomos": .object(["type": .string("integer")]),
            "projectId": .object(["type": .string("string")]),
            "tag": .object(["type": .string("string")]),
            "expectedRevision": .object(["type": .string("integer")]),
            "idempotencyKey": .object(["type": .string("string")])
        ], required: ["id", "title", "estimatedPomos", "expectedRevision"]),
        tool("set_active_task", proposalDescription("Propose selecting an open task without starting a timer."), [
            "taskId": .object(["type": .string("string")]),
            "idempotencyKey": .object(["type": .string("string")])
        ], required: ["taskId"]),
        tool("begin_focus", proposalDescription("Propose starting a new focus session, optionally creating or selecting a task. Fails while a session is paused; use resume_focus instead."), [
            "taskId": .object(["type": .string("string")]),
            "title": .object(["type": .string("string")]),
            "estimatedPomos": .object(["type": .string("integer")]),
            "projectId": .object(["type": .string("string")]),
            "tag": .object(["type": .string("string")]),
            "idempotencyKey": .object(["type": .string("string")])
        ]),
        tool("resume_focus", proposalDescription("Propose resuming the paused focus timer."), [
            "idempotencyKey": .object(["type": .string("string")])
        ]),
        tool("pause_focus", proposalDescription("Propose pausing the running focus timer."), [
            "idempotencyKey": .object(["type": .string("string")])
        ]),
        tool("finish_focus", proposalDescription("Propose finishing the active focus timer. With completeTask, the selected task is also marked complete and the confirmation says so."), [
            "completeTask": .object(["type": .string("boolean")]),
            "idempotencyKey": .object(["type": .string("string")])
        ]),
        tool("complete_task", proposalDescription("Propose marking one task done without logging any sessions or time. Requires expectedRevision from list_tasks. To record the work (fill 0/3 to 3/3 and log the time), use complete_tasks."), [
            "taskId": .object(["type": .string("string")]),
            "expectedRevision": .object(["type": .string("integer")]),
            "idempotencyKey": .object(["type": .string("string")])
        ], required: ["taskId", "expectedRevision"]),
        tool("complete_tasks", proposalDescription(
            "Propose completing one or more tasks as finished work, in one confirmation. For each task, logs its remaining sessions "
            + "(estimate minus completed) at the person's focus length, fills the session count to the estimate, and marks it done. "
            + "Sessions are placed back-to-back ending now unless startedAt is given, count as completed sessions, and are recorded as logged by this agent. "
            + "Refused if the time overlaps existing logs. Do not drive the timer to fill sessions."
        ), [
            "tasks": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "taskId": .object(["type": .string("string")]),
                        "expectedRevision": .object(["type": .string("integer")])
                    ]),
                    "required": .array([.string("taskId"), .string("expectedRevision")])
                ])
            ]),
            "startedAt": .object(["type": .string("string"), "description": .string("Optional ISO-8601 start of the first session.")]),
            "idempotencyKey": .object(["type": .string("string")])
        ], required: ["tasks"]),
        tool("reopen_task", proposalDescription("Propose moving a completed task back to the open Task Shelf. Requires expectedRevision from list_tasks with includeCompleted."), [
            "taskId": .object(["type": .string("string")]),
            "expectedRevision": .object(["type": .string("integer")]),
            "idempotencyKey": .object(["type": .string("string")])
        ], required: ["taskId", "expectedRevision"]),
        tool("correct_time_entry", proposalDescription("Propose correcting a completed activity entry. Read expectedRevision with get_activity."), [
            "id": .object(["type": .string("string")]),
            "expectedRevision": .object(["type": .string("integer")]),
            "durationSeconds": .object(["type": .string("integer")]),
            "startedAt": .object(["type": .string("string")]),
            "title": .object(["type": .string("string")]),
            "projectId": .object(["type": .string("string")]),
            "reason": .object(["type": .string("string")]),
            "idempotencyKey": .object(["type": .string("string")])
        ], required: ["id", "expectedRevision", "reason"])
    ]

    await server.withMethodHandler(ListTools.self) { _ in
        do {
            try await requireAuthorizedAccess(proxy: proxy)
            return .init(tools: tools)
        } catch {
            scheduleHelperExit(message: authorizationMessage(for: error))
            throw error
        }
    }

    await server.withMethodHandler(CallTool.self) { params in
        do {
            try await requireAuthorizedAccess(proxy: proxy)
            let result = try await proxy.call(
                params.name,
                parameters: params.arguments?.mapValues { JSONValue.from(mcp: $0) } ?? [:],
                idempotencyKey: params.arguments?["idempotencyKey"]?.stringValue
            )
            return .init(
                content: [.text(text: try encodeJSON(result), annotations: nil, _meta: nil)],
                isError: false
            )
        } catch let error as IPCStructuredError {
            if shouldExitAfterAccessLoss(error) {
                scheduleHelperExit(message: authorizationMessage(for: error))
            }
            return .init(
                content: [.text(text: structuredErrorPayload(error), annotations: nil, _meta: nil)],
                isError: true
            )
        } catch let error as MCPError {
            scheduleHelperExit(message: authorizationMessage(for: error))
            throw error
        } catch let error as CancellationError {
            // The agent cancelled the call; the SDK drops the response per the MCP spec.
            throw error
        } catch {
            let wrapped = IPCStructuredError(code: "internal_error", message: error.localizedDescription)
            return .init(
                content: [.text(text: structuredErrorPayload(wrapped), annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }
}

private func shouldExitAfterAccessLoss(_ error: IPCStructuredError) -> Bool {
    ["agent_access_disabled", "session_disconnected", "app_unavailable", "ipc_failure", "connection_closed"].contains(error.code)
}

/// The one JSON error shape agents can rely on from tools and resources.
private func structuredErrorPayload(_ error: IPCStructuredError) -> String {
    (try? encodeJSON(.object([
        "code": .string(error.code),
        "message": .string(error.message),
        "retryable": .bool(error.retryable),
        "details": error.details.map { .object($0) } ?? .null
    ]))) ?? error.message
}

private func proposalDescription(_ summary: String) -> String {
    "\(summary) Flumen checks the request first and returns an error immediately if it cannot apply. "
        + "When get_server_status reports approvalsRequired true, this waits up to \(Int(FlumenIPC.confirmationWindow)) seconds for approval. "
        + "When approvalsRequired is false, it applies immediately and the result includes autoApplied. "
        + "Pass a fresh idempotencyKey per change; reusing a key with different arguments returns idempotency_conflict."
}

private func scheduleHelperExit(message: String) {
    Task {
        fputs("\(message)\n", stderr)
        // Give the MCP error response a moment to flush before tearing down stdio.
        try? await Task.sleep(for: .milliseconds(150))
        Foundation.exit(1)
    }
}

private func registerResources(on server: Server, proxy: FlumenIPCProxy) async {
    let resources = [
        Resource(name: "Focus Status", uri: "flumen://status", description: "Current timer and active task", icons: FlumenMCPIcons.brand),
        Resource(name: "Today", uri: "flumen://today", description: "Today's focus totals", icons: FlumenMCPIcons.brand),
        Resource(name: "Active Task", uri: "flumen://active-task", description: "Currently selected task", icons: FlumenMCPIcons.brand)
    ]

    await server.withMethodHandler(ListResources.self) { _ in
        do {
            try await requireAuthorizedAccess(proxy: proxy)
            return .init(resources: resources, nextCursor: nil)
        } catch {
            scheduleHelperExit(message: authorizationMessage(for: error))
            throw error
        }
    }

    await server.withMethodHandler(ReadResource.self) { params in
        try await requireAuthorizedAccess(proxy: proxy)
        let operation: String
        switch params.uri {
        case "flumen://status": operation = "get_focus_status"
        case "flumen://today": operation = "get_today_summary"
        case "flumen://active-task": operation = "get_active_task"
        default:
            throw MCPError.invalidParams("Unknown resource URI: \(params.uri)")
        }
        do {
            let result = try await proxy.call(operation)
            return .init(contents: [.text(try encodeJSON(result), uri: params.uri, mimeType: "application/json")])
        } catch let error as IPCStructuredError {
            if shouldExitAfterAccessLoss(error) {
                scheduleHelperExit(message: authorizationMessage(for: error))
            }
            throw MCPError.serverError(code: -32000, message: structuredErrorPayload(error))
        }
    }
}

private func registerPrompts(on server: Server) async {
    let prompts = [
        Prompt(
            name: "recover_missing_time",
            description: "Help recover forgotten meetings or short work into Flumen with confirmation.",
            arguments: [
                .init(name: "hint", description: "Optional description of the missing work")
            ],
            icons: FlumenMCPIcons.brand
        ),
        Prompt(
            name: "plan_focus_day",
            description: "Propose a small Flumen day plan from calendar or project context.",
            arguments: [
                .init(name: "context", description: "Optional planning context")
            ],
            icons: FlumenMCPIcons.brand
        ),
        Prompt(
            name: "weekly_focus_review",
            description: "Review Flumen focus history for the week and prepare external work items.",
            arguments: [
                .init(name: "start", description: "Optional ISO-8601 start"),
                .init(name: "end", description: "Optional ISO-8601 end")
            ],
            icons: FlumenMCPIcons.brand
        )
    ]

    await server.withMethodHandler(ListPrompts.self) { _ in
        .init(prompts: prompts, nextCursor: nil)
    }

    await server.withMethodHandler(GetPrompt.self) { params in
        let hint = params.arguments?["hint"]
            ?? params.arguments?["context"]
            ?? ""
        let message: String
        switch params.name {
        case "recover_missing_time":
            message = """
            Use Flumen MCP tools to inspect recent activity, reconstruct missing work\(hint.isEmpty ? "" : " related to \(hint)"), \
            and call log_time with clear provenance. Wait for Flumen confirmation before assuming the entry exists.
            """
        case "plan_focus_day":
            message = """
            Read Flumen tasks and estimation context, combine with the user's calendar or project context, \
            propose a small Task Shelf plan, and only create/start items after Flumen confirmation. \(hint)
            """
        case "weekly_focus_review":
            message = """
            Call get_focus_summary and query_focus_activity for the requested range, group verified Flumen sessions, \
            and prepare external work-item proposals that cite Flumen activity IDs. Do not invent sessions.
            """
        default:
            throw MCPError.invalidParams("Unknown prompt: \(params.name)")
        }
        return .init(
            description: params.name,
            messages: [.user(.text(text: message))]
        )
    }
}

private func tool(
    _ name: String,
    _ description: String,
    _ properties: [String: Value] = [:],
    required: [String] = []
) -> Tool {
    Tool(
        name: name,
        description: description,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(Value.string))
        ]),
        icons: FlumenMCPIcons.brand
    )
}

private func encodeJSON(_ value: JSONValue) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: value.anyValue, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

private extension JSONValue {
    static func from(mcp value: Value) -> JSONValue {
        switch value {
        case .null: return .null
        case .bool(let value): return .bool(value)
        case .int(let value): return .number(Double(value))
        case .double(let value): return .number(value)
        case .string(let value): return .string(value)
        case .array(let value): return .array(value.map(JSONValue.from(mcp:)))
        case .object(let value): return .object(value.mapValues(JSONValue.from(mcp:)))
        case .data(_, let data): return .string(data.base64EncodedString())
        @unknown default: return .string(String(describing: value))
        }
    }
}
