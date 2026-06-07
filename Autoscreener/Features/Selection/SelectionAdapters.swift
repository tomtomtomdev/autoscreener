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
    var ohlcv: OHLCV {
        OHLCV(date: date, open: open, high: high, low: low, close: close, volume: volume, value: value)
    }
}

extension Sequence where Element == HistoricalSummaryBar {
    /// Engine-ready OHLCV bars, ascending by date (oldest→newest).
    var ohlcvSeries: [OHLCV] {
        sorted { $0.date < $1.date }.map(\.ohlcv)
    }
    /// Per-day net foreign flow, ascending by date — the engine's `foreignNetFlow` window input (§1.6).
    var foreignNetFlowSeries: [Rupiah] {
        sorted { $0.date < $1.date }.map(\.netForeign)
    }
}

// MARK: - Fundamentals → engine TTMFinancials / AnnualFinancials (Phase 1.1 / 1.2, §8 / §11)
//
// Pure adapters from the keystats field map (KeystatsRatioService.fieldMap) and the fundachart
// series (FundachartService) onto the engine's input structs. Kept pure (no networking) so the
// field-id → typed-field mapping — the fiddly part — is unit-tested in isolation; StockbitDataProvider
// (Phase 1.8) does the fetching and hands the raw payloads here.

enum SelectionFundamentals {

    enum AdapterError: Error, Equatable {
        /// A keystats field the industrial scoring path requires was absent ("-"): the name
        /// can't be gated/scored as an industrial. Phase 2's archetype seam routes banks
        /// (which legitimately return "-" for current ratio / D/E) to a financial profile instead.
        case missingField(id: String, name: String)
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
    /// The six fields the industrial gates/scorers actually read (`eps`, `bvps`, `currentRatio`,
    /// `debtToEquity`, `returnOnEquity`, `epsGrowthPct`) are **required**: absent ("-") ⇒ `missingField`,
    /// never coerced to 0 (§13-A3). The three absolute fields are unread by today's gates/scorers and
    /// only feed `sharesOutstanding` derivation (§1.4), so a missing one degrades to 0.
    static func ttm(fromKeystats fields: [String: String]) throws -> TTMFinancials {
        func plain(_ id: String) -> Double? { fields[id].flatMap(DisplayNumber.parseDecimal) }
        func scaled(_ id: String) -> Double? { fields[id].flatMap(DisplayNumber.parseScaledDecimal) }
        func require(_ id: String) throws -> Double {
            guard let v = plain(id) else { throw AdapterError.missingField(id: id, name: Field.names[id] ?? id) }
            return v
        }

        let eps = try require(Field.eps)
        let bvps = try require(Field.bookValuePerShare)
        let currentRatio = try require(Field.currentRatio)
        let debtToEquity = try require(Field.debtToEquity)
        let roe = try require(Field.returnOnEquity) / 100.0      // percent → ratio
        let epsGrowthPct = try require(Field.epsGrowthAnnual)    // percent-number, kept verbatim

        return TTMFinancials(
            eps: Decimal(eps),
            bookValuePerShare: Decimal(bvps),
            netIncome: Decimal(scaled(Field.netIncome) ?? 0),
            operatingCashFlow: Decimal(scaled(Field.operatingCashFlow) ?? 0),
            totalAssets: Decimal(scaled(Field.totalAssets) ?? 0),
            epsGrowthPct: epsGrowthPct,
            currentRatio: currentRatio,
            debtToEquity: debtToEquity,
            returnOnEquity: roe)
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
}
