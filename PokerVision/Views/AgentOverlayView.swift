import SwiftUI

/// Top-level agent overlay: a semi-transparent panel that hosts cards and
/// sits above the live video stream + cube. It is hit-test transparent
/// outside the cards themselves so it never blocks cube interactions.
struct AgentOverlayView: View {
    @ObservedObject var session: AgentSessionViewModel
    @ObservedObject var ptt: PushToTalkController
    @ObservedObject private var googleAuth: GoogleAuthManager = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                AgentHeaderView(session: session)
                Spacer(minLength: 8)
                Button {
                    session.toggleExpanded()
                } label: {
                    Image(systemName: session.isExpanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .padding(8)
                        .background(Color.black.opacity(0.55))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            if ptt.isRecording {
                ListeningIndicator(
                    partial: ptt.partialTranscript ?? "",
                    onCancel: { ptt.cancelListening() }
                )
                .padding(.horizontal, 12)
            }

            if session.isExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        AgentFallbackTextInput(session: session, ptt: ptt)
                        // Phase D: assistant text reply is always shown first
                        // when present — that's the chat-like answer.
                        if let info = session.lastInfo {
                            InfoCard(info: info)
                        }
                        if let panel = session.currentPanel {
                            switch panel {
                            case .calendar(let data):
                                CalendarPanelCard(data: data)
                            case .solution(let data):
                                SolutionPanelCard(data: data)
                            }
                        }
                        if let proposal = session.currentProposal {
                            ProposalCard(
                                proposal: proposal,
                                isProcessing: session.isProcessing,
                                onConfirm: { Task { await session.confirm() } },
                                onCancel: { session.cancelProposal() }
                            )
                        }
                        if let clarify = session.currentClarification {
                            ClarifyCard(
                                clarification: clarify,
                                onAnswer: { ans in
                                    Task { await session.answerClarification(ans) }
                                }
                            )
                        }
                        if let result = session.lastResult {
                            ResultCard(result: result)
                        }
                        if let last = session.transcripts.last {
                            TranscriptCard(transcript: last)
                        }
                        if !session.history.isEmpty {
                            HistoryListView(items: session.history)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 360)
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if let partial = ptt.partialTranscript, !partial.isEmpty, !ptt.isRecording {
                LivePartialView(partial: partial)
                    .padding(.horizontal, 12)
            } else if !session.statusMessage.isEmpty && !ptt.isRecording {
                Text(session.statusMessage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 12)
            }

            if let googleErr = googleAuth.lastErrorMessage {
                Text(googleErr)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.yellow)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.55), Color.black.opacity(0.0)],
                startPoint: .top, endPoint: .bottom
            )
        )
        .animation(.easeInOut(duration: 0.18), value: session.isExpanded)
        .animation(.easeInOut(duration: 0.18), value: session.currentProposal)
        .animation(.easeInOut(duration: 0.18), value: session.currentClarification)
        .animation(.easeInOut(duration: 0.18), value: session.lastResult)
        .animation(.easeInOut(duration: 0.18), value: ptt.isRecording)
    }
}

// MARK: - Listening indicator (shown while speech is active)

private struct ListeningIndicator: View {
    let partial: String
    let onCancel: () -> Void
    @State private var pulse: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .scaleEffect(pulse ? 1.25 : 0.85)
                .animation(
                    .easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                    value: pulse
                )
            Text(partial.isEmpty ? "Listening…" : partial)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .padding(6)
                    .background(Color.white.opacity(0.18))
                    .clipShape(Circle())
            }
            .accessibilityLabel("Cancel listening")
            .accessibilityIdentifier("listen_cancel_button")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.6))
        .clipShape(Capsule())
        .onAppear { pulse = true }
    }
}

// MARK: - Header

private struct AgentHeaderView: View {
    @ObservedObject var session: AgentSessionViewModel
    @ObservedObject private var googleAuth: GoogleAuthManager = .shared
    @State private var showSignedInMenu: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.isProcessing ? Color.yellow : Color.green)
                .frame(width: 8, height: 8)
            Text("Assistant")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
            Spacer(minLength: 8)
            googleButton
        }
    }

    @ViewBuilder
    private var googleButton: some View {
        if googleAuth.isSignedIn, let email = googleAuth.userEmail {
            Menu {
                Text(email)
                Button("Sign out", role: .destructive) {
                    googleAuth.signOut()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.green)
                    Text("Connected as \(shortEmail(email))")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.55))
                .clipShape(Capsule())
            }
        } else {
            Button {
                googleAuth.signIn()
            } label: {
                HStack(spacing: 4) {
                    if googleAuth.isBusy {
                        ProgressView().tint(.white).scaleEffect(0.6, anchor: .center)
                    } else {
                        Image(systemName: "g.circle")
                            .font(.system(size: 12, weight: .bold))
                    }
                    Text(googleAuth.isBusy ? "Signing in…" : "Connect Google")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.55))
                .clipShape(Capsule())
            }
            .disabled(googleAuth.isBusy)
        }
    }

    private func shortEmail(_ email: String) -> String {
        if email.count > 24, let at = email.firstIndex(of: "@") {
            return email[..<at].prefix(10) + "…" + email[at...]
        }
        return email
    }
}

// MARK: - Cards

struct TranscriptCard: View {
    let transcript: AgentTranscript
    var body: some View {
        AgentCard(title: "Transcript", icon: "text.bubble.fill", accent: .blue) {
            Text("\u{201C}\(transcript.text)\u{201D}")
                .font(.system(size: 14))
                .foregroundColor(.white)
        }
    }
}

struct ProposalCard: View {
    let proposal: AgentProposal
    let isProcessing: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        AgentCard(title: "Proposal", icon: "wand.and.stars", accent: .purple) {
            VStack(alignment: .leading, spacing: 8) {
                Text(proposal.summary)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                if let args = proposal.calendarArgs {
                    KeyValueRow(key: "Tool", value: proposal.tool.rawValue)
                    KeyValueRow(key: "Title", value: args.title)
                    KeyValueRow(key: "Start", value: humanReadable(args.startISO))
                    KeyValueRow(key: "Duration", value: "\(args.durationMinutes) min")
                    if !args.attendees.isEmpty {
                        KeyValueRow(key: "Attendees", value: args.attendees.joined(separator: ", "))
                    }
                }
                HStack(spacing: 8) {
                    Button(action: onConfirm) {
                        Text(isProcessing ? "Working…" : "Confirm")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.green.opacity(0.85))
                            .clipShape(Capsule())
                    }
                    .disabled(isProcessing)

                    Button(action: onCancel) {
                        Text("Cancel")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.18))
                            .clipShape(Capsule())
                    }
                    .disabled(isProcessing)
                }
                .padding(.top, 4)
            }
        }
    }
}

struct ResultCard: View {
    let result: AgentResult
    var body: some View {
        AgentCard(
            title: "Result",
            icon: result.success ? "checkmark.seal.fill" : "xmark.octagon.fill",
            accent: result.success ? .green : .red
        ) {
            VStack(alignment: .leading, spacing: 4) {
                Text(result.summary)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                if let detail = result.detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.75))
                }
            }
        }
    }
}

struct ClarifyCard: View {
    let clarification: AgentClarification
    let onAnswer: (String) -> Void
    @State private var answer: String = ""

    var body: some View {
        AgentCard(title: "Clarify", icon: "questionmark.bubble.fill", accent: .orange) {
            VStack(alignment: .leading, spacing: 8) {
                Text(clarification.question)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                HStack(spacing: 8) {
                    TextField("Your answer", text: $answer)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.send)
                        .onSubmit { send() }
                    Button("Send") { send() }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.blue.opacity(0.85))
                        .clipShape(Capsule())
                        .disabled(answer.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func send() {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onAnswer(trimmed)
        answer = ""
    }
}

struct InfoCard: View {
    let info: AgentInfo
    var body: some View {
        AgentCard(title: "Assistant", icon: "sparkles", accent: .cyan) {
            Text(info.message)
                .font(.system(size: 14))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Phase E panels

struct CalendarPanelCard: View {
    let data: CalendarPanelData
    var body: some View {
        AgentCard(
            title: "\(data.title) — \(data.dateLabel)",
            icon: "calendar",
            accent: .blue
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if data.events.isEmpty {
                    Text("No events.")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.7))
                } else {
                    ForEach(data.events) { event in
                        HStack(alignment: .top, spacing: 10) {
                            Text(event.timeRange)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.85))
                                .frame(width: 96, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white)
                                if let loc = event.location {
                                    Text(loc)
                                        .font(.system(size: 11))
                                        .foregroundColor(.white.opacity(0.6))
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }
}

struct SolutionPanelCard: View {
    let data: SolutionPanelData
    var body: some View {
        AgentCard(title: "Analysis", icon: "wand.and.stars.inverse", accent: .purple) {
            VStack(alignment: .leading, spacing: 8) {
                Text(data.problemSummary)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
                if !data.steps.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(data.steps.enumerated()), id: \.offset) { idx, step in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(idx + 1).")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(.cyan)
                                    .frame(width: 18, alignment: .leading)
                                Text(step)
                                    .font(.system(size: 12))
                                    .foregroundColor(.white.opacity(0.92))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if let answer = data.finalAnswer {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Answer:")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.cyan)
                        Text(answer)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .padding(.top, 2)
                }
            }
        }
    }
}

struct HistoryListView: View {
    let items: [AgentHistoryEntry]
    var body: some View {
        AgentCard(title: "History", icon: "clock.arrow.circlepath", accent: .teal) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items.suffix(8)) { entry in
                    HStack(alignment: .top, spacing: 6) {
                        Text(symbol(for: entry.kind))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(color(for: entry.kind))
                            .frame(width: 14, alignment: .leading)
                        Text(entry.text)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.85))
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    private func symbol(for k: AgentHistoryEntry.Kind) -> String {
        switch k {
        case .transcript: return ">"
        case .proposal: return "?"
        case .confirm: return "✓"
        case .execute: return "*"
        case .result: return "="
        case .clarify: return "?"
        case .info: return "i"
        case .errorEntry: return "!"
        case .reset: return "·"
        }
    }
    private func color(for k: AgentHistoryEntry.Kind) -> Color {
        switch k {
        case .transcript: return .blue
        case .proposal, .clarify: return .purple
        case .confirm, .execute, .result: return .green
        case .errorEntry: return .red
        case .info, .reset: return .gray
        }
    }
}

private struct LivePartialView: View {
    let partial: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform")
                .foregroundColor(.cyan)
            Text(partial)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.55))
        .clipShape(Capsule())
    }
}

// MARK: - Card chrome

private struct AgentCard<Content: View>: View {
    let title: String
    let icon: String
    let accent: Color
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundColor(accent)
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
            }
            content()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(accent.opacity(0.4), lineWidth: 1)
        )
    }
}

private struct KeyValueRow: View {
    let key: String
    let value: String
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(key)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Listening controller (gesture-driven, silence-finalized)

/// Bridges SpeechService into SwiftUI state. Phase-3 behavior:
/// - `startListening()` is triggered by the open-palm gesture (from the view
///   model), NOT by a push-to-talk button.
/// - The SpeechService auto-finalizes after `silenceTimeout` seconds of
///   silence and the delegate callback submits the transcript.
/// - `cancelListening()` is called from the HUD "Cancel" button and from
///   Stop-Streaming.
///
/// The "PushToTalkController" class name is kept for minimum blast radius;
/// no push-to-talk UI remains.
@MainActor
final class PushToTalkController: ObservableObject, SpeechServiceDelegate {
    @Published var isRecording: Bool = false
    @Published var partialTranscript: String?
    @Published var availability: SpeechAvailability = .available
    /// True when speech is unavailable/denied → UI offers text-input fallback.
    @Published var devModeOnly: Bool = false

    private let speech = SpeechService()
    weak var session: AgentSessionViewModel?

    init() {
        speech.delegate = self
    }

    func bind(session: AgentSessionViewModel) {
        self.session = session
    }

    func ensurePermissions() async {
        let result = await speech.requestPermissions()
        availability = result
        devModeOnly = (result != .available)
        NSLog(
            "[Listen] availability=%@ devModeOnly=%d",
            String(describing: result), devModeOnly ? 1 : 0)
    }

    /// Triggered by the open-palm gesture in PokerVisionViewModel.
    func startListening() {
        guard !isRecording else {
            NSLog("[Listen] startListening ignored — already recording")
            return
        }
        guard !devModeOnly else {
            NSLog("[Listen] devModeOnly — expanding HUD for text input")
            session?.isExpanded = true
            session?.statusMessage = "Type your request below"
            return
        }
        do {
            try speech.start()
            isRecording = true
            partialTranscript = ""
            session?.isExpanded = true
            session?.statusMessage = "Listening…"
            NSLog("[Listen] startListening OK")
        } catch {
            NSLog("[Listen] start failed: %@", String(describing: error))
            devModeOnly = true
            availability = .unknownError(String(describing: error))
            session?.isExpanded = true
            session?.statusMessage = "Speech unavailable — use text input"
        }
    }

    /// Called by HUD Cancel button and by Stop-Streaming.
    func cancelListening() {
        guard isRecording else { return }
        speech.cancel()
        isRecording = false
        partialTranscript = nil
        session?.statusMessage = "Cancelled"
        NSLog("[Listen] cancel")
    }

    // MARK: SpeechServiceDelegate

    func speechService(_ service: SpeechService, didUpdatePartial text: String) {
        partialTranscript = text
    }

    func speechService(_ service: SpeechService, didFinishWith text: String?) {
        isRecording = false
        partialTranscript = nil
        guard let session else { return }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            NSLog("[Listen] empty finalize — logging to history, no submit")
            session.history.append(
                .init(kind: .info, text: "No speech detected", timestamp: Date()))
            session.statusMessage = "No speech detected"
            return
        }
        Task { await session.submit(transcript: trimmed) }
    }

    func speechService(_ service: SpeechService, didFailWith error: Error) {
        let ns = error as NSError
        NSLog(
            "[Listen] speech error domain=%@ code=%d — suppressing UI flip", ns.domain, ns.code)
        // Do NOT switch to dev mode on transient errors. Just end this session.
        isRecording = false
        partialTranscript = nil
        session?.statusMessage = "Listening stopped"
    }
}

/// HUD-level fallback text input (shown only when speech is unavailable).
/// Replaces the old PTT bar entirely.
struct AgentFallbackTextInput: View {
    @ObservedObject var session: AgentSessionViewModel
    @ObservedObject var ptt: PushToTalkController
    @FocusState private var focused: Bool

    var body: some View {
        if ptt.devModeOnly {
            VStack(alignment: .leading, spacing: 6) {
                Text("Speech unavailable — type your request:")
                    .font(.caption2)
                    .foregroundColor(.yellow)
                HStack(spacing: 8) {
                    TextField("Type a request…", text: $session.devModeText)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.send)
                        .focused($focused)
                        .onSubmit { send() }
                    Button(action: send) {
                        Image(systemName: "paperplane.fill")
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color.blue.opacity(0.85))
                            .clipShape(Circle())
                    }
                    .disabled(session.devModeText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func send() {
        let text = session.devModeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        session.devModeText = ""
        focused = false
        Task { await session.submit(transcript: text) }
    }
}
