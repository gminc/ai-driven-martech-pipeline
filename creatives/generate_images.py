"""依 synthesizer/creatives.json 的 image_prompt 產生 24 張素材圖

用法：python3 creatives/generate_images.py [--only cr-meta-evg-p1,...] [--seed-offset 0]

- 呼叫 Pollinations 的匿名免費端點，不需要金鑰、不產生費用
- 每張圖用固定種子（creative_id 的雜湊＋seed_offset），重跑會得到同一張圖
- 產出放在 creatives/images/，並寫 creatives/images/manifest.csv 記錄種子、模型、實際尺寸、檔案雜湊
- 要求 1200×628，匿名端點的模型實際輸出約 1061×555（比例相同），manifest 記實際尺寸
- 圖片屬性（有沒有人物、按鈕位置、主色系、文字多寡）在 creatives.json 先決定，
  這批圖同時是 Day 16 特徵抽取與 Day 20 評測的標準答案，生完要逐張驗收
"""
import argparse
import csv
import hashlib
import json
import pathlib
import time
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
SPEC = ROOT / "synthesizer" / "creatives.json"
OUT = ROOT / "creatives" / "images"
ENDPOINT = "https://image.pollinations.ai/prompt/"
WIDTH, HEIGHT = 1200, 628


def jpeg_size(data: bytes) -> tuple[int, int]:
    """讀 JPEG 的 SOF 標記取得實際寬高（模型可能不照要求的尺寸輸出）"""
    i = 2
    while i < len(data):
        marker, length = data[i + 1], int.from_bytes(data[i + 2:i + 4], "big")
        if marker in (0xC0, 0xC1, 0xC2):
            return int.from_bytes(data[i + 7:i + 9], "big"), int.from_bytes(data[i + 5:i + 7], "big")
        i += 2 + length
    return 0, 0


def default_model() -> str:
    try:
        with urllib.request.urlopen("https://image.pollinations.ai/models", timeout=30) as r:
            return ",".join(json.loads(r.read()))
    except Exception:
        return "unknown"


def seed_of(creative_id: str, offset: int) -> int:
    return int(hashlib.sha256(creative_id.encode()).hexdigest()[:8], 16) % 1_000_000 + offset


def fetch(prompt: str, seed: int) -> bytes:
    query = urllib.parse.urlencode(
        {"width": WIDTH, "height": HEIGHT, "seed": seed, "nologo": "true", "enhance": "false"}
    )
    url = ENDPOINT + urllib.parse.quote(prompt) + "?" + query
    last = None
    for attempt in range(5):
        try:
            with urllib.request.urlopen(url, timeout=180) as r:
                data = r.read()
                if r.status == 200 and data[:2] == b"\xff\xd8":
                    return data
                last = f"HTTP {r.status}, {len(data)} bytes"
        except Exception as e:  # 逾時或 429 都等一下再試
            last = repr(e)
        time.sleep(15 * (attempt + 1))
    raise RuntimeError(f"生圖失敗：{last}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="", help="只重生這些 creative_id，逗號分隔")
    ap.add_argument("--seed-offset", type=int, default=0, help="重生時換種子用")
    args = ap.parse_args()
    only = {s for s in args.only.split(",") if s}

    OUT.mkdir(parents=True, exist_ok=True)
    manifest_path = OUT / "manifest.csv"
    rows = {}
    if manifest_path.exists():
        with manifest_path.open() as f:
            rows = {r["creative_id"]: r for r in csv.DictReader(f)}

    model = default_model()
    creatives = [c for c in json.loads(SPEC.read_text())["creatives"] if c["format"] == "image"]
    for c in creatives:
        cid = c["creative_id"]
        if only and cid not in only:
            continue
        seed = seed_of(cid, args.seed_offset)
        data = fetch(c["image_prompt"], seed)
        (OUT / c["image_file"]).write_bytes(data)
        w, h = jpeg_size(data)
        rows[cid] = {
            "creative_id": cid,
            "image_file": c["image_file"],
            "seed": seed,
            "model": model,
            "width": w,
            "height": h,
            "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
        }
        print(f"{cid}\tseed={seed}\t{w}x{h}\t{len(data):,} bytes", flush=True)
        time.sleep(6)  # 匿名端點有速率限制

    with manifest_path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(next(iter(rows.values())).keys()))
        w.writeheader()
        for cid in sorted(rows):
            w.writerow(rows[cid])
    print(f"完成 {len(rows)} 張，清單寫在 {manifest_path.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
