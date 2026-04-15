//
//  TmuxReplyTransport.swift
//  VibeHUD
//
//  Sends replies to tmux panes.
//

import Foundation

struct TmuxReplyTransport: ReplyTransport {
    let id = "tmux"

    func canHandle(_ context: ReplyContext) -> Bool {
        context.isInTmux
    }

    func send(_ payload: ReplyPayload, context: ReplyContext) async -> Bool {
        guard let target = await resolveTarget(context) else { return false }
        return await ToolApprovalHandler.shared.sendMessage(
            payload.text,
            toTargetString: target,
            tmuxSocketPath: context.tmuxSocketPath
        )
    }

    private func resolveTarget(_ context: ReplyContext) async -> String? {
        if let tmuxPane = context.tmuxPane,
           !tmuxPane.isEmpty {
            return tmuxPane
        }

        guard let tty = context.tty,
              let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return nil
        }

        var args: [String] = []
        if let socket = context.tmuxSocketPath, !socket.isEmpty {
            args += ["-S", socket]
        }
        args += ["list-panes", "-a", "-F", "#{pane_id} #{pane_tty}"]

        do {
            let output = try await ProcessExecutor.shared.run(tmuxPath, arguments: args)
            let lines = output.components(separatedBy: "\n")
            for line in lines {
                let parts = line.components(separatedBy: " ")
                guard parts.count >= 2 else { continue }
                let paneTty = parts[1].replacingOccurrences(of: "/dev/", with: "")
                if paneTty == tty {
                    return parts[0]
                }
            }
        } catch {
            return nil
        }

        return nil
    }
}
