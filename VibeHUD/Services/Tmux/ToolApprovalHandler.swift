//
//  ToolApprovalHandler.swift
//  VibeHUD
//
//  Handles Claude tool approval operations via tmux
//

import Foundation
import os.log

/// Handles tool approval and rejection for Claude instances
actor ToolApprovalHandler {
    static let shared = ToolApprovalHandler()

    /// Logger for tool approval (nonisolated static for cross-context access)
    nonisolated static let logger = Logger(subsystem: "com.vibehud", category: "Approval")

    private init() {}

    /// Approve a tool once (sends '1' + Enter)
    func approveOnce(target: TmuxTarget) async -> Bool {
        await sendKeys(to: target, keys: "1", pressEnter: true)
    }

    /// Approve a tool always (sends '2' + Enter)
    func approveAlways(target: TmuxTarget) async -> Bool {
        await sendKeys(to: target, keys: "2", pressEnter: true)
    }

    /// Reject a tool with optional message
    func reject(target: TmuxTarget, message: String? = nil) async -> Bool {
        // First send 'n' + Enter to reject
        guard await sendKeys(to: target, keys: "n", pressEnter: true) else {
            return false
        }

        // If there's a message, send it after a brief delay
        if let message = message, !message.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
            return await sendKeys(to: target, keys: message, pressEnter: true)
        }

        return true
    }

    /// Send a message to a tmux target
    func sendMessage(_ message: String, to target: TmuxTarget, tmuxSocketPath: String? = nil) async -> Bool {
        await sendKeys(toTargetString: target.targetString, keys: message, pressEnter: true, tmuxSocketPath: tmuxSocketPath)
    }

    /// Send a message to a raw tmux target string (e.g. "%12" or "session:window.pane")
    func sendMessage(_ message: String, toTargetString target: String, tmuxSocketPath: String? = nil) async -> Bool {
        await sendKeys(toTargetString: target, keys: message, pressEnter: true, tmuxSocketPath: tmuxSocketPath)
    }

    // MARK: - Private Methods

    private func sendKeys(to target: TmuxTarget, keys: String, pressEnter: Bool, tmuxSocketPath: String? = nil) async -> Bool {
        await sendKeys(toTargetString: target.targetString, keys: keys, pressEnter: pressEnter, tmuxSocketPath: tmuxSocketPath)
    }

    private func sendKeys(toTargetString targetStr: String, keys: String, pressEnter: Bool, tmuxSocketPath: String? = nil) async -> Bool {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return false
        }

        // tmux send-keys needs literal text and Enter as separate arguments
        // Use -l flag to send keys literally (prevents interpreting special chars)
        var prefixArgs: [String] = []
        if let tmuxSocketPath, !tmuxSocketPath.isEmpty {
            prefixArgs = ["-S", tmuxSocketPath]
        }
        let textArgs = prefixArgs + ["send-keys", "-t", targetStr, "-l", keys]

        do {
            Self.logger.debug("Sending text to \(targetStr, privacy: .public)")
            _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: textArgs)

            // Send Enter as a separate command if needed
            if pressEnter {
                Self.logger.debug("Sending Enter key")
                let enterArgs = prefixArgs + ["send-keys", "-t", targetStr, "Enter"]
                _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: enterArgs)
            }
            return true
        } catch {
            Self.logger.error("Error: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
