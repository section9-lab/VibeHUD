//
//  HookInstaller.swift
//  VibeHUD
//
//  Auto-installs Claude Code hooks on app launch
//

import Foundation

struct HookInstaller {

    /// Install hook script and update settings.json on app launch
    static func installIfNeeded() {
        let hooksDir = ClaudePaths.hooksDir
        let pythonScript = hooksDir.appendingPathComponent("vibe-hud-state.py")
        let bridgeScript = ClaudePaths.bridgeScriptPath
        let ttyBridgeScript = hooksDir.appendingPathComponent("vibe-hud-tty-bridge.py")
        let bridgeLauncher = ClaudePaths.bridgeLauncherPath

        try? FileManager.default.createDirectory(
            at: hooksDir,
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            at: ClaudePaths.binDir,
            withIntermediateDirectories: true
        )

        installScript(resource: "vibe-hud-state", to: pythonScript)
        installScript(resource: "vibe-hud-bridge", to: bridgeScript)
        installScript(resource: "vibe-hud-tty-bridge", to: ttyBridgeScript)
        installCodexHooksIfNeeded()
        installOpenCodeHooksIfNeeded()

        let launcher = """
        #!/bin/sh
        exec \(detectPython()) \(ClaudePaths.bridgeScriptShellPath) "$@"
        """
        try? launcher.write(to: bridgeLauncher, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: bridgeLauncher.path
        )

        updateSettings(at: ClaudePaths.settingsFile)
    }

    private static func installCodexHooksIfNeeded() {
        try? FileManager.default.createDirectory(
            at: CodexPaths.hooksDir,
            withIntermediateDirectories: true
        )

        installScript(resource: "vibe-hud-state", to: CodexPaths.hookScriptPath)
        updateCodexHooks(at: CodexPaths.hooksFile)
    }

    private static func installOpenCodeHooksIfNeeded() {
        try? FileManager.default.createDirectory(
            at: OpenCodePaths.pluginDir,
            withIntermediateDirectories: true
        )

        installScript(resource: "vibe-hud", to: OpenCodePaths.pluginFile, extension: "js")
        updateOpenCodeConfig(at: OpenCodePaths.configFile)
    }

    private static func updateSettings(at settingsURL: URL) {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        let python = detectPython()
        let command = "\(python) \(ClaudePaths.hookScriptShellPath) --source claude"
        let hookEntry: [[String: Any]] = [["type": "command", "command": command]]
        let hookEntryWithTimeout: [[String: Any]] = [["type": "command", "command": command, "timeout": 86400]]
        let withMatcher: [[String: Any]] = [["matcher": "*", "hooks": hookEntry]]
        let withMatcherAndTimeout: [[String: Any]] = [["matcher": "*", "hooks": hookEntryWithTimeout]]
        let withoutMatcher: [[String: Any]] = [["hooks": hookEntry]]
        let preCompactConfig: [[String: Any]] = [
            ["matcher": "auto", "hooks": hookEntry],
            ["matcher": "manual", "hooks": hookEntry]
        ]

        var hooks = json["hooks"] as? [String: Any] ?? [:]

        let hookEvents: [(String, [[String: Any]])] = [
            ("UserPromptSubmit", withoutMatcher),
            ("PreToolUse", withMatcher),
            ("PostToolUse", withMatcher),
            // PostToolUseFailure fires when a tool errored or was interrupted — we
            // currently miss these signals entirely (v2.0.x+)
            ("PostToolUseFailure", withMatcher),
            ("PermissionRequest", withMatcherAndTimeout),
            // PermissionDenied surfaces auto-mode classifier denials (v2.1.88+)
            ("PermissionDenied", withMatcher),
            ("Notification", withMatcher),
            ("Stop", withoutMatcher),
            // StopFailure fires on API errors (rate limit, auth, billing) — lets
            // us show the failure in the notch instead of appearing stuck (v2.1.78+)
            ("StopFailure", withoutMatcher),
            // SubagentStart pairs with existing SubagentStop (v2.0.43+)
            ("SubagentStart", withoutMatcher),
            ("SubagentStop", withoutMatcher),
            ("SessionStart", withoutMatcher),
            ("SessionEnd", withoutMatcher),
            ("PreCompact", preCompactConfig),
            // PostCompact pairs with PreCompact so the UI can exit the
            // .compacting phase cleanly (v2.1.76+)
            ("PostCompact", preCompactConfig),
        ]

        for (event, config) in hookEvents {
            let existingEvent = hooks[event] as? [[String: Any]] ?? []
            let cleanedEvent = existingEvent.compactMap { removingVibeHUDHooks(from: $0) }
            hooks[event] = cleanedEvent + config
        }

        json["hooks"] = hooks

        if let data = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: settingsURL)
        }
    }

    private static func updateCodexHooks(at hooksURL: URL) {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: hooksURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        let python = detectPython()
        let command = "\(python) \(CodexPaths.hookScriptShellPath) --source codex"
        let hookEntry: [[String: Any]] = [[
            "type": "command",
            "command": command,
            "timeout": 10
        ]]
        let vibeHUDEventEntry: [String: Any] = ["hooks": hookEntry]

        var hooks = json["hooks"] as? [String: Any] ?? [:]
        let hookEvents = ["SessionStart", "UserPromptSubmit", "Stop", "PreToolUse", "PostToolUse"]

        for event in hookEvents {
            let existingEvent = hooks[event] as? [[String: Any]] ?? []
            let cleanedEvent = existingEvent.compactMap { removingVibeHUDHooks(from: $0) }
            hooks[event] = cleanedEvent + [vibeHUDEventEntry]
        }

        json["hooks"] = hooks

        if let data = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: hooksURL)
        }
    }

    private static func updateOpenCodeConfig(at configURL: URL) {
        var json: [String: Any] = [
            "$schema": "https://opencode.ai/config.json"
        ]
        if let data = try? Data(contentsOf: configURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        var plugins = json["plugin"] as? [String] ?? []
        plugins.removeAll(where: isVibeHUDOpenCodePlugin)
        plugins.append(OpenCodePaths.pluginFileURLString)
        json["plugin"] = plugins

        if let data = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: configURL)
        }
    }

    /// Check if hooks are currently installed
    static func isInstalled() -> Bool {
        isInstalled(at: ClaudePaths.settingsFile) ||
        isInstalled(at: CodexPaths.hooksFile) ||
        isInstalledOpenCode(at: OpenCodePaths.configFile)
    }

    /// Uninstall hooks from settings.json and remove script
    static func uninstall() {
        let hooksDir = ClaudePaths.hooksDir
        let pythonScript = hooksDir.appendingPathComponent("vibe-hud-state.py")
        let bridgeScript = ClaudePaths.bridgeScriptPath
        let ttyBridgeScript = hooksDir.appendingPathComponent("vibe-hud-tty-bridge.py")
        let bridgeLauncher = ClaudePaths.bridgeLauncherPath
        let settings = ClaudePaths.settingsFile

        try? FileManager.default.removeItem(at: pythonScript)
        try? FileManager.default.removeItem(at: bridgeScript)
        try? FileManager.default.removeItem(at: ttyBridgeScript)
        try? FileManager.default.removeItem(at: bridgeLauncher)
        try? FileManager.default.removeItem(at: CodexPaths.hookScriptPath)
        try? FileManager.default.removeItem(at: OpenCodePaths.pluginFile)

        removeHooks(at: settings)
        removeHooks(at: CodexPaths.hooksFile)
        removeOpenCodePlugin(at: OpenCodePaths.configFile)
    }

    private static func isInstalled(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }

        for (_, value) in hooks {
            if let entries = value as? [[String: Any]] {
                for entry in entries {
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        for hook in entryHooks {
                            if let cmd = hook["command"] as? String,
                               cmd.contains("vibe-hud-state.py") {
                                return true
                            }
                        }
                    }
                }
            }
        }
        return false
    }

    private static func removeHooks(at url: URL) {
        guard let data = try? Data(contentsOf: url),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = json["hooks"] as? [String: Any] else {
            return
        }

        for (event, value) in hooks {
            if var entries = value as? [[String: Any]] {
                entries = entries.compactMap { removingVibeHUDHooks(from: $0) }

                if entries.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = entries
                }
            }
        }

        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooks
        }

        if let updated = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? updated.write(to: url)
        }
    }

    private static func removeOpenCodePlugin(at url: URL) {
        guard let data = try? Data(contentsOf: url),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        var plugins = json["plugin"] as? [String] ?? []
        plugins.removeAll(where: isVibeHUDOpenCodePlugin)

        if plugins.isEmpty {
            json.removeValue(forKey: "plugin")
        } else {
            json["plugin"] = plugins
        }

        if let updated = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? updated.write(to: url)
        }
    }

    private static func isInstalledOpenCode(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = json["plugin"] as? [String] else {
            return false
        }

        return plugins.contains(where: isVibeHUDOpenCodePlugin)
    }

    private static func installScript(resource: String, to destination: URL, extension ext: String = "py") {
        guard let bundled = Bundle.main.url(forResource: resource, withExtension: ext) else { return }
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: bundled, to: destination)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
    }

    private static func detectPython() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["python3"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return "python3"
            }
        } catch {}

        return "python"
    }

    nonisolated private static func removingVibeHUDHooks(from entry: [String: Any]) -> [String: Any]? {
        guard var entryHooks = entry["hooks"] as? [[String: Any]] else {
            return entry
        }

        entryHooks.removeAll(where: isVibeHUDHook)
        guard !entryHooks.isEmpty else { return nil }

        var updatedEntry = entry
        updatedEntry["hooks"] = entryHooks
        return updatedEntry
    }

    nonisolated private static func isVibeHUDHook(_ hook: [String: Any]) -> Bool {
        let cmd = hook["command"] as? String ?? ""
        return cmd.contains("vibe-hud-state.py")
    }

    nonisolated private static func isVibeHUDOpenCodePlugin(_ plugin: String) -> Bool {
        plugin == OpenCodePaths.pluginFileURLString || plugin.contains("/plugin/vibe-hud.js")
    }
}
