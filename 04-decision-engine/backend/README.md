# Solver Backend

HTTP wrapper implementing `contracts/API.md` v1.

## Solvers

| Name | Status | Notes |
|---|---|---|
| `heuristic` | **default** | Chen preflop formula + Monte Carlo postflop equity (`treys`). Real poker logic, ~50 ms/call. |
| `decisionholdem` | disabled | Code wired, but `AlascasiaHoldem.so` won't load until the Baidu Netdisk data files arrive. Flip with `SOLVER=decisionholdem`. |

## Run

```bash
cd backend
uv sync
uv run uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

```bash
curl -s http://localhost:8000/v1/health | jq
curl -s http://localhost:8000/v1/info | jq
curl -s -X POST http://localhost:8000/v1/solve \
  -H 'Content-Type: application/json' \
  -d '{
    "hero": {"position": "SB", "hole_cards": ["As", "Kd"]},
    "board": ["Kh", "8c", "3s"],
    "history": [
      {"street": "preflop", "actor": "SB", "action": "raise", "to": 250},
      {"street": "preflop", "actor": "BB", "action": "call"},
      {"street": "flop",    "actor": "BB", "action": "check"}
    ]
  }' | jq
```

## Switch to DecisionHoldem (when data files arrive)

```bash
SOLVER=decisionholdem uv run uvicorn app.main:app --host 0.0.0.0 --port 8000
```

Requires:
1. Baidu data files (`blueprint_strategy.dat`, `sevencards_strength.bin`, 4 cluster files) in `../DecisionHoldem/PokerAI/cluster/`
2. Symlink: `sudo mkdir -p /home/zhouqibin/projects/PokerAI && sudo ln -s $(realpath ../DecisionHoldem/PokerAI/cluster) /home/zhouqibin/projects/PokerAI/cluster`
3. ~25 GB free RAM
