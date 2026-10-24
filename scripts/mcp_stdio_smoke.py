#!/usr/bin/env python3
"""Protocol smoke test for the bundled Flumen stdio MCP helper.

Modes:
  default       Without Flumen, the helper must refuse with a known message. With Flumen
                open and Agent Access on, the full handshake must pass.
  --require-app Flumen must be open with Agent Access on; the full handshake must pass.
  --stub-app    Runs the helper against an in-process fake Flumen socket, so the authorized
                handshake and a write round trip are exercised without the app (CI).
"""

from __future__ import annotations

import argparse
import json
import os
import selectors
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Any


EXPECTED_TOOLS = {
    "get_server_status",
    "get_focus_status",
    "list_tasks",
    "list_projects",
    "query_focus_activity",
    "get_activity",
    "get_focus_summary",
    "get_estimation_context",
    "log_time",
    "create_task",
    "update_task",
    "set_active_task",
    "begin_focus",
    "resume_focus",
    "pause_focus",
    "finish_focus",
    "complete_task",
    "complete_tasks",
    "reopen_task",
    "correct_time_entry",
}

EXPECTED_RESOURCES = {
    "flumen://status",
    "flumen://today",
    "flumen://active-task",
}

EXPECTED_PROMPTS = {
    "recover_missing_time",
    "plan_focus_day",
    "weekly_focus_review",
}

# Messages the helper prints when it correctly refuses to run without authorized Agent Access.
REFUSAL_MARKERS = (
    "Agent Access is off in Flumen",
    "Flumen is not available",
    "Flumen disconnected this agent session",
)


class MCPProcess:
    def __init__(self, executable: Path, timeout: float, extra_env: dict[str, str] | None = None) -> None:
        self.timeout = timeout
        self.process = subprocess.Popen(
            [str(executable)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env={**os.environ, "FLUMEN_MCP_LOG_LEVEL": "error", **(extra_env or {})},
        )
        if self.process.stdin is None or self.process.stdout is None:
            raise RuntimeError("Failed to open helper stdio")

        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)

    def send(self, message: dict[str, Any]) -> None:
        assert self.process.stdin is not None
        self.process.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
        self.process.stdin.flush()

    def receive(self, expected_id: int) -> dict[str, Any]:
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            remaining = max(0.0, deadline - time.monotonic())
            if not self.selector.select(remaining):
                break

            assert self.process.stdout is not None
            line = self.process.stdout.readline()
            if not line:
                break

            payload = json.loads(line)
            if payload.get("id") == expected_id:
                return payload

        raise TimeoutError(
            f"Timed out waiting for MCP response id={expected_id}. "
            f"exit={self.process.poll()} stderr={self.stderr_text()!r}"
        )

    def stderr_text(self) -> str:
        if self.process.poll() is None or self.process.stderr is None:
            return ""
        return self.process.stderr.read().strip()

    def close(self) -> None:
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2)


class StubFlumen:
    """Minimal fake of Flumen's Agent Access socket (newline-delimited JSON IPC)."""

    def __init__(self) -> None:
        self.directory = tempfile.mkdtemp(prefix="flumen-mcp-", dir="/tmp")
        self.path = os.path.join(self.directory, "agent.sock")
        self.requests: list[dict[str, Any]] = []
        self.lock = threading.Lock()
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(self.path)
        self.server.listen(8)
        self.running = True
        self.thread = threading.Thread(target=self._accept_loop, daemon=True)
        self.thread.start()

    def operations(self, name: str) -> list[dict[str, Any]]:
        with self.lock:
            return [request for request in self.requests if request.get("operation") == name]

    def _accept_loop(self) -> None:
        while self.running:
            try:
                connection, _ = self.server.accept()
            except OSError:
                return
            threading.Thread(target=self._serve, args=(connection,), daemon=True).start()

    def _serve(self, connection: socket.socket) -> None:
        with connection:
            buffer = b""
            while True:
                chunk = connection.recv(4096)
                if not chunk:
                    return
                buffer += chunk
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    request = json.loads(line)
                    with self.lock:
                        self.requests.append(request)
                    response = self._respond(request)
                    connection.sendall((json.dumps(response) + "\n").encode())

    def _respond(self, request: dict[str, Any]) -> dict[str, Any]:
        operation = request.get("operation")
        base = {"version": 1, "requestId": request.get("requestId", "unknown")}
        if operation in ("get_server_status", "ping"):
            return {**base, "result": {
                "ok": True,
                "app": "Flumen",
                "agentAccessEnabled": True,
                "readFocusData": True,
                "allowProposals": True,
            }}
        if operation == "list_projects":
            return {**base, "result": []}
        if operation == "create_task":
            return {**base, "result": {"id": "stub-task"}}
        return {**base, "error": {
            "code": "unsupported_operation",
            "message": f"Stub does not implement {operation}",
            "retryable": False,
        }}

    def close(self) -> None:
        self.running = False
        try:
            self.server.close()
        finally:
            shutil.rmtree(self.directory, ignore_errors=True)


def _assert_flumen_icons(icons: Any, label: str) -> None:
    if not isinstance(icons, list) or not icons:
        raise AssertionError(f"Missing SEP-973 icons on {label}")
    first = icons[0]
    src = first.get("src") if isinstance(first, dict) else None
    if not isinstance(src, str) or not src.startswith("data:image/png;base64,"):
        raise AssertionError(f"Expected embedded PNG icon on {label}, got {first!r}")


def request(
    helper: MCPProcess, request_id: int, method: str, params: dict[str, Any] | None = None
) -> dict[str, Any]:
    message: dict[str, Any] = {
        "jsonrpc": "2.0",
        "id": request_id,
        "method": method,
    }
    if params is not None:
        message["params"] = params
    helper.send(message)
    response = helper.receive(request_id)
    if "error" in response:
        raise RuntimeError(f"{method} failed: {response['error']}")
    return response.get("result", {})


def call_tool(helper: MCPProcess, request_id: int, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
    result = request(helper, request_id, "tools/call", {"name": name, "arguments": arguments})
    content = result.get("content", [])
    text = next((item.get("text") for item in content if item.get("type") == "text"), "")
    if result.get("isError"):
        raise RuntimeError(f"{name} returned tool error: {text}")
    return json.loads(text) if text else {}


def resolve_helper(explicit: Path | None) -> Path:
    if explicit is not None:
        return explicit.expanduser().resolve()

    candidates = [
        Path("macos/Pomodoro/.build/arm64-apple-macosx/debug/flumen-mcp"),
        Path("macos/Pomodoro/.build/arm64-apple-macosx/release/flumen-mcp"),
        Path("macos/Pomodoro/.build/apple/Products/Release/flumen-mcp"),
        Path("macos/Pomodoro/.build/debug/flumen-mcp"),
        Path("macos/Pomodoro/.build/release/flumen-mcp"),
        Path("Flumen.app/Contents/Helpers/flumen-mcp"),
    ]
    for candidate in candidates:
        resolved = candidate.resolve()
        if resolved.is_file() and os.access(resolved, os.X_OK):
            return resolved
    raise FileNotFoundError(
        "flumen-mcp helper not found. Build with "
        "`swift build --package-path macos/Pomodoro --product flumen-mcp` "
        "or pass an explicit helper path."
    )


def is_known_refusal(stderr: str) -> bool:
    return any(marker in stderr for marker in REFUSAL_MARKERS)


def run_handshake(helper: MCPProcess, helper_path: Path, stub: StubFlumen | None) -> None:
    initialize = request(
        helper,
        1,
        "initialize",
        {
            "protocolVersion": "2025-11-25",
            "capabilities": {},
            "clientInfo": {
                "name": "flumen-smoke-test",
                "version": "1.0.0",
            },
        },
    )
    helper.send(
        {
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
            "params": {},
        }
    )

    tools_result = request(helper, 2, "tools/list", {})
    tools = tools_result.get("tools", [])
    tool_names = {tool["name"] for tool in tools}
    missing_tools = EXPECTED_TOOLS - tool_names
    if missing_tools:
        raise AssertionError(
            f"Missing expected tools: {', '.join(sorted(missing_tools))}"
        )
    _assert_flumen_icons(
        initialize.get("serverInfo", {}).get("icons"),
        "serverInfo",
    )
    for tool in tools:
        _assert_flumen_icons(tool.get("icons"), f"tool {tool.get('name')}")

    resources_result = request(helper, 3, "resources/list", {})
    resources = resources_result.get("resources", [])
    resource_uris = {resource["uri"] for resource in resources}
    missing_resources = EXPECTED_RESOURCES - resource_uris
    if missing_resources:
        raise AssertionError(
            f"Missing expected resources: {', '.join(sorted(missing_resources))}"
        )
    for resource in resources:
        _assert_flumen_icons(
            resource.get("icons"), f"resource {resource.get('uri')}"
        )

    prompts_result = request(helper, 4, "prompts/list", {})
    prompts = prompts_result.get("prompts", [])
    prompt_names = {prompt["name"] for prompt in prompts}
    missing_prompts = EXPECTED_PROMPTS - prompt_names
    if missing_prompts:
        raise AssertionError(
            f"Missing expected prompts: {', '.join(sorted(missing_prompts))}"
        )
    for prompt in prompts:
        _assert_flumen_icons(prompt.get("icons"), f"prompt {prompt.get('name')}")

    payload = call_tool(helper, 5, "get_server_status", {})
    if not payload.get("ok") or not payload.get("agentAccessEnabled", True):
        raise RuntimeError(f"get_server_status returned unauthorized payload: {payload}")

    if stub is not None:
        projects = call_tool(helper, 6, "list_projects", {})
        if projects != []:
            raise AssertionError(f"Unexpected list_projects payload: {projects!r}")
        created = call_tool(
            helper, 7, "create_task", {"title": "Smoke task", "idempotencyKey": "smoke-1"}
        )
        if created.get("id") != "stub-task":
            raise AssertionError(f"Unexpected create_task payload: {created!r}")
        writes = stub.operations("create_task")
        if len(writes) != 1:
            raise AssertionError(f"Expected exactly one create_task IPC request, saw {len(writes)}")
        if writes[0].get("idempotencyKey") != "smoke-1":
            raise AssertionError("create_task did not forward its idempotencyKey")

    print(
        "MCP stdio smoke test passed: "
        f"helper={helper_path} "
        f"server={initialize.get('serverInfo', {}).get('name', 'unknown')} "
        f"tools={len(tool_names)} resources={len(resource_uris)} "
        f"prompts={len(prompt_names)} icons=ok "
        + ("app=stub writes=ok" if stub is not None else "app=authorized")
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("helper", nargs="?", type=Path, default=None)
    parser.add_argument("--timeout", type=float, default=10.0)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--require-app",
        action="store_true",
        help="Require Flumen open with Agent Access on for a full healthy handshake.",
    )
    mode.add_argument(
        "--stub-app",
        action="store_true",
        help="Run the full handshake against a fake Flumen socket (no app needed).",
    )
    args = parser.parse_args()

    try:
        helper_path = resolve_helper(args.helper)
    except FileNotFoundError as error:
        print(str(error), file=sys.stderr)
        return 2

    stub = StubFlumen() if args.stub_app else None
    must_handshake = args.require_app or stub is not None
    extra_env = {"FLUMEN_SOCKET_PATH": stub.path} if stub is not None else None
    helper = MCPProcess(helper_path, args.timeout, extra_env)
    try:
        # Preflight may exit immediately when Flumen Agent Access is unavailable.
        deadline = time.monotonic() + min(2.0, args.timeout)
        while time.monotonic() < deadline and helper.process.poll() is None:
            time.sleep(0.05)

        if helper.process.poll() is not None:
            stderr = helper.stderr_text()
            code = helper.process.returncode
            if must_handshake or not is_known_refusal(stderr):
                print(f"Helper exited before initialize (code={code}): {stderr}", file=sys.stderr)
                return 1
            print(
                "MCP stdio smoke test passed: "
                f"helper={helper_path} refused unauthorized session "
                f"(exit={code}) message={stderr!r}"
            )
            return 0

        run_handshake(helper, helper_path, stub)
        return 0
    except Exception as error:
        exit_code = helper.process.poll()
        stderr = helper.stderr_text()
        if not must_handshake and exit_code not in (None, 0) and is_known_refusal(stderr):
            # Agent Access can flip off mid-handshake; that refusal is still correct behavior.
            print(
                "MCP stdio smoke test passed: "
                f"helper={helper_path} refused unauthorized session "
                f"(exit={exit_code}, message={stderr!r})"
            )
            return 0
        print(f"MCP stdio smoke test failed: {error} stderr={stderr!r}", file=sys.stderr)
        return 1
    finally:
        helper.close()
        if stub is not None:
            stub.close()


if __name__ == "__main__":
    raise SystemExit(main())
