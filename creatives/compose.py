"""把底圖照片合成成 24 張廣告素材（1200×628）

照片只負責商品、有沒有人物、主色系（生圖 prompt 見 photo_prompts.py）
按鈕位置（cta_position）與文字多寡（text_density）由這支程式依 synthesizer/creatives.json 畫上去，
所以這兩個屬性一定和規格一致，Day 16 抽特徵、Day 20 評測拿它當標準答案

用法：python3 creatives/compose.py --photos <底圖資料夾> [--only cr-meta-evg-p1,...]
底圖檔名：<creative_id>.png 或 .jpg，任何尺寸都可以，會置中裁成 1200×628
產出：creatives/images/<creative_id>.jpg 與 creatives/images/manifest.csv
"""
import argparse
import csv
import hashlib
import json
import pathlib

from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageStat

ROOT = pathlib.Path(__file__).resolve().parent.parent
SPEC = ROOT / "synthesizer" / "creatives.json"
OUT = ROOT / "creatives" / "images"
W, H = 1200, 628
FONT_FILE = "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc"

# 虛構品牌的文案，不放療效、成分百分比這類宣稱
COPY = {
    "sock-crew-daily": ("天天穿的純棉短襪", "透氣柔軟　不悶腳", "多色可選　一次補齊"),
    "sock-towel-training": ("重訓日的厚底毛巾襪", "加厚足底　穩穩支撐", "吸汗快乾　練完不黏"),
    "towel-bath-cotton": ("一條包得住的大浴巾", "蓬鬆厚實　好吸水", "洗了依然柔軟"),
    "towel-face-cotton": ("每天洗臉的純棉毛巾", "細緻觸感　溫和親膚", "快乾好收納"),
    "set-starter": ("襪子＋毛巾新手組", "第一次買就上手", "送禮自用都合適"),
}
BADGES = {
    "evergreen": ("新品", "免運"),
    "training-socks": ("重訓", "專案價"),
    "autumn-cotton": ("秋日", "限定"),
}
CTA_TEXT = "立即選購"


def font(size: int) -> ImageFont.FreeTypeFont:
    """在 .ttc 裡找繁體中文（TC）那一套字型"""
    for index in range(10):
        try:
            f = ImageFont.truetype(FONT_FILE, size, index=index)
        except OSError:
            break
        if "TC" in " ".join(f.getname()):
            return f
    return ImageFont.truetype(FONT_FILE, size)


def cover(photo: Image.Image) -> Image.Image:
    """置中裁切成 1200×628 的比例再縮放"""
    photo = photo.convert("RGB")
    ratio = W / H
    w, h = photo.size
    if w / h > ratio:
        nw = int(h * ratio)
        photo = photo.crop(((w - nw) // 2, 0, (w - nw) // 2 + nw, h))
    else:
        nh = int(w / ratio)
        photo = photo.crop((0, (h - nh) // 2, w, (h - nh) // 2 + nh))
    return photo.resize((W, H), Image.LANCZOS)


def panel(draw: ImageDraw.ImageDraw, box, radius=18, alpha=215):
    draw.rounded_rectangle(box, radius=radius, fill=(255, 255, 255, alpha))


def text_center(draw, box, text, f, fill):
    l, t, r, b = draw.textbbox((0, 0), text, font=f)
    x = box[0] + (box[2] - box[0] - (r - l)) / 2 - l
    y = box[1] + (box[3] - box[1] - (b - t)) / 2 - t
    draw.text((x, y), text, font=f, fill=fill)


BADGE_SLOTS = {"top_left": (40, 40), "right": (920, 336), "bottom_left": (40, 478)}


def quietest(base: Image.Image) -> tuple:
    """回傳兩個徽章（240×110）放哪裡最不會蓋到人物或商品：看候選區域的邊緣強度，越低代表越接近素面背景"""
    edges = base.convert("L").filter(ImageFilter.FIND_EDGES)
    best, best_score = None, None
    for name, (x, y) in BADGE_SLOTS.items():
        score = ImageStat.Stat(edges.crop((x, y, x + 240, y + 110))).mean[0]
        if best_score is None or score < best_score:
            best, best_score = (x, y), score
    return best


def compose(c: dict, photo: Image.Image) -> Image.Image:
    base = cover(photo).convert("RGBA")
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    headline, sub1, sub2 = COPY[c["product_focus"]]
    dark = (40, 40, 40, 255)

    # 文字區塊放右側，照片主體在左半邊
    panel(d, (700, 60, 1160, 160))
    text_center(d, (700, 60, 1160, 160), headline, font(44), dark)

    if c["text_density"] == "high":
        # 三個文字區塊＋兩個徽章
        panel(d, (740, 180, 1160, 240), radius=14)
        text_center(d, (740, 180, 1160, 240), sub1, font(32), dark)
        panel(d, (740, 256, 1160, 316), radius=14)
        text_center(d, (740, 256, 1160, 316), sub2, font(32), dark)
        # 徽章位置不寫死：左上、右欄副標下方、左下三個候選位置，挑照片最單純（邊緣最少）的那一個
        # 固定放左上時，人物的頭常常在那裡，會壓到臉
        bx, by = quietest(base)
        for i, label in enumerate(BADGES[c["utm_campaign"]]):
            x0, y0 = bx + i * 130, by
            d.ellipse((x0, y0, x0 + 110, y0 + 110), fill=(55, 62, 72, 235))  # 深灰，不影響主色系判讀
            text_center(d, (x0, y0, x0 + 110, y0 + 110), label, font(30), (255, 255, 255, 255))

    if c["cta_position"] in ("center", "bottom_right"):
        bw, bh = 300, 76
        if c["cta_position"] == "center":
            box = ((W - bw) // 2, H - bh - 40, (W + bw) // 2, H - 40)
        else:
            box = (W - bw - 40, H - bh - 40, W - 40, H - 40)
        d.rounded_rectangle(box, radius=38, fill=(35, 35, 35, 240))
        text_center(d, box, CTA_TEXT, font(34), (255, 255, 255, 255))

    return Image.alpha_composite(base, layer).convert("RGB")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--photos", required=True, help="底圖資料夾")
    ap.add_argument("--only", default="")
    args = ap.parse_args()
    only = {s for s in args.only.split(",") if s}
    photos = pathlib.Path(args.photos)

    OUT.mkdir(parents=True, exist_ok=True)
    manifest_path = OUT / "manifest.csv"
    rows = {}
    if manifest_path.exists():
        with manifest_path.open(encoding="utf-8") as f:
            rows = {r["creative_id"]: r for r in csv.DictReader(f)}

    creatives = [c for c in json.loads(SPEC.read_text(encoding="utf-8"))["creatives"] if c["format"] == "image"]
    for c in creatives:
        cid = c["creative_id"]
        if only and cid not in only:
            continue
        src = next((p for p in (photos / f"{cid}.png", photos / f"{cid}.jpg", photos / f"{cid}.jpeg") if p.exists()), None)
        if src is None:
            print(f"⚠️ 找不到 {cid} 的底圖，略過")
            continue
        out = OUT / c["image_file"]
        compose(c, Image.open(src)).save(out, "JPEG", quality=90)
        rows[cid] = {
            "creative_id": cid,
            "image_file": c["image_file"],
            "photo_file": src.name,
            "photo_sha256": hashlib.sha256(src.read_bytes()).hexdigest(),
            "has_person": c["has_person"],
            "cta_position": c["cta_position"],
            "dominant_color": c["dominant_color"],
            "text_density": c["text_density"],
            "sha256": hashlib.sha256(out.read_bytes()).hexdigest(),
        }
        print(f"✅ {cid}")

    with manifest_path.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(next(iter(rows.values())).keys()))
        w.writeheader()
        for cid in sorted(rows):
            w.writerow(rows[cid])
    print(f"完成 {len(rows)} 張，清單寫在 {manifest_path.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
