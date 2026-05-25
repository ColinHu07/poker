# PokerVision Pipeline

```text
Meta glasses / phone camera
        |
        v
01-world-to-state
        |
        | TableObservation
        v
State fusion
        |
        | HandState
        v
02-ocr-that-plays
        |
        | Advice
        v
Glasses display + phone debug UI
```

## Build Order

1. Make the table read reliable: players, hero cards, pot, hero stack.
2. Stabilize multiple observations over time.
3. Add board cards and visible actions.
4. Gate advice behind confidence thresholds.
5. Add odds, EV, and bet sizing.
