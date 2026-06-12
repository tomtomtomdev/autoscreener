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
  `SecurityData`/`MarketContext` as optional best-effort fields**. It does **not** change
  scorer weights or gates — feeding the new factors into scoring is a follow-up
  calibration task (see `INTEGRATION.md` Phase 4 / `FactorRegression`).

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
| `GET /analyst-ratings/{SYM}` | `null` | ⛔ **Envelope only** — populated shape unknown |
| `GET /analyst-ratings/{SYM}/consensus` | `[]` | ⛔ **Envelope only** — element shape unknown |
| `GET /research/company/{SYM}` | `{id:0, symbol:"", content:"", masks:{}}` | ⚠️ **Shape known, payload empty** (no coverage / paywalled) |

**Implication:** ship the three ✅ families now. For the ⛔/⚠️ three, build the service
skeleton + envelope handling (so "no coverage" is a clean `nil`/`[]`, not a crash) and
**gate the DTO modeling on a fresh capture from a covered large-cap** (e.g. BBCA, BBRI,
TLKM, ASII — names that actually carry sell-side coverage and research notes). Modeling
their inner fields off naming guesses would be unverifiable.

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

### 2.2 `StockbitValue` — the `{raw, formatted}` pair
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
**File:** `Features/StockDetail/SeasonalityService.swift`
**Endpoint:** `GET seasonality/{SYM}?year={Y}&back_year=0`

Captured `data`: parallel "columns" arrays each keyed by month name (`x13` = 12 months +
aggregate): `up`, `down`, `total_months`, `avg` (avg % return), `prob` (P(up) %), plus
`price_change` (per-year rows) and `default_last_year`. Values are strings; `color` is hex
(UI-only, dropped).

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

**Tier 1 — selection-relevant (build first):**

| Method | Endpoint | Key query | Drives |
|---|---|---|---|
| `distribution(symbol:)` | `order-trade/broker/distribution` | `symbol, data_type=…_VALUE, period=TB_PERIOD_LAST_1_DAY, investor_type, market_board` | per-ticker bandar concentration |
| `topStocks(valueType:)` | `order-trade/top-stock` | `value_type=VALUE_TYPE_NET, market_type, investor_type, period, page` | market accumulation leaderboard |
| `marketMovers(type:)` | `order-trade/market-mover` | `mover_type, filter_stocks×N, limit` | gainers/losers + net foreign |

```swift
// distribution — "who is accumulating THIS stock today"
nonisolated struct BrokerDistribution: Sendable, Equatable {
    let symbol: String, date: String
    let topBuyers: [BrokerLeg]            // by value, descending
    let topSellers: [BrokerLeg]
    /// concentration signal: top-N net buyer value ÷ total — high ⇒ few brokers accumulating
}
nonisolated struct BrokerLeg: Sendable, Equatable { let code: String; let type: String; let amount: Double }
// DTO: data.by_value.top_broker_buy[].detail{code,type,amount:Int}; top_broker_sell mirror.

// top-stock — market-wide net buy/sell leaders
nonisolated struct FlowLeaderboard: Sendable, Equatable { let topBuy: [FlowRow]; let topSell: [FlowRow] }
nonisolated struct FlowRow: Sendable, Equatable {
    let rank: Int; let code: String
    let value, foreignValue, lot: StockbitValue
}
// DTO: data.top_buy[].{rank, code, value{raw:String,formatted}, foreign_value{…}, lot{…}}
```

**Tier 2 — UI / analysis (defer; spec'd, not in first cut):**
`running-trade` (live tick tape), `running-trade/chart/{SYM}` (intraday price + per-broker
cumulative, ~560 KB), `trade-book` + `trade-book/chart` (price-ladder / time buckets),
`broker/top` (broker league table), `broker/activity` (per-broker stock picks),
`broker/activity-chart` (~440 KB). These are large, display-oriented, and not selection
inputs — wire them when the StockDetail "Bandarmology" tab is built.

### 3.4 `AnalystRatingsService` ⛔ — skeleton only
**File:** `Features/StockDetail/AnalystRatingsService.swift`
**Endpoints:** `GET analyst-ratings/{SYM}` (`data:null`), `GET analyst-ratings/{SYM}/consensus`
(`data:[]`).

Build the service + protocol + envelope handling now; return `AnalystCoverage?` /
`[AnalystConsensusRow]` where `null`/`[]` ⇒ "no coverage" (nil/empty, **not** an error). The
inner field models (target high/low/mean, buy/hold/sell counts, # analysts, upside %) are
**hypotheses to confirm against a covered-large-cap capture** — do not finalize CodingKeys
until then. A test asserts the null/empty envelope degrades to "no coverage."

### 3.5 `ResearchService` ⚠️ — thin, display-only
**File:** `Features/StockDetail/ResearchService.swift`
**Endpoint:** `GET research/company/{SYM}` → `{ id, symbol, content, masks }`. Captured
`content:""` (no research / paywalled). Model directly; treat empty `content` as "no research."
`masks` is an empty object in the capture (purpose unknown — decode as opaque, ignore for now).
**Not** a selection input — qualitative text for the StockDetail UI. Lowest priority.

---

## 4. `DataProvider` seam changes

`SecurityData` (per-ticker) and `MarketContext` (market-wide) in `StockSelectionEngine.swift`
gain **optional** fields; `StockbitDataProvider` fetches them **best-effort** (`try? await
paced { … }`) so a failed/absent leg degrades instead of failing the whole pick — exactly the
existing pattern for the balance-sheet / governance legs.

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

## 6. Unblocking the ⛔/⚠️ endpoints

Re-run the proxy capture against a **covered large-cap** so `analyst-ratings` / `research`
return populated `data`, then finalize §3.4/§3.5 DTOs against the real payload. Good candidates:
**BBCA, BBRI, BMRI, TLKM, ASII**. Until then those services exist but yield "no coverage."

---

## 7. Recommended build order

1. **Shared primitives** — `StockbitEnvelope<T>`, `StockbitValue` (+ tests). Foundation for the rest.
2. **`ComparisonRatiosService`** ✅ — highest selection value, fully captured.
3. **Order-trade Tier 1** ✅ — `distribution` (per-ticker bandar) + `top-stock` (market flow).
4. **`SeasonalityService`** ✅ — overlay/UI.
5. **Plumb 2–4 into `SecurityData`/`MarketContext`** as best-effort optional fields (no scoring change).
6. **`AnalystRatingsService` / `ResearchService`** skeletons ⛔⚠️ — envelope handling only; finalize after a covered-large-cap re-capture.
7. *(later)* Order-trade Tier 2 UI feeds + scorer calibration for the new factors.
