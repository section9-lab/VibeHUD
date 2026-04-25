//
//  ConversationParser.swift
//  VibeHUD
//
//  Parses Claude JSONL conversation files to extract summary and last message
//  Optimized for incremental parsing - only reads new lines since last sync
//

import Foundation
import os.log

/// Token usage information from a session
struct UsageInfo: Equatable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0

    nonisolated init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
    }

    var totalTokens: Int {
        inputTokens + outputTokens
    }

    /// Formatted string for display (e.g., "12.5K tokens")
    var formattedTotal: String {
        let total = totalTokens
        if total >= 1_000_000 {
            return String(format: "%.1fM", Double(total) / 1_000_000)
        } else if total >= 1_000 {
            return String(format: "%.1fK", Double(total) / 1_000)
        }
        return "\(total)"
    }
}

struct ConversationInfo: Equatable {
    let summary: String?
    let lastMessage: String?
    let lastMessageRole: String?  // "user", "assistant", or "tool"
    let lastToolName: String?  // Tool name if lastMessageRole is "tool"
    let firstUserMessage: String?  // Fallback title when no summary
    let lastUserMessageDate: Date?  // Timestamp of last user message (for stable sorting)
    var usage: UsageInfo = UsageInfo()  // Token usage stats
}

actor ConversationParser {
    static let shared = ConversationParser()

    /// Logger for conversation parser (nonisolated static for cross-context access)
    nonisolated static let logger = Logger(subsystem: "com.vibehud", category: "Parser")

    /// Shared ISO8601 date formatter (expensive to create, reused across all message parsing)
    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Cache of parsed conversation info, keyed by session file path
    private var cache: [String: CachedInfo] = [:]

    private var incrementalState: [String: IncrementalParseState] = [:]

    private struct CachedInfo {
        let modificationDate: Date
        let info: ConversationInfo
    }

    /// State for incremental JSONL parsing
    private struct IncrementalParseState {
        var lastFileOffset: UInt64 = 0
        var messages: [ChatMessage] = []
        var seenToolIds: Set<String> = []
        var toolIdToName: [String: String] = [:]  // Map tool_use_id to tool name
        var completedToolIds: Set<String> = []  // Tools that have received results
        var toolResults: [String: ToolResult] = [:]  // Tool results keyed by tool_use_id
        var structuredResults: [String: ToolResultData] = [:]  // Structured results keyed by tool_use_id
        var lastClearOffset: UInt64 = 0  // Offset of last /clear command (0 = none or at start)
        var clearPending: Bool = false  // True if a /clear was just detected
    }

    /// Parsed tool result data
    struct ToolResult: Equatable {
        let content: String?
        let stdout: String?
        let stderr: String?
        let isError: Bool
        let isInterrupted: Bool

        init(content: String?, stdout: String?, stderr: String?, isError: Bool) {
            self.content = content
            self.stdout = stdout
            self.stderr = stderr
            self.isError = isError
            // Detect if this was an interrupt or rejection (various formats)
            self.isInterrupted = isError && (
                content?.contains("Interrupted by user") == true ||
                content?.contains("interrupted by user") == true ||
                content?.contains("user doesn't want to proceed") == true
            )
        }
    }

    /// Parse a JSONL file to extract conversation info
    /// Uses caching based on file modification time
    func parse(sessionId: String, cwd: String, transcriptPath: String? = nil) -> ConversationInfo {
        let sessionFile = Self.sessionFilePath(sessionId: sessionId, cwd: cwd, transcriptPath: transcriptPath)

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionFile),
              let attrs = try? fileManager.attributesOfItem(atPath: sessionFile),
              let modDate = attrs[.modificationDate] as? Date else {
            return ConversationInfo(summary: nil, lastMessage: nil, lastMessageRole: nil, lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil)
        }

        if let cached = cache[sessionFile], cached.modificationDate == modDate {
            return cached.info
        }

        guard let data = fileManager.contents(atPath: sessionFile),
              let content = String(data: data, encoding: .utf8) else {
            return ConversationInfo(summary: nil, lastMessage: nil, lastMessageRole: nil, lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil)
        }

        let info = parseContent(content, filePath: sessionFile)
        cache[sessionFile] = CachedInfo(modificationDate: modDate, info: info)

        return info
    }

    /// Parse JSONL content
    private func parseContent(_ content: String, filePath: String) -> ConversationInfo {
        if isOpenCodeTranscript(filePath: filePath) {
            return parseOpenCodeConversationInfo(filePath: filePath)
        }

        if isCodexTranscript(filePath: filePath, content: content) {
            return parseCodexContent(content)
        }

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }

        var summary: String?
        var lastMessage: String?
        var lastMessageRole: String?
        var lastToolName: String?
        var firstUserMessage: String?
        var lastUserMessageDate: Date?
        var usage = UsageInfo()

        let formatter = isoFormatter

        // First pass: collect usage from all assistant messages
        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            if json["type"] as? String == "assistant",
               let message = json["message"] as? [String: Any],
               let usageDict = message["usage"] as? [String: Any] {
                usage.inputTokens += usageDict["input_tokens"] as? Int ?? 0
                usage.outputTokens += usageDict["output_tokens"] as? Int ?? 0
                usage.cacheReadTokens += usageDict["cache_read_input_tokens"] as? Int ?? 0
                usage.cacheCreationTokens += usageDict["cache_creation_input_tokens"] as? Int ?? 0
            }
        }

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let type = json["type"] as? String
            let isMeta = json["isMeta"] as? Bool ?? false

            if type == "user" && !isMeta {
                if let message = json["message"] as? [String: Any],
                   let msgContent = message["content"] as? String {
                    if !msgContent.hasPrefix("<command-name>") && !msgContent.hasPrefix("<local-command") && !msgContent.hasPrefix("Caveat:") {
                        firstUserMessage = Self.truncateMessage(msgContent, maxLength: 50)
                        break
                    }
                }
            }
        }

        var foundLastUserMessage = false
        for line in lines.reversed() {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let type = json["type"] as? String

            if lastMessage == nil {
                if type == "user" || type == "assistant" {
                    let isMeta = json["isMeta"] as? Bool ?? false
                    if !isMeta, let message = json["message"] as? [String: Any] {
                        if let msgContent = message["content"] as? String {
                            if !msgContent.hasPrefix("<command-name>") && !msgContent.hasPrefix("<local-command") && !msgContent.hasPrefix("Caveat:") {
                                lastMessage = msgContent
                                lastMessageRole = type
                            }
                        } else if let contentArray = message["content"] as? [[String: Any]] {
                            for block in contentArray.reversed() {
                                let blockType = block["type"] as? String
                                if blockType == "tool_use" {
                                    let toolName = block["name"] as? String ?? "Tool"
                                    let toolInput = Self.formatToolInput(block["input"] as? [String: Any], toolName: toolName)
                                    lastMessage = toolInput
                                    lastMessageRole = "tool"
                                    lastToolName = toolName
                                    break
                                } else if blockType == "text", let text = block["text"] as? String {
                                    if !text.hasPrefix("[Request interrupted by user") {
                                        lastMessage = text
                                        lastMessageRole = type
                                        break
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if !foundLastUserMessage && type == "user" {
                let isMeta = json["isMeta"] as? Bool ?? false
                if !isMeta, let message = json["message"] as? [String: Any] {
                    if let msgContent = message["content"] as? String {
                        if !msgContent.hasPrefix("<command-name>") && !msgContent.hasPrefix("<local-command") && !msgContent.hasPrefix("Caveat:") {
                            if let timestampStr = json["timestamp"] as? String {
                                lastUserMessageDate = formatter.date(from: timestampStr)
                            }
                            foundLastUserMessage = true
                        }
                    }
                }
            }

            if summary == nil, type == "summary", let summaryText = json["summary"] as? String {
                summary = summaryText
            }

            if summary != nil && lastMessage != nil && foundLastUserMessage {
                break
            }
        }

        return ConversationInfo(
            summary: summary,
            lastMessage: Self.truncateMessage(lastMessage, maxLength: 80),
            lastMessageRole: lastMessageRole,
            lastToolName: lastToolName,
            firstUserMessage: firstUserMessage,
            lastUserMessageDate: lastUserMessageDate,
            usage: usage
        )
    }

    /// Format tool input for display in instance list
    private static func formatToolInput(_ input: [String: Any]?, toolName: String) -> String {
        guard let input = input else { return "" }

        switch toolName {
        case "Read", "Write", "Edit":
            if let filePath = input["file_path"] as? String {
                return (filePath as NSString).lastPathComponent
            }
        case "Bash":
            if let command = input["command"] as? String {
                return command
            }
        case "Grep":
            if let pattern = input["pattern"] as? String {
                return pattern
            }
        case "Glob":
            if let pattern = input["pattern"] as? String {
                return pattern
            }
        case "Task", "Agent":
            // "Task" is the legacy name; Claude Code now uses "Agent"
            if let description = input["description"] as? String {
                return description
            }
        case "WebFetch":
            if let url = input["url"] as? String {
                return url
            }
        case "WebSearch":
            if let query = input["query"] as? String {
                return query
            }
        default:
            for (_, value) in input {
                if let str = value as? String, !str.isEmpty {
                    return str
                }
            }
        }
        return ""
    }

    /// Truncate message for display
    private static func truncateMessage(_ message: String?, maxLength: Int = 80) -> String? {
        guard let msg = message else { return nil }
        let cleaned = msg.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if cleaned.count > maxLength {
            return String(cleaned.prefix(maxLength - 3)) + "..."
        }
        return cleaned
    }

    // MARK: - Full Conversation Parsing

    /// Parse full conversation history for chat view (returns ALL messages - use sparingly)
    func parseFullConversation(sessionId: String, cwd: String, transcriptPath: String? = nil) -> [ChatMessage] {
        let sessionFile = Self.sessionFilePath(sessionId: sessionId, cwd: cwd, transcriptPath: transcriptPath)

        guard FileManager.default.fileExists(atPath: sessionFile) else {
            return []
        }

        if isOpenCodeTranscript(filePath: sessionFile) {
            let messages = parseOpenCodeFullConversation(sessionId: sessionId)
            var state = incrementalState[sessionId] ?? IncrementalParseState()
            state.messages = messages
            state.completedToolIds = parseOpenCodeCompletedToolIds(sessionId: sessionId)
            state.toolResults = parseOpenCodeToolResults(sessionId: sessionId)
            state.structuredResults = parseOpenCodeStructuredResults(sessionId: sessionId)
            incrementalState[sessionId] = state
            return messages
        }

        var state = incrementalState[sessionId] ?? IncrementalParseState()
        _ = parseNewLines(filePath: sessionFile, state: &state)
        incrementalState[sessionId] = state

        return state.messages
    }

    /// Result of incremental parsing
    struct IncrementalParseResult {
        let newMessages: [ChatMessage]
        let allMessages: [ChatMessage]
        let completedToolIds: Set<String>
        let toolResults: [String: ToolResult]
        let structuredResults: [String: ToolResultData]
        let clearDetected: Bool
        let hasStateChanges: Bool
    }

    /// Parse only NEW messages since last call (efficient incremental updates)
    func parseIncremental(sessionId: String, cwd: String, transcriptPath: String? = nil) -> IncrementalParseResult {
        let sessionFile = Self.sessionFilePath(sessionId: sessionId, cwd: cwd, transcriptPath: transcriptPath)

        guard FileManager.default.fileExists(atPath: sessionFile) else {
            return IncrementalParseResult(
                newMessages: [],
                allMessages: [],
                completedToolIds: [],
                toolResults: [:],
                structuredResults: [:],
                clearDetected: false,
                hasStateChanges: false
            )
        }

        var state = incrementalState[sessionId] ?? IncrementalParseState()
        let previousCompletedToolIds = state.completedToolIds
        let previousToolResults = state.toolResults
        let previousStructuredResults = state.structuredResults
        let newMessages = parseNewLines(filePath: sessionFile, state: &state)
        let clearDetected = state.clearPending
        if clearDetected {
            state.clearPending = false
        }
        incrementalState[sessionId] = state

        return IncrementalParseResult(
            newMessages: newMessages,
            allMessages: state.messages,
            completedToolIds: state.completedToolIds,
            toolResults: state.toolResults,
            structuredResults: state.structuredResults,
            clearDetected: clearDetected,
            hasStateChanges: previousCompletedToolIds != state.completedToolIds ||
                previousToolResults != state.toolResults ||
                previousStructuredResults != state.structuredResults
        )
    }

    /// Parse only new lines since last read (incremental)
    private func parseNewLines(filePath: String, state: inout IncrementalParseState) -> [ChatMessage] {
        if isOpenCodeTranscript(filePath: filePath) {
            return parseNewOpenCodeLines(filePath: filePath, state: &state)
        }

        if isCodexTranscript(filePath: filePath) {
            return parseNewCodexLines(filePath: filePath, state: &state)
        }

        guard let fileHandle = FileHandle(forReadingAtPath: filePath) else {
            return []
        }
        defer { try? fileHandle.close() }

        let fileSize: UInt64
        do {
            fileSize = try fileHandle.seekToEnd()
        } catch {
            return []
        }

        if fileSize < state.lastFileOffset {
            state = IncrementalParseState()
        }

        if fileSize == state.lastFileOffset {
            return state.messages
        }

        do {
            try fileHandle.seek(toOffset: state.lastFileOffset)
        } catch {
            return state.messages
        }

        guard let newData = try? fileHandle.readToEnd(),
              let newContent = String(data: newData, encoding: .utf8) else {
            return state.messages
        }

        state.clearPending = false
        let isIncrementalRead = state.lastFileOffset > 0
        let lines = newContent.components(separatedBy: "\n")
        var newMessages: [ChatMessage] = []

        for line in lines where !line.isEmpty {
            if line.contains("<command-name>/clear</command-name>") {
                state.messages = []
                state.seenToolIds = []
                state.toolIdToName = [:]
                state.completedToolIds = []
                state.toolResults = [:]
                state.structuredResults = [:]

                if isIncrementalRead {
                    state.clearPending = true
                    state.lastClearOffset = state.lastFileOffset
                    Self.logger.debug("/clear detected (new), will notify UI")
                }
                continue
            }

            if line.contains("\"tool_result\"") {
                if let lineData = line.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                   let messageDict = json["message"] as? [String: Any],
                   let contentArray = messageDict["content"] as? [[String: Any]] {
                    let toolUseResult = json["toolUseResult"] as? [String: Any]
                    let topLevelToolName = json["toolName"] as? String
                    let stdout = toolUseResult?["stdout"] as? String
                    let stderr = toolUseResult?["stderr"] as? String

                    for block in contentArray {
                        if block["type"] as? String == "tool_result",
                           let toolUseId = block["tool_use_id"] as? String {
                            state.completedToolIds.insert(toolUseId)

                            let content = block["content"] as? String
                            let isError = block["is_error"] as? Bool ?? false
                            state.toolResults[toolUseId] = ToolResult(
                                content: content,
                                stdout: stdout,
                                stderr: stderr,
                                isError: isError
                            )

                            let toolName = topLevelToolName ?? state.toolIdToName[toolUseId]

                            if let toolUseResult = toolUseResult,
                               let name = toolName {
                                let structured = Self.parseStructuredResult(
                                    toolName: name,
                                    toolUseResult: toolUseResult,
                                    isError: isError
                                )
                                state.structuredResults[toolUseId] = structured
                            }
                        }
                    }
                }
            } else if line.contains("\"type\":\"user\"") || line.contains("\"type\":\"assistant\"") {
                if let lineData = line.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                   let message = parseMessageLine(json, seenToolIds: &state.seenToolIds, toolIdToName: &state.toolIdToName) {
                    newMessages.append(message)
                    state.messages.append(message)
                }
            }
        }

        state.lastFileOffset = fileSize
        return newMessages
    }

    /// Get set of completed tool IDs for a session
    func completedToolIds(for sessionId: String) -> Set<String> {
        return incrementalState[sessionId]?.completedToolIds ?? []
    }

    /// Get tool results for a session
    func toolResults(for sessionId: String) -> [String: ToolResult] {
        return incrementalState[sessionId]?.toolResults ?? [:]
    }

    /// Get structured tool results for a session
    func structuredResults(for sessionId: String) -> [String: ToolResultData] {
        return incrementalState[sessionId]?.structuredResults ?? [:]
    }

    /// Reset incremental state for a session (call when reloading)
    func resetState(for sessionId: String) {
        incrementalState.removeValue(forKey: sessionId)
    }

    /// Check if a /clear command was detected during the last parse
    /// Returns true once and consumes the pending flag
    func checkAndConsumeClearDetected(for sessionId: String) -> Bool {
        guard var state = incrementalState[sessionId], state.clearPending else {
            return false
        }
        state.clearPending = false
        incrementalState[sessionId] = state
        return true
    }

    /// Build session file path
    nonisolated private static func sessionFilePath(sessionId: String, cwd: String, transcriptPath: String? = nil) -> String {
        if let transcriptPath, !transcriptPath.isEmpty {
            return transcriptPath
        }
        let projectDir = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        return ClaudePaths.projectsDir.path + "/" + projectDir + "/" + sessionId + ".jsonl"
    }

    nonisolated private func isOpenCodeTranscript(filePath: String) -> Bool {
        filePath.contains("/.local/share/opencode/storage/session/")
    }

    nonisolated private func isCodexTranscript(filePath: String, content: String? = nil) -> Bool {
        if filePath.contains("/.codex/") {
            return true
        }
        if let content {
            return content.contains("\"type\":\"session_meta\"") || content.contains("\"type\":\"event_msg\"")
        }
        return false
    }

    private func parseCodexContent(_ content: String) -> ConversationInfo {
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }

        var summary: String?
        var lastMessage: String?
        var lastMessageRole: String?
        var firstUserMessage: String?
        var lastUserMessageDate: Date?

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            if summary == nil,
               json["type"] as? String == "session_meta",
               let payload = json["payload"] as? [String: Any],
               let threadName = payload["thread_name"] as? String,
               !threadName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                summary = threadName
            }

            guard json["type"] as? String == "event_msg",
                  let payload = json["payload"] as? [String: Any],
                  let eventType = payload["type"] as? String else {
                continue
            }

            switch eventType {
            case "user_message":
                guard let message = payload["message"] as? String,
                      !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                if firstUserMessage == nil {
                    firstUserMessage = Self.truncateMessage(message, maxLength: 50)
                }
                lastUserMessageDate = parseCodexTimestamp(json["timestamp"] as? String)
                lastMessage = Self.truncateMessage(message, maxLength: 80)
                lastMessageRole = "user"
            case "agent_message":
                guard let message = payload["message"] as? String,
                      !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                lastMessage = Self.truncateMessage(message, maxLength: 80)
                lastMessageRole = "assistant"
            default:
                continue
            }
        }

        return ConversationInfo(
            summary: summary,
            lastMessage: lastMessage,
            lastMessageRole: lastMessageRole,
            lastToolName: nil,
            firstUserMessage: firstUserMessage,
            lastUserMessageDate: lastUserMessageDate
        )
    }

    private func parseNewCodexLines(filePath: String, state: inout IncrementalParseState) -> [ChatMessage] {
        guard let fileHandle = FileHandle(forReadingAtPath: filePath) else {
            return []
        }
        defer { try? fileHandle.close() }

        let fileSize: UInt64
        do {
            fileSize = try fileHandle.seekToEnd()
        } catch {
            return []
        }

        if fileSize < state.lastFileOffset {
            state = IncrementalParseState()
        }

        if fileSize == state.lastFileOffset {
            return []
        }

        do {
            try fileHandle.seek(toOffset: state.lastFileOffset)
        } catch {
            return []
        }

        guard let newData = try? fileHandle.readToEnd(),
              let newContent = String(data: newData, encoding: .utf8) else {
            return []
        }

        let lines = newContent.components(separatedBy: "\n")
        var newMessages: [ChatMessage] = []

        for line in lines where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  json["type"] as? String == "event_msg",
                  let payload = json["payload"] as? [String: Any],
                  let eventType = payload["type"] as? String else {
                continue
            }

            let timestamp = parseCodexTimestamp(json["timestamp"] as? String) ?? Date()
            switch eventType {
            case "user_message":
                if let message = payload["message"] as? String,
                   let chatMessage = makeCodexChatMessage(
                    role: .user,
                    text: message,
                    timestamp: timestamp,
                    discriminator: "user"
                   ) {
                    newMessages.append(chatMessage)
                    state.messages.append(chatMessage)
                }
            case "agent_message":
                if let message = payload["message"] as? String,
                   let chatMessage = makeCodexChatMessage(
                    role: .assistant,
                    text: message,
                    timestamp: timestamp,
                    discriminator: payload["phase"] as? String ?? "assistant"
                   ) {
                    newMessages.append(chatMessage)
                    state.messages.append(chatMessage)
                }
            default:
                continue
            }
        }

        state.lastFileOffset = fileSize
        return newMessages
    }

    private func parseOpenCodeConversationInfo(filePath: String) -> ConversationInfo {
        guard let sessionData = FileManager.default.contents(atPath: filePath),
              let sessionJson = try? JSONSerialization.jsonObject(with: sessionData) as? [String: Any] else {
            return ConversationInfo(summary: nil, lastMessage: nil, lastMessageRole: nil, lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil)
        }

        let sessionId = sessionJson["id"] as? String ?? filePath.components(separatedBy: "/").last?.replacingOccurrences(of: ".json", with: "") ?? ""
        let title = sessionJson["title"] as? String
        let messages = parseOpenCodeFullConversation(sessionId: sessionId)

        let firstUserMessage = messages.first(where: { $0.role == .user })?.textContent
        let lastUserMessage = messages.last(where: { $0.role == .user })
        let lastMessage = messages.last
        let lastToolName = lastMessage?.content.compactMap { block -> String? in
            if case .toolUse(let tool) = block { return tool.name }
            return nil
        }.last

        var usage = UsageInfo()
        if let messageDir = openCodeMessagesDir(for: sessionId),
           let enumerator = FileManager.default.enumerator(at: messageDir, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "json" {
                guard let data = try? Data(contentsOf: fileURL),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tokens = json["tokens"] as? [String: Any] else { continue }

                usage.inputTokens += tokens["input"] as? Int ?? 0
                usage.outputTokens += tokens["output"] as? Int ?? 0
                if let cache = tokens["cache"] as? [String: Any] {
                    usage.cacheReadTokens += cache["read"] as? Int ?? 0
                    usage.cacheCreationTokens += cache["write"] as? Int ?? 0
                }
            }
        }

        return ConversationInfo(
            summary: title,
            lastMessage: Self.truncateMessage(lastMessage?.textContent, maxLength: 80),
            lastMessageRole: lastMessage?.role.rawValue,
            lastToolName: lastToolName,
            firstUserMessage: Self.truncateMessage(firstUserMessage, maxLength: 50),
            lastUserMessageDate: lastUserMessage?.timestamp,
            usage: usage
        )
    }

    private func parseOpenCodeFullConversation(sessionId: String) -> [ChatMessage] {
        guard let messageDir = openCodeMessagesDir(for: sessionId) else { return [] }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: messageDir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) else {
            return []
        }

        return files.compactMap { parseOpenCodeMessageFile($0) }
    }

    private func parseNewOpenCodeLines(filePath: String, state: inout IncrementalParseState) -> [ChatMessage] {
        guard let sessionId = openCodeSessionId(from: filePath) else {
            return []
        }

        let latestMessages = parseOpenCodeFullConversation(sessionId: sessionId)
        let previousIds = Set(state.messages.map(\.id))
        let newMessages = latestMessages.filter { !previousIds.contains($0.id) }

        state.messages = latestMessages
        state.completedToolIds = parseOpenCodeCompletedToolIds(sessionId: sessionId)
        state.toolResults = parseOpenCodeToolResults(sessionId: sessionId)
        state.structuredResults = parseOpenCodeStructuredResults(sessionId: sessionId)
        state.lastFileOffset = UInt64(latestMessages.count)

        return newMessages
    }

    private func parseOpenCodeCompletedToolIds(sessionId: String) -> Set<String> {
        var completed = Set<String>()
        let fm = FileManager.default
        guard let messageIds = openCodeMessageIds(for: sessionId) else { return completed }

        for messageId in messageIds {
            let dir = OpenCodePaths.partsDir.appendingPathComponent(messageId)
            guard let partFiles = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
                  let completedPart = partFiles
                    .filter({ $0.pathExtension == "json" })
                    .compactMap({ parseOpenCodePartFile($0) })
                    .first(where: { part in
                        if case .toolUse(let tool) = part.block {
                            return tool.input["__tool_status"] == "completed" || tool.input["__tool_status"] == "error"
                        }
                        return false
                    }) else { continue }

            if case .toolUse(let tool) = completedPart.block {
                completed.insert(tool.id)
            }
        }

        return completed
    }

    private func parseOpenCodeToolResults(sessionId: String) -> [String: ToolResult] {
        var results: [String: ToolResult] = [:]
        let fm = FileManager.default
        guard let messageIds = openCodeMessageIds(for: sessionId) else { return results }

        for messageId in messageIds {
            let dir = OpenCodePaths.partsDir.appendingPathComponent(messageId)
            guard let partFiles = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter({ $0.pathExtension == "json" })
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) else { continue }

            for file in partFiles {
                guard let data = try? Data(contentsOf: file),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      json["type"] as? String == "tool",
                      let callId = json["callID"] as? String,
                      let stateJson = json["state"] as? [String: Any] else { continue }

                let status = stateJson["status"] as? String ?? "pending"
                guard status == "completed" || status == "error" else { continue }

                let output = stateJson["output"] as? String
                let error = stateJson["error"] as? String
                results[callId] = ToolResult(
                    content: output ?? error,
                    stdout: output,
                    stderr: error,
                    isError: status == "error"
                )
            }
        }

        return results
    }

    private func parseOpenCodeStructuredResults(sessionId: String) -> [String: ToolResultData] {
        var results: [String: ToolResultData] = [:]
        let fm = FileManager.default
        guard let messageIds = openCodeMessageIds(for: sessionId) else { return results }

        for messageId in messageIds {
            let dir = OpenCodePaths.partsDir.appendingPathComponent(messageId)
            guard let partFiles = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter({ $0.pathExtension == "json" })
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) else { continue }

            for file in partFiles {
                guard let data = try? Data(contentsOf: file),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      json["type"] as? String == "tool",
                      let callId = json["callID"] as? String,
                      let toolName = json["tool"] as? String,
                      let stateJson = json["state"] as? [String: Any] else { continue }

                let status = stateJson["status"] as? String ?? "pending"
                guard status == "completed" || status == "error" else { continue }

                let rawResult = stateJson["metadata"] as? [String: Any] ?? [:]
                let genericText = stateJson["output"] as? String ?? stateJson["error"] as? String
                results[callId] = .generic(GenericResult(
                    rawContent: genericText,
                    rawData: rawResult.isEmpty ? stateJson : rawResult
                ))

                if results[callId] == nil {
                    results[callId] = .generic(GenericResult(rawContent: genericText, rawData: [
                        "tool": toolName,
                        "state": stateJson
                    ]))
                }
            }
        }

        return results
    }

    private func parseOpenCodeMessageFile(_ url: URL) -> ChatMessage? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String,
              let roleString = json["role"] as? String else { return nil }

        let role: ChatRole = roleString == "user" ? .user : .assistant
        let timestampMs: Double
        if let time = json["time"] as? [String: Any] {
            timestampMs = (time["created"] as? Double) ??
                Double(time["created"] as? Int ?? 0)
        } else {
            timestampMs = 0
        }
        let timestamp = Date(timeIntervalSince1970: timestampMs / 1000)
        let sessionId = json["sessionID"] as? String ?? ""
        let parts = parseOpenCodeParts(messageId: id, sessionId: sessionId)

        if parts.isEmpty {
            return nil
        }

        return ChatMessage(
            id: id,
            role: role,
            timestamp: timestamp,
            content: parts
        )
    }

    private func parseOpenCodeParts(messageId: String, sessionId: String) -> [MessageBlock] {
        let partDir = OpenCodePaths.partsDir.appendingPathComponent(messageId)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: partDir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) else {
            return []
        }

        return files.compactMap { parseOpenCodePartFile($0)?.block }
    }

    private func parseOpenCodePartFile(_ url: URL) -> (block: MessageBlock, timestamp: Date?)? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return nil
        }

        switch type {
        case "text":
            guard let text = json["text"] as? String else { return nil }
            return (.text(text), nil)

        case "reasoning":
            guard let text = json["text"] as? String else { return nil }
            return (.thinking(text), nil)

        case "tool":
            guard let callId = json["callID"] as? String,
                  let toolName = json["tool"] as? String,
                  let state = json["state"] as? [String: Any] else {
                return nil
            }

            var input: [String: String] = [:]
            if let rawInput = state["input"] as? [String: Any] {
                for (key, value) in rawInput {
                    if let string = value as? String {
                        input[key] = string
                    } else if let int = value as? Int {
                        input[key] = String(int)
                    } else if let bool = value as? Bool {
                        input[key] = bool ? "true" : "false"
                    }
                }
            }

            if let status = state["status"] as? String {
                input["__tool_status"] = status
            }
            if let output = state["output"] as? String {
                input["__tool_output"] = output
            }
            if let error = state["error"] as? String {
                input["__tool_error"] = error
            }

            return (.toolUse(ToolUseBlock(id: callId, name: normalizeOpenCodeToolName(toolName), input: input)), nil)

        default:
            return nil
        }
    }

    nonisolated private func normalizeOpenCodeToolName(_ name: String) -> String {
        switch name.lowercased() {
        case "bash": return "Bash"
        case "read": return "Read"
        case "write": return "Write"
        case "edit": return "Edit"
        case "glob": return "Glob"
        case "grep": return "Grep"
        case "webfetch": return "WebFetch"
        case "websearch": return "WebSearch"
        case "task": return "Agent"
        default: return name
        }
    }

    nonisolated private func openCodeSessionId(from filePath: String) -> String? {
        let fileName = URL(fileURLWithPath: filePath).lastPathComponent
        return fileName.hasSuffix(".json") ? String(fileName.dropLast(5)) : nil
    }

    nonisolated private func openCodeMessagesDir(for sessionId: String) -> URL? {
        let dir = OpenCodePaths.messagesDir.appendingPathComponent(sessionId)
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    nonisolated private func openCodeMessageIds(for sessionId: String) -> [String]? {
        guard let messageDir = openCodeMessagesDir(for: sessionId),
              let messageFiles = try? FileManager.default.contentsOfDirectory(at: messageDir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" }) else {
            return nil
        }

        let messageIds = messageFiles.map { $0.deletingPathExtension().lastPathComponent }
        return messageIds.isEmpty ? nil : messageIds
    }

    private func makeCodexChatMessage(
        role: ChatRole,
        text: String,
        timestamp: Date,
        discriminator: String
    ) -> ChatMessage? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        let identifierBase = "\(timestamp.timeIntervalSince1970)-\(discriminator)-\(cleaned.prefix(120))"
        return ChatMessage(
            id: "codex-\(StableHash.hash(identifierBase.prefix(200)))",
            role: role,
            timestamp: timestamp,
            content: [.text(cleaned)]
        )
    }

    private func parseCodexTimestamp(_ timestampStr: String?) -> Date? {
        guard let timestampStr else { return nil }
        return isoFormatter.date(from: timestampStr)
    }

    /// Build subagent JSONL file path.
    ///
    /// Current Claude Code nests subagent files under the parent session:
    ///   projects/<project>/<sessionId>/subagents/agent-<agentId>.jsonl
    ///
    /// Older Claude Code versions stored them flat:
    ///   projects/<project>/agent-<agentId>.jsonl
    ///
    /// Prefer the nested path; fall back to the flat path if only it exists
    /// (cross-version compatibility). If neither exists yet (file still being
    /// created) we return the nested path as the modern default.
    nonisolated static func subagentFilePath(sessionId: String, agentId: String, projectDir: String) -> String {
        let base = ClaudePaths.projectsDir.path + "/" + projectDir
        let nested = base + "/" + sessionId + "/subagents/agent-" + agentId + ".jsonl"
        let flat = base + "/agent-" + agentId + ".jsonl"

        let fm = FileManager.default
        if fm.fileExists(atPath: nested) { return nested }
        if fm.fileExists(atPath: flat) { return flat }
        return nested
    }

    private func parseMessageLine(_ json: [String: Any], seenToolIds: inout Set<String>, toolIdToName: inout [String: String]) -> ChatMessage? {
        guard let type = json["type"] as? String,
              let uuid = json["uuid"] as? String else {
            return nil
        }

        guard type == "user" || type == "assistant" else {
            return nil
        }

        if json["isMeta"] as? Bool == true {
            return nil
        }

        guard let messageDict = json["message"] as? [String: Any] else {
            return nil
        }

        let timestamp: Date
        if let timestampStr = json["timestamp"] as? String {
            timestamp = isoFormatter.date(from: timestampStr) ?? Date()
        } else {
            timestamp = Date()
        }

        var blocks: [MessageBlock] = []

        if let content = messageDict["content"] as? String {
            if content.hasPrefix("<command-name>") || content.hasPrefix("<local-command") || content.hasPrefix("Caveat:") {
                return nil
            }
            if content.hasPrefix("[Request interrupted by user") {
                blocks.append(.interrupted)
            } else {
                blocks.append(.text(content))
            }
        } else if let contentArray = messageDict["content"] as? [[String: Any]] {
            for block in contentArray {
                if let blockType = block["type"] as? String {
                    switch blockType {
                    case "text":
                        if let text = block["text"] as? String {
                            if text.hasPrefix("[Request interrupted by user") {
                                blocks.append(.interrupted)
                            } else {
                                blocks.append(.text(text))
                            }
                        }
                    case "tool_use":
                        if let toolId = block["id"] as? String {
                            if seenToolIds.contains(toolId) {
                                continue
                            }
                            seenToolIds.insert(toolId)
                            if let toolName = block["name"] as? String {
                                toolIdToName[toolId] = toolName
                            }
                        }
                        if let toolBlock = parseToolUse(block) {
                            blocks.append(.toolUse(toolBlock))
                        }
                    case "thinking":
                        if let thinking = block["thinking"] as? String {
                            blocks.append(.thinking(thinking))
                        }
                    case "image":
                        // Claude Code stores inline images as base64 with media_type.
                        if let source = block["source"] as? [String: Any],
                           let mediaType = source["media_type"] as? String,
                           let data = source["data"] as? String {
                            blocks.append(.image(ImageBlock(mediaType: mediaType, base64Data: data)))
                        }
                    default:
                        break
                    }
                }
            }
        }

        guard !blocks.isEmpty else { return nil }

        let role: ChatRole = type == "user" ? .user : .assistant

        return ChatMessage(
            id: uuid,
            role: role,
            timestamp: timestamp,
            content: blocks
        )
    }

    private func parseToolUse(_ block: [String: Any]) -> ToolUseBlock? {
        guard let id = block["id"] as? String,
              let name = block["name"] as? String else {
            return nil
        }

        var input: [String: String] = [:]
        if let inputDict = block["input"] as? [String: Any] {
            for (key, value) in inputDict {
                if let strValue = value as? String {
                    input[key] = strValue
                } else if let intValue = value as? Int {
                    input[key] = String(intValue)
                } else if let boolValue = value as? Bool {
                    input[key] = boolValue ? "true" : "false"
                }
            }
        }

        return ToolUseBlock(id: id, name: name, input: input)
    }

    // MARK: - Structured Result Parsing

    /// Parse tool result JSON into structured ToolResultData
    private static func parseStructuredResult(
        toolName: String,
        toolUseResult: [String: Any],
        isError: Bool
    ) -> ToolResultData {
        if toolName.hasPrefix("mcp__") {
            let parts = String(toolName.dropFirst(5)).components(separatedBy: "__")
            let serverName = parts.first.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
            let mcpToolName = parts.dropFirst().joined(separator: "__")
            return .mcp(MCPResult(
                serverName: serverName,
                toolName: mcpToolName.isEmpty ? toolName : mcpToolName,
                rawResult: toolUseResult
            ))
        }

        switch toolName {
        case "Read":
            return parseReadResult(toolUseResult)
        case "Edit":
            return parseEditResult(toolUseResult)
        case "Write":
            return parseWriteResult(toolUseResult)
        case "Bash":
            return parseBashResult(toolUseResult)
        case "Grep":
            return parseGrepResult(toolUseResult)
        case "Glob":
            return parseGlobResult(toolUseResult)
        case "TodoWrite":
            return parseTodoWriteResult(toolUseResult)
        case "Task", "Agent":
            return parseTaskResult(toolUseResult)
        case "WebFetch":
            return parseWebFetchResult(toolUseResult)
        case "WebSearch":
            return parseWebSearchResult(toolUseResult)
        case "AskUserQuestion":
            return parseAskUserQuestionResult(toolUseResult)
        case "BashOutput":
            return parseBashOutputResult(toolUseResult)
        case "KillShell":
            return parseKillShellResult(toolUseResult)
        case "ExitPlanMode":
            return parseExitPlanModeResult(toolUseResult)
        default:
            let content = toolUseResult["content"] as? String ??
                          toolUseResult["stdout"] as? String ??
                          toolUseResult["result"] as? String
            return .generic(GenericResult(rawContent: content, rawData: toolUseResult))
        }
    }

    // MARK: - Individual Tool Result Parsers

    private static func parseReadResult(_ data: [String: Any]) -> ToolResultData {
        if let fileData = data["file"] as? [String: Any] {
            return .read(ReadResult(
                filePath: fileData["filePath"] as? String ?? "",
                content: fileData["content"] as? String ?? "",
                numLines: fileData["numLines"] as? Int ?? 0,
                startLine: fileData["startLine"] as? Int ?? 1,
                totalLines: fileData["totalLines"] as? Int ?? 0
            ))
        }
        return .read(ReadResult(
            filePath: data["filePath"] as? String ?? "",
            content: data["content"] as? String ?? "",
            numLines: data["numLines"] as? Int ?? 0,
            startLine: data["startLine"] as? Int ?? 1,
            totalLines: data["totalLines"] as? Int ?? 0
        ))
    }

    private static func parseEditResult(_ data: [String: Any]) -> ToolResultData {
        var patches: [PatchHunk]? = nil
        if let patchArray = data["structuredPatch"] as? [[String: Any]] {
            patches = patchArray.compactMap { patch -> PatchHunk? in
                guard let oldStart = patch["oldStart"] as? Int,
                      let oldLines = patch["oldLines"] as? Int,
                      let newStart = patch["newStart"] as? Int,
                      let newLines = patch["newLines"] as? Int,
                      let lines = patch["lines"] as? [String] else {
                    return nil
                }
                return PatchHunk(
                    oldStart: oldStart,
                    oldLines: oldLines,
                    newStart: newStart,
                    newLines: newLines,
                    lines: lines
                )
            }
        }

        return .edit(EditResult(
            filePath: data["filePath"] as? String ?? "",
            oldString: data["oldString"] as? String ?? "",
            newString: data["newString"] as? String ?? "",
            replaceAll: data["replaceAll"] as? Bool ?? false,
            userModified: data["userModified"] as? Bool ?? false,
            structuredPatch: patches
        ))
    }

    private static func parseWriteResult(_ data: [String: Any]) -> ToolResultData {
        let typeStr = data["type"] as? String ?? "create"
        let writeType: WriteResult.WriteType = typeStr == "overwrite" ? .overwrite : .create

        var patches: [PatchHunk]? = nil
        if let patchArray = data["structuredPatch"] as? [[String: Any]] {
            patches = patchArray.compactMap { patch -> PatchHunk? in
                guard let oldStart = patch["oldStart"] as? Int,
                      let oldLines = patch["oldLines"] as? Int,
                      let newStart = patch["newStart"] as? Int,
                      let newLines = patch["newLines"] as? Int,
                      let lines = patch["lines"] as? [String] else {
                    return nil
                }
                return PatchHunk(
                    oldStart: oldStart,
                    oldLines: oldLines,
                    newStart: newStart,
                    newLines: newLines,
                    lines: lines
                )
            }
        }

        return .write(WriteResult(
            type: writeType,
            filePath: data["filePath"] as? String ?? "",
            content: data["content"] as? String ?? "",
            structuredPatch: patches
        ))
    }

    private static func parseBashResult(_ data: [String: Any]) -> ToolResultData {
        return .bash(BashResult(
            stdout: data["stdout"] as? String ?? "",
            stderr: data["stderr"] as? String ?? "",
            interrupted: data["interrupted"] as? Bool ?? false,
            isImage: data["isImage"] as? Bool ?? false,
            returnCodeInterpretation: data["returnCodeInterpretation"] as? String,
            backgroundTaskId: data["backgroundTaskId"] as? String
        ))
    }

    private static func parseGrepResult(_ data: [String: Any]) -> ToolResultData {
        let modeStr = data["mode"] as? String ?? "files_with_matches"
        let mode: GrepResult.Mode
        switch modeStr {
        case "content": mode = .content
        case "count": mode = .count
        default: mode = .filesWithMatches
        }

        return .grep(GrepResult(
            mode: mode,
            filenames: data["filenames"] as? [String] ?? [],
            numFiles: data["numFiles"] as? Int ?? 0,
            content: data["content"] as? String,
            numLines: data["numLines"] as? Int,
            appliedLimit: data["appliedLimit"] as? Int
        ))
    }

    private static func parseGlobResult(_ data: [String: Any]) -> ToolResultData {
        return .glob(GlobResult(
            filenames: data["filenames"] as? [String] ?? [],
            durationMs: data["durationMs"] as? Int ?? 0,
            numFiles: data["numFiles"] as? Int ?? 0,
            truncated: data["truncated"] as? Bool ?? false
        ))
    }

    private static func parseTodoWriteResult(_ data: [String: Any]) -> ToolResultData {
        func parseTodos(_ array: [[String: Any]]?) -> [TodoItem] {
            guard let array = array else { return [] }
            return array.compactMap { item -> TodoItem? in
                guard let content = item["content"] as? String,
                      let status = item["status"] as? String else {
                    return nil
                }
                return TodoItem(
                    content: content,
                    status: status,
                    activeForm: item["activeForm"] as? String
                )
            }
        }

        return .todoWrite(TodoWriteResult(
            oldTodos: parseTodos(data["oldTodos"] as? [[String: Any]]),
            newTodos: parseTodos(data["newTodos"] as? [[String: Any]])
        ))
    }

    private static func parseTaskResult(_ data: [String: Any]) -> ToolResultData {
        return .task(TaskResult(
            agentId: data["agentId"] as? String ?? "",
            status: data["status"] as? String ?? "unknown",
            content: data["content"] as? String ?? "",
            prompt: data["prompt"] as? String,
            totalDurationMs: data["totalDurationMs"] as? Int,
            totalTokens: data["totalTokens"] as? Int,
            totalToolUseCount: data["totalToolUseCount"] as? Int
        ))
    }

    private static func parseWebFetchResult(_ data: [String: Any]) -> ToolResultData {
        return .webFetch(WebFetchResult(
            url: data["url"] as? String ?? "",
            code: data["code"] as? Int ?? 0,
            codeText: data["codeText"] as? String ?? "",
            bytes: data["bytes"] as? Int ?? 0,
            durationMs: data["durationMs"] as? Int ?? 0,
            result: data["result"] as? String ?? ""
        ))
    }

    private static func parseWebSearchResult(_ data: [String: Any]) -> ToolResultData {
        var results: [SearchResultItem] = []
        if let resultsArray = data["results"] as? [[String: Any]] {
            results = resultsArray.compactMap { item -> SearchResultItem? in
                guard let title = item["title"] as? String,
                      let url = item["url"] as? String else {
                    return nil
                }
                return SearchResultItem(
                    title: title,
                    url: url,
                    snippet: item["snippet"] as? String ?? ""
                )
            }
        }

        return .webSearch(WebSearchResult(
            query: data["query"] as? String ?? "",
            durationSeconds: data["durationSeconds"] as? Double ?? 0,
            results: results
        ))
    }

    private static func parseAskUserQuestionResult(_ data: [String: Any]) -> ToolResultData {
        var questions: [QuestionItem] = []
        if let questionsArray = data["questions"] as? [[String: Any]] {
            questions = questionsArray.compactMap { q -> QuestionItem? in
                guard let question = q["question"] as? String else { return nil }
                var options: [QuestionOption] = []
                if let optionsArray = q["options"] as? [[String: Any]] {
                    options = optionsArray.compactMap { opt -> QuestionOption? in
                        guard let label = opt["label"] as? String else { return nil }
                        return QuestionOption(
                            label: label,
                            description: opt["description"] as? String
                        )
                    }
                }
                return QuestionItem(
                    question: question,
                    header: q["header"] as? String,
                    options: options
                )
            }
        }

        var answers: [String: String] = [:]
        if let answersDict = data["answers"] as? [String: String] {
            answers = answersDict
        }

        return .askUserQuestion(AskUserQuestionResult(
            questions: questions,
            answers: answers
        ))
    }

    private static func parseBashOutputResult(_ data: [String: Any]) -> ToolResultData {
        return .bashOutput(BashOutputResult(
            shellId: data["shellId"] as? String ?? "",
            status: data["status"] as? String ?? "",
            stdout: data["stdout"] as? String ?? "",
            stderr: data["stderr"] as? String ?? "",
            stdoutLines: data["stdoutLines"] as? Int ?? 0,
            stderrLines: data["stderrLines"] as? Int ?? 0,
            exitCode: data["exitCode"] as? Int,
            command: data["command"] as? String,
            timestamp: data["timestamp"] as? String
        ))
    }

    private static func parseKillShellResult(_ data: [String: Any]) -> ToolResultData {
        return .killShell(KillShellResult(
            shellId: data["shell_id"] as? String ?? data["shellId"] as? String ?? "",
            message: data["message"] as? String ?? ""
        ))
    }

    private static func parseExitPlanModeResult(_ data: [String: Any]) -> ToolResultData {
        return .exitPlanMode(ExitPlanModeResult(
            filePath: data["filePath"] as? String,
            plan: data["plan"] as? String,
            isAgent: data["isAgent"] as? Bool ?? false
        ))
    }

    // MARK: - Subagent Tools Parsing

    /// Parse subagent tools from an agent JSONL file
    func parseSubagentTools(sessionId: String, agentId: String, cwd: String) -> [SubagentToolInfo] {
        guard !agentId.isEmpty else { return [] }

        let projectDir = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let agentFile = Self.subagentFilePath(sessionId: sessionId, agentId: agentId, projectDir: projectDir)

        guard FileManager.default.fileExists(atPath: agentFile),
              let content = try? String(contentsOfFile: agentFile, encoding: .utf8) else {
            return []
        }

        var tools: [SubagentToolInfo] = []
        var seenToolIds: Set<String> = []
        var completedToolIds: Set<String> = []

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            if line.contains("\"tool_result\""),
               let lineData = line.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
               let messageDict = json["message"] as? [String: Any],
               let contentArray = messageDict["content"] as? [[String: Any]] {
                for block in contentArray {
                    if block["type"] as? String == "tool_result",
                       let toolUseId = block["tool_use_id"] as? String {
                        completedToolIds.insert(toolUseId)
                    }
                }
            }
        }

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            guard line.contains("\"tool_use\""),
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let messageDict = json["message"] as? [String: Any],
                  let contentArray = messageDict["content"] as? [[String: Any]] else {
                continue
            }

            for block in contentArray {
                guard block["type"] as? String == "tool_use",
                      let toolId = block["id"] as? String,
                      let toolName = block["name"] as? String,
                      !seenToolIds.contains(toolId) else {
                    continue
                }

                seenToolIds.insert(toolId)

                var input: [String: String] = [:]
                if let inputDict = block["input"] as? [String: Any] {
                    for (key, value) in inputDict {
                        if let strValue = value as? String {
                            input[key] = strValue
                        } else if let intValue = value as? Int {
                            input[key] = String(intValue)
                        } else if let boolValue = value as? Bool {
                            input[key] = boolValue ? "true" : "false"
                        }
                    }
                }

                let isCompleted = completedToolIds.contains(toolId)
                let timestamp = json["timestamp"] as? String

                tools.append(SubagentToolInfo(
                    id: toolId,
                    name: toolName,
                    input: input,
                    isCompleted: isCompleted,
                    timestamp: timestamp
                ))
            }
        }

        return tools
    }
}

/// Info about a subagent tool call parsed from JSONL
struct SubagentToolInfo: Sendable {
    let id: String
    let name: String
    let input: [String: String]
    let isCompleted: Bool
    let timestamp: String?
}

// MARK: - Static Subagent Tools Parsing

extension ConversationParser {
    /// Parse subagent tools from an agent JSONL file (static, synchronous version)
    nonisolated static func parseSubagentToolsSync(sessionId: String, agentId: String, cwd: String) -> [SubagentToolInfo] {
        guard !agentId.isEmpty else { return [] }

        let projectDir = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let agentFile = subagentFilePath(sessionId: sessionId, agentId: agentId, projectDir: projectDir)

        guard FileManager.default.fileExists(atPath: agentFile),
              let content = try? String(contentsOfFile: agentFile, encoding: .utf8) else {
            return []
        }

        var tools: [SubagentToolInfo] = []
        var seenToolIds: Set<String> = []
        var completedToolIds: Set<String> = []

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            if line.contains("\"tool_result\""),
               let lineData = line.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
               let messageDict = json["message"] as? [String: Any],
               let contentArray = messageDict["content"] as? [[String: Any]] {
                for block in contentArray {
                    if block["type"] as? String == "tool_result",
                       let toolUseId = block["tool_use_id"] as? String {
                        completedToolIds.insert(toolUseId)
                    }
                }
            }
        }

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            guard line.contains("\"tool_use\""),
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let messageDict = json["message"] as? [String: Any],
                  let contentArray = messageDict["content"] as? [[String: Any]] else {
                continue
            }

            for block in contentArray {
                guard block["type"] as? String == "tool_use",
                      let toolId = block["id"] as? String,
                      let toolName = block["name"] as? String,
                      !seenToolIds.contains(toolId) else {
                    continue
                }

                seenToolIds.insert(toolId)

                var input: [String: String] = [:]
                if let inputDict = block["input"] as? [String: Any] {
                    for (key, value) in inputDict {
                        if let strValue = value as? String {
                            input[key] = strValue
                        } else if let intValue = value as? Int {
                            input[key] = String(intValue)
                        } else if let boolValue = value as? Bool {
                            input[key] = boolValue ? "true" : "false"
                        }
                    }
                }

                let isCompleted = completedToolIds.contains(toolId)
                let timestamp = json["timestamp"] as? String

                tools.append(SubagentToolInfo(
                    id: toolId,
                    name: toolName,
                    input: input,
                    isCompleted: isCompleted,
                    timestamp: timestamp
                ))
            }
        }

        return tools
    }
}
