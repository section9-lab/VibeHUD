//
//  AccessibilityFallbackReplyTransport.swift
//  VibeHUD
//
//  Fallback transport that injects text via Accessibility keystrokes.
//

import Foundation

struct AccessibilityFallbackReplyTransport: ReplyTransport {
    let id = "accessibility-fallback"

    func canHandle(_ context: ReplyContext) -> Bool {
        context.claudePid != nil || context.terminalPid != nil
    }

    func send(_ payload: ReplyPayload, context: ReplyContext) async -> Bool {
        guard let pid = context.claudePid ?? context.terminalPid else { return false }
        return await TtyMessageSender(
            pid: pid,
            terminalPidHint: context.terminalPid
        ).sendMessage(payload.text)
    }
}
