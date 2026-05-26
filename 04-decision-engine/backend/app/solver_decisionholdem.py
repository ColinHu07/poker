"""Real DecisionHoldem solver via ctypes. Loads AlascasiaHoldem.so.

Currently a stub: raises SolverUnavailable if the .so or required data files
are missing. Wired identically to solver_mock so we can flip modes with an
env var once the Baidu data files arrive.
"""
from __future__ import annotations
import os
from ctypes import CDLL, c_char_p, c_int
from pathlib import Path
from .schemas import (
    ActionResult,
    ActionVerb,
    Alternative,
    Display,
    SolveRequest,
    Position,
    Street,
)

REPO_ROOT = Path(__file__).resolve().parents[2]
POKER_AI_DIR = REPO_ROOT / "DecisionHoldem" / "PokerAI"
SO_PATH = POKER_AI_DIR / "AlascasiaHoldem.so"
REQUIRED_DATA_FILES = [
    "sevencards_strength.bin",
    "preflop_hand_cluster.bin",
    "blueprint_strategy.dat",
]
# Hard-coded paths inside the .so the maintainer baked in.
HARDCODED_DATA_DIR = Path("/home/zhouqibin/projects/PokerAI/cluster")

SUITS = "scdh"
RANKS = "23456789TJQKA"


class SolverUnavailable(RuntimeError):
    pass


def _card_to_idx(card: str) -> int:
    return SUITS.index(card[1]) * 13 + RANKS.index(card[0])


def _check_environment() -> None:
    if not SO_PATH.exists():
        raise SolverUnavailable(f".so missing at {SO_PATH}")
    cluster = POKER_AI_DIR / "cluster"
    missing = [f for f in REQUIRED_DATA_FILES if not (cluster / f).exists()]
    if missing:
        raise SolverUnavailable(
            f"cluster data files missing: {missing}. Get them from Baidu Netdisk "
            f"(see DecisionHoldem README) and place in {cluster}"
        )
    if not HARDCODED_DATA_DIR.exists():
        raise SolverUnavailable(
            f"the .so has hardcoded paths at {HARDCODED_DATA_DIR}. "
            f"Run: sudo mkdir -p {HARDCODED_DATA_DIR.parent} && "
            f"sudo ln -s {cluster.resolve()} {HARDCODED_DATA_DIR}"
        )


class DecisionHoldemSolver:
    def __init__(self) -> None:
        _check_environment()
        os.chdir(POKER_AI_DIR)  # .so resolves cluster/ relative to cwd
        self._lib = CDLL(str(SO_PATH))
        self._lib.restart_game.argtypes = [c_int, c_int, c_int]
        self._lib.restart_game.restype = None
        self._lib.Next_stage.argtypes = [c_int, c_char_p]
        self._lib.Next_stage.restype = None
        self._lib.opp_take_action.argtypes = [c_char_p]
        self._lib.opp_take_action.restype = None
        self._lib.getdecision.argtypes = [c_char_p]
        self._lib.getdecision.restype = None

    def solve(self, req: SolveRequest) -> tuple[ActionResult, list[Alternative] | None, Display]:
        my_pos = 1 if req.hero.position == Position.SB else 0
        c1 = _card_to_idx(req.hero.hole_cards[0])
        c2 = _card_to_idx(req.hero.hole_cards[1])
        self._lib.restart_game(my_pos ^ 1, c1, c2)

        current_street = Street.PREFLOP
        flop_dealt = turn_dealt = river_dealt = False

        for entry in req.history:
            if entry.street != current_street:
                if entry.street == Street.FLOP and not flop_dealt:
                    cards = bytes(_card_to_idx(c) for c in req.board[:3])
                    self._lib.Next_stage(1, cards)
                    flop_dealt = True
                elif entry.street == Street.TURN and not turn_dealt:
                    cards = bytes(_card_to_idx(c) for c in req.board[:4])
                    self._lib.Next_stage(2, cards)
                    turn_dealt = True
                elif entry.street == Street.RIVER and not river_dealt:
                    cards = bytes(_card_to_idx(c) for c in req.board[:5])
                    self._lib.Next_stage(3, cards)
                    river_dealt = True
                current_street = entry.street

            verb = entry.action.value
            if verb in ("raise", "bet") and entry.to is not None:
                action_str = f"raise {entry.to}"
            else:
                action_str = verb
            self._lib.opp_take_action(action_str.encode())

        buf = bytes(20)
        self._lib.getdecision(buf)
        raw = buf.decode("utf-8").rstrip("\x00").strip()

        if raw.startswith("raise"):
            parts = raw.split()
            verb = ActionVerb.RAISE
            to = int(parts[1]) if len(parts) > 1 else 0
        else:
            verb = ActionVerb(raw)
            to = 0

        action = ActionResult(verb=verb, to=to, raw=raw)
        bb = to / 100
        primary = action.verb.value.upper() if to == 0 else f"{action.verb.value.upper()} {bb:.2g}bb"
        color = "red" if verb == ActionVerb.FOLD else "yellow" if verb in (ActionVerb.CHECK, ActionVerb.CALL) else "green"
        display = Display(primary=primary[:16], color_hint=color)
        return action, None, display


_singleton: DecisionHoldemSolver | None = None


def get_solver() -> DecisionHoldemSolver:
    global _singleton
    if _singleton is None:
        _singleton = DecisionHoldemSolver()
    return _singleton
