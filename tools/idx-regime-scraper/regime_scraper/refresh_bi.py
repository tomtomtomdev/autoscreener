"""Cheap daily BI-rate refresh — the mid-month companion to the monthly snapshot job.

BI decides its policy rate mid-month (e.g. 22 Apr → 20 May → 9 Jun), but the full
``regime.json`` is rebuilt only monthly (it depends on IDX's month-end, Cloudflare-gated
ratios). So a rate move used to lag the app by up to ~26 days. This entry point re-reads
the already-published ``regime.json``, fetches just the BI rate (plain bi.go.id HTML — no
IDX, no curl_cffi), and rewrites the file with only ``biRate`` patched. Run daily, it
lands a rate change within a day; the workflow commits only when the bytes actually
change. ``regime-history.json`` (monthly percentile series) is never touched.

Usage:
    python -m regime_scraper.refresh_bi                 # read+write <root>/dist/regime.json
    python -m regime_scraper.refresh_bi --out-dir dist  # explicit dir
    python -m regime_scraper.refresh_bi --no-bi         # offline no-op (testing)
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import List

from .build import patch_bi_rate
from .sources import fetch_bi_rate

ROOT = Path(__file__).resolve().parent.parent  # tools/idx-regime-scraper/


def run(argv: List[str] = None) -> int:
    parser = argparse.ArgumentParser(
        prog="regime_scraper.refresh_bi",
        description="Patch the BI rate in an already-published regime.json.")
    parser.add_argument("--out-dir", default=str(ROOT / "dist"),
                        help="dir holding regime.json (read in place, written back)")
    parser.add_argument("--no-bi", action="store_true",
                        help="skip the BI-rate fetch (offline/testing) — leaves the file unchanged")
    args = parser.parse_args(argv)

    snapshot_path = Path(args.out_dir) / "regime.json"
    if not snapshot_path.is_file():
        # The monthly job must seed the data branch first; there's nothing to patch.
        print(f"no {snapshot_path} to refresh — run the monthly snapshot job first", file=sys.stderr)
        return 1

    snapshot = json.loads(snapshot_path.read_text())
    before = snapshot.get("biRate")

    bi_rate = None if args.no_bi else fetch_bi_rate()
    if bi_rate is None:
        print("BI-rate fetch unavailable — leaving the published rate unchanged", file=sys.stderr)
        return 0

    patched = patch_bi_rate(snapshot, bi_rate)
    if patched.get("biRate") == before:
        print(f"BI rate unchanged ({before}) — nothing to publish")
        return 0

    snapshot_path.write_text(json.dumps(patched, indent=2) + "\n")
    print(f"BI rate {before} -> {patched['biRate']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
