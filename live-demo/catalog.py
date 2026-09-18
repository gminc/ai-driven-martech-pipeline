"""商品目錄：從 products.json 載入品牌、商品與活動資料。

價格與品名一律以伺服器端資料為準，前端只能傳商品 ID、數量與尺寸，三者都要通過白名單驗證。
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

CATALOG_PATH = Path(__file__).with_name("products.json")
MAX_QUANTITY = 5


@dataclass(frozen=True)
class Product:
    id: str
    name: str
    subtitle: str
    category: str
    price: int
    compare_at_price: int | None
    badge: str
    image: str
    gallery: tuple[str, ...]
    summary: str
    details: str
    story: str
    material: str
    size: str
    care: str
    made_in: str
    # 可選尺寸：第一個為預設值，結帳時只接受清單內的字串
    size_options: tuple[str, ...]

    def has_size(self, value: str) -> bool:
        return value in self.size_options

    def resolve_size(self, raw: str | None) -> str:
        """結帳入口用：回傳合法尺寸；傳入空值或不在清單內時，一律退回預設尺寸。"""
        raw = (raw or "").strip()
        fallback = self.size_options[0] if self.size_options else ""
        return raw if self.has_size(raw) else fallback

    def size_index(self, value: str) -> int:
        """尺寸在清單中的位置；送進金流自訂欄位的是這個數字，不是中文字串。"""
        return self.size_options.index(value) if self.has_size(value) else 0

    def size_by_index(self, raw: str) -> str:
        """付款結果回程用：把索引還原成尺寸。不合法一律回空字串，絕不猜預設值。"""
        raw = (raw or "").strip()
        if not raw.isdigit():
            return ""
        index = int(raw)
        return self.size_options[index] if index < len(self.size_options) else ""


@dataclass(frozen=True)
class Pillar:
    id: str
    title: str
    title_en: str
    body: str


@dataclass(frozen=True)
class Campaign:
    slug: str
    name: str
    headline: str
    subhead: str
    promotion_id: str
    promotion_name: str
    creative_name: str
    creative_slot: str
    hero_image: str
    bullets: tuple[str, ...]
    product_ids: tuple[str, ...]


@dataclass(frozen=True)
class Brand:
    name_zh: str
    name_en: str
    tagline: str
    lede: str
    story: str
    location: str


@dataclass(frozen=True)
class Catalog:
    brand: Brand
    currency: str
    products: tuple[Product, ...]
    pillars: tuple[Pillar, ...]
    campaigns: tuple[Campaign, ...] = field(default_factory=tuple)

    def get(self, product_id: str) -> Product | None:
        return next((p for p in self.products if p.id == product_id), None)

    def campaign(self, slug: str) -> Campaign | None:
        return next((c for c in self.campaigns if c.slug == slug), None)

    def campaign_products(self, campaign: Campaign) -> tuple[Product, ...]:
        found = (self.get(pid) for pid in campaign.product_ids)
        return tuple(p for p in found if p is not None)

    def related(self, product: Product, limit: int = 3) -> tuple[Product, ...]:
        others = [p for p in self.products if p.id != product.id]
        same_category = [p for p in others if p.category == product.category]
        rest = [p for p in others if p.category != product.category]
        return tuple((same_category + rest)[:limit])


def load_catalog(path: Path = CATALOG_PATH) -> Catalog:
    data = json.loads(path.read_text(encoding="utf-8"))
    products = tuple(
        Product(
            id=item["id"],
            name=item["name"],
            subtitle=item["subtitle"],
            category=item["category"],
            price=int(item["price"]),
            compare_at_price=item.get("compare_at_price"),
            badge=item.get("badge", ""),
            image=item["image"],
            gallery=tuple(item.get("gallery") or [item["image"]]),
            summary=item["summary"],
            details=item["details"],
            story=item.get("story", ""),
            material=item.get("material", ""),
            size=item.get("size", ""),
            care=item.get("care", ""),
            made_in=item.get("made_in", ""),
            size_options=tuple(item.get("size_options") or ()),
        )
        for item in data["products"]
    )
    ids = [p.id for p in products]
    if len(ids) != len(set(ids)):
        raise ValueError("products.json 內有重複的商品 id")
    if any(p.price <= 0 for p in products):
        raise ValueError("商品價格必須為正整數")
    for product in products:
        if not product.size_options:
            raise ValueError(f"商品 {product.id} 至少要有一個尺寸選項")
        if len(product.size_options) != len(set(product.size_options)):
            raise ValueError(f"商品 {product.id} 的尺寸選項重複")

    pillars = tuple(Pillar(**item) for item in data.get("pillars", []))
    campaigns = tuple(
        Campaign(
            slug=item["slug"],
            name=item["name"],
            headline=item["headline"],
            subhead=item["subhead"],
            promotion_id=item["promotion_id"],
            promotion_name=item["promotion_name"],
            creative_name=item["creative_name"],
            creative_slot=item["creative_slot"],
            hero_image=item["hero_image"],
            bullets=tuple(item.get("bullets", ())),
            product_ids=tuple(item.get("product_ids", ())),
        )
        for item in data.get("campaigns", [])
    )
    slugs = [c.slug for c in campaigns]
    if len(slugs) != len(set(slugs)):
        raise ValueError("products.json 內有重複的活動 slug")
    for campaign in campaigns:
        unknown = [pid for pid in campaign.product_ids if pid not in ids]
        if unknown:
            raise ValueError(f"活動 {campaign.slug} 指到不存在的商品：{unknown}")

    brand = Brand(**data["brand"])
    return Catalog(brand, data["currency"], products, pillars, campaigns)


def parse_quantity(raw: str | None) -> int:
    """數量只接受 1–MAX_QUANTITY 的整數，其餘一律視為 1。"""
    try:
        qty = int(raw or "1")
    except ValueError:
        return 1
    return qty if 1 <= qty <= MAX_QUANTITY else 1
