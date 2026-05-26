"""Replace SHADES YOLOv5 with TeogopK YOLOv8m playing-cards (99.5% mAP, 52 MB).
Run: uv run python swap_to_yolov8m.py
Output log: /tmp/swap.log
"""
from __future__ import annotations
import os, sys, shutil, urllib.request, pathlib

os.environ["CUDA_VISIBLE_DEVICES"] = ""

HERE = pathlib.Path(__file__).resolve().parent
MODELS = HERE / "models"
MODELS.mkdir(exist_ok=True)
LOG = pathlib.Path("/tmp/swap.log")
LOG.write_text("")

URLS = [
    ("yolov8m_synthetic.pt", "https://raw.githubusercontent.com/TeogopK/Playing-Cards-Object-Detection/main/final_models/yolov8m_synthetic.pt"),
    ("yolov8m_tuned.pt",     "https://raw.githubusercontent.com/TeogopK/Playing-Cards-Object-Detection/main/final_models/yolov8m_tuned.pt"),
]

def log(msg):
    with open(LOG, "a") as f:
        f.write(str(msg) + "\n")

def main():
    for name, url in URLS:
        dest = MODELS / name
        if dest.exists() and dest.stat().st_size > 1_000_000:
            log(f"have {name} ({dest.stat().st_size//1024//1024} MB)")
            continue
        log(f"downloading {name} from {url}")
        urllib.request.urlretrieve(url, dest)
        log(f"  -> {dest} ({dest.stat().st_size//1024//1024} MB)")

    pick = MODELS / "yolov8m_synthetic.pt"  # 52-class synthetic-trained
    log(f"\nPicked: {pick.name}")

    log("\n=== Verify load (Ultralytics) ===")
    from ultralytics import YOLO
    model = YOLO(str(pick))
    model.to("cpu")
    log(f"classes ({len(model.names)}): {dict(list(model.names.items())[:10])} ...")
    log(f"params: ~{sum(p.numel() for p in model.parameters()) // 1_000_000} M")
    import numpy as np
    blank = np.zeros((640, 640, 3), dtype=np.uint8)
    res = model.predict(blank, verbose=False, device="cpu")
    log(f"dry inference OK; {len(res[0].boxes)} dets on blank (expected 0)")
    log(f"\nDONE. Model at: {pick}")
    log(f"Update demo/server.py MODEL_PATH to: models/{pick.name}")

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        import traceback
        log("FAILED: " + traceback.format_exc())
        sys.exit(1)
