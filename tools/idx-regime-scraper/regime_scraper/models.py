from __future__ import annotations

from dataclasses import dataclass
from typing import Optional


def to_float(value) -> Optional[float]:
    """Coerce an IDX/FRED field to a float, mapping blanks, ``-``, ``"."`` and NaN
    to ``None`` (absence is information — a loss-maker has no meaningful P/E)."""
    if value is None:
        return None
    if isinstance(value, str):
        s = value.strip()
        if s in ("", "-", ".", "N/A", "n/a"):
            return None
        s = s.replace(",", "")
        try:
            value = float(s)
        except ValueError:
            return None
    try:
        f = float(value)
    except (TypeError, ValueError):
        return None
    if f != f:  # NaN
        return None
    return f


@dataclass(frozen=True)
class StockRatio:
    """One company's row from the IDX ``LINK_FINANCIAL_DATA_RATIO`` feed (§4).

    Only the fields the cap-weighted aggregation needs are required; the rest are
    kept for completeness/debugging. ``per`` = P/E, ``price_bv`` = P/B, ``equity``
    = total equity (the weight, and — via ``price_bv × equity`` — the market cap).
    """

    code: str
    sector_code: str
    per: Optional[float]
    price_bv: Optional[float]
    equity: Optional[float]
    eps: Optional[float] = None
    book_value: Optional[float] = None

    @classmethod
    def from_api(cls, row: dict) -> "StockRatio":
        return cls(
            code=str(row.get("code") or "").strip().upper(),
            sector_code=str(row.get("sectorCode") or row.get("sector") or "").strip(),
            per=to_float(row.get("per")),
            price_bv=to_float(row.get("priceBV")),
            equity=to_float(row.get("equity")),
            eps=to_float(row.get("eps")),
            book_value=to_float(row.get("bookValue")),
        )


@dataclass(frozen=True)
class BIRate:
    """Bank Indonesia policy rate: level, last-move direction, and the date of the
    latest observation. Serialises to the ``biRate`` object in the app's contract."""

    value: float
    direction: str  # "cut" | "hold" | "hike"
    as_of: str

    def to_dict(self) -> dict:
        return {"value": self.value, "direction": self.direction, "asOf": self.as_of}
