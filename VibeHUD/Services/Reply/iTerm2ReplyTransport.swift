//
//  iTerm2ReplyTransport.swift
//  VibeHUD
//
//  Sends replies via iTerm2 AppleScript.
//

import Foundation

struct ITerm2ReplyTransport: ReplyTransport {
    let id = "iterm2"

    func canHandle(_ context: ReplyContext) -> Bool {
        context.terminalBundleId == "com.googlecode.iterm2" && context.tty != nil
    }

    func send(_ payload: ReplyPayload, context: ReplyContext) async -> Bool {
        guard let tty = context.tty, !tty.isEmpty else { return false }
        let escaped = AppleScriptEscape.escape(payload.text)
        let targetTty = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        let script = """
        tell application "iTerm2"
            set targetTTY to "\(targetTty)"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is targetTTY then
                            tell s to write text "\(escaped)"
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
            if (count of windows) > 0 then
                tell current session of current window to write text "\(escaped)"
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

enum AppleScriptEscape {
    nonisolated static func escape(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
