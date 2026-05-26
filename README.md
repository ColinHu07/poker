# PokerVision

PokerVision is a consent-based training prototype built on the Meta Wearables DAT
iOS SDK. It streams a frame from Meta glasses or the phone camera, turns the visible
poker table into structured state, and then feeds that state into a local trainer.

The repo is organized around the two-step system we want to build:

1. `01-world-to-state/` - bring human/table information into the computer.
2. `02-ocr-that-plays/` - use OCR/parsed state to evaluate the hand and produce a play.
3. `03-display-ui/` - show the smallest useful phone/glasses interface.

The iOS app lives in `PokerVision/` and currently contains both layers while the
prototype is still small. The root folders describe the boundaries and point to the
source files that belong to each layer.

## Current Milestone

The first useful "Analyze" pass should read:

- number of players
- hero cards
- pot size
- hero stack / money

After that is stable, the trainer can safely add board cards, actions, odds, and
recommended decisions.

## Open The App

Open `PokerVision.xcodeproj` and run the `PokerVision` scheme.

The project uses Meta Wearables DAT `0.7.0` and links:

- `MWDATCore`
- `MWDATCamera`
- `MWDATDisplay`
- `MWDATMockDevice`

## Safety Scope

This is for sandbox/replay or explicitly consented demo use. It should not be used
for covert real-money play.
