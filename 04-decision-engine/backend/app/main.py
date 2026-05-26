"""FastAPI entrypoint implementing contracts/API.md v1.

Default solver is the heuristic engine (`solver_heuristic`). DecisionHoldem
is wired but disabled until its Baidu data files arrive. Switch with:
    SOLVER=decisionholdem uv run uvicorn app.main:app
"""
from __future__ import annotations
import os
import secrets as _secrets
import time
from contextlib import asynccontextmanager
from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse
from fastapi.exceptions import RequestValidationError
from ulid import ULID

from . import solver_heuristic
from .schemas import (
    ErrorBody,
    ErrorResponse,
    SMALL_BLIND,
    BIG_BLIND,
    STARTING_STACK,
    SolveRequest,
    SolveResponse,
)

SOLVER_NAME = os.environ.get("SOLVER", "heuristic").lower()
API_KEY = os.environ.get("API_KEY", "").strip()


async def require_api_key(x_api_key: str | None = Header(default=None, alias="X-API-Key")):
    if not API_KEY:
        return  # auth disabled when env var is empty
    if not x_api_key or not _secrets.compare_digest(x_api_key, API_KEY):
        raise HTTPException(status_code=401, detail="invalid or missing X-API-Key header")

active_solver = None
active_solver_error: str | None = None

if SOLVER_NAME == "heuristic":
    active_solver = solver_heuristic
elif SOLVER_NAME == "decisionholdem":
    try:
        from . import solver_decisionholdem
        active_solver = solver_decisionholdem.get_solver()
    except Exception as e:
        active_solver_error = f"decisionholdem disabled: {e}"
else:
    active_solver_error = f"unknown SOLVER='{SOLVER_NAME}', expected 'heuristic' or 'decisionholdem'"


@asynccontextmanager
async def lifespan(app: FastAPI):
    yield


app = FastAPI(title="Poker Solver API", version="1.0.0", lifespan=lifespan)


@app.exception_handler(RequestValidationError)
async def _validation_error(request: Request, exc: RequestValidationError):
    msg = exc.errors()[0]["msg"] if exc.errors() else "invalid request"
    code = "INVALID_HISTORY"
    msg_lower = str(exc).lower()
    if "hole_card" in msg_lower:
        code = "INVALID_HOLE_CARDS"
    elif "board" in msg_lower:
        code = "INVALID_BOARD"
    return JSONResponse(
        status_code=400,
        content=ErrorResponse(error=ErrorBody(code=code, message=msg, request_id=str(ULID()))).model_dump(),
    )


@app.get("/v1/health")
async def health():
    if active_solver is None:
        return {"status": "degraded", "solver": SOLVER_NAME, "reason": active_solver_error}
    return {"status": "ok", "solver": SOLVER_NAME}


@app.get("/v1/info", dependencies=[Depends(require_api_key)])
async def info():
    return {
        "solver": SOLVER_NAME,
        "version": "v1",
        "available_solvers": {
            "heuristic": "enabled — Chen preflop + Monte Carlo equity postflop",
            "decisionholdem": "disabled — awaiting Baidu Netdisk data files",
        },
        "variant": "nlhe_hu",
        "constants": {
            "small_blind": SMALL_BLIND,
            "big_blind": BIG_BLIND,
            "starting_stack": STARTING_STACK,
            "num_players": 2,
        },
        "action_vocab": ["check", "call", "fold", "allin", "raise", "bet"],
        "card_format": "<rank><suit>",
        "position_codes": {"SB": 1, "BB": 0},
    }


@app.post("/v1/solve", response_model=SolveResponse, dependencies=[Depends(require_api_key)])
async def solve(req: SolveRequest):
    request_id = str(ULID())
    start = time.perf_counter()

    used = set(req.hero.hole_cards) | set(req.board)
    if len(used) != len(req.hero.hole_cards) + len(req.board):
        return JSONResponse(
            status_code=400,
            content=ErrorResponse(
                error=ErrorBody(code="INVALID_BOARD", message="board overlaps hero hole cards", request_id=request_id)
            ).model_dump(),
        )

    if active_solver is None:
        return JSONResponse(
            status_code=503,
            content=ErrorResponse(
                error=ErrorBody(code="SOLVER_UNAVAILABLE", message=active_solver_error or "solver not loaded", request_id=request_id)
            ).model_dump(),
        )

    try:
        action, alternatives, display = active_solver.solve(req)
    except Exception as e:
        return JSONResponse(
            status_code=503,
            content=ErrorResponse(
                error=ErrorBody(code="SOLVER_UNAVAILABLE", message=str(e), request_id=request_id)
            ).model_dump(),
        )

    latency_ms = int((time.perf_counter() - start) * 1000)
    return SolveResponse(
        request_id=request_id,
        latency_ms=latency_ms,
        solver=SOLVER_NAME,
        mode="real",
        action=action,
        alternatives=alternatives,
        display=display,
    )
