# Poker Solver API — v1 Contract

This is the **frozen v1 contract** between the three components. Do not change it without all three of us agreeing — breaking changes go to `/v2/solve`.

- Vision team (Person B): produces `POST /v1/solve` request bodies from camera frames.
- Glasses team (Person C): consumes `POST /v1/solve` responses, renders `response.display.primary` on the HUD.
- Backend team (Person A): implements the FastAPI app, wraps DecisionHoldem behind this contract.

## Constraints baked into v1

DecisionHoldem is heads-up no-limit, 200bb deep, 50/100 blinds. That's the only configuration the solver supports. The API rejects anything else.

| | Fixed value |
|---|---|
| Variant | NLHE heads-up |
| Players | 2 |
| Small blind | 50 |
| Big blind | 100 |
| Starting stack | 20000 chips (200 bb) |
| Action vocab | `check`, `call`, `fold`, `allin`, `raise`, `bet` |
| Card format | `<rank><suit>` lowercase suit. Ranks: `2 3 4 5 6 7 8 9 T J Q K A`. Suits: `s c d h`. Example: `As`, `Td`, `2c`, `Kh`. |
| Position codes | `"SB"` = small blind (acts first preflop), `"BB"` = big blind (acts first postflop) |

## Endpoints

### `GET /v1/health`

Liveness check.

**Response 200:**
```json
{ "status": "ok", "mode": "real" }
```
`mode` is `"real"` (DecisionHoldem loaded), `"mock"` (canned responses), or `"loading"` (warming up).

---

### `GET /v1/info`

Self-documenting endpoint so clients don't have to hard-code constants.

**Response 200:**
```json
{
  "solver": "decisionholdem",
  "version": "v1",
  "mode": "real",
  "variant": "nlhe_hu",
  "constants": {
    "small_blind": 50,
    "big_blind": 100,
    "starting_stack": 20000,
    "num_players": 2
  },
  "action_vocab": ["check", "call", "fold", "allin", "raise", "bet"],
  "card_format": "<rank><suit>",
  "position_codes": { "SB": 1, "BB": 0 }
}
```

---

### `POST /v1/solve`

Solve the current spot. Returns the action DecisionHoldem recommends.

#### Request body

```json
{
  "hero": {
    "position": "SB",
    "hole_cards": ["As", "Kd"]
  },
  "board": ["Kh", "8c", "3s"],
  "history": [
    {"street": "preflop", "actor": "SB", "action": "raise", "to": 250},
    {"street": "preflop", "actor": "BB", "action": "call"},
    {"street": "flop",    "actor": "BB", "action": "check"},
    {"street": "flop",    "actor": "SB", "action": "bet",   "to": 250}
  ],
  "options": {
    "sample_frequencies": 1,
    "timeout_ms": 5000
  }
}
```

##### Field rules

| Field | Type | Required | Notes |
|---|---|---|---|
| `hero.position` | `"SB"` \| `"BB"` | yes | Hero's position. |
| `hero.hole_cards` | `[card, card]` | yes | Exactly 2 cards. Suit-rank format. |
| `board` | `[]` \| `[card,card,card]` \| `[c,c,c,c]` \| `[c,c,c,c,c]` | yes | 0/3/4/5 cards. Empty = preflop. |
| `history` | `Action[]` | yes | Ordered list since hand start. Empty = bot is first to act. |
| `options.sample_frequencies` | int 1-20 | no, default 1 | 1 = single `getdecision()` call (cheap). >1 = call N times, aggregate. Each extra sample multiplies latency. |
| `options.timeout_ms` | int | no, default 10000 | Server-side abort after this many ms. |

##### Action object

```json
{
  "street": "preflop" | "flop" | "turn" | "river",
  "actor":  "SB" | "BB",
  "action": "check" | "call" | "fold" | "allin" | "raise" | "bet",
  "to":     <int, optional>
}
```

- `to` is required for `raise` and `bet`. It is the **total chips that actor has committed on this street** after the action (matches DecisionHoldem's native `"raise N"` semantics).
- `to` is **omitted or 0** for `check`, `call`, `fold`, `allin`.
- `bet` is treated identically to `raise` by the solver; we keep both vocab entries because that's how humans talk about poker.

Cards already used in `hero.hole_cards` MUST NOT appear in `board`. The server validates.

#### Response 200

```json
{
  "request_id": "01HXYZ...",
  "latency_ms": 873,
  "solver": "decisionholdem",
  "mode": "real",
  "action": {
    "verb": "raise",
    "to": 825,
    "raw": "raise 825"
  },
  "alternatives": null,
  "display": {
    "primary": "RAISE 8.25bb",
    "secondary": null,
    "color_hint": "green"
  }
}
```

##### Field rules

| Field | Notes |
|---|---|
| `request_id` | ULID, unique per request. Echo back in logs/errors. |
| `latency_ms` | Wall-clock server time spent on the solve. |
| `mode` | `"real"`, `"mock"`, `"cached"`. |
| `action.verb` | One of: `check`, `call`, `fold`, `allin`, `raise`, `bet`. Matches action vocab. |
| `action.to` | Total chips hero would commit on this street after the action. 0 for non-sizing actions. |
| `action.raw` | Exactly what the .so returned, for debugging. |
| `alternatives` | `null` unless `options.sample_frequencies > 1`. See below. |
| `display.primary` | Short string preformatted for glasses HUD. Max 16 chars. |
| `display.secondary` | Optional sub-line. Null if not needed. Max 12 chars. |
| `display.color_hint` | `"green"` (aggressive), `"yellow"` (passive), `"red"` (fold). Glasses can ignore. |

When `options.sample_frequencies > 1`:
```json
"alternatives": [
  { "verb": "raise", "to": 825, "count": 6, "frequency": 0.60 },
  { "verb": "check", "to": 0,   "count": 4, "frequency": 0.40 }
],
"display": { "primary": "RAISE 8.25bb", "secondary": "60%", "color_hint": "green" }
```

Frequencies are **estimates from sampling**, not true GTO mixed-strategy weights. DecisionHoldem does not expose true frequencies; we approximate by calling `getdecision()` N times. Document this in your UI.

#### Errors

Single envelope, HTTP status indicates class:

```json
{
  "error": {
    "code": "INVALID_HISTORY",
    "message": "Action 'bet 100000' exceeds player stack (current commitment 19800)",
    "request_id": "01HXYZ..."
  }
}
```

| HTTP | Code | When |
|---|---|---|
| 400 | `INVALID_HOLE_CARDS` | Wrong count, duplicate, or malformed. |
| 400 | `INVALID_BOARD` | Count not in {0,3,4,5}, duplicate, or conflicts with hole cards. |
| 400 | `INVALID_HISTORY` | Action ordering, sizing, or street transition is impossible. |
| 400 | `UNSUPPORTED_CONFIG` | Asked for 6-max, different blinds, etc. |
| 408 | `SOLVER_TIMEOUT` | `getdecision()` exceeded `options.timeout_ms`. |
| 429 | `RATE_LIMITED` | Too many concurrent solves. |
| 503 | `SOLVER_UNAVAILABLE` | .so not loaded, or data files missing. |
| 503 | `SOLVER_BUSY` | All worker processes busy. Client should retry. |

## What this API does NOT expose

These are intentional omissions, not bugs:

| Field clients will ask for | Why omitted |
|---|---|
| `ev_bb` per action | DecisionHoldem doesn't expose EV at the C ABI. |
| `equity` / hand strength | Not exposed. |
| `opponent_range` | Internal only. |
| True GTO frequencies | Use `sample_frequencies` for estimates. |
| 6-max / multi-way | Bot is HU-only. |
| Different stack depths / blinds | Blueprint is trained for 200bb @ 50/100. |
| Mid-hand session save/restore | No serialization in the .so. |

## Examples

See `examples/`:
- `request_preflop_first_to_act.json`
- `request_flop_facing_bet.json`
- `request_river_check_decision.json`
- `response_single_action.json`
- `response_with_frequencies.json`
- `response_error.json`

Curl one-liner against local dev:
```bash
curl -s -X POST http://localhost:8000/v1/solve \
  -H 'Content-Type: application/json' \
  -d @contracts/examples/request_flop_facing_bet.json | jq
```
