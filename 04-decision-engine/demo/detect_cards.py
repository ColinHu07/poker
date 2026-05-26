#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import pathlib
import re
import time
import warnings
from collections import defaultdict, deque
from dataclasses import dataclass

import cv2


warnings.filterwarnings("ignore", category=FutureWarning, message=r".*torch\.cuda\.amp\.autocast.*")

SUIT_SYMBOLS = {
    "C": "clubs",
    "D": "diamonds",
    "H": "hearts",
    "S": "spades",
}

DEFAULT_MODEL_PATH = os.path.join(
    os.path.dirname(__file__),
    "models",
    "shades_bestModel.pt",
)


@dataclass(frozen=True)
class Detection:
    label: str
    confidence: float
    box: tuple[int, int, int, int]


class StableCardLogger:
    def __init__(self, min_hits: int = 3, window_seconds: float = 1.5, hold_seconds: float = 1.0):
        self.min_hits = min_hits
        self.window_seconds = window_seconds
        self.hold_seconds = hold_seconds
        self.history = defaultdict(deque)
        self.last_logged = {}

    def update(self, detections: list[Detection]) -> list[str]:
        now = time.monotonic()
        stable = []

        for detection in detections:
            events = self.history[detection.label]
            events.append((now, detection.confidence))

            while events and now - events[0][0] > self.window_seconds:
                events.popleft()

            if len(events) >= self.min_hits:
                last = self.last_logged.get(detection.label, 0)
                if now - last > self.hold_seconds:
                    avg_conf = sum(conf for _, conf in events) / len(events)
                    stable.append(f"{detection.label} ({avg_conf:.2f})")
                    self.last_logged[detection.label] = now

        return stable


def normalize_card_label(raw_label: str) -> str:
    label = raw_label.strip().upper()
    label = label.replace(" ", "_").replace("-", "_")

    direct = re.fullmatch(r"(10|[2-9AJQK])([CDHS])", label)
    if direct:
        return f"{direct.group(1)}{direct.group(2)}"

    compact = label.replace("_", "")
    direct = re.fullmatch(r"(10|[2-9AJQK])([CDHS])", compact)
    if direct:
        return f"{direct.group(1)}{direct.group(2)}"

    ranks = {
        "ACE": "A",
        "A": "A",
        "KING": "K",
        "K": "K",
        "QUEEN": "Q",
        "Q": "Q",
        "JACK": "J",
        "J": "J",
        "TEN": "10",
        "10": "10",
        "T": "10",
        "NINE": "9",
        "EIGHT": "8",
        "SEVEN": "7",
        "SIX": "6",
        "FIVE": "5",
        "FOUR": "4",
        "THREE": "3",
        "TWO": "2",
    }
    suits = {
        "CLUB": "C",
        "CLUBS": "C",
        "DIAMOND": "D",
        "DIAMONDS": "D",
        "HEART": "H",
        "HEARTS": "H",
        "SPADE": "S",
        "SPADES": "S",
    }

    parts = [part for part in re.split(r"[_/]+", label) if part]
    found_rank = next((ranks[p] for p in parts if p in ranks), None)
    found_suit = next((suits[p] for p in parts if p in suits), None)
    if found_rank and found_suit:
        return f"{found_rank}{found_suit}"

    return raw_label


def card_display(label: str) -> str:
    normalized = normalize_card_label(label)
    match = re.fullmatch(r"(10|[2-9AJQK])([CDHS])", normalized)
    if not match:
        return normalized
    return f"{match.group(1)} of {SUIT_SYMBOLS[match.group(2)]}"


def load_model(model_path: str):
    if not os.path.exists(model_path):
        raise FileNotFoundError(f"Model not found: {model_path}")

    try:
        import torch
    except ImportError as exc:
        raise RuntimeError("Install dependencies first: pip install -r requirements.txt") from exc

    # SHADES' checkpoint was saved on Windows, so macOS/Linux need this before torch.load.
    pathlib.WindowsPath = pathlib.PosixPath
    return torch.hub.load("ultralytics/yolov5", "custom", path=model_path, trust_repo=True)


def detect_cards(model, frame, conf: float) -> list[Detection]:
    results = model(frame)
    predictions = results.pred[0]
    detections = []
    names = results.names

    for prediction in predictions:
        x1, y1, x2, y2, confidence, cls_id = prediction.detach().cpu().tolist()
        confidence = float(confidence)
        if confidence < conf:
            continue

        raw_label = str(names[int(cls_id)])
        detections.append(
            Detection(
                label=normalize_card_label(raw_label),
                confidence=confidence,
                box=(int(x1), int(y1), int(x2), int(y2)),
            )
        )

    return unique_left_to_right(detections)


def unique_left_to_right(detections: list[Detection]) -> list[Detection]:
    best_by_label = {}
    for detection in detections:
        existing = best_by_label.get(detection.label)
        if existing is None or detection.confidence > existing.confidence:
            best_by_label[detection.label] = detection
    return sorted(best_by_label.values(), key=lambda detection: detection.box[0])


def draw_detections(frame, detections: list[Detection]):
    for detection in detections:
        x1, y1, x2, y2 = detection.box
        color = (80, 220, 80)
        cv2.rectangle(frame, (x1, y1), (x2, y2), color, 2)

        text = f"{detection.label} {detection.confidence:.2f}"
        cv2.putText(frame, text, (x1, max(22, y1 - 8)), cv2.FONT_HERSHEY_SIMPLEX, 0.65, color, 2)

    cv2.putText(frame, "SHADES YOLOv5 model", (16, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (255, 255, 255), 2)
    cv2.putText(frame, "Press q to quit", (16, 62), cv2.FONT_HERSHEY_SIMPLEX, 0.65, (255, 255, 255), 2)


def parse_args():
    parser = argparse.ArgumentParser(description="Webcam playing-card detection prototype.")
    parser.add_argument(
        "--model",
        default=DEFAULT_MODEL_PATH,
        help="Path to YOLO playing-card .pt model.",
    )
    parser.add_argument("--camera", type=int, default=0, help="Webcam index. Usually 0 or 1.")
    parser.add_argument("--conf", type=float, default=0.30, help="Detection confidence threshold.")
    parser.add_argument("--width", type=int, default=640, help="Requested webcam width.")
    parser.add_argument("--height", type=int, default=480, help="Requested webcam height.")
    return parser.parse_args()


def main():
    args = parse_args()
    model = load_model(args.model)

    cap = cv2.VideoCapture(args.camera)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, args.width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, args.height)

    if not cap.isOpened():
        raise RuntimeError(f"Could not open webcam index {args.camera}")

    logger = StableCardLogger()
    print("Starting webcam card detector. Press q in the preview window to quit.")

    while True:
        ok, frame = cap.read()
        if not ok:
            break

        detections = detect_cards(model, frame, args.conf)

        for stable in logger.update(detections):
            print(f"[stable] {card_display(stable.split(' ')[0])} {stable[stable.find('('):]}")

        draw_detections(frame, detections)
        cv2.imshow("PokerVision webcam prototype", frame)

        if cv2.waitKey(1) & 0xFF == ord("q"):
            break

    cap.release()
    cv2.destroyAllWindows()


if __name__ == "__main__":
    main()
