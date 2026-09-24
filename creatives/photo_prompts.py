"""產生 24 張素材底圖的生圖 prompt（照片只管商品、人物、主色系）

按鈕空位與文字區塊不交給生圖模型，由 compose.py 依 creatives.json 合成，
這樣 cta_position 與 text_density 一定和規格一致
"""
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SPEC = ROOT / "synthesizer" / "creatives.json"

PRODUCT = {
    "sock-crew-daily": "a pair of plain cotton crew socks",
    "towel-bath-cotton": "a large fluffy cotton bath towel",
    "sock-towel-training": "a pair of thick cushioned terry training socks",
    "towel-face-cotton": "a folded pure cotton face towel",
    "set-starter": "a gift set of cotton socks and a face towel",
}
PALETTE = {
    "warm": "warm palette of terracotta, beige and soft orange",
    "cool": "cool palette of light blue, grey and white",
    "neutral": "neutral palette of off-white, oatmeal and light grey",
}


def prompt_of(c: dict) -> str:
    who = (
        "a smiling young Taiwanese adult is using the product, the product is clearly visible"
        if c["has_person"]
        else "product only, no people, no hands"
    )
    return (
        f"Photorealistic advertising photo for a Taiwanese cotton textile brand: {PRODUCT[c['product_focus']]}, "
        f"{who}, {PALETTE[c['dominant_color']]} for the background and props, "
        "wide 16:9 landscape, subject slightly left of center, plain uncluttered background, soft studio lighting, "
        "no text, no letters, no logo, no watermark"
    )


def main() -> None:
    creatives = [c for c in json.loads(SPEC.read_text())["creatives"] if c["format"] == "image"]
    for i, c in enumerate(creatives, 1):
        print(f"#{i:02d} 存檔名稱：{c['creative_id']}.png")
        print(prompt_of(c))
        print()


if __name__ == "__main__":
    main()
