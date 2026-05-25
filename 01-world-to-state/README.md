# 01 - World To State

This layer brings human/table information into the computer.

It answers: what is visible right now?

## Inputs

- Meta glasses camera frames
- phone camera fallback frames
- captured still frames
- visible cards, text, chips, player seats, and actions

## Outputs

The layer should produce a stable `TableObservation`:

```swift
struct TableObservation {
    let heroCards: [PlayingCard]
    let boardCards: [PlayingCard]
    let seatCount: Int
    let playerActions: [String]
    let chipStacks: [String: Int]
    let pot: Int?
    let heroStack: Int?
    let confidence: Double
}
```

## Current Source Areas

- `PokerVision/Video/` - Meta glasses stream, phone fallback stream, source switching.
- `PokerVision/ViewModels/PokerVisionViewModel.swift` - frame capture, Vision OCR, table parsing, analysis flow.
- `PokerVision/ViewModels/PokerDisplayViewModel.swift` - glasses display "Analyze" button and compact table readout.
- `PokerVision/Views/PokerVisionOverlayView.swift` - phone debug overlay for detections and parsed state.
- `PokerVision/TestResources/` - bundled training frames for repeatable parsing.

## First Target

The first analyze pass should return:

- number of players
- our two cards
- pot size
- our money / stack

If any of those fields are low confidence, this layer should say `Unknown` instead of
guessing.
