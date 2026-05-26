/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import CoreML
import Foundation
import Vision

struct CardQuad: Equatable {
  let topLeft: CGPoint
  let topRight: CGPoint
  let bottomRight: CGPoint
  let bottomLeft: CGPoint

  var points: [CGPoint] {
    [topLeft, topRight, bottomRight, bottomLeft]
  }

  func mappedFromROI(_ roi: CGRect) -> CardQuad {
    CardQuad(
      topLeft: Self.map(topLeft, from: roi),
      topRight: Self.map(topRight, from: roi),
      bottomRight: Self.map(bottomRight, from: roi),
      bottomLeft: Self.map(bottomLeft, from: roi)
    )
  }

  private static func map(_ point: CGPoint, from roi: CGRect) -> CGPoint {
    CGPoint(
      x: roi.minX + point.x * roi.width,
      y: roi.minY + point.y * roi.height
    )
  }
}

struct DetectedPlayingCard: Identifiable, Equatable {
  let id = UUID()
  let label: String
  let apiLabel: String
  let confidence: Float
  let boundingBox: CGRect
  let orientedQuad: CardQuad?
  let locationConfidence: Float
  let rankConfidence: Float?
  let suitConfidence: Float?
  let sourceFrameTimestamp: Date
  let detectorName: String

  init(
    label: String,
    apiLabel: String,
    confidence: Float,
    boundingBox: CGRect,
    orientedQuad: CardQuad? = nil,
    locationConfidence: Float? = nil,
    rankConfidence: Float? = nil,
    suitConfidence: Float? = nil,
    sourceFrameTimestamp: Date = Date(),
    detectorName: String = "ml-coreml"
  ) {
    self.label = label
    self.apiLabel = apiLabel
    self.confidence = confidence
    self.boundingBox = boundingBox.clampedToUnit
    self.orientedQuad = orientedQuad
    self.locationConfidence = locationConfidence ?? confidence
    self.rankConfidence = rankConfidence
    self.suitConfidence = suitConfidence
    self.sourceFrameTimestamp = sourceFrameTimestamp
    self.detectorName = detectorName
  }

  var hasRankAndSuit: Bool {
    guard apiLabel.count == 2 else { return false }
    let rank = apiLabel.prefix(1)
    let suit = apiLabel.suffix(1)
    return "23456789TJQKA".contains(rank) && "cdhs".contains(suit)
  }

  func mappedFromROI(_ roi: CGRect, detectorName: String) -> DetectedPlayingCard {
    DetectedPlayingCard(
      label: label,
      apiLabel: apiLabel,
      confidence: confidence,
      boundingBox: CGRect(
        x: roi.minX + boundingBox.minX * roi.width,
        y: roi.minY + boundingBox.minY * roi.height,
        width: boundingBox.width * roi.width,
        height: boundingBox.height * roi.height
      ),
      orientedQuad: orientedQuad?.mappedFromROI(roi),
      locationConfidence: locationConfidence,
      rankConfidence: rankConfidence,
      suitConfidence: suitConfidence,
      sourceFrameTimestamp: sourceFrameTimestamp,
      detectorName: detectorName
    )
  }
}

enum TableCardZone: String, Equatable {
  case hero
  case board
  case unknown
}

struct TableCardCandidate: Identifiable, Equatable {
  let id = UUID()
  let detection: DetectedPlayingCard
  let zone: TableCardZone
  let supportCount: Int
  let peakConfidence: Float
  let stabilizedConfidence: Float
  let isUsableForState: Bool
}

struct TableCardState: Equatable {
  let candidates: [TableCardCandidate]
  let heroCards: [String]
  let boardCards: [String]
  let confidence: Int
  let warning: String?
  let visibleCardCount: Int
  let identifiedCardCount: Int

  init(
    candidates: [TableCardCandidate],
    heroCards: [String],
    boardCards: [String],
    confidence: Int,
    warning: String?,
    visibleCardCount: Int = 0,
    identifiedCardCount: Int? = nil
  ) {
    let identified = identifiedCardCount ?? Set(heroCards + boardCards).count
    self.candidates = candidates
    self.heroCards = heroCards
    self.boardCards = boardCards
    self.confidence = confidence
    self.warning = warning
    self.visibleCardCount = max(visibleCardCount, identified)
    self.identifiedCardCount = identified
  }

  var unidentifiedCardCount: Int {
    max(0, visibleCardCount - identifiedCardCount)
  }

  var isDecisionReady: Bool {
    heroCards.count == 2 && [3, 4, 5].contains(boardCards.count) && unidentifiedCardCount == 0
  }
}

enum CardDetectionError: LocalizedError {
  case modelNotFound
  case unsupportedObservation

  var errorDescription: String? {
    switch self {
    case .modelNotFound:
      return "Card detector model was not found in the app bundle."
    case .unsupportedObservation:
      return "Card detector returned an unsupported output type."
    }
  }
}

protocol CardDetectionEngine {
  var name: String { get }

  func detectCards(
    in image: CGImage,
    minimumConfidence: Float,
    sourceFrameTimestamp: Date
  ) async throws -> [DetectedPlayingCard]
}

final class MLCardDetector: CardDetectionEngine {
  let name = "ml-coreml"
  private let modelName: String
  private var visionModel: VNCoreMLModel?

  var isAvailable: Bool {
    (try? loadVisionModel()) != nil
  }

  init(modelName: String) {
    self.modelName = modelName
  }

  func detectCards(
    in image: CGImage,
    minimumConfidence: Float,
    sourceFrameTimestamp: Date
  ) async throws -> [DetectedPlayingCard] {
    let model = try loadVisionModel()

    return try await withCheckedThrowingContinuation { continuation in
      let request = VNCoreMLRequest(model: model) { request, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }

        guard let observations = request.results as? [VNRecognizedObjectObservation] else {
          continuation.resume(throwing: CardDetectionError.unsupportedObservation)
          return
        }

        let detections = observations.compactMap { observation in
          Self.detection(
            from: observation,
            minimumConfidence: minimumConfidence,
            sourceFrameTimestamp: sourceFrameTimestamp
          )
        }
          .sorted { $0.boundingBox.minX < $1.boundingBox.minX }
        continuation.resume(returning: detections)
      }

      request.imageCropAndScaleOption = .scaleFit
      let handler = VNImageRequestHandler(cgImage: image, orientation: .up)

      do {
        try handler.perform([request])
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }

  private func loadVisionModel() throws -> VNCoreMLModel {
    if let visionModel {
      return visionModel
    }

    let compiledURL = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc")
    let packageURL = Bundle.main.url(forResource: modelName, withExtension: "mlpackage")
    guard let modelURL = compiledURL ?? packageURL else {
      throw CardDetectionError.modelNotFound
    }

    let config = MLModelConfiguration()
    config.computeUnits = .all
    let coreMLModel = try MLModel(contentsOf: modelURL, configuration: config)
    let model = try VNCoreMLModel(for: coreMLModel)
    visionModel = model
    return model
  }

  private static func detection(
    from observation: VNRecognizedObjectObservation,
    minimumConfidence: Float,
    sourceFrameTimestamp: Date
  ) -> DetectedPlayingCard? {
    guard let bestLabel = observation.labels.first else {
      return nil
    }
    guard bestLabel.confidence >= minimumConfidence else {
      return nil
    }

    let normalized = normalizeCardLabel(bestLabel.identifier)
    return DetectedPlayingCard(
      label: normalized,
      apiLabel: labelToSolverFormat(normalized),
      confidence: bestLabel.confidence,
      boundingBox: observation.boundingBox,
      locationConfidence: observation.confidence,
      rankConfidence: bestLabel.confidence,
      suitConfidence: bestLabel.confidence,
      sourceFrameTimestamp: sourceFrameTimestamp,
      detectorName: "ml-coreml"
    )
  }

  private static func normalizeCardLabel(_ rawLabel: String) -> String {
    let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
      .uppercased()
      .replacingOccurrences(of: " ", with: "_")
      .replacingOccurrences(of: "-", with: "_")

    let compact = label.replacingOccurrences(of: "_", with: "")
    if compact.range(of: #"^(10|[2-9AJQK])[CDHS]$"#, options: .regularExpression) != nil {
      return compact
    }

    let ranks = [
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
    let suits = [
      "CLUB": "C", "CLUBS": "C", "C": "C",
      "DIAMOND": "D", "DIAMONDS": "D", "D": "D",
      "HEART": "H", "HEARTS": "H", "H": "H",
      "SPADE": "S", "SPADES": "S", "S": "S",
    ]

    let parts = label.split(separator: "_").map(String.init)
    let rank = parts.compactMap { ranks[$0] }.first
    let suit = parts.compactMap { suits[$0] }.first
    if let rank, let suit {
      return rank + suit
    }

    return rawLabel
  }

  private static func labelToSolverFormat(_ label: String) -> String {
    guard label.count >= 2 else {
      return label.lowercased()
    }

    let suit = label.suffix(1).lowercased()
    let rankText = String(label.dropLast())
    let rank = rankText == "10" ? "T" : rankText
    return rank + suit
  }
}

final class VisionHeuristicCardDetector: CardDetectionEngine {
  let name = "vision-rectangles"

  func detectCards(
    in image: CGImage,
    minimumConfidence: Float,
    sourceFrameTimestamp: Date
  ) async throws -> [DetectedPlayingCard] {
    try await withCheckedThrowingContinuation { continuation in
      let request = VNDetectRectanglesRequest { request, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }

        let observations = (request.results as? [VNRectangleObservation]) ?? []
        let detections = observations
          .filter { $0.confidence >= minimumConfidence }
          .prefix(16)
          .map { observation in
            DetectedPlayingCard(
              label: "Card",
              apiLabel: "card",
              confidence: observation.confidence,
              boundingBox: observation.boundingBox,
              orientedQuad: CardQuad(
                topLeft: observation.topLeft,
                topRight: observation.topRight,
                bottomRight: observation.bottomRight,
                bottomLeft: observation.bottomLeft
              ),
              locationConfidence: observation.confidence,
              sourceFrameTimestamp: sourceFrameTimestamp,
              detectorName: self.name
            )
          }
        continuation.resume(returning: detections)
      }

      request.minimumAspectRatio = 0.45
      request.maximumAspectRatio = 0.78
      request.minimumSize = 0.035
      request.quadratureTolerance = 35
      request.maximumObservations = 16

      do {
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }
}

final class CardDetectionService {
  static let shared = CardDetectionService()

  static let debugConfidenceFloor: Float = 0.45
  static let usableConfidenceFloor: Float = 0.60

  private let mlDetector = MLCardDetector(modelName: "yolov8m_synthetic")
  private let heuristicDetector = VisionHeuristicCardDetector()
  private let roiPasses: [(name: String, rect: CGRect)] = [
    ("table", CGRect(x: 0.04, y: 0.10, width: 0.92, height: 0.78)),
    ("hero", CGRect(x: 0.00, y: 0.00, width: 1.00, height: 0.54)),
    ("board", CGRect(x: 0.08, y: 0.34, width: 0.84, height: 0.44)),
  ]

  var isAvailable: Bool {
    mlDetector.isAvailable
  }

  private init() {}

  func detectCards(
    in image: CGImage,
    minimumConfidence: Float = CardDetectionService.debugConfidenceFloor
  ) async throws -> [DetectedPlayingCard] {
    let timestamp = Date()
    do {
      var detections = try await detectCardsWithMultiScale(
        engine: mlDetector,
        image: image,
        minimumConfidence: minimumConfidence,
        sourceFrameTimestamp: timestamp
      )
      if let cardShapes = try? await heuristicDetector.detectCards(
        in: image,
        minimumConfidence: max(0.35, minimumConfidence - 0.10),
        sourceFrameTimestamp: timestamp
      ) {
        detections.append(contentsOf: cardShapes)
      }
      return Self.sortDetections(Self.mergeDetections(detections))
    } catch CardDetectionError.modelNotFound {
      return try await heuristicDetector.detectCards(
        in: image,
        minimumConfidence: minimumConfidence,
        sourceFrameTimestamp: timestamp
      )
    }
  }

  private func detectCardsWithMultiScale(
    engine: CardDetectionEngine,
    image: CGImage,
    minimumConfidence: Float,
    sourceFrameTimestamp: Date
  ) async throws -> [DetectedPlayingCard] {
    var detections = try await engine.detectCards(
      in: image,
      minimumConfidence: minimumConfidence,
      sourceFrameTimestamp: sourceFrameTimestamp
    )

    for pass in roiPasses {
      guard let crop = image.cropping(to: pixelRect(for: pass.rect, image: image)) else {
        continue
      }
      let roiDetections = try await engine.detectCards(
        in: crop,
        minimumConfidence: minimumConfidence,
        sourceFrameTimestamp: sourceFrameTimestamp
      )
      detections.append(
        contentsOf: roiDetections.map {
          $0.mappedFromROI(pass.rect, detectorName: "\(engine.name)-\(pass.name)")
        }
      )
    }

    return Self.sortDetections(Self.mergeDetections(detections))
  }

  private func pixelRect(for normalizedRect: CGRect, image: CGImage) -> CGRect {
    let width = CGFloat(image.width)
    let height = CGFloat(image.height)
    let x = normalizedRect.minX * width
    let y = (1 - normalizedRect.maxY) * height
    let rect = CGRect(
      x: x,
      y: y,
      width: normalizedRect.width * width,
      height: normalizedRect.height * height
    ).integral
    return rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
  }

  private static func mergeDetections(_ detections: [DetectedPlayingCard]) -> [DetectedPlayingCard] {
    var kept: [DetectedPlayingCard] = []

    for detection in detections.sorted(by: { $0.confidence > $1.confidence }) {
      if let duplicateIndex = kept.firstIndex(where: { isDuplicate(detection, $0) }) {
        if detection.confidence > kept[duplicateIndex].confidence {
          kept[duplicateIndex] = detection
        }
      } else {
        kept.append(detection)
      }
    }

    return kept
  }

  private static func sortDetections(_ detections: [DetectedPlayingCard]) -> [DetectedPlayingCard] {
    detections.sorted {
      if abs($0.boundingBox.minY - $1.boundingBox.minY) > 0.08 {
        return $0.boundingBox.minY > $1.boundingBox.minY
      }
      return $0.boundingBox.minX < $1.boundingBox.minX
    }
  }

  private static func isDuplicate(_ lhs: DetectedPlayingCard, _ rhs: DetectedPlayingCard) -> Bool {
    guard lhs.apiLabel == rhs.apiLabel else { return false }

    let centerDistance = hypot(
      lhs.boundingBox.midX - rhs.boundingBox.midX,
      lhs.boundingBox.midY - rhs.boundingBox.midY
    )

    return intersectionOverUnion(lhs.boundingBox, rhs.boundingBox) > 0.30 || centerDistance < 0.055
  }

  private static func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
    let intersection = lhs.intersection(rhs)
    guard !intersection.isNull else { return 0 }

    let intersectionArea = intersection.width * intersection.height
    let unionArea = lhs.width * lhs.height + rhs.width * rhs.height - intersectionArea
    guard unionArea > 0 else { return 0 }
    return intersectionArea / unionArea
  }
}

private extension CGRect {
  var clampedToUnit: CGRect {
    let minX = max(0, min(1, self.minX))
    let minY = max(0, min(1, self.minY))
    let maxX = max(0, min(1, self.maxX))
    let maxY = max(0, min(1, self.maxY))
    return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
  }
}
