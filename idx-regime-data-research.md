# IDX Regime & Data-Sourcing Research

Companion to [`idx-investing-research.md`](./idx-investing-research.md). That doc defines the
*methodology* (the four-layer flow: fundamentals / flow / charts / regime). **This doc records
where each layer can actually be sourced**, what the app already has, which feeds were verified
live, and the plan for the server-side **regime job** that closes the top-down (§3) gaps.

> Verified live June 2026 against the user's own Stockbit session and public IDX/BI endpoints.
> All endpoints below are referenced by path only — **no tokens/cookies are stored in this repo**
> (see Security note).

---

## 1. App coverage vs. the four-layer flow

| Layer (from `idx-investing-research.md`) | App status | Where |
|---|---|---|
| **L1 Fundamentals** (IS/BS/CF) | ✅ Have | `FinancialStatementService` (3 statements, annual+quarterly) |
| **L2 Who** — broker summary (per-stock) | ✅ Have | `BrokerSummaryService` `/marketdetectors/{sym}` |
| **L2 Who** — foreign flow (per-stock) | ✅ Have | `ForeignFlowService` `/foreign-domestic/.../{sym}` |
| **L3 When** — charts (OHLCV) | ✅ Have | `ChartService` (stocks/indices/sectors, multi-timeframe) |
| **L4 Regime** — instruments | ✅ Have | `MarketCatalog` (IHSG, LQ45, IDX30/80, 11 sectors, commodities, USD/IDR) |
| **L4 Regime** — *synthesis / read* | ❌ Missing | no aggregate flow, no valuation percentile, no breadth, no BI rate, no risk-on/off output |
| **§4** liquidity floor | ✅ Have | screener veto gates 5B/10B IDR |
| **§4** Graham Number / valuation ratios | ✅ Have | `KeystatsRatioService` (keystats/ratio) + `GrahamNumber` calc |
| **§4** forensic / governance screens | ❌ Missing | unbuilt |
| **§5** paper trading / microstructure / journal | ❌ Missing | entirely unbuilt |
| **§6** performance vs IHSG | ❌ Missing | unbuilt |

**Key point:** the app has the L4 *instruments* but not the L4 *regime read* — the synthesis the
doc is actually about (how aggressive to be). Index price alone is one input of four; it gives
trend, not altitude (valuation), flow durability, breadth, or the macro driver.

---

## 2. Stockbit / `exodus` API → gap mapping

Derived from a captured Postman collection of the Stockbit iOS app (`exodus.stockbit.com`).
Endpoints that close gaps the app doesn't yet use:

| Gap | Stockbit endpoint | Verdict |
|---|---|---|
| §3 **aggregate foreign flow** | `/findata-view/foreign-domestic/v1/chart-data/IHSG?market_type=&period=` | ✅ **Built** — `AggregateForeignFlowService` (per-stock family pinned to `IHSG`) |
| §3 breadth (adv/dec) | `/order-trade/market-mover?mover_type=`, `/order-trade/top-stock` | 🟡 proxy |
| §4 valuation history | `/keystats/ratio/v1/{sym}?year_limit=10` | ✅ **Built** — `KeystatsRatioService`; PE/PBV/BVPS/EPS + current/quick (Graham inputs) |
| §4 forensic/governance | `/insider/company/majorholder`, `/insider/shareholding/composition/...`, `/emitten-metadata/subsidiary/{sym}`, `/corpaction/{sym}` | ✅ ownership, related-party, dilution/rights |
| §5 microstructure | `/company-price-feed/v2/orderbook/companies/{sym}`, `/order-trade/running-trade`, `/company-price-feed/market-time/session` | ✅ depth + executed ticks + session |
| L2 deeper flow | `/order-trade/broker/top`, `/broker/distribution`, `/broker/activity/historical` | ✅ market-wide + historical broker flow |

**Not in this API:** BI policy rate, **index-level P/E percentile** (see §4–§5 below), and all
paper-trading *state* (positions/journal/performance — local by design).

### Verified Stockbit endpoints (live, 200)
- `/keystats/ratio/v1/{sym}?year_limit=10` → grouped ratios (**built: `KeystatsRatioService`**):
  **Valuation** (PE annualised+TTM, P/S, **P/B**, P/CF, P/FCF, EV/EBITDA), **Per-share** (EPS, **BVPS**,
  Cash/sh, FCF/sh), **Solvency** (**Current 3.09 / Quick 2.45 / D/E 1.38**), plus Profitability (ROE 31.87%),
  Dividend, IS/BS/CF, Growth, Price-Performance. → Graham Number `√(22.5·EPS·BVPS)` direct (TPIA ≈ 2034).
  Wire: `data.closure_fin_items_results[].fin_name_results[].fitem{id,name,value}`; `value` is a display
  string (`"1,688.51"`, `"(5,349)"`=neg, `"31.87%"`, `"-"`=n/a). Map by **stable `id`**: PE 12148 ·
  PE-TTM 2891 · P/S 2893 · P/B 2896 · P/CF 16533 · P/FCF 15881 · EV/EBITDA 21457 · EPS-TTM 13200
  (EPS-annualised 12988) · BVPS 15718 · Cash/sh 15879 · FCF/sh 15882 · Current 1498 · Quick 1500 · D/E 1508.
- `/emitten/{sym}/info` → price, **previous close**, **board** (Papan Utama/Akselerasi),
  `notation[]` (UMA flags), top-of-book, index membership. **No ARA/ARB field** → compute from BEI
  rules + previous close. (Corrects an earlier assumption.)
- `/emitten/indexes/mobile` → index **levels + %change** only. **No P/E / P/B / market cap.**
  → index valuation must come from IDX, not Stockbit.

---

## 3. Macro — BI policy rate

| Source | Verdict |
|---|---|
| **Yahoo Finance** | ❌ has FX (`IDR=X`) and US yields (`^TNX`), **no BI rate, no ID bond-yield ticker** |
| **bi.go.id** `…/statistik/indikator/BI-Rate.aspx` | ✅ **best** — 200, server-rendered HTML with an **inline history table** (date + rate), no Cloudflare. Source-of-truth, free. HTML scrape (no JSON API). |
| **FRED** `fredgraph.csv?id=IRSTCB01IDM156N` | ✅ fallback/cross-check — monthly, CSV, no key, lagged |

BI sets the rate on RDG board-meeting days (~monthly) → scrape BI **weekly** if you want it
announcement-fresh; FRED is monthly.

---

## 4. IDX index-statistics feed (the index P/E percentile source)

idx.co.id runs an undocumented JSON backend powering its public **Statistical Reports → Digital
Statistic** pages. **Free** (no auth/subscription) but **Cloudflare-gated** — plain `curl`/
`URLSession` get the "Attention Required" challenge; **`curl_cffi` (TLS impersonation) clears it,
confirmed even from a datacenter IP** (so CI hosting works).

Exact endpoints (verified live, 200 JSON):

```
# per-stock ratios, monthly — the real source for index valuation
GET https://www.idx.co.id/primary/DigitalStatistic/GetApiDataPaginated
    ?urlName=LINK_FINANCIAL_DATA_RATIO
    &periodYear={YYYY}&periodMonth={M}&periodType=monthly
    &isPrint=False&cumulative=false&pageSize=500&pageNumber={n}
# fields: code, sector, sectorCode, per, priceBV, eps, bookValue,
#         profitAttrOwner, equity, roe, roa, npm, deRatio, assets, liabilities, sales

# per-index PERFORMANCE (close/high/low, month1/3/6, YTD, ranks) — NO PER/PBV, NO members
GET .../GetApiDataPaginated?urlName=LINK_IDX_INDICES_HIGHLIGHT&periodYear=&periodMonth=&...

# daily index level (OHLC/value/volume, no ratios)
GET https://www.idx.co.id/primary/TradingSummary/GetIndexSummary?lang=id&date={YYYYMMDD}&start=0&length=
```

- **Format:** JSON backend, or downloadable Statistical Reports (Excel/PDF) and per-index
  **Factsheets** (`idx.co.id/Media/.../fs-{INDEX}-{YYYY-MM}.pdf`).
- **Granularity:** monthly for ratios. ~120 points / 10y — fine for a regime percentile.
- **Backfill:** the ratio endpoint is parameterized by month → loop past months to build 5–10y of
  percentile history on first run (no "build forward and wait").
- **Paid alternative:** **IDX Data Services** = the official system-to-system real-time/EOD
  licensed feed (via vendors). The actual paywall — *not needed* for monthly index valuation.

---

## 5. Index P/E · P/B percentile — method & verification

**Do not average member P/Es** (ratio-mean bias + loss-makers blow up). Use the cap-weighted
aggregate. Market cap is derived robustly from P/B (works for loss-makers):

```
Mcap_i   = priceBV_i × equity_i            # = price/BVPS × total equity = market cap
Index PB = Σ Mcap_i / Σ equity_i           # over equity_i > 0
Index PE = Σ Mcap_i / Σ (Mcap_i / per_i)   # over per_i > 0 (exclude loss-makers BOTH sides)
```

Robustness rules: drop non-positive `equity`; exclude loss-makers from PE numerator *and*
denominator (a discovery run that excluded them only from the denominator inflated COMPOSITE PE to
22.4); winsorize extreme per-stock ratios (e.g. tiny/negative-equity names).

**Verified** (2026-01, 958 listed companies, one endpoint, no membership lookup):
- COMPOSITE **P/B = 2.36** (IHSG historically ~2.2–2.6 ✓).
- Sectors rank sensibly: Tech P/B 4.6, Healthcare 4.6, Financials 1.6, Industrials 1.2.
- **Composite + all 11 IDX-IC sectors compute with zero membership data** (group by `sectorCode`).

**Membership gap:** LQ45 / IDX30 valuation needs a constituent list — *not* in the ratio table and
*not* in the indices-highlight payload. Resolve via a small `constituents/*.json` config refreshed
at the Feb/Aug rebalance. Non-blocking: IHSG (the doc's actual requirement) = COMPOSITE, covered.

Note: this method won't exactly match IDX's published IHSG PER (different convention). Irrelevant
for percentile (self-consistent); only matters if displaying "matches IDX".

---

## 6. Plan — server-side monthly regime job

Approved approach: a server-side monthly job that scrapes the free feeds, aggregates, and serves
the app a clean static JSON. Decisions locked: **static `regime.json` committed to this repo**
(raw URL), code in **`tools/idx-regime-scraper/`** with data on a **`data` branch**, scope
**Composite + LQ45 + 11 sectors**.

**Inputs (all confirmed free + reachable via one `curl_cffi` scraper):**
1. IDX `LINK_FINANCIAL_DATA_RATIO` → cap-weighted index P/E·P/B (Composite + sectors; LQ45/IDX30 via constituents config).
2. bi.go.id BI-Rate table → level + direction (hike/hold/cut).
3. (cross-check) FRED `IRSTCB01IDM156N`.

**Architecture:** Python + `curl_cffi`, run by a **GitHub Actions** monthly cron
(`workflow_dispatch` too). Writes `regime.json` (snapshot) + `regime-history.json` (the monthly
series for percentiles) to the `data` branch. The macOS/iOS app does a plain `URLSession` GET of
the raw JSON, computes percentile + risk-on/neutral/risk-off, renders the regime read — **no
Cloudflare logic on-device.**

**`regime.json` contract (draft):**
```json
{ "asOf": "2026-01-31",
  "biRate": { "value": 4.75, "direction": "cut", "asOf": "2026-01-15" },
  "indices": {
    "COMPOSITE": { "pe": 13.2, "pb": 2.1, "pePctile": 0.42, "pbPctile": 0.55 },
    "LQ45":      { "pe": 12.1, "pb": 1.9, "pePctile": 0.38, "pbPctile": 0.49 }
  } }
```

**Verification:** pytest on parse/aggregation against a saved real fixture; Swift decode +
percentile test under `-UITestFixtures`.

---

## 7. Open gaps & next steps

**In the regime job:**
1. LQ45/IDX30 valuation — needs a constituents config (Composite + sectors don't).
2. Loss-maker + outlier handling — bake into the scraper (above).

**Wider flow (separate tasks, unbuilt):**
- §3 aggregate foreign flow ✅ built (`AggregateForeignFlowService`); LQ45 breadth (% > 200dma) still unbuilt.
- §4 Graham Number ✅ built (`KeystatsRatioService` + `GrahamNumber`); forensic/governance screens unbuilt.
- §5 paper trading + IDX microstructure (lot/tick/ARA-ARB/fees) + journal.
- §6 performance vs IHSG total return.

---

## Security note

The Postman collection this research drew from embeds **live Bearer JWTs, session cookies, and a
personal email**. It is **not** part of this repo and must never be committed. Treat it as a
secret and rotate if shared. Scraping idx.co.id / bi.go.id uses public data but is ToS-gray —
monthly cadence keeps it low-risk.

## Sources
- IDX Statistical Reports — https://www.idx.co.id/en-us/market-data/statistical-reports/statistics/
- IDX Index Summary — https://idx.co.id/en-us/market-data/trading-summary/index-summary/
- IDX Data Services (paid) — https://www.idx.co.id/en/products/idx-data-services/
- Bank Indonesia BI-Rate — https://www.bi.go.id/id/statistik/indikator/BI-Rate.aspx
- FRED Indonesia central-bank rate — https://fred.stlouisfed.org/series/IRSTCB01IDM156N
- IDX backend endpoint reference (open-source wrapper) — https://github.com/NeaByteLab/IDX-API
