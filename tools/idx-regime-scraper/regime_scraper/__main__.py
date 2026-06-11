from __future__ import annotations

import argparse
import json
import sys
from datetime import date, timedelta
from pathlib import Path
from typing import Dict, List, Tuple

from .build import build, compute_indices, history_record, upsert_history
from .sources import fetch_bi_rate, fetch_idx_ratios, fetch_macro_series

ROOT = Path(__file__).resolve().parent.parent  # tools/idx-regime-scraper/
CONSTITUENTS_DIR = ROOT / "constituents"


def load_constituents(directory: Path = CONSTITUENTS_DIR) -> Dict[str, List[str]]:
    """Each ``constituents/<index>.json`` → ``{"<INDEX>": [codes...]}`` (e.g.
    ``lq45.json`` → ``LQ45``). Accepts either a bare JSON list or ``{"constituents": [...]}``."""
    out: Dict[str, List[str]] = {}
    if not directory.is_dir():
        return out
    for path in sorted(directory.glob("*.json")):
        try:
            data = json.loads(path.read_text())
        except (json.JSONDecodeError, OSError):
            continue
        codes = data.get("constituents") if isinstance(data, dict) else data
        if isinstance(codes, list):
            out[path.stem.upper()] = [str(c).strip().upper() for c in codes]
    return out


def load_history(path: Path) -> List[dict]:
    if not path.is_file():
        return []
    try:
        data = json.loads(path.read_text())
    except (json.JSONDecodeError, OSError):
        return []
    if isinstance(data, list):
        return data
    if isinstance(data, dict) and isinstance(data.get("history"), list):
        return data["history"]
    return []


def default_period() -> Tuple[int, int]:
    """IDX monthly statistics lag, so default to the previous month."""
    first_of_this_month = date.today().replace(day=1)
    prev = first_of_this_month - timedelta(days=1)
    return prev.year, prev.month


def month_end(year: int, month: int) -> str:
    """ISO date of the last day of the month — the snapshot's ``asOf``."""
    nxt = date(year + 1, 1, 1) if month == 12 else date(year, month + 1, 1)
    return (nxt - timedelta(days=1)).isoformat()


def _months_back(year: int, month: int, count: int) -> List[Tuple[int, int]]:
    """The ``count`` months immediately before ``(year, month)``, oldest first."""
    out: List[Tuple[int, int]] = []
    y, m = year, month
    for _ in range(count):
        m -= 1
        if m == 0:
            m, y = 12, y - 1
        out.append((y, m))
    return list(reversed(out))


def run(argv: List[str] = None) -> int:
    parser = argparse.ArgumentParser(prog="regime_scraper", description="Build regime.json from IDX/BI data.")
    parser.add_argument("--year", type=int, help="stats year (default: previous month)")
    parser.add_argument("--month", type=int, help="stats month 1-12 (default: previous month)")
    parser.add_argument("--backfill", type=int, default=0, metavar="N",
                        help="also fetch the N months before the target to seed percentile history")
    parser.add_argument("--out-dir", default=str(ROOT / "dist"), help="where to write the JSON files")
    parser.add_argument("--no-bi", action="store_true", help="skip the BI-rate fetch (offline/testing)")
    parser.add_argument("--no-macro", action="store_true",
                        help="skip the US fed-funds/10y/dollar fetch (offline/testing)")
    args = parser.parse_args(argv)

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    snapshot_path = out_dir / "regime.json"
    history_path = out_dir / "regime-history.json"

    constituents = load_constituents()
    history = load_history(history_path)
    year, month = (args.year, args.month) if args.year and args.month else default_period()

    if args.backfill > 0:
        for y, m in _months_back(year, month, args.backfill):
            try:
                recs = fetch_idx_ratios(y, m)
            except Exception as exc:  # noqa: BLE001 — one bad month shouldn't abort backfill
                print(f"[backfill] {y}-{m:02d} failed: {exc}", file=sys.stderr)
                continue
            if not recs:
                continue
            history = upsert_history(history, history_record(month_end(y, m), compute_indices(recs, constituents)))
            print(f"[backfill] {y}-{m:02d}: {len(recs)} records")

    records = fetch_idx_ratios(year, month)
    if not records:
        print(f"no IDX ratio records for {year}-{month:02d}", file=sys.stderr)
        return 1

    bi_rate = None if args.no_bi else fetch_bi_rate()
    macro = None if args.no_macro else fetch_macro_series()
    snapshot, history = build(month_end(year, month), records, history, constituents, bi_rate, macro)

    snapshot_path.write_text(json.dumps(snapshot, indent=2) + "\n")
    history_path.write_text(json.dumps(history, indent=2) + "\n")
    print(f"wrote {snapshot_path.name} + {history_path.name} ({len(history)} history points, "
          f"{len(records)} stocks, asOf {snapshot['asOf']})")
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
