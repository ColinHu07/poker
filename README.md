# PokerVision

PokerVision is a consent-based training prototype built on the Meta Wearables DAT
iOS SDK. It streams frames from Meta display glasses, turns the visible poker table
into structured state, and feeds that state into the solver/advice layer.

The repo is organized around the two-step system we want to build:

1. `01-world-to-state/` - bring human/table information into the computer.
2. `02-ocr-that-plays/` - use OCR/parsed state to evaluate the hand and produce a play.
3. `03-display-ui/` - show the smallest useful phone/glasses interface.

## Active iOS App

The app currently being tested on device is:

`apps/DisplayAccessPokerVision/DisplayAccess.xcodeproj`

This is the Meta DisplayAccess sample converted into PokerVision. It is the
"car icon" app from the Meta sample, now with PokerVision UI, glasses display
mirroring, glasses camera preview, card detection overlays, table-state capture,
and solver API integration.

The older native prototype is still kept at `PokerVision.xcodeproj` for reference,
but it is not the app we are actively testing right now.

## Current Milestone

The first useful "Analyze" pass should read:

- number of players
- hero cards
- pot size
- hero stack / money

After that is stable, the trainer can safely add board cards, actions, odds, and
recommended decisions.

## Open The App

Open `apps/DisplayAccessPokerVision/DisplayAccess.xcodeproj` and run the
`DisplayAccess` scheme.

If iOS shows multiple apps named PokerVision, keep the car-icon one from this
DisplayAccess project and delete the older camera-icon installs from the phone.

The active app uses Meta Wearables DAT `0.7.0` and links:

- `MWDATCore`
- `MWDATCamera`
- `MWDATDisplay`
- `MWDATMockDevice`

## Safety Scope

This is for sandbox/replay or explicitly consented demo use. It should not be used
for covert real-money play.
