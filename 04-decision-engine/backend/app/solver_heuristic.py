"""Heuristic HUNL solver. Real poker logic — not superhuman, not a mock.

Strategy:
  - Preflop: hand strength via Chen formula + HU 200bb opening logic
  - Postflop: Monte Carlo equity vs random hand using treys, threshold-based
    bet/check/fold decisions with size based on equity bucket.

Swap to DecisionHoldem by setting SOLVER=decisionholdem once the Baidu weights
are in place.
"""
from __future__ import annotations
import random
from treys import Card, Evaluator

from .schemas import (
    ActionResult,
    ActionVerb,
    Alternative,
    Display,
    HistoryEntry,
    Position,
    SolveRequest,
    Street,
    BIG_BLIND,
    STARTING_STACK,
)

_EVAL = Evaluator()
_FULL_DECK = [r + s for r in "23456789TJQKA" for s in "shdc"]


def _equity_vs_random(hero: list[str], board: list[str], samples: int = 800) -> float:
    hero_t = [Card.new(c) for c in hero]
    board_t = [Card.new(c) for c in board]
    used = set(hero + board)
    pool = [c for c in _FULL_DECK if c not in used]
    rng = random.Random(hash(tuple(hero) + tuple(board)) & 0xFFFFFFFF)

    wins = 0.0
    cards_needed = 2 + (5 - len(board))
    for _ in range(samples):
        rng.shuffle(pool)
        villain = [Card.new(c) for c in pool[:2]]
        runout = [Card.new(c) for c in pool[2 : 2 + (5 - len(board))]]
        full_board = board_t + runout
        h = _EVAL.evaluate(full_board, hero_t)
        v = _EVAL.evaluate(full_board, villain)
        if h < v:
            wins += 1
        elif h == v:
            wins += 0.5
    return wins / samples


def _chen_score(hole: list[str]) -> float:
    """Approximate preflop hand strength (Bill Chen's formula). Higher = better."""
    rank_vals = {"A": 10, "K": 8, "Q": 7, "J": 6, "T": 5}
    r1, r2 = hole[0][0], hole[1][0]
    s1, s2 = hole[0][1], hole[1][1]

    def v(r: str) -> float:
        if r in rank_vals:
            return rank_vals[r]
        return int(r) / 2

    score = max(v(r1), v(r2))
    if r1 == r2:
        score = max(5.0, v(r1) * 2)
    if s1 == s2:
        score += 2
    gap = abs("23456789TJQKA".index(r1) - "23456789TJQKA".index(r2))
    if r1 != r2:
        if gap == 1:
            score += 1
        elif gap == 2:
            score -= 1
        elif gap == 3:
            score -= 2
        elif gap >= 4:
            score -= 4
        if gap <= 2 and "23456789T".find(r1) >= 0 and "23456789T".find(r2) >= 0:
            score += 1
    return score


def _hero_committed(history: list[HistoryEntry], position: Position, street: Street) -> int:
    total = 0
    for h in history:
        if h.actor == position and h.street == street and h.to is not None:
            total = h.to
    return total


def _to_call(history: list[HistoryEntry], position: Position, street: Street) -> int:
    hero_in = 0
    villain_in = 0
    for h in history:
        if h.street != street:
            continue
        if h.action in (ActionVerb.RAISE, ActionVerb.BET) and h.to is not None:
            if h.actor == position:
                hero_in = h.to
            else:
                villain_in = h.to
    return max(0, villain_in - hero_in)


def _pot_size(history: list[HistoryEntry]) -> int:
    sb_total = BIG_BLIND // 2
    bb_total = BIG_BLIND
    last_by = {Position.SB: sb_total, Position.BB: bb_total}
    streets_seen = {Street.PREFLOP}
    for h in history:
        if h.street not in streets_seen:
            last_by = {Position.SB: 0, Position.BB: 0}
            streets_seen.add(h.street)
        if h.to is not None and h.action in (ActionVerb.RAISE, ActionVerb.BET):
            last_by[h.actor] = h.to
    return sum(last_by.values()) + 2 * sb_total if Street.PREFLOP in streets_seen and len(streets_seen) == 1 else sum(last_by.values()) + BIG_BLIND + BIG_BLIND // 2


def _format_display(verb: ActionVerb, to: int) -> Display:
    if verb == ActionVerb.FOLD:
        return Display(primary="FOLD", color_hint="red")
    if verb == ActionVerb.CHECK:
        return Display(primary="CHECK", color_hint="yellow")
    if verb == ActionVerb.CALL:
        return Display(primary="CALL", color_hint="yellow")
    if verb == ActionVerb.ALLIN:
        return Display(primary="ALL-IN", color_hint="green")
    bb = to / BIG_BLIND
    return Display(primary=f"{verb.value.upper()} {bb:.2g}bb"[:16], color_hint="green")


def _current_street(req: SolveRequest) -> Street:
    if not req.board:
        return Street.PREFLOP
    if len(req.board) == 3:
        return Street.FLOP
    if len(req.board) == 4:
        return Street.TURN
    return Street.RIVER


def solve(req: SolveRequest) -> tuple[ActionResult, list[Alternative] | None, Display]:
    street = _current_street(req)
    hero_pos = req.hero.position
    facing = _to_call(req.history, hero_pos, street)

    if street == Street.PREFLOP:
        score = _chen_score(req.hero.hole_cards)
        sb_already = BIG_BLIND // 2 if hero_pos == Position.SB else BIG_BLIND

        if facing == 0:
            if score >= 8:
                to = max(BIG_BLIND * 3, sb_already)
                verb = ActionVerb.RAISE
            elif score >= 5:
                to = max(BIG_BLIND * 25 // 10, sb_already)
                verb = ActionVerb.RAISE
            else:
                if hero_pos == Position.SB:
                    verb, to = ActionVerb.FOLD, 0
                else:
                    verb, to = ActionVerb.CHECK, 0
        else:
            if score >= 9:
                to = facing * 3
                verb = ActionVerb.RAISE
            elif score >= 6:
                to = sb_already + facing
                verb = ActionVerb.CALL
            else:
                verb, to = ActionVerb.FOLD, 0
    else:
        equity = _equity_vs_random(req.hero.hole_cards, req.board, samples=600)
        hero_in = _hero_committed(req.history, hero_pos, street)
        pot = max(BIG_BLIND, _pot_size(req.history))

        if facing == 0:
            if equity >= 0.70:
                bet = max(BIG_BLIND, int(pot * 0.75))
                verb, to = ActionVerb.BET, hero_in + bet
            elif equity >= 0.55:
                bet = max(BIG_BLIND, int(pot * 0.40))
                verb, to = ActionVerb.BET, hero_in + bet
            else:
                verb, to = ActionVerb.CHECK, 0
        else:
            pot_odds = facing / (pot + facing)
            if equity >= 0.75:
                raise_to = hero_in + facing + max(BIG_BLIND, int((pot + facing) * 0.75))
                verb, to = ActionVerb.RAISE, raise_to
            elif equity > pot_odds + 0.05:
                verb, to = ActionVerb.CALL, 0
            else:
                verb, to = ActionVerb.FOLD, 0

    to = min(to, STARTING_STACK)
    raw = f"{verb.value} {to}" if verb in (ActionVerb.RAISE, ActionVerb.BET) and to > 0 else verb.value
    action = ActionResult(verb=verb, to=to, raw=raw)
    display = _format_display(verb, to)
    return action, None, display
