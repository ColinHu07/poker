/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import MWDATDisplay

struct PokerDecisionDisplayResult {
  let primary: String
  let secondary: String
  let colorHint: String
  let heroCards: String
  let boardCards: String
}

struct PokerVisionStateDisplayResult {
  let heroCards: String
  let boardCards: String
  let status: String
  let confidence: Int
}

enum PokerVisionDisplay {
  static func ready(
    onTakeImage: @escaping @Sendable () -> Void = {},
    onAnalyzeTable: @escaping @Sendable () -> Void,
    onGetDecision: @escaping @Sendable () -> Void
  ) -> FlexBox {
    FlexBox(direction: .column, spacing: 12) {
      FlexBox(direction: .column, spacing: 8) {
        Text("PokerVision", style: .heading)
        Text("Take one photo, then run prediction.", style: .body)
        Text("Phone analyzes the captured image.", style: .meta, color: .secondary)
      }
      .padding(24)
      .background(.card)

      FlexBox(direction: .row, spacing: 8, alignment: .center, crossAlignment: .center, wrap: true) {
        Button(label: "Take image", style: .primary, onClick: onTakeImage)
        Button(label: "Run prediction", style: .primary, onClick: onAnalyzeTable)
      }
    }
  }

  static func analyzingTable(
    title: String = "Reading image",
    subtitle: String = "Processing the captured glasses photo.",
    status: String = "Reading camera"
  ) -> FlexBox {
    FlexBox(direction: .column, spacing: 12) {
      FlexBox(direction: .column, spacing: 8) {
        Text(title, style: .heading)
        Text(subtitle, style: .body)
        Text(status, style: .meta, color: .secondary)
      }
      .padding(24)
      .background(.card)
    }
  }

  static func analyzingDecision(heroCards: String, boardCards: String) -> FlexBox {
    FlexBox(direction: .column, spacing: 12) {
      FlexBox(direction: .column, spacing: 8) {
        Text("Choosing action", style: .heading)
        Text("Hand \(heroCards)", style: .body)
        Text("Board \(boardCards)", style: .body)
        Text("Calculating from the captured image.", style: .meta, color: .secondary)
      }
      .padding(24)
      .background(.card)
    }
  }

  static func tableState(
    result: PokerVisionStateDisplayResult,
    isDecisionReady: Bool,
    onTakeImage: @escaping @Sendable () -> Void = {},
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
        Button(label: "Take image", style: .secondary, onClick: onTakeImage)
        Button(label: isDecisionReady ? "Run prediction" : "Prediction locked", style: isDecisionReady ? .primary : .secondary, onClick: onGetDecision)
      }
    }
  }

  static func decisionResult(
    result: PokerDecisionDisplayResult,
    onRetakeImage: @escaping @Sendable () -> Void,
    onAnalyzeAgain: @escaping @Sendable () -> Void
  ) -> FlexBox {
    FlexBox(direction: .column, spacing: 12) {
      FlexBox(direction: .column, spacing: 8) {
        Text("Best action", style: .meta, color: .secondary)
        Text(result.primary, style: .heading)
        Text(result.secondary, style: .meta, color: .secondary)
        Text("Hand \(result.heroCards)", style: .body)
        Text("Board \(result.boardCards)", style: .body)
      }
      .padding(24)
      .background(.card)

      FlexBox(direction: .row, spacing: 8, alignment: .center, crossAlignment: .center, wrap: true) {
        Button(label: "Take image", style: .secondary, onClick: onRetakeImage)
        Button(label: "Get decision", style: .primary, onClick: onAnalyzeAgain)
      }
    }
  }

  static func decisionError(
    message: String,
    onRetakeImage: @escaping @Sendable () -> Void,
    onRetry: @escaping @Sendable () -> Void
  ) -> FlexBox {
    FlexBox(direction: .column, spacing: 12) {
      FlexBox(direction: .column, spacing: 8) {
        Text("Decision error", style: .heading)
        Text(message, style: .body)
        Text("Take another image or retry analysis.", style: .meta, color: .secondary)
      }
      .padding(24)
      .background(.card)

      FlexBox(direction: .row, spacing: 8, alignment: .center, crossAlignment: .center, wrap: true) {
        Button(label: "Take image", style: .secondary, onClick: onRetakeImage)
        Button(label: "Retry", style: .primary, onClick: onRetry)
      }
    }
  }

}
