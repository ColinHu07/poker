/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// DisplayViewModel.swift
//
// Manages the display session lifecycle: attaching to a display-capable device,
// sending views, and detaching. Uses DSPN's pending action pattern so that
// tapping "play" auto-attaches and sends the view once the display is ready.
//

import MWDATCamera
import MWDATCore
import MWDATDisplay
import Observation
import SwiftUI
import Foundation
import UIKit

struct GeminiPokerDecision: Equatable {
  let action: String
  let heroCards: [String]
  let boardCards: [String]
  let confidence: Double
  let reason: String
  let rawText: String
}

private struct CapturedPokerPhoto {
  let data: Data
  let image: UIImage
  let cgImage: CGImage
}

private enum GeminiVisionClient {
  private static let apiKeyEnvironmentKey = "GEMINI_API_KEY"
  private static let modelEnvironmentKey = "GEMINI_MODEL"
  private static let defaultModel = "gemini-3.5-flash"
  private static let maxOutputTokens = 65_536

  static var isConfigured: Bool {
    apiKey != nil
  }

  static func analyzeCards(imageData: Data) async throws -> GeminiPokerDecision {
    guard let apiKey else {
      throw NSError(
        domain: "GeminiConfiguration",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Set the GEMINI_API_KEY environment variable to enable image analysis."]
      )
    }

    let model = clean(ProcessInfo.processInfo.environment[modelEnvironmentKey]) ?? defaultModel
    let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(GeminiGenerateContentRequest(
      contents: [
        .init(parts: [
          .init(text: prompt),
          .init(inlineData: .init(mimeType: "image/jpeg", data: imageData.base64EncodedString())),
        ])
      ],
      generationConfig: .init(
        temperature: 0,
        responseMimeType: "text/plain",
        maxOutputTokens: maxOutputTokens
      )
    ))

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
      let message = String(data: data, encoding: .utf8) ?? "Unknown image analysis error"
      throw NSError(
        domain: "Gemini",
        code: (response as? HTTPURLResponse)?.statusCode ?? 1,
        userInfo: [NSLocalizedDescriptionKey: message]
      )
    }

    let decoded = try JSONDecoder().decode(GeminiGenerateContentResponse.self, from: data)
    let text = decoded.candidates.first?.content.parts.compactMap(\.text).joined(separator: "\n") ?? ""
    guard !text.isEmpty else {
      throw NSError(domain: "Gemini", code: 2, userInfo: [NSLocalizedDescriptionKey: "Image analysis returned no decision."])
    }

    return parseDecision(from: text)
  }

  private static var apiKey: String? {
    clean(ProcessInfo.processInfo.environment[apiKeyEnvironmentKey])
  }

  private static func clean(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }

  private static let prompt = """
  You are a Texas Hold'em poker assistant using one first-person camera photo.
  Read the visible cards and recommend the best immediate action.

  Card-reading rules:
  - Identify the user's two hole cards first. These are usually closest to the camera or separated from the shared board.
  - Identify shared community cards left to right as the board.
  - Read both the rank character and the suit symbol on each card. Use the corner index and repeated pips/symbols together.
  - Rank symbols are A K Q J T/10 9 8 7 6 5 4 3 2.
  - Suit symbols are spades ♠/s, hearts ♥/h, diamonds ♦/d, clubs ♣/c.
  - Hearts and diamonds are usually red; spades and clubs are usually black. Do not use color alone because lighting can distort it.
  - Do not guess a card if the rank or suit symbol is unreadable. If important cards are unreadable, recommend TAKE IMAGE AGAIN.
  - Be careful not to confuse 6/9, 5/S, T/10, Q/O, clubs/spades, or hearts/diamonds.

  Poker-decision rules:
  - Output a direct action such as CHECK/FOLD, CHECK/CALL, CALL, BET 1/3 POT, BET 1/2 POT, RAISE 2.5BB, RAISE 3BB, RAISE POT, or TAKE IMAGE AGAIN.
  - If no bet is visible, prefer CHECK, BET 1/3 POT, BET 1/2 POT, or RAISE 3BB.
  - If facing action is unclear, use CHECK/CALL or CHECK/FOLD.
  - Use conservative sizing when the betting context, stack size, or pot size is not visible.

  Return plain text only, no JSON, no Markdown, exactly these lines:
  ACTION: <best action>
  HAND: <two cards or unknown>
  BOARD: <community cards or none/unknown>
  CONFIDENCE: <0-100>
  WHY: <one short reason>
  """

  private static func parseDecision(from text: String) -> GeminiPokerDecision {
    let action = lineValue("ACTION", in: text) ?? text
      .split(whereSeparator: \.isNewline)
      .first
      .map(String.init) ?? "Review image"
    let handText = lineValue("HAND", in: text) ?? ""
    let boardText = lineValue("BOARD", in: text) ?? ""
    let confidenceText = lineValue("CONFIDENCE", in: text) ?? ""
    let reason = lineValue("WHY", in: text) ?? "Calculated from the captured image."
    let confidence = min(1, max(0, (Double(confidenceText.filter { $0.isNumber || $0 == "." }) ?? 0) / 100))

    return GeminiPokerDecision(
      action: action.trimmingCharacters(in: .whitespacesAndNewlines),
      heroCards: Array(cards(in: handText).prefix(2)),
      boardCards: Array(cards(in: boardText).prefix(5)),
      confidence: confidence,
      reason: reason.trimmingCharacters(in: .whitespacesAndNewlines),
      rawText: text.trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }

  private static func lineValue(_ key: String, in text: String) -> String? {
    let prefix = "\(key):"
    return text
      .split(whereSeparator: \.isNewline)
      .map(String.init)
      .first { $0.uppercased().hasPrefix(prefix) }?
      .dropFirst(prefix.count)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func cards(in text: String) -> [String] {
    let pattern = #"(?i)(10|[2-9TJQKA])\s*([cdhs♣♦♥♠])"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.matches(in: text, range: nsRange).compactMap { match in
      let rankRange = match.range(at: 1)
      let suitRange = match.range(at: 2)
      guard
        let swiftRankRange = Range(rankRange, in: text),
        let swiftSuitRange = Range(suitRange, in: text)
      else { return nil }

      return normalizeCard(String(text[swiftRankRange]) + String(text[swiftSuitRange]))
    }
  }

  private static func normalizeCard(_ raw: String) -> String? {
    let card = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "10", with: "T")
      .replacingOccurrences(of: "♣", with: "c")
      .replacingOccurrences(of: "♦", with: "d")
      .replacingOccurrences(of: "♥", with: "h")
      .replacingOccurrences(of: "♠", with: "s")
    guard card.count == 2 else { return nil }
    let rank = String(card.prefix(1)).uppercased()
    let suit = String(card.suffix(1)).lowercased()
    guard "23456789TJQKA".contains(rank), "cdhs".contains(suit) else { return nil }
    return rank + suit
  }
}

private struct GeminiGenerateContentRequest: Encodable {
  struct Content: Encodable {
    let parts: [Part]
  }

  struct Part: Encodable {
    struct InlineData: Encodable {
      let mimeType: String
      let data: String
    }

    let text: String?
    let inlineData: InlineData?

    init(text: String) {
      self.text = text
      self.inlineData = nil
    }

    init(inlineData: InlineData) {
      self.text = nil
      self.inlineData = inlineData
    }
  }

  struct GenerationConfig: Encodable {
    let temperature: Double
    let responseMimeType: String
    let maxOutputTokens: Int
  }

  let contents: [Content]
  let generationConfig: GenerationConfig
}

private struct GeminiGenerateContentResponse: Decodable {
  struct Candidate: Decodable {
    struct Content: Decodable {
      struct Part: Decodable {
        let text: String?
      }

      let parts: [Part]
    }

    let content: Content
  }

  let candidates: [Candidate]
}

@Observable
@MainActor
class DisplayViewModel {
  var isConnected: Bool = false
  var isSending: Bool = false
  var errorMessage: String?
  var requiresDATAppUpdate: Bool = false
  var didFailToStartSession: Bool = false
  var isCameraStreaming: Bool = false
  var hasCameraFrame: Bool = false
  var cameraFrameSize: String = "--"
  var currentCameraFrame: UIImage?
  var capturedPhotoSize: String = "--"
  var geminiDecision: GeminiPokerDecision?
  var geminiRawResponse: String = ""
  var visionStatus: String = "No image captured"
  var predictionStatus: String = "Waiting"
  var isInitializingPokerVision: Bool = false
  var isCapturingImage: Bool = false
  var isRunningVision: Bool = false
  var isRunningPrediction: Bool = false
  var heroCards: [String] = []
  var boardCards: [String] = []
  var tableWarning: String?
  var displayMirrorTitle: String = "Open on display"
  var displayMirrorPrimary: String = "Waiting to send PokerVision to the glasses."
  var displayMirrorSecondary: String = "QuickTime will show this mirror plus the glasses camera preview."
  var displayMirrorAction: String = "Decision locked"
  var geminiAPIStatus: String = "Checking"
  var canGetDecision: Bool {
    geminiDecision != nil
  }
  var canRunPrediction: Bool {
    geminiDecision != nil
      && !isInitializingPokerVision
      && !isCapturingImage
      && !isRunningVision
      && !isRunningPrediction
  }

  @ObservationIgnored private let wearables: WearablesInterface
  @ObservationIgnored private var deviceSelector: AutoDeviceSelector
  @ObservationIgnored private var deviceSession: DeviceSession?
  @ObservationIgnored private var display: Display?
  @ObservationIgnored private var cameraStream: MWDATCamera.Stream?
  @ObservationIgnored private var stateListenerToken: AnyListenerToken?
  @ObservationIgnored private var cameraStateListenerToken: AnyListenerToken?
  @ObservationIgnored private var cameraFrameListenerToken: AnyListenerToken?
  @ObservationIgnored private var cameraPhotoListenerToken: AnyListenerToken?
  @ObservationIgnored private var cameraErrorListenerToken: AnyListenerToken?
  @ObservationIgnored private var coreStateTask: Task<Void, Never>?
  @ObservationIgnored private var sessionErrorTask: Task<Void, Never>?
  @ObservationIgnored private var registrationTask: Task<Void, Never>?
  @ObservationIgnored private var displayStateTask: Task<Void, Never>?
  @ObservationIgnored private var displayStateContinuation: AsyncStream<DisplayState>.Continuation?
  @ObservationIgnored private var pendingAction: (() async -> Void)?
  @ObservationIgnored private var latestCameraFrame: CGImage?
  @ObservationIgnored private var displayResultHoldUntil: Date = .distantPast
  @ObservationIgnored private var photoCaptureContinuation: CheckedContinuation<CapturedPokerPhoto, Error>?
  @ObservationIgnored private var capturedPhotoData: Data?

  init(wearables: WearablesInterface) {
    geminiAPIStatus = GeminiVisionClient.isConfigured ? "Configured" : "Missing key"
    self.wearables = wearables
    self.deviceSelector = AutoDeviceSelector(wearables: wearables, filter: { $0.supportsDisplay() })
    observeRegistration()
  }

  isolated deinit {
    stateListenerToken = nil
    coreStateTask?.cancel()
    sessionErrorTask?.cancel()
    registrationTask?.cancel()
    displayStateTask?.cancel()
  }

  // MARK: - Registration Observation

  private func observeRegistration() {
    registrationTask = Task { [weak self] in
      guard let wearables = self?.wearables else { return }
      for await state in wearables.registrationStateStream() {
        guard let self, !Task.isCancelled else { return }
        if state == .available || state == .unavailable {
          await self.resetDisplaySession()
        }
      }
    }
  }

  private func resetDisplaySession() async {
    await detachFromDisplay()
    deviceSelector = AutoDeviceSelector(wearables: wearables, filter: { $0.supportsDisplay() })
  }

  // MARK: - Public API

  /// Sends a display view to the glasses. Auto-attaches if not connected;
  /// the view is queued and sent once the display session is ready.
  func send(_ view: some DisplayableView) async {
    if let display, isConnected {
      await doSend(view, on: display)
      return
    }

    // Store as pending action — will fire once display is ready
    let sendableView = view
    pendingAction = { [weak self] in
      guard let self, let cap = self.display else { return }
      await self.doSend(sendableView, on: cap)
    }

    if display == nil {
      await attachToDisplay()
    }
  }

  private func doSend(_ view: some DisplayableView, on capability: Display) async {
    isSending = true
    defer { isSending = false }

    do {
      try await capability.send(view)
    } catch {
      let message = (error as? DisplayError)?.description ?? error.localizedDescription
      errorMessage = message
    }
  }

  // MARK: - Session Management

  func attachToDisplay() async {
    guard display == nil else { return }

    didFailToStartSession = false

    do {
      let devSession = try wearables.createSession(deviceSelector: deviceSelector)
      deviceSession = devSession

      let stateStream = devSession.stateStream()
      let errorStream = devSession.errorStream()
      coreStateTask = Task { [weak self] in
        for await sessionState in stateStream {
          guard let self, !Task.isCancelled else { return }
          switch sessionState {
          case .started:
            self.requiresDATAppUpdate = false
            self.didFailToStartSession = false
            await self.setupDisplay(on: devSession)
            await self.setupCameraStream(on: devSession)
          case .stopping, .stopped:
            self.isConnected = false
            self.display = nil
            await self.stopCameraStream()
          case .starting, .idle, .paused:
            break
          @unknown default:
            break
          }
        }
      }
      sessionErrorTask = Task { [weak self] in
        for await error in errorStream {
          guard let self, !Task.isCancelled else { return }
          self.handleSessionError(error)
        }
      }

      try devSession.start()
    } catch DeviceSessionError.datAppOnTheGlassesUpdateRequired {
      requiresDATAppUpdate = true
      didFailToStartSession = true
      errorMessage = DeviceSessionError.datAppOnTheGlassesUpdateRequired.localizedDescription
    } catch {
      requiresDATAppUpdate = false
      didFailToStartSession = true
      errorMessage = "Failed to create session: \(error.localizedDescription)"
    }
  }

  func clearSessionStartFailure() {
    didFailToStartSession = false
  }

  private func setupDisplay(on devSession: DeviceSession) async {
    guard display == nil else { return }

    do {
      let capability = try devSession.addDisplay()

      let (stateStream, continuation) = AsyncStream.makeStream(of: DisplayState.self)
      displayStateContinuation = continuation
      stateListenerToken = capability.statePublisher.listen { state in
        continuation.yield(state)
      }

      displayStateTask = Task { [weak self] in
        for await state in stateStream {
          guard let self, !Task.isCancelled else { return }
          switch state {
          case .starting:
            break
          case .started:
            self.isConnected = true
            // Execute pending action now that display is ready
            if let action = self.pendingAction {
              self.pendingAction = nil
              await action()
            }
          case .stopping:
            self.isConnected = false
          case .stopped:
            self.isConnected = false
            self.stateListenerToken = nil
            self.displayStateContinuation?.finish()
            self.displayStateContinuation = nil
            self.display = nil
            self.coreStateTask?.cancel()
            self.coreStateTask = nil
            self.deviceSession?.stop()
            self.deviceSession = nil
          }
        }
      }

      await capability.start()
      display = capability
    } catch {
      errorMessage = "Failed to start display: \(error.localizedDescription)"
    }
  }

  private func setupCameraStream(on devSession: DeviceSession) async {
    guard cameraStream == nil else { return }

    do {
      var status = try await wearables.checkPermissionStatus(.camera)
      if status != .granted {
        status = try await wearables.requestPermission(.camera)
      }
      guard status == .granted else {
        errorMessage = "Camera permission was not granted."
        return
      }

      let config = StreamConfiguration(
        videoCodec: VideoCodec.raw,
        resolution: StreamingResolution.high,
        frameRate: 24
      )
      guard let stream = try devSession.addStream(config: config) else {
        errorMessage = "Could not attach the glasses camera capability to this session."
        return
      }
      cameraStream = stream
      setupCameraListeners(for: stream)
      await stream.start()
    } catch {
      errorMessage = "Could not start glasses camera stream: \(error.localizedDescription)"
    }
  }

  private func setupCameraListeners(for stream: MWDATCamera.Stream) {
    cameraStateListenerToken = stream.statePublisher.listen { [weak self] state in
      Task { @MainActor in
        switch state {
        case .streaming:
          self?.isCameraStreaming = true
        case .stopped:
          self?.isCameraStreaming = false
        case .waitingForDevice, .starting, .stopping, .paused:
          self?.isCameraStreaming = false
        }
      }
    }

    cameraFrameListenerToken = stream.videoFramePublisher.listen { [weak self] frame in
      guard let image = frame.makeUIImage(), let cgImage = image.cgImage else { return }
      Task { @MainActor in
        self?.latestCameraFrame = cgImage
        self?.cameraFrameSize = "\(cgImage.width)x\(cgImage.height)"
        self?.hasCameraFrame = true
      }
    }

    cameraPhotoListenerToken = stream.photoDataPublisher.listen { [weak self] photoData in
      guard let image = UIImage(data: photoData.data), let cgImage = image.cgImage else { return }
      Task { @MainActor in
        self?.handleCapturedPhoto(CapturedPokerPhoto(data: photoData.data, image: image, cgImage: cgImage))
      }
    }

    cameraErrorListenerToken = stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor in
        self?.isCameraStreaming = false
        self?.errorMessage = "Glasses camera stream error: \(error.localizedDescription)"
      }
    }
  }

  private func stopCameraStream() async {
    let stream = cameraStream
    cameraStream = nil
    cameraStateListenerToken = nil
    cameraFrameListenerToken = nil
    cameraPhotoListenerToken = nil
    cameraErrorListenerToken = nil
    if let continuation = photoCaptureContinuation {
      photoCaptureContinuation = nil
      continuation.resume(
        throwing: NSError(
          domain: "PokerVisionCamera",
          code: 5,
          userInfo: [NSLocalizedDescriptionKey: "Glasses camera stream stopped before photo capture completed."]
        )
      )
    }
    latestCameraFrame = nil
    currentCameraFrame = nil
    capturedPhotoData = nil
    cameraFrameSize = "--"
    capturedPhotoSize = "--"
    visionStatus = "No image captured"
    predictionStatus = "Waiting"
    geminiDecision = nil
    geminiRawResponse = ""
    tableWarning = nil
    hasCameraFrame = false
    isCameraStreaming = false
    await stream?.stop()
  }

  private func handleCapturedPhoto(_ photo: CapturedPokerPhoto) {
    latestCameraFrame = photo.cgImage
    currentCameraFrame = photo.image
    capturedPhotoData = photo.data
    capturedPhotoSize = "\(photo.cgImage.width)x\(photo.cgImage.height)"
    cameraFrameSize = capturedPhotoSize
    hasCameraFrame = true

    if let continuation = photoCaptureContinuation {
      photoCaptureContinuation = nil
      continuation.resume(returning: photo)
    }
  }

  // MARK: - PokerVision

  func sendPokerVisionReady() async {
    updateDisplayMirror(
      title: "PokerVision ready",
      primary: "Take one still image, then run prediction.",
      secondary: "Image analysis reads cards and recommends the action.",
      action: "Take image"
    )
    await send(
      PokerVisionDisplay.ready(
        onTakeImage: { [weak self] in
          Task { @MainActor in
            await self?.takeImage()
          }
        },
        onAnalyzeTable: { [weak self] in
          Task { @MainActor in
            await self?.runPrediction()
          }
        },
        onGetDecision: { [weak self] in
          Task { @MainActor in
            await self?.runPrediction()
          }
        }
      )
    )
  }

  func initializePokerVision() async {
    guard !isInitializingPokerVision else { return }
    isInitializingPokerVision = true
    tableWarning = nil
    visionStatus = "Starting glasses camera"
    predictionStatus = geminiDecision == nil ? "Waiting" : predictionStatus

    updateDisplayMirror(
      title: "Starting PokerVision",
      primary: "Opening the glasses display and camera stream.",
      secondary: "Wait for Camera to show Streaming before taking an image.",
      action: "Starting"
    )

    await sendPokerVisionReady()

    do {
      try await waitForCameraStream()
      visionStatus = "Glasses camera ready"
      predictionStatus = geminiDecision == nil ? "Take image" : predictionStatus
      tableWarning = nil
      updateDisplayMirror(
        title: "PokerVision ready",
        primary: "Glasses camera is streaming.",
        secondary: "Take one still image, then run prediction.",
        action: "Take image"
      )
    } catch {
      visionStatus = error.localizedDescription
      tableWarning = error.localizedDescription
    }

    isInitializingPokerVision = false
  }

  func takeImage() async {
    guard !isInitializingPokerVision && !isCapturingImage && !isRunningVision else { return }
    if !isConnected || !isCameraStreaming {
      await initializePokerVision()
    }
    guard isCameraStreaming else { return }

    isCapturingImage = true
    isRunningVision = false
    tableWarning = nil
    geminiDecision = nil
    geminiRawResponse = ""
    heroCards = []
    boardCards = []
    predictionStatus = "Waiting"

    do {
      try await runCaptureCountdown()
      let photo = try await captureStillPhoto()
      isCapturingImage = false
      visionStatus = "Photo captured. Calculating."
      isRunningVision = true
      updateDisplayMirror(
        title: "Reading image",
        primary: "Calculating the best action.",
        secondary: "Photo \(photo.cgImage.width)x\(photo.cgImage.height)",
        action: "Reading"
      )

      let result = try await GeminiVisionClient.analyzeCards(imageData: photo.data)
      geminiDecision = result
      geminiRawResponse = result.rawText
      heroCards = result.heroCards
      boardCards = result.boardCards
      tableWarning = result.action.uppercased().contains("TAKE IMAGE AGAIN") ? "Take a clearer image" : nil
      visionStatus = "Analysis ready"
      predictionStatus = "Ready to run"
      await sendPokerVisionTableState(
        status: tableWarning == nil ? "Decision ready" : "Review image",
        confidence: Int((result.confidence * 100).rounded())
      )
    } catch {
      visionStatus = error.localizedDescription
      await sendPokerVisionDecisionError(error.localizedDescription)
    }

    isCapturingImage = false
    isRunningVision = false
  }

  private func runCaptureCountdown() async throws {
    for count in ["1.5", "1.0", "0.5"] {
      visionStatus = "Taking photo in \(count)s"
      updateDisplayMirror(
        title: "Taking image",
        primary: "Photo in \(count)s",
        secondary: "Keep hand and board in view.",
        action: "\(count)s"
      )
      await send(
        PokerVisionDisplay.analyzingTable(
          title: "Taking image",
          subtitle: "Keep hand and board in view.",
          status: "Photo in \(count)s"
        )
      )
      try await Task.sleep(for: .milliseconds(500))
    }

    visionStatus = "Capturing photo"
    updateDisplayMirror(
      title: "Taking image",
      primary: "Capturing a still photo from the glasses.",
      secondary: "Hold still.",
      action: "Capturing"
    )
    await send(
      PokerVisionDisplay.analyzingTable(
        title: "Taking image",
        subtitle: "Capturing a still photo.",
        status: "Hold still."
      )
    )
  }

  func runPrediction() async {
    guard !isRunningPrediction else { return }
    guard let decision = geminiDecision else {
      predictionStatus = "Take image first"
      tableWarning = "Take image first"
      await sendPokerVisionTableState(status: "Take image first", confidence: 0)
      return
    }

    isRunningPrediction = true
    predictionStatus = "Showing decision"
    heroCards = decision.heroCards
    boardCards = decision.boardCards
    tableWarning = nil
    await sendPokerVisionDecisionResult(displayResult(from: decision))
    isRunningPrediction = false
  }

  func getDecision() async {
    await runPrediction()
  }

  private func captureStillPhoto() async throws -> CapturedPokerPhoto {
    if deviceSession == nil {
      await attachToDisplay()
    }
    try await waitForCameraStream()
    return try await captureAnalysisPhoto()
  }

  private func waitForCameraStream() async throws {
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline {
      if cameraStream != nil, isCameraStreaming {
        try await Task.sleep(for: .milliseconds(400))
        return
      }
      if cameraStream == nil, let session = deviceSession, session.state == .started {
        await setupCameraStream(on: session)
      }
      try await Task.sleep(for: .milliseconds(200))
    }

    throw NSError(
      domain: "PokerVisionCamera",
      code: 7,
      userInfo: [NSLocalizedDescriptionKey: "Camera stream did not become ready. Check glasses connection and camera permission."]
    )
  }

  private func captureAnalysisPhoto() async throws -> CapturedPokerPhoto {
    if cameraStream == nil, let session = deviceSession, session.state == .started {
      await setupCameraStream(on: session)
    }

    guard let stream = cameraStream else {
      throw NSError(
        domain: "PokerVisionCamera",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "No glasses camera stream is available yet. Initialize the glasses first."]
      )
    }
    guard isCameraStreaming else {
      throw NSError(
        domain: "PokerVisionCamera",
        code: 8,
        userInfo: [NSLocalizedDescriptionKey: "Glasses camera is still starting. Wait for Camera to show Streaming, then take an image."]
      )
    }

    return try await withCheckedThrowingContinuation { continuation in
      if let previousContinuation = photoCaptureContinuation {
        previousContinuation.resume(
          throwing: NSError(
            domain: "PokerVisionCamera",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "A newer photo capture replaced the previous request."]
          )
        )
      }

      photoCaptureContinuation = continuation
      let didStartCapture = stream.capturePhoto(format: .jpeg)
      guard didStartCapture else {
        photoCaptureContinuation = nil
        continuation.resume(
          throwing: NSError(
            domain: "PokerVisionCamera",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "The glasses did not accept the photo capture request."]
          )
        )
        return
      }

      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(5000))
        guard let self, let pendingContinuation = self.photoCaptureContinuation else { return }
        self.photoCaptureContinuation = nil

        pendingContinuation.resume(
          throwing: NSError(
            domain: "PokerVisionCamera",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for the glasses photo frame."]
          )
        )
      }
    }
  }

  private func sendPokerVisionTableState(status: String, confidence: Int) async {
    guard Date() >= displayResultHoldUntil || status != "Watching board" else {
      return
    }

    updateDisplayMirror(
      title: status,
      primary: "Hand \(heroCardsDisplay)",
      secondary: tableWarning.map { "Board \(boardCardsDisplay) | \($0)" }
        ?? "Board \(boardCardsDisplay) | Confidence \(confidence)%",
      action: canGetDecision ? "Get decision" : "Decision locked"
    )

    let result = PokerVisionStateDisplayResult(
      heroCards: heroCards.isEmpty ? "--" : heroCards.joined(separator: " "),
      boardCards: boardCards.isEmpty ? "--" : boardCards.joined(separator: " "),
      status: status,
      confidence: confidence
    )

    await send(
      PokerVisionDisplay.tableState(
        result: result,
        isDecisionReady: canGetDecision,
        onTakeImage: { [weak self] in
          Task { @MainActor in
            await self?.takeImage()
          }
        },
        onGetDecision: { [weak self] in
          Task { @MainActor in
            await self?.getDecision()
          }
        }
      )
    )
  }

  private var geminiConfidencePercent: Int {
    Int(((geminiDecision?.confidence ?? 0) * 100).rounded())
  }

  private func displayResult(from decision: GeminiPokerDecision) -> PokerDecisionDisplayResult {
    let confidence = Int((decision.confidence * 100).rounded())
    let secondary = "\(decision.reason) | Confidence \(confidence)%"

    return PokerDecisionDisplayResult(
      primary: decision.action,
      secondary: secondary,
      colorHint: "neutral",
      heroCards: decision.heroCards.isEmpty ? "--" : decision.heroCards.joined(separator: " "),
      boardCards: decision.boardCards.isEmpty ? "--" : decision.boardCards.joined(separator: " ")
    )
  }

  private func sendPokerVisionDecisionResult(_ result: PokerDecisionDisplayResult) async {
    displayResultHoldUntil = Date().addingTimeInterval(30)
    updateDisplayMirror(
      title: "Best action",
      primary: result.primary,
      secondary: "Hand \(result.heroCards) | Board \(result.boardCards)",
      action: "Get decision"
    )
    await send(
      PokerVisionDisplay.decisionResult(
        result: result,
        onRetakeImage: { [weak self] in
          Task { @MainActor in
            await self?.takeImage()
          }
        },
        onAnalyzeAgain: { [weak self] in
          Task { @MainActor in
            await self?.getDecision()
          }
        }
      )
    )
  }

  private func sendPokerVisionDecisionError(_ message: String) async {
    displayResultHoldUntil = Date().addingTimeInterval(15)
    updateDisplayMirror(
      title: "Decision error",
      primary: message,
      secondary: "Check the captured state, then retry.",
      action: canGetDecision ? "Retry decision" : "Decision locked"
    )
    await send(
      PokerVisionDisplay.decisionError(
        message: message,
        onRetakeImage: { [weak self] in
          Task { @MainActor in
            await self?.takeImage()
          }
        },
        onRetry: { [weak self] in
          Task { @MainActor in
            await self?.getDecision()
          }
        }
      )
    )
  }

  func detachFromDisplay() async {
    await stopCameraStream()
    stateListenerToken = nil
    displayStateContinuation?.finish()
    displayStateContinuation = nil
    displayStateTask?.cancel()
    displayStateTask = nil
    await display?.stop()
    display = nil
    coreStateTask?.cancel()
    coreStateTask = nil
    sessionErrorTask?.cancel()
    sessionErrorTask = nil
    deviceSession?.stop()
    deviceSession = nil
    isConnected = false
  }

  private func handleSessionError(_ error: DeviceSessionError) {
    requiresDATAppUpdate = error == .datAppOnTheGlassesUpdateRequired
    didFailToStartSession = true
    errorMessage = error.localizedDescription
  }

  private var heroCardsDisplay: String {
    heroCards.isEmpty ? "--" : heroCards.joined(separator: " ")
  }

  private var boardCardsDisplay: String {
    boardCards.isEmpty ? "--" : boardCards.joined(separator: " ")
  }

  private func updateDisplayMirror(
    title: String,
    primary: String,
    secondary: String,
    action: String
  ) {
    displayMirrorTitle = title
    displayMirrorPrimary = primary
    displayMirrorSecondary = secondary
    displayMirrorAction = action
  }

  private func returnToPokerVisionControls() async {
    if !heroCards.isEmpty || !boardCards.isEmpty {
      await sendPokerVisionTableState(
        status: canGetDecision ? "Table ready" : "Need clearer table view",
        confidence: geminiConfidencePercent
      )
    } else {
      await sendPokerVisionReady()
    }
  }
}
