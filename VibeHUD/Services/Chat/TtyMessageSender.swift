//
//  TtyMessageSender.swift
//  VibeHUD
//
//  Sends messages to a Claude Code session running in a non-tmux terminal
//  by using osascript to inject keystrokes via System Events.
//

import AppKit
import Foundation

struct TtyMessageSender {
    let pid: Int  // Claude process PID

    func sendMessage(_ message: String) async -> Bool {
        // Walk up the process tree to find the parent terminal app PID
        let tree = ProcessTreeBuilder.shared.buildTree()
        guard let terminalPid = ProcessTreeBuilder.shared.findTerminalPid(forProcess: pid, tree: tree) else {
            return false
        }

        // Escape the message for AppleScript string literal
        let escaped = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        // Use System Events to keystroke into the terminal process
        // This requires Accessibility permission (already requested by VibeHUD)
        let script = """
        tell application "System Events"
            set frontApp to name of first application process whose frontmost is true
            set targetProc to first application process whose unix id is \(terminalPid)
            set frontmost of targetProc to true
            delay 0.1
            keystroke "\(escaped)"
            key code 36
            delay 0.05
            set frontmost of first application process whose name is frontApp to true
        end tell
        """

        do {
            _ = try await ProcessExecutor.shared.run(
                "/usr/bin/osascript",
                arguments: ["-e", script]
            )
            return true
        } catch {
            return false
        }
    }
}
