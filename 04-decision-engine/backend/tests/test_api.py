"""End-to-end tests against a running solver. Set API_URL env to target.

Usage:
    API_URL=http://44.211.131.130:8000 uv run pytest tests/test_api.py -v
"""
from __future__ import annotations
import os
import httpx
import pytest

API_URL = os.environ.get("API_URL", "http://localhost:8000")
TIMEOUT = 120.0  # postflop CFR subgame solves can take 30-90s on tough spots


@pytest.fixture(scope="session")
def client():
    with httpx.Client(base_url=API_URL, timeout=TIMEOUT) as c:
        yield c


# ── Health / info ──────────────────────────────────────────────────────────

def test_health(client):
    r = client.get("/v1/health")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok"
    assert body["solver"] in ("decisionholdem", "heuristic")


def test_info(client):
    r = client.get("/v1/info")
    assert r.status_code == 200
    b = r.json()
    assert b["variant"] == "nlhe_hu"
    assert b["constants"] == {
        "small_blind": 50,
        "big_blind": 100,
        "starting_stack": 20000,
        "num_players": 2,
    }
    assert "raise" in b["action_vocab"]
    assert b["position_codes"] == {"SB": 1, "BB": 0}


# ── Happy-path solves ──────────────────────────────────────────────────────

def _solve(client, **kwargs):
    body = {
        "hero": kwargs["hero"],
        "board": kwargs.get("board", []),
        "history": kwargs.get("history", []),
    }
    if "options" in kwargs:
        body["options"] = kwargs["options"]
    return client.post("/v1/solve", json=body)


def _assert_valid_response(r):
    assert r.status_code == 200, r.text
    b = r.json()
    assert b["solver"] in ("decisionholdem", "heuristic")
    assert b["mode"] in ("real", "mock", "cached")
    assert b["action"]["verb"] in ("check", "call", "fold", "allin", "raise", "bet")
    assert isinstance(b["action"]["to"], int)
    assert 0 <= b["action"]["to"] <= 20000
    assert isinstance(b["display"]["primary"], str)
    assert len(b["display"]["primary"]) <= 16
    return b


def test_preflop_sb_first_to_act(client):
    r = _solve(client, hero={"position": "SB", "hole_cards": ["As", "Kd"]})
    b = _assert_valid_response(r)
    assert b["action"]["verb"] in ("raise", "call", "fold", "allin")


def test_preflop_bb_facing_raise(client):
    r = _solve(
        client,
        hero={"position": "BB", "hole_cards": ["Qh", "Qd"]},
        history=[{"street": "preflop", "actor": "SB", "action": "raise", "to": 250}],
    )
    _assert_valid_response(r)


def test_flop_facing_check(client):
    r = _solve(
        client,
        hero={"position": "SB", "hole_cards": ["As", "Kd"]},
        board=["Kh", "8c", "3s"],
        history=[
            {"street": "preflop", "actor": "SB", "action": "raise", "to": 250},
            {"street": "preflop", "actor": "BB", "action": "call"},
            {"street": "flop", "actor": "BB", "action": "check"},
        ],
    )
    _assert_valid_response(r)


def test_turn_after_flop_bet_call(client):
    r = _solve(
        client,
        hero={"position": "SB", "hole_cards": ["As", "Kd"]},
        board=["Kh", "8c", "3s", "2d"],
        history=[
            {"street": "preflop", "actor": "SB", "action": "raise", "to": 250},
            {"street": "preflop", "actor": "BB", "action": "call"},
            {"street": "flop", "actor": "BB", "action": "check"},
            {"street": "flop", "actor": "SB", "action": "bet", "to": 250},
            {"street": "flop", "actor": "BB", "action": "call"},
            {"street": "turn", "actor": "BB", "action": "check"},
        ],
    )
    _assert_valid_response(r)


def test_river_decision(client):
    r = _solve(
        client,
        hero={"position": "SB", "hole_cards": ["As", "Kd"]},
        board=["Kh", "8c", "3s", "2d", "7h"],
        history=[
            {"street": "preflop", "actor": "SB", "action": "raise", "to": 250},
            {"street": "preflop", "actor": "BB", "action": "call"},
            {"street": "flop", "actor": "BB", "action": "check"},
            {"street": "flop", "actor": "SB", "action": "bet", "to": 250},
            {"street": "flop", "actor": "BB", "action": "call"},
            {"street": "turn", "actor": "BB", "action": "check"},
            {"street": "turn", "actor": "SB", "action": "bet", "to": 500},
            {"street": "turn", "actor": "BB", "action": "call"},
            {"street": "river", "actor": "BB", "action": "check"},
        ],
    )
    _assert_valid_response(r)


def test_facing_3bet(client):
    r = _solve(
        client,
        hero={"position": "SB", "hole_cards": ["Ah", "Kh"]},
        history=[
            {"street": "preflop", "actor": "SB", "action": "raise", "to": 250},
            {"street": "preflop", "actor": "BB", "action": "raise", "to": 800},
        ],
    )
    _assert_valid_response(r)


# ── Validation errors ─────────────────────────────────────────────────────

def test_bad_card_format(client):
    r = client.post(
        "/v1/solve",
        json={
            "hero": {"position": "SB", "hole_cards": ["AAA", "Kd"]},
            "board": [],
            "history": [],
        },
    )
    assert r.status_code == 400
    assert r.json()["error"]["code"] in ("INVALID_HOLE_CARDS", "INVALID_HISTORY")


def test_duplicate_hole_cards(client):
    r = client.post(
        "/v1/solve",
        json={
            "hero": {"position": "SB", "hole_cards": ["As", "As"]},
            "board": [],
            "history": [],
        },
    )
    assert r.status_code == 400


def test_board_overlaps_hole(client):
    r = client.post(
        "/v1/solve",
        json={
            "hero": {"position": "SB", "hole_cards": ["As", "Kd"]},
            "board": ["As", "8c", "3s"],
            "history": [],
        },
    )
    assert r.status_code == 400
    assert r.json()["error"]["code"] == "INVALID_BOARD"


def test_wrong_board_size(client):
    r = client.post(
        "/v1/solve",
        json={
            "hero": {"position": "SB", "hole_cards": ["As", "Kd"]},
            "board": ["Kh", "8c"],  # 2 cards: not 0/3/4/5
            "history": [],
        },
    )
    assert r.status_code == 400


def test_unknown_position(client):
    r = client.post(
        "/v1/solve",
        json={
            "hero": {"position": "BTN", "hole_cards": ["As", "Kd"]},
            "board": [],
            "history": [],
        },
    )
    assert r.status_code == 400


# ── Latency / behavior signals ────────────────────────────────────────────

def test_preflop_latency_under_1s(client):
    r = _solve(client, hero={"position": "SB", "hole_cards": ["Ah", "As"]})
    b = _assert_valid_response(r)
    assert b["latency_ms"] < 1000, f"preflop too slow: {b['latency_ms']}ms"


def test_premium_hand_is_aggressive(client):
    """Pocket aces should never just check/fold preflop facing nothing."""
    r = _solve(client, hero={"position": "SB", "hole_cards": ["As", "Ah"]})
    b = _assert_valid_response(r)
    assert b["action"]["verb"] in ("raise", "allin"), f"AA played as {b['action']['verb']}"


def test_garbage_hand_preflop(client):
    """72o vs nothing — heuristic should fold or open small; solver may mix."""
    r = _solve(client, hero={"position": "SB", "hole_cards": ["7d", "2c"]})
    _assert_valid_response(r)
