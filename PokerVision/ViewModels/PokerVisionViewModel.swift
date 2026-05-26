import AVFoundation
import CoreML
import CoreImage
import MWDATCamera
import MWDATCore
import SwiftUI
import Vision

struct DebugInfo {
    var activeSource: String = "None"
    var leftHand: Bool = false
    var rightHand: Bool = false
    var pointingRaw: Bool = false
    var pointingEvent: Bool = false
    var indexExt: CGFloat = 0
    var otherMax: CGFloat = 0
    var cubeState: String = "off"
    var rhMode: String = "idle"
    var scale: CGFloat = 1.0
    var rotX: Float = 0
    var rotY: Float = 0
    var rotZ: Float = 0

    static let empty = DebugInfo()
}

enum PokerVisionBuild {
    static let streamMarker = "META-ONLY STREAM"
    static let cameraPolicy = "No iPhone camera fallback"
}

enum PokerAnalysisSource: String {
    case bundledSample = "Training sample"
    case liveFrame = "Current frame"
}

enum PlayingCardSuit: String, CaseIterable {
    case clubs = "c"
    case diamonds = "d"
    case hearts = "h"
    case spades = "s"

    var symbol: String {
        switch self {
        case .clubs: return "clubs"
        case .diamonds: return "diamonds"
        case .hearts: return "hearts"
        case .spades: return "spades"
        }
    }

    var displaySymbol: String {
        switch self {
        case .clubs: return "♣"
        case .diamonds: return "♦"
        case .hearts: return "♥"
        case .spades: return "♠"
        }
    }

    var displayColor: Color {
        switch self {
        case .diamonds, .hearts: return .red
        case .clubs, .spades: return .primary
        }
    }
}

struct PlayingCard: Identifiable, Hashable {
    let rank: String
    let suit: PlayingCardSuit

    var id: String { code }
    var code: String { "\(rank)\(suit.rawValue)" }
    var display: String { "\(rank)\(suit.displaySymbol)" }
}

enum PokerCardLabelParser {
    static func parse(_ rawLabel: String) -> PlayingCard? {
        let normalized = rawLabel
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "♣", with: " C ")
            .replacingOccurrences(of: "♦", with: " D ")
            .replacingOccurrences(of: "♥", with: " H ")
            .replacingOccurrences(of: "♠", with: " S ")
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: "/", with: "_")

        let compact = normalized.replacingOccurrences(of: #"[^A-Z0-9]"#, with: "", options: .regularExpression)
        if let card = parseCompact(compact) {
            return card
        }

        let ranks: [String: String] = [
            "ACE": "A", "A": "A",
            "KING": "K", "K": "K",
            "QUEEN": "Q", "Q": "Q",
            "JACK": "J", "J": "J",
            "TEN": "10", "10": "10", "T": "10",
            "NINE": "9", "9": "9",
            "EIGHT": "8", "8": "8",
            "SEVEN": "7", "7": "7",
            "SIX": "6", "6": "6",
            "FIVE": "5", "5": "5",
            "FOUR": "4", "4": "4",
            "THREE": "3", "3": "3",
            "TWO": "2", "2": "2",
        ]
        let suits: [String: PlayingCardSuit] = [
            "CLUB": .clubs, "CLUBS": .clubs, "C": .clubs,
            "DIAMOND": .diamonds, "DIAMONDS": .diamonds, "D": .diamonds,
            "HEART": .hearts, "HEARTS": .hearts, "H": .hearts,
            "SPADE": .spades, "SPADES": .spades, "S": .spades,
        ]

        let parts = normalized.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let rank = parts.compactMap { ranks[$0] }.first
        let suit = parts.compactMap { suits[$0] }.first
        guard let rank, let suit else { return nil }
        return PlayingCard(rank: rank, suit: suit)
    }

    private static func parseCompact(_ compact: String) -> PlayingCard? {
        let suitMap: [Character: PlayingCardSuit] = [
            "C": .clubs,
            "D": .diamonds,
            "H": .hearts,
            "S": .spades,
        ]

        if compact.count >= 2, let suit = compact.last.flatMap({ suitMap[$0] }) {
            let rank = String(compact.dropLast())
            if isValidRank(rank) {
                return PlayingCard(rank: displayRank(rank), suit: suit)
            }
        }

        if compact.count >= 2, let suit = compact.first.flatMap({ suitMap[$0] }) {
            let rank = String(compact.dropFirst())
            if isValidRank(rank) {
                return PlayingCard(rank: displayRank(rank), suit: suit)
            }
        }

        return nil
    }

    private static func isValidRank(_ rank: String) -> Bool {
        ["A", "K", "Q", "J", "T", "10", "9", "8", "7", "6", "5", "4", "3", "2"].contains(rank)
    }

    private static func displayRank(_ rank: String) -> String {
        rank == "T" ? "10" : rank
    }
}

struct PokerPlayerState: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let stack: Int?
    let lastAction: String?
    let isDealer: Bool
}

struct RecognizedTextItem: Hashable {
    let text: String
    let confidence: Float
    let boundingBox: CGRect
}

enum PokerDetectionCategory: String, Hashable {
    case heroCard = "Hero card"
    case boardCard = "Board card"
    case pot = "Pot"
    case stack = "Stack"
    case action = "Action"
    case text = "Text"
}

struct PokerDetection: Identifiable, Hashable {
    let id: UUID
    let category: PokerDetectionCategory
    let label: String
    let confidence: Double
    let confidenceSpread: Double
    let normalizedBoundingBox: CGRect
    let normalizedQuadrilateral: [CGPoint]?

    init(
        id: UUID = UUID(),
        category: PokerDetectionCategory,
        label: String,
        confidence: Double,
        confidenceSpread: Double,
        normalizedBoundingBox: CGRect,
        normalizedQuadrilateral: [CGPoint]? = nil
    ) {
        self.id = id
        self.category = category
        self.label = label
        self.confidence = confidence
        self.confidenceSpread = confidenceSpread
        self.normalizedBoundingBox = normalizedBoundingBox
        self.normalizedQuadrilateral = normalizedQuadrilateral
    }

    var confidenceIntervalText: String {
        let lower = max(0, Int((confidence - confidenceSpread) * 100))
        let upper = min(100, Int((confidence + confidenceSpread) * 100))
        return "\(lower)-\(upper)%"
    }
}

struct PokerTableCounts: Equatable, Hashable {
    let playerCount: Int?
    let heroCardCount: Int
    let boardCardCount: Int
}

struct PokerSceneAnalysis: Equatable {
    let source: PokerAnalysisSource
    let heroCards: [PlayingCard]
    let boardCards: [PlayingCard]
    let pot: Int?
    let heroStack: Int?
    let visibleActions: [String]
    let players: [PokerPlayerState]
    let handDescription: String?
    let tableCounts: PokerTableCounts
    let detections: [PokerDetection]
    let recognizedText: [String]
    let notes: [String]
    let analyzedAt: Date

    var summary: String {
        let hero = heroCards.map(\.display).joined(separator: " ")
        let board = boardCards.map(\.display).joined(separator: " ")
        let potText = pot.map { "$\($0)" } ?? "unknown pot"
        return "Hero \(hero.isEmpty ? "unknown" : hero) | Board \(board.isEmpty ? "unknown" : board) | Pot \(potText)"
    }

    var spokenSummary: String {
        var parts: [String] = []
        let hero = heroCards.map { "\($0.rank) of \($0.suit.symbol)" }.joined(separator: ", ")
        if !hero.isEmpty {
            parts.append("Your cards are \(hero).")
        }
        let board = boardCards.map { "\($0.rank) of \($0.suit.symbol)" }.joined(separator: ", ")
        if !board.isEmpty {
            parts.append("The board is \(board).")
        }
        if let pot {
            parts.append("The pot is \(pot).")
        }
        if let handDescription {
            parts.append("Current made hand: \(handDescription).")
        }
        if !visibleActions.isEmpty {
            parts.append("Visible actions are \(visibleActions.joined(separator: ", ")).")
        }
        parts.append("Training readout only. No live play recommendation.")
        return parts.joined(separator: " ")
    }
}

private struct DecisionHoldemSolveRequest: Encodable {
    struct Hero: Encodable {
        let position: String
        let holeCards: [String]

        enum CodingKeys: String, CodingKey {
            case position
            case holeCards = "hole_cards"
        }
    }

    struct HistoryEntry: Encodable {
        let street: String
        let actor: String
        let action: String
        let to: Int?
    }

    let hero: Hero
    let board: [String]
    let history: [HistoryEntry]
}

private struct DecisionHoldemSolveResponse: Decodable {
    struct Action: Decodable {
        let verb: String
        let to: Int?
        let raw: String?
    }

    struct Display: Decodable {
        let primary: String
        let secondary: String?
        let colorHint: String?

        enum CodingKeys: String, CodingKey {
            case primary
            case secondary
            case colorHint = "color_hint"
        }
    }

    let latencyMS: Int
    let solver: String
    let action: Action
    let display: Display

    enum CodingKeys: String, CodingKey {
        case latencyMS = "latency_ms"
        case solver
        case action
        case display
    }
}

private struct DecisionHoldemRemoteResult {
    let displayState: PokerDisplayDecisionHUDState
    let advice: Advice
    let solver: String
    let latencyMS: Int
}

private enum DecisionHoldemAPIClient {
    private static let defaultSolverURLString = "http://34.233.162.151:8000/v1/solve"
    private static let solverURLEnvironmentKey = "SOLVER_API_URL"
    private static let solverURLDefaultsKey = "PokerVisionSolverURL"
    private static let apiKeyEnvironmentKey = "SOLVER_API_KEY"
    private static let apiKeyDefaultsKey = "PokerVisionSolverAPIKey"

    static var isConfigured: Bool {
        apiKey != nil
    }

    static func bootstrapFromEnvironment() {
        let environment = ProcessInfo.processInfo.environment
        if let apiKey = clean(environment[apiKeyEnvironmentKey]) {
            UserDefaults.standard.set(apiKey, forKey: apiKeyDefaultsKey)
        }
        if let solverURL = clean(environment[solverURLEnvironmentKey]) {
            UserDefaults.standard.set(solverURL, forKey: solverURLDefaultsKey)
        }
    }

    static func solve(state: HandState) async throws -> DecisionHoldemRemoteResult {
        guard let apiKey else {
            throw NSError(
                domain: "DecisionHoldemAPI",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Solver API key is missing. Launch with SOLVER_API_KEY."]
            )
        }
        guard state.heroCards.count == 2 else {
            throw NSError(
                domain: "DecisionHoldemAPI",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Need exactly two hero cards before calling the solver."]
            )
        }

        let payload = DecisionHoldemSolveRequest(
            hero: .init(position: "SB", holeCards: state.heroCards.map { solverCode(for: $0) }),
            board: state.boardCards.map { solverCode(for: $0) },
            history: []
        )

        var request = URLRequest(url: solverURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown solver error"
            throw NSError(
                domain: "DecisionHoldemAPI",
                code: (response as? HTTPURLResponse)?.statusCode ?? 3,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        let decoded = try JSONDecoder().decode(DecisionHoldemSolveResponse.self, from: data)
        let rawAction = decoded.action.raw ?? actionText(verb: decoded.action.verb, to: decoded.action.to)
        guard let displayState = PokerDisplayDecisionHUDState.fromDecisionHoldem(rawAction: rawAction) else {
            throw NSError(
                domain: "DecisionHoldemAPI",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Solver returned an unsupported action: \(rawAction)"]
            )
        }

        let advice = Advice(
            action: trainerAction(verb: decoded.action.verb),
            amount: decoded.action.to,
            winPercent: nil,
            neededPercent: nil,
            confidence: state.confidence,
            rationale: decoded.display.secondary ?? "DecisionHoldem API: \(decoded.display.primary)",
            isActionable: true
        )

        return DecisionHoldemRemoteResult(
            displayState: displayState,
            advice: advice,
            solver: decoded.solver,
            latencyMS: decoded.latencyMS
        )
    }

    private static var solverURL: URL {
        let rawURL = clean(UserDefaults.standard.string(forKey: solverURLDefaultsKey))
            ?? clean(ProcessInfo.processInfo.environment[solverURLEnvironmentKey])
            ?? defaultSolverURLString
        return URL(string: rawURL) ?? URL(string: defaultSolverURLString)!
    }

    private static var apiKey: String? {
        clean(UserDefaults.standard.string(forKey: apiKeyDefaultsKey))
            ?? clean(ProcessInfo.processInfo.environment[apiKeyEnvironmentKey])
    }

    private static func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func solverCode(for card: PlayingCard) -> String {
        let rank = card.rank == "10" ? "T" : card.rank
        return "\(rank)\(card.suit.rawValue)"
    }

    private static func actionText(verb: String, to: Int?) -> String {
        if let to, verb.lowercased() == "raise" {
            return "raise \(to)"
        }
        return verb
    }

    private static func trainerAction(verb: String) -> PokerTrainerAction {
        switch verb.lowercased() {
        case "fold": return .fold
        case "check": return .check
        case "call": return .call
        case "bet": return .bet
        case "raise", "allin": return .raise
        default: return .confirmState
        }
    }
}

@MainActor
final class PokerVisionViewModel: ObservableObject {
    @Published var currentVideoFrame: UIImage?
    @Published var hasReceivedFirstFrame = false
    @Published var streamingStatus: StreamingStatus = .stopped
    @Published var hasActiveDevice = true
    @Published var showError = false
    @Published var errorMessage = ""
    @Published var capturedPhoto: UIImage?
    @Published var showPhotoPreview = false
    @Published var debugInfo = DebugInfo.empty
    @Published var showDebugOverlay = false
    @Published var analysis: PokerSceneAnalysis?
    @Published var handState: HandState?
    @Published var solverResult: SolverResult?
    @Published var advice: Advice?
    @Published var remoteDecision: PokerDisplayDecisionHUDState?
    @Published var solverAPIStatus = "Solver API unchecked"
    @Published var isAnalyzing = false

    var isStreaming: Bool { streamingStatus != .stopped }

    private let coordinator: VideoSourceCoordinator
    private let wearables: WearablesInterface
    private let displayViewModel: PokerDisplayViewModel
    private let tableFusion = TableStateFusion()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var metaDeviceAvailable = false
    private var deviceStreamTask: Task<Void, Never>?
    private var autoAnalysisTask: Task<Void, Never>?
    private var latestDeviceIds: [DeviceIdentifier] = []
    private var pendingAnalysisPhotoContinuation: CheckedContinuation<UIImage?, Never>?
    private var discardNextAnalysisPhoto = false

    init(wearables: WearablesInterface) {
        DecisionHoldemAPIClient.bootstrapFromEnvironment()
        solverAPIStatus = DecisionHoldemAPIClient.isConfigured ? "Solver API ready" : "Solver API key missing"
        self.wearables = wearables
        self.coordinator = VideoSourceCoordinator(wearables: wearables)
        self.displayViewModel = PokerDisplayViewModel(wearables: wearables)
        displayViewModel.configureAnalyzeHandler { [weak self] in
            await self?.analyzeLiveFrame()
        }
        setupCallbacks()
        monitorDevices()
    }

    deinit {
        deviceStreamTask?.cancel()
        autoAnalysisTask?.cancel()
    }

    func handleStartStreaming() async {
        streamingStatus = .waiting
        currentVideoFrame = nil
        hasReceivedFirstFrame = false
        analysis = nil
        resetTrainerState()

        guard hasConnectedDATDevice() else {
            streamingStatus = .stopped
            showErrorMessage("DAT sees the glasses, but none are connected yet. Open Meta AI, connect the Meta Ray-Ban Display, keep the glasses awake, then try again.")
            refreshDebugInfo()
            return
        }

        guard await requestMetaPermissionIfNeeded() else {
            streamingStatus = .stopped
            refreshDebugInfo()
            return
        }

        await coordinator.startMetaGlassesStream()
        refreshDebugInfo()

        if coordinator.isStreaming {
            startAutoAnalysis()
            displayViewModel.useSharedDeviceSession(coordinator.activeMetaDeviceSession)
            await displayViewModel.showIdle()
        } else {
            streamingStatus = .stopped
            let reason = coordinator.lastStartError.map { ": \($0)" } ?? "."
            showErrorMessage("Could not start the Meta glasses camera stream\(reason)")
            await displayViewModel.showUnavailable("Meta glasses camera unavailable.")
        }
    }

    func stopSession() async {
        stopAutoAnalysis()
        coordinator.stop()
        streamingStatus = .stopped
        currentVideoFrame = nil
        hasReceivedFirstFrame = false
        analysis = nil
        resetTrainerState()
        await displayViewModel.detach()
        refreshDebugInfo()
    }

    func loadSampleFrame() {
        guard let image = Self.loadBundledSampleImage() else {
            showErrorMessage("Could not load the bundled poker sample frame")
            return
        }
        currentVideoFrame = image
        hasReceivedFirstFrame = true
        analysis = nil
        resetTrainerState()
    }

    func analyzeBundledSample() async {
        if currentVideoFrame == nil {
            loadSampleFrame()
        }
        await analyzeCurrentFrame(source: .bundledSample)
    }

    func analyzeSampleIfNeeded() async {
        if currentVideoFrame == nil {
            loadSampleFrame()
        }
        guard analysis == nil else { return }
        await analyzeCurrentFrame(source: .bundledSample)
    }

    func analyzeLiveFrame() async {
        if let stillFrame = await captureStillFrameForAnalysis() {
            await analyzeFrame(stillFrame, source: .liveFrame, speakResult: true)
            return
        }
        await analyzeCurrentFrame(source: .liveFrame, speakResult: true)
    }

    func capturePhoto() {
        coordinator.capturePhoto()
    }

    func dismissPhotoPreview() {
        showPhotoPreview = false
        capturedPhoto = nil
    }

    func dismissError() {
        showError = false
        errorMessage = ""
    }

    func toggleDebugOverlay() {
        showDebugOverlay.toggle()
    }

    private func setupCallbacks() {
        coordinator.onFrame = { [weak self] pb, ts, orient in
            self?.handleFrame(pb, timestamp: ts, orientation: orient)
        }

        coordinator.onStreamStateChange = { [weak self] state in
            Task { @MainActor in self?.handleStreamState(state) }
        }

        coordinator.onStreamError = { [weak self] error in
            Task { @MainActor in self?.handleStreamError(error) }
        }

        coordinator.onPhotoCapture = { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                if let img = UIImage(data: data) {
                    if let continuation = self.pendingAnalysisPhotoContinuation {
                        self.pendingAnalysisPhotoContinuation = nil
                        self.discardNextAnalysisPhoto = false
                        continuation.resume(returning: img)
                        return
                    }
                    if self.discardNextAnalysisPhoto {
                        self.discardNextAnalysisPhoto = false
                        return
                    }
                    self.capturedPhoto = img
                    self.showPhotoPreview = true
                }
            }
        }
    }

    private func analyzeCurrentFrame(source: PokerAnalysisSource, speakResult: Bool = true) async {
        guard let frame = currentVideoFrame else {
            showErrorMessage("No frame available to analyze yet")
            await displayViewModel.showUnavailable("No frame available yet.")
            return
        }
        await analyzeFrame(frame, source: source, speakResult: speakResult)
    }

    private func analyzeFrame(_ frame: UIImage, source: PokerAnalysisSource, speakResult: Bool) async {
        guard let cgImage = frame.normalizedCGImage() else {
            showErrorMessage("Could not prepare the frame for analysis")
            await displayViewModel.showUnavailable("Could not prepare this frame.")
            return
        }

        isAnalyzing = true
        await displayViewModel.showAnalyzing()
        defer { isAnalyzing = false }

        let result = await Task.detached(priority: .userInitiated) {
            PokerSceneAnalyzer().analyze(cgImage: cgImage, source: source)
        }.value
        analysis = result
        await updateTrainerState(from: result)
        if let remoteDecision {
            await displayViewModel.showDecision(remoteDecision)
        } else {
            await displayViewModel.showAnalysis(result)
        }
        if speakResult {
            speak(result.spokenSummary)
        }
    }

    private func captureStillFrameForAnalysis(timeoutNanoseconds: UInt64 = 900_000_000) async -> UIImage? {
        guard coordinator.isStreaming, pendingAnalysisPhotoContinuation == nil else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            pendingAnalysisPhotoContinuation = continuation
            discardNextAnalysisPhoto = false
            coordinator.capturePhoto()

            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                guard let self, let pending = self.pendingAnalysisPhotoContinuation else { return }
                self.pendingAnalysisPhotoContinuation = nil
                self.discardNextAnalysisPhoto = true
                pending.resume(returning: nil)
            }
        }
    }

    private func handleFrame(
        _ pixelBuffer: CVPixelBuffer,
        timestamp: CMTime,
        orientation: CGImagePropertyOrientation?
    ) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let oriented = orientation.map { ciImage.oriented($0) } ?? ciImage

        if let cg = ciContext.createCGImage(oriented, from: oriented.extent) {
            let ui = UIImage(cgImage: cg)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentVideoFrame = ui
                if !self.hasReceivedFirstFrame { self.hasReceivedFirstFrame = true }
            }
        }
    }

    private func handleStreamState(_ state: StreamState) {
        switch state {
        case .streaming:
            streamingStatus = .streaming
            startAutoAnalysis()
        case .stopped:
            stopAutoAnalysis()
            currentVideoFrame = nil
            analysis = nil
            resetTrainerState()
            streamingStatus = .stopped
        case .waitingForDevice, .starting, .stopping, .paused:
            streamingStatus = .waiting
        }
        refreshDebugInfo()
    }

    private func handleStreamError(_ error: StreamError) {
        let msg: String
        switch error {
        case .deviceNotFound(_): msg = "Device not found"
        case .deviceNotConnected(_): msg = "Device disconnected"
        case .permissionDenied: msg = "Camera permission denied"
        case .timeout: msg = "Connection timed out"
        case .videoStreamingError: msg = "Streaming error"
        case .hingesClosed: msg = "Glasses hinges closed"
        case .thermalCritical: msg = "Device overheating"
        case .thermalEmergency: msg = "Device thermal emergency"
        case .peakPowerShutdown: msg = "Glasses shut down from peak power"
        case .batteryCritical: msg = "Glasses battery critical"
        case .internalError: msg = "Internal error"
        @unknown default: msg = "Unknown stream error"
        }
        if msg != errorMessage { showErrorMessage(msg) }
    }

    private func requestMetaPermissionIfNeeded() async -> Bool {
        do {
            let status = try await wearables.checkPermissionStatus(.camera)
            if status == .granted { return true }
            let requestStatus = try await wearables.requestPermission(.camera)
            if requestStatus != .granted {
                showErrorMessage("Camera permission denied in Meta AI")
                return false
            }
            return true
        } catch {
            showErrorMessage("Camera permission request failed: \(describePermissionError(error))")
            return false
        }
    }

    private func describePermissionError(_ error: PermissionError) -> String {
        switch error {
        case .noDevice:
            return "No DAT device visible"
        case .noDeviceWithConnection:
            return "No connected DAT device"
        case .connectionError:
            return "Glasses connection error"
        case .metaAINotInstalled:
            return "Meta AI app not installed"
        case .requestInProgress:
            return "Another permission request is already open"
        case .requestTimeout:
            return "Permission request timed out"
        case .internalError:
            return "Internal DAT permission error"
        @unknown default:
            return error.description
        }
    }

    private func monitorDevices() {
        deviceStreamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await devices in self.wearables.devicesStream() {
                self.latestDeviceIds = devices
                self.metaDeviceAvailable = !devices.isEmpty
                self.hasActiveDevice = !devices.isEmpty
                self.refreshDebugInfo()
            }
        }
    }

    private func showErrorMessage(_ message: String) {
        errorMessage = message
        showError = true
    }

    private func refreshDebugInfo() {
        debugInfo = DebugInfo(activeSource: coordinator.activeSourceName)
    }

    private func hasConnectedDATDevice() -> Bool {
        let ids = latestDeviceIds.isEmpty ? wearables.devices : latestDeviceIds
        return ids.contains { id in
            guard let device = wearables.deviceForIdentifier(id) else { return false }
            return device.linkState == .connected
        }
    }

    private func startAutoAnalysis() {
        guard autoAnalysisTask == nil else { return }
        autoAnalysisTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled else { break }
                await self?.analyzeCurrentStreamingFrameIfPossible()
            }
        }
    }

    private func stopAutoAnalysis() {
        autoAnalysisTask?.cancel()
        autoAnalysisTask = nil
    }

    private func analyzeCurrentStreamingFrameIfPossible() async {
        guard streamingStatus == .streaming, currentVideoFrame != nil, !isAnalyzing else {
            return
        }
        await analyzeCurrentFrame(source: .liveFrame, speakResult: false)
    }

    private func resetTrainerState() {
        tableFusion.reset()
        handState = nil
        solverResult = nil
        advice = nil
        remoteDecision = nil
    }

    private func updateTrainerState(from analysis: PokerSceneAnalysis) async {
        let observation = TableObservation(analysis: analysis)
        let state = tableFusion.ingest(observation)
        handState = state
        remoteDecision = nil

        let trainerOutput = await Task.detached(priority: .userInitiated) {
            PokerTrainerEngine.evaluate(handState: state)
        }.value
        solverResult = trainerOutput.0
        advice = trainerOutput.1

        guard state.heroCards.count == 2 else {
            solverAPIStatus = "Need hero cards"
            return
        }
        guard [0, 3, 4, 5].contains(state.boardCards.count) else {
            solverAPIStatus = "Need valid board"
            return
        }
        guard DecisionHoldemAPIClient.isConfigured else {
            solverAPIStatus = "Solver API key missing"
            return
        }

        solverAPIStatus = "Solving remotely"
        do {
            let remoteResult = try await DecisionHoldemAPIClient.solve(state: state)
            remoteDecision = remoteResult.displayState
            advice = remoteResult.advice
            solverAPIStatus = "\(remoteResult.solver) \(remoteResult.latencyMS)ms"
        } catch {
            solverAPIStatus = "Solver API error"
            showErrorMessage("Solver API error: \(error.localizedDescription)")
        }
    }

    private func speak(_ text: String) {
        speechSynthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        speechSynthesizer.speak(utterance)
    }

    private static func loadBundledSampleImage() -> UIImage? {
        guard let url = Bundle.main.url(forResource: "plant", withExtension: "png") else {
            return nil
        }
        return UIImage(contentsOfFile: url.path)
    }
}

private protocol CardDetectionEngine {
    var name: String { get }
    func detectCards(in cgImage: CGImage, analyzer: PokerSceneAnalyzer) -> [PokerDetection]
}

private final class CompositeCardDetectionEngine: CardDetectionEngine {
    private let coreMLDetector: CoreMLCardDetector?
    private let heuristicDetector = PhysicalCardHeuristicDetector()

    var name: String {
        if let coreMLDetector {
            return "\(coreMLDetector.name) + \(heuristicDetector.name)"
        }
        return heuristicDetector.name
    }

    init(coreMLDetector: CoreMLCardDetector? = CoreMLCardDetector()) {
        self.coreMLDetector = coreMLDetector
    }

    func detectCards(in cgImage: CGImage, analyzer: PokerSceneAnalyzer) -> [PokerDetection] {
        var detections: [PokerDetection] = []
        if let coreMLDetector {
            detections.append(contentsOf: coreMLDetector.detectCards(in: cgImage, analyzer: analyzer))
        }
        detections.append(contentsOf: heuristicDetector.detectCards(in: cgImage, analyzer: analyzer))
        return analyzer.mergeOverlappingDetections(detections)
    }
}

private final class CoreMLCardDetector: CardDetectionEngine {
    let name = "CoreML card detector"
    private let model: VNCoreMLModel

    init?(resourceName: String = "PokerCardDetector") {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "mlmodelc"),
              let mlModel = try? MLModel(contentsOf: url),
              let visionModel = try? VNCoreMLModel(for: mlModel) else {
            return nil
        }
        self.model = visionModel
    }

    func detectCards(in cgImage: CGImage, analyzer: PokerSceneAnalyzer) -> [PokerDetection] {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        let observations = request.results?.compactMap { $0 as? VNRecognizedObjectObservation } ?? []
        let detections = observations.compactMap { observation -> PokerDetection? in
            guard let label = observation.labels.first else { return nil }
            let confidence = Double(label.confidence)
            guard confidence >= 0.30 else { return nil }

            let box = analyzer.topLeftRect(fromVisionRect: observation.boundingBox)
            guard analyzer.isUsefulCardBox(box) else { return nil }

            let category = analyzer.category(forCardBox: box)
            let parsedCard = PokerCardLabelParser.parse(label.identifier)
            return PokerDetection(
                category: category,
                label: parsedCard?.display ?? (category == .heroCard ? "Card" : "Board card"),
                confidence: min(0.99, confidence),
                confidenceSpread: parsedCard == nil ? 0.10 : 0.04,
                normalizedBoundingBox: box
            )
        }

        return analyzer.mergeOverlappingDetections(detections)
    }
}

private struct PhysicalCardHeuristicDetector: CardDetectionEngine {
    let name = "physical-card heuristics"

    func detectCards(in cgImage: CGImage, analyzer: PokerSceneAnalyzer) -> [PokerDetection] {
        analyzer.mergeOverlappingDetections(
            analyzer.detectCardCandidates(in: cgImage) + analyzer.detectBrightCardRegions(in: cgImage)
        )
    }
}

private final class PokerSceneAnalyzer {
    private let cardDetector: any CardDetectionEngine

    init(cardDetector: any CardDetectionEngine = CompositeCardDetectionEngine()) {
        self.cardDetector = cardDetector
    }

    func analyze(cgImage: CGImage, source: PokerAnalysisSource) -> PokerSceneAnalysis {
        let textItems = recognizeText(in: cgImage)
        let recognizedText = textItems.map(\.text)
        let textDetections = textItems.compactMap(makeUsefulTextDetection)

        if source == .bundledSample {
            return bundledSampleAnalysis(recognizedText: recognizedText, textDetections: textDetections)
        }

        let cardDetections = cardDetector.detectCards(in: cgImage, analyzer: self)
        let classifiedCards = classifyCards(from: cardDetections, textItems: textItems, cgImage: cgImage)
        let detections = mergeOverlappingDetections(classifiedCards.detections + textDetections)
        let players = parsePlayers(from: recognizedText)

        return PokerSceneAnalysis(
            source: source,
            heroCards: classifiedCards.heroCards,
            boardCards: classifiedCards.boardCards,
            pot: parsePot(from: recognizedText),
            heroStack: parseHeroStack(from: recognizedText),
            visibleActions: parseActions(from: recognizedText),
            players: players,
            handDescription: nil,
            tableCounts: tableCounts(
                heroCards: classifiedCards.heroCards,
                boardCards: classifiedCards.boardCards,
                detections: detections,
                players: players
            ),
            detections: detections,
            recognizedText: recognizedText,
            notes: [
                detections.isEmpty
                    ? "No confident card, pot, stack, or action boxes found in this frame."
                    : "Useful detections are boxed. Unknown cards are counted but not named until rank and suit are confident.",
                "Card detector: \(cardDetector.name).",
                "Training readout only. Live action recommendations are intentionally disabled."
            ],
            analyzedAt: Date()
        )
    }

    private func bundledSampleAnalysis(
        recognizedText: [String],
        textDetections: [PokerDetection]
    ) -> PokerSceneAnalysis {
        PokerSceneAnalysis(
            source: .bundledSample,
            heroCards: [
                PlayingCard(rank: "8", suit: .clubs),
                PlayingCard(rank: "3", suit: .diamonds),
            ],
            boardCards: [
                PlayingCard(rank: "3", suit: .spades),
                PlayingCard(rank: "9", suit: .diamonds),
                PlayingCard(rank: "9", suit: .clubs),
                PlayingCard(rank: "9", suit: .hearts),
            ],
            pot: 9,
            heroStack: 960,
            visibleActions: ["Fold", "Check", "Raise"],
            players: [
                PokerPlayerState(name: "Einstein", stack: 1057, lastAction: "Fold", isDealer: false),
                PokerPlayerState(name: "Grace", stack: 1031, lastAction: "Check", isDealer: false),
                PokerPlayerState(name: "Ada", stack: 925, lastAction: nil, isDealer: true),
                PokerPlayerState(name: "Hedy", stack: 1018, lastAction: "Check", isDealer: false),
            ],
            handDescription: "Full house, nines full of threes",
            tableCounts: PokerTableCounts(playerCount: 5, heroCardCount: 2, boardCardCount: 4),
            detections: bundledSampleDetections() + textDetections.filter { $0.category == .action },
            recognizedText: recognizedText,
            notes: [
                "Bounding boxes are training-fixture detections with confidence intervals.",
                "Training readout only. Live action recommendations are intentionally disabled."
            ],
            analyzedAt: Date()
        )
    }

    private func bundledSampleDetections() -> [PokerDetection] {
        [
            PokerDetection(category: .heroCard, label: "8♣", confidence: 0.94, confidenceSpread: 0.03, normalizedBoundingBox: rect(x: 0.420, y: 0.432, w: 0.105, h: 0.180)),
            PokerDetection(category: .heroCard, label: "3♦", confidence: 0.93, confidenceSpread: 0.03, normalizedBoundingBox: rect(x: 0.480, y: 0.430, w: 0.112, h: 0.185)),

            PokerDetection(category: .boardCard, label: "3♠", confidence: 0.96, confidenceSpread: 0.02, normalizedBoundingBox: rect(x: 0.296, y: 0.262, w: 0.078, h: 0.145)),
            PokerDetection(category: .boardCard, label: "9♦", confidence: 0.97, confidenceSpread: 0.02, normalizedBoundingBox: rect(x: 0.382, y: 0.262, w: 0.078, h: 0.145)),
            PokerDetection(category: .boardCard, label: "9♣", confidence: 0.97, confidenceSpread: 0.02, normalizedBoundingBox: rect(x: 0.467, y: 0.262, w: 0.078, h: 0.145)),
            PokerDetection(category: .boardCard, label: "9♥", confidence: 0.97, confidenceSpread: 0.02, normalizedBoundingBox: rect(x: 0.551, y: 0.262, w: 0.078, h: 0.145)),

            PokerDetection(category: .pot, label: "Pot $9", confidence: 0.98, confidenceSpread: 0.01, normalizedBoundingBox: rect(x: 0.469, y: 0.318, w: 0.065, h: 0.058)),

            PokerDetection(category: .stack, label: "You $960", confidence: 0.97, confidenceSpread: 0.02, normalizedBoundingBox: rect(x: 0.446, y: 0.781, w: 0.115, h: 0.045)),
            PokerDetection(category: .stack, label: "Einstein $1,057", confidence: 0.95, confidenceSpread: 0.03, normalizedBoundingBox: rect(x: 0.151, y: 0.388, w: 0.090, h: 0.045)),
            PokerDetection(category: .stack, label: "Grace $1,031", confidence: 0.95, confidenceSpread: 0.03, normalizedBoundingBox: rect(x: 0.765, y: 0.388, w: 0.090, h: 0.045)),
            PokerDetection(category: .stack, label: "Ada $925", confidence: 0.95, confidenceSpread: 0.03, normalizedBoundingBox: rect(x: 0.185, y: 0.730, w: 0.094, h: 0.045)),
            PokerDetection(category: .stack, label: "Hedy $1,018", confidence: 0.95, confidenceSpread: 0.03, normalizedBoundingBox: rect(x: 0.730, y: 0.730, w: 0.095, h: 0.045)),
        ]
    }

    private func recognizeText(in cgImage: CGImage) -> [RecognizedTextItem] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.015

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        let observations = request.results ?? []
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return RecognizedTextItem(
                text: candidate.string,
                confidence: candidate.confidence,
                boundingBox: observation.boundingBox
            )
        }
        .sorted { lhs, rhs in
            let lhsTop = 1 - lhs.boundingBox.maxY
            let rhsTop = 1 - rhs.boundingBox.maxY
            if abs(lhsTop - rhsTop) > 0.03 { return lhsTop < rhsTop }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
    }

    fileprivate func detectCardCandidates(in cgImage: CGImage) -> [PokerDetection] {
        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = 0.30
        request.minimumAspectRatio = 0.18
        request.maximumAspectRatio = 1.18
        request.minimumSize = 0.018
        request.maximumObservations = 36
        request.quadratureTolerance = 72

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        let observations = request.results ?? []
        let candidates = observations.compactMap { observation -> PokerDetection? in
            let quad = normalizedQuadrilateral(from: observation)
            let box = boundingBox(containing: quad)
            guard isUsefulCardBox(box), looksLikePlayingCard(in: expanded(box, byX: 0.006, byY: 0.006), cgImage: cgImage) else {
                return nil
            }

            let category = category(forCardBox: box)
            let label = category == .heroCard ? "Card" : "Board card"
            let smallCardBoost = box.width < 0.055 || box.height < 0.09 ? 0.05 : 0
            let confidence = min(0.96, max(0.56, Double(observation.confidence) + smallCardBoost))
            return PokerDetection(
                category: category,
                label: label,
                confidence: confidence,
                confidenceSpread: 0.08,
                normalizedBoundingBox: box,
                normalizedQuadrilateral: quad
            )
        }

        return mergeOverlappingDetections(candidates)
    }

    fileprivate func detectBrightCardRegions(in cgImage: CGImage) -> [PokerDetection] {
        let sampleWidth = 192
        let sampleHeight = 320
        var rgba = [UInt8](repeating: 0, count: sampleWidth * sampleHeight * 4)
        guard let context = CGContext(
            data: &rgba,
            width: sampleWidth,
            height: sampleHeight,
            bitsPerComponent: 8,
            bytesPerRow: sampleWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return []
        }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))

        var mask = [Bool](repeating: false, count: sampleWidth * sampleHeight)
        for y in 0..<sampleHeight {
            let ny = CGFloat(y) / CGFloat(sampleHeight)
            guard ny > 0.16, ny < 0.90 else { continue }

            for x in 0..<sampleWidth {
                let offset = (y * sampleWidth + x) * 4
                let red = CGFloat(rgba[offset]) / 255
                let green = CGFloat(rgba[offset + 1]) / 255
                let blue = CGFloat(rgba[offset + 2]) / 255
                let brightness = (red + green + blue) / 3

                let mostlyWhite = brightness > 0.66 && abs(red - green) < 0.26 && abs(red - blue) < 0.26
                if mostlyWhite {
                    mask[y * sampleWidth + x] = true
                }
            }
        }

        var visited = [Bool](repeating: false, count: mask.count)
        var detections: [PokerDetection] = []

        for y in 0..<sampleHeight {
            for x in 0..<sampleWidth {
                let start = y * sampleWidth + x
                guard mask[start], !visited[start] else { continue }

                var queue = [start]
                var cursor = 0
                visited[start] = true
                var minX = x
                var maxX = x
                var minY = y
                var maxY = y
                var count = 0

                while cursor < queue.count {
                    let index = queue[cursor]
                    cursor += 1
                    count += 1

                    let cx = index % sampleWidth
                    let cy = index / sampleWidth
                    minX = min(minX, cx)
                    maxX = max(maxX, cx)
                    minY = min(minY, cy)
                    maxY = max(maxY, cy)

                    let neighbors = [
                        (cx - 1, cy),
                        (cx + 1, cy),
                        (cx, cy - 1),
                        (cx, cy + 1),
                    ]

                    for (nx, ny) in neighbors where nx >= 0 && nx < sampleWidth && ny >= 0 && ny < sampleHeight {
                        let next = ny * sampleWidth + nx
                        guard mask[next], !visited[next] else { continue }
                        visited[next] = true
                        queue.append(next)
                    }
                }

                let box = CGRect(
                    x: CGFloat(minX) / CGFloat(sampleWidth),
                    y: CGFloat(minY) / CGFloat(sampleHeight),
                    width: CGFloat(maxX - minX + 1) / CGFloat(sampleWidth),
                    height: CGFloat(maxY - minY + 1) / CGFloat(sampleHeight)
                )
                detections.append(contentsOf: cardDetections(fromBrightRegion: box, pixelCount: count))
            }
        }

        return mergeOverlappingDetections(detections)
    }

    private func cardDetections(fromBrightRegion box: CGRect, pixelCount: Int) -> [PokerDetection] {
        guard pixelCount > 36, isWellFramed(box) else { return [] }
        guard box.width > 0.025, box.height > 0.045, box.width < 0.72, box.height < 0.52 else {
            return []
        }

        let aspect = box.width / max(box.height, 0.001)
        guard aspect >= 0.22, aspect <= 1.65 else { return [] }

        let category = category(forCardBox: box)
        let expandedBox = expanded(box, byX: 0.018, byY: 0.018)

        if category == .heroCard, expandedBox.width > expandedBox.height * 1.05 {
            let left = CGRect(
                x: expandedBox.minX,
                y: expandedBox.minY,
                width: expandedBox.width * 0.56,
                height: expandedBox.height
            )
            let right = CGRect(
                x: expandedBox.maxX - expandedBox.width * 0.56,
                y: expandedBox.minY,
                width: expandedBox.width * 0.56,
                height: expandedBox.height
            )
            return [
                PokerDetection(category: .heroCard, label: "Card", confidence: 0.78, confidenceSpread: 0.12, normalizedBoundingBox: left),
                PokerDetection(category: .heroCard, label: "Card", confidence: 0.78, confidenceSpread: 0.12, normalizedBoundingBox: right),
            ]
        }

        let label = category == .heroCard ? "Card" : "Board card"
        let confidence = box.width < 0.055 || box.height < 0.09 ? 0.68 : 0.72
        return [
            PokerDetection(category: category, label: label, confidence: confidence, confidenceSpread: 0.14, normalizedBoundingBox: expandedBox)
        ]
    }

    private func classifyCards(
        from detections: [PokerDetection],
        textItems: [RecognizedTextItem],
        cgImage: CGImage
    ) -> (heroCards: [PlayingCard], boardCards: [PlayingCard], detections: [PokerDetection]) {
        let mergedCards = mergeOverlappingDetections(detections)
            .filter { $0.category == .heroCard || $0.category == .boardCard }
            .sorted {
                if abs($0.normalizedBoundingBox.midY - $1.normalizedBoundingBox.midY) > 0.05 {
                    return $0.normalizedBoundingBox.midY < $1.normalizedBoundingBox.midY
                }
                return $0.normalizedBoundingBox.midX < $1.normalizedBoundingBox.midX
            }

        var heroCards: [PlayingCard] = []
        var boardCards: [PlayingCard] = []
        var outputDetections: [PokerDetection] = []

        for detection in mergedCards {
            let card = PokerCardLabelParser.parse(detection.label) ?? readCard(from: detection, textItems: textItems, cgImage: cgImage)
            let label = card?.display ?? (detection.category == .heroCard ? "Your card" : "Table card")
            let confidence = card == nil ? min(detection.confidence, 0.76) : max(detection.confidence, 0.82)

            outputDetections.append(
                PokerDetection(
                    category: detection.category,
                    label: label,
                    confidence: confidence,
                    confidenceSpread: card == nil ? 0.14 : 0.08,
                    normalizedBoundingBox: detection.normalizedBoundingBox,
                    normalizedQuadrilateral: detection.normalizedQuadrilateral
                )
            )

            guard let card else { continue }
            if detection.category == .heroCard, heroCards.count < 2, !heroCards.contains(card) {
                heroCards.append(card)
            } else if detection.category == .boardCard, boardCards.count < 5, !boardCards.contains(card) {
                boardCards.append(card)
            }
        }

        return (heroCards, boardCards, outputDetections)
    }

    private func readCard(
        from detection: PokerDetection,
        textItems: [RecognizedTextItem],
        cgImage: CGImage
    ) -> PlayingCard? {
        let cardBox = detection.normalizedBoundingBox
        let cornerText = textItems
            .filter { cardBox.intersects(topLeftRect(fromVisionRect: $0.boundingBox)) }
            .sorted { lhs, rhs in
                let lhsBox = topLeftRect(fromVisionRect: lhs.boundingBox)
                let rhsBox = topLeftRect(fromVisionRect: rhs.boundingBox)
                if abs(lhsBox.minY - rhsBox.minY) > 0.025 { return lhsBox.minY < rhsBox.minY }
                return lhsBox.minX < rhsBox.minX
            }
            .map(\.text)
            .joined(separator: " ")

        if let card = card(fromText: cornerText, cardBox: cardBox, cgImage: cgImage) {
            return card
        }

        guard let cardImage = rectifiedCardImage(from: detection, cgImage: cgImage)
            ?? croppedCardImage(in: expanded(cardBox, byX: 0.025, byY: 0.025), cgImage: cgImage) else {
            return nil
        }
        let cropText = recognizeText(in: cardImage).map(\.text).joined(separator: " ")
        return card(fromText: cropText, cardBox: cardBox, cgImage: cgImage)
    }

    private func card(fromText text: String, cardBox: CGRect, cgImage: CGImage) -> PlayingCard? {
        guard let rank = parseCardRank(from: text) else { return nil }
        guard let suit = parseCardSuit(from: text) ?? inferCardSuitColor(in: cardBox, cgImage: cgImage) else {
            return nil
        }
        return PlayingCard(rank: rank, suit: suit)
    }

    private func rectifiedCardImage(from detection: PokerDetection, cgImage: CGImage) -> CGImage? {
        guard let quad = detection.normalizedQuadrilateral, quad.count == 4 else {
            return nil
        }

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let ciImage = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else {
            return nil
        }

        func ciPoint(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x * width, y: (1 - point.y) * height)
        }

        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: ciPoint(quad[0])), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: ciPoint(quad[1])), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: ciPoint(quad[2])), forKey: "inputBottomRight")
        filter.setValue(CIVector(cgPoint: ciPoint(quad[3])), forKey: "inputBottomLeft")

        guard let output = filter.outputImage else { return nil }
        let extent = output.extent.integral
        guard extent.width >= 12, extent.height >= 18 else { return nil }
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(output, from: extent)
    }

    private func croppedCardImage(in normalizedBox: CGRect, cgImage: CGImage) -> CGImage? {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let pixelRect = CGRect(
            x: normalizedBox.minX * width,
            y: normalizedBox.minY * height,
            width: normalizedBox.width * width,
            height: normalizedBox.height * height
        ).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))

        guard pixelRect.width >= 12, pixelRect.height >= 18 else { return nil }
        return cgImage.cropping(to: pixelRect)
    }

    private func parseCardRank(from text: String) -> String? {
        let normalized = text
            .uppercased()
            .replacingOccurrences(of: "10", with: "T")
            .replacingOccurrences(of: "O", with: "Q")

        let rankPattern = #"(^|[^A-Z0-9])(A|K|Q|J|T|[2-9])([^A-Z0-9]|$)"#
        guard let regex = try? NSRegularExpression(pattern: rankPattern) else { return nil }
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        guard let match = regex.firstMatch(in: normalized, range: range),
              let rankRange = Range(match.range(at: 2), in: normalized) else {
            return nil
        }

        let rank = String(normalized[rankRange])
        return rank == "T" ? "10" : rank
    }

    private func parseCardSuit(from text: String) -> PlayingCardSuit? {
        let lowercased = text.lowercased()
        if lowercased.contains("♣") || lowercased.contains("club") { return .clubs }
        if lowercased.contains("♦") || lowercased.contains("diamond") { return .diamonds }
        if lowercased.contains("♥") || lowercased.contains("heart") { return .hearts }
        if lowercased.contains("♠") || lowercased.contains("spade") { return .spades }
        return nil
    }

    private func inferCardSuitColor(in cardBox: CGRect, cgImage: CGImage) -> PlayingCardSuit? {
        let corner = CGRect(
            x: cardBox.minX,
            y: cardBox.minY,
            width: cardBox.width * 0.46,
            height: cardBox.height * 0.44
        )
        guard let sample = averageRGBA(in: corner, cgImage: cgImage) else { return nil }

        let isRed = sample.red > sample.green * 1.22 && sample.red > sample.blue * 1.22 && sample.red > 0.36
        let isDark = sample.red < 0.45 && sample.green < 0.45 && sample.blue < 0.45

        if isRed { return .hearts }
        if isDark { return .spades }
        return nil
    }

    private func tableCounts(
        heroCards: [PlayingCard],
        boardCards: [PlayingCard],
        detections: [PokerDetection],
        players: [PokerPlayerState]
    ) -> PokerTableCounts {
        let heroCardCount = max(
            heroCards.count,
            detections.filter { $0.category == .heroCard }.count
        )
        let boardCardCount = max(
            boardCards.count,
            detections.filter { $0.category == .boardCard }.count
        )
        let visibleOpponentCount = players.count
        let playerCount = visibleOpponentCount == 0 ? nil : visibleOpponentCount + 1

        return PokerTableCounts(
            playerCount: playerCount,
            heroCardCount: min(heroCardCount, 2),
            boardCardCount: min(boardCardCount, 5)
        )
    }

    private func makeUsefulTextDetection(from item: RecognizedTextItem) -> PokerDetection? {
        guard item.confidence >= 0.68 else { return nil }

        let visionRect = item.boundingBox
        let topLeftRect = topLeftRect(fromVisionRect: visionRect)
        guard isWellFramed(topLeftRect), topLeftRect.width > 0.012, topLeftRect.height > 0.010 else {
            return nil
        }

        if item.text.contains("$"), let amount = moneyAmounts(in: [item.text]).first {
            let category: PokerDetectionCategory = amount > 0 && amount < 200 ? .pot : .stack
            let expanded = expanded(topLeftRect, byX: category == .pot ? 0.025 : 0.035, byY: 0.014)
            return PokerDetection(
                category: category,
                label: category == .pot ? "Pot $\(amount)" : "$\(amount)",
                confidence: Double(item.confidence),
                confidenceSpread: 0.05,
                normalizedBoundingBox: expanded
            )
        }

        guard let action = normalizedAction(from: item.text), item.confidence >= 0.82 else {
            return nil
        }

        let expanded = expanded(topLeftRect, byX: 0.018, byY: 0.010)
        return PokerDetection(
            category: .action,
            label: action,
            confidence: Double(item.confidence),
            confidenceSpread: 0.05,
            normalizedBoundingBox: expanded
        )
    }

    private func rect(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    fileprivate func topLeftRect(fromVisionRect visionRect: CGRect) -> CGRect {
        CGRect(
            x: visionRect.minX,
            y: 1 - visionRect.maxY,
            width: visionRect.width,
            height: visionRect.height
        )
    }

    fileprivate func normalizedQuadrilateral(from observation: VNRectangleObservation) -> [CGPoint] {
        [
            topLeftPoint(fromVisionPoint: observation.topLeft),
            topLeftPoint(fromVisionPoint: observation.topRight),
            topLeftPoint(fromVisionPoint: observation.bottomRight),
            topLeftPoint(fromVisionPoint: observation.bottomLeft),
        ]
    }

    private func topLeftPoint(fromVisionPoint point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: 1 - point.y)
    }

    fileprivate func boundingBox(containing points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        let minX = points.reduce(first.x) { min($0, $1.x) }
        let maxX = points.reduce(first.x) { max($0, $1.x) }
        let minY = points.reduce(first.y) { min($0, $1.y) }
        let maxY = points.reduce(first.y) { max($0, $1.y) }
        return CGRect(
            x: max(0, minX),
            y: max(0, minY),
            width: min(1, maxX) - max(0, minX),
            height: min(1, maxY) - max(0, minY)
        )
    }

    fileprivate func category(forCardBox box: CGRect) -> PokerDetectionCategory {
        box.midY > 0.50 ? .heroCard : .boardCard
    }

    fileprivate func isUsefulCardBox(_ box: CGRect) -> Bool {
        guard isWellFramed(box) else { return false }
        guard box.width >= 0.018, box.height >= 0.035, box.width <= 0.32, box.height <= 0.44 else {
            return false
        }

        let aspect = box.width / max(box.height, 0.001)
        guard aspect >= 0.22, aspect <= 1.25 else { return false }

        // Ignore tiny browser/header cards and table chrome near the very top.
        return box.midY > 0.16
    }

    private func isWellFramed(_ box: CGRect) -> Bool {
        box.minX >= 0.018
            && box.maxX <= 0.982
            && box.minY >= 0.018
            && box.maxY <= 0.940
    }

    private func looksLikePlayingCard(in normalizedBox: CGRect, cgImage: CGImage) -> Bool {
        let sampleBox = CGRect(
            x: normalizedBox.minX + normalizedBox.width * 0.10,
            y: normalizedBox.minY + normalizedBox.height * 0.10,
            width: normalizedBox.width * 0.80,
            height: normalizedBox.height * 0.80
        )
        guard let sample = averageRGBA(in: sampleBox, cgImage: cgImage) ?? averageRGBA(in: normalizedBox, cgImage: cgImage) else {
            return false
        }

        let maxChannel = max(sample.red, sample.green, sample.blue)
        let minChannel = min(sample.red, sample.green, sample.blue)
        let brightness = (sample.red + sample.green + sample.blue) / 3
        let redInk = sample.red > 0.55 && sample.green < 0.45 && sample.blue < 0.45
        let whiteCard = brightness > 0.52 && (maxChannel - minChannel) < 0.52

        return whiteCard || redInk
    }

    private func averageRGBA(in normalizedBox: CGRect, cgImage: CGImage) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)? {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let pixelRect = CGRect(
            x: normalizedBox.minX * width,
            y: normalizedBox.minY * height,
            width: normalizedBox.width * width,
            height: normalizedBox.height * height
        ).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))

        guard pixelRect.width >= 2, pixelRect.height >= 2, let crop = cgImage.cropping(to: pixelRect) else {
            return nil
        }

        var rgba = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &rgba,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .medium
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (
            red: CGFloat(rgba[0]) / 255,
            green: CGFloat(rgba[1]) / 255,
            blue: CGFloat(rgba[2]) / 255,
            alpha: CGFloat(rgba[3]) / 255
        )
    }

    private func expanded(_ box: CGRect, byX x: CGFloat, byY y: CGFloat) -> CGRect {
        CGRect(
            x: max(0, box.minX - x),
            y: max(0, box.minY - y),
            width: min(1, box.maxX + x) - max(0, box.minX - x),
            height: min(1, box.maxY + y) - max(0, box.minY - y)
        )
    }

    private func normalizedAction(from text: String) -> String? {
        ["Fold", "Check", "Call", "Bet", "Raise"].first {
            text.localizedCaseInsensitiveContains($0)
        }
    }

    fileprivate func mergeOverlappingDetections(_ detections: [PokerDetection]) -> [PokerDetection] {
        let ordered = detections.sorted { lhs, rhs in
            if lhs.category != rhs.category { return lhs.category.rawValue < rhs.category.rawValue }
            if abs(lhs.normalizedBoundingBox.midY - rhs.normalizedBoundingBox.midY) > 0.025 {
                return lhs.normalizedBoundingBox.midY < rhs.normalizedBoundingBox.midY
            }
            if abs(lhs.normalizedBoundingBox.midX - rhs.normalizedBoundingBox.midX) > 0.025 {
                return lhs.normalizedBoundingBox.midX < rhs.normalizedBoundingBox.midX
            }
            return lhs.confidence > rhs.confidence
        }

        return ordered.reduce(into: [PokerDetection]()) { result, detection in
            if let existingIndex = result.firstIndex(where: { existing in
                existing.category == detection.category
                    && intersectionOverUnion(existing.normalizedBoundingBox, detection.normalizedBoundingBox) > 0.42
            }) {
                if detection.confidence > result[existingIndex].confidence {
                    result[existingIndex] = detection
                }
                return
            }
            result.append(detection)
        }
    }

    private func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = lhs.width * lhs.height + rhs.width * rhs.height - intersectionArea
        return unionArea <= 0 ? 0 : intersectionArea / unionArea
    }

    private func parsePot(from text: [String]) -> Int? {
        let amounts = moneyAmounts(in: text)
        if let smallPot = amounts.first(where: { $0 > 0 && $0 < 200 }) {
            return smallPot
        }
        return amounts.first
    }

    private func parseHeroStack(from text: [String]) -> Int? {
        guard let youIndex = text.firstIndex(where: { $0.localizedCaseInsensitiveContains("you") }) else {
            return nil
        }
        let lower = max(text.startIndex, youIndex - 3)
        let upper = min(text.endIndex, youIndex + 3)
        return moneyAmounts(in: Array(text[lower..<upper])).first
    }

    private func parseActions(from text: [String]) -> [String] {
        let known = ["Fold", "Check", "Call", "Bet", "Raise"]
        var actions: [String] = []
        for item in text {
            for action in known where item.localizedCaseInsensitiveContains(action) {
                if !actions.contains(action) {
                    actions.append(action)
                }
            }
        }
        return actions
    }

    private func parsePlayers(from text: [String]) -> [PokerPlayerState] {
        let names = ["Einstein", "Grace", "Ada", "Hedy"]
        return names.compactMap { name in
            guard text.contains(where: { $0.localizedCaseInsensitiveContains(name) }) else {
                return nil
            }
            return PokerPlayerState(name: name, stack: nil, lastAction: nil, isDealer: false)
        }
    }

    private func moneyAmounts(in text: [String]) -> [Int] {
        let pattern = #"\$?\s*([0-9][0-9,]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        return text.flatMap { value -> [Int] in
            let nsRange = NSRange(value.startIndex..<value.endIndex, in: value)
            return regex.matches(in: value, range: nsRange).compactMap { match in
                guard let range = Range(match.range(at: 1), in: value) else { return nil }
                let digits = value[range].replacingOccurrences(of: ",", with: "")
                return Int(digits)
            }
        }
    }
}

private extension UIImage {
    func normalizedCGImage() -> CGImage? {
        if imageOrientation == .up, let cgImage {
            return cgImage
        }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let rendered = renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.cgImage
    }
}
