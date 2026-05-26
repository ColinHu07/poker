/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import MWDATDisplay

struct PokerTableSnapshot {
  let players: Int
  let heroCards: String
  let boardCards: String
  let pot: String
  let heroStack: String
  let bestAction: String
  let raiseAmount: String
  let foldPercent: Int
  let callPercent: Int
  let raisePercent: Int
  let confidence: Int

  static let placeholder = PokerTableSnapshot(
    players: 0,
    heroCards: "Scanning",
    boardCards: "Scanning",
    pot: "--",
    heroStack: "--",
    bestAction: "Frame table",
    raiseAmount: "",
    foldPercent: 0,
    callPercent: 0,
    raisePercent: 0,
    confidence: 0
  )

  static let demo = PokerTableSnapshot(
    players: 5,
    heroCards: "8c 3d",
    boardCards: "3s 9d 9c 9h",
    pot: "$9",
    heroStack: "$960",
    bestAction: "Raise",
    raiseAmount: "$1,500",
    foldPercent: 8,
    callPercent: 20,
    raisePercent: 72,
    confidence: 91
  )
}

struct PokerSolverDisplayResult {
  let primary: String
  let secondary: String
  let colorHint: String
  let heroCards: String
  let boardCards: String
  let solver: String
  let latencyMS: Int
}

struct PokerCardDetectionDisplayResult {
  let cards: String
  let count: Int
  let averageConfidence: Int
  let details: [String]
}

struct PokerVisionStateDisplayResult {
  let heroCards: String
  let boardCards: String
  let status: String
  let confidence: Int
}

enum PokerVisionDisplay {
  static func ready(
    onScanHand: @escaping @Sendable () -> Void = {},
    onStartRecording: @escaping @Sendable () -> Void = {},
    onStartCameraStream: @escaping @Sendable () -> Void = {},
    onAnalyzeTable: @escaping @Sendable () -> Void,
    onGetDecision: @escaping @Sendable () -> Void
  ) -> FlexBox {
    FlexBox(direction: .column, spacing: 12) {
      FlexBox(direction: .column, spacing: 8) {
        Text("PokerVision", style: .heading)
        Text("Look at your hand and the board together, then scan the table.", style: .body)
        Text("Phone computes; glasses show state.", style: .meta, color: .secondary)
      }
      .padding(24)
      .background(.card)

      FlexBox(direction: .row, spacing: 8, alignment: .center, crossAlignment: .center, wrap: true) {
        Button(label: "Scan hand", style: .secondary, onClick: onScanHand)
        Button(label: "Start recording", style: .secondary, onClick: onStartRecording)
        Button(label: "Camera stream", style: .secondary, onClick: onStartCameraStream)
        Button(label: "Analyze table", style: .primary, onClick: onAnalyzeTable)
        Button(label: "Decision locked", style: .secondary, onClick: onGetDecision)
      }
    }
  }

  static func recording(
    isRecording: Bool = false,
    sampleCount: Int = 0,
    onScanHand: @escaping @Sendable () -> Void = {},
    onStartRecording: @escaping @Sendable () -> Void = {},
    onStopRecording: @escaping @Sendable () -> Void = {},
    onStartCameraStream: @escaping @Sendable () -> Void = {},
    onAnalyzeTable: @escaping @Sendable () -> Void,
    onGetDecision: @escaping @Sendable () -> Void
  ) -> FlexBox {
    FlexBox(direction: .column, spacing: 12) {
      FlexBox(direction: .column, spacing: 8) {
        Text(isRecording ? "Recording table" : "Frame the table", style: .heading)
        Text(isRecording ? "Move slowly across hand and board." : "Keep your two cards and the board in view.", style: .body)
        Text(isRecording ? "\(sampleCount) frame samples collected" : "Decision unlocks after hand plus flop, turn, or river.", style: .meta, color: .secondary)
      }
      .padding(24)
      .background(.card)

      FlexBox(direction: .row, spacing: 8, alignment: .center, crossAlignment: .center, wrap: true) {
        Button(label: "Scan hand", style: .secondary, onClick: onScanHand)
        Button(label: isRecording ? "End recording" : "Start recording", style: .primary, onClick: isRecording ? onStopRecording : onStartRecording)
        Button(label: "Camera stream", style: .secondary, onClick: onStartCameraStream)
        Button(label: "Analyze table", style: .primary, onClick: onAnalyzeTable)
        Button(label: "Decision locked", style: .secondary, onClick: onGetDecision)
      }
    }
  }

  static func cameraPreview(
    frameURI: String?,
    status: String,
    onRefresh: @escaping @Sendable () -> Void,
    onAnalyzeTable: @escaping @Sendable () -> Void,
    onBack: @escaping @Sendable () -> Void
  ) -> FlexBox {
    FlexBox(direction: .column, spacing: 12) {
      FlexBox(direction: .column, spacing: 8) {
        Text("Camera view", style: .heading)
        Text(status, style: .body)
        Text("Preview refreshes on demand; phone keeps the live stream.", style: .meta, color: .secondary)
      }
      .padding(24)
      .background(.card)

      if let frameURI {
        FlexBox(direction: .column, spacing: 8) {
          Image(uri: frameURI, sizePreset: .fill, cornerRadius: .medium)
        }
        .padding(8)
        .background(.card)
      } else {
        FlexBox(direction: .column, spacing: 8) {
          Text("No camera frame yet", style: .body)
          Text("Open display, wait for Streaming on the phone, then refresh.", style: .meta, color: .secondary)
        }
        .padding(24)
        .background(.card)
      }

      FlexBox(direction: .row, spacing: 8, alignment: .center, crossAlignment: .center, wrap: true) {
        Button(label: "Refresh", style: .secondary, onClick: onRefresh)
        Button(label: "Analyze table", style: .primary, onClick: onAnalyzeTable)
        Button(label: "Back", style: .secondary, onClick: onBack)
      }
    }
  }

  static func cameraStream(
    frameURI: String?,
    status: String,
    onStop: @escaping @Sendable () -> Void
  ) -> FlexBox {
    FlexBox(direction: .column, spacing: 10) {
      FlexBox(direction: .row, spacing: 8, alignment: .center, crossAlignment: .center, wrap: true) {
        Text("Camera monitor", style: .heading)
        Text(status, style: .meta, color: .secondary)
        Button(label: "Stop", style: .secondary, onClick: onStop)
      }
      .padding(16)
      .background(.card)

      if let frameURI {
        FlexBox(direction: .column, spacing: 6) {
          Image(uri: frameURI, sizePreset: .fill, cornerRadius: .medium)
          Text("Frame URL ready", style: .meta, color: .secondary)
          Text("If the image stays blank, DAT Display is not rendering live camera frame URLs.", style: .meta, color: .secondary)
        }
        .padding(8)
        .background(.card)
      } else {
        FlexBox(direction: .column, spacing: 8) {
          Text("Waiting for camera", style: .heading)
          Text("Keep the glasses awake and wait for the stream.", style: .body)
        }
        .padding(24)
        .background(.card)
      }
    }
  }

  static func emptyAnalysis(
    onStartRecording: @escaping @Sendable () -> Void,
    onAnalyzeAgain: @escaping @Sendable () -> Void
  ) -> FlexBox {
    FlexBox(direction: .column, spacing: 12) {
      FlexBox(direction: .column, spacing: 8) {
        Text("Nothing detected", style: .heading)
        Text("No cards, pot, stack, or player state was captured yet.", style: .body)
        Text("Open display first, then keep the table in view before analyzing.", style: .meta, color: .secondary)
      }
      .padding(24)
      .background(.card)

      FlexBox(direction: .column, spacing: 8) {
        Text("Players --", style: .body)
        Text("Hero --", style: .body)
        Text("Board --", style: .body)
        Text("Pot -- | Stack --", style: .body)
      }
      .padding(24)
      .background(.card)

      FlexBox(direction: .row, spacing: 8, alignment: .center, crossAlignment: .center, wrap: true) {
        Button(label: "Frame table", style: .primary, onClick: onStartRecording)
        Button(label: "Analyze table", style: .secondary, onClick: onAnalyzeAgain)
      }
    }
  }

  static func analyzingTable(
    title: String = "Scanning table",
    subtitle: String = "Reading several glasses camera frames."
  ) -> FlexBox {
    FlexBox(direction: .column, spacing: 12) {
      FlexBox(direction: .column, spacing: 8) {
        Text(title, style: .heading)
        Text(subtitle, style: .body)
        Text("Separating hero cards from board cards.", style: .meta, color: .secondary)
      }
      .padding(24)
      .background(.card)
    }
  }

  static func analyzingDecision(heroCards: String, boardCards: String) -> FlexBox {
    FlexBox(direction: .column, spacing: 12) {
      FlexBox(direction: .column, spacing: 8) {
        Text("Solving spot", style: .heading)
        Text("Hand \(heroCards)", style: .body)
        Text("Board \(boardCards)", style: .body)
        Text("Sending detected state to the poker solver.", style: .meta, color: .secondary)
      }
      .padding(24)
      .background(.card)
    }
  }

  static func cardDetections(
    result: PokerCardDetectionDisplayResult,
    onAnalyzeAgain: @escaping @Sendable () -> Void
  ) -> FlexBox {
    FlexBox(direction: .column, spacing: 12) {
      FlexBox(direction: .column, spacing: 8) {
        Text("Cards: \(result.cards)", style: .heading)
        Text("\(result.count) detections | confidence \(result.averageConfidence)%", style: .body)
        Text("Solver wiring comes next; this is live OCR from the glasses camera.", style: .meta, color: .secondary)
      }
      .padding(24)
      .background(.card)

      FlexBox(direction: .column, spacing: 6) {
        Text(result.details[safe: 0] ?? "--", style: .body)
        Text(result.details[safe: 1] ?? "--", style: .body)
        Text(result.details[safe: 2] ?? "--", style: .body)
        Text(result.details[safe: 3] ?? "--", style: .body)
      }
      .padding(24)
      .background(.card)

      FlexBox(direction: .row, spacing: 8, alignment: .center, crossAlignment: .center) {
        Button(label: "Analyze again", style: .primary, onClick: onAnalyzeAgain)
      }
    }
  }

  static func tableState(
    result: PokerVisionStateDisplayResult,
    isDecisionReady: Bool,
    onScanHand: @escaping @Sendable () -> Void = {},
    onStartRecording: @escaping @Sendable () -> Void = {},
    onAnalyzeTable: @escaping @Sendable () -> Void,
    onGetDecision: @escaping @Sendable () -> Void
  ) -> FlexBox {
    FlexBox(direction: .column, spacing: 12) {
      FlexBox(direction: .column, spacing: 8) {
        Text(result.status, style: .heading)
        Text("Hand \(result.heroCards)", style: .body)
        Text("Board \(result.boardCards)", style: .body)
        Text(isDecisionReady ? "Decision ready" : "Need hand + flop/turn/river", style: .meta, color: .secondary)
        Text("Confidence \(result.confidence)%", style: .meta, color: .secondary)
      }
      .padding(24)
      .background(.card)

      FlexBox(direction: .row, spacing: 8, alignment: .center, crossAlignment: .center, wrap: true) {
        Button(label: "Scan hand", style: .secondary, onClick: onScanHand)
        Button(label: "Record table", style: .secondary, onClick: onStartRecording)
        Button(label: "Rescan table", style: .secondary, onClick: onAnalyzeTable)
        Button(label: isDecisionReady ? "Get decision" : "Decision locked", style: isDecisionReady ? .primary : .secondary, onClick: onGetDecision)
      }
    }
  }

  static func solverResult(
    result: PokerSolverDisplayResult,
    onStartRecording: @escaping @Sendable () -> Void,
    onAnalyzeAgain: @escaping @Sendable () -> Void
  ) -> FlexBox {
    FlexBox(direction: .column, spacing: 12) {
      FlexBox(direction: .column, spacing: 8) {
        Text("Best: \(result.primary)", style: .heading)
        Text(result.secondary, style: .body)
        Text("Hero \(result.heroCards)", style: .body)
        Text("Board \(result.boardCards)", style: .body)
      }
      .padding(24)
      .background(.card)

      FlexBox(direction: .row, spacing: 8, alignment: .center, crossAlignment: .center, wrap: true) {
        Button(label: "Rescan table", style: .secondary, onClick: onStartRecording)
        Button(label: "Get decision", style: .primary, onClick: onAnalyzeAgain)
      }
    }
  }

  static func solverError(
    message: String,
    onStartRecording: @escaping @Sendable () -> Void,
    onRetry: @escaping @Sendable () -> Void
  ) -> FlexBox {
    FlexBox(direction: .column, spacing: 12) {
      FlexBox(direction: .column, spacing: 8) {
        Text("Solver error", style: .heading)
        Text(message, style: .body)
        Text("Check network or solver API, then retry.", style: .meta, color: .secondary)
      }
      .padding(24)
      .background(.card)

      FlexBox(direction: .row, spacing: 8, alignment: .center, crossAlignment: .center, wrap: true) {
        Button(label: "Rescan table", style: .secondary, onClick: onStartRecording)
        Button(label: "Retry", style: .primary, onClick: onRetry)
      }
    }
  }

  static func result(
    snapshot: PokerTableSnapshot,
    onStartRecording: @escaping @Sendable () -> Void,
    onAnalyzeAgain: @escaping @Sendable () -> Void
  ) -> FlexBox {
    FlexBox(direction: .column, spacing: 12) {
      FlexBox(direction: .column, spacing: 8) {
        Text("Best: \(snapshot.bestAction) \(snapshot.raiseAmount)", style: .heading)
        Text("Players \(snapshot.players) | Pot \(snapshot.pot) | Stack \(snapshot.heroStack)", style: .meta, color: .secondary)
        Text("Hero \(snapshot.heroCards)", style: .body)
        Text("Board \(snapshot.boardCards)", style: .body)
      }
      .padding(24)
      .background(.card)

      FlexBox(direction: .column, spacing: 8) {
        Text(actionBar(label: "Fold", percent: snapshot.foldPercent), style: .body)
        Text(actionBar(label: "Call", percent: snapshot.callPercent), style: .body)
        Text(actionBar(label: "Raise", percent: snapshot.raisePercent), style: .body)
        Text("Confidence \(snapshot.confidence)%", style: .meta, color: .secondary)
      }
      .padding(24)
      .background(.card)

      FlexBox(direction: .row, spacing: 8, alignment: .center, crossAlignment: .center, wrap: true) {
        Button(label: "Rescan table", style: .secondary, onClick: onStartRecording)
        Button(label: "Analyze table", style: .primary, onClick: onAnalyzeAgain)
      }
    }
  }

  private static func actionBar(label: String, percent: Int) -> String {
    let filledCount = max(0, min(10, Int((Double(percent) / 10.0).rounded())))
    let emptyCount = 10 - filledCount
    return "\(label) \(percent)% " + String(repeating: "|", count: filledCount)
      + String(repeating: ".", count: emptyCount)
  }

}

private extension Array {
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
