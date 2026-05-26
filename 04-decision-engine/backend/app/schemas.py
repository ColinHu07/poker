"""Pydantic models mirroring contracts/API.md v1. Single source of truth."""
from __future__ import annotations
from enum import Enum
from typing import Literal
from pydantic import BaseModel, Field, field_validator

SMALL_BLIND = 50
BIG_BLIND = 100
STARTING_STACK = 20_000
RANKS = "23456789TJQKA"
SUITS = "scdh"


class Position(str, Enum):
    SB = "SB"
    BB = "BB"


class Street(str, Enum):
    PREFLOP = "preflop"
    FLOP = "flop"
    TURN = "turn"
    RIVER = "river"


class ActionVerb(str, Enum):
    CHECK = "check"
    CALL = "call"
    FOLD = "fold"
    ALLIN = "allin"
    RAISE = "raise"
    BET = "bet"


def _validate_card(card: str) -> str:
    if len(card) != 2 or card[0] not in RANKS or card[1] not in SUITS:
        raise ValueError(f"bad card '{card}', expected rank+suit e.g. 'As'")
    return card


class Hero(BaseModel):
    model_config = {"extra": "forbid"}
    position: Position
    hole_cards: list[str] = Field(min_length=2, max_length=2)

    @field_validator("hole_cards")
    @classmethod
    def _cards_ok(cls, v: list[str]) -> list[str]:
        out = [_validate_card(c) for c in v]
        if len(set(out)) != 2:
            raise ValueError("hole cards must be distinct")
        return out


class HistoryEntry(BaseModel):
    model_config = {"extra": "forbid"}
    street: Street
    actor: Position
    action: ActionVerb
    to: int | None = Field(default=None, ge=0, le=STARTING_STACK)


class SolveOptions(BaseModel):
    model_config = {"extra": "forbid"}
    sample_frequencies: int = Field(default=1, ge=1, le=20)
    timeout_ms: int = Field(default=10_000, ge=100, le=60_000)


class SolveRequest(BaseModel):
    model_config = {"extra": "forbid"}
    hero: Hero
    board: list[str] = Field(default_factory=list)
    history: list[HistoryEntry] = Field(default_factory=list)
    options: SolveOptions = Field(default_factory=SolveOptions)

    @field_validator("board")
    @classmethod
    def _board_ok(cls, v: list[str]) -> list[str]:
        if len(v) not in (0, 3, 4, 5):
            raise ValueError(f"board must have 0, 3, 4, or 5 cards (got {len(v)})")
        out = [_validate_card(c) for c in v]
        if len(set(out)) != len(out):
            raise ValueError("board has duplicate cards")
        return out


class ActionResult(BaseModel):
    verb: ActionVerb
    to: int = Field(ge=0, le=STARTING_STACK)
    raw: str


class Alternative(BaseModel):
    verb: ActionVerb
    to: int = Field(ge=0, le=STARTING_STACK)
    count: int = Field(ge=1)
    frequency: float = Field(ge=0.0, le=1.0)


class Display(BaseModel):
    primary: str = Field(max_length=16)
    secondary: str | None = Field(default=None, max_length=12)
    color_hint: Literal["green", "yellow", "red"] = "green"


class SolveResponse(BaseModel):
    request_id: str
    latency_ms: int
    solver: Literal["decisionholdem", "heuristic"]
    mode: Literal["real", "mock", "cached"]
    action: ActionResult
    alternatives: list[Alternative] | None = None
    display: Display


ErrorCode = Literal[
    "INVALID_HOLE_CARDS",
    "INVALID_BOARD",
    "INVALID_HISTORY",
    "UNSUPPORTED_CONFIG",
    "SOLVER_TIMEOUT",
    "RATE_LIMITED",
    "SOLVER_UNAVAILABLE",
    "SOLVER_BUSY",
]


class ErrorBody(BaseModel):
    code: ErrorCode
    message: str
    request_id: str | None = None


class ErrorResponse(BaseModel):
    error: ErrorBody
