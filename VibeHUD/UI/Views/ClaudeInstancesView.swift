//
//  ClaudeInstancesView.swift
//  VibeHUD
//
//  Minimal instances list matching Dynamic Island aesthetic
//

import Combine
import SwiftUI

enum ApprovalSelection: Equatable {
    case allow
    case deny

    mutating func toggle() {
        self = (self == .allow) ? .deny : .allow
    }
}

struct ClaudeInstancesView: View {
    @ObservedObject var sessionMonitor: ClaudeSessionMonitor
    @ObservedObject var viewModel: NotchViewModel
    @State private var focusedSessionId: String?
    @State private var tapApprovalSelection: ApprovalSelection = .allow
    @State private var tapApprovalToolId: String?
    @State private var askFocusIndexByKey: [String: Int] = [:]
    @State private var askSelectedByKey: [String: [Int: Set<String>]] = [:]

    var body: some View {
        VStack(spacing: 8) {
            if sessionMonitor.instances.isEmpty {
                emptyState
            } else {
                instancesList
            }
        }
        .onAppear {
            syncInteractionTargets()
        }
        .onChange(of: sortedInstances) { _, _ in
            syncInteractionTargets()
        }
        .onReceive(EventMonitors.shared.singleTap.receive(on: RunLoop.main)) { _ in
            handleSingleTap()
        }
        .onReceive(EventMonitors.shared.doubleTap.receive(on: RunLoop.main)) { _ in
            handleDoubleTap()
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No sessions")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.4))

            Text("Run claude in terminal")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.25))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Instances List

    /// Priority: active (approval/processing/compacting) > waitingForInput > idle
    /// Secondary sort: by last user message date (stable - doesn't change when agent responds)
    /// Note: approval requests stay in their date-based position to avoid layout shift
    private var sortedInstances: [SessionState] {
        sessionMonitor.instances.sorted { a, b in
            let priorityA = phasePriority(a.phase)
            let priorityB = phasePriority(b.phase)
            if priorityA != priorityB {
                return priorityA < priorityB
            }
            // Sort by last user message date (more recent first)
            // Fall back to lastActivity if no user messages yet
            let dateA = a.lastUserMessageDate ?? a.lastActivity
            let dateB = b.lastUserMessageDate ?? b.lastActivity
            return dateA > dateB
        }
    }

    /// Lower number = higher priority
    /// Approval requests share priority with processing to maintain stable ordering
    private func phasePriority(_ phase: SessionPhase) -> Int {
        switch phase {
        case .waitingForApproval, .processing, .compacting: return 0
        case .waitingForInput: return 1
        case .idle, .ended: return 2
        }
    }

    private var instancesList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 2) {
                ForEach(sortedInstances) { session in
                    VStack(spacing: 6) {
                        InstanceRow(
                            session: session,
                            onSelect: { focusedSessionId = session.sessionId },
                            onFocus: { focusSession(session) },
                            onChat: { openChat(session) },
                            onArchive: { archiveSession(session) },
                            onApprove: { approveSession(session) },
                            onReject: { rejectSession(session) },
                            tapSelectedApproval: tapSelectedApproval(for: session),
                            isFocusedForTapInput: focusedSessionId == session.sessionId
                        )

                        if let questions = askQuestions(for: session), !questions.isEmpty {
                            SessionAskUserQuestionCard(
                                session: session,
                                questions: questions,
                                focusedSessionId: focusedSessionId,
                                focusIndex: askFocusIndex(for: session, questions: questions),
                                selectedByQuestion: askSelections(for: session),
                                onSelectSession: { focusedSessionId = session.sessionId },
                                onTapOption: { questionIndex, option in
                                    handleAskOptionTap(session: session, questionIndex: questionIndex, option: option)
                                },
                                onTapConfirm: { questionIndex in
                                    submitAskSelections(session: session, questionIndex: questionIndex, questions: questions)
                                }
                            )
                        }
                    }
                    .id(session.stableId)
                }
            }
            .padding(.vertical, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func tapControlledSession() -> SessionState? {
        if let focusedSessionId,
           let focused = sortedInstances.first(where: { $0.sessionId == focusedSessionId }),
           focused.phase.isWaitingForApproval {
            return focused
        }

        return sortedInstances.first { $0.phase.isWaitingForApproval }
    }

    private func tapSelectedApproval(for session: SessionState) -> ApprovalSelection? {
        guard let target = tapControlledSession(),
              target.pendingToolName != "AskUserQuestion",
              session.pendingToolId == target.pendingToolId else {
            return nil
        }
        return tapApprovalSelection
    }

    private func syncInteractionTargets() {
        guard let target = tapControlledSession() else {
            focusedSessionId = nil
            tapApprovalToolId = nil
            tapApprovalSelection = .allow
            return
        }

        focusedSessionId = target.sessionId
        guard target.pendingToolName != "AskUserQuestion",
              let toolId = target.pendingToolId else {
            tapApprovalToolId = nil
            tapApprovalSelection = .allow
            return
        }

        if tapApprovalToolId != toolId {
            tapApprovalToolId = toolId
            tapApprovalSelection = .allow
        }
    }

    private func handleSingleTap() {
        guard let target = tapControlledSession() else {
            print("[TapControl] single tap ignored: no waiting-for-approval target")
            return
        }
        print("[TapControl] single tap target session=\(target.sessionId) tool=\(target.pendingToolName ?? "none")")
        if target.pendingToolName == "AskUserQuestion" {
            advanceAskFocus(session: target)
            return
        }
        tapApprovalSelection.toggle()
    }

    private func handleDoubleTap() {
        guard let target = tapControlledSession() else {
            print("[TapControl] double tap ignored: no waiting-for-approval target")
            return
        }
        print("[TapControl] double tap target session=\(target.sessionId) tool=\(target.pendingToolName ?? "none")")
        if target.pendingToolName == "AskUserQuestion" {
            commitAskFocusedAction(session: target)
            return
        }

        switch tapApprovalSelection {
        case .allow:
            approveSession(target)
        case .deny:
            rejectSession(target)
        }
    }

    private func askQuestions(for session: SessionState) -> [SessionAskUserQuestionItem]? {
        guard session.pendingToolName == "AskUserQuestion",
              let toolInput = session.activePermission?.toolInput,
              let questionsRaw = toolInput["questions"]?.value as? [[String: Any]] else {
            return nil
        }

        let parsed = questionsRaw.compactMap { q -> SessionAskUserQuestionItem? in
            guard let question = q["question"] as? String else { return nil }
            let multiSelect = q["multiSelect"] as? Bool ?? false
            let optionsRaw = q["options"] as? [[String: Any]] ?? []
            let options = optionsRaw.compactMap { $0["label"] as? String }
            return SessionAskUserQuestionItem(question: question, options: options, multiSelect: multiSelect)
        }

        return parsed.isEmpty ? nil : parsed
    }

    private func askStateKey(for session: SessionState) -> String? {
        guard let toolUseId = session.pendingToolId else { return nil }
        return "\(session.sessionId)::\(toolUseId)"
    }

    private func askSelections(for session: SessionState) -> [Int: Set<String>] {
        guard let key = askStateKey(for: session) else { return [:] }
        return askSelectedByKey[key] ?? [:]
    }

    private func askFocusTargets(for session: SessionState, questions: [SessionAskUserQuestionItem]) -> [AskFocusTarget] {
        SessionAskUserQuestionCard.buildFocusTargets(questions: questions, selected: askSelections(for: session))
    }

    private func askFocusIndex(for session: SessionState, questions: [SessionAskUserQuestionItem]) -> Int {
        guard let key = askStateKey(for: session) else { return 0 }
        let targets = askFocusTargets(for: session, questions: questions)
        if targets.isEmpty { return 0 }
        return min(askFocusIndexByKey[key] ?? 0, targets.count - 1)
    }

    private func advanceAskFocus(session: SessionState) {
        guard let questions = askQuestions(for: session),
              let key = askStateKey(for: session) else { return }
        let targets = askFocusTargets(for: session, questions: questions)
        guard !targets.isEmpty else { return }
        let current = min(askFocusIndexByKey[key] ?? 0, targets.count - 1)
        askFocusIndexByKey[key] = (current + 1) % targets.count
        print("[TapControl] advanced AskUserQuestion focus session=\(session.sessionId) from=\(current) to=\(askFocusIndexByKey[key] ?? 0)")
    }

    private func commitAskFocusedAction(session: SessionState) {
        guard let questions = askQuestions(for: session),
              let key = askStateKey(for: session) else { return }
        let targets = askFocusTargets(for: session, questions: questions)
        guard !targets.isEmpty else { return }
        let index = min(askFocusIndexByKey[key] ?? 0, targets.count - 1)
        let target = targets[index]
        print("[TapControl] commit AskUserQuestion focused action session=\(session.sessionId) index=\(index)")
        switch target {
        case .option(let qIdx, let option):
            handleAskOptionTap(session: session, questionIndex: qIdx, option: option)
            if !questions[qIdx].multiSelect {
                askFocusIndexByKey[key] = 0
            }
        case .confirm(let qIdx):
            submitAskSelections(session: session, questionIndex: qIdx, questions: questions)
            askFocusIndexByKey[key] = 0
        }
    }

    private func handleAskOptionTap(session: SessionState, questionIndex: Int, option: String) {
        guard let questions = askQuestions(for: session),
              questionIndex < questions.count,
              let key = askStateKey(for: session) else { return }
        let item = questions[questionIndex]
        if item.multiSelect {
            var all = askSelectedByKey[key] ?? [:]
            var set = all[questionIndex] ?? Set<String>()
            if set.contains(option) {
                set.remove(option)
            } else {
                set.insert(option)
            }
            all[questionIndex] = set
            askSelectedByKey[key] = all
            return
        }
        Task {
            let sent = await sessionMonitor.sendInteractiveAnswer(
                sessionId: session.sessionId,
                text: option
            )
            if !sent {
                print("[ClaudeInstancesView] Failed to send AskUserQuestion answer for session \(session.sessionId)")
            }
        }
    }

    private func submitAskSelections(session: SessionState, questionIndex: Int, questions: [SessionAskUserQuestionItem]) {
        guard questionIndex < questions.count,
              questions[questionIndex].multiSelect,
              let key = askStateKey(for: session) else { return }
        let selected = (askSelectedByKey[key]?[questionIndex] ?? [])
        guard !selected.isEmpty else { return }
        let text = selected.sorted().joined(separator: ", ")
        Task {
            let sent = await sessionMonitor.sendInteractiveAnswer(
                sessionId: session.sessionId,
                text: text
            )
            guard sent else {
                print("[ClaudeInstancesView] Failed to submit AskUserQuestion multi-select answer for session \(session.sessionId)")
                return
            }

            await MainActor.run {
                var all = askSelectedByKey[key] ?? [:]
                all[questionIndex] = []
                askSelectedByKey[key] = all
            }
        }
    }

    // MARK: - Actions

    private func focusSession(_ session: SessionState) {
        guard session.isInTmux else { return }

        Task {
            if let pid = session.pid {
                _ = await YabaiController.shared.focusWindow(forClaudePid: pid)
            } else {
                _ = await YabaiController.shared.focusWindow(forWorkingDirectory: session.cwd)
            }
        }
    }

    private func openChat(_ session: SessionState) {
        viewModel.showChat(for: session)
    }

    private func approveSession(_ session: SessionState) {
        sessionMonitor.approvePermission(sessionId: session.sessionId)
    }

    private func rejectSession(_ session: SessionState) {
        sessionMonitor.denyPermission(sessionId: session.sessionId, reason: nil)
    }

    private func archiveSession(_ session: SessionState) {
        sessionMonitor.archiveSession(sessionId: session.sessionId)
    }
}

enum AskFocusTarget: Equatable {
    case option(questionIndex: Int, option: String)
    case confirm(questionIndex: Int)
}

struct SessionAskUserQuestionItem {
    let question: String
    let options: [String]
    let multiSelect: Bool
}

struct SessionAskUserQuestionCard: View {
    let session: SessionState
    let questions: [SessionAskUserQuestionItem]
    let focusedSessionId: String?
    let focusIndex: Int
    let selectedByQuestion: [Int: Set<String>]
    let onSelectSession: () -> Void
    let onTapOption: (Int, String) -> Void
    let onTapConfirm: (Int) -> Void

    static func buildFocusTargets(
        questions: [SessionAskUserQuestionItem],
        selected: [Int: Set<String>]
    ) -> [AskFocusTarget] {
        var targets: [AskFocusTarget] = []
        for (qIdx, item) in questions.enumerated() {
            for option in item.options {
                targets.append(.option(questionIndex: qIdx, option: option))
            }
            if item.multiSelect && !(selected[qIdx] ?? []).isEmpty {
                targets.append(.confirm(questionIndex: qIdx))
            }
        }
        return targets
    }

    private var focusTargets: [AskFocusTarget] {
        Self.buildFocusTargets(questions: questions, selected: selectedByQuestion)
    }

    private var clampedFocusIndex: Int {
        guard !focusTargets.isEmpty else { return 0 }
        return min(focusIndex, focusTargets.count - 1)
    }

    private func isFocusedTarget(_ target: AskFocusTarget) -> Bool {
        guard focusedSessionId == session.sessionId, !focusTargets.isEmpty else { return false }
        return focusTargets[clampedFocusIndex] == target
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(MCPToolFormatter.formatToolName("AskUserQuestion"))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(TerminalColors.amber)

            ForEach(Array(questions.enumerated()), id: \.offset) { questionIndex, item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.question)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)

                    FlowLayout(spacing: 6) {
                        ForEach(item.options, id: \.self) { option in
                            let target = AskFocusTarget.option(questionIndex: questionIndex, option: option)
                            let isSelected = (selectedByQuestion[questionIndex] ?? []).contains(option)
                            let isFocused = isFocusedTarget(target)

                            Button {
                                onSelectSession()
                                onTapOption(questionIndex, option)
                            } label: {
                                Text(option)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor((isSelected || isFocused) ? .black : .white.opacity(0.85))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill((isSelected || isFocused) ? Color.white.opacity(0.9) : Color.white.opacity(0.1))
                                    )
                            }
                            .buttonStyle(.plain)
                        }

                        if item.multiSelect && !(selectedByQuestion[questionIndex] ?? []).isEmpty {
                            let target = AskFocusTarget.confirm(questionIndex: questionIndex)
                            let isFocused = isFocusedTarget(target)
                            Button {
                                onSelectSession()
                                onTapConfirm(questionIndex)
                            } label: {
                                Text("Confirm")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(isFocused ? Color.white.opacity(0.95) : TerminalColors.amber)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill((focusedSessionId == session.sessionId) ? Color.white.opacity(0.08) : Color.white.opacity(0.04))
        )
        .onTapGesture {
            onSelectSession()
        }
    }
}

// MARK: - Instance Row

struct InstanceRow: View {
    let session: SessionState
    let onSelect: () -> Void
    let onFocus: () -> Void
    let onChat: () -> Void
    let onArchive: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void
    let tapSelectedApproval: ApprovalSelection?
    let isFocusedForTapInput: Bool

    @State private var isHovered = false
    @State private var spinnerPhase = 0
    @State private var isYabaiAvailable = false

    private let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)
    private let spinnerSymbols = ["·", "✢", "✳", "∗", "✻", "✽"]
    private let spinnerTimer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    /// Whether we're showing the approval UI
    private var isWaitingForApproval: Bool {
        session.phase.isWaitingForApproval
    }

    /// Whether the pending tool requires interactive input (not just approve/deny)
    private var isInteractiveTool: Bool {
        guard let toolName = session.pendingToolName else { return false }
        return toolName == "AskUserQuestion"
    }

    /// Status text based on session phase (fallback when no other content)
    private var phaseStatusText: String {
        switch session.phase {
        case .processing:
            return "Processing..."
        case .compacting:
            return "Compacting..."
        case .waitingForInput:
            return "Ready"
        case .waitingForApproval:
            return "Waiting for approval"
        case .idle:
            return "Idle"
        case .ended:
            return "Ended"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // State indicator on left
            stateIndicator
                .frame(width: 14)

            // Text content
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.displayTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    // Token usage indicator
                    if session.usage.totalTokens > 0 {
                        Text(session.usage.formattedTotal)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.3))
                    }
                }

                // Show tool call when waiting for approval, otherwise last activity
                if isWaitingForApproval, let toolName = session.pendingToolName {
                    // Show tool name in amber + input on same line
                    HStack(spacing: 4) {
                        Text(MCPToolFormatter.formatToolName(toolName))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(TerminalColors.amber.opacity(0.9))
                        if isInteractiveTool {
                            Text("Needs your input")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5))
                                .lineLimit(1)
                        } else if let input = session.pendingToolInput {
                            Text(input)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5))
                                .lineLimit(1)
                        }
                    }
                } else if let role = session.lastMessageRole {
                    switch role {
                    case "tool":
                        // Tool call - show tool name + input
                        HStack(spacing: 4) {
                            if let toolName = session.lastToolName {
                                Text(MCPToolFormatter.formatToolName(toolName))
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                            if let input = session.lastMessage {
                                Text(input)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.4))
                                    .lineLimit(1)
                            }
                        }
                    case "user":
                        // User message - prefix with "You:"
                        HStack(spacing: 4) {
                            Text("You:")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.5))
                            if let msg = session.lastMessage {
                                Text(msg)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.4))
                                    .lineLimit(1)
                            }
                        }
                    default:
                        // Assistant message - just show text
                        if let msg = session.lastMessage {
                            Text(msg)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.4))
                                .lineLimit(1)
                        }
                    }
                } else if let lastMsg = session.lastMessage {
                    Text(lastMsg)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)
                } else {
                    // Fallback: show phase-based status when no other content
                    Text(phaseStatusText)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            // Action icons or approval buttons
            if isWaitingForApproval && isInteractiveTool {
                // Interactive tools like AskUserQuestion - show chat + terminal buttons
                HStack(spacing: 8) {
                    IconButton(icon: "bubble.left") {
                        onChat()
                    }

                    // Go to Terminal button (only if yabai available)
                    if isYabaiAvailable {
                        TerminalButton(
                            isEnabled: session.isInTmux,
                            onTap: { onFocus() }
                        )
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else if isWaitingForApproval {
                InlineApprovalButtons(
                    onChat: onChat,
                    onApprove: onApprove,
                    onReject: onReject,
                    selectedAction: tapSelectedApproval ?? .allow
                )
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
                HStack(spacing: 8) {
                    // Chat icon - always show
                    IconButton(icon: "bubble.left") {
                        onChat()
                    }

                    // Focus icon (only for tmux instances with yabai)
                    if session.isInTmux && isYabaiAvailable {
                        IconButton(icon: "eye") {
                            onFocus()
                        }
                    }

                    // Archive button - only for idle or completed sessions
                    if session.phase == .idle || session.phase == .waitingForInput {
                        IconButton(icon: "archivebox") {
                            onArchive()
                        }
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onChat()
        }
        .onTapGesture {
            onSelect()
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isWaitingForApproval)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    isFocusedForTapInput
                        ? Color.white.opacity(0.1)
                        : (isHovered ? Color.white.opacity(0.06) : Color.clear)
                )
        )
        .onHover { isHovered = $0 }
        .task {
            isYabaiAvailable = await WindowFinder.shared.isYabaiAvailable()
        }
    }

    @ViewBuilder
    private var stateIndicator: some View {
        switch session.phase {
        case .processing, .compacting:
            Text(spinnerSymbols[spinnerPhase % spinnerSymbols.count])
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(claudeOrange)
                .onReceive(spinnerTimer) { _ in
                    spinnerPhase = (spinnerPhase + 1) % spinnerSymbols.count
                }
        case .waitingForApproval:
            Text(spinnerSymbols[spinnerPhase % spinnerSymbols.count])
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(TerminalColors.amber)
                .onReceive(spinnerTimer) { _ in
                    spinnerPhase = (spinnerPhase + 1) % spinnerSymbols.count
                }
        case .waitingForInput:
            Circle()
                .fill(TerminalColors.green)
                .frame(width: 6, height: 6)
        case .idle, .ended:
            Circle()
                .fill(Color.white.opacity(0.2))
                .frame(width: 6, height: 6)
        }
    }

}

// MARK: - Inline Approval Buttons

/// Compact inline approval buttons with staggered animation
struct InlineApprovalButtons: View {
    let onChat: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void
    let selectedAction: ApprovalSelection

    @State private var showChatButton = false
    @State private var showDenyButton = false
    @State private var showAllowButton = false

    var body: some View {
        HStack(spacing: 6) {
            // Chat button
            IconButton(icon: "bubble.left") {
                onChat()
            }
            .opacity(showChatButton ? 1 : 0)
            .scaleEffect(showChatButton ? 1 : 0.8)

            Button {
                onReject()
            } label: {
                Text("Deny")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(selectedAction == .deny ? .black : .white.opacity(0.6))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(selectedAction == .deny ? Color.white.opacity(0.9) : Color.white.opacity(0.1))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showDenyButton ? 1 : 0)
            .scaleEffect(showDenyButton ? 1 : 0.8)

            Button {
                onApprove()
            } label: {
                Text("Allow")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(selectedAction == .allow ? .black : .white.opacity(0.6))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(selectedAction == .allow ? Color.white.opacity(0.9) : Color.white.opacity(0.1))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showAllowButton ? 1 : 0)
            .scaleEffect(showAllowButton ? 1 : 0.8)
        }
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.0)) {
                showChatButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                showDenyButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.1)) {
                showAllowButton = true
            }
        }
    }
}

// MARK: - Icon Button

struct IconButton: View {
    let icon: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isHovered ? .white.opacity(0.8) : .white.opacity(0.4))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Compact Terminal Button (inline in description)

struct CompactTerminalButton: View {
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button {
            if isEnabled {
                onTap()
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "terminal")
                    .font(.system(size: 8, weight: .medium))
                Text("Go to Terminal")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(isEnabled ? .white.opacity(0.9) : .white.opacity(0.3))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isEnabled ? Color.white.opacity(0.15) : Color.white.opacity(0.05))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Terminal Button

struct TerminalButton: View {
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button {
            if isEnabled {
                onTap()
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "terminal")
                    .font(.system(size: 9, weight: .medium))
                Text("Terminal")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isEnabled ? .black : .white.opacity(0.4))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isEnabled ? Color.white.opacity(0.95) : Color.white.opacity(0.1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
