import json
from pathlib import Path

import pytest

from regime_scraper.build import COMPOSITE, build, compute_indices
from regime_scraper.models import BIRate, MacroSeries, StockRatio

FIXTURES = Path(__file__).parent / "fixtures"


def load_rows():
    rows = json.loads((FIXTURES / "idx_ratio_rows.json").read_text())
    return [StockRatio.from_api(r) for r in rows]


def test_compute_indices_covers_composite_sectors_and_constituents():
    indices = compute_indices(load_rows(), {"LQ45": ["AAA", "CCC"]})

    pe, pb = indices[COMPOSITE]
    assert pb == pytest.approx(480 / 230)
    assert pe == pytest.approx(400 / 30)

    # LQ45 = AAA + CCC; CCC is a loss-maker (no P/E contribution).
    lq_pe, lq_pb = indices["LQ45"]
    assert lq_pb == pytest.approx(280 / 180)   # (200+80)/(100+80)
    assert lq_pe == pytest.approx(10.0)         # AAA only: 200/20

    assert "SECTOR:FIN" in indices and "SECTOR:ENE" in indices


def test_build_emits_the_app_contract_shape():
    bi = BIRate(value=4.75, direction="cut", as_of="2026-01-15")
    snapshot, history = build("2026-01-31", load_rows(), [], {"LQ45": ["AAA", "CCC"]}, bi)

    assert snapshot["asOf"] == "2026-01-31"
    assert snapshot["biRate"] == {"value": 4.75, "direction": "cut", "asOf": "2026-01-15"}
    composite = snapshot["indices"][COMPOSITE]
    assert composite["pb"] == round(480 / 230, 2)
    # First-ever observation ranks against itself → percentile 1.0.
    assert composite["pePctile"] == 1.0
    assert composite["pbPctile"] == 1.0
    assert len(history) == 1


def test_percentile_uses_prior_history_and_bi_rate_optional():
    prior = [{"period": "2025-12-31", "indices": {COMPOSITE: {"pe": 5.0, "pb": 1.0}}}]
    snapshot, history = build("2026-01-31", load_rows(), prior, {}, None)

    composite = snapshot["indices"][COMPOSITE]
    # COMPOSITE pb history = [1.0 (prior), ~2.09 (now)] → now is the max → 1.0.
    assert composite["pbPctile"] == 1.0
    assert len(history) == 2
    assert snapshot["biRate"] is None


def test_build_includes_macro_block_when_present():
    macro = {
        "us10y": MacroSeries(value=4.35, trend="up", as_of="2026-06-03"),
        "broadDollar": MacroSeries(value=121.5, trend="up", as_of="2026-06-03"),
    }
    snapshot, _ = build("2026-01-31", load_rows(), [], {}, None, macro)
    assert snapshot["macro"] == {
        "us10y": {"value": 4.35, "trend": "up", "asOf": "2026-06-03"},
        "broadDollar": {"value": 121.5, "trend": "up", "asOf": "2026-06-03"},
    }


def test_build_macro_is_none_when_absent():
    # Backward-compatible: the existing 5-arg call still works and omits macro.
    snapshot, _ = build("2026-01-31", load_rows(), [], {}, None)
    assert snapshot["macro"] is None


def test_rerunning_a_period_is_idempotent():
    rows = load_rows()
    _, history_once = build("2026-01-31", rows, [], {}, None)
    _, history_twice = build("2026-01-31", rows, history_once, {}, None)
    assert len(history_twice) == 1   # replaced, not duplicated
