# Captured-Endpoint Integration Spec

Wiring five additional Stockbit endpoint families into the `DataProvider` seam, using
shapes reverse-engineered from a live capture and following the existing service /
test / UITest conventions verbatim.

- **Source capture:** `~/Downloads/proxseer_collection-4.json` — Postman v2.1 export of
  Stockbit iOS **3.21.5** traffic, **2026-06-11**, account `uid:248236`.
- **Conventions mirrored:** `APIClient.send/sendRaw` + `Endpoint` (base
  `https://exodus.stockbit.com`), explicit `CodingKeys` (no `.convertFromSnakeCase`),
  `DisplayNumber` for formatted-string numbers, `RequestThrottle.paced { }`,
  `DataProvider` seam in `StockSelectionEngine.swift`, `StubSession`-driven Swift Testing
  tests, `UITestSupport` stub structs.
- **Scope boundary:** this spec covers **services + DTOs + tests + plumbing into
  `SecurityData`/`MarketContext` as optional best-effort fields** (Slices 1–4), **plus** the
  scorer calibration that feeds those overlays into scoring as capped, inert-on-`nil` tilts
  (Slice 6 — see §8). It deliberately does **not** add hard gates from these signals, and leaves
  the cap values as paper-trading sweep targets.

---

## 1. Data-availability triage (read this first)

The capture proves the request shape for all five, but two return **no payload** for the
captured symbols (TPIA and the IHSG index) — so their *populated* response models cannot be
derived from this capture and must not be invented.

| Endpoint | Captured `data` | Buildable from this capture? |
|---|---|---|
| `GET /comparison/v2/ratios?symbol=X` | full (10 metric groups × symbol matrix) | ✅ **Yes** |
| `GET /seasonality/{SYM}?year=&back_year=` | full (monthly up/down/avg/prob table) | ✅ **Yes** |
| `GET /order-trade/*` (distribution, top-stock, market-mover, running-trade, trade-book, broker/top, broker/activity) | full | ✅ **Yes** |
| `GET /analyst-ratings/{SYM}` | orig `null`; **BBCA re-capture: full** | ✅ **Yes** — DTO finalized vs BBCA (§3.4) |
| `GET /analyst-ratings/{SYM}/consensus` | orig `[]`; **BBCA re-capture: full** | ✅ **Yes** — forward-estimate series, finalized (§3.4) |
| `GET /research/company/{SYM}` | `{id:0, symbol:"", content:"", masks:{}}` — **empty even for BBCA** | ⚠️ **Shape known, payload empty everywhere** (genuinely dead per-symbol note, §3.5) |
| `GET /research?keyword=` + `/research/indicator/new` | full (25 Snips articles + `{has_new,count}` badge) | ✅ **Yes** — the real "Research" tab feed (`stockbit.com.har`); §3.6, not yet built |

**Implication:** all five families now have verified shapes. The original capture left analyst-ratings
`null`/`[]`; a **covered-large-cap re-capture (BBCA, `proxseer_collection (2).json`)** unblocked both
analyst endpoints — DTOs finalized in §3.4. `research/company` stayed `content:""` even for BBCA, so it
remains a verified-but-empty endpoint (the in-app research detail is the separate Snips content site —
HTML, not this JSON; §3.5). Modeling fields off naming guesses would be unverifiable — so analyst-ratings
shipped as a skeleton first, then was finalized only once the BBCA payload existed.

---

## 2. Shared primitives (new, used by several services)

### 2.1 `StockbitEnvelope<T>` — generic response wrapper
Every endpoint returns `{ "message": String, "data": <T?> }`, and `data` is legitimately
`null` (analyst-ratings) or `[]` (consensus). A generic envelope handles null cleanly and
removes per-service boilerplate. Place in `Core/Networking/DTO/`.

```swift
nonisolated struct StockbitEnvelope<T: Decodable>: Decodable {
    let message: String
    let data: T?            // optional — tolerates `"data": null`
}
```

### 2.2 `StockbitValue` ✅ — the `{raw, formatted}` pair
**Shipped (Slice 2)** at `Core/Networking/DTO/StockbitValue.swift`; `StockbitValueTests` (6).
`order-trade/*` wraps numbers as `{ "raw": …, "formatted": "…" }`. **`raw` is inconsistently
typed** — `Int` in `market-mover`, a numeric **`String`** in `top-stock` / `broker/top` /
`running-trade/chart`. A tolerant decoder is mandatory (and gets its own test).

```swift
nonisolated struct StockbitValue: Decodable, Sendable, Equatable {
    let raw: Double?        // parsed from Int, Double, or numeric String
    let formatted: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatted = (try? c.decode(String.self, forKey: .formatted)) ?? ""
        if let i = try? c.decode(Int.self, forKey: .raw) { raw = Double(i) }
        else if let d = try? c.decode(Double.self, forKey: .raw) { raw = d }
        else if let s = try? c.decode(String.self, forKey: .raw) { raw = DisplayNumber.parseDecimal(s) }
        else { raw = nil }
    }
    enum CodingKeys: String, CodingKey { case raw, formatted }
}
```

`DisplayNumber` (already in `Core/Common/`) covers the *formatted-only* strings:
`"154,423 B"` via `parseScaledDecimal`, `"31.87%"`/`"-"` via `parseDecimal`. **Reuse it; do
not add a second parser.**

---

## 3. Service specs

All services: `nonisolated final class XService: XServicing`, inject `APIClient`, map errors
exactly like `KeystatsRatioService` (`401`→`.unauthorized`, `402|403`→`.paywall`, other
`APIError`→`.network`). DTOs are `private` structs at end-of-file. Domain models are
`Sendable, Equatable`. Files live under `Features/<Area>/`.

### 3.1 `ComparisonRatiosService` ✅ — peer ratio table
**File:** `Features/StockDetail/ComparisonRatiosService.swift`
**Endpoint:** `GET comparison/v2/ratios?symbol={SYM}` — server auto-selects 2 sector peers,
so `data.symbols` has 3 entries: `[subject, peer, peer]`.

Captured `data`: `symbols: [String]`, `metric_groups: [{ metric_group_name, metric: [{
fitem_id, fitem_name, ratios: [{ symbol, value }] }] }]`. 10 groups (Valuation, Profitability,
…); `value` is a formatted string (`"154,423 B"`, `"12.07"`, `"-"`).

```swift
nonisolated struct PeerComparison: Sendable, Equatable {
    let symbols: [String]                 // [subject, peer, peer]
    let groups: [PeerMetricGroup]
    func metric(named: String) -> PeerMetric? { groups.lazy.flatMap(\.metrics).first { $0.name == named } }
}
nonisolated struct PeerMetricGroup: Sendable, Equatable { let name: String; let metrics: [PeerMetric] }
nonisolated struct PeerMetric: Sendable, Equatable {
    let id: Int
    let name: String                      // "Market Cap", "PE", "PBV", …
    let raw: [String: String]             // symbol → formatted value
    let numeric: [String: Double]         // symbol → DisplayNumber.parseScaledDecimal(value)
}

private struct ComparisonDTO: Decodable {            // decode via StockbitEnvelope<ComparisonDTO>
    let symbols: [String]
    let metricGroups: [Group]
    enum CodingKeys: String, CodingKey { case symbols; case metricGroups = "metric_groups" }
    struct Group: Decodable {
        let name: String; let metrics: [Metric]
        enum CodingKeys: String, CodingKey { case name = "metric_group_name"; case metrics = "metric" }
    }
    struct Metric: Decodable {
        let fitemID: Int; let fitemName: String; let ratios: [Ratio]
        enum CodingKeys: String, CodingKey { case fitemID = "fitem_id"; case fitemName = "fitem_name"; case ratios }
    }
    struct Ratio: Decodable { let symbol: String; let value: String }
}
```

**Selection use (follow-up):** the subject's **rank/percentile vs its peers** on PE / PBV /
EV-EBITDA → a relative-cheapness factor. Peers are server-chosen (same sector), which is
exactly the right comparison set.

### 3.2 `SeasonalityService` ✅ — monthly win-rate / avg return
**✅ SHIPPED (Slice 3, 2026-06-12).** `Features/StockDetail/SeasonalityService.swift`
(`SeasonalityServicing → Seasonality`); `SeasonalityServiceTests` (9: endpoint / parse — incl.
negative avg + "Year" aggregate / null-envelope throw / error mapping).
**Endpoint:** `GET seasonality/{SYM}?year={Y}&back_year={B}` (`backYear` defaults to 0).

Captured `data`: five parallel columns each wrapped as `{ "columns": [{ name, value, color }] }`
(**not** a bare array) — `up`, `down`, `total_months`, `avg` (avg % return), `prob` (P(up) %) —
with 13 entries (Jan … Dec + a `"Year"` aggregate, kept as a 13th `SeasonalMonth`). Also present
but dropped: `price_change` (per-year grid), `default_last_year`, and the UI-only hex `color`.
Values are strings; counts parse as `Int`, `avg`/`prob` via `DisplayNumber.parseDecimal`
(handles the negative `avg` like `"-3.00"`). Zip uses `up.columns` as the canonical ordered spine.

```swift
nonisolated struct Seasonality: Sendable, Equatable {
    let symbol: String
    let months: [SeasonalMonth]           // zipped by month name across the parallel arrays
    func month(_ name: String) -> SeasonalMonth? { months.first { $0.name == name } }
}
nonisolated struct SeasonalMonth: Sendable, Equatable {
    let name: String                      // "Jan" … "Dec" (+ aggregate)
    let upCount, downCount, totalYears: Int
    let avgReturnPct, probabilityUpPct: Double
}
// DTO: column = { name, value: String, color: String }; zip up/down/total/avg/prob by `name`.
```

**Selection use (follow-up):** **soft overlay only** — current calendar month's
`probabilityUpPct`/`avgReturnPct` as a small timing tilt; never a hard gate (thin signal,
survivorship-prone). Primary value is the StockDetail UI table.

### 3.3 Order-trade bandar/flow family ✅
`order-trade/broker/activity/historical` is **already wired** (`BrokerActivityService`,
feeds `brokerAccumulationSignal`). The live feeds split by usefulness:

**Tier 1 — selection-relevant — ✅ SHIPPED (Slice 2)** as one cohesive family service,
`Features/MarketActivity/OrderTradeFlowService.swift` (`OrderTradeFlowServicing`), `OrderTradeFlowServiceTests`:

| Method | Endpoint | Key query | Drives | Status |
|---|---|---|---|---|
| `distribution(symbol:)` | `order-trade/broker/distribution` | `symbol, data_type=BROKER_DISTRIBUTION_DATA_TYPE_VALUE, period=TB_PERIOD_LAST_1_DAY, investor_type=…_ALL, market_board=MARKET_TYPE_REGULER` | per-ticker bandar concentration | ✅ built |
| `topStocks(valueType:page:)` | `order-trade/top-stock` | `value_type=VALUE_TYPE_NET, market_type=MARKET_TYPE_REGULER, investor_type, period=TOP_STOCK_PERIOD_LATEST, page` | market accumulation leaderboard | ✅ built |
| `marketMovers(type:)` | `order-trade/market-mover` | `mover_type, filter_stocks×N, limit` | gainers/losers + net foreign | ⏸ deferred (not in Slice 2) |

```swift
// distribution — "who is accumulating THIS stock today"  (amount is a JSON Int on the wire)
nonisolated struct BrokerDistribution: Sendable, Equatable {
    let symbol: String, date: String
    let topBuyers: [DistributionLeg]      // by value, descending
    let topSellers: [DistributionLeg]
    func buyConcentration(topN: Int = 3) -> Double?   // Σ(top-N buy value) ÷ Σ(all buy); nil if no buy side
}
// NB renamed BrokerLeg → DistributionLeg: BrokerLeg already exists (the richer /marketdetectors
// Bandar-Detector leg in BrokerSummaryModels.swift). `type` kept as raw String ("Lokal"/"Asing"/
// "Pemerintah") — could reuse the existing InvestorCategory enum later.
nonisolated struct DistributionLeg: Sendable, Equatable { let code: String; let type: String; let amount: Double }
// DTO: data.by_value.top_broker_buy[].detail{code,type,amount:Int}; top_broker_sell mirror (distribute_to ignored).

// top-stock — market-wide net buy/sell leaders  (value/lot/foreign_value are StockbitValue; raw is a numeric String)
nonisolated struct FlowLeaderboard: Sendable, Equatable { let topBuy: [FlowRow]; let topSell: [FlowRow] }
nonisolated struct FlowRow: Sendable, Equatable {
    let rank: Int; let code: String
    let value, foreignValue, lot: StockbitValue
}
nonisolated enum TopStockValueType: String, Sendable { case net = "VALUE_TYPE_NET", gross = "VALUE_TYPE_GROSS", total = "VALUE_TYPE_TOTAL" }
// DTO: data.top_buy[].{rank, code, value{raw:String,formatted}, foreign_value{…}, lot{…}} (average/frequency/icon_url dropped)
```

**Tier 2 — UI / analysis (defer; spec'd, not in first cut):**
`running-trade` (live tick tape), `running-trade/chart/{SYM}` (intraday price + per-broker
cumulative, ~560 KB), `trade-book` + `trade-book/chart` (price-ladder / time buckets),
`broker/top` (broker league table), `broker/activity` (per-broker stock picks),
`broker/activity-chart` (~440 KB). These are large, display-oriented, and not selection
inputs — wire them when the StockDetail "Bandarmology" tab is built.

### 3.4 `AnalystRatingsService` ✅ — DTOs FINALIZED vs BBCA re-capture (Slice 5, 2026-06-13)
**File:** `Features/StockDetail/AnalystRatingsService.swift` (`AnalystRatingsServicing` →
`coverage(symbol:) -> AnalystCoverage?` / `consensus(symbol:) -> [AnalystEstimateSeries]`);
`AnalystRatingsServiceTests` (13).
**Endpoints:** `GET analyst-ratings/{SYM}` and `…/consensus`. Empty (`null`/`[]`/missing) ⇒
"no coverage" (`nil`/`[]`), **not** an error.

**Unblocked & finalized** against a covered-large-cap re-capture (BBCA, `proxseer_collection (2).json`,
2026-06-12 — the §1/§6 re-capture). The earlier skeleton's *hypothesized* fields were both wrong;
the verified shapes are:
- **Coverage** = `{ price_target{ best_target, best_low_target, best_high_target, current_price },
  recommendation:String, total_buy, total_sell, total_hold, total_analyst, last_updated }` → domain
  `AnalystCoverage` (nested `AnalystPriceTarget` + counts + `recommendation` + computed
  `targetUpsidePct` = (best−current)/current; BBCA ≈ +49%).
- **Consensus** is **not** rating rows — it's a **forward-estimate series**: `[{ name, items:[{ year,
  is_estimate, value:String, raw_value }] }]` for Revenue / Op. Profit / Net Income / EPS → domain
  `AnalystEstimateSeries`/`AnalystEstimate`. `raw_value` is `0` on the wire (figure lives in the
  display-string `value`), parsed via `DisplayNumber.parseScaledDecimal` (`"118,573 B"`→`118_573e9`,
  EPS `"466.74"` unscaled).

Tests cover the populated decode (both endpoints) + the null/empty degradation + error mapping.
**Still NOT plumbed into `SecurityData`/scoring** (user scoped this to "DTOs + tests only") — the
`analystCoverage` overlay + any target-upside/recommendation tilt remain a separate, opinionated
calibration pass (Slice-6 style), deferred.

### 3.5 `ResearchService` ⚠️ — thin, display-only ✅ SHIPPED (Slice 5, 2026-06-13); content STILL data-blocked
**File:** `Features/StockDetail/ResearchService.swift` (`ResearchServicing → CompanyResearch?`);
`ResearchServiceTests` (7 — incl. a populated-decode test, since the shape is verified).
**Endpoint:** `GET research/company/{SYM}` → `{ id, symbol, content, masks }`. Modelled directly;
empty `content` (or absent `data`) ⇒ `nil` ("no research"), so a returned `CompanyResearch` always
carries non-empty `content`. `masks` is left **undeclared** (skipped) — purpose unknown.

**`content` is empty for EVERY symbol captured, incl. the BBCA re-capture** (TPIA, IHSG, BBCA all
`content:""`) → this per-symbol research note appears genuinely **unused/dead**. The app's actual
"Research" tab is **not** this endpoint — it's the **research feed** (`GET /research?keyword=`,
§3.6), a keyword-searchable list of **Stockbit Snips** articles. `CompanyResearch` stays modelled (so
a populated note degrades cleanly if it ever returns one), but expect `nil` indefinitely. **Not** a
selection input. Lowest priority.

### 3.6 `ResearchFeedService` ✅ — research feed / Snips index (DISCOVERED 2026-06-13, NOT yet built)
**Source:** `~/Downloads/stockbit.com.har`. This is the **real backing for the app's "Research" tab**
— a keyword-searchable feed of Snips articles (NOT the empty per-symbol §3.5 note). Two endpoints,
both on `exodus` (authed), both verified-populated:

- **`GET research?keyword={kw}`** → `StockbitEnvelope<[ResearchArticle]>`; captured 25 articles, all
  `category_label:"Snips"`. Element = `{ id:Int, title:String, category_label:String, url:String
  (→ snips.stockbit.com/snips-terbaru/…?source=research, the HTML article), icon_url, image_url,
  compressed_image_url:String, description:String (display date "12 June 2026"), created:String
  (ISO8601) }`. *(The HAR stored the body base64 via `content.encoding:"base64"` — HAR storage only;
  the live API returns plain JSON.)*
- **`GET research/indicator/new`** → `{ message, data:{ has_new:Bool, count:Int } }` — the "new
  research" badge counter.

**Status / scope:** editorial / news, keyword-searchable, **NOT symbol-keyed, NOT a selection input**
(same scope conclusion as §3.5 — but now cleanly modelable). Proposed as a **standalone display
service** `ResearchFeedService` — `feed(keyword:) -> [ResearchArticle]` + `indicatorNew() ->
ResearchIndicator` (DTOs + tests, same `APIClient`/`StockbitEnvelope`/error-map conventions). No
scoring / `SecurityData` / golden-master impact. Backs a future "Research / Snips news" feed UI.
**Awaiting go/no-go before building.**

---

## 4. `DataProvider` seam changes — ✅ SHIPPED (Slice 4, 2026-06-12)

`SecurityData` (per-ticker) and `MarketContext` (market-wide) in `StockSelectionEngine.swift`
gained **optional** fields; `StockbitDataProvider` fetches them **best-effort** (`try? await
paced { … }`) so a failed/absent leg degrades instead of failing the whole pick — exactly the
existing pattern for the balance-sheet / governance legs.

**Shipped as additive `var … = nil`** (the source-compatible memberwise-init pattern from
`TTMFinancials.payoutRatio`, so the golden master is byte-for-byte unchanged): `peerComparison` /
`seasonality` / `brokerDistribution` on `SecurityData`, `flowLeaders` on `MarketContext`.
`analystCoverage` is **deferred to Slice 5** (data-blocked). The provider gained 3 injected services
(`comparisonService` / `seasonalityService` / `orderFlowService`); the per-ticker legs are paced,
the market `top-stock` leg joins the unthrottled regime fan-out; all wired into `AppDependencies`
(+ `Stub{ComparisonRatios,Seasonality,OrderTradeFlow}Service` fixtures) and `SelectionRunner`.
`StockbitDataProviderTests` extended (overlays populate / degrade-to-nil / leaderboard carried).
**Scoring still untouched** — these are carried context only; feeding them into scorers is Slice 6.

```swift
// SecurityData — additive, all optional (existing fields unchanged)
let peerComparison: PeerComparison?         // 3.1
let seasonality: Seasonality?               // 3.2
let brokerDistribution: BrokerDistribution? // 3.3 Tier 1
let analystCoverage: AnalystCoverage?       // 3.4 (nil until data unblocked)

// MarketContext — additive
let flowLeaders: FlowLeaderboard?           // 3.3 top-stock
```

```swift
// StockbitDataProvider.fetchSecurity(_:) — append best-effort legs
let peers = try? await paced { try await self.comparison.ratios(symbol: t) }
let seas  = try? await paced { try await self.seasonality.load(symbol: t, year: currentYear) }
let dist  = try? await paced { try await self.brokerFlow.distribution(symbol: t) }
// inject into SecurityData(...) initializer
```

Scoring stays untouched until a calibration pass decides weights — keep these as carried
context first, then add scorers in a separate, tested change.

---

## 5. Test plan (TDD, Swift Testing + `StubSession`)

One `…ServiceTests.swift` per service in `AutoscreenerTests/`, fixtures as inline
`Data(#"""…"""#.utf8)` **trimmed from the real captured bodies** (arrays cut to 2–3 elements,
values verbatim). Per service:

1. **Happy path** — decode real captured body, assert key fields (`symbols.count == 3`;
   `PeerMetric.numeric["TPIA"]` for "Market Cap" ≈ 154_423e9; a known month's `probabilityUpPct`).
2. **Envelope edges** — `data:null` (analyst) and `data:[]` (consensus) ⇒ `nil`/`[]`, no throw.
3. **`StockbitValue` tolerance** — dedicated test: `raw` as `Int`, as `Double`, as numeric
   `String`, and missing ⇒ correct `Double?`.
4. **Error mapping** — `401`→`.unauthorized`, `402`/`403`→`.paywall` (mirror
   `KeystatsRatioServiceTests`).
5. **`UITestSupport`** — add a `Stub<Name>Service` per new protocol returning canned data, wired
   under `-UITestFixtures`.

`StockbitValue` + `DisplayNumber` interplay (`"154,423 B"` → `154_423e9`) gets a unit test even
though `DisplayNumber` is already covered — the new call sites are what's under test.

---

## 6. Unblocking the ⛔/⚠️ endpoints — ✅ DONE (analyst); research still empty

Re-ran the capture against **BBCA** (`proxseer_collection (2).json`, 2026-06-12):
- **`analyst-ratings/{SYM}` + `…/consensus` → populated.** §3.4 DTOs **finalized** against the real
  BBCA payload (coverage block + forward-estimate series). The skeleton's guessed fields were both
  wrong; the verified shapes are now modelled and tested. ✅
- **`research/company/BBCA` → still `content:""`.** Empty for every symbol captured, so there is no
  populated per-symbol research payload to model — `ResearchService` stays correct-but-empty. The
  in-app "Research" detail is **Stockbit Snips** (`snips.stockbit.com`, HTML/Squarespace), a separate
  content site, not this endpoint (§3.5). No further DTO work possible/needed here.

Remaining optional follow-on (NOT done — user scoped analyst to "DTOs + tests only"): plumb
`analystCoverage` into `SecurityData` + a best-effort provider leg, and decide whether
target-upside/recommendation feeds scoring as a capped modifier (Slice-6 style).

---

## 7. Recommended build order

(`✅ done` = built & green; `📦 captured` = wire shape verified, not yet built.)

1. ✅ **Shared primitives** — `StockbitEnvelope<T>` (Slice 1) + `StockbitValue` (Slice 2), with tests. Foundation for the rest.
2. ✅ **`ComparisonRatiosService`** (Slice 1) — highest selection value, fully captured.
3. ✅ **Order-trade Tier 1** (Slice 2) — `distribution` (per-ticker bandar) + `top-stock` (market flow) in `OrderTradeFlowService`; `marketMovers` deferred.
4. ✅ **`SeasonalityService`** (Slice 3) — monthly win-rate / avg-return overlay; fully captured.
5. ✅ **Plumb 2–4 into `SecurityData`/`MarketContext`** (Slice 4) — best-effort optional fields, no scoring change; golden master unchanged.
6. ✅ **Scorer calibration** (Slice 6) — feed the plumbed overlays into scoring as three capped, additive, inert-on-`nil` tilts (see §8). Golden master byte-for-byte unchanged. **← jumped ahead of skeletons (Slice 5) — it's the payoff and the data was already plumbed.**
7. ✅ **`AnalystRatingsService` / `ResearchService`** (Slice 5) — shipped as skeletons (envelope handling, null/empty ⇒ "no coverage"), then **analyst-ratings DTOs finalized** against the BBCA re-capture (§3.4/§6). Research stays verified-but-empty (§3.5). Not plumbed into scoring.
8. *(later — all optional, no selection impact)* `ResearchFeedService` for the real Research tab (`research?keyword=` + `indicator/new`, §3.6 — shape verified, awaiting go/no-go). Plumb `analystCoverage` into `SecurityData` + decide on a target-upside/recommendation scoring tilt (Slice-6 style). Order-trade Tier 2 UI feeds; per-preset tilt tuning + a live paper-trading sweep of the §8 caps.

---

## 8. Scorer calibration — ✅ SHIPPED (Slice 6, 2026-06-13)

The four plumbed overlays now feed scoring as **capped, additive modifiers** on the composite —
parallel to the existing `flow` / `timing` tilts, **not** new scorers. Rationale: a new `Scorer`
adds its weight to the composite's `num/den` denominator, diluting *every* name's score even at
value 0 → it would move the golden master for all names. A modifier adds 0 when its overlay is
absent and the engine appends **no audit line** for it, so any name without the data stays
**byte-for-byte unchanged** (same ethos as Slice 4). The strict golden-master audit snapshot test
passed **unmodified**; the calibration is proven by *new* tests that populate the overlays.

All knobs live in `SelectionConfig` (the single calibration surface), added to `.balanced` and
inherited by the derived presets:

| Modifier (`Modifiers.*`) | Overlay | Signal | Default cap |
|---|---|---|---|
| `relativeValue` | `peerComparison` | subject vs `INDUSTRY`+`SECTOR` on PE / PBV / EV-EBITDA (verified `fitem_name`s); cheaper-than-both votes +1, richer −1, mixed 0; mean × cap | ±0.03 |
| `seasonality` | `seasonality` | current month's `probabilityUpPct` (centred at 50) blended equally with `avgReturnPct`/`avgReturnSpanPct`; **soft, never a gate** | ±0.02 |
| `accumulation` | `brokerDistribution` + `MarketContext.flowLeaders` | per-ticker net buy/sell imbalance (buy-concentration surfaced in the audit) + leaderboard membership (top-buy +1 / top-sell −1), averaged | ±0.03 |

- **Determinism:** the seasonality "current month" is the **latest daily bar's month (UTC)** — no
  wall clock, so the read is testable and never flaky.
- **Threading:** `run()` fetches `marketContext` once and passes `context.flowLeaders` into
  `accumulation`; the per-ticker overlays ride on `SecurityData` (Slice 4).
- **Contract:** each modifier returns `(0, "")` exactly when its overlay is absent/unscoreable; a
  present overlay always yields a non-empty rationale (audited even at a net-zero tilt).
- **Config params:** `SelectionConfig.{relativeValue,seasonality,accumulation}` (new) — `cap`,
  `cheaperMetricNames`, `avgReturnSpanPct`, `topConcentrationN`. Caps are starting points to sweep
  against paper-trading, exactly like the `flow`/`timing`/bank betas.
- **Tests:** `AutoscreenerTests/SelectionEngineOverlayModifierTests.swift` (20) — per-modifier units
  (inert-on-`nil`, ±cap, clamp, missing-cell tolerance) + 2 engine-integration tests (favorable
  overlays raise the composite and add ordered audit lines; overlay-less name has no tilt lines).
  Full bundle green; golden master unchanged.
