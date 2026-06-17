import Foundation

// Integration glue between the app's networking domain and the vendored StockSelectionEngine.
// Lives in the Selection feature (not in the price-feed service) so the service stays free of any
// engine type dependency — the engine integration depends on the service's domain, never the reverse.
//
// Phase 0.2 (§8): HistoricalSummaryBar → engine OHLCV. The historical-summary feed returns bars
// newest-first; the engine expects ascending (oldest→newest), so the sequence adapters sort
// defensively. The same bar also yields the per-day foreign-flow series the engine consumes (§1.6).

extension HistoricalSummaryBar {
    /// This bar as the engine's input type. `value` carries the true traded rupiah (ADV input).
    /// `nonisolated`: a pure value transform with no actor state, so the (non-Main) engine
    /// `StockbitDataProvider` actor can call it (the module defaults declarations to `@MainActor`).
    nonisolated var ohlcv: OHLCV {
        OHLCV(date: date, open: open, high: high, low: low, close: close, volume: volume, value: value)
    }
}

extension Sequence where Element == HistoricalSummaryBar {
    /// Engine-ready OHLCV bars, ascending by date (oldest→newest).
    nonisolated var ohlcvSeries: [OHLCV] {
        sorted { $0.date < $1.date }.map(\.ohlcv)
    }
    /// Per-day net foreign flow, ascending by date — the engine's `foreignNetFlow` window input (§1.6).
    nonisolated var foreignNetFlowSeries: [Rupiah] {
        sorted { $0.date < $1.date }.map(\.netForeign)
    }
}

// MARK: - Fundamentals → engine TTMFinancials / AnnualFinancials (Phase 1.1 / 1.2, §8 / §11)
//
// Pure adapters from the keystats field map (KeystatsRatioService.fieldMap) and the fundachart
// series (FundachartService) onto the engine's input structs. Kept pure (no networking) so the
// field-id → typed-field mapping — the fiddly part — is unit-tested in isolation; StockbitDataProvider
// (Phase 1.8) does the fetching and hands the raw payloads here.

// MARK: - Skip reporting (resilience)
//
// A name the engine/reviewer could not value (missing required fundamentals or no price) is SKIPPED
// rather than aborting the whole run, so one bad ticker never empties the Recommendations screen.
// `reason` is the offending error's `localizedDescription`; the view aggregates these into a small
// non-blocking "N skipped" note. The outcome wrappers carry the survivors alongside the skips.

nonisolated struct SkippedName: Equatable, Sendable {
    let ticker: Ticker
    let reason: String
}

/// Thread-safe sink for the engine/reviewer's `onSkip` callback. The buy engine and Gate-5 reviewer
/// are non-isolated `async` types, so `onSkip` may fire off the calling actor — a locked reference
/// box lets the orchestration collect skips synchronously without a data-race warning.
nonisolated final class SkipCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SkippedName] = []
    func add(_ skipped: SkippedName) { lock.lock(); items.append(skipped); lock.unlock() }
    var all: [SkippedName] { lock.lock(); defer { lock.unlock() }; return items }
}

/// Buy-side run result: the ranked recommendations plus the names skipped while assembling them.
/// `awaitingData` is set when the sweep-filled cache is still cold (no regime context / no fresh
/// entries), so the screen shows a "waiting for the sweep" state instead of a misleading "no picks".
/// `asOf` is non-nil only while the market is CLOSED — it's the cache's last-warmed time, so the screen
/// can rank the last-known close and label it "as of <date> · market closed" rather than waiting on a
/// sweep that won't run until the next session. nil while open (figures are live).
nonisolated struct SelectionOutcome: Sendable {
    let recommendations: [Recommendation]
    let skipped: [SkippedName]
    var awaitingData: Bool = false
    var asOf: Date? = nil
}

/// Sell-side review result: the hold/trim/exit verdicts plus the held names skipped while re-valuing.
/// `awaitingData` / `asOf` mirror `SelectionOutcome` — a cold cache means "wait", and a closed market
/// ranks the last-warmed close labelled "as of <date>".
nonisolated struct ReviewOutcome: Sendable {
    let decisions: [ExitDecision]
    let skipped: [SkippedName]
    var awaitingData: Bool = false
    var asOf: Date? = nil
}

enum SelectionFundamentals {

    enum AdapterError: Error, Equatable, LocalizedError {
        /// A keystats field the industrial scoring path requires was absent ("-"): the name
        /// can't be gated/scored as an industrial. Phase 2's archetype seam routes banks
        /// (which legitimately return "-" for current ratio / D/E) to a financial profile instead.
        case missingField(id: String, name: String)

        /// `LocalizedError` so the Recommendations screen (and the skip note) names the offending
        /// field instead of Swift's default "…AdapterError error 0" enum-index formatting.
        var errorDescription: String? {
            switch self {
            case let .missingField(id, name):
                return "\(name) unavailable (field \(id)) — can't value this name."
            }
        }
    }

    /// Stable keystats `fitem.id`s for the TTM block the engine consumes (verified on WIFI, §11).
    /// Most are read elsewhere too (see `KeystatsRatioService.Field`); duplicated here so the
    /// engine's field contract is explicit and self-documenting at its own boundary.
    private enum Field {
        static let eps = "13200"               // Current EPS (TTM), per-share rupiah
        static let bookValuePerShare = "15718" // Current Book Value Per Share
        static let currentRatio = "1498"       // Current Ratio (Quarter)
        static let debtToEquity = "1508"        // Debt to Equity Ratio (Quarter)
        static let returnOnEquity = "1461"      // Return on Equity (TTM), a PERCENT → ÷100 ratio
        static let epsGrowthAnnual = "1471"     // EPS (Annual YoY Growth), a percent-NUMBER (keep as-is)
        static let netIncome = "1555"           // Net Income (TTM), scaled ("490 B")
        static let operatingCashFlow = "2545"   // Cash From Operations (TTM), scaled ("(1,899 B)")
        static let totalAssets = "1559"         // Total Assets (Quarter), scaled ("16,196 B")
        static let commonEquity = "15883"       // Common Equity, scaled ("7,464 B") — shares fallback
        static let payoutRatio = "2916"         // Payout Ratio, a PERCENT → ratio (financial profile)
        static let returnOnAssets = "1460"      // Return on Assets (TTM), a PERCENT → ratio (bank quality)

        static let names: [String: String] = [
            eps: "EPS (TTM)", bookValuePerShare: "Book Value Per Share",
            currentRatio: "Current Ratio", debtToEquity: "Debt/Equity",
            returnOnEquity: "ROE (TTM)", epsGrowthAnnual: "EPS Annual YoY Growth",
        ]
    }

    /// Builds the engine's `TTMFinancials` from a keystats field map.
    ///
    /// Unit handling is field-specific and easy to get wrong, so it's pinned by tests:
    /// - `returnOnEquity` is stored as a **ratio** (engine `roeFloor` is 0.10), so "6.57%" → 0.0657.
    /// - `epsGrowthPct` is a **percent-number** (engine PEG does `pe / g` with g≈15), so "-11.46%" → −11.46.
    /// - Net Income / CFO / Total Assets are absolute rupiah with `B`/`T` suffixes → `parseScaledDecimal`.
    ///
    /// The required set is **archetype-dependent** (§14 / Phase 3.6). `eps`, `bvps` and
    /// `returnOnEquity` are required on **every** path — both the industrial Graham valuator and the
    /// bank P/B-vs-ROE valuator/scorers read them, and absent ("-") ⇒ `missingField`, never coerced to
    /// 0 (§13-A3). `currentRatio` / `debtToEquity` / `epsGrowthPct` are required for `.industrial`
    /// (`SolvencyGate` + Lynch PEG read them) but **degrade to 0 for `.financial`**: banks report "-"
    /// for current ratio / D-E (their `SolvencyGate` is replaced by `CapitalStrengthGate`, and Lynch
    /// growth is reused but guards `g`), so coercing those three to 0 lets a bank build instead of
    /// throwing upstream before it can be classified. The three absolute fields are unread by today's
    /// gates/scorers and only feed `sharesOutstanding` derivation (§1.4), so a missing one degrades to 0.
    static func ttm(fromKeystats fields: [String: String],
                    archetype: CompanyArchetype = .industrial) throws -> TTMFinancials {
        func plain(_ id: String) -> Double? { fields[id].flatMap(DisplayNumber.parseDecimal) }
        func scaled(_ id: String) -> Double? { fields[id].flatMap(DisplayNumber.parseScaledDecimal) }
        func require(_ id: String) throws -> Double {
            guard let v = plain(id) else { throw AdapterError.missingField(id: id, name: Field.names[id] ?? id) }
            return v
        }

        let eps = try require(Field.eps)
        let bvps = try require(Field.bookValuePerShare)
        let roe = try require(Field.returnOnEquity) / 100.0      // percent → ratio

        // Solvency / growth: required for industrials, degraded to 0 for banks (see doc comment).
        let currentRatio: Double, debtToEquity: Double, epsGrowthPct: Double
        switch archetype {
        case .industrial:
            currentRatio = try require(Field.currentRatio)
            debtToEquity = try require(Field.debtToEquity)
            epsGrowthPct = try require(Field.epsGrowthAnnual)    // percent-number, kept verbatim
        case .financial:
            currentRatio = plain(Field.currentRatio) ?? 0
            debtToEquity = plain(Field.debtToEquity) ?? 0
            epsGrowthPct = plain(Field.epsGrowthAnnual) ?? 0     // percent-number, kept verbatim
        }

        // Payout / ROA are universal but NOT required — a non-dividend payer reports payout "-", so
        // an absent value degrades to 0 (a ratio, like ROE). Read only by the financial profile.
        let payoutRatio = (plain(Field.payoutRatio) ?? 0) / 100.0
        let returnOnAssets = (plain(Field.returnOnAssets) ?? 0) / 100.0

        return TTMFinancials(
            eps: Decimal(eps),
            bookValuePerShare: Decimal(bvps),
            netIncome: Decimal(scaled(Field.netIncome) ?? 0),
            operatingCashFlow: Decimal(scaled(Field.operatingCashFlow) ?? 0),
            totalAssets: Decimal(scaled(Field.totalAssets) ?? 0),
            epsGrowthPct: epsGrowthPct,
            currentRatio: currentRatio,
            debtToEquity: debtToEquity,
            returnOnEquity: roe,
            payoutRatio: payoutRatio,
            returnOnAssets: returnOnAssets)
    }

    /// Legends within the annual fundachart datasets the engine consumes (verified on WIFI, §11).
    private enum Legend {
        static let revenue = "Revenue"                  // data_type 1
        static let netIncome = "Net Income"             // data_type 1
        static let totalAssets = "Total Assets"          // data_type 2
        static let totalLiabilities = "Total Liabilities" // data_type 2
        static let operatingCashFlow = "Operating"        // data_type 3
    }

    /// Joins the three annual fundachart datasets into the engine's `[AnnualFinancials]`, ascending
    /// (oldest→newest) as the engine's `.suffix()` / `.last` consumers expect — fundachart returns
    /// fiscal years newest-first, so the result is re-sorted.
    ///
    /// Covers the §1.2 numeric core only: `revenue` / `netIncome` (income), `totalAssets` /
    /// `totalLiabilities` (balance), `operatingCashFlow` (cash flow), and the identity
    /// `shareholderEquity = assets − liabilities`. `currentAssets` / `currentLiabilities` /
    /// `receivables` (the §1.3 display-tree balance-sheet items) and per-year `sharesOutstanding`
    /// (§1.4) are not charted, so they're left 0 — safe, because every engine consumer guards them
    /// (`ForensicGate` skips when `receivables == 0`; `Valuator` NCAV skips when `sharesOutstanding == 0`).
    /// A period missing any of the five core figures, or one that isn't a plain fiscal year (e.g. a
    /// quarterly "Q1 2026"), is skipped rather than emitted partial.
    static func annualFinancials(income: FundachartFinancials,
                                 balance: FundachartFinancials,
                                 cashFlow: FundachartFinancials) -> [AnnualFinancials] {
        var out: [AnnualFinancials] = []
        for period in income.periods {
            guard let year = Int(period),
                  let revenue = income.value(legend: Legend.revenue, period: period),
                  let netIncome = income.value(legend: Legend.netIncome, period: period),
                  let totalAssets = balance.value(legend: Legend.totalAssets, period: period),
                  let totalLiabilities = balance.value(legend: Legend.totalLiabilities, period: period),
                  let operatingCashFlow = cashFlow.value(legend: Legend.operatingCashFlow, period: period)
            else { continue }
            out.append(AnnualFinancials(
                year: year,
                revenue: revenue,
                netIncome: netIncome,
                operatingCashFlow: operatingCashFlow,
                totalAssets: totalAssets,
                totalLiabilities: totalLiabilities,
                currentAssets: 0,
                currentLiabilities: 0,
                shareholderEquity: totalAssets - totalLiabilities,
                receivables: 0,
                sharesOutstanding: 0))
        }
        return out.sorted { $0.year < $1.year }
    }

    // MARK: - Industrial balance-sheet extractor (Phase 1.3, §5/§11)
    //
    // The three per-year balance-sheet figures the engine consumes that neither keystats
    // (snapshot-only) nor fundachart (not charted) expose. They live only in the display-string
    // tree (`findata-view/v2/financials`, report_type=2 balance sheet, statement_type=2 annual),
    // where each appears as a bold *subtotal* leaf (with figures) nested under an empty bold section
    // *header* of the same name. The extractor reads the valued node, parses "8,688 B" with
    // `parseScaledDecimal`, and keys by the fiscal year in the "12M 2025" period label.

    /// The three §1.3 balance-sheet line items, per fiscal year. Absent items are 0 (not failure):
    /// every engine consumer (`ForensicGate` receivables rule, `Valuator` NCAV) guards on `> 0`,
    /// so 0 means "skip this check" — the correct behaviour for banks, which lack these subtotals.
    struct BalanceSheetItems: Equatable, Sendable {
        var currentAssets: Rupiah = 0
        var currentLiabilities: Rupiah = 0
        var receivables: Rupiah = 0
    }

    /// Exact (case-insensitive) Indonesian names of the bold subtotals to pull. Matched against the
    /// *valued* node so the same-named empty section header that wraps each one is skipped.
    private enum BalanceSheetAccount {
        static let currentAssets = "Aset Lancar"
        static let currentLiabilities = "Liabilitas Jangka Pendek"
        static let receivables = "Piutang Usaha"
    }

    /// Walks the annual balance-sheet tree and pulls the three §1.3 subtotals per fiscal year.
    /// The period labels are annual ("12M 2025" → 2025); a label with no trailing year token is
    /// skipped. A subtotal absent for the company (e.g. a bank) leaves its field 0.
    static func balanceSheetItems(from statement: FinancialStatement) -> [Int: BalanceSheetItems] {
        let currentAssets = valuedCells(named: BalanceSheetAccount.currentAssets, in: statement.accounts)
        let currentLiabilities = valuedCells(named: BalanceSheetAccount.currentLiabilities, in: statement.accounts)
        let receivables = valuedCells(named: BalanceSheetAccount.receivables, in: statement.accounts)

        var out: [Int: BalanceSheetItems] = [:]
        for (column, period) in statement.periods.enumerated() {
            guard let year = fiscalYear(period) else { continue }
            out[year] = BalanceSheetItems(
                currentAssets: cell(currentAssets, column),
                currentLiabilities: cell(currentLiabilities, column),
                receivables: cell(receivables, column))
        }
        return out
    }

    /// Overlays the three extracted balance-sheet items onto the fundachart-derived annuals, matched
    /// by year. Years with no balance-sheet column keep their existing (0) tree fields; every other
    /// field (revenue, equity, …) and the input ordering are preserved. Pure: `StockbitDataProvider`
    /// (1.8) calls this only when the balance-sheet fetch succeeds, so a paywall/absent statement
    /// simply leaves the §1.2 annuals as-is.
    static func merging(_ annuals: [AnnualFinancials], balanceSheet: FinancialStatement) -> [AnnualFinancials] {
        let items = balanceSheetItems(from: balanceSheet)
        return annuals.map { a in
            guard let bs = items[a.year] else { return a }
            return AnnualFinancials(
                year: a.year,
                revenue: a.revenue,
                netIncome: a.netIncome,
                operatingCashFlow: a.operatingCashFlow,
                totalAssets: a.totalAssets,
                totalLiabilities: a.totalLiabilities,
                currentAssets: bs.currentAssets,
                currentLiabilities: bs.currentLiabilities,
                shareholderEquity: a.shareholderEquity,
                receivables: bs.receivables,
                sharesOutstanding: a.sharesOutstanding)
        }
    }

    /// Depth-first search for the first node whose stripped name equals `name` (case-insensitive)
    /// and that carries at least one parseable figure — i.e. the bold subtotal, not the empty header.
    /// Returns its `values`, parallel to `statement.periods`.
    private static func valuedCells(named name: String, in accounts: [FinancialAccount]) -> [String]? {
        for account in accounts {
            if account.name.caseInsensitiveCompare(name) == .orderedSame,
               account.values.contains(where: { DisplayNumber.parseScaledDecimal($0) != nil }) {
                return account.values
            }
            if let nested = valuedCells(named: name, in: account.children) { return nested }
        }
        return nil
    }

    /// The parsed figure in `values` at `column`, or 0 when the cell is absent / "-" / unparseable.
    private static func cell(_ values: [String]?, _ column: Int) -> Rupiah {
        guard let values, column < values.count,
              let parsed = DisplayNumber.parseScaledDecimal(values[column]) else { return 0 }
        return Decimal(parsed)
    }

    /// Fiscal year from an annual period label: "12M 2025" → 2025, "2025" → 2025; nil when the
    /// trailing space-separated token isn't an integer.
    private static func fiscalYear(_ period: String) -> Int? {
        period.split(separator: " ").last.flatMap { Int($0) }
    }

    // MARK: - Company fields (Phase 1.4, §11)
    //
    // The engine's company-level inputs that aren't in keystats/fundachart: `freeFloatPct` from the
    // profile, and `sharesOutstanding`, which has no direct field and is derived from keystats.

    /// Free float as a ratio from the profile's "40.00%" display → 0.40. nil when absent/unparseable,
    /// letting `StockbitDataProvider` (1.8) choose the gate behaviour rather than defaulting here.
    static func freeFloat(fromProfile profile: EmittenProfile) -> Ratio? {
        profile.freeFloatDisplay.flatMap(DisplayNumber.parseDecimal).map { $0 / 100.0 }
    }

    /// Derived shares outstanding — Stockbit exposes no direct count (the profile's snapshot lags
    /// corporate actions). Primary: Net Income (TTM, `1555`) ÷ EPS (TTM, `13200`) when EPS > 0.
    /// Loss-maker fallback (EPS ≤ 0, where the quotient is meaningless): Common Equity (`15883`) ÷
    /// Book Value Per Share (`15718`) when BVPS > 0 (§13-A3). nil when neither basis is available.
    static func sharesOutstanding(fromKeystats fields: [String: String]) -> Decimal? {
        func plain(_ id: String) -> Double? { fields[id].flatMap(DisplayNumber.parseDecimal) }
        func scaled(_ id: String) -> Double? { fields[id].flatMap(DisplayNumber.parseScaledDecimal) }

        if let netIncome = scaled(Field.netIncome), let eps = plain(Field.eps), eps > 0 {
            return Decimal(netIncome / eps)
        }
        if let equity = scaled(Field.commonEquity), let bvps = plain(Field.bookValuePerShare), bvps > 0 {
            return Decimal(equity / bvps)
        }
        return nil
    }

    /// Stamps the derived share count onto the most-recent annual only — `Valuator` NCAV reads
    /// `financials.last`, and the current count is valid for that latest period, not for prior years
    /// (which may pre-date rights issues). Older years keep 0, so NCAV simply doesn't fire on them.
    static func assigning(sharesOutstanding shares: Decimal,
                          toLatestOf annuals: [AnnualFinancials]) -> [AnnualFinancials] {
        guard let lastIndex = annuals.indices.last else { return annuals }
        var out = annuals
        let a = out[lastIndex]
        out[lastIndex] = AnnualFinancials(
            year: a.year,
            revenue: a.revenue,
            netIncome: a.netIncome,
            operatingCashFlow: a.operatingCashFlow,
            totalAssets: a.totalAssets,
            totalLiabilities: a.totalLiabilities,
            currentAssets: a.currentAssets,
            currentLiabilities: a.currentLiabilities,
            shareholderEquity: a.shareholderEquity,
            receivables: a.receivables,
            sharesOutstanding: shares)
        return out
    }

    // MARK: - Sector → IDX sector-index symbol (Phase 1.5, §11 / §13-B4)
    //
    // The engine's `sectorIndexBars` (the `Modifiers.timing` sector leg) needs the company's IDX
    // sector index. IDX-IC classifies every listed company into exactly one of 11 sectors, each with a
    // tradable index whose daily bars come from the SAME historical-summary feed (Phase 0.2) as the
    // stock's own bars — so 1.8 fetches `dailyBars(symbol: <sectorIndex>, …).ohlcvSeries`. The map keys
    // are the Indonesian sector display names from `EmittenInfo.sector`: "Teknologi"→IDXTECHNO and
    // "Keuangan"→IDXFINANCE are capture-verified (WIFI, BBCA); the other nine are the standard IDX-IC
    // names and the 11 index symbols are all confirmed present in the captures. Because the name match
    // is the only fragile part, `sectorIndexSymbol(for:)` falls back to the sector index inside
    // `EmittenInfo.indexes`, which always lists the company's one sector index (verified on both names).

    /// IDX-IC sector display name (normalized: lowercased + trimmed) → IDX sector-index symbol.
    static let sectorIndexBySector: [String: String] = [
        "energi": "IDXENERGY",
        "barang baku": "IDXBASIC",
        "perindustrian": "IDXINDUST",
        "barang konsumen primer": "IDXNONCYC",       // Consumer Non-Cyclicals
        "barang konsumen non-primer": "IDXCYCLIC",   // Consumer Cyclicals
        "kesehatan": "IDXHEALTH",
        "keuangan": "IDXFINANCE",                    // verified (BBCA)
        "properti & real estat": "IDXPROPERT",
        "teknologi": "IDXTECHNO",                    // verified (WIFI)
        "infrastruktur": "IDXINFRA",
        "transportasi & logistik": "IDXTRANS",
    ]

    /// The 11 IDX-IC sector-index symbols — used to recognise the sector index inside `info.indexes`.
    static let sectorIndexSymbols: Set<String> = Set(sectorIndexBySector.values)

    /// The IDX sector-index symbol for a company. Primary: the sector-name map. Fallback (when the
    /// name isn't mapped — e.g. a spelling drift): the one sector index present in `info.indexes`.
    /// nil when neither resolves; 1.8 then leaves `sectorIndexBars` empty and the engine's timing
    /// modifier omits the sector leg (it already guards on `sectorIndexBars.count`).
    static func sectorIndexSymbol(for info: EmittenInfo) -> String? {
        if let mapped = sectorIndexSymbol(forSector: info.sector) { return mapped }
        return info.indexes.first(where: sectorIndexSymbols.contains)
    }

    /// Name-only lookup: the IDX sector-index symbol for an `EmittenInfo.sector` display name
    /// (case-/whitespace-insensitive), or nil if the name isn't one of the 11 IDX-IC sectors.
    static func sectorIndexSymbol(forSector sector: String) -> String? {
        sectorIndexBySector[sector.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    // MARK: - Broker accumulation signal (Phase 1.6, §6 / §11)
    //
    // The engine's `brokerAccumulationSignal` is a single [-1,1] scalar (the flow modifier averages it
    // with the foreign-flow sign). We compute it from the daily broker-activity series (BrokerActivity-
    // Service) as a VALUE-WEIGHTED net-accumulation ratio over a recent window:
    //
    //     signal = Σ netValue / Σ (buyValue + sellValue)        (clamped to [-1,1])
    //
    // |net| = |buy − sell| ≤ buy + sell, so the ratio is already in [-1,1]; the clamp is defensive.
    // Value-weighting lets high-activity days dominate and stops a thin day swinging the signal.
    // Records arrive newest-first, so the window is simply the first `window` records.
    //
    // The per-day foreign-flow series the flow modifier also consumes is already free from Phase 0.2
    // (`Sequence<HistoricalSummaryBar>.foreignNetFlowSeries`), so 1.6 only needs this broker scalar.

    /// Value-weighted net-accumulation signal in [-1,1] over the most recent `window` daily records.
    /// 0 when there are no records or no traded value in the window (no information → no tilt). 1.8 may
    /// pass `config.flow.foreignWindow` for symmetry with the foreign leg; the default is a trading month.
    static func brokerAccumulationSignal(from records: [BrokerActivityRecord], window: Int = 20) -> Double {
        let recent = records.prefix(window)
        var net = Decimal(0), gross = Decimal(0)
        for r in recent {
            net += r.netValue
            gross += r.buyValue + r.sellValue
        }
        guard gross > 0 else { return 0 }
        let signal = (net as NSDecimalNumber).doubleValue / (gross as NSDecimalNumber).doubleValue
        return max(-1, min(1, signal))
    }

    // MARK: - Market regime → engine MarketContext (Phase 1.7, §3)
    //
    // `MarketContext` is the engine's market-wide regime input (consumed by `RegimeAssessor.assess`,
    // which accumulates a risk score from these seven facts). The app ALREADY gathers every one of
    // them for the Market Regime screen, so `RegimeFactorBuilder.factors(…)` and this adapter are two
    // consumers of the IDENTICAL raw inputs (server snapshot + aggregate foreign flow + IHSG 200-day
    // distance + USD/IDR move + LQ45 breadth, + the relevant commodity move). Phase 1.8 therefore
    // reuses `RegimeViewModel`'s proven fan-out wiring verbatim and hands the results here. Kept pure
    // (no networking) so the field mapping + degradation policy are unit-tested in isolation, exactly
    // like the fundamentals adapters above.
    //
    // Degradation policy — an input is absent when its feed failed or the snapshot isn't published yet.
    // `RegimeFactorBuilder` simply DROPS an absent factor, but `MarketContext` has no optionals, so this
    // adapter must default each field. It defaults to the **neutral / no-evidence** value, never
    // fabricating a confident read:
    //   • valuation / breadth → 0.5 (mid-cycle). Defaulting the dominant valuation driver to 0 ("cheapest")
    //     on a missing snapshot would manufacture a false risk-on — the exact bias to avoid.
    //   • idrWeakening / biRateRising → false (no evidence of FX or rate stress; don't claim a hike with no snapshot).
    //   • indexAbove200dma / commodityTailwind → false (an unconfirmed uptrend / unseen tailwind is not
    //     scored as one — conservatively each then ADDS, not removes, regime risk in `assess`).
    //   • marketForeignFlowNet → 0 (`assess` only penalises a NEGATIVE net, so 0 = no flow signal).
    // When LITERALLY every input is absent the engine would still score a phantom (neutral-to-risk-off)
    // regime, so 1.8 should `throw` rather than call this with an all-nil set — mirroring `RegimeViewModel`,
    // which surfaces an error rather than reading an empty factor list.

    /// Builds the engine's `MarketContext` from the same raw regime inputs `RegimeFactorBuilder`
    /// consumes. `marketForeignFlowNet` is `AggregateForeignFlow.netForeign.raw`; `ihsgDistanceFrom200dma`
    /// is `MovingAverage.distanceFromSMA(ihsg, period: 200)` (≥ 0 ⇒ above trend); `usdIdrChangePercent`
    /// is the USD/IDR daily move (> 0 ⇒ rupiah weakening); `commodityChangePercent` is the relevant
    /// market commodity's move (> 0 ⇒ tailwind). Absent inputs follow the neutral degradation policy above.
    static func marketContext(
        snapshot: RegimeSnapshot?,
        marketForeignFlowNet: Double?,
        ihsgDistanceFrom200dma: Double?,
        usdIdrChangePercent: Double?,
        breadth: BreadthReading?,
        commodityChangePercent: Double?
    ) -> MarketContext {
        MarketContext(
            indexValuationPercentile: snapshot?.composite?.valuationPercentile ?? 0.5,
            breadthAbove200dma: breadth?.fraction ?? 0.5,
            indexAbove200dma: ihsgDistanceFrom200dma.map { $0 >= 0 } ?? false,
            idrWeakeningTrend: usdIdrChangePercent.map { $0 > 0 } ?? false,
            biRateRising: snapshot?.biRate?.direction == .hike,
            marketForeignFlowNet: Decimal(marketForeignFlowNet ?? 0),
            commodityTailwind: commodityChangePercent.map { $0 > 0 } ?? false)
    }
}
