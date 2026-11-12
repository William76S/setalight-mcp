#!/usr/bin/env python3
"""Local macOS set.a.light MCP server. Python 3.10+, standard library only."""
from __future__ import annotations

import argparse
import base64
from contextlib import contextmanager
import json
import math
import os
from pathlib import Path
import shlex
import stat
import subprocess
import sys
import tempfile

VERSION = "0.3.1"
ROOT = Path(__file__).resolve().parent
HELPER = ROOT / "SetALight MCP.app" / "Contents" / "MacOS" / "setalight-input"
PROTOCOLS = ("2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05")
MAX_LINE = 1_048_576
MAX_HELPER_INPUT = 65_536
INSTRUCTIONS = """Control only the running macOS set.a.light 3D v2.5 app. First call status,
then screenshot. Screenshot metadata maps image pixels to global screen points. Inspect
that image before choosing coordinates; never guess hidden controls. Use click/click_hid
for Unity, then screenshot to verify. An event sent is not proof that a setting changed.
Do not automatically retry failed input: it may be partly applied. Re-observe first.
Use short batches only for known, deterministic steps within one already-visible control.
Accessibility enables input. Screen Recording separately enables screenshots. Never call
request_access without explicit user approval for that specific permission. No permission
dialogs are triggered by status/screenshot. The server does not edit .set files or expose a scene
API. Save and render through the app UI. Avoid concurrent human mouse/keyboard input."""


def schema(properties=None, required=()):
    return {"type": "object", "properties": properties or {}, "required": list(required), "additionalProperties": False}


def tool(name, description, properties=None, required=(), read_only=False, idempotent=False):
    return {"name": name, "description": description, "inputSchema": schema(properties, required),
            "annotations": {"readOnlyHint": read_only, "destructiveHint": not read_only,
                            "idempotentHint": idempotent, "openWorldHint": False}}


NUMBER = {"type": "number"}
POINT = {"x": NUMBER, "y": NUMBER}
DURATION = {"type": "number", "minimum": 20, "maximum": 1000}
BATCH_NAMES = ("focus", "click", "click_hid", "scroll_hid", "drag_hid", "keypress", "type_text")
TOOLS = [
    tool("status", "Read running state, permissions, visible window bounds and displays. Works when set.a.light is closed. No permission dialogs or focus changes.", read_only=True, idempotent=True),
    tool("screenshot", "Capture only one visible set.a.light window as an inline PNG. Defaults to the largest window; use windowId from status for a dialog. Requires existing Screen Recording permission; never requests access. Returns exact image-to-screen coordinate mapping. Does not focus the app.",
         {"windowId": {"type": "integer", "minimum": 1, "maximum": 4294967295}, "maxWidth": {"type": "integer", "minimum": 640, "maximum": 2560}}, read_only=True, idempotent=True),
    tool("request_access", "Ask macOS for the named permission ONLY after explicit user approval for SetALight MCP at action time. Accessibility enables input; screen_recording enables window screenshots. confirmed must be true. This requests, never grants, access.",
         {"confirmed": {"type": "boolean", "enum": [True]}, "permission": {"type": "string", "enum": ["accessibility", "screen_recording"]}}, ("confirmed",)),
    tool("focus", "Activate only the already-running set.a.light app. Never launches it.", idempotent=True),
    tool("fit_window", "Fit set.a.light's main window to the primary screen through Accessibility. Does not change display settings.", idempotent=True),
    tool("click", "Verified Unity input: focus set.a.light, validate global screen point and Accessibility hit owner, then left click via HID. Inspect a current screenshot first. Returns an error on rejected or interrupted input.", {**POINT, "durationMs": DURATION}, ("x", "y")),
    tool("click_hid", "Compatibility alias for click; same validated HID left click. Coordinates are global screen points, not image pixels.", {**POINT, "durationMs": DURATION}, ("x", "y")),
    tool("scroll_hid", "Scroll at the observed global screen point via HID. Nonzero integer deltaY in pixels: positive up, negative down, magnitude <=2000. Validates Accessibility hit owner.", {**POINT, "deltaY": {"type": "integer", "minimum": -2000, "maximum": 2000}}, ("x", "y", "deltaY")),
    tool("drag_hid", "Smooth validated HID drag within set.a.light. Rechecks foreground/path hit ownership and releases the button on interruption. Re-observe before any retry.", {"fromX": NUMBER, "fromY": NUMBER, "toX": NUMBER, "toY": NUMBER, "durationMs": {"type": "number", "minimum": 200, "maximum": 2000}}, ("fromX", "fromY", "toX", "toY")),
    tool("keypress", "Send an allowed key/chord only while set.a.light is frontmost. Examples cmd+a, return, escape, shift+tab. Global app/workspace switch shortcuts are blocked. This may change or save the project.", {"key": {"type": "string", "minLength": 1, "maxLength": 80}}, ("key",)),
    tool("type_text", "Type Unicode into the already-focused set.a.light field without using the clipboard. At most 4096 UTF-16 units. Does not clear existing contents or press Enter.", {"text": {"type": "string", "maxLength": 4096}}, ("text",)),
]
ACTION = {"oneOf": [{**item["inputSchema"], "properties": {"command": {"type": "string", "const": item["name"]}, **item["inputSchema"]["properties"]}, "required": ["command", *item["inputSchema"]["required"]]} for item in TOOLS if item["name"] in BATCH_NAMES]}
TOOLS.append(tool("batch", "Run 1..20 known input steps serially. No permission requests, screenshots, or nested batches. Stops on error, rejected input, or foreground change, reporting completed steps and failedIndex. Not atomic: a failed action may be partly applied.", {"actions": {"type": "array", "items": ACTION, "minItems": 1, "maxItems": 20}}, ("actions",)))
BY_NAME = {item["name"]: item for item in TOOLS}


class RPCError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def json_loads(value):
    def reject_constant(value):
        raise ValueError("Non-finite JSON number")
    return json.loads(value, parse_constant=reject_constant)


def utf16_length(value):
    try:
        return len(value.encode("utf-16-le")) // 2
    except UnicodeEncodeError as exc:
        raise RPCError(-32602, "Text contains an unpaired Unicode surrogate") from exc


def validate_action(name, args):
    if not isinstance(name, str) or name not in BY_NAME:
        raise RPCError(-32602, "Unknown tool")
    if not isinstance(args, dict):
        raise RPCError(-32602, "arguments must be an object")
    spec = BY_NAME[name]["inputSchema"]
    if set(args) - set(spec["properties"]) or set(spec["required"]) - set(args):
        raise RPCError(-32602, "Unknown or missing arguments")
    for key, value in args.items():
        prop = spec["properties"][key]
        kind = prop["type"]
        if kind in ("number", "integer"):
            valid = type(value) in (int, float) and (kind != "integer" or type(value) is int)
            try:
                valid = valid and math.isfinite(value)
            except OverflowError:
                valid = False
            if not valid or value < prop.get("minimum", -math.inf) or value > prop.get("maximum", math.inf):
                raise RPCError(-32602, f"Invalid finite {kind}: {key}")
        elif kind == "string":
            if not isinstance(value, str) or not prop.get("minLength", 0) <= len(value) <= prop.get("maxLength", MAX_LINE):
                raise RPCError(-32602, f"Invalid string: {key}")
            utf16_length(value)
        elif kind == "boolean" and type(value) is not bool:
            raise RPCError(-32602, f"Invalid boolean: {key}")
        elif kind == "array" and (not isinstance(value, list) or not prop.get("minItems", 0) <= len(value) <= prop["maxItems"]):
            raise RPCError(-32602, f"Invalid array: {key}")
        if "enum" in prop and value not in prop["enum"]:
            raise RPCError(-32602, f"Invalid choice: {key}")
    if name == "request_access" and args["confirmed"] is not True:
        raise RPCError(-32602, "Explicit user confirmation is required")
    if name == "scroll_hid" and args["deltaY"] == 0:
        raise RPCError(-32602, "deltaY must not be zero")
    if name == "type_text" and utf16_length(args["text"]) > 4096:
        raise RPCError(-32602, "Text exceeds 4096 UTF-16 units")
    if name == "batch":
        for action in args["actions"]:
            if not isinstance(action, dict) or action.get("command") not in BATCH_NAMES:
                raise RPCError(-32602, "Invalid batch action")
            validate_action(action["command"], {k: v for k, v in action.items() if k != "command"})
        if sum(utf16_length(a.get("text", "")) for a in args["actions"]) > 4096:
            raise RPCError(-32602, "Combined text exceeds 4096 UTF-16 units")


@contextmanager
def helper_lock():
    """Serialize helper calls across MCP clients and the CLI; never queue stale input."""
    import fcntl
    path = Path(tempfile.gettempdir()) / f"setalight-mcp-{os.getuid()}.lock"
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if info.st_uid != os.getuid() or not stat.S_ISREG(info.st_mode):
            raise OSError("Unsafe lock file")
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(fd)


def tool_result(data):
    content = [{"type": "text", "text": json.dumps(data, ensure_ascii=True, allow_nan=False)}]
    return {"content": content, "structuredContent": data, "isError": not data.get("ok", False)}


def call_tool(name, args):
    validate_action(name, args)
    if sys.platform != "darwin":
        return tool_result({"ok": False, "error": "This helper requires macOS 14 or later."})
    if not HELPER.is_file():
        return tool_result({"ok": False, "error": "Helper is not built. Run sh build.sh in the repository."})
    payload = json.dumps({"command": name, **args}, ensure_ascii=True, allow_nan=False)
    if len(payload.encode("utf-8")) > MAX_HELPER_INPUT:
        raise RPCError(-32602, "Helper request exceeds 64 KiB")
    try:
        with helper_lock():
            proc = subprocess.run([str(HELPER)], input=payload, capture_output=True, text=True, timeout=120, check=False)
        data = json_loads(proc.stdout)
        if not isinstance(data, dict) or type(data.get("ok")) is not bool:
            raise ValueError("Invalid helper response")
        if proc.returncode and data["ok"]:
            raise ValueError("Helper exit status contradicts response")
        detail = data.get("result", {})
        if isinstance(detail, dict) and (any(detail.get(k) is False for k in ("clicked", "scrolled", "dragged", "frontmostAfter")) or detail.get("interrupted")):
            data["ok"] = False
            data["error"] = "Input rejected or interrupted; inspect the current UI before retrying."
        if name == "screenshot" and data["ok"]:
            png = detail.pop("imageBase64")
            raw = base64.b64decode(png, validate=True)
            if len(raw) > 20_000_000 or not raw.startswith(b"\x89PNG\r\n\x1a\n"):
                raise ValueError("Invalid screenshot PNG")
            result = tool_result(data)
            result["content"].append({"type": "image", "mimeType": "image/png", "data": png})
            return result
        return tool_result(data)
    except BlockingIOError:
        return tool_result({"ok": False, "error": "Another SetALight MCP operation is running. Re-observe before retrying input."})
    except subprocess.TimeoutExpired:
        return tool_result({"ok": False, "error": "Helper timed out. Input may be partially applied; inspect the UI before retrying."})
    except (ValueError, OSError, KeyError, TypeError):
        # Do not leak typed text, command arguments, or arbitrary helper stderr.
        return tool_result({"ok": False, "error": "Helper failed or returned invalid output. Run --doctor and check the build and macOS permissions."})


def error_response(request_id, code, message):
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


class Session:
    def __init__(self):
        self.initialized = False

    def handle(self, request):
        if not isinstance(request, dict) or request.get("jsonrpc") != "2.0" or not isinstance(request.get("method"), str):
            return error_response(None, -32600, "Invalid JSON-RPC request")
        # A notification must never trigger an input action or receive a response.
        if "id" not in request:
            return None
        request_id = request["id"]
        if type(request_id) not in (str, int):
            return error_response(None, -32600, "id must be a string or integer")
        try:
            method, params = request["method"], request.get("params", {})
            if not isinstance(params, dict):
                raise RPCError(-32602, "params must be an object")
            if method == "initialize":
                if self.initialized:
                    raise RPCError(-32600, "Session is already initialized")
                version = params.get("protocolVersion")
                if not isinstance(version, str) or not isinstance(params.get("capabilities"), dict) or not isinstance(params.get("clientInfo"), dict):
                    raise RPCError(-32602, "Invalid initialization parameters")
                self.initialized = True
                result = {"protocolVersion": version if version in PROTOCOLS else PROTOCOLS[0],
                          "capabilities": {"tools": {"listChanged": False}},
                          "serverInfo": {"name": "setalight-local-input", "version": VERSION}, "instructions": INSTRUCTIONS}
            elif method == "ping":
                result = {}
            elif not self.initialized:
                raise RPCError(-32002, "Initialize the server first")
            elif method == "tools/list":
                if params.get("cursor") not in (None, ""):
                    raise RPCError(-32602, "Unknown cursor; all tools are returned in one page")
                result = {"tools": TOOLS}
            elif method == "tools/call":
                result = call_tool(params.get("name"), params.get("arguments", {}))
            else:
                raise RPCError(-32601, "Method not found")
            return {"jsonrpc": "2.0", "id": request_id, "result": result}
        except RPCError as exc:
            return error_response(request_id, exc.code, exc.message)
        except Exception:
            return error_response(request_id, -32603, "Internal server error")


def run_server(source=None, sink=None):
    source = source if source is not None else sys.stdin.buffer
    sink = sink if sink is not None else sys.stdout
    session = Session()
    while True:
        line = source.readline(MAX_LINE + 1)
        if not line:
            break
        if len(line) > MAX_LINE:
            while not line.endswith(b"\n"):
                line = source.readline(MAX_LINE + 1)
                if not line:
                    break
            response = error_response(None, -32600, "Request exceeds 1 MiB")
        elif not line.strip():
            continue
        else:
            try:
                response = session.handle(json_loads(line))
            except (ValueError, UnicodeError):
                response = error_response(None, -32700, "Parse error")
        if response is not None:
            sink.write(json.dumps(response, ensure_ascii=True, allow_nan=False) + "\n")
            sink.flush()


def client_config(client):
    executable = str(Path(sys.executable).resolve())
    script = str(ROOT / "server.py")
    if client == "claude-code":
        return shlex.join(["claude", "mcp", "add", "--transport", "stdio", "--scope", "user", "setalight", "--", executable, script])
    if client == "codex-cli":
        return shlex.join(["codex", "mcp", "add", "setalight", "--", executable, script])
    if client == "codex":
        return "\n".join([
            "[mcp_servers.setalight]",
            "command = " + json.dumps(executable, ensure_ascii=False),
            "args = " + json.dumps([script], ensure_ascii=False),
            "startup_timeout_sec = 10",
            "tool_timeout_sec = 150",
        ])
    if client == "claude-desktop":
        return json.dumps({"mcpServers": {"setalight": {"command": executable, "args": [script]}}}, indent=2)
    raise ValueError("Unknown MCP client")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--call", choices=BY_NAME, help="Call one tool; no MCP session required")
    modes.add_argument("--config", choices=("claude-desktop", "claude-code", "codex", "codex-cli"), help="Print configuration; does not change client settings")
    modes.add_argument("--doctor", action="store_true", help="Read-only platform/build/permission diagnostics")
    modes.add_argument("--version", action="version", version=VERSION)
    parser.add_argument("--args", default="{}", help="Tool arguments as a JSON object")
    options = parser.parse_args()
    if options.config:
        print(client_config(options.config))
        return 0
    if options.call or options.doctor:
        try:
            result = call_tool(options.call or "status", json_loads(options.args) if options.call else {})
            print(json.dumps(result, ensure_ascii=True, indent=2))
            return int(result["isError"])
        except (RPCError, ValueError) as exc:
            print(str(exc), file=sys.stderr)
            return 2
    try:
        run_server()
    except (BrokenPipeError, KeyboardInterrupt):
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
