#!/usr/bin/env python3
"""
User-space Claude bridge for VibeHUD.

- Launches the real Claude CLI inside a PTY so terminal UX stays intact.
- Exposes a Unix socket that VibeHUD can write answers into.
- Forwards both terminal keyboard input and socket input to Claude stdin.
"""

import json
import os
import pty
import selectors
import shutil
import signal
import socket
import struct
import subprocess
import sys
import termios
import tty
from fcntl import ioctl


def find_real_claude():
    self_path = os.path.realpath(sys.argv[0])
    candidates = []

    which_bin = shutil.which("which")
    if which_bin:
        try:
            result = subprocess.run(
                [which_bin, "-a", "claude"],
                capture_output=True,
                text=True,
                timeout=2,
                check=False,
            )
            candidates.extend(line.strip() for line in result.stdout.splitlines() if line.strip())
        except Exception:
            pass

    for candidate in candidates:
        if os.path.realpath(candidate) != self_path:
            return candidate

    for path_dir in os.environ.get("PATH", "").split(os.pathsep):
        candidate = os.path.join(path_dir, "claude")
        if os.path.exists(candidate) and os.access(candidate, os.X_OK):
            if os.path.realpath(candidate) != self_path:
                return candidate

    return None


def set_winsize(fd):
    try:
        size = ioctl(sys.stdin.fileno(), termios.TIOCGWINSZ, b"\0" * 8)
        ioctl(fd, termios.TIOCSWINSZ, size)
    except Exception:
        pass


def main():
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        real = find_real_claude()
        if not real:
            print("VibeHUD bridge could not find the real claude executable.", file=sys.stderr)
            sys.exit(1)
        os.execvp(real, [real] + sys.argv[1:])

    real_claude = find_real_claude()
    if not real_claude:
        print("VibeHUD bridge could not find the real claude executable.", file=sys.stderr)
        sys.exit(1)

    socket_path = f"/tmp/vibe-hud-input-{os.getpid()}.sock"
    try:
        os.unlink(socket_path)
    except FileNotFoundError:
        pass

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(socket_path)
    os.chmod(socket_path, 0o600)
    server.listen(5)
    server.setblocking(False)

    env = os.environ.copy()
    env["VIBE_HUD_INPUT_SOCKET"] = socket_path

    old_tty = termios.tcgetattr(sys.stdin.fileno())
    master_fd = None
    child_pid = None
    client_sockets = set()

    def cleanup(*_args):
        try:
            if server:
                server.close()
        except Exception:
            pass
        try:
            os.unlink(socket_path)
        except FileNotFoundError:
            pass

    def forward_signal(signum, _frame):
        if child_pid:
            try:
                os.kill(child_pid, signum)
            except ProcessLookupError:
                pass

    signal.signal(signal.SIGINT, forward_signal)
    signal.signal(signal.SIGTERM, forward_signal)
    signal.signal(signal.SIGQUIT, forward_signal)

    def resize_handler(_signum, _frame):
        if master_fd is not None:
            set_winsize(master_fd)

    signal.signal(signal.SIGWINCH, resize_handler)

    try:
        child_pid, master_fd = pty.fork()
        if child_pid == 0:
            os.execvpe(real_claude, [real_claude] + sys.argv[1:], env)

        set_winsize(master_fd)
        tty.setraw(sys.stdin.fileno())

        selector = selectors.DefaultSelector()
        selector.register(sys.stdin.buffer, selectors.EVENT_READ, "stdin")
        selector.register(server, selectors.EVENT_READ, "server")
        selector.register(master_fd, selectors.EVENT_READ, "pty")

        while True:
            try:
                pid, status = os.waitpid(child_pid, os.WNOHANG)
            except ChildProcessError:
                pid, status = child_pid, 0

            if pid == child_pid:
                cleanup()
                if os.WIFEXITED(status):
                    sys.exit(os.WEXITSTATUS(status))
                if os.WIFSIGNALED(status):
                    sys.exit(128 + os.WTERMSIG(status))
                sys.exit(0)

            for key, _ in selector.select(timeout=0.1):
                source = key.data

                if source == "stdin":
                    data = os.read(sys.stdin.fileno(), 65536)
                    if not data:
                        os.close(master_fd)
                        continue
                    os.write(master_fd, data)

                elif source == "pty":
                    data = os.read(master_fd, 65536)
                    if not data:
                        cleanup()
                        sys.exit(0)
                    os.write(sys.stdout.fileno(), data)

                elif source == "server":
                    client, _ = server.accept()
                    client.setblocking(False)
                    client_sockets.add(client)
                    selector.register(client, selectors.EVENT_READ, ("client", client))

                elif isinstance(source, tuple) and source[0] == "client":
                    client = source[1]
                    try:
                        data = client.recv(65536)
                    except BlockingIOError:
                        continue

                    if not data:
                        selector.unregister(client)
                        client.close()
                        client_sockets.discard(client)
                        continue

                    try:
                        payload = json.loads(data.decode())
                        text = payload.get("text", "")
                    except Exception:
                        text = ""

                    if text:
                        os.write(master_fd, text.encode() + b"\n")
                        client.sendall(b"ok")
                    else:
                        client.sendall(b"error")

                    selector.unregister(client)
                    client.close()
                    client_sockets.discard(client)

    finally:
        for client in list(client_sockets):
            try:
                client.close()
            except Exception:
                pass
        cleanup()
        try:
            termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, old_tty)
        except Exception:
            pass
