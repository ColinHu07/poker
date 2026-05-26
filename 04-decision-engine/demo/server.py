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
from dataclasses import dataclass
from pathlib import Path

# Force CPU before any torch import — host GPU may be too new for installed torch
os.environ.setdefault("CUDA_VISIBLE_DEVICES", "")

import cv2
import httpx
import numpy as np
from fastapi import FastAPI, File, UploadFile, HTTPException
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from detect_cards import normalize_card_label

HERE = Path(__file__).resolve().parent
# YOLOv8m playing-cards (TeogopK) — 99.5% mAP@50, 52 classes, ~25M params
MODEL_PATH = HERE / "models" / "yolov8m_synthetic.pt"
FALLBACK_MODEL = HERE / "models" / "shades_bestModel.pt"
SOLVER_URL = os.environ.get("SOLVER_URL", "http://44.211.131.130:8000")
DEFAULT_CONF = float(os.environ.get("DETECT_CONF", "0.50"))

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
    path = MODEL_PATH if MODEL_PATH.exists() else FALLBACK_MODEL
    if not path.exists():
        print(f"[demo] WARNING: no model at {MODEL_PATH} or {FALLBACK_MODEL}")
        return
    try:
        from ultralytics import YOLO
        import torch
        _model = YOLO(str(path))
        _model.to("cpu")
        torch.set_num_threads(max(1, os.cpu_count() // 2))
        n_classes = len(_model.names)
        print(f"[demo] YOLO loaded on CPU from {path.name} ({n_classes} classes)")
    except Exception as e:
        import traceback; traceback.print_exc()
        print(f"[demo] WARNING: model load failed: {e}")
        _model = None


@dataclass(frozen=True)
class _Detection:
    label: str
    confidence: float
    box: tuple[int, int, int, int]


def _detect(model, frame, conf: float) -> list[_Detection]:
    results = model.predict(frame, conf=conf, verbose=False, device="cpu")
    r = results[0]
    out: list[_Detection] = []
    names = r.names
    if r.boxes is None:
        return out
    boxes = r.boxes
    for i in range(len(boxes)):
        c = float(boxes.conf[i].item())
        if c < conf:
            continue
        cls_id = int(boxes.cls[i].item())
        x1, y1, x2, y2 = [int(v) for v in boxes.xyxy[i].tolist()]
        raw = str(names[cls_id])
        out.append(_Detection(label=normalize_card_label(raw), confidence=c, box=(x1, y1, x2, y2)))
    # collapse to unique label, keep highest-confidence
    best = {}
    for d in out:
        if d.label not in best or d.confidence > best[d.label].confidence:
            best[d.label] = d
    return sorted(best.values(), key=lambda d: d.box[0])


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
    dets = _detect(_model, img, conf)
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
