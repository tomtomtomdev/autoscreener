# idx-regime-scraper

Builds the static **`regime.json`** the macOS/iOS app reads for the top-down regime
read — the two inputs the app can't source on-device: the **BI policy rate** and the
**cap-weighted index P/E·P/B percentile** vs. each index's own history.

Companion to [`idx-regime-data-research.md`](../../idx-regime-data-research.md) §4–§6
(sources, aggregation method, and the plan) and to the app-side consumer in
`Autoscreener/Features/Regime/` (`RegimeSnapshotService` + `RegimeSynthesizer`).

## What it produces

- **`regime.json`** — the latest snapshot, matching the app's `RegimeSnapshot` contract:

  ```json
  { "asOf": "2026-01-31",
    "biRate": { "value": 4.75, "direction": "cut", "asOf": "2026-01-15" },
    "indices": {
      "COMPOSITE":  { "pe": 13.2, "pb": 2.1, "pePctile": 0.42, "pbPctile": 0.55 },
      "LQ45":       { "pe": 12.1, "pb": 1.9, "pePctile": 0.38, "pbPctile": 0.49 },
      "SECTOR:...": { "pe": 0.0,  "pb": 0.0, "pePctile": 0.0,  "pbPctile": 0.0 }
    } }
  ```

  The app reads `COMPOSITE` (and `LQ45` when present); the `SECTOR:*` keys are extra
  and safely ignored by the decoder.

- **`regime-history.json`** — the monthly series of raw `pe`/`pb` per index that the
  percentiles are computed against. Re-running a month is idempotent (upsert by period).

Both are published to the **`data` branch**; the app fetches the raw URL
(`RegimeSnapshotService.defaultURL`).

## Data sources (all free)

| Input | Source | Notes |
|---|---|---|
| Index P/E·P/B | IDX `LINK_FINANCIAL_DATA_RATIO` | Cloudflare-gated → `curl_cffi` TLS impersonation |
| BI policy rate | bi.go.id `BI-Rate.aspx` (HTML) | plain HTML; falls back to FRED on failure |
| BI rate (fallback) | FRED `IRSTCB01IDM156N` (CSV) | monthly, no key, lagged |

## Method (`idx-regime-data-research.md` §5)

Market cap is derived from P/B so it works for loss-makers:
`Mcap = priceBV × equity`. Then `Index PB = ΣMcap / Σequity` and
`Index PE = ΣMcap / Σ(Mcap/per)` over profitable names only (loss-makers excluded
from both sides). Non-positive equity is dropped and extreme per-stock ratios are
winsorised. Percentile = fraction of the index's own history at or below today's value.

## Layout

```
regime_scraper/
  aggregate.py    §5 cap-weighted P/E·P/B  (pure)
  percentile.py   percentile rank          (pure)
  bi_rate.py      BI HTML + FRED CSV parse (pure)
  build.py        compose the snapshot     (pure)
  models.py       StockRatio / BIRate
  sources.py      live HTTP (lazy curl_cffi) — the only impure module
  __main__.py     CLI: fetch → build → write
constituents/     LQ45 / IDX30 membership (maintained at each Feb/Aug rebalance)
tests/            pytest over the pure logic against saved fixtures
```

## Run

```bash
pip install -r requirements.txt          # curl_cffi + beautifulsoup4 (live only)
python -m regime_scraper                  # previous month → ./dist/
python -m regime_scraper --year 2026 --month 1 --backfill 120   # seed 10y of history
python -m regime_scraper --no-bi          # skip the BI fetch
```

## Test

```bash
python -m pytest -q                       # pure logic only — no network, no curl_cffi
```

The pure modules import without `curl_cffi`/`beautifulsoup4`; those are needed only for
the live `sources` path (lazy-imported), so the suite runs anywhere `pytest` does.

## Automation

`.github/workflows/idx-regime.yml` runs monthly (cron) and on demand
(`workflow_dispatch`, with a `backfill` input), runs the tests, builds the snapshot
seeded from the existing history, and commits both files to the `data` branch.

## Notes

- Scraping idx.co.id / bi.go.id is public data but ToS-gray; the monthly cadence keeps
  it low-risk. No tokens or cookies are stored here.
- `constituents/*.json` must be refreshed at each IDX rebalance (Feb & Aug); a stale
  name just fails to load and is excluded from that index's aggregate.
