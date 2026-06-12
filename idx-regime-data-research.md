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
| **L4 Regime** — *synthesis / read* | ✅ Have | `RegimeSynthesizer` + `RegimeViewModel`/`RegimeView` (Market Regime screen): weighted risk-on/neutral/risk-off read across all nine factors (valuation, BI rate, **US 10y**, **broad USD**, **S&P 500 trend**, foreign flow, IHSG trend, rupiah, breadth), with the Howard-Marks late-cycle valuation guard (an expensive market can't read risk-on). Breadth built (see below); valuation percentile + BI rate + the **`macro` intermarket anchors** (US fed funds/10y/broad dollar) consumed from the `regime.json` contract (`RegimeSnapshotService`); S&P 500 is a live `ChartService` leg — **real** snapshot values await the §6 scraper, read degrades to live factors until then. |
| **§3** LQ45 breadth (% > 200dma) | ✅ Have | `BreadthService` over `LQ45Constituents` + `ChartService` (`MovingAverage`) |
| **§4** liquidity floor | ✅ Have | screener veto gates 5B/10B IDR |
| **§4** Graham Number / valuation ratios | ✅ Have | `KeystatsRatioService` (keystats/ratio) + `GrahamNumber` calc |
| **§4** forensic / governance screens | ❌ Missing | unbuilt |
| **§5** paper trading / microstructure / journal | ❌ Missing | entirely unbuilt |
| **§6** performance vs IHSG | ❌ Missing | unbuilt |

**Key point (now closed):** the app has both the L4 *instruments* and the L4 *regime read* — the
synthesis the doc is actually about (how aggressive to be). The read combines valuation percentile
(weighted 2× as the dominant driver of future risk), BI-rate direction, the **intermarket macro
anchors** (US fed funds/10y yield & the broad trade-weighted dollar — rising = EM headwind = risk-off,
Murphy intermarket chain), the **S&P 500 200-day trend** (live global risk appetite), aggregate
foreign flow, IHSG trend vs. 200dma, the rupiah, and LQ45 breadth into a single posture, and is
framed as cycle position, not a forecast. **Data sourcing (2026-06-12):** BI rate and the macro
anchors are now fetched **live on-device** (`BIRateService` + `FREDMacroService`, see §3) and merged
*over* `regime.json`; only the **valuation percentile** (`indices`) still depends on the §6
server-side scraper (Cloudflare-gated IDX feed + multi-year history). The published `biRate`/`macro`
in `regime.json` are now just an offline fallback. Until the scraper publishes, the read runs on its
live factors (BI rate / macro / foreign flow / IHSG trend / rupiah / breadth / S&P 500) alone.

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

## 3. Macro — BI policy rate + global intermarket anchors

| Source | Verdict |
|---|---|
| **Yahoo Finance** | ❌ has FX (`IDR=X`) and US yields (`^TNX`), **no BI rate, no ID bond-yield ticker** |
| **bi.go.id** `…/statistik/indikator/BI-Rate.aspx` | ✅ **best** — 200, server-rendered HTML with an **inline history table** (date + rate), no Cloudflare. Source-of-truth, free. HTML scrape (no JSON API). |
| **FRED** `fredgraph.csv?id=IRSTCB01IDM156N` | ✅ fallback/cross-check for BI rate — monthly, CSV, no key, lagged |

BI sets the rate on RDG board-meeting days (~monthly). **Now fetched live on-device**
(`BIRateService`): bi.go.id HTML primary → FRED CSV fallback, parsed by `MacroParsing` (the Swift port
of `bi_rate.py`), refreshed in the sweep on a 12h in-memory TTL. This replaced the old daily Python
refresh job (`refresh_bi.py` + `bi-rate-refresh.yml`, both removed) — the app now picks up a mid-month
rate move within a sweep, so the BI rate no longer waits on the monthly snapshot.

### 3a. Global intermarket anchors (left end of the chain → EM flows → IDR → IHSG)

The same free FRED CSV path (`fredgraph.csv?id=<SERIES>`, no key) supplies the global anchors. **Now
fetched live on-device** (`FREDMacroService`, parsed by `MacroParsing`), merged over `regime.json`'s
`macro` block (which the §6 monthly job still emits as the offline fallback); each is read
**directionally** (`trend`: up/down/flat over a ~1-month window) rather than as a discrete policy move.

| Series | FRED id | Role in the read |
|---|---|---|
| US fed funds | `DFF` | policy-rate context behind the 10y (rides in the factor *detail*, not the vote, to avoid double-counting the US leg) |
| US 10y yield | `DGS10` | the global discount-rate / EM-flow anchor — **rising = risk-off** |
| Broad trade-weighted USD | `DTWEXBGS` | rupiah/flow pressure — **rising = risk-off**. Chosen over ICE **DXY** (which is **not** a Stockbit symbol and is EUR-heavy); the broad index is the EM/rupiah-relevant gauge |
| **S&P 500 (live, not scraped)** | — | global **risk appetite**: Stockbit serves `SP500` on the same `charts/{symbol}/daily` path as IHSG, so the app reads its **200-day trend** live (above = risk-on), no scraper dependency |

Permissive value parsing matters: the BI/`parseRate` path bounds values < 50 (a policy-rate
plausibility check), which would wrongly reject the dollar index (~121) — so the macro series use
their own magnitude-agnostic `parseFREDValue` (`MacroParsing` on-device; `parse_fred_value` in
`regime_scraper/macro.py` server-side — same rule, two implementations kept in sync).

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

**Scope narrowed (2026-06-12):** the monthly job's *authoritative* output is now the **`indices`
(valuation/percentile) block only** — the one leg that genuinely can't run on-device (Cloudflare-gated
IDX feed + a multi-year monthly history to rank against). BI rate (input 2/3) and the FRED macro block
(input 4) are now **fetched live on-device** (§3 / §3a — `BIRateService` + `FREDMacroService`); the job
still emits them into `regime.json` as an offline fallback, but they are no longer the source of truth.
The separate **daily BI-rate refresh job was retired** (`refresh_bi.py`, `bi-rate-refresh.yml`,
`build.patch_bi_rate` — all removed), since the app now tracks mid-month rate moves itself.

**Inputs (all confirmed free + reachable via one `curl_cffi` scraper):**
1. IDX `LINK_FINANCIAL_DATA_RATIO` → cap-weighted index P/E·P/B (Composite + sectors; LQ45/IDX30 via constituents config). **← the job's sole authoritative leg now.**
2. bi.go.id BI-Rate table → level + direction (hike/hold/cut). *(fallback only — app fetches live)*
3. (cross-check) FRED `IRSTCB01IDM156N`. *(fallback only)*
4. FRED `DFF` / `DGS10` / `DTWEXBGS` → the `macro` block (US fed funds / US 10y / broad dollar), each `{value, trend, asOf}` (§3a). *(fallback only — app fetches live)* `--no-macro` skips it; one failed series is omitted, not fatal.

**Architecture:** Python + `curl_cffi`, run by a **GitHub Actions** monthly cron
(`workflow_dispatch` too). Writes `regime.json` (snapshot) + `regime-history.json` (the monthly
series for percentiles) to the `data` branch. The macOS/iOS app does a plain `URLSession` GET of
the raw JSON, computes percentile + risk-on/neutral/risk-off, renders the regime read — **no
Cloudflare logic on-device.**

**`regime.json` contract (draft):**
```json
{ "asOf": "2026-01-31",
  "biRate": { "value": 4.75, "direction": "cut", "asOf": "2026-01-15" },
  "macro": {
    "usFedFunds":  { "value": 4.33,  "trend": "down", "asOf": "2026-01-31" },
    "us10y":       { "value": 4.10,  "trend": "down", "asOf": "2026-01-31" },
    "broadDollar": { "value": 119.0, "trend": "flat", "asOf": "2026-01-31" }
  },
  "indices": {
    "COMPOSITE": { "pe": 13.2, "pb": 2.1, "pePctile": 0.42, "pbPctile": 0.55 },
    "LQ45":      { "pe": 12.1, "pb": 1.9, "pePctile": 0.38, "pbPctile": 0.49 }
  } }
```
`macro` (and any individual series) is **optional** — `null`/absent for a pre-macro snapshot or a
skipped/failed fetch, decoding to `macro == nil` on the app side (`RegimeSnapshot.MacroBlock` /
`MacroSeries`), so the read degrades to its IDX-side factors exactly like a missing `biRate`.

**Verification:** pytest on parse/aggregation against a saved real fixture; Swift decode +
percentile test under `-UITestFixtures`.

> **On-device consumer status (built):** the contract above is implemented as `RegimeSnapshot`
> (`Decodable`) and fetched read-only by `RegimeSnapshotService` (plain `URLSession`, no auth, no
> Cloudflare on-device) from the `data`-branch raw URL — now used for the **`indices` block**.
> **BI rate + macro are fetched live on-device** by `BIRateService` (bi.go.id HTML → FRED CSV) and
> `FREDMacroService` (DFF/DGS10/DTWEXBGS), parsed by `MacroParsing` (the Swift port of `bi_rate.py` +
> `macro.py`), and merged *over* the published snapshot in `DataSweepCoordinator.sweepRegime`
> (device wins, published = fallback, 12h in-memory TTL). `RegimeSynthesizer` turns the merged inputs
> (plus the live flow / trend / rupiah / breadth / S&P 500 factors) into the read. **The server-side
> job is built** (`tools/idx-regime-scraper/`, pytest green); only its first GitHub Actions run that
> publishes the `indices`/history to the `data` branch remains. Until then the snapshot fetch 404s and
> the read runs on the live on-device factors (incl. BI rate + macro) by design.

---

## 7. Open gaps & next steps

**In the regime job (now built — `tools/idx-regime-scraper/`):**
1. LQ45/IDX30 valuation — constituents config shipped (`constituents/lq45.json`, `idx30.json`;
   maintained at each Feb/Aug rebalance). ✅
2. Loss-maker + outlier handling — baked into `aggregate_index` (drop non-positive equity, exclude
   loss-makers from PE both sides, winsorise extreme per-stock ratios). ✅
3. Remaining: the **first GitHub Actions run** that publishes `regime.json` + `regime-history.json`
   to the `data` branch (use the `backfill` input once to seed 5–10y of percentile history). Until
   that runs, the app's `RegimeSnapshotService` 404s and the read uses live factors only.

**Regime read (now built — `Features/Regime/`):**
- §3 aggregate foreign flow ✅ (`AggregateForeignFlowService`); LQ45 breadth % > 200dma ✅
  (`BreadthService` + `LQ45Constituents` + `MovingAverage`).
- §3a intermarket macro anchors ✅ — `usRates` (US 10y, fed funds in detail) + `globalDollar` (broad
  USD) factors read from `snapshot.macro` via `RegimeSynthesizer.globalHeadwindSignal` (rising =
  risk-off); `globalEquities` ✅ — the live S&P 500 200-day trend (`ChartService` `SP500` →
  `MovingAverage.distanceFromSMA(_,200)`, reuses `trendSignal`). Both `RegimeViewModel.load` and
  `StockbitDataProvider.fetchMarketContext` fan-outs fetch `SP500` and stay byte-for-byte identical.
- §3 synthesis ✅ — `RegimeSynthesizer` (pure, fully unit-tested) + `RegimeViewModel`/`RegimeView`.
  Weighted vote (nine factors; macro/global legs weight 1, valuation 2×), one-sided late-cycle
  valuation guard, graceful degradation when a factor (or the whole snapshot/`macro` block) is missing.
- §6 scraper ✅ built (`tools/idx-regime-scraper/` + `.github/workflows/idx-regime.yml`): cap-weighted
  index P/E·P/B (Composite + sectors + LQ45/IDX30) — its sole authoritative leg now — plus BI rate +
  macro as an offline fallback, pytest-covered, emits the app contract. BI rate + macro are otherwise
  fetched live on-device (`BIRateService`/`FREDMacroService`); the daily Python refresh job is retired.
  Only its **first publishing run** to the `data` branch remains — until then the valuation-percentile
  and BI-rate factors are absent and the read uses live factors (flow/trend/rupiah/breadth) only.

**Wider flow (separate tasks, unbuilt):**
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
