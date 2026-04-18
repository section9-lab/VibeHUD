//
//  TerminalAppReplyTransport.swift
//  VibeHUD
//
//  Sends replies via Terminal.app AppleScript.
//

import Foundation

struct TerminalAppReplyTransport: ReplyTransport {
    let id = "terminal-app"

    func canHandle(_ context: ReplyContext) -> Bool {
        context.terminalBundleId == TerminalAppRegistry.terminalAppBundleId && context.tty != nil
    }

    func send(_ payload: ReplyPayload, context: ReplyContext) async -> Bool {
        guard let tty = context.tty, !tty.isEmpty else { return false }
        let escaped = AppleScriptEscape.escape(payload.text)
        let targetTty = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        let script = """
        tell application "Terminal"
            set targetTTY to "\(targetTty)"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is targetTTY then
                        do script "\(escaped)" in t
                        return "ok"
                    end if
                end repeat
            end repeat
            if (count of windows) > 0 then
                do script "\(escaped)" in selected tab of front window
                return "ok"
            else
                return "not_found"
            end if
        end tell
        """

        do {
            let output = try await ProcessExecutor.shared.run("/usr/bin/osascript", arguments: ["-e", script])
            return output.trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
        } catch {
            return false
        }
    }
}
