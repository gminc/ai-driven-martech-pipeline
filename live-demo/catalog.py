"""商品目錄：從 products.json 載入品牌、商品與活動資料。

價格與品名一律以伺服器端資料為準，前端只能傳商品 ID 與數量。
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
    colors: tuple[str, ...]


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
            colors=tuple(item.get("colors") or ()),
        )
        for item in data["products"]
    )
    ids = [p.id for p in products]
    if len(ids) != len(set(ids)):
        raise ValueError("products.json 內有重複的商品 id")
    if any(p.price <= 0 for p in products):
        raise ValueError("商品價格必須為正整數")

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
