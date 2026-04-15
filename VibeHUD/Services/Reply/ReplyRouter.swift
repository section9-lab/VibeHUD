//
//  ReplyRouter.swift
//  VibeHUD
//
//  Routes interactive replies through prioritized transports.
//

import Foundation

@MainActor
final class ReplyRouter {
    static let shared = ReplyRouter()

    private let transports: [any ReplyTransport] = [
        BridgeReplyTransport(),
        TmuxReplyTransport(),
        ITerm2ReplyTransport(),
        TerminalAppReplyTransport(),
        GhosttyReplyTransport(),
        AccessibilityFallbackReplyTransport()
    ]

    private init() {}

    func sendReply(_ text: String, for session: SessionState) async -> Bool {
        let payload = ReplyPayload(text: text)
        let context = ReplyContext(session: session)

        for transport in transports where transport.canHandle(context) {
            if await sendWithTimeout(transport, payload: payload, context: context, timeoutMs: 1500) {
                return true
            }
        }

        return false
    }

    private func sendWithTimeout(
        _ transport: any ReplyTransport,
        payload: ReplyPayload,
        context: ReplyContext,
        timeoutMs: UInt64
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await transport.send(payload, context: context)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutMs * 1_000_000)
                return false
            }

            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}
