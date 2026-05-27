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
import Darwin
import MWDATCore
import MWDATDisplay
import Network
import Observation
import SwiftUI
import Foundation
import UIKit

private struct PokerSolveRequest: Encodable {
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

private struct PokerSolveResponse: Decodable {
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
  let display: Display

  enum CodingKeys: String, CodingKey {
    case latencyMS = "latency_ms"
    case solver
    case display
  }
}

private extension CGRect {
  func intersectionOverUnion(with other: CGRect) -> CGFloat {
    let intersection = intersection(other)
    guard !intersection.isNull else { return 0 }

    let intersectionArea = intersection.width * intersection.height
    let unionArea = width * height + other.width * other.height - intersectionArea
    guard unionArea > 0 else { return 0 }
    return intersectionArea / unionArea
  }
}

private enum PokerSolverClient {
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

  static func solve(heroCards: [String], boardCards: [String]) async throws -> PokerSolverDisplayResult {
    do {
      return try await remoteSolve(heroCards: heroCards, boardCards: boardCards)
    } catch {
      let nsError = error as NSError
      if nsError.domain == "PokerSolverConfiguration" || nsError.domain == "PokerSolverAuth" {
        throw error
      }
      return localFallbackSolve(heroCards: heroCards, boardCards: boardCards, error: error)
    }
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

  private static func remoteSolve(heroCards: [String], boardCards: [String]) async throws -> PokerSolverDisplayResult {
    guard let apiKey else {
      throw NSError(
        domain: "PokerSolverConfiguration",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Solver API key is missing. Launch with SOLVER_API_KEY."]
      )
    }

    let payload = PokerSolveRequest(
      hero: .init(position: "SB", holeCards: heroCards),
      board: boardCards,
      history: []
    )

    var request = URLRequest(url: solverURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
    request.timeoutInterval = 8
    request.httpBody = try JSONEncoder().encode(payload)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
      let message = String(data: data, encoding: .utf8) ?? "Unknown solver error"
      let domain = (response as? HTTPURLResponse).map { [401, 403].contains($0.statusCode) ? "PokerSolverAuth" : "PokerSolver" } ?? "PokerSolver"
      throw NSError(domain: domain, code: (response as? HTTPURLResponse)?.statusCode ?? 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    let decoded = try JSONDecoder().decode(PokerSolveResponse.self, from: data)
    return PokerSolverDisplayResult(
      primary: decoded.display.primary,
      secondary: decoded.display.secondary ?? "From captured hand and board.",
      colorHint: decoded.display.colorHint ?? "neutral",
      heroCards: heroCards.joined(separator: " "),
      boardCards: boardCards.joined(separator: " "),
      solver: decoded.solver,
      latencyMS: decoded.latencyMS
    )
  }

  private static func localFallbackSolve(
    heroCards: [String],
    boardCards: [String],
    error: Error
  ) -> PokerSolverDisplayResult {
    let allCards = heroCards + boardCards
    let ranks = allCards.compactMap { rankValue(for: $0) }
    let suits = allCards.compactMap { $0.last }
    let rankCounts = Dictionary(grouping: ranks, by: { $0 }).mapValues(\.count)
    let suitCounts = Dictionary(grouping: suits, by: { $0 }).mapValues(\.count)
    let heroRanks = heroCards.compactMap { rankValue(for: $0) }
    let boardRanks = Set(boardCards.compactMap { rankValue(for: $0) })

    let pairs = rankCounts.values.filter { $0 == 2 }.count
    let trips = rankCounts.values.filter { $0 == 3 }.count
    let quads = rankCounts.values.contains(4)
    let hasFlush = suitCounts.values.contains { $0 >= 5 }
    let hasFlushDraw = suitCounts.values.contains { $0 == 4 }
    let heroPair = heroRanks.count == 2 && heroRanks[0] == heroRanks[1]
    let heroTouchesBoard = heroRanks.contains { boardRanks.contains($0) }

    let primary: String
    let strength: String
    if quads || hasFlush || trips >= 1 && pairs >= 1 {
      primary = "Raise 1/2 pot"
      strength = "very strong made hand"
    } else if trips >= 1 || pairs >= 2 {
      primary = "Raise small"
      strength = "strong made hand"
    } else if heroPair || heroTouchesBoard {
      primary = "Call"
      strength = "pair or board connection"
    } else if hasFlushDraw {
      primary = "Call"
      strength = "draw equity"
    } else {
      primary = "Check"
      strength = "low confirmed equity"
    }

    return PokerSolverDisplayResult(
      primary: primary,
      secondary: "Local fallback: \(strength). Remote solver unavailable.",
      colorHint: "neutral",
      heroCards: heroCards.joined(separator: " "),
      boardCards: boardCards.joined(separator: " "),
      solver: "local-fallback",
      latencyMS: 0
    )
  }

  private static func rankValue(for card: String) -> Int? {
    guard let rank = card.first else { return nil }
    switch rank {
    case "2": return 2
    case "3": return 3
    case "4": return 4
    case "5": return 5
    case "6": return 6
    case "7": return 7
    case "8": return 8
    case "9": return 9
    case "T", "t": return 10
    case "J", "j": return 11
    case "Q", "q": return 12
    case "K", "k": return 13
    case "A", "a": return 14
    default: return nil
    }
  }
}

private struct StableCardGroup {
  let apiLabel: String
  let label: String
  let detections: [DetectedPlayingCard]
  let supportCount: Int
  let peakConfidence: Float
  let stabilizedConfidence: Float
  let boundingBox: CGRect
  let center: CGPoint
  let isUsableForState: Bool

  var fusionScore: Double {
    (Double(supportCount) * 4.0)
      + (Double(stabilizedConfidence) * 2.0)
      + Double(peakConfidence)
  }
}

private struct DemoPokerSpot {
  let street: String
  let heroCards: [String]
  let boardCards: [String]
  let primaryAction: String
  let secondaryAction: String
  let tableStatus: String
}

private enum PokerVisionDemoScript {
  static let players = [
    "Hero Ac Jc",
    "Villain Ks Qs",
    "Villain 8h 8d",
    "Villain Qh Jh"
  ]

  static let spots: [DemoPokerSpot] = [
    DemoPokerSpot(
      street: "Flop",
      heroCards: ["Ac", "Jc"],
      boardCards: ["3c", "4d", "5c"],
      primaryAction: "Call",
      secondaryAction: "Call is best: we have the nut flush draw, two overcards, and enough equity to continue against a small bet.",
      tableStatus: "Flop captured"
    ),
    DemoPokerSpot(
      street: "Turn",
      heroCards: ["Ac", "Jc"],
      boardCards: ["3c", "4d", "5c", "9c"],
      primaryAction: "Raise",
      secondaryAction: "Raise is best: the turn completes our ace-high flush, so we can build the pot for value.",
      tableStatus: "Turn captured"
    ),
    DemoPokerSpot(
      street: "River",
      heroCards: ["Ac", "Jc"],
      boardCards: ["3c", "4d", "5c", "9c", "5h"],
      primaryAction: "Jam all in",
      secondaryAction: "Jam is best: our ace-high flush is strong enough to value shove even when the board pairs.",
      tableStatus: "River captured"
    )
  ]
}

private struct StableCardRow {
  let groups: [StableCardGroup]

  var averageY: CGFloat {
    groups.map(\.center.y).reduce(0, +) / CGFloat(max(groups.count, 1))
  }
}

private final class DisplayFrameServer {
  private let queue = DispatchQueue(label: "PokerVision.DisplayFrameServer")
  private let lock = NSLock()
  private var latestJPEG: Data?
  private var listener: NWListener?
  private var baseURL: URL?

  func updateFrame(_ data: Data) throws -> URL {
    let baseURL = try startIfNeeded()
    lock.lock()
    latestJPEG = data
    lock.unlock()
    return baseURL
  }

  func stop() {
    listener?.cancel()
    listener = nil
    baseURL = nil
    lock.lock()
    latestJPEG = nil
    lock.unlock()
  }

  private func startIfNeeded() throws -> URL {
    if let baseURL {
      return baseURL
    }

    let port = NWEndpoint.Port(rawValue: 8877)!
    let listener = try NWListener(using: .tcp, on: port)
    listener.newConnectionHandler = { [weak self] connection in
      self?.handle(connection)
    }
    listener.start(queue: queue)
    self.listener = listener

    // The display renderer runs through the companion stack on the phone. A LAN
    // address can be blocked or unreachable from that renderer, so serve the
    // live JPEG frame through localhost first.
    let url = URL(string: "http://127.0.0.1:\(port.rawValue)/camera.jpg")!
    baseURL = url
    return url
  }

  private func handle(_ connection: NWConnection) {
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, _, _ in
      self?.sendLatestFrame(on: connection)
    }
  }

  private func sendLatestFrame(on connection: NWConnection) {
    lock.lock()
    let frame = latestJPEG
    lock.unlock()

    let body = frame ?? Data()
    let statusLine = frame == nil
      ? "HTTP/1.1 503 Service Unavailable\r\n"
      : "HTTP/1.1 200 OK\r\n"
    let headers = statusLine
      + "Content-Type: image/jpeg\r\n"
      + "Content-Length: \(body.count)\r\n"
      + "Access-Control-Allow-Origin: *\r\n"
      + "Cache-Control: no-store, no-cache, must-revalidate, max-age=0\r\n"
      + "Pragma: no-cache\r\n"
      + "Connection: close\r\n\r\n"

    var response = Data(headers.utf8)
    response.append(body)
    connection.send(content: response, completion: .contentProcessed { _ in
      connection.cancel()
    })
  }

  private static func localIPv4Address() -> String? {
    var address: String?
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
      return nil
    }
    defer { freeifaddrs(interfaces) }

    var interface = firstInterface
    while true {
      let current = interface.pointee
      let name = String(cString: current.ifa_name)
      let family = current.ifa_addr.pointee.sa_family
      if name == "en0", family == UInt8(AF_INET) {
        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(
          current.ifa_addr,
          socklen_t(current.ifa_addr.pointee.sa_len),
          &hostname,
          socklen_t(hostname.count),
          nil,
          0,
          NI_NUMERICHOST
        )
        address = String(cString: hostname)
        break
      }

      guard let next = current.ifa_next else { break }
      interface = next
    }

    return address
  }
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
  var isStreamingCameraToDisplay: Bool = false
  var hasCameraFrame: Bool = false
  var currentCameraFrame: UIImage?
  var latestDetections: [DetectedPlayingCard] = []
  var latestTableCandidates: [TableCardCandidate] = []
  var detectionStatus: String = "Waiting"
  var heroCards: [String] = []
  var boardCards: [String] = []
  var tableWarning: String?
  var hasUnidentifiedVisibleCards: Bool = false
  var isScanningTable: Bool = false
  var isRecordingTable: Bool = false
  var recordingSampleCount: Int = 0
  var isDemoMode: Bool = false
  var demoStatus: String = "Off"
  var displayMirrorTitle: String = "Open on display"
  var displayMirrorPrimary: String = "Waiting to send PokerVision to the glasses."
  var displayMirrorSecondary: String = "QuickTime will show this mirror plus the glasses camera preview."
  var displayMirrorAction: String = "Analyze table"
  var solverAPIStatus: String = "Checking"
  var canGetDecision: Bool {
    heroCards.count == 2 && [3, 4, 5].contains(boardCards.count) && !hasUnidentifiedVisibleCards
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
  @ObservationIgnored private let displayFrameServer = DisplayFrameServer()
  @ObservationIgnored private var displayCameraStreamTask: Task<Void, Never>?
  @ObservationIgnored private var coreStateTask: Task<Void, Never>?
  @ObservationIgnored private var sessionErrorTask: Task<Void, Never>?
  @ObservationIgnored private var registrationTask: Task<Void, Never>?
  @ObservationIgnored private var displayStateTask: Task<Void, Never>?
  @ObservationIgnored private var displayStateContinuation: AsyncStream<DisplayState>.Continuation?
  @ObservationIgnored private var pendingAction: (() async -> Void)?
  @ObservationIgnored private var latestCameraFrame: CGImage?
  @ObservationIgnored private var isDetectingFrame: Bool = false
  @ObservationIgnored private var lastDetectionTime: Date = .distantPast
  @ObservationIgnored private var displayResultHoldUntil: Date = .distantPast
  @ObservationIgnored private var photoCaptureContinuation: CheckedContinuation<CGImage, Error>?
  @ObservationIgnored private var tableRecordingTask: Task<Void, Never>?
  @ObservationIgnored private var recordedTableSamples: [[DetectedPlayingCard]] = []
  @ObservationIgnored private var lastRecordedDetectionSignature: String?
  @ObservationIgnored private var displayFrameSequence: Int = 0
  @ObservationIgnored private var demoSpotIndex: Int = 0
  @ObservationIgnored private var currentDemoSpot: DemoPokerSpot?

  init(wearables: WearablesInterface) {
    PokerSolverClient.bootstrapFromEnvironment()
    solverAPIStatus = PokerSolverClient.isConfigured ? "Configured" : "Missing key"
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
        self?.currentCameraFrame = image
        self?.hasCameraFrame = true
        self?.schedulePreviewDetection(on: cgImage)
      }
    }

    cameraPhotoListenerToken = stream.photoDataPublisher.listen { [weak self] photoData in
      guard let image = UIImage(data: photoData.data), let cgImage = image.cgImage else { return }
      Task { @MainActor in
        self?.handleCapturedPhoto(cgImage, image: image)
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
    latestDetections = []
    latestTableCandidates = []
    detectionStatus = "Waiting"
    tableWarning = nil
    isScanningTable = false
    stopTableRecordingLocally()
    hasCameraFrame = false
    isCameraStreaming = false
    await stream?.stop()
  }

  private func handleCapturedPhoto(_ cgImage: CGImage, image: UIImage) {
    latestCameraFrame = cgImage
    currentCameraFrame = image
    hasCameraFrame = true

    if let continuation = photoCaptureContinuation {
      photoCaptureContinuation = nil
      continuation.resume(returning: cgImage)
    }
  }

  private func schedulePreviewDetection(on frame: CGImage) {
    let now = Date()
    guard !isDetectingFrame, now.timeIntervalSince(lastDetectionTime) > 1.0 else {
      return
    }

    isDetectingFrame = true
    lastDetectionTime = now
    detectionStatus = "Detecting..."

    Task { [weak self] in
      do {
        let detections = try await CardDetectionService.shared.detectCards(in: frame)
        await MainActor.run {
          self?.updateScanPreview(with: detections, prefix: "Live")
          self?.isDetectingFrame = false
        }
      } catch {
        await MainActor.run {
          self?.latestDetections = []
          self?.detectionStatus = error.localizedDescription
          self?.isDetectingFrame = false
        }
      }
    }
  }

  // MARK: - PokerVision

  func sendPokerVisionReady() async {
    updateDisplayMirror(
      title: "PokerVision ready",
      primary: "Analyze table captures your hand and board together.",
      secondary: "Decision unlocks after 2 hand cards plus 3-5 board cards.",
      action: "Analyze table"
    )
    await send(
      PokerVisionDisplay.ready(
        onScanHand: { [weak self] in
          Task { @MainActor in
            await self?.analyzeHeroHand()
          }
        },
        onStartRecording: { [weak self] in
          Task { @MainActor in
            await self?.startTableRecording()
          }
        },
        onStartCameraStream: { [weak self] in
          Task { @MainActor in
            await self?.startCameraStreamOnDisplay()
          }
        },
        onInitializeDemo: { [weak self] in
          Task { @MainActor in
            await self?.initializeDemoPlay()
          }
        },
        onAnalyzeTable: { [weak self] in
          Task { @MainActor in
            await self?.analyzeTable()
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

  func sendPokerVisionRecording() async {
    updateDisplayMirror(
      title: isRecordingTable ? "Recording table" : "Frame the table",
      primary: isRecordingTable ? "Move slowly across hand and board." : "Look at your hand and the board together.",
      secondary: isRecordingTable ? "\(recordingSampleCount) frame samples collected." : "Tap Start recording for video fusion, or Analyze table for a quick burst.",
      action: isRecordingTable ? "End recording" : "Start recording"
    )
    await send(
      PokerVisionDisplay.recording(
        isRecording: isRecordingTable,
        sampleCount: recordingSampleCount,
        onScanHand: { [weak self] in
          Task { @MainActor in
            await self?.analyzeHeroHand()
          }
        },
        onStartRecording: { [weak self] in
          Task { @MainActor in
            await self?.startTableRecording()
          }
        },
        onStopRecording: { [weak self] in
          Task { @MainActor in
            await self?.stopTableRecording()
          }
        },
        onStartCameraStream: { [weak self] in
          Task { @MainActor in
            await self?.startCameraStreamOnDisplay()
          }
        },
        onInitializeDemo: { [weak self] in
          Task { @MainActor in
            await self?.initializeDemoPlay()
          }
        },
        onAnalyzeTable: { [weak self] in
          Task { @MainActor in
            await self?.analyzeTable()
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

  func showCameraPreviewOnDisplay() async {
    if cameraStream == nil, let session = deviceSession, session.state == .started {
      await setupCameraStream(on: session)
    }

    let frameURI = makeDisplayCameraFrameURI()
    let status = frameURI == nil
      ? "Waiting for a glasses camera frame."
      : "Latest glasses camera frame."

    updateDisplayMirror(
      title: "Camera view",
      primary: status,
      secondary: "The phone keeps the actual live stream and detection boxes.",
      action: "Refresh"
    )

    await send(
      PokerVisionDisplay.cameraPreview(
        frameURI: frameURI,
        status: status,
        onRefresh: { [weak self] in
          Task { @MainActor in
            await self?.showCameraPreviewOnDisplay()
          }
        },
        onAnalyzeTable: { [weak self] in
          Task { @MainActor in
            await self?.analyzeTable()
          }
        },
        onBack: { [weak self] in
          Task { @MainActor in
            await self?.returnToPokerVisionControls()
          }
        }
      )
    )
  }

  func startCameraStreamOnDisplay() async {
    guard !isStreamingCameraToDisplay else { return }

    if cameraStream == nil, let session = deviceSession, session.state == .started {
      await setupCameraStream(on: session)
    }

    isStreamingCameraToDisplay = true
    updateDisplayMirror(
      title: "Camera stream",
      primary: "Sending glasses camera frames to the glasses display.",
      secondary: "This is for aiming the glasses; stop it before analyzing.",
      action: "Stop stream"
    )

    await send(
      PokerVisionDisplay.cameraStream(
        frameURI: nil,
        status: "Starting camera stream",
        onStop: { [weak self] in
          Task { @MainActor in
            await self?.stopCameraStreamOnDisplay()
          }
        }
      )
    )

    displayCameraStreamTask = Task { @MainActor [weak self] in
      while let self, self.isStreamingCameraToDisplay, !Task.isCancelled {
        await self.sendCameraStreamFrameToDisplay()
        try? await Task.sleep(for: .milliseconds(650))
        guard self.isStreamingCameraToDisplay, !Task.isCancelled else { break }
      }
    }
  }

  func stopCameraStreamOnDisplay() async {
    stopDisplayCameraStreamLocally()
    await returnToPokerVisionControls()
  }

  private func sendCameraStreamFrameToDisplay() async {
    guard isStreamingCameraToDisplay else { return }

    let frameURI = makeDisplayCameraFrameURI()
    let status = frameURI == nil ? "Waiting for frame" : "Glasses camera"

    await send(
      PokerVisionDisplay.cameraStream(
        frameURI: frameURI,
        status: status,
        onStop: { [weak self] in
          Task { @MainActor in
            await self?.stopCameraStreamOnDisplay()
          }
        }
      )
    )
  }

  func initializeDemoPlay() async {
    stopDisplayCameraStreamLocally()
    stopTableRecordingLocally()
    displayResultHoldUntil = .distantPast
    isDemoMode = true
    demoSpotIndex = 0
    currentDemoSpot = nil
    demoStatus = "Ready"
    heroCards = []
    boardCards = []
    tableWarning = nil
    hasUnidentifiedVisibleCards = false
    latestDetections = []
    latestTableCandidates = []
    detectionStatus = "Ready"

    updateDisplayMirror(
      title: "Play initialized",
      primary: "Players loaded: \(PokerVisionDemoScript.players.joined(separator: " | "))",
      secondary: "Tap Scan Play to run table analysis.",
      action: "Scan Play"
    )

    await send(
      PokerVisionDisplay.tableState(
        result: PokerVisionStateDisplayResult(
          heroCards: "--",
          boardCards: "--",
          status: "Play initialized",
          confidence: 100
        ),
        isDecisionReady: false,
        onScanHand: { [weak self] in
          Task { @MainActor in
            await self?.runDemoInference()
          }
        },
        onStartRecording: { [weak self] in
          Task { @MainActor in
            await self?.runDemoInference()
          }
        },
        onInitializeDemo: { [weak self] in
          Task { @MainActor in
            await self?.initializeDemoPlay()
          }
        },
        onAnalyzeTable: { [weak self] in
          Task { @MainActor in
            await self?.runDemoInference()
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

  func analyzeTable() async {
    if isDemoMode {
      await runDemoInference()
      return
    }

    stopDisplayCameraStreamLocally()
    stopTableRecordingLocally()
    displayResultHoldUntil = .distantPast
    isScanningTable = true
    tableWarning = nil
    updateDisplayMirror(
      title: "Scanning table",
      primary: "Reading several glasses frames.",
      secondary: "Separating your hand from the board.",
      action: "Scanning"
    )
    await send(PokerVisionDisplay.analyzingTable())

    defer { isScanningTable = false }
    do {
      let samples = try await collectTableScanFrames()
      let state = buildTableCardState(from: samples)
      applyTableCardState(state)
      let status = state.isDecisionReady ? "Table ready" : "Need clearer table view"
      await sendPokerVisionTableState(status: status, confidence: state.confidence)
    } catch {
      await sendPokerVisionSolverError(error.localizedDescription)
    }
  }

  func analyzeHeroHand() async {
    if isDemoMode {
      await runDemoInference()
      return
    }

    stopDisplayCameraStreamLocally()
    stopTableRecordingLocally()
    displayResultHoldUntil = .distantPast
    isScanningTable = true
    tableWarning = nil
    updateDisplayMirror(
      title: "Scanning hand",
      primary: "Reading your two cards from the glasses camera.",
      secondary: "Board state will be kept if already captured.",
      action: "Scanning"
    )
    await send(PokerVisionDisplay.analyzingTable(title: "Scanning hand", subtitle: "Reading your two cards from the glasses camera."))

    defer { isScanningTable = false }
    do {
      let samples = try await collectHandScanFrames()
      let state = buildHeroHandState(from: samples)
      applyTableCardState(state)
      let status = state.heroCards.count == 2 ? "Hand ready" : "Need clearer hero cards"
      await sendPokerVisionTableState(status: status, confidence: state.confidence)
    } catch {
      await sendPokerVisionSolverError(error.localizedDescription)
    }
  }

  func toggleBoardWatcher() async {
    await analyzeTable()
  }

  func startTableRecording() async {
    if isDemoMode {
      await runDemoInference()
      return
    }

    stopDisplayCameraStreamLocally()
    guard !isRecordingTable else {
      await sendPokerVisionRecording()
      return
    }

    displayResultHoldUntil = .distantPast
    recordedTableSamples = []
    recordingSampleCount = 0
    lastRecordedDetectionSignature = nil
    isRecordingTable = true
    isScanningTable = false
    tableWarning = nil

    updateDisplayMirror(
      title: "Recording table",
      primary: "Keep the glasses moving slowly across hand and board.",
      secondary: "Tap End recording when the table has been covered.",
      action: "End recording"
    )
    await sendPokerVisionRecording()

    tableRecordingTask = Task { [weak self] in
      await self?.recordTableFrames()
    }
  }

  func stopTableRecording() async {
    guard isRecordingTable else {
      return
    }

    let samples = recordedTableSamples
    stopTableRecordingLocally()

    guard !samples.isEmpty else {
      await sendPokerVisionEmptyAnalysis()
      return
    }

    let state = buildTableCardState(from: samples)
    applyTableCardState(state)
    let status = state.isDecisionReady ? "Table ready" : "Need clearer table view"
    await sendPokerVisionTableState(status: status, confidence: state.confidence)
  }

  func getDecision() async {
    stopDisplayCameraStreamLocally()
    if isDemoMode {
      await sendCurrentDemoDecision()
      return
    }

    guard canGetDecision else {
      updateDisplayMirror(
        title: "Need table state",
        primary: "Need 2 hand cards and 3, 4, or 5 board cards.",
        secondary: "Hand \(heroCardsDisplay) | Board \(boardCardsDisplay)",
        action: "Analyze table"
      )
      await sendPokerVisionTableState(
        status: "Need table state",
        confidence: averageConfidence(latestDetections)
      )
      return
    }

    isScanningTable = false
    displayResultHoldUntil = Date().addingTimeInterval(20)

    updateDisplayMirror(
      title: "Solving spot",
      primary: "Hand \(heroCardsDisplay)",
      secondary: "Board \(boardCardsDisplay)",
      action: "Solving"
    )
    await send(
      PokerVisionDisplay.analyzingDecision(
        heroCards: heroCards.joined(separator: " "),
        boardCards: boardCards.joined(separator: " ")
      )
    )

    do {
      let result = try await PokerSolverClient.solve(heroCards: heroCards, boardCards: boardCards)
      await sendPokerVisionSolverResult(result)
    } catch {
      await sendPokerVisionSolverError(error.localizedDescription)
    }
  }

  private func runDemoInference() async {
    stopDisplayCameraStreamLocally()
    stopTableRecordingLocally()
    displayResultHoldUntil = .distantPast
    isScanningTable = true
    isRecordingTable = false
    demoStatus = "Analyzing"
    tableWarning = nil

    updateDisplayMirror(
      title: "Analyzing table",
      primary: "Reading hand, board, and action context...",
      secondary: "Calculating the best available move.",
      action: "Loading"
    )
    await send(PokerVisionDisplay.analyzingTable(title: "Analyzing table", subtitle: "Reading hand, board, and action context..."))

    try? await Task.sleep(nanoseconds: 3_000_000_000)
    guard !Task.isCancelled else {
      isScanningTable = false
      return
    }

    let spot = PokerVisionDemoScript.spots[min(demoSpotIndex, PokerVisionDemoScript.spots.count - 1)]
    currentDemoSpot = spot
    demoSpotIndex = min(demoSpotIndex + 1, PokerVisionDemoScript.spots.count - 1)
    heroCards = spot.heroCards
    boardCards = spot.boardCards
    hasUnidentifiedVisibleCards = false
    latestDetections = []
    latestTableCandidates = []
    detectionStatus = spot.street
    demoStatus = spot.street
    isScanningTable = false

    await sendCurrentDemoDecision()
  }

  private func sendCurrentDemoDecision() async {
    guard isDemoMode else { return }

    guard let spot = currentDemoSpot else {
      updateDisplayMirror(
        title: "Play ready",
        primary: "Tap Scan Play to analyze the table.",
        secondary: "Waiting for table analysis.",
        action: "Scan Play"
      )
      await sendPokerVisionTableState(status: "Play ready", confidence: 100)
      return
    }

    displayResultHoldUntil = Date().addingTimeInterval(30)
    let result = PokerSolverDisplayResult(
      primary: spot.primaryAction,
      secondary: spot.secondaryAction,
      colorHint: "neutral",
      heroCards: spot.heroCards.joined(separator: " "),
      boardCards: spot.boardCards.joined(separator: " "),
      solver: "on-device",
      latencyMS: 3000
    )

    updateDisplayMirror(
      title: "\(spot.street): \(spot.primaryAction)",
      primary: spot.secondaryAction,
      secondary: "Hero \(result.heroCards) | Board \(result.boardCards)",
      action: "Analyze next"
    )

    await send(
      PokerVisionDisplay.solverResult(
        result: result,
        onStartRecording: { [weak self] in
          Task { @MainActor in
            await self?.runDemoInference()
          }
        },
        onAnalyzeAgain: { [weak self] in
          Task { @MainActor in
            await self?.runDemoInference()
          }
        }
      )
    )
  }

  func analyzePokerVisionCards() async {
    await analyzeTable()
  }

  private func detectCardsInLatestGlassesFrame(
    minimumConfidence: Float = CardDetectionService.debugConfidenceFloor
  ) async throws -> [DetectedPlayingCard] {
    if cameraStream == nil, let session = deviceSession, session.state == .started {
      await setupCameraStream(on: session)
    }

    guard let frame = latestCameraFrame else {
      throw NSError(
        domain: "PokerVisionCamera",
        code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: "No glasses camera frame is available yet. Start PokerVision on the display, wait a second, then try Analyze again."
        ]
      )
    }

    return try await CardDetectionService.shared.detectCards(in: frame, minimumConfidence: minimumConfidence)
  }

  private func detectCardsInFreshAnalysisFrame(
    minimumConfidence: Float = CardDetectionService.debugConfidenceFloor
  ) async throws -> [DetectedPlayingCard] {
    let frame = try await captureAnalysisFrame()
    return try await CardDetectionService.shared.detectCards(in: frame, minimumConfidence: minimumConfidence)
  }

  private func captureAnalysisFrame() async throws -> CGImage {
    if cameraStream == nil, let session = deviceSession, session.state == .started {
      await setupCameraStream(on: session)
    }

    guard let stream = cameraStream else {
      if let frame = latestCameraFrame {
        return frame
      }
      throw NSError(
        domain: "PokerVisionCamera",
        code: 2,
        userInfo: [
          NSLocalizedDescriptionKey: "No glasses camera stream is available yet. Open PokerVision on the display first."
        ]
      )
    }

    return try await withCheckedThrowingContinuation { continuation in
      if let previousContinuation = photoCaptureContinuation {
        previousContinuation.resume(
          throwing: NSError(
            domain: "PokerVisionCamera",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "A newer table scan replaced the previous photo capture."]
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
        try? await Task.sleep(for: .milliseconds(1800))
        guard let self, let pendingContinuation = self.photoCaptureContinuation else { return }
        self.photoCaptureContinuation = nil

        if let fallbackFrame = self.latestCameraFrame {
          pendingContinuation.resume(returning: fallbackFrame)
        } else {
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
  }

  private func collectTableScanFrames() async throws -> [[DetectedPlayingCard]] {
    var samples: [[DetectedPlayingCard]] = []

    if let stillDetections = try? await detectCardsInFreshAnalysisFrame(
      minimumConfidence: CardDetectionService.debugConfidenceFloor
    ) {
      let deduped = dedupeFrameDetections(stillDetections)
      samples.append(deduped)
      updateScanPreview(with: deduped, prefix: "Still")
    }

    for index in 0..<12 {
      let detections = dedupeFrameDetections(try await detectCardsInLatestGlassesFrame(
        minimumConfidence: CardDetectionService.debugConfidenceFloor
      ))
      samples.append(detections)
      updateScanPreview(with: detections, prefix: "Scanning")

      if index < 11 {
        try await Task.sleep(for: .milliseconds(160))
      }
    }
    return samples
  }

  private func collectHandScanFrames() async throws -> [[DetectedPlayingCard]] {
    var samples: [[DetectedPlayingCard]] = []

    if let stillDetections = try? await detectCardsInFreshAnalysisFrame(
      minimumConfidence: CardDetectionService.debugConfidenceFloor
    ) {
      let deduped = dedupeFrameDetections(stillDetections)
      samples.append(deduped)
      updateScanPreview(with: deduped, prefix: "Hand still")
    }

    for index in 0..<8 {
      let detections = dedupeFrameDetections(try await detectCardsInLatestGlassesFrame(
        minimumConfidence: CardDetectionService.debugConfidenceFloor
      ))
      samples.append(detections)
      updateScanPreview(with: detections, prefix: "Hand scan")

      if index < 7 {
        try await Task.sleep(for: .milliseconds(140))
      }
    }

    return samples
  }

  private func recordTableFrames() async {
    while !Task.isCancelled {
      let detections = dedupeFrameDetections(latestDetections)
      if !detections.isEmpty {
        recordedTableSamples.append(detections)
        if recordedTableSamples.count > 60 {
          recordedTableSamples.removeFirst(recordedTableSamples.count - 60)
        }
        recordingSampleCount = recordedTableSamples.count
        updateScanPreview(with: detections, prefix: "Recording")
        updateRecordingMirror()
        lastRecordedDetectionSignature = detectionSignature(detections)
      } else if let frame = latestCameraFrame {
        detectionStatus = "Recording: detecting..."
        if let freshDetections = try? await CardDetectionService.shared.detectCards(
          in: frame,
          minimumConfidence: CardDetectionService.debugConfidenceFloor
        ) {
          let deduped = dedupeFrameDetections(freshDetections)
          if !deduped.isEmpty {
            recordedTableSamples.append(deduped)
            if recordedTableSamples.count > 60 {
              recordedTableSamples.removeFirst(recordedTableSamples.count - 60)
            }
            recordingSampleCount = recordedTableSamples.count
            updateScanPreview(with: deduped, prefix: "Recording")
            updateRecordingMirror()
            lastRecordedDetectionSignature = detectionSignature(deduped)
          } else {
            detectionStatus = "Recording 0 cards"
          }
        }
      } else {
        detectionStatus = "Recording: waiting for camera"
      }

      try? await Task.sleep(for: .milliseconds(280))
    }
  }

  private func stopTableRecordingLocally() {
    tableRecordingTask?.cancel()
    tableRecordingTask = nil
    isRecordingTable = false
  }

  private func updateRecordingMirror() {
    updateDisplayMirror(
      title: "Recording table",
      primary: "Move slowly across hand and board.",
      secondary: "\(recordingSampleCount) frame samples collected.",
      action: "End recording"
    )
  }

  private func detectionSignature(_ detections: [DetectedPlayingCard]) -> String {
    detections
      .map { "\($0.apiLabel):\(Int($0.boundingBox.midX * 100)):\(Int($0.boundingBox.midY * 100))" }
      .sorted()
      .joined(separator: "|")
  }

  private func updateScanPreview(with detections: [DetectedPlayingCard], prefix: String) {
    let state = buildTableCardState(from: [detections])
    latestDetections = state.candidates.map(\.detection)
    latestTableCandidates = state.candidates
    detectionStatus = state.visibleCardCount == 0
      ? "\(prefix) 0 cards"
      : "\(prefix) \(state.visibleCardCount) cards"
  }

  private func dedupeFrameDetections(_ detections: [DetectedPlayingCard]) -> [DetectedPlayingCard] {
    let cardDetections = dedupePhysicalCardDetections(detections.filter(\.hasRankAndSuit))
    let bestCardsByLabel = Dictionary(grouping: cardDetections, by: \.apiLabel)
      .values
      .compactMap { group in
        group.max { $0.confidence < $1.confidence }
      }

    let debugDetections = detections
      .filter { !$0.hasRankAndSuit }
      .filter { debugDetection in
        !bestCardsByLabel.contains { isSamePhysicalCard(debugDetection.boundingBox, $0.boundingBox) }
      }
    return (bestCardsByLabel + debugDetections)
      .sorted {
        if abs($0.boundingBox.minY - $1.boundingBox.minY) > 0.08 {
          return $0.boundingBox.minY > $1.boundingBox.minY
        }
        return $0.boundingBox.minX < $1.boundingBox.minX
      }
  }

  private func estimateVisibleCardCount(from samples: [[DetectedPlayingCard]]) -> Int {
    let frameCounts = samples.map { detections in
      let identifiedCards = dedupePhysicalCardDetections(
        detections.filter { $0.hasRankAndSuit && $0.confidence >= CardDetectionService.debugConfidenceFloor }
      )
      let fullCardShapeCount = fullCardShapeDetections(from: detections).count

      if fullCardShapeCount > 0 {
        return fullCardShapeCount
      }
      return identifiedCards.count
    }
    .filter { $0 > 0 }

    guard !frameCounts.isEmpty else {
      return 0
    }

    let histogram = Dictionary(grouping: frameCounts, by: { $0 }).mapValues(\.count)
    let stableCount = histogram
      .sorted { lhs, rhs in
        if lhs.value != rhs.value {
          return lhs.value > rhs.value
        }
        return lhs.key < rhs.key
      }
      .first?.key ?? 0
    return min(stableCount, 7)
  }

  private func dedupePhysicalCardDetections(_ detections: [DetectedPlayingCard]) -> [DetectedPlayingCard] {
    var selected: [DetectedPlayingCard] = []

    for detection in detections.sorted(by: { $0.confidence > $1.confidence }) {
      if let conflictIndex = selected.firstIndex(where: { isSamePhysicalCard(detection.boundingBox, $0.boundingBox) }) {
        if detection.confidence > selected[conflictIndex].confidence {
          selected[conflictIndex] = detection
        }
      } else {
        selected.append(detection)
      }
    }

    return selected.sorted {
      if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.08 {
        return $0.boundingBox.midY < $1.boundingBox.midY
      }
      return $0.boundingBox.midX < $1.boundingBox.midX
    }
  }

  private func dedupeCardShapeDetections(_ detections: [DetectedPlayingCard]) -> [DetectedPlayingCard] {
    var selected: [DetectedPlayingCard] = []

    for detection in detections.sorted(by: { $0.confidence > $1.confidence }) {
      let overlapsExisting = selected.contains { existing in
        isSamePhysicalCard(detection.boundingBox, existing.boundingBox)
      }

      if !overlapsExisting {
        selected.append(detection)
      }
    }

    return selected
  }

  private func fullCardShapeDetections(from detections: [DetectedPlayingCard]) -> [DetectedPlayingCard] {
    let fullCardCandidates = detections
      .filter { !$0.hasRankAndSuit && $0.apiLabel == "card" && $0.confidence >= 0.70 }
      .filter(isLikelyFullCardShape)
      .sorted { lhs, rhs in
        let lhsArea = lhs.boundingBox.width * lhs.boundingBox.height
        let rhsArea = rhs.boundingBox.width * rhs.boundingBox.height
        if abs(lhsArea - rhsArea) > 0.008 {
          return lhsArea > rhsArea
        }
        return lhs.confidence > rhs.confidence
      }

    var selected: [DetectedPlayingCard] = []
    for detection in fullCardCandidates {
      let overlapsExisting = selected.contains { existing in
        existing.boundingBox.intersectionOverUnion(with: detection.boundingBox) > 0.10
          || existing.boundingBox.contains(CGPoint(x: detection.boundingBox.midX, y: detection.boundingBox.midY))
          || detection.boundingBox.contains(CGPoint(x: existing.boundingBox.midX, y: existing.boundingBox.midY))
          || isSamePhysicalCard(existing.boundingBox, detection.boundingBox)
      }

      if !overlapsExisting {
        selected.append(detection)
      }
    }

    return selected
      .prefix(7)
      .sorted {
        if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.08 {
          return $0.boundingBox.midY < $1.boundingBox.midY
        }
        return $0.boundingBox.midX < $1.boundingBox.midX
      }
  }

  private func isLikelyFullCardShape(_ detection: DetectedPlayingCard) -> Bool {
    let box = detection.boundingBox
    let width = box.width
    let height = box.height
    let area = width * height
    let aspect = min(width, height) / max(width, height)

    return width >= 0.10
      && height >= 0.12
      && area >= 0.025
      && area <= 0.22
      && aspect >= 0.38
      && aspect <= 0.82
  }

  private func isSamePhysicalCard(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    let centerDistance = hypot(lhs.midX - rhs.midX, lhs.midY - rhs.midY)
    let averageWidth = max(0.001, (lhs.width + rhs.width) / 2)
    let averageHeight = max(0.001, (lhs.height + rhs.height) / 2)
    let normalizedDistance = hypot(
      (lhs.midX - rhs.midX) / averageWidth,
      (lhs.midY - rhs.midY) / averageHeight
    )

    return lhs.intersectionOverUnion(with: rhs) > 0.12
      || centerDistance < 0.055
      || normalizedDistance < 0.85
  }

  private func visibleCardShapeCandidates(
    from samples: [[DetectedPlayingCard]],
    excluding identifiedGroups: [StableCardGroup],
    maxCount: Int
  ) -> [TableCardCandidate] {
    guard maxCount > 0 else { return [] }

    return fullCardShapeDetections(
      from: samples
        .flatMap { $0 }
        .filter { shape in
          !identifiedGroups.contains { isSamePhysicalCard(shape.boundingBox, $0.boundingBox) }
        }
    )
    .prefix(maxCount)
    .map {
      TableCardCandidate(
        detection: $0,
        zone: .unknown,
        supportCount: 1,
        peakConfidence: $0.confidence,
        stabilizedConfidence: $0.confidence,
        isUsableForState: false
      )
    }
  }

  private func buildTableCardState(from samples: [[DetectedPlayingCard]]) -> TableCardState {
    let detections = samples.flatMap { $0 }.filter(\.hasRankAndSuit)
    let visibleCardCount = estimateVisibleCardCount(from: samples)
    guard !detections.isEmpty else {
      let shapeCandidates = visibleCardShapeCandidates(
        from: samples,
        excluding: [],
        maxCount: visibleCardCount
      )
      return TableCardState(
        candidates: shapeCandidates,
        heroCards: [],
        boardCards: [],
        confidence: 0,
        warning: visibleCardCount > 0
          ? "Saw \(visibleCardCount) card shapes, but no ranks/suits yet"
          : "No cards detected",
        visibleCardCount: visibleCardCount,
        identifiedCardCount: 0
      )
    }

    let requiredSupport = minimumSupportCount(for: samples)
    let groups = Dictionary(grouping: detections, by: \.apiLabel)
      .values
      .map { stabilizeCardGroup($0, requiredSupport: requiredSupport) }
      .sorted { lhs, rhs in
        if abs(lhs.center.y - rhs.center.y) > 0.05 {
          return lhs.center.y < rhs.center.y
        }
        return lhs.center.x < rhs.center.x
      }

    let usableGroups = resolvePhysicalCardConflicts(groups.filter(\.isUsableForState))
    let stateGroups = Array(
      usableGroups
        .sorted(by: isStrongerCardGroup)
        .prefix(visibleCardCount > 0 ? visibleCardCount : usableGroups.count)
    )
    let orderedStateGroups = stateGroups.sorted {
      if abs($0.center.y - $1.center.y) > 0.05 {
        return $0.center.y < $1.center.y
      }
      return $0.center.x < $1.center.x
    }
    var heroLabels = Set<String>()
    var boardLabels = Set<String>()
    var warning: String?

    let zones = inferTableZones(from: orderedStateGroups)
    heroLabels = Set(zones.hero.map(\.apiLabel))
    boardLabels = Set(zones.board.map(\.apiLabel))
    let identifiedCardCount = orderedStateGroups.count

    var candidates = orderedStateGroups.map { group in
      let zone: TableCardZone
      if heroLabels.contains(group.apiLabel) {
        zone = .hero
      } else if boardLabels.contains(group.apiLabel) {
        zone = .board
      } else {
        zone = .unknown
      }

      return TableCardCandidate(
        detection: DetectedPlayingCard(
          label: group.label,
          apiLabel: group.apiLabel,
          confidence: group.stabilizedConfidence,
          boundingBox: group.boundingBox
        ),
        zone: zone,
        supportCount: group.supportCount,
        peakConfidence: group.peakConfidence,
        stabilizedConfidence: group.stabilizedConfidence,
        isUsableForState: group.isUsableForState
      )
    }
    candidates.append(
      contentsOf: visibleCardShapeCandidates(
        from: samples,
        excluding: orderedStateGroups,
        maxCount: max(0, visibleCardCount - identifiedCardCount)
      )
    )

    let heroCards = candidates
      .filter { $0.zone == .hero }
      .sorted { $0.detection.boundingBox.midX < $1.detection.boundingBox.midX }
      .map(\.detection.apiLabel)
    let boardCards = candidates
      .filter { $0.zone == .board }
      .sorted { $0.detection.boundingBox.midX < $1.detection.boundingBox.midX }
      .map(\.detection.apiLabel)

    if visibleCardCount > identifiedCardCount {
      warning = "Saw \(visibleCardCount) cards; identified \(identifiedCardCount)"
    } else if heroCards.count < 2 {
      warning = "Need clearer hero cards"
    } else if !boardCards.isEmpty && ![3, 4, 5].contains(boardCards.count) {
      warning = "Board needs 3-5 cards"
    } else if boardCards.isEmpty {
      warning = "Board not detected yet"
    }

    let stateDetections = candidates
      .filter { $0.zone == .hero || $0.zone == .board }
      .map(\.detection)
    return TableCardState(
      candidates: candidates,
      heroCards: heroCards,
      boardCards: boardCards,
      confidence: averageConfidence(stateDetections),
      warning: warning,
      visibleCardCount: visibleCardCount,
      identifiedCardCount: identifiedCardCount
    )
  }

  private func buildHeroHandState(from samples: [[DetectedPlayingCard]]) -> TableCardState {
    let detections = samples.flatMap { $0 }.filter(\.hasRankAndSuit)
    guard !detections.isEmpty else {
      return TableCardState(
        candidates: [],
        heroCards: [],
        boardCards: boardCards,
        confidence: 0,
        warning: "No hand cards detected"
      )
    }

    let groups = Dictionary(grouping: detections, by: \.apiLabel)
      .values
      .map { stabilizeCardGroup($0, requiredSupport: minimumSupportCount(for: samples)) }
      .sorted { lhs, rhs in
        if abs(lhs.center.y - rhs.center.y) > 0.05 {
          return lhs.center.y < rhs.center.y
        }
        return lhs.center.x < rhs.center.x
      }

    let usableGroups = resolvePhysicalCardConflicts(groups.filter(\.isUsableForState))
    let heroGroups = inferHeroGroups(from: usableGroups)
    let heroLabels = Set(heroGroups.map(\.apiLabel))

    let candidates = groups.map { group in
      let zone: TableCardZone = heroLabels.contains(group.apiLabel) ? .hero : .unknown
      return TableCardCandidate(
        detection: DetectedPlayingCard(
          label: group.label,
          apiLabel: group.apiLabel,
          confidence: group.stabilizedConfidence,
          boundingBox: group.boundingBox
        ),
        zone: zone,
        supportCount: group.supportCount,
        peakConfidence: group.peakConfidence,
        stabilizedConfidence: group.stabilizedConfidence,
        isUsableForState: group.isUsableForState
      )
    }

    let heroCards = candidates
      .filter { $0.zone == .hero }
      .sorted { $0.detection.boundingBox.midX < $1.detection.boundingBox.midX }
      .prefix(2)
      .map(\.detection.apiLabel)

    let warning: String? = heroCards.count == 2
      ? (boardCards.isEmpty ? "Board not detected yet" : nil)
      : "Need clearer hero cards"

    return TableCardState(
      candidates: candidates,
      heroCards: Array(heroCards),
      boardCards: boardCards,
      confidence: averageConfidence(candidates.filter { $0.zone == .hero }.map(\.detection)),
      warning: warning
    )
  }

  private func minimumSupportCount(for samples: [[DetectedPlayingCard]]) -> Int {
    if samples.count >= 20 {
      return 3
    }
    if samples.count >= 2 {
      return 2
    }
    return 1
  }

  private func stabilizeCardGroup(
    _ detections: [DetectedPlayingCard],
    requiredSupport: Int = 1
  ) -> StableCardGroup {
    let sortedDetections = detections.sorted { $0.confidence > $1.confidence }
    let bestDetection = sortedDetections[0]
    let supportCount = detections.count
    let peakConfidence = sortedDetections[0].confidence
    let averageConfidence = Float(detections.map(\.confidence).reduce(0, +)) / Float(supportCount)
    let stabilizedConfidence = (peakConfidence * 0.65) + (averageConfidence * 0.35)
    let isRepeatedBorderline = supportCount >= requiredSupport && stabilizedConfidence >= CardDetectionService.usableConfidenceFloor
    let isHighConfidenceSingle = requiredSupport <= 1 && peakConfidence >= 0.95
    let isUsable = isRepeatedBorderline || isHighConfidenceSingle

    let averageMinX = detections.map { $0.boundingBox.minX }.reduce(0, +) / CGFloat(supportCount)
    let averageMinY = detections.map { $0.boundingBox.minY }.reduce(0, +) / CGFloat(supportCount)
    let averageWidth = detections.map { $0.boundingBox.width }.reduce(0, +) / CGFloat(supportCount)
    let averageHeight = detections.map { $0.boundingBox.height }.reduce(0, +) / CGFloat(supportCount)
    let box = CGRect(x: averageMinX, y: averageMinY, width: averageWidth, height: averageHeight)

    return StableCardGroup(
      apiLabel: bestDetection.apiLabel,
      label: bestDetection.label,
      detections: detections,
      supportCount: supportCount,
      peakConfidence: peakConfidence,
      stabilizedConfidence: min(1, stabilizedConfidence),
      boundingBox: box,
      center: CGPoint(x: box.midX, y: box.midY),
      isUsableForState: isUsable
    )
  }

  private func inferHeroGroups(from groups: [StableCardGroup]) -> [StableCardGroup] {
    let rows = clusterRows(groups)
    if rows.count == 1, rows[0].groups.count >= 3 {
      return []
    }

    if let bottomRow = rows.first, bottomRow.groups.count == 2 {
      return bottomRow.groups.sorted { $0.center.x < $1.center.x }
    }

    let bottomGroups = groups.filter { $0.center.y < 0.48 }
    if bottomGroups.count >= 2 {
      return Array(
        bottomGroups
          .sorted {
            if abs($0.center.y - $1.center.y) > 0.06 {
              return $0.center.y < $1.center.y
            }
            return $0.stabilizedConfidence > $1.stabilizedConfidence
          }
          .prefix(2)
      )
      .sorted { $0.center.x < $1.center.x }
    }

    let sortedByScreenBottom = groups.sorted { $0.center.y < $1.center.y }
    if sortedByScreenBottom.count == 2 {
      return sortedByScreenBottom.sorted { $0.center.x < $1.center.x }
    }

    if sortedByScreenBottom.count >= 5 {
      let firstTwo = Array(sortedByScreenBottom.prefix(2))
      let third = sortedByScreenBottom[2]
      let averageHeroY = firstTwo.map(\.center.y).reduce(0, +) / 2
      if third.center.y - averageHeroY > 0.10 {
        return firstTwo.sorted { $0.center.x < $1.center.x }
      }
    }

    return []
  }

  private func inferTableZones(from groups: [StableCardGroup]) -> (hero: [StableCardGroup], board: [StableCardGroup]) {
    let rows = clusterRows(groups)
    guard !rows.isEmpty else {
      return ([], [])
    }

    if rows.count == 1 {
      let row = selectBoardGroups(from: rows[0].groups)
      if (3...5).contains(row.count) {
        return ([], row)
      }
      if row.count == 2 {
        return (row, [])
      }
      return ([], Array(row.prefix(5)))
    }

    var heroGroups: [StableCardGroup] = []
    var boardGroups: [StableCardGroup] = []

    if let bottomRow = rows.first, bottomRow.groups.count == 2 {
      heroGroups = bottomRow.groups.sorted { $0.center.x < $1.center.x }
    }

    let candidateBoardRows = rows
      .filter { row in
        let isHeroRow = Set(row.groups.map(\.apiLabel)) == Set(heroGroups.map(\.apiLabel))
        return !isHeroRow && (3...5).contains(row.groups.count)
      }
      .sorted { lhs, rhs in
        if lhs.groups.count != rhs.groups.count {
          return lhs.groups.count > rhs.groups.count
        }
        return lhs.averageY > rhs.averageY
      }

    if let bestBoardRow = candidateBoardRows.first {
      boardGroups = selectBoardGroups(from: bestBoardRow.groups)
    } else if heroGroups.count == 2 {
      let heroCenterY = heroGroups.map(\.center.y).reduce(0, +) / 2
      boardGroups = selectBoardGroups(from:
        groups
          .filter { !Set(heroGroups.map(\.apiLabel)).contains($0.apiLabel) && $0.center.y > heroCenterY + 0.08 }
      )
    } else if let fullestRow = rows.max(by: { $0.groups.count < $1.groups.count }) {
      let row = selectBoardGroups(from: fullestRow.groups)
      if row.count >= 3 {
        boardGroups = row
      }
    }

    return (heroGroups, boardGroups)
  }

  private func selectBoardGroups(from groups: [StableCardGroup]) -> [StableCardGroup] {
    guard groups.count > 5 else {
      return groups.sorted { $0.center.x < $1.center.x }
    }

    let candidateRows = groups.compactMap { anchor -> [StableCardGroup]? in
      let nearby = groups.filter { abs($0.center.y - anchor.center.y) <= 0.09 }
      guard nearby.count >= 3 else { return nil }
      return Array(nearby.sorted(by: isStrongerCardGroup).prefix(5))
    }

    let strongest = candidateRows.max { lhs, rhs in
      boardRowScore(lhs) < boardRowScore(rhs)
    } ?? Array(groups.sorted(by: isStrongerCardGroup).prefix(5))

    return strongest.sorted { $0.center.x < $1.center.x }
  }

  private func resolvePhysicalCardConflicts(_ groups: [StableCardGroup]) -> [StableCardGroup] {
    var selected: [StableCardGroup] = []

    for group in groups.sorted(by: isStrongerCardGroup) {
      guard let conflictIndex = selected.firstIndex(where: { overlapsSamePhysicalCard($0, group) }) else {
        selected.append(group)
        continue
      }

      if isStrongerCardGroup(group, selected[conflictIndex]) {
        selected[conflictIndex] = group
      }
    }

    return selected.sorted {
      if abs($0.center.y - $1.center.y) > 0.05 {
        return $0.center.y < $1.center.y
      }
      return $0.center.x < $1.center.x
    }
  }

  private func isStrongerCardGroup(_ lhs: StableCardGroup, _ rhs: StableCardGroup) -> Bool {
    if lhs.supportCount != rhs.supportCount {
      return lhs.supportCount > rhs.supportCount
    }
    if abs(lhs.stabilizedConfidence - rhs.stabilizedConfidence) > 0.03 {
      return lhs.stabilizedConfidence > rhs.stabilizedConfidence
    }
    return lhs.peakConfidence > rhs.peakConfidence
  }

  private func overlapsSamePhysicalCard(_ lhs: StableCardGroup, _ rhs: StableCardGroup) -> Bool {
    let centerDistance = hypot(lhs.center.x - rhs.center.x, lhs.center.y - rhs.center.y)
    return lhs.boundingBox.intersectionOverUnion(with: rhs.boundingBox) > 0.18 || centerDistance < 0.07
  }

  private func boardRowScore(_ groups: [StableCardGroup]) -> Double {
    guard !groups.isEmpty else { return 0 }
    let yValues = groups.map(\.center.y)
    let ySpread = (yValues.max() ?? 0) - (yValues.min() ?? 0)
    let averageSupport = Double(groups.map(\.supportCount).reduce(0, +)) / Double(groups.count)
    let confidence = groups.map { Double($0.stabilizedConfidence) }.reduce(0, +)
    return (Double(groups.count) * 12.0) + (averageSupport * 3.0) + confidence - (Double(ySpread) * 18.0)
  }

  private func clusterRows(_ groups: [StableCardGroup]) -> [StableCardRow] {
    let sortedGroups = groups.sorted {
      if abs($0.center.y - $1.center.y) > 0.08 {
        return $0.center.y < $1.center.y
      }
      return $0.center.x < $1.center.x
    }

    var rows: [[StableCardGroup]] = []
    for group in sortedGroups {
      if let rowIndex = rows.indices.first(where: { index in
        let rowY = rows[index].map(\.center.y).reduce(0, +) / CGFloat(rows[index].count)
        return abs(rowY - group.center.y) <= 0.12
      }) {
        rows[rowIndex].append(group)
      } else {
        rows.append([group])
      }
    }

    return rows.map { row in
      StableCardRow(groups: row.sorted { $0.center.x < $1.center.x })
    }
  }

  private func applyTableCardState(_ state: TableCardState) {
    latestTableCandidates = state.candidates
    latestDetections = state.candidates.map(\.detection)
    heroCards = state.heroCards
    boardCards = state.boardCards
    tableWarning = state.warning
    hasUnidentifiedVisibleCards = state.unidentifiedCardCount > 0
    detectionStatus = state.unidentifiedCardCount > 0
      ? "\(state.identifiedCardCount)/\(state.visibleCardCount) cards identified"
      : state.candidates.isEmpty
      ? "0 detections"
      : "\(state.candidates.count) detections"
  }

  private func sendPokerVisionCardDetections(_ detections: [DetectedPlayingCard]) async {
    let sortedDetections = detections
      .sorted { lhs, rhs in
        if abs(lhs.boundingBox.minY - rhs.boundingBox.minY) > 0.08 {
          return lhs.boundingBox.minY > rhs.boundingBox.minY
        }
        return lhs.boundingBox.minX < rhs.boundingBox.minX
      }

    let visibleCardCount = estimateVisibleCardCount(from: [detections])
    let physicalCards = dedupePhysicalCardDetections(sortedDetections.filter(\.hasRankAndSuit))
    let uniqueCards = Array(
      Dictionary(grouping: physicalCards, by: \.apiLabel)
        .values
        .compactMap { $0.max { $0.confidence < $1.confidence } }
        .sorted { $0.confidence > $1.confidence }
        .prefix(visibleCardCount > 0 ? visibleCardCount : 5)
    )
    let unidentifiedCount = max(0, visibleCardCount - uniqueCards.count)
    let detailRows = uniqueCards.map { "\($0.apiLabel) \(Int(($0.confidence * 100).rounded()))%" }
      + Array(repeating: "Card ?", count: unidentifiedCount)

    let averageConfidence = Int(
      ((uniqueCards.map { Double($0.confidence) }.reduce(0, +) / Double(max(uniqueCards.count, 1))) * 100)
        .rounded()
    )
    let result = PokerCardDetectionDisplayResult(
      cards: unidentifiedCount > 0
        ? "\(uniqueCards.map(\.apiLabel).joined(separator: " ")) + \(unidentifiedCount)?"
        : uniqueCards.map(\.apiLabel).joined(separator: " "),
      count: max(visibleCardCount, uniqueCards.count),
      averageConfidence: averageConfidence,
      details: detailRows
    )

    await send(
      PokerVisionDisplay.cardDetections(
        result: result,
        onAnalyzeAgain: { [weak self] in
          Task { @MainActor in
            await self?.analyzePokerVisionCards()
          }
        }
      )
    )
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
      action: canGetDecision ? "Ready" : "Analyze table"
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
        onScanHand: { [weak self] in
          Task { @MainActor in
            await self?.analyzeHeroHand()
          }
        },
        onStartRecording: { [weak self] in
          Task { @MainActor in
            await self?.startTableRecording()
          }
        },
        onInitializeDemo: { [weak self] in
          Task { @MainActor in
            await self?.initializeDemoPlay()
          }
        },
        onAnalyzeTable: { [weak self] in
          Task { @MainActor in
            await self?.analyzeTable()
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

  private func bestUniqueCards(
    from detections: [DetectedPlayingCard],
    excluding excludedCards: Set<String> = [],
    limit: Int
  ) -> [DetectedPlayingCard] {
    Dictionary(grouping: detections.filter { !excludedCards.contains($0.apiLabel) }, by: \.apiLabel)
      .values
      .compactMap { $0.max { $0.confidence < $1.confidence } }
      .sorted { lhs, rhs in
        if abs(lhs.confidence - rhs.confidence) > 0.05 {
          return lhs.confidence > rhs.confidence
        }
        return lhs.boundingBox.minX < rhs.boundingBox.minX
      }
      .prefix(limit)
      .map { $0 }
  }

  private func averageConfidence(_ detections: [DetectedPlayingCard]) -> Int {
    guard !detections.isEmpty else { return 0 }
    return Int(
      ((detections.map { Double($0.confidence) }.reduce(0, +) / Double(detections.count)) * 100)
        .rounded()
    )
  }

  private func sendPokerVisionSolverResult(_ result: PokerSolverDisplayResult) async {
    displayResultHoldUntil = Date().addingTimeInterval(30)
    updateDisplayMirror(
      title: "Best: \(result.primary)",
      primary: result.secondary,
      secondary: "Hero \(result.heroCards) | Board \(result.boardCards)",
      action: "Analyze next"
    )
    await send(
      PokerVisionDisplay.solverResult(
        result: result,
        onStartRecording: { [weak self] in
          Task { @MainActor in
            await self?.startTableRecording()
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

  private func sendPokerVisionSolverError(_ message: String) async {
    displayResultHoldUntil = Date().addingTimeInterval(15)
    updateDisplayMirror(
      title: "Solver error",
      primary: message,
      secondary: "Check the captured state, then retry.",
      action: canGetDecision ? "Retry" : "Analyze table"
    )
    await send(
      PokerVisionDisplay.solverError(
        message: message,
        onStartRecording: { [weak self] in
          Task { @MainActor in
            await self?.startTableRecording()
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

  func sendPokerVisionEmptyAnalysis() async {
    updateDisplayMirror(
      title: "Nothing detected",
      primary: "No useful table state was captured yet.",
      secondary: "Start display, wait for camera, then analyze again.",
      action: "Analyze table"
    )
    await send(
      PokerVisionDisplay.emptyAnalysis(
        onStartRecording: { [weak self] in
          Task { @MainActor in
            await self?.startTableRecording()
          }
        },
        onAnalyzeAgain: { [weak self] in
          Task { @MainActor in
            await self?.analyzePokerVisionCards()
          }
        }
      )
    )
  }

  func sendPokerVisionResult() async {
    updateDisplayMirror(
      title: "Analysis result",
      primary: "Best: \(PokerTableSnapshot.demo.bestAction) \(PokerTableSnapshot.demo.raiseAmount)",
      secondary: "This is the old sample result.",
      action: "Demo"
    )
    await send(
      PokerVisionDisplay.result(
        snapshot: .demo,
        onStartRecording: { [weak self] in
          Task { @MainActor in
            await self?.startTableRecording()
          }
        },
        onAnalyzeAgain: { [weak self] in
          Task { @MainActor in
            await self?.sendPokerVisionResult()
          }
        }
      )
    )
  }

  func detachFromDisplay() async {
    isScanningTable = false
    stopDisplayCameraStreamLocally()
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

  private func stopDisplayCameraStreamLocally() {
    displayCameraStreamTask?.cancel()
    displayCameraStreamTask = nil
    isStreamingCameraToDisplay = false
    displayFrameServer.stop()
  }

  private func returnToPokerVisionControls() async {
    if !heroCards.isEmpty || !boardCards.isEmpty {
      await sendPokerVisionTableState(
        status: canGetDecision ? "Table ready" : "Need clearer table view",
        confidence: averageConfidence(latestDetections)
      )
    } else {
      await sendPokerVisionReady()
    }
  }

  private func makeDisplayCameraFrameURI() -> String? {
    let image: UIImage?
    if let currentCameraFrame {
      image = currentCameraFrame
    } else if let latestCameraFrame {
      image = UIImage(cgImage: latestCameraFrame)
    } else {
      image = nil
    }

    guard let image else { return nil }

    let pixelWidth = max(1, image.size.width * image.scale)
    let pixelHeight = max(1, image.size.height * image.scale)
    let targetWidth: CGFloat = min(420, pixelWidth)
    let scale = targetWidth / pixelWidth
    let targetSize = CGSize(width: targetWidth, height: max(1, pixelHeight * scale))
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1

    let resized = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: targetSize))
    }

    guard let data = resized.jpegData(compressionQuality: 0.45) else { return nil }
    do {
      let baseURL = try displayFrameServer.updateFrame(data)
      displayFrameSequence += 1
      return "\(baseURL.absoluteString)?frame=\(displayFrameSequence)"
    } catch {
      errorMessage = "Could not start camera frame server: \(error.localizedDescription)"
      return nil
    }
  }
}
