#!/usr/bin/env python3
"""
VibeHUD Hook
- Sends session state to VibeHUD.app via Unix socket
- For PermissionRequest: waits for user decision from the app
"""
import json
import os
import socket
import subprocess
import sys
import time

SOCKET_PATH = "/tmp/vibe-hud.sock"
TIMEOUT_SECONDS = 300  # 5 minutes for permission decisions
TTY_BRIDGE_PROTOCOL = "v4"


def get_tty():
    """Get the TTY of the Claude process (parent)"""
    # Get parent PID (Claude process)
    ppid = os.getppid()

    # Try to get TTY from ps command for the parent process
    try:
        result = subprocess.run(
            ["ps", "-p", str(ppid), "-o", "tty="],
            capture_output=True,
            text=True,
            timeout=2
        )
        tty = result.stdout.strip()
        if tty and tty != "??" and tty != "-":
            # ps returns just "ttys001", we need "/dev/ttys001"
            if not tty.startswith("/dev/"):
                tty = "/dev/" + tty
            return tty
    except Exception:
        pass

    # Fallback: try current process stdin/stdout
    try:
        return os.ttyname(sys.stdin.fileno())
    except (OSError, AttributeError):
        pass
    try:
        return os.ttyname(sys.stdout.fileno())
    except (OSError, AttributeError):
        pass
    return None


def get_process_command(pid):
    """Get process command name for a pid."""
    try:
        result = subprocess.run(
            ["ps", "-p", str(pid), "-o", "comm="],
            capture_output=True,
            text=True,
            timeout=2
        )
        cmd = result.stdout.strip()
        return cmd if cmd else None
    except Exception:
        return None


def find_terminal_pid(start_pid):
    """Walk parent chain to find a known terminal process pid."""
    known = [
        "Terminal", "iTerm", "iTerm2", "Ghostty", "Warp",
        "Alacritty", "kitty", "WezTerm", "Hyper", "Tabby"
    ]

    current = start_pid
    for _ in range(20):
        try:
            result = subprocess.run(
                ["ps", "-p", str(current), "-o", "ppid=,comm="],
                capture_output=True,
                text=True,
                timeout=2
            )
            line = result.stdout.strip()
            if not line:
                return None
            parts = line.split(None, 1)
            if len(parts) < 2:
                return None
            ppid = int(parts[0])
            comm = parts[1]

            if any(name.lower() in comm.lower() for name in known):
                return current

            if ppid <= 1:
                return None
            current = ppid
        except Exception:
            return None

    return None


def map_bundle_id(command):
    """Best-effort mapping from process command to terminal bundle ID."""
    if not command:
        return None

    c = command.lower()
    if "iterm" in c:
        return "com.googlecode.iterm2"
    if c.endswith("/terminal") or c == "terminal":
        return "com.apple.Terminal"
    if "ghostty" in c:
        return "com.mitchellh.ghostty"
    if "warp" in c:
        return "dev.warp.Warp-Stable"
    if "wezterm" in c:
        return "com.github.wez.wezterm"
    if "alacritty" in c:
        return "io.alacritty"
    if "kitty" in c:
        return "net.kovidgoyal.kitty"
    if "hyper" in c:
        return "co.zeit.hyper"
    return None


def send_event(state):
    """Send event to app, return response if any"""
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(TIMEOUT_SECONDS)
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(state).encode())

        # For permission requests, wait for response
        if state.get("status") == "waiting_for_approval":
            response = sock.recv(4096)
            sock.close()
            if response:
                return json.loads(response.decode())
        else:
            sock.close()

        return None
    except (socket.error, OSError, json.JSONDecodeError):
        return None


def bridge_socket_path(session_id):
    safe = "".join(c if c.isalnum() or c in ("-", "_") else "_" for c in (session_id or "unknown"))
    return f"/tmp/vibe-hud-tty-{TTY_BRIDGE_PROTOCOL}-{safe}.sock"


def is_bridge_alive(socket_path):
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(0.25)
        sock.connect(socket_path)
        sock.sendall(json.dumps({"ping": True}).encode())
        response = sock.recv(32)
        sock.close()
        return response.strip() == f"ok-{TTY_BRIDGE_PROTOCOL}".encode()
    except Exception:
        return False


def ensure_tty_bridge(session_id, tty):
    """Ensure per-session tty bridge is running and return socket path."""
    existing = os.environ.get("VIBE_HUD_INPUT_SOCKET")
    if existing:
        return existing

    if not tty:
        return None

    socket_path = bridge_socket_path(session_id)
    if os.path.exists(socket_path) and is_bridge_alive(socket_path):
        return socket_path

    script_path = os.path.join(os.path.dirname(__file__), "vibe-hud-tty-bridge.py")
    if not os.path.exists(script_path):
        return None

    python_exec = sys.executable or "python3"
    try:
        subprocess.Popen(
            [python_exec, script_path, "--socket", socket_path, "--tty", tty],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            close_fds=True,
        )
    except Exception:
        return None

    for _ in range(8):
        if os.path.exists(socket_path) and is_bridge_alive(socket_path):
            return socket_path
        time.sleep(0.03)

    return None


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(1)

    session_id = data.get("session_id", "unknown")
    event = data.get("hook_event_name", "")
    cwd = data.get("cwd", "")
    tool_input = data.get("tool_input", {})

    # Get process info
    claude_pid = os.getppid()
    tty = get_tty()
    terminal_pid = find_terminal_pid(claude_pid)
    terminal_cmd = get_process_command(terminal_pid) if terminal_pid else None
    terminal_bundle_id = map_bundle_id(terminal_cmd)

    tmux_env = os.environ.get("TMUX", "")
    tmux_socket = tmux_env.split(",")[0] if tmux_env else None

    input_socket = ensure_tty_bridge(session_id, tty)

    # Build state object
    state = {
        "session_id": session_id,
        "cwd": cwd,
        "event": event,
        "pid": claude_pid,
        "tty": tty,
        "input_socket": input_socket,
        "terminal_pid": terminal_pid,
        "terminal_bundle_id": terminal_bundle_id,
        "tmux_pane": os.environ.get("TMUX_PANE"),
        "tmux_socket": tmux_socket,
    }

    # Map events to status
    if event == "UserPromptSubmit":
        # User just sent a message - Claude is now processing
        state["status"] = "processing"

    elif event == "PreToolUse":
        state["status"] = "running_tool"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        # Send tool_use_id to Swift for caching
        tool_use_id_from_event = data.get("tool_use_id")
        if tool_use_id_from_event:
            state["tool_use_id"] = tool_use_id_from_event

    elif event == "PostToolUse":
        state["status"] = "processing"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        # Send tool_use_id so Swift can cancel the specific pending permission
        tool_use_id_from_event = data.get("tool_use_id")
        if tool_use_id_from_event:
            state["tool_use_id"] = tool_use_id_from_event

    elif event == "PostToolUseFailure":
        # Tool errored or was interrupted — main session continues processing
        state["status"] = "processing"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        state["tool_error"] = data.get("error") or data.get("message")
        tool_use_id_from_event = data.get("tool_use_id")
        if tool_use_id_from_event:
            state["tool_use_id"] = tool_use_id_from_event

    elif event == "PermissionDenied":
        # Auto-mode classifier denied a tool call — surface to the app so the
        # user can see what was blocked instead of a silent skip
        state["status"] = "processing"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        state["denial_reason"] = data.get("reason") or data.get("message")

    elif event == "PermissionRequest":
        # This is where we can control the permission
        state["status"] = "waiting_for_approval"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        # tool_use_id lookup handled by Swift-side cache from PreToolUse

        # Send to app and wait for decision
        response = send_event(state)

        if response:
            decision = response.get("decision", "ask")
            reason = response.get("reason", "")

            if decision == "allow":
                # Output JSON to approve
                output = {
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": {"behavior": "allow"},
                    }
                }
                print(json.dumps(output))
                sys.exit(0)

            elif decision == "deny":
                # Output JSON to deny
                output = {
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": {
                            "behavior": "deny",
                            "message": reason or "Denied by user via VibeHUD",
                        },
                    }
                }
                print(json.dumps(output))
                sys.exit(0)

        # No response or "ask" - let Claude Code show its normal UI
        sys.exit(0)

    elif event == "Notification":
        notification_type = data.get("notification_type")
        # Skip permission_prompt - PermissionRequest hook handles this with better info
        if notification_type == "permission_prompt":
            sys.exit(0)
        elif notification_type == "idle_prompt":
            state["status"] = "waiting_for_input"
        else:
            state["status"] = "notification"
        state["notification_type"] = notification_type
        state["message"] = data.get("message")

    elif event == "Stop":
        state["status"] = "waiting_for_input"

    elif event == "StopFailure":
        # Turn ended via API error (rate limit, auth, billing). Mark waiting
        # so the user sees it's done (not stuck), with the error surfaced
        state["status"] = "waiting_for_input"
        state["stop_error"] = data.get("error") or data.get("message")

    elif event == "SubagentStart":
        # A subagent task is beginning — main session is still processing
        state["status"] = "processing"

    elif event == "SubagentStop":
        # SubagentStop fires when a subagent completes - main session continues processing
        state["status"] = "processing"

    elif event == "SessionStart":
        # New session starts waiting for user input
        state["status"] = "waiting_for_input"

    elif event == "SessionEnd":
        state["status"] = "ended"

    elif event == "PreCompact":
        # Context is being compacted (manual or auto)
        state["status"] = "compacting"

    elif event == "PostCompact":
        # Compaction finished — return to processing so UI exits .compacting phase
        state["status"] = "processing"

    else:
        state["status"] = "unknown"

    # Send to socket (fire and forget for non-permission events)
    send_event(state)


if __name__ == "__main__":
    main()
