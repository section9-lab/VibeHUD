//
//  GhosttyReplyTransport.swift
//  VibeHUD
//
//  Ghostty-specific reply transport using real key events:
//  type text as Unicode key events, then press Return.
//

import AppKit
import CoreGraphics
import Foundation

struct GhosttyReplyTransport: ReplyTransport {
    let id = "ghostty"

    func canHandle(_ context: ReplyContext) -> Bool {
        context.terminalBundleId == TerminalAppRegistry.ghosttyBundleId ||
        !NSRunningApplication.runningApplications(withBundleIdentifier: TerminalAppRegistry.ghosttyBundleId).isEmpty
    }

    func send(_ payload: ReplyPayload, context: ReplyContext) async -> Bool {
        guard let app = resolveGhosttyApp(context: context) else {
            return false
        }
        let targetPid = app.processIdentifier

        app.activate()
        try? await Task.sleep(for: .milliseconds(90))

        var sent = typeAndSubmitViaPid(payload.text, pid: targetPid)
        if !sent {
            sent = typeAndSubmitGlobally(payload.text)
        }
        if !sent {
            sent = await typeAndSubmitViaSystemEvents(payload.text, targetPid: targetPid)
        }

        return sent
    }

    private func resolveGhosttyApp(context: ReplyContext) -> NSRunningApplication? {
        if let terminalPid = context.terminalPid,
           let app = NSRunningApplication(processIdentifier: pid_t(terminalPid)),
           app.bundleIdentifier == TerminalAppRegistry.ghosttyBundleId {
            return app
        }

        let running = NSRunningApplication.runningApplications(withBundleIdentifier: TerminalAppRegistry.ghosttyBundleId)
        if running.count == 1 {
            return running[0]
        }

        if let frontmost = running.first(where: { $0.isActive }) {
            return frontmost
        }

        return running.first
    }

    private func typeAndSubmitViaPid(_ text: String, pid: pid_t) -> Bool {
        typeStringToPid(text, pid: pid) &&
        postKeyPairToPid(keyCode: 36, flags: [], to: pid)
    }

    private func typeAndSubmitGlobally(_ text: String) -> Bool {
        typeStringGlobally(text) &&
        postKeyPairGlobal(keyCode: 36, flags: [])
    }

    private func typeAndSubmitViaSystemEvents(_ text: String, targetPid: pid_t) async -> Bool {
        let escaped = AppleScriptEscape.escape(text)
        let script = """
        tell application "System Events"
            set targetProc to first application process whose unix id is \(targetPid)
            set frontmost of targetProc to true
            delay 0.05
            keystroke "\(escaped)"
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

    private func typeStringToPid(_ text: String, pid: pid_t) -> Bool {
        for unit in text.utf16 {
            guard postUnicodeToPid(unit, pid: pid) else { return false }
        }
        return true
    }

    private func typeStringGlobally(_ text: String) -> Bool {
        for unit in text.utf16 {
            guard postUnicodeGlobal(unit) else { return false }
        }
        return true
    }

    private func postUnicodeToPid(_ codeUnit: UInt16, pid: pid_t) -> Bool {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            return false
        }
        var value = codeUnit
        down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
        up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }

    private func postUnicodeGlobal(_ codeUnit: UInt16) -> Bool {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            return false
        }
        var value = codeUnit
        down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
        up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func postKeyPairToPid(keyCode: CGKeyCode, flags: CGEventFlags, to pid: pid_t) -> Bool {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            return false
        }
        down.flags = flags
        up.flags = flags
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }

    private func postKeyPairGlobal(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            return false
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
