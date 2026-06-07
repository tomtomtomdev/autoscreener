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
        static let commonEquity = "15883"       // Common Equity, scaled ("7,464 B") — shares fallback

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
}
