# 02 - OCR That Plays

This layer takes parsed table state and decides what a training/demo player should do.

It answers: given the current state, what is the best action?

## Inputs

- `TableObservation` from `01-world-to-state`
- stabilized `HandState`
- known cards
- pot size
- stack sizes
- visible action history
- confidence scores

## Outputs

The layer should produce one compact recommendation:

```swift
struct Advice {
    let action: PokerTrainerAction
    let amount: Int?
    let winProbability: Double?
    let neededEquity: Double?
    let confidence: Double
    let reason: String
}
```

## Current Source Areas

- `PokerVision/PokerCore/PokerTrainingModels.swift` - shared poker state models.
- `PokerVision/PokerCore/PokerOddsTrainer.swift` - table fusion, odds estimation, and conservative advice.
- `PokerVision/ViewModels/PokerVisionViewModel.swift` - connects parsed observations to the trainer.

## Rules

- Do not recommend a play when the table read is low confidence.
- Prefer `Confirm state` over pretending the OCR is certain.
- Keep all computation local on device for v1.
- Start with conservative Hold'em trainer logic before adding more aggressive bet sizing.
