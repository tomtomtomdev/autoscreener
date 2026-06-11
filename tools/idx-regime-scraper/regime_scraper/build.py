from __future__ import annotations

from typing import Dict, List, Optional, Tuple

from .aggregate import aggregate_index, filter_constituents, group_by_sector
from .models import BIRate, MacroSeries, StockRatio
from .percentile import percentile_rank

COMPOSITE = "COMPOSITE"
SECTOR_PREFIX = "SECTOR:"

IndexPair = Tuple[Optional[float], Optional[float]]  # (pe, pb)


def compute_indices(
    records: List[StockRatio], constituents: Dict[str, List[str]]
) -> Dict[str, IndexPair]:
    """Cap-weighted (pe, pb) for every index in scope (§6): the composite, each
    IDX-IC sector (keyed ``SECTOR:<code>``), and each membership index in
    ``constituents`` (e.g. ``LQ45``, ``IDX30``)."""
    indices: Dict[str, IndexPair] = {COMPOSITE: aggregate_index(records)}
    for sector_code, recs in group_by_sector(records).items():
        indices[SECTOR_PREFIX + sector_code] = aggregate_index(recs)
    for key, codes in constituents.items():
        indices[key] = aggregate_index(filter_constituents(records, codes))
    return indices


def history_record(as_of: str, indices: Dict[str, IndexPair]) -> dict:
    """One month's raw aggregates, for the ``regime-history.json`` series."""
    return {
        "period": as_of,
        "indices": {key: {"pe": pe, "pb": pb} for key, (pe, pb) in indices.items()},
    }


def upsert_history(history: List[dict], record: dict) -> List[dict]:
    """Replace any existing record for the same period, append, and keep the series
    sorted by period — so re-running a month is idempotent and back-fill stays ordered."""
    out = [h for h in history if h.get("period") != record["period"]]
    out.append(record)
    out.sort(key=lambda h: h.get("period", ""))
    return out


def assemble_snapshot(
    as_of: str,
    indices: Dict[str, IndexPair],
    history: List[dict],
    bi_rate: Optional[BIRate],
    macro: Optional[Dict[str, MacroSeries]] = None,
) -> dict:
    """The ``regime.json`` snapshot: current pe/pb plus each one's percentile vs. the
    full (current-inclusive) history. Matches the app's ``RegimeSnapshot`` contract.

    ``macro`` carries the global anchors of the intermarket chain (US fed funds, US 10y
    yield, broad dollar); ``None`` when the fetch was skipped or failed, so the app's
    regime read degrades to its IDX-side factors — same contract as ``biRate``."""
    out_indices: Dict[str, dict] = {}
    for key, (pe, pb) in indices.items():
        pe_hist = [h["indices"][key]["pe"] for h in history if key in h.get("indices", {})]
        pb_hist = [h["indices"][key]["pb"] for h in history if key in h.get("indices", {})]
        out_indices[key] = {
            "pe": _round(pe, 2),
            "pb": _round(pb, 2),
            "pePctile": _round(percentile_rank(pe, pe_hist), 4),
            "pbPctile": _round(percentile_rank(pb, pb_hist), 4),
        }
    return {
        "asOf": as_of,
        "biRate": bi_rate.to_dict() if bi_rate else None,
        "macro": {key: series.to_dict() for key, series in macro.items()} if macro else None,
        "indices": out_indices,
    }


def build(
    as_of: str,
    records: List[StockRatio],
    prior_history: List[dict],
    constituents: Dict[str, List[str]],
    bi_rate: Optional[BIRate],
    macro: Optional[Dict[str, MacroSeries]] = None,
) -> Tuple[dict, List[dict]]:
    """End-to-end pure build: aggregate → fold into history → assemble snapshot.
    Returns ``(snapshot, updated_history)`` ready to serialise. No I/O."""
    indices = compute_indices(records, constituents)
    history = upsert_history(list(prior_history), history_record(as_of, indices))
    snapshot = assemble_snapshot(as_of, indices, history, bi_rate, macro)
    return snapshot, history


def _round(value: Optional[float], digits: int) -> Optional[float]:
    return None if value is None else round(value, digits)
