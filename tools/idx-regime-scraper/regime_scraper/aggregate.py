from __future__ import annotations

from typing import Dict, Iterable, List, Optional, Tuple

from .models import StockRatio

# Winsorisation caps for per-stock ratios. Tiny / near-zero-equity names throw up
# absurd P/E and P/B values that would otherwise dominate a cap-weighted sum; the
# research doc (§5) calls for winsorising these. The caps are deliberately generous
# — they tame outliers without distorting the bulk of the distribution.
DEFAULT_MAX_PER = 200.0
DEFAULT_MAX_PB = 50.0


def aggregate_index(
    records: Iterable[StockRatio],
    *,
    max_per: float = DEFAULT_MAX_PER,
    max_pb: float = DEFAULT_MAX_PB,
) -> Tuple[Optional[float], Optional[float]]:
    """Cap-weighted index P/E and P/B per ``idx-regime-data-research.md`` §5.

    ``Mcap_i = priceBV_i × equity_i`` (works for loss-makers — uses P/B, not P/E):

        Index PB = Σ Mcap_i / Σ equity_i          over equity_i > 0
        Index PE = Σ Mcap_i / Σ (Mcap_i / per_i)  over per_i > 0 (loss-makers excluded
                                                   from BOTH numerator and denominator)

    Robustness rules, all from §5:
      • drop non-positive equity (and non-positive P/B — can't form a market cap);
      • exclude loss-makers (per ≤ 0) from the P/E sum on both sides;
      • winsorise extreme per-stock P/E and P/B before weighting.

    Returns ``(pe, pb)``; either is ``None`` when nothing qualified.
    """
    pb_num = pb_den = 0.0
    pe_num = pe_den = 0.0

    for r in records:
        if not r.equity or r.equity <= 0:
            continue
        if not r.price_bv or r.price_bv <= 0:
            continue
        pbv = min(r.price_bv, max_pb)
        mcap = pbv * r.equity

        pb_num += mcap
        pb_den += r.equity

        if r.per and r.per > 0:
            per = min(r.per, max_per)
            pe_num += mcap
            pe_den += mcap / per  # = earnings_i

    pe = pe_num / pe_den if pe_den > 0 else None
    pb = pb_num / pb_den if pb_den > 0 else None
    return pe, pb


def group_by_sector(records: Iterable[StockRatio]) -> Dict[str, List[StockRatio]]:
    """Bucket records by ``sectorCode`` (the §5 finding: Composite + all 11 IDX-IC
    sectors compute with zero membership data, purely by grouping)."""
    out: Dict[str, List[StockRatio]] = {}
    for r in records:
        if not r.sector_code:
            continue
        out.setdefault(r.sector_code, []).append(r)
    return out


def filter_constituents(records: Iterable[StockRatio], codes: Iterable[str]) -> List[StockRatio]:
    """Records whose ``code`` is in ``codes`` — for membership-defined indices
    (LQ45 / IDX30) that the ratio feed can't group on its own (§5 membership gap)."""
    wanted = {c.strip().upper() for c in codes}
    return [r for r in records if r.code in wanted]
