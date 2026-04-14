//
//  TtyMessageSender.swift
//  VibeHUD
//
//  Sends messages to a Claude Code session by writing directly to its tty device.
//  Works with any terminal (Ghostty, iTerm2, Terminal.app, etc.) without requiring tmux.
//

import Foundation

struct TtyMessageSender {
    let ttyPath: String  // e.g. "ttys001" (without /dev/ prefix)

    func sendMessage(_ message: String) async -> Bool {
        let fullPath = "/dev/\(ttyPath)"
        let fd = open(fullPath, O_WRONLY | O_NOCTTY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let text = message + "\n"
        let bytes = Array(text.utf8)
        return write(fd, bytes, bytes.count) == bytes.count
    }
}
