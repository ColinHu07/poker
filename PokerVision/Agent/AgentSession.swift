import CoreLocation
import Foundation
import SwiftUI

// MARK: - Models

/// A single recognized utterance from speech (or dev-mode text input).
struct AgentTranscript: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let timestamp: Date
}

/// Tools the agent can propose. MVP: calendar create. Read/find-free are stubs.
enum AgentTool: String, Codable, Equatable {
    case createCalendarEvent
    case readSchedule
    case findFreeTime
}

/// Structured arguments for `createCalendarEvent`.
struct CalendarEventArgs: Equatable, Codable {
    var title: String
    var startISO: String
    var durationMinutes: Int
    var attendees: [String]
    var notes: String?
}

/// Unified backend response. Every reply carries an `assistantText` —
/// that's the natural-language "Assistant" reply card the user always sees.
/// Proposal / clarification / panel are optional structured extras.
struct AgentReply: Equatable {
    var assistantText: String
    var proposal: AgentProposal? = nil
    var clarification: AgentClarification? = nil
    var panel: AgentPanel? = nil
}

enum AgentResponse: Equatable {
    case reply(AgentReply)
    case error(String)
}

struct AgentProposal: Identifiable, Equatable {
    let id = UUID()
    let summary: String
    let tool: AgentTool
    let calendarArgs: CalendarEventArgs?
    let requiresConfirmation: Bool
}

// MARK: - Panels (Phase E)

/// Structured UI cards the agent can attach to a reply.
enum AgentPanel: Equatable, Identifiable {
    case calendar(CalendarPanelData)
    case solution(SolutionPanelData)

    var id: UUID {
        switch self {
        case .calendar(let d): return d.id
        case .solution(let d): return d.id
        }
    }
}

struct CalendarPanelData: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let dateLabel: String
    let events: [CalendarEventDisplay]
}

struct CalendarEventDisplay: Identifiable, Equatable {
    let id = UUID()
    let timeRange: String
    let title: String
    let location: String?
}

struct SolutionPanelData: Identifiable, Equatable {
    let id = UUID()
    let problemSummary: String
    let steps: [String]
    let finalAnswer: String?
}

struct AgentClarification: Identifiable, Equatable {
    let id = UUID()
    let question: String
}

struct AgentInfo: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

struct AgentResult: Identifiable, Equatable {
    let id = UUID()
    let success: Bool
    let summary: String
    let detail: String?
}

/// One audit entry; we keep an append-only list of these.
struct AgentHistoryEntry: Identifiable, Equatable {
    enum Kind: String {
        case transcript
        case proposal
        case confirm
        case execute
        case result
        case clarify
        case info
        case errorEntry
        case reset
    }
    let id = UUID()
    let kind: Kind
    let text: String
    let timestamp: Date
}

/// User context sent with every request.
struct AgentContext: Equatable {
    let timeZoneIdentifier: String
    let nowISO: String
    let location: AgentLocation?
}

struct AgentLocation: Equatable, Codable {
    let lat: Double
    let lon: Double
    let placeName: String?
    let accuracy: Double?
    let timestamp: Date
}

// MARK: - Backend protocol

/// Abstraction so we can plug in a real backend later (HTTP, GraphQL, etc.).
protocol AgentBackend: Sendable {
    func submit(transcript: String, context: AgentContext) async -> AgentResponse
    func confirm(proposal: AgentProposal, context: AgentContext) async -> AgentResult
    func analyze(imageData: Data, context: AgentContext) async -> AgentResponse
}

// MARK: - Mock backend

/// In-memory mock that:
/// - Parses keywords ("schedule", "meeting", "remind", "tomorrow", etc.)
/// - Returns a Proposal (create_calendar_event) for actionable utterances
/// - Returns a Clarification when the request is ambiguous
/// - Returns Info for greetings / "what's on my calendar"
/// - Stores accepted events in `acceptedEvents` so you can verify execution
actor MockAgentBackend: AgentBackend {
    private(set) var acceptedEvents: [CalendarEventArgs] = []

    func submit(transcript: String, context: AgentContext) async -> AgentResponse {
        let lower = transcript.lowercased()
        guard !lower.isEmpty else {
            return .error("Empty transcript")
        }

        // Greeting / introduction
        if lower.contains("hello") || lower == "hi" || lower.hasPrefix("hi ") {
            return .reply(
                AgentReply(
                    assistantText:
                        "Hi! I can schedule events, look up your calendar, or analyze what your camera sees. Show two fingers up to analyze the scene, or say something like 'schedule a call tomorrow at 2pm'."
                )
            )
        }

        // Calendar lookup intent ("what's on my calendar tomorrow")
        let isLookup =
            lower.contains("what's on my calendar") || lower.contains("what is on my calendar")
            || lower.contains("schedule today") || lower.contains("schedule tomorrow")
            || lower.contains("my calendar") || lower.contains("agenda")
            || (lower.contains("calendar") && (lower.contains("tomorrow") || lower.contains("today")))
        if isLookup {
            let isTomorrow = lower.contains("tomorrow")
            let label = isTomorrow ? "Tomorrow" : "Today"
            let panel = CalendarPanelData(
                title: "Schedule",
                dateLabel: label,
                events: mockEvents(forTomorrow: isTomorrow)
            )
            return .reply(
                AgentReply(
                    assistantText:
                        "Here's what's on your calendar \(label.lowercased()) — \(panel.events.count) events. Let me know if you'd like to add anything.",
                    panel: .calendar(panel)
                )
            )
        }

        // Calendar create intent
        let isCalendarIntent =
            lower.contains("schedule") || lower.contains("meeting")
            || lower.contains("remind") || lower.contains("event")
            || lower.contains("appointment") || lower.contains("set up") || lower.contains("book")
            || lower.contains("add ") && lower.contains("calendar")
        if isCalendarIntent {
            let parsed = parseRoughTime(from: lower, contextNowISO: context.nowISO)
            if parsed.isAmbiguous {
                return .reply(
                    AgentReply(
                        assistantText:
                            "Sure — when should I schedule it? You can say something like 'tomorrow at 2pm' or 'Friday at 10am'.",
                        clarification: AgentClarification(
                            question:
                                "When should I schedule it? (e.g. 'tomorrow at 2pm' or 'Friday at 10am')"
                        )
                    )
                )
            }
            let title = guessTitle(from: lower)
            let args = CalendarEventArgs(
                title: title,
                startISO: parsed.startISO,
                durationMinutes: 30,
                attendees: [],
                notes: "Drafted by agent from: \"\(transcript)\""
            )
            let proposal = AgentProposal(
                summary:
                    "Create '\(title)' on \(humanReadable(args.startISO)) for \(args.durationMinutes) min",
                tool: .createCalendarEvent,
                calendarArgs: args,
                requiresConfirmation: true
            )
            return .reply(
                AgentReply(
                    assistantText:
                        "Got it. I can create '\(title)' on \(humanReadable(args.startISO)) for \(args.durationMinutes) minutes. Thumbs-up or tap Confirm to add it to your calendar.",
                    proposal: proposal
                )
            )
        }

        // Generic / unknown — still answer.
        return .reply(
            AgentReply(
                assistantText:
                    "I heard: \u{201C}\(transcript)\u{201D}. I don't have a tool for that yet, but I can schedule events, look up your calendar, or analyze what your camera sees."
            )
        )
    }

    func analyze(imageData: Data, context: AgentContext) async -> AgentResponse {
        // Simulate a vision/LLM round-trip.
        try? await Task.sleep(nanoseconds: 700_000_000)
        let mocks: [(summary: String, steps: [String], answer: String?)] = [
            (
                "Detected a one-step linear equation: 2x + 5 = 13.",
                [
                    "Subtract 5 from both sides: 2x = 8",
                    "Divide both sides by 2: x = 4",
                ],
                "x = 4"
            ),
            (
                "Detected a quadratic equation: x\u{00B2} \u{2212} 5x + 6 = 0.",
                [
                    "Factor: (x \u{2212} 2)(x \u{2212} 3) = 0",
                    "Set each factor to zero",
                    "Solve: x = 2 or x = 3",
                ],
                "x = 2 or x = 3"
            ),
            (
                "Detected a system of two linear equations.",
                [
                    "Add the equations to eliminate y",
                    "Solve for x",
                    "Back-substitute to find y",
                ],
                "(x, y) = (4, \u{2212}1)"
            ),
        ]
        let pick = mocks.randomElement()!
        let panel = SolutionPanelData(
            problemSummary: pick.summary,
            steps: pick.steps,
            finalAnswer: pick.answer
        )
        let answerSuffix = pick.answer.map { " Final answer: \($0)." } ?? ""
        return .reply(
            AgentReply(
                assistantText: "I analyzed the scene. \(pick.summary)\(answerSuffix)",
                panel: .solution(panel)
            )
        )
    }

    private func mockEvents(forTomorrow: Bool) -> [CalendarEventDisplay] {
        if forTomorrow {
            return [
                CalendarEventDisplay(
                    timeRange: "9:00 \u{2013} 9:30", title: "Standup", location: nil),
                CalendarEventDisplay(
                    timeRange: "11:00 \u{2013} 12:00", title: "Design review", location: "Zoom"),
                CalendarEventDisplay(
                    timeRange: "14:30 \u{2013} 15:00", title: "1:1 with Sam", location: nil),
            ]
        } else {
            return [
                CalendarEventDisplay(
                    timeRange: "10:00 \u{2013} 10:30", title: "Email triage", location: nil),
                CalendarEventDisplay(
                    timeRange: "13:00 \u{2013} 13:45", title: "Lunch w/ Alex",
                    location: "Cafe Maya"),
            ]
        }
    }

    func confirm(proposal: AgentProposal, context: AgentContext) async -> AgentResult {
        guard proposal.tool == .createCalendarEvent, let args = proposal.calendarArgs else {
            return AgentResult(
                success: false,
                summary: "Unsupported tool",
                detail: "Tool \(proposal.tool.rawValue) not implemented in mock backend."
            )
        }
        // Simulate API latency
        try? await Task.sleep(nanoseconds: 350_000_000)
        acceptedEvents.append(args)
        return AgentResult(
            success: true,
            summary: "Created '\(args.title)' on \(humanReadable(args.startISO))",
            detail: "Mock backend stored event #\(acceptedEvents.count). No real Google API call."
        )
    }

    // MARK: Helpers

    private func guessTitle(from lower: String) -> String {
        if lower.contains("lunch") { return "Lunch" }
        if lower.contains("standup") { return "Standup" }
        if lower.contains("interview") { return "Interview" }
        if lower.contains("call") { return "Call" }
        if lower.contains("meeting") { return "Meeting" }
        return "Event"
    }

    private func parseRoughTime(from lower: String, contextNowISO: String)
        -> (startISO: String, isAmbiguous: Bool)
    {
        let now = ISO8601DateFormatter().date(from: contextNowISO) ?? Date()
        var date = now.addingTimeInterval(60 * 60)  // default: 1h from now
        var hadHint = false

        if lower.contains("tomorrow") {
            date = Calendar.current.date(byAdding: .day, value: 1, to: now) ?? date
            hadHint = true
        } else if lower.contains("today") {
            hadHint = true
        } else if lower.contains("friday") {
            date = nextWeekday(7 - 1, after: now) ?? date  // Friday = 6 (Sun=1)
            hadHint = true
        } else if lower.contains("monday") {
            date = nextWeekday(2, after: now) ?? date
            hadHint = true
        }

        // Time of day
        if let hour = extractHour(from: lower) {
            var comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
            comps.hour = hour
            comps.minute = 0
            if let combined = Calendar.current.date(from: comps) { date = combined }
            hadHint = true
        }

        let iso = ISO8601DateFormatter().string(from: date)
        return (iso, !hadHint)
    }

    private func nextWeekday(_ targetWeekday: Int, after date: Date) -> Date? {
        let cal = Calendar.current
        var comps = DateComponents()
        comps.weekday = targetWeekday
        return cal.nextDate(after: date, matching: comps, matchingPolicy: .nextTime)
    }

    private func extractHour(from lower: String) -> Int? {
        // "2pm", "2 pm", "14:00", "noon", "midnight"
        if lower.contains("noon") { return 12 }
        if lower.contains("midnight") { return 0 }
        let pattern = #"(\d{1,2})\s?(am|pm|:00)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(lower.startIndex..<lower.endIndex, in: lower)
        guard let match = regex.firstMatch(in: lower, range: nsRange),
            match.numberOfRanges >= 2,
            let hRange = Range(match.range(at: 1), in: lower),
            let h = Int(lower[hRange])
        else { return nil }
        var hour = h
        if match.numberOfRanges >= 3, let suf = Range(match.range(at: 2), in: lower) {
            let s = String(lower[suf])
            if s == "pm" && hour < 12 { hour += 12 }
            if s == "am" && hour == 12 { hour = 0 }
        }
        if hour > 23 { return nil }
        return hour
    }
}

// MARK: - Free helpers (visible to view + view model)

func humanReadable(_ iso: String) -> String {
    guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f.string(from: date)
}

// MARK: - Session view model

@MainActor
final class AgentSessionViewModel: ObservableObject {
    // UI state
    @Published var isExpanded: Bool = false
    @Published var transcripts: [AgentTranscript] = []
    @Published var currentProposal: AgentProposal?
    @Published var currentClarification: AgentClarification?
    @Published var lastResult: AgentResult?
    @Published var lastInfo: AgentInfo?
    @Published var currentPanel: AgentPanel?
    @Published var history: [AgentHistoryEntry] = []
    @Published var isProcessing: Bool = false
    @Published var devModeText: String = ""
    @Published var statusMessage: String = ""

    private let backend: AgentBackend
    private let location: LocationContextProviding

    init(backend: AgentBackend = MockAgentBackend(), location: LocationContextProviding = NoLocationProvider())
    {
        self.backend = backend
        self.location = location
    }

    // MARK: Public API

    func submit(transcript text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = AgentTranscript(text: trimmed, timestamp: Date())
        transcripts.append(entry)
        history.append(.init(kind: .transcript, text: trimmed, timestamp: Date()))
        clearTransientReply()
        isProcessing = true
        statusMessage = "Thinking…"
        isExpanded = true
        NSLog("[Agent] submit transcript=\"%@\"", trimmed)

        let context = makeContext()
        let response = await backend.submit(transcript: trimmed, context: context)
        await MainActor.run { self.handle(response: response) }
    }

    /// Phase B: send a captured frame for analysis. Skips the transcript
    /// list (this isn't speech) but still appears in the audit history.
    func submitAnalyze(imageData: Data) async {
        history.append(
            .init(kind: .transcript, text: "[Analyze scene]", timestamp: Date()))
        clearTransientReply()
        isProcessing = true
        statusMessage = "Analyzing scene…"
        isExpanded = true
        NSLog("[Agent] submitAnalyze bytes=%d", imageData.count)

        let context = makeContext()
        let response = await backend.analyze(imageData: imageData, context: context)
        await MainActor.run { self.handle(response: response) }
    }

    func confirm() async {
        guard let proposal = currentProposal else { return }
        history.append(
            .init(kind: .confirm, text: "Confirmed: \(proposal.summary)", timestamp: Date())
        )
        isProcessing = true
        statusMessage = "Executing…"
        NSLog("[Agent] confirm proposal=\"%@\"", proposal.summary)
        let context = makeContext()
        let result = await backend.confirm(proposal: proposal, context: context)
        await MainActor.run {
            self.lastResult = result
            self.currentProposal = nil
            self.isProcessing = false
            self.statusMessage = result.success ? "Done" : "Failed"
            // Phase D: always emit a brief assistant reply after execute.
            self.lastInfo = AgentInfo(
                message: result.success
                    ? "Done — \(result.summary). Anything else?"
                    : "I couldn't complete that: \(result.summary)"
            )
            self.history.append(
                .init(
                    kind: .result,
                    text: (result.success ? "\u{2713} " : "\u{2717} ") + result.summary,
                    timestamp: Date()
                )
            )
        }
    }

    func cancelProposal() {
        guard let p = currentProposal else { return }
        history.append(.init(kind: .info, text: "Cancelled: \(p.summary)", timestamp: Date()))
        currentProposal = nil
        statusMessage = "Cancelled"
        NSLog("[Agent] proposal cancelled")
    }

    func answerClarification(_ answer: String) async {
        guard currentClarification != nil else { return }
        let combined: String
        if let last = transcripts.last {
            combined = "\(last.text). \(answer)"
        } else {
            combined = answer
        }
        currentClarification = nil
        await submit(transcript: combined)
    }

    func resetForNewSession() {
        NSLog("[Agent] resetForNewSession")
        transcripts.removeAll()
        currentProposal = nil
        currentClarification = nil
        lastResult = nil
        lastInfo = nil
        currentPanel = nil
        history.removeAll()
        history.append(.init(kind: .reset, text: "Session reset", timestamp: Date()))
        isProcessing = false
        devModeText = ""
        statusMessage = ""
        isExpanded = false
    }

    func toggleExpanded() { isExpanded.toggle() }

    // MARK: Private

    /// Wipe the visible reply state — called before every new submission so
    /// stale cards don't linger while the new request is in-flight.
    private func clearTransientReply() {
        currentClarification = nil
        currentProposal = nil
        lastResult = nil
        lastInfo = nil
        currentPanel = nil
    }

    private func handle(response: AgentResponse) {
        isProcessing = false
        switch response {
        case .reply(let r):
            // Phase D: always show the assistant text card.
            lastInfo = AgentInfo(message: r.assistantText)
            history.append(.init(kind: .info, text: r.assistantText, timestamp: Date()))

            if let panel = r.panel {
                currentPanel = panel
                let label: String = {
                    switch panel {
                    case .calendar(let d): return "Calendar panel: \(d.dateLabel)"
                    case .solution(let d): return "Solution panel: \(d.problemSummary)"
                    }
                }()
                history.append(.init(kind: .info, text: label, timestamp: Date()))
            }
            if let p = r.proposal {
                currentProposal = p
                history.append(.init(kind: .proposal, text: p.summary, timestamp: Date()))
            }
            if let c = r.clarification {
                currentClarification = c
                history.append(.init(kind: .clarify, text: c.question, timestamp: Date()))
            }

            statusMessage = {
                if r.proposal != nil { return "Proposal ready" }
                if r.clarification != nil { return "Needs more info" }
                if r.panel != nil { return "Reply ready" }
                return "Reply"
            }()
            NSLog(
                "[Agent] reply text=\"%@\" hasProposal=%d hasPanel=%d hasClarify=%d",
                r.assistantText, r.proposal != nil ? 1 : 0,
                r.panel != nil ? 1 : 0, r.clarification != nil ? 1 : 0)

        case .error(let e):
            lastInfo = AgentInfo(message: "Error: \(e)")
            statusMessage = "Error"
            history.append(.init(kind: .errorEntry, text: e, timestamp: Date()))
            NSLog("[Agent] response=error: %@", e)
        }
    }

    private func makeContext() -> AgentContext {
        AgentContext(
            timeZoneIdentifier: TimeZone.current.identifier,
            nowISO: ISO8601DateFormatter().string(from: Date()),
            location: location.currentLocation()
        )
    }
}

// MARK: - Location context (stubbed; CoreLocation hookup is opt-in)

protocol LocationContextProviding: Sendable {
    func currentLocation() -> AgentLocation?
}

struct NoLocationProvider: LocationContextProviding {
    func currentLocation() -> AgentLocation? { nil }
}
