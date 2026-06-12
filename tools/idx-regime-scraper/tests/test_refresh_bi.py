import copy
import json

from regime_scraper import refresh_bi
from regime_scraper.build import patch_bi_rate
from regime_scraper.models import BIRate

# A published snapshot with a stale BI rate and the surrounding monthly fields the
# refresh must not disturb (this is the bug: 4.75/cut lingered while BI had moved to 5.50).
STALE_SNAPSHOT = {
    "asOf": "2026-05-31",
    "biRate": {"value": 4.75, "direction": "cut", "asOf": "2026-01-15"},
    "macro": {"us10y": {"value": 4.35, "trend": "up", "asOf": "2026-05-31"}},
    "indices": {"COMPOSITE": {"pe": 13.2, "pb": 2.1, "pePctile": 0.42, "pbPctile": 0.55}},
}


def test_patch_updates_only_birate_and_preserves_the_monthly_fields():
    fresh = BIRate(value=5.50, direction="hike", as_of="2026-06-09")
    out = patch_bi_rate(STALE_SNAPSHOT, fresh)

    assert out["biRate"] == {"value": 5.50, "direction": "hike", "asOf": "2026-06-09"}
    # The monthly IDX vintage and its derived fields are untouched by a BI refresh.
    assert out["asOf"] == "2026-05-31"
    assert out["macro"] == STALE_SNAPSHOT["macro"]
    assert out["indices"] == STALE_SNAPSHOT["indices"]


def test_patch_does_not_mutate_the_input():
    before = copy.deepcopy(STALE_SNAPSHOT)
    patch_bi_rate(STALE_SNAPSHOT, BIRate(value=5.50, direction="hike", as_of="2026-06-09"))
    assert STALE_SNAPSHOT == before


def test_patch_keeps_existing_birate_when_fetch_failed():
    # A failed live fetch (None) must not wipe a previously-good rate to null.
    out = patch_bi_rate(STALE_SNAPSHOT, None)
    assert out["biRate"] == STALE_SNAPSHOT["biRate"]


def test_patch_sets_birate_when_snapshot_had_none():
    snap = {"asOf": "2026-05-31", "biRate": None, "indices": {}}
    out = patch_bi_rate(snap, BIRate(value=5.50, direction="hike", as_of="2026-06-09"))
    assert out["biRate"] == {"value": 5.50, "direction": "hike", "asOf": "2026-06-09"}


def _seed(tmp_path):
    (tmp_path / "regime.json").write_text(json.dumps(STALE_SNAPSHOT) + "\n")


def test_run_rewrites_only_birate_when_the_rate_moved(tmp_path, monkeypatch):
    _seed(tmp_path)
    monkeypatch.setattr(refresh_bi, "fetch_bi_rate",
                        lambda: BIRate(value=5.50, direction="hike", as_of="2026-06-09"))

    assert refresh_bi.run(["--out-dir", str(tmp_path)]) == 0
    out = json.loads((tmp_path / "regime.json").read_text())
    assert out["biRate"] == {"value": 5.50, "direction": "hike", "asOf": "2026-06-09"}
    assert out["indices"] == STALE_SNAPSHOT["indices"]  # monthly fields preserved


def test_run_leaves_file_byte_identical_when_rate_unchanged(tmp_path, monkeypatch):
    _seed(tmp_path)
    original = (tmp_path / "regime.json").read_text()
    monkeypatch.setattr(refresh_bi, "fetch_bi_rate",
                        lambda: BIRate(value=4.75, direction="cut", as_of="2026-01-15"))

    assert refresh_bi.run(["--out-dir", str(tmp_path)]) == 0
    assert (tmp_path / "regime.json").read_text() == original  # no spurious commit


def test_run_does_not_blank_the_rate_on_fetch_failure(tmp_path, monkeypatch):
    _seed(tmp_path)
    original = (tmp_path / "regime.json").read_text()
    monkeypatch.setattr(refresh_bi, "fetch_bi_rate", lambda: None)

    assert refresh_bi.run(["--out-dir", str(tmp_path)]) == 0
    assert (tmp_path / "regime.json").read_text() == original


def test_run_errors_when_nothing_is_published_yet(tmp_path):
    # Data branch not seeded → nothing to patch; surface it rather than writing a stub.
    assert refresh_bi.run(["--out-dir", str(tmp_path), "--no-bi"]) == 1
