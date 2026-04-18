#!/usr/bin/env python3
"""
Per-session TTY bridge for VibeHUD.

Listens on a Unix socket and writes incoming text to a target TTY, so VibeHUD
can send messages without terminal-specific UI automation.
"""

import argparse
import fcntl
import json
import os
import select
import signal
import socket
import sys
import termios
import time

PROTOCOL = "v4"


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True, dest="socket_path")
    parser.add_argument("--tty", required=True, dest="tty_path")
    parser.add_argument("--idle-timeout", type=int, default=21600)  # 6h
    return parser.parse_args()


def cleanup(path):
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    except OSError:
        pass


def write_to_tty(tty_path, text, submit, submit_sequence):
    fd = os.open(tty_path, os.O_RDWR | os.O_NOCTTY)
    try:
        tiocsti = getattr(termios, "TIOCSTI", None)
        if tiocsti is None:
            raise RuntimeError("TIOCSTI unavailable")

        payload = text.encode("utf-8", errors="ignore")
        if submit_sequence:
            payload += submit_sequence.encode("utf-8", errors="ignore")
        if submit:
            payload += b"\r"
        for byte in payload:
            fcntl.ioctl(fd, tiocsti, bytes([byte]))
    finally:
        os.close(fd)


def run_server(socket_path, tty_path, idle_timeout):
    cleanup(socket_path)

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(socket_path)
    os.chmod(socket_path, 0o600)
    server.listen(8)
    server.setblocking(False)

    running = True

    def stop_handler(_signum, _frame):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, stop_handler)
    signal.signal(signal.SIGINT, stop_handler)

    last_activity = time.time()

    try:
        while running:
            if time.time() - last_activity > idle_timeout:
                break

            readable, _, _ = select.select([server], [], [], 1.0)
            if not readable:
                continue

            client, _ = server.accept()
            client.settimeout(1.0)
            try:
                data = client.recv(65536)
                if not data:
                    client.sendall(b"error")
                    continue

                try:
                    payload = json.loads(data.decode("utf-8", errors="ignore"))
                except Exception:
                    payload = {}

                if payload.get("ping") is True:
                    client.sendall(f"ok-{PROTOCOL}".encode())
                    last_activity = time.time()
                    continue

                text = payload.get("text", "")
                submit = payload.get("submit", True)
                submit_sequence = payload.get("submit_sequence", "")
                allow_empty = payload.get("allow_empty", False)
                if not isinstance(text, str):
                    client.sendall(b"error")
                    continue
                if not isinstance(submit_sequence, str):
                    submit_sequence = ""
                if not isinstance(allow_empty, bool):
                    allow_empty = False
                if not text and not submit_sequence and not (allow_empty and submit):
                    client.sendall(b"error")
                    continue
                if not isinstance(submit, bool):
                    submit = True

                write_to_tty(tty_path, text, submit, submit_sequence)
                client.sendall(b"ok")
                last_activity = time.time()
            except Exception:
                try:
                    client.sendall(b"error")
                except Exception:
                    pass
            finally:
                try:
                    client.close()
                except Exception:
                    pass
    finally:
        try:
            server.close()
        except Exception:
            pass
        cleanup(socket_path)


def main():
    args = parse_args()
    if not os.path.exists(args.tty_path):
        sys.exit(1)
    run_server(args.socket_path, args.tty_path, args.idle_timeout)


if __name__ == "__main__":
    main()
