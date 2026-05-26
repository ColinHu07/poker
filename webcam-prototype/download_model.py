#!/usr/bin/env python3
from pathlib import Path

from urllib.request import urlretrieve


MODEL_DIR = Path(__file__).resolve().parent / "models"
MODEL_URLS = {
    "shades_bestModel.pt": "https://www.dropbox.com/scl/fi/zcpt3bcevpw03wtqtfhk2/bestModel.pt?rlkey=wciothjbbeahi5zb4twjpecvv&dl=1",
}


def main():
    MODEL_DIR.mkdir(exist_ok=True)
    for filename, url in MODEL_URLS.items():
        path = MODEL_DIR / filename
        if path.exists():
            print(f"{path} already exists")
            continue
        print(f"Downloading {url}")
        urlretrieve(url, path)
        print(path)


if __name__ == "__main__":
    main()
