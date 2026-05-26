"""Local demo server: webcam frames -> YOLO -> AWS solver API.

Run:
    cd demo && uv sync && uv run uvicorn server:app --port 8080 --reload
Browse:
    http://localhost:8080
"""
from __future__ import annotations
import io
import os
import re
import pathlib
from pathlib import Path

# Force CPU before any torch import — host GPU may be too new for installed torch
os.environ.setdefault("CUDA_VISIBLE_DEVICES", "")

import cv2
import httpx
import numpy as np
from fastapi import FastAPI, File, UploadFile, HTTPException
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from detect_cards import detect_cards, load_model, normalize_card_label

HERE = Path(__file__).resolve().parent
MODEL_PATH = HERE / "models" / "shades_bestModel.pt"
SOLVER_URL = os.environ.get("SOLVER_URL", "http://44.211.131.130:8000")
DEFAULT_CONF = float(os.environ.get("DETECT_CONF", "0.30"))

# detect_cards labels use "10" for ten and uppercase suit; our API uses "T" and lowercase suit.
SUIT_API = {"S": "s", "C": "c", "D": "d", "H": "h"}


def label_to_api(label: str) -> str:
    m = re.fullmatch(r"(10|[2-9AJQK])([SCDH])", label)
    if not m:
        return label.lower()
    rank, suit = m.group(1), m.group(2)
    if rank == "10":
        rank = "T"
    return f"{rank}{SUIT_API[suit]}"


app = FastAPI(title="Poker Demo")
app.mount("/static", StaticFiles(directory=str(HERE / "static")), name="static")
_model = None


@app.on_event("startup")
def _load_model():
    global _model
    if not MODEL_PATH.exists():
        print(f"[demo] WARNING: no model at {MODEL_PATH} — run download_model.py")
        return
    try:
        import torch
        _model = load_model(str(MODEL_PATH))
        _model.cpu()
        for p in _model.parameters():
            p.requires_grad_(False)
        torch.set_num_threads(max(1, os.cpu_count() // 2))
        print(f"[demo] YOLO loaded on CPU from {MODEL_PATH}")
    except Exception as e:
        print(f"[demo] WARNING: model load failed: {e}")
        _model = None


@app.get("/")
async def index():
    return FileResponse(str(HERE / "static" / "index.html"))


@app.get("/api/config")
async def config():
    return {"solver_url": SOLVER_URL, "model_loaded": _model is not None}


@app.post("/api/detect")
async def detect(frame: UploadFile = File(...), conf: float = DEFAULT_CONF):
    if _model is None:
        return {"detections": [], "model_loaded": False}
    raw = await frame.read()
    arr = np.frombuffer(raw, dtype=np.uint8)
    img = cv2.imdecode(arr, cv2.IMREAD_COLOR)
    if img is None:
        raise HTTPException(400, "could not decode image")
    dets = detect_cards(_model, img, conf)
    return {
        "detections": [
            {
                "label": d.label,
                "api_label": label_to_api(d.label),
                "confidence": round(d.confidence, 3),
                "box": list(d.box),
            }
            for d in dets
        ],
        "model_loaded": True,
    }


@app.post("/api/solve")
async def solve(payload: dict):
    async with httpx.AsyncClient(timeout=120.0) as client:
        try:
            r = await client.post(f"{SOLVER_URL}/v1/solve", json=payload)
            return JSONResponse(content=r.json(), status_code=r.status_code)
        except httpx.HTTPError as e:
            raise HTTPException(502, f"solver unreachable: {e}")


@app.get("/api/health")
async def health():
    async with httpx.AsyncClient(timeout=5.0) as client:
        try:
            r = await client.get(f"{SOLVER_URL}/v1/health")
            return {"solver": r.json(), "demo_model_loaded": _model is not None}
        except Exception as e:
            return {"solver": {"status": "unreachable", "error": str(e)}, "demo_model_loaded": _model is not None}
