# 03 - Display UI

This layer is the user-facing experience for the phone and Meta glasses display.

It should stay simple: the phone can show debug detail, but the glasses should show
only the next useful action.

## Glasses Flow

```text
PokerVision

[ Analyze ]
```

The phone keeps the camera stream running and maintains recent world-state frames.
The glasses button is the trigger:

1. User selects `Analyze` on the display.
2. App freezes the best recent stabilized table state.
3. App runs the decision layer when the state is confident enough.
4. Display switches to the compact decision HUD.

## Decision HUD

```text
Best: Raise $1,500

Fold    8%
Call   20%
Raise  72%

[ Analyze Again ]
```

If the state is not ready:

```text
Look again

Cards unclear
Pot unknown

[ Analyze Again ]
```

## Phone UI

The phone is the debug mirror. It can show:

- stream status
- current table read
- detected cards and counts
- pot and stack OCR
- raw solver output
- confidence warnings

## Current Source Areas

- `PokerVision/ViewModels/PokerDisplayViewModel.swift` - Meta glasses display content.
- `PokerVision/Views/StreamView.swift` - phone stream and debug panel.
- `PokerVision/Views/PokerVisionOverlayView.swift` - phone detection boxes.
- `PokerVision/ViewModels/PokerVisionViewModel.swift` - connects Analyze actions to world-state and decision state.

## UI Rules

- Glasses display should avoid math-heavy explanations.
- The first screen should be one `Analyze` button.
- Decision results should fit in one glance.
- Raise output must include the amount when available.
- Unknown or low-confidence state should say `Look again`, not guess.
