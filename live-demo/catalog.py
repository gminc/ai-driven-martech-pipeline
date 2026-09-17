"""商品目錄：從 products.json 載入，價格與品名一律以伺服器端資料為準。"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

CATALOG_PATH = Path(__file__).with_name("products.json")
MAX_QUANTITY = 5


@dataclass(frozen=True)
class Product:
    id: str
    name: str
    category: str
    price: int
    image: str
    summary: str
    details: str


@dataclass(frozen=True)
class Catalog:
    brand_name_zh: str
    brand_name_en: str
    tagline: str
    currency: str
    products: tuple[Product, ...]

    def get(self, product_id: str) -> Product | None:
        return next((p for p in self.products if p.id == product_id), None)


def load_catalog(path: Path = CATALOG_PATH) -> Catalog:
    data = json.loads(path.read_text(encoding="utf-8"))
    products = tuple(Product(**item) for item in data["products"])
    ids = [p.id for p in products]
    if len(ids) != len(set(ids)):
        raise ValueError("products.json 內有重複的商品 id")
    if any(p.price <= 0 for p in products):
        raise ValueError("商品價格必須為正整數")
    brand = data["brand"]
    return Catalog(brand["name_zh"], brand["name_en"], brand["tagline"], data["currency"], products)


def parse_quantity(raw: str | None) -> int:
    """數量只接受 1–MAX_QUANTITY 的整數，其餘一律視為 1。"""
    try:
        qty = int(raw or "1")
    except ValueError:
        return 1
    return qty if 1 <= qty <= MAX_QUANTITY else 1
