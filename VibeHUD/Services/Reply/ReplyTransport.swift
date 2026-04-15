//
//  ReplyTransport.swift
//  VibeHUD
//
//  Transport abstraction for sending interactive replies back to Claude.
//

import Foundation

struct ReplyPayload: Sendable {
    let text: String
}

protocol ReplyTransport: Sendable {
    var id: String { get }
    func canHandle(_ context: ReplyContext) -> Bool
    func send(_ payload: ReplyPayload, context: ReplyContext) async -> Bool
}

