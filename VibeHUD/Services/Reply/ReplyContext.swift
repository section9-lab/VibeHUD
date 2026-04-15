//
//  ReplyContext.swift
//  VibeHUD
//
//  Routing context derived from a session for interactive reply delivery.
//

import AppKit
import Foundation

struct ReplyContext: Sendable {
    let sessionId: String
    let claudePid: Int?
    let tty: String?
    let inputSocketPath: String?
    let isInTmux: Bool
    let tmuxPane: String?
    let tmuxSocketPath: String?
    let terminalPid: Int?
    let terminalBundleId: String?
}

extension ReplyContext {
    init(session: SessionState) {
        var resolvedTerminalPid = session.terminalPid
        var resolvedTerminalBundleId = session.terminalBundleId

        if (resolvedTerminalPid == nil || resolvedTerminalBundleId == nil),
           let pid = session.pid {
            let tree = ProcessTreeBuilder.shared.buildTree()

            if resolvedTerminalPid == nil {
                resolvedTerminalPid = ProcessTreeBuilder.shared.findTerminalPid(forProcess: pid, tree: tree)
            }

            if resolvedTerminalBundleId == nil,
               let terminalPid = resolvedTerminalPid,
               let app = NSRunningApplication(processIdentifier: pid_t(terminalPid)) {
                resolvedTerminalBundleId = app.bundleIdentifier
            }
        }

        self.sessionId = session.sessionId
        self.claudePid = session.pid
        self.tty = session.tty
        self.inputSocketPath = session.inputSocketPath
        self.isInTmux = session.isInTmux
        self.tmuxPane = session.tmuxPane
        self.tmuxSocketPath = session.tmuxSocketPath
        self.terminalPid = resolvedTerminalPid
        self.terminalBundleId = resolvedTerminalBundleId
    }
}

