//
//  BridgeReplyTransport.swift
//  VibeHUD
//
//  Sends replies through the user-space Claude input bridge socket.
//

import Foundation
import AppKit
import CoreGraphics

struct BridgeReplyTransport: ReplyTransport {
    let id = "bridge"
    private let ghosttyBundleId = "com.mitchellh.ghostty"

    func canHandle(_ context: ReplyContext) -> Bool {
        guard let socket = context.inputSocketPath else { return false }
        return !socket.isEmpty
    }

    func send(_ payload: ReplyPayload, context: ReplyContext) async -> Bool {
        guard let socket = context.inputSocketPath else { return false }
        let isGhostty = context.terminalBundleId == ghosttyBundleId
        let textSent = await ClaudeInputBridgeClient.shared.sendMessage(
            payload.text,
            toSocketPath: socket,
            submit: !isGhostty
        )
        guard textSent else { return false }

        // Ghostty: keep text insertion and submit as two separate steps.
        // Manual testing shows plain Enter is the right submit key.
        if isGhostty {
            let bridgeSubmit = await ClaudeInputBridgeClient.shared.sendMessage(
                "",
                toSocketPath: socket,
                submit: true,
                allowEmpty: true
            )
            if bridgeSubmit {
                return true
            }
            return await pressGhosttySubmit(context: context)
        }

        return true
    }

    private func pressGhosttySubmit(context: ReplyContext) async -> Bool {
        let pid = resolveGhosttyPid(context: context)
        if let pid {
            let app = NSRunningApplication(processIdentifier: pid)
            app?.activate()
        }
        try? await Task.sleep(for: .milliseconds(120))

        if await submitEnterViaSystemEvents(pid: pid) {
            return true
        }
        if let pid, postReturnToPid(pid) {
            return true
        }
        if postReturnGlobal() {
            return true
        }
        return false
    }

    private func resolveGhosttyPid(context: ReplyContext) -> pid_t? {
        if let terminalPid = context.terminalPid {
            return pid_t(terminalPid)
        }
        return NSRunningApplication.runningApplications(withBundleIdentifier: ghosttyBundleId).first?.processIdentifier
    }

    private func postReturnToPid(_ pid: pid_t) -> Bool {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: false) else {
            return false
        }
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }

    private func postReturnGlobal() -> Bool {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: false) else {
            return false
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func submitEnterViaSystemEvents(pid: pid_t?) async -> Bool {
        let pidScript: String
        if let pid {
            pidScript = """
            set targetProc to first application process whose unix id is \(pid)
            set frontmost of targetProc to true
            """
        } else {
            pidScript = ""
        }

        let script = """
        tell application "System Events"
            \(pidScript)
            delay 0.05
            key code 36
        end tell
        """

        do {
            _ = try await ProcessExecutor.shared.run("/usr/bin/osascript", arguments: ["-e", script])
            return true
        } catch {
            return false
        }
    }
}
