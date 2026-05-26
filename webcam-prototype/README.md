# Webcam Card Detection Prototype

This is the fast laptop test path before wiring card recognition into the iOS app.

It opens a webcam, runs the SHADES YOLOv5 playing-card model, displays
detections, and logs stable cards such as `QH` or `10S`. None of the SHADES poker
advice, OpenAI, Twilio, or emotion-analysis logic is included here.

## Setup

```bash
cd webcam-prototype
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Run Immediately

```bash
python detect_cards.py --camera 0
```

Press `q` to quit.

## Model

The default model is from SHADES:

- Code repo: `JaredCarrillo207/SHADES`
- Weights file: `bestModel.pt` from the Dropbox link in that repo README
- Loader: YOLOv5 via `torch.hub.load("ultralytics/yolov5", "custom", ...)`

Re-download it with:

```bash
python download_model.py
```

The default model path is:

```text
webcam-prototype/models/shades_bestModel.pt
```

Run:

```bash
python detect_cards.py --camera 0
```

You can also pass the model path explicitly:

```bash
python detect_cards.py --model models/shades_bestModel.pt --camera 0
```

The model should be trained with one class per card, using labels like `AS`,
`2S`, `10H`, `QD`, or equivalent names such as `ace_spades`.

## Useful Options

```bash
python detect_cards.py --help
```

Common examples:

```bash
python detect_cards.py --camera 1
python detect_cards.py --conf 0.45
```

The default confidence is `0.30`, matching SHADES' card-detection path. OpenCV is
only used for webcam capture and drawing boxes.

## Later iOS Export

Once the webcam prototype works, export the same YOLO model to CoreML:

```bash
# This SHADES model is YOLOv5, so CoreML export should be handled through YOLOv5 tooling.
```
