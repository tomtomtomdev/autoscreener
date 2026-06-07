# Selection Engine Integration Plan

Integrating `StockSelectionEngine.swift` + `BacktestHarness.swift` (Opus 4.8 reference spec) into
Autoscreener.

---

## Status & how to resume (READ FIRST) — locked 2026-06-06

**Planning is complete and locked. Build is in progress.** This doc is the single source of truth;
it was authored to survive a context clear. To resume, read this section, then continue **§8 (the
canonical build order)** from the next-unbuilt item. All other sections are background/rationale.

**Done (2026-06-06):**
- **Phase 0.1 ✅** — both engine files copied verbatim into the app target at
  `Autoscreener/Features/Selection/{StockSelectionEngine,BacktestHarness}.swift` (the project uses
  Xcode file-system synchronized groups with no membership exceptions, so dropping files under
  `Autoscreener/` auto-adds them to the target — no `.pbxproj` edit). App target **compiles** with
  no errors/collisions. `Reference/selection-engine/*` kept pristine as the locked spec.
- **Phase 0.3 ✅** — confirmed `DisplayNumber.parseDecimal` covers `%`, `( )` negatives, thousands
  separators, `"-"`/blank→nil. **Gap found & pinned:** it does NOT handle magnitude suffixes
  (`B`/`T`). **Closed in Phase 1.1** (below): added sibling `DisplayNumber.parseScaledDecimal`
  (`K`/`M`/`B`/`T` → ×10³/⁶/⁹/¹²) rather than mutate `parseDecimal`, so the ratio/percent callers
  (keystats-ratios, governance) stay byte-for-byte unchanged. Turns out keystats *also* needs it
  (the TTM absolute fields print as `"490 B"`), so it wasn't §1.3-only.
- **Safety net ✅** — characterization/golden-master tests (Swift Testing) added:
  `AutoscreenerTests/SelectionEngineCharacterizationTests.swift` (in-memory Stub `DataProvider` +
  `SecurityData` Object Mother; pins regime branches, every hard gate's failure reason, and the full
  pipeline incl. exact composite/MoS/weight + the 13-line audit trail) and
  `AutoscreenerTests/DisplayNumberTests.swift`. **All green.** This is the baseline Phase 2's
  "industrial path byte-for-byte unchanged" refactor is verified against.
- **Phase 0.2 ✅ (2026-06-07)** — `OHLCV` adapter + the service it needs, built against the
  **verified** wire shape (from the WIFI capture; envelope `{message, data:{paginate:{next_page},
  result:[…]}}`, rows are JSON numbers newest-first with true `value` + `net_foreign`):
  - `Autoscreener/Features/Charts/CompanyPriceFeedService.swift` — `GET company-price-feed/historical/
    summary/{SYM}` (period/start/end/limit/page). Decodes numbers **straight to `Decimal`** (exact;
    no `Double` round-trip), maps APIError→`CompanyPriceFeedError` like `ChartService`, and
    `dailyBars(symbol:from:to:)` walks `next_page` and returns bars **ascending**.
  - `Autoscreener/Features/Selection/SelectionAdapters.swift` — `HistoricalSummaryBar.ohlcv` +
    `Sequence.ohlcvSeries` (sorts ascending; engine expects oldest→newest) and `.foreignNetFlowSeries`
    (free for §1.6). Tests: `AutoscreenerTests/CompanyPriceFeedServiceTests.swift`, all green.
- **Phase 1.1 ✅ (2026-06-07)** — **keystats → `TTMFinancials`**. `DisplayNumber.parseScaledDecimal`
  added (see 0.3). `KeystatsRatioService` gained a reusable `static fieldMap(_:) -> [String:String]`
  (DRY refactor; `parse`→`ValuationRatios` now sits on top of it — characterization-safe, existing
  `KeystatsRatioParseTests` still green). Pure adapter `SelectionFundamentals.ttm(fromKeystats:)` in
  `Autoscreener/Features/Selection/SelectionAdapters.swift` builds the engine `TTMFinancials`.
  **Two unit pitfalls pinned by tests** (`AutoscreenerTests/SelectionFundamentalsAdapterTests.swift`):
  (a) ROE `1461` is a **percent** → ÷100 to a ratio (engine `roeFloor=0.10`); (b) epsGrowth `1471`
  is a **percent-number** kept verbatim (engine PEG does `pe/g`, g≈15). Net Income `1555` / CFO
  `2545` / Total Assets `1559` are scaled (`parseScaledDecimal`). The 6 industrial-essential fields
  throw `AdapterError.missingField` when `"-"` (banks → Phase 2 archetype, not coerced to 0); the 3
  absolute fields (unread by today's gates/scorers, only seed §1.4 shares) degrade to 0.
- **Phase 1.3 ✅ (2026-06-07)** — **industrial balance-sheet extractor**. No new endpoint — reuses
  `FinancialStatementService.load(report:.balanceSheet, basis:.annual)` (the display-string tree).
  Added to `SelectionFundamentals`: `BalanceSheetItems`, `balanceSheetItems(from:) -> [Int:…]`
  (DFS for the *valued* bold subtotal — skips the same-named empty section header that wraps each
  one; verified on WIFI: `Aset Lancar` 8,688 B, `Liabilitas Jangka Pendek` 3,981 B, `Piutang Usaha`
  223 B; parsed with `parseScaledDecimal`, keyed by the year in "12M 2025"), and
  `merging(_:balanceSheet:) -> [AnnualFinancials]` overlaying the 3 fields by year (everything else
  preserved; years with no column / banks lacking the subtotals → 0, which the engine's NCAV /
  forensic consumers guard). Tests: `AutoscreenerTests/BalanceSheetExtractorTests.swift`, all green.
- **Phase 1.4 ✅ (2026-06-07)** — **company fields**. New `Autoscreener/Features/StockDetail/
  EmittenService.swift` (`EmittenServicing`): `info(symbol:)` → `EmittenInfo{symbol,name,sector,
  subSector,indexes}` from `GET /emitten/{SYM}/info`; `profile(symbol:)` → `EmittenProfile{
  freeFloatDisplay,sharesDisplay}` from `GET /emitten/{SYM}/profile.history`. Same error-mapping
  shape as the other exodus services; DTO fields decoded tolerantly. Pure adapters in
  `SelectionFundamentals`: `freeFloat(fromProfile:)` ("40.00%"→0.40 ratio), `sharesOutstanding(
  fromKeystats:)` (NetIncome `1555` ÷ EPS `13200`; loss-maker fallback Common Equity `15883` ÷ BVPS
  `15718`; nil when neither basis), `assigning(sharesOutstanding:toLatestOf:)` (stamps the most-recent
  annual only — NCAV reads `.last`). Note: profile `history.shares` (156 M) lags WIFI's 2025 rights
  issue, so the keystats derivation (~5.3 B) is primary, not the profile count. Tests:
  `AutoscreenerTests/EmittenServiceTests.swift`. **Full `AutoscreenerTests` bundle: TEST SUCCEEDED.**
- **Phase 1.2 ✅ (2026-06-07)** — **fundachart → `[AnnualFinancials]`**. New
  `Autoscreener/Features/Charts/FundachartService.swift` reads `GET fundachart/v2/{SYM}/financials`
  (query is **`data_type`=1/2/3 + `report`** — `report=2` annual / `report=1` quarterly; note this is
  *not* the findata-view `report_type`/`statement_type`). Neutral `FundachartFinancials` (x_axis +
  per-legend `y_axis` decoded straight to `Decimal`, no display parsing). Pure adapter
  `SelectionFundamentals.annualFinancials(income:balance:cashFlow:)` joins data_type 1 (Revenue, Net
  Income), 2 (Total Assets, Total Liabilities), 3 (Operating) **by fiscal year**, sorts ascending,
  sets `shareholderEquity = assets − liabilities`. `currentAssets`/`currentLiabilities`/`receivables`
  (§1.3) and per-year `sharesOutstanding` (§1.4) left **0** (engine guards each consumer). Tests:
  `AutoscreenerTests/FundachartServiceTests.swift` (real WIFI bodies), all green. Full
  `AutoscreenerTests` bundle: **TEST SUCCEEDED**.

- **Phase 1.5 ✅ (2026-06-07)** — **sector → IDX sector-index static map**. Pure adapters in
  `SelectionFundamentals` (`SelectionAdapters.swift`): `sectorIndexBySector` (11-row IDX-IC
  Indonesian-name → index-symbol table, normalized lowercase keys), `sectorIndexSymbols` (the 11
  symbols), `sectorIndexSymbol(forSector:)` (case/whitespace-insensitive name lookup) and
  `sectorIndexSymbol(for: EmittenInfo)` (name map **primary**, falls back to the one sector index in
  `info.indexes` — always present — when the name isn't mapped; nil ⇒ 1.8 leaves `sectorIndexBars`
  empty and the engine's timing modifier already guards on `count`). "Teknologi"→IDXTECHNO and
  "Keuangan"→IDXFINANCE are capture-verified; all 11 index symbols confirmed present in the captures
  (`emitten/company/catalog.pchange_info` lists them). 1.8 fetches the sector bars via the **same**
  historical-summary feed as the stock (`dailyBars(symbol: <sectorIndex>,…).ohlcvSeries`). Tests:
  `AutoscreenerTests/SectorIndexMapTests.swift`, all green.
- **Phase 1.6 ✅ (2026-06-07)** — **broker accumulation signal** (the foreign series was already free
  from 0.2 — `foreignNetFlowSeries`). New `Autoscreener/Features/MarketActivity/BrokerActivityService.swift`
  (`BrokerActivityServicing`) reads `GET order-trade/broker/activity/historical` (pinned
  `interval=INTERVAL_DAILY`, `transaction_type=TRANSACTION_TYPE_NET`, `investor_type=INVESTOR_TYPE_ALL`,
  `market_board=BOARD_TYPE_REGULAR`, `period`, `pagination.limit/page`, optional `broker_codes` CSV).
  Neutral `BrokerActivityRecord{date,netValue,buyValue,sellValue}` (values JSON numbers → `Decimal`
  exact; uses `Decimal` not `Rupiah` to stay engine-independent; same error-mapping shape as the other
  exodus services). Pure adapter `SelectionFundamentals.brokerAccumulationSignal(from:window:)` =
  value-weighted **Σnet / Σ(buy+sell)** over the most-recent `window` records, clamped [-1,1], 0 on no
  activity. **CAVEAT (audit-trailed by the engine):** with no `broker_codes` the endpoint returns the
  *default broker's* net — a true all-broker net is identically zero, so a per-broker series is the
  only meaningful unit; `brokerCodes` is exposed so 1.8 can later track a curated "smart-money" group
  (signal math unchanged). Tests: `AutoscreenerTests/BrokerActivityServiceTests.swift`. **Full
  `AutoscreenerTests` bundle: TEST EXECUTE SUCCEEDED.**
- **Phase 1.7 ✅ (2026-06-07)** — **regime → engine `MarketContext`**. Pure adapter
  `SelectionFundamentals.marketContext(snapshot:marketForeignFlowNet:ihsgDistanceFrom200dma:
  usdIdrChangePercent:breadth:commodityChangePercent:)` in `SelectionAdapters.swift`. The app already
  gathers all seven raw inputs for the Regime screen — this adapter and `RegimeFactorBuilder.factors`
  are two consumers of the **identical** input set, so 1.8 reuses `RegimeViewModel`'s fan-out verbatim
  (snapshot composite valuation pctile, `AggregateForeignFlow.netForeign.raw`, IHSG
  `MovingAverage.distanceFromSMA(_,200)`, USD/IDR change, LQ45 `BreadthReading.fraction`, relevant
  commodity move). **Sign conventions pinned:** distance ≥ 0 ⇒ above trend; USD/IDR > 0 ⇒ rupiah
  weakening; `biRate.direction == .hike` ⇒ rising; net < 0 ⇒ outflow; commodity > 0 ⇒ tailwind.
  **Degradation policy (decided & tested):** `MarketContext` has no optionals but `RegimeFactorBuilder`
  drops absent factors, so each field defaults to the **neutral / no-evidence** value — valuation &
  breadth → 0.5 (mid-cycle; defaulting the dominant valuation driver to "cheapest" would manufacture a
  false risk-on), stress/trend/tailwind booleans → false, net → 0. **1.8 must `throw` on an all-nil
  input set** (mirrors `RegimeViewModel` refusing to read an empty factor list) rather than score a
  phantom regime. Tests: `AutoscreenerTests/MarketContextAdapterTests.swift` (8 cases). **Full
  `AutoscreenerTests` bundle: TEST SUCCEEDED.**

**Next action:** continue **§8 Phase 1** at **1.8** — assemble `StockbitDataProvider: DataProvider`
(fetch + throttle/cache/paywall pre-check; compose the now-complete adapter set: keystats→TTM,
fundachart→annuals, `merging(_:balanceSheet:)`, `assigning(sharesOutstanding:…)`, `ohlcvSeries` for the
stock **and** the `sectorIndexSymbol(for:)` bars, `foreignNetFlowSeries`, `brokerAccumulationSignal`,
`freeFloat`/`sector` from `EmittenService`, and `marketContext(…)` via `RegimeViewModel`'s fan-out —
**throwing when no regime input resolves**). **Every Phase-1 unit data-source + adapter is now built;
1.8 is pure assembly/wiring and completes Phase 1.**

**Capture note:** the 18 MB WIFI capture was moved from `~/Downloads` to the repo root
(`proxseer_collection.json`, **gitignored**) so it's reachable; `-2.json` (BBCA) + `-3.json` are in
`~/Downloads`. Use these for verifying Phase 1 wire shapes (keystats/fundachart are in `-2.json`/`-3.json`).

**Input file locations:**
- Engine spec (reference-only / **not** in any target — the pristine locked copy):
  `Reference/selection-engine/StockSelectionEngine.swift`,
  `Reference/selection-engine/BacktestHarness.swift`. The working copies now live in the app target
  under `Autoscreener/Features/Selection/` (Phase 0.1, done).
- API captures analyzed: `~/Downloads/proxseer_collection.json` (WIFI, industrial),
  `~/Downloads/proxseer_collection-2.json` (BBCA, bank). All findings already distilled into this
  doc — the raw captures are not needed to execute Phase 0–2.

**Decisions locked:**
- Tier A first (data-complete). Tier B (backtest) is a separate later project (Phase 5).
- Integrate via the `DataProvider` seam only; networking layer unchanged (§2).
- Data gaps closed — sources confirmed in §11/§12 (keystats + fundachart + info/profile +
  historical-summary + broker-historical + reports-stream for filing dates).
- Banks/financials: **rework not rewrite** — add a `CompanyArchetype`/`SelectionProfile` seam and a
  financial profile (P/B-vs-ROE valuation). Classifier: `/emitten/info.sector == "Keuangan"` →
  `.financial` (§14, confirmed on BBCA).
- v1 bank profile skips CAR/NPL (not structured); uses equity/assets proxy + ROE/ROA/efficiency.

**Pending (non-blocking) data samples** — capture if convenient, else extractor is written
defensively (§ "what's next"): annual balance sheets `/findata-view/v2/financials/{ASII,UNVR,ADRO,
CTRA}?report_type=2&statement_type=2` (harden the 3-item extractor); one deep
`/company-price-feed/historical/summary/BBCA?period=HS_PERIOD_DAILY&...&limit=1000` (confirm bar depth).

**Open decisions still to make** (don't block Phase 0–1): §10 — universe source
(`/emitten/v3/sector/...` vs an index vs watchlist), default preset + config source (compiled vs JSON).

---

## 1. Goal & scope

Two tiers, shipped independently:

- **Tier A — Live "today's picks".** Run the engine against the *current* Stockbit feed and
  produce ranked, audited recommendations under a chosen `SelectionConfig` preset. **Achievable
  now**; the work is one adapter + one missing parser + three missing data fields.
- **Tier B — Backtester.** Replay the engine over history with no look-ahead and sweep configs.
  **Blocked** — requires a point-in-time persistence layer the app does not have. Deferred; do
  not gate Tier A on it.

The engine and harness are pure and complete. **We change nothing in our networking layer.** Our
only job is to implement two protocols by adapting existing services.

---

## 2. The integration seam

The engine reaches data through exactly two protocols:

```swift
protocol DataProvider {                          // Tier A
    func universe() async throws -> [Ticker]
    func data(for: Ticker) async throws -> SecurityData
    func marketContext() async throws -> MarketContext
}

protocol HistoricalDataSource {                  // Tier B
    var rebalanceDates: [Date] { get }
    func universe(asOf: Date) -> [Ticker]
    func data(for: Ticker, asOf: Date) -> SecurityData    // point-in-time, no look-ahead
    func nextTradableBar(for:after:) -> OHLCV?            // fills at NEXT bar
    func bar(for:on:) -> OHLCV?
    func benchmarkClose(on:) -> Double?
}
```

Everything downstream (gates, scorers, `RegimeAssessor`, sizing, `ConfigSweep`) is already done.

**No type-name collisions.** The spec's `SecurityData`, `AnnualFinancials`, `TTMFinancials`,
`MarketContext`, `MarketRegime`, `RegimePolicy`, `OHLCV`, `Ticker` are all unused in our code. We
have `PriceCandle`/`PriceSeries` (`Charts/ChartModels.swift`) and `StockTicker`
(`StockDetail/FinancialStatementModels.swift`), which do **not** clash.

---

## 3. `MarketContext` ← existing Regime feature (cheap)

`RegimeAssessor.assess` wants seven raw inputs, all of which `RegimeFactorBuilder` already
gathers. `marketContext()` is essentially a re-pack of inputs we compute today. This is a *second*
consumer of those inputs — it does **not** replace `RegimeSynthesizer` (which turns them into a
stance); no conflict.

| `MarketContext` field | Existing source |
|---|---|
| `indexValuationPercentile` | `RegimeSnapshot.indices["IHSG"].pePctile` |
| `breadthAbove200dma` | `BreadthService` (LQ45 % above 200dma) |
| `indexAbove200dma` | `MovingAverage.isAboveSMA` on IHSG bars |
| `idrWeakeningTrend` | `CommodityPriceService` "USD_IDR" change |
| `biRateRising` | `RegimeSnapshot.biRate.direction == .hike` |
| `marketForeignFlowNet` | `AggregateForeignFlowService` (pinned to IHSG) |
| `commodityTailwind` | `CommodityPriceService` (sign of relevant commodity move) |

---

## 4. `SecurityData` field map (the real work)

> **Updated 2026-06-06 — see §11.** A captured API trace (`proxseer_collection.json`,
> 224 `exodus.stockbit.com` calls) closed almost every ❗ in this table. The statuses below are
> the *original* assessment; §11 is authoritative.

Status legend: ✅ have it · ⚙️ adapter/derivation only · ❗ missing data source.

| Engine field | Source / field-id | Status |
|---|---|---|
| `ticker` | symbol | ✅ |
| `price` (`Rupiah`) | keystats `2661`, or chart last close | ✅ |
| `dailyBars: [OHLCV]` | `ChartService` → `PriceCandle` (5y) | ⚙️ adapter (see §6) |
| `marketIndexBars` | `ChartService "IHSG"` | ✅ |
| `sectorIndexBars` | `ChartService` on stock's IDX sector index | ❗ depends on sector gap |
| `ttm.eps` | keystats `13200` | ✅ |
| `ttm.bookValuePerShare` | keystats `15718` | ✅ |
| `ttm.currentRatio` | keystats `1498` | ✅ |
| `ttm.debtToEquity` | keystats `1508` | ✅ |
| `ttm.returnOnEquity` | keystats `1461` | ✅ |
| `ttm.netIncome / operatingCashFlow / totalAssets` | derive from financials (latest TTM) | ⚙️ |
| `ttm.epsGrowthPct` | derive from annual EPS series | ⚙️ |
| `financials: [AnnualFinancials]` | `FinancialStatementService` ×3 reports, annual | ❗ **parser missing (§5)** |
| `foreignNetFlow: [Rupiah]` (per-day series) | `ForeignFlowService` | ❗ snapshot only → degrade to 1-window proxy |
| `brokerAccumulationSignal: Double` | `BandarDetector.accdist` label | ❗ map label → `[-1,1]` scalar |
| `sharesOutstanding: Decimal` | — | ❗ **no source** |
| `freeFloatPct: Ratio` | — | ❗ **no source** (derive from Governance shareholding composition?) |
| `sector: String` (per stock) | — | ❗ **no symbol→sector map** |

`AnnualFinancials` per year needs: `revenue, netIncome` (income report), `operatingCashFlow`
(cash-flow report), `totalAssets, totalLiabilities, currentAssets, currentLiabilities,
shareholderEquity, receivables` (balance sheet), `sharesOutstanding` (❗ not in the tree).

---

## 5. Keystone gap: financial-statement extractor

`FinancialStatementService` returns a **recursive tree of display strings**
(`FinancialAccount { name, values[], children, isEmphasized }`), one `values` entry per period.
Nothing today maps an account → a typed `Decimal` field.

Work:
- An extractor that walks the tree per report and pulls the ~9 line items into `AnnualFinancials`
  by matching localized account names/ids ("Pendapatan", "Total Aset", "Arus Kas dari Operasi", …).
- Parse cells with the existing `DisplayNumber.parseDecimal` (`Core/Common/DisplayNumber.swift`)
  — already handles `"1,688.51"`, `"(5,349)"`, `%`, `"-"`→nil.
- Requires **3 calls per symbol**: `report_type` 1 (income), 2 (balance sheet), 3 (cash flow), all
  `statement_type=2` (annual).
- TDD against existing statement fixtures; matching is the fiddly part (Indonesian labels, totals
  vs. subtotals via `isEmphasized`).

This is the single largest unit of work in Tier A.

---

## 6. Adapter & type concerns

- **`PriceCandle` → `OHLCV`.** Direct map for date/open/high/low/close/volume. **`OHLCV.value`**
  (traded rupiah — used by `LiquidityGate` ADV and `Sizing.liquidityCap`) is **not** on
  `PriceCandle`. Cleanest fix: source ADV from keystats `16454` (Value MA20) rather than summing
  per-bar value; otherwise approximate `value ≈ close × volume`.
- **`Decimal`/`Rupiah` vs `Double`.** Engine money types are `Decimal`; our parsers yield `Double`.
  Trivial conversions at the adapter boundary.
- **Broker signal.** Map `accdist` label → scalar: e.g. `Big Acc=+1, Acc=+0.5, Dist=-0.5,
  Big Dist=-1`. Document the mapping in the audit trail.
- **Foreign-flow degrade.** `ForeignFlowService` returns an aggregate, not a daily series. The
  engine sums a window, so feed the single net as a 1-element window and flag it in the rationale.

---

## 7. Cost / paywall / throttle budget

Per ticker the engine fans out **5–6 calls**: 3× financials + keystats + chart + foreign-flow
(+ broker). Across a universe this is heavy and partly paywalled.

- **Paywalled features:** `PAYWALL_FEATURE_FOREIGN_DOMESTIC`, `PAYWALL_FEATURE_INSIDER`, screener.
  Check `PaywallService` eligibility before fan-out; degrade gracefully on 402/403.
- **Throttle:** Governance already paces 1–1.5s/call. Need a shared rate-limiter + per-symbol
  result cache for a universe-scale run (none exists today).
- Tier A v1 should run against a **small candidate universe** (e.g. a screener result or a
  watchlist), not all of IDX, until caching lands.

---

## 8. Canonical build order

> **This is the authoritative plan.** It folds in the data resolutions (§11/§12), the bank archetype
> (§14), and the open risks (§13), and supersedes the step numbers referenced loosely elsewhere in
> this doc. Per CLAUDE.md: **TDD for every new unit**; **characterization tests** when wrapping the
> existing display-string services or refactoring proven code (Phase 2). Each item names its §ref.

### Phase 0 — Foundations (drop-in + parsing)

0.1 Add `StockSelectionEngine.swift` + `BacktestHarness.swift` to the app target as-is — they
    compile; presets/betas are placeholders tuned later (§ spec header). No type-name collisions (§2).
0.2 `OHLCV` adapter. **Settled (§11):** source dated bars + true rupiah `value` from
    `GET /company-price-feed/historical/summary/{SYM}` (daily, date-range), not the
    `PriceCandle`/keystats workaround. One small adapter `summary row → OHLCV`.
0.3 Confirm `DisplayNumber.parseDecimal` covers every value path it'll now feed (`B`/`T` suffixes,
    `%`, `( )` negatives, `"-"`→nil).

### Phase 1 — `StockbitDataProvider` (industrial path) (§4, §11)

1.1 ✅ **keystats → `TTMFinancials`** (all fields present): eps `13200`, bvps `15718`, currentRatio
    `1498`, D/E `1508`, ROE `1461` (÷100 → ratio), netIncome `1555`, CFO `2545`, totalAssets `1559`
    (all three scaled via `parseScaledDecimal`), epsGrowthPct `1471` (percent-number, verbatim).
    Null-safe (§13-A3): essential fields throw `missingField` on `"-"`; absolute fields degrade to 0.
1.2 ✅ **fundachart → multi-year `AnnualFinancials` core:** Revenue / NetIncome / TotalAssets /
    TotalLiabilities / OperatingCF as raw numerics from `GET /fundachart/v2/{SYM}/financials`
    (`data_type` 1/2/3, `report=2` annual); shareholderEquity = assets − liabilities. Joined by year,
    ascending. (`FundachartService` + `SelectionFundamentals.annualFinancials`.)
1.3 ✅ **Industrial balance-sheet extractor** (§5, reduced): pulls the 3 tree-only items
    `Piutang Usaha` (receivables), `Aset Lancar`, `Liabilitas Jangka Pendek` from the existing
    `FinancialStatementService` (`report:.balanceSheet, basis:.annual`) via `parseScaledDecimal`.
    Reads the *valued* bold subtotal, not the same-named empty section header; keys by fiscal year
    ("12M 2025"→2025). `SelectionFundamentals.balanceSheetItems(from:)` + `merging(_:balanceSheet:)`
    overlays onto the §1.2 annuals; absent items → 0 (banks safe, consumers guard `>0`).
1.4 ✅ **Company fields:** new `EmittenService` (`/emitten/{SYM}/info` → sector/subSector/indexes;
    `/emitten/{SYM}/profile` → free_float/shares). Adapters: `freeFloat(fromProfile:)`
    ("40.00%"→0.40); `sharesOutstanding(fromKeystats:)` = NetIncome `1555` ÷ EPS `13200`, loss-maker
    fallback Common Equity `15883` ÷ BVPS `15718` (§13-A3); `assigning(sharesOutstanding:toLatestOf:)`
    stamps the latest annual (NCAV reads `financials.last`).
1.5 ✅ **Sector → IDX-index static map** (§13-B4) for `sectorIndexBars`: 11-row IDX-IC name→symbol
    table in `SelectionFundamentals` ("Teknologi"→IDXTECHNO / "Keuangan"→IDXFINANCE verified; all 11
    symbols confirmed in `emitten/company/catalog.pchange_info`). `sectorIndexSymbol(for:)` falls back
    to the sector index inside `info.indexes` when the name isn't mapped; nil ⇒ engine omits sector leg.
1.6 ✅ **Flow & broker (real series, §11):** `foreignNetFlow` per-day already free from 0.2
    (`foreignNetFlowSeries`). New `BrokerActivityService` (`order-trade/broker/activity/historical`,
    daily NET) + `SelectionFundamentals.brokerAccumulationSignal` = value-weighted Σnet/Σ(buy+sell)
    over a window, clamped [-1,1]. No "degrade". CAVEAT: unfiltered = default-broker net (per-broker is
    the only meaningful unit; all-broker net is identically 0); `brokerCodes` exposed for later.
1.7 ✅ **`marketContext()`** from `RegimeFactorBuilder` inputs (§3): pure adapter
    `SelectionFundamentals.marketContext(…)` re-packs the same seven raw regime inputs the app already
    gathers into the engine's `MarketContext`. Sign conventions + a neutral/no-evidence degradation
    policy (absent → valuation/breadth 0.5, booleans false, net 0; 1.8 throws on an all-nil set) are
    pinned by `MarketContextAdapterTests`.
1.8 **Assemble `StockbitDataProvider: DataProvider`** + shared throttle / per-symbol cache / paywall
    pre-check (§7, §13-B6) — now ~8 calls/ticker.

### Phase 2 — Archetype seam (the §14 rework — additive, no behavior change)

2.1 Add `enum CompanyArchetype { industrial, financial }` + `struct SelectionProfile { gates,
    scorers, valuator }`; engine gains `profileSelector: (SecurityData) -> SelectionProfile` (DIP).
2.2 Sector → archetype classifier (`"Keuangan"` → `.financial`), driven by 1.4's `sector`.
2.3 **Refactor today's gates/scorers into the `.industrial` profile and dispatch `Valuator` by
    archetype — characterization-tested to prove the industrial path is byte-for-byte unchanged.**

### Phase 3 — Financial (bank) profile (§14)

3.1 Gates: **Capital-strength** (Common Equity `15883` ÷ Total Assets `1559` ≥ floor — the
    available CAR proxy); drop current-ratio / receivables / accruals. Audit-trail the proxy so it's
    never mistaken for true CAR.
3.2 Valuator: **justified P/B = (ROE − g)/(r − g); IV = justified P/B × BVPS**; `g = (1−payout)·ROE`
    capped ≤ Rf (or 2-stage); `r = Rf + β·ERP`. MoS gate reused verbatim.
3.3 Scorers: BankValue (actual P/B `2896` vs justified), BankQuality (ROE `1461` + ROA `1460` +
    efficiency `1562`/cost-to-income), EarningsQuality (NI-growth stability + payout sustainability),
    de-emphasized growth.
3.4 Optional derived inputs from bank-format statements: NIM (`Pendapatan Bunga − Beban Bunga`),
    LDR (`Kredit`/`Deposito`), cost-to-income. **Skip CAR/NPL in v1** (not structured — §14).
3.5 Add `bank: BankParams` + bank presets to `SelectionConfig`. Leave registry open for
    `insurer`/`reit` (YAGNI).

### Phase 4 — Calibration & end-to-end (§13-A2, A3)

4.1 Replace placeholder betas (`marketBeta`/`sectorBeta`) with measured ones (rolling regression over
    historical bars — data now available).
4.2 Null/loss-maker robustness sweep across all gates/scorers (both profiles).
4.3 Run `.balanced` (industrial) **and** a bank preset over a small candidate universe; verify the
    full audit trail end-to-end for one industrial name (e.g. WIFI) **and** one bank (BBCA).

### Phase 5 — Tier B backtest (separate project — §9, §12, §13-C)

5.1 **Persistence layer** (the standing blocker; shared with 1.8 caching).
5.2 **Reports-stream crawler** → store `(symbol, fiscal_period, posted_on, attachment)`; verify
    `last_stream_id` pages back far enough (§12).
5.3 `HistoricalDataSource`: prices/flow as-of via historical-summary + broker-historical;
    fundamentals gated by `posted_on`; handle restatements via the XBRL caveat (§12, §13-C10).
5.4 `ConfigSweep` / preset shootout once point-in-time data is trustworthy.

**Gating:** Phases 0→1→2→3 are sequential (2 depends on 1.4's sector; 3 depends on 2's seam). Phase 4
follows 3. Phase 5 is independent of 2–4 and can start whenever persistence (5.1) is funded.

---

## 9. Tier B (deferred) — what unblocks it

`HistoricalDataSource.data(for:asOf:)` needs **point-in-time snapshots with filing dates**
("financials reported on/before t"). Blockers:

- **No persistence layer.** Every service is a live pass-through — no Core Data / SwiftData /
  SQLite / disk cache anywhere in the app.
- **No filing timestamps.** Stockbit's API doesn't expose when each result became public, so we
  can't reconstruct as-of fundamentals from the live feed without look-ahead.

Unblock by either (a) accumulating daily snapshots into a local store going forward, or (b)
sourcing a historical IDX dataset with as-of/announcement dates (the spec's own sketch assumes a
"FastAPI/SQLite layer"). Treat as a separate project.

---

## 10. Open decisions

- ~~Company-info endpoint for `sharesOutstanding` / `freeFloatPct` / `sector`~~ — **answered (§11):**
  `sector`/`sub_sector` from `/emitten/{SYM}/info`; `free_float` from `/emitten/{SYM}/profile`;
  `sharesOutstanding` derived from keystats (NetIncome `1555` ÷ EPS `13200`).
- ~~ADV source~~ — **answered (§11):** `/company-price-feed/historical/summary/{SYM}` returns
  per-day `value` (traded rupiah) directly; no keystats-MA workaround needed.
- Tier A v1 universe: screener result, watchlist, or a fixed candidate list? (Now also possible via
  `/emitten/company/catalog`, `/emitten/v3/sector/{ID}/subsector/{ID}/company`,
  `/order-trade/market-mover`.)
- Which preset is the default (`.balanced`) and is config loaded from JSON/backend or compiled?
- **New:** still parse the `/findata-view` display-string tree for the 3 balance-sheet items §11
  leaves open, or accept the degradation (disable NCAV + skip the receivables forensic check)?

---

## 11. Gap re-assessment after `proxseer_collection.json` (2026-06-06)

An 18 MB Proxyman capture of the iOS app (224 `exodus.stockbit.com` requests, real bodies for
symbol WIFI) was inspected. It exposes several endpoints the app does **not** use today, which
close almost every open gap. Authoritative over §4/§5/§9.

### ✅ Resolved

| Gap (was) | Now sourced from | Detail |
|---|---|---|
| `sector` / `sub_sector` per stock | `GET /emitten/{SYM}/info` | `data.sector` = `"Teknologi"`, `data.sub_sector` = `"Perangkat Lunak & Jasa TI"`, plus `data.catalogs[]` (id/parent taxonomy) and `data.indexes[]`. Needs a static 11-entry Indonesian-name → IDX sector-index-symbol map (Teknologi→IDXTECHNO) to fetch `sectorIndexBars`. |
| `freeFloatPct` | `GET /emitten/{SYM}/profile` | `data.history.free_float` = `"40.00%"`; cross-checks: `data.listing_information.foreign_percentage/local_percentage`, public shareholder line "MASYARAKAT NON WARKAT". |
| `sharesOutstanding` | keystats (already wired) | Derive: NetIncome TTM `1555` ÷ EPS TTM `13200`, or Common Equity `15883` ÷ BVPS `15718` (both ≈ 5.3 B for WIFI). Per-share source, no new endpoint. |
| `ttm.netIncome / operatingCashFlow / totalAssets` | keystats | Direct fields: Net Income TTM `1555`, **Cash From Operations TTM `2545`**, Total Assets (Q) `1559`. Also Total Liabilities `1560`, Total Equity `21544`, ROA `1460`. No statement-tree parse for the TTM block. |
| `ttm.epsGrowthPct` | keystats | EPS YoY Growth — Annual `1471`, Quarter `1470`, YTD `1472`. (Also Revenue/NetIncome YoY groups.) |
| `foreignNetFlow` **per-day series** | `GET /company-price-feed/historical/summary/{SYM}` | Daily rows with `date, net_foreign, foreign_buy, foreign_sell` over `start_date`/`end_date` (`period=HS_PERIOD_DAILY`, paginated). True series, not the single aggregate. |
| `OHLCV.value` (ADV in rupiah) | same historical-summary endpoint | Per-day `open/high/low/close/volume/**value**/frequency/average` with explicit `date`. Replaces the `PriceCandle`-has-no-value workaround and gives true ADV. |
| `brokerAccumulationSignal` (numeric) | `GET /order-trade/broker/activity/historical` | Daily (`interval=INTERVAL_DAILY`, `date_from`/`date_to`) `net_summary{value,lot,freq}`, `buy/sell_summary`, `total_buy_lot.pct` / `total_sell_lot.pct`, `foreign_summary.net_foreign` → compute a real `[-1,1]` signal instead of mapping the `accdist` label. |
| Multi-year Revenue / NetIncome / TotalAssets / TotalLiabilities / OperatingCF | `GET /fundachart/v2/{SYM}/financials` | **Raw numeric** `y_axis` aligned to `x_axis` (5 fiscal years), no display-string parsing. `data_type=1`→{Net Margin, Revenue, Net Income}; `=2`→{D/E, Total Assets, Total Liabilities}; `=3`→{Operating, Investing, Financing}. e.g. Revenue 2025 = `1659396000000`. `shareholderEquity` ≈ assets − liabilities. |

### ⚠️ Reduced — small parser still required

The **keystone financials extractor (§5) shrinks dramatically.** TTM is all keystats; the 5-year
core is numeric from fundachart. The display-string tree (`/findata-view/v2/financials`) is now
needed **only** for three per-year balance-sheet items that neither keystats (snapshot-only) nor
fundachart (not charted) expose, and that the engine actually consumes:

- `receivables` — `Piutang Usaha` (used by `ForensicGate` receivables-vs-revenue check). Confirmed
  present as a bold subtotal (e.g. `223 B`).
- `currentAssets` — `Aset Lancar` (`8,688 B`) and `currentLiabilities` — `Liabilitas Jangka Pendek`
  (`3,981 B`) — used by `Valuator` NCAV (last year only) and as a Graham cross-check.

These are a **bounded set of ~3 named Indonesian subtotals**, parsed with the existing
`DisplayNumber.parseDecimal`, walking `data_tables.accounts[].accounts[]` (the tree nests
`Aset → Aset Lancar → Piutang Usaha`). Much smaller than the original "map the whole multi-statement
tree" scope. If we accept config degradation (`valuation.useNCAV=false` + skip the receivables
forensic rule), even this parser can be deferred.

### ❌ Still remaining

- **Tier B point-in-time *fundamentals*.** Prices/flow are de-risked (historical-summary and
  broker-activity-historical serve dated daily series). Fundamental **history** is available
  (`/findata-view` 9 annual periods, `/fundachart` 5 years). The old blocker was the **missing
  publication date** — and a second capture (`proxseer_collection-2.json`, BBCA) **resolves it**:
  see §12. What remains for Tier B is now an **engineering** problem (crawl + persist), not a
  missing-data one: there is still no persistence layer, and building a point-in-time timeline means
  paging each company's reports stream back through history and joining filing-date → fiscal-period
  → numbers. Still a separate project, but no longer dependent on an assumed-lag approximation.
- **Sector-name → IDX-index mapping** is a tiny static table we must author (not in the data).
- **Paywall/throttle** unchanged: §7 still applies, and we've now *added* endpoints per ticker
  (info, profile, historical-summary, broker-historical, fundachart×3), so caching/rate-limiting
  matters more, not less.

### Bonus endpoints discovered (not gaps, but useful)

- **Universe building:** `/emitten/company/catalog`, `/emitten/v3/sector/{ID}/subsector/{ID}/company`,
  `/emitten/indexes/mobile`, `/order-trade/market-mover`, `/watchlist`.
- **Enrichment:** `/analyst-ratings/{SYM}` + `/consensus`, `/seasonality/{SYM}`,
  `/research/company/{SYM}`, `/comparison/v2/ratios` (WIFI-vs-INDUSTRY benchmark across 10 metric
  groups), `/company-price-feed/price-performance/{SYM}`, `/emitten-metadata/shareholders/{SYM}/chart`
  (monthly Local/Foreign ownership series).

### Net effect on the plan

The §8 phased plan is largely unchanged in shape but **much cheaper**: step 4 ("source the three
missing fields") is now mostly wiring two new endpoints (`info`, `profile`) + arithmetic; step 3
(the extractor) drops to a ~3-field balance-sheet pull; step 5's foreign-flow "degrade" becomes a
real per-day series; and the ADV/`value` adapter question in §6 is settled. Tier A is now
data-complete. Only Tier B's fundamental as-of history stays blocked.

---

## 12. Financial-report publication date — resolved (2026-06-06, capture #2)

A second capture (`proxseer_collection-2.json`, symbol BBCA) found the **filing/announcement
date** that §11 flagged as the Tier-B blocker. Stockbit mirrors the IDX disclosure feed.

**The chain:**

1. `GET /stream/v3/symbol/{SYM}?category=STREAM_CATEGORY_REPORTS` → `data.stream[]` (paginated 30 /
   page via `last_stream_id`). Each item: `title`, `created_at` (`"2026-01-27 16:51:14"`),
   `type: STREAM_TYPE_REPORT`, and `title_url = streams/announcement/{hash}`.
2. `GET /stream/announcement/{hash}` → `data[]`, one row per attachment, each with:
   - **`posted_on`** = `"2026-01-27 23:39:15"` ← the publication date
   - `headline` = `"Penyampaian Laporan Keuangan Tahunan [BBCA]"`
   - `title` / `attachment` = `FinancialStatement-2025-Tahunan-BBCA.pdf` (+ **.xlsx** and **idxnet
     inline-XBRL** + instance `.zip`)
   - `retrieved_on` (when Stockbit scraped it — *not* the public date; use `posted_on`)

**Identifying the filings** (filter `stream[]` by `headline`/`title`):
- `"Penyampaian Laporan Keuangan **Tahunan**"` → annual (FY). BBCA FY2025 → published **2026-01-27**.
- `"Penyampaian Laporan Keuangan **Interim**…"` → quarterly. BBCA Q1 2026 → published **2026-04-23**.
- Fiscal period comes from the headline/filename (`…-2025-Tahunan-…`, `…Interim…`); the actual
  numbers still come from `findata`/`fundachart`/`keystats` (or the XBRL attachment), joined by
  fiscal period.

**What this changes:** Tier B no longer needs an assumed reporting-lag approximation — it can gate
each period on its **actual** publication date. The remaining Tier-B work is purely engineering:
- **Crawl + persist.** Page each company's REPORTS stream back through the backtest window, keep
  only `Laporan Keuangan` items, store `(symbol, fiscal_period, posted_on, attachment)`. History
  depth via `last_stream_id` is unverified here (capture shows ~6 months / 30 items) — confirm you
  can page back years. This re-introduces the §9 persistence requirement.
- **Corrections.** Watch for `(KOREKSI)` / amended filings and restatements — for point-in-time
  correctness, take the original `posted_on` and treat a correction as new information at its own
  date.
- **Gold path (optional):** the `idxnet-…inlineXBRL.zip` / `instance.zip` attachments are
  machine-readable financials — parsing those would yield numbers *and* date from one source,
  bypassing the display-string tree entirely (bigger lift: XBRL parsing).
- **Auth/paywall** of the stream endpoints is unconfirmed (likely the free social feed, but verify).

---

## 13. What's still missing / open risks (2026-06-06)

Data gaps are largely closed (§11/§12). What remains, prioritized:

### A. Modeling gaps (highest impact — these are in the engine, not the data)

1. **Banks / financials break the engine.** Verified on BBCA: bank balance sheets have **no
   current/non-current split** (no `Aset Lancar`, `Liabilitas Jangka Pendek`, `Piutang Usaha`), and
   keystats returns `Current Ratio`, `Quick Ratio`, `Debt/Equity` as `"-"` (null). So `SolvencyGate`,
   the Graham current-ratio sub-score, the receivables forensic rule, and NCAV are **invalid for
   financials** — and banks/insurers/multifinance are a large slice of IDX cap. `Pendapatan` (top
   line) is also blank for banks (keystats `2997` Revenue uses a net-interest base). **Decision
   needed:** (a) exclude `sector == Keuangan/Financials` from the v1 universe, or (b) make gates
   sector-aware (skip current-ratio/NCAV when null) and add a bank-specific scorer (ROE/NIM/CAR/NPL).
   **→ Resolved by design in §14 (option b, "rework not rethink").**
2. **Betas are placeholders.** `TimingParams.marketBeta=1.0 / sectorBeta=0.5` are hardcoded; the
   spec says "replace with measured." Data is now available (charts / historical-summary) — needs a
   rolling regression per name. Until then the timing modifier is approximate.
3. **Null / loss-maker robustness.** `sharesOutstanding` via NetIncome `1555` ÷ EPS `13200` fails
   when EPS ≤ 0 (loss-makers) — need a fallback (Equity ÷ BVPS, or profile share counts). Many
   keystats fields can be `"-"`; every gate/scorer must be null-safe, not coerce to 0.

### B. Tier A engineering (known, deferrable for a small-universe v1)

4. **Sector-name → IDX-index map** — author the static 11-row table (enumerate the exact Indonesian
   names from `/emitten/company/catalog`; we've only seen "Teknologi").
5. **Universe definition** — pick the source (`/emitten/company/catalog` vs sector vs watchlist vs
   market-mover) and confirm it returns a clean symbol list.
6. **Throttle + per-symbol cache** — now ~8 endpoints/ticker; no rate-limiter/cache exists yet.
7. **Balance-sheet extractor** (industrials only: receivables / current assets / current
   liabilities) — still to write, or accept degradation.

### C. Tier B (after the §12 publication-date win)

8. **Persistence layer** — still nonexistent; the #1 Tier-B blocker (shared with #6).
9. **Reports-stream history depth** — unverified that `last_stream_id` pages back *years* (capture
   shows ~6 months).
10. **Point-in-time *values* vs restatements** — the filing date says *when*, but `findata`/
    `fundachart` return *today's* view of old periods, which may be **restated**. True PIT requires
    parsing the period's **XBRL attachment** (the only as-reported source), not the live endpoints.
11. **Unverified access** — auth/paywall of the stream + historical endpoints; and
    `historical-summary` date-range **depth** (capture only showed ~1 year).

### D. Minor / edge

12. **Multi-currency** — keystats carries `financial_year_groups_usd`; some IDX issuers report in
    USD. Normalize to IDR (or per-share, currency-agnostic) before gating.
13. **Coverage breadth** — confirm `free_float` / share counts are populated across the universe,
    not just large caps.

---

## 14. Accommodating banks / financials — rework, not rethink (2026-06-06)

**Verdict: extend the engine, don't rewrite it.** The pipeline architecture is already correct —
`Gate`, `Scorer`, and the `Valuator` sit behind protocols + a `SelectionConfig` value type, which is
exactly Open/Closed. The core layers (regime → MoS gate → composite → rank → constrained sizing) are
**archetype-agnostic** because scorers already emit a normalized `[0,1]` value: only the *producers*
of those scores (which gates run, which scorers, which intrinsic-value formula) differ for a bank.
So we add a strategy seam and a second profile; we change none of the proven industrial code.

### The one new concept: `CompanyArchetype` → `SelectionProfile`

```
enum CompanyArchetype { case industrial, financial }      // open for insurer/REIT later
struct SelectionProfile { let gates: [Gate]; let scorers: [Scorer]; let valuator: Valuator }
// Engine gains:  profileSelector: (SecurityData) -> SelectionProfile   (DIP — depends on abstraction)
```

Classify each name from `/emitten/{SYM}/info.sector` (e.g. `"Keuangan"` → `.financial`). The default
selector maps sector → archetype; the engine runs whatever profile it returns. New bank gates/scorers
conform to the **existing** `Gate`/`Scorer` protocols (LSP — substitutable). `SelectionConfig` gains a
parallel `bank: BankParams` block + bank presets; `Valuator.intrinsicValue/marginOfSafety` become
archetype-dispatched (or move onto the profile). Backtester is untouched.

### What the financial profile swaps (Damodaran financial-firm approach)

| Layer | Industrial (today) | Financial (new) | Data |
|---|---|---|---|
| Hard gates | `Solvency` (current ratio, D/E), `Forensic` (receivables, accruals) | **Capital strength**: Common Equity ÷ Total Assets ≥ floor; drop current-ratio / receivables / accruals (all null/meaningless) | keystats `15883/1559` ✅ |
| Valuation / MoS | Graham Number, NCAV | **Justified P/B = (ROE − g)/(r − g); IV = justified P/B × BVPS** | ROE `1461`, BVPS `15718`, payout `2916`→g ✅ |
| Value scorer | Graham MoS + P/B + current ratio | actual P/B vs ROE-justified P/B (cheapness *given* ROE) | P/B `2896` ✅ |
| Quality scorer | ROE + margin consistency + trend | ROE `1461` + ROA `1460` + efficiency (operating margin `1562` / cost-to-income) | ✅ |
| Earnings quality | CFO/NI | NI-growth stability + payout sustainability (CFO/NI is noisy for banks) | ✅ |
| Growth (Lynch) | PEG | loan / EPS growth, de-emphasized | ✅ |
| Flow + timing modifiers, regime, sizing | — | **unchanged** | — |

### The key formula (replaces Graham Number for financials)

```
g  = (1 − payout) × ROE,  capped at ≤ risk-free rate (terminal discipline)
r  = Rf + β·ERP            (IDR: Rf ≈ Indo 10y, β_bank ≈ 1.0–1.2, ERP from Damodaran dataset)
justified P/B = (ROE − g) / (r − g)
IV/share      = justified P/B × BVPS
MoS           = (IV − price) / IV          ← unchanged; the MoS gate is reused verbatim
```

**Worked check on BBCA** (real capture values): ROE 22.41%, payout 63% → g = 8.25% (must cap ≤ Rf
≈ 6.5%, or go 2-stage — a high-ROE/high-retention bank can't compound that forever). With r ≈ 6.5%
+ 1.1×7% ≈ 14.2% and g capped ~6.5%: justified P/B = (0.224−0.065)/(0.142−0.065) ≈ **2.07** vs actual
**2.41** → IV/price ≈ 0.86, i.e. ~14% rich (negative MoS, screened out). Coherent, sensible result —
the approach works on real data, not just in theory.

### Data reality (honest scope)

- **Direct from keystats:** ROE, ROA, P/B, BVPS, payout, yield, margins, growth, equity, assets — the
  whole value + quality + capital-proxy block. ✅
- **Derivable from the bank-format statements** (small extractor): NIM (`Pendapatan Bunga − Beban
  Bunga` ÷ earning assets), LDR (`Kredit`/`Deposito`), cost-to-income.
- **NOT available as structured data: CAR and NPL** (regulatory — live in notes/XBRL/IDXNet, not the
  summary feeds). **v1: use Common-Equity÷Total-Assets as a capitalization proxy and skip NPL**; add a
  proper source (XBRL/notes) later. State this in the audit trail so the proxy is never mistaken for
  true CAR.

### Phasing

1. Add `CompanyArchetype` + sector→archetype classification (`/emitten/info`).
2. Add `SelectionProfile` selection to the engine (industrial = existing set; financial = new set).
3. Implement financial gates/scorers/valuator on **available** data (P/B–ROE, ROE/ROA/efficiency,
   equity/assets). Skip CAR/NPL in v1.
4. Add `bank: BankParams` + bank presets to `SelectionConfig`.
5. Leave the archetype registry open for `insurer` / `reit` — don't build them yet (YAGNI).
