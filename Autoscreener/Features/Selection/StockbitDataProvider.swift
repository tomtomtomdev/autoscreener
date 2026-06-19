import Foundation

// Phase 1.8 (§8) — the live Tier-A `DataProvider`. Pure assembly: it fetches from the Stockbit
// services wired in 1.1–1.7 and hands their payloads to the pure `SelectionFundamentals` adapters,
// composing the engine's `SecurityData` and `MarketContext`. No new wire shapes, no parsing — every
// field-id → typed-field decision lives in the (unit-tested) adapters; this file only orchestrates.
//
// Orchestration concerns it owns (§7 / §13-B6):
//   • Anti-burst throttle. Stockbit penalises parallel bursts, so the per-ticker fan-out is
//     SERIALISED through one shared `RequestThrottle` (first call free, then a randomized gap) —
//     the same primitive `GovernanceService` uses. `marketContext()` reuses `RegimeViewModel`'s
//     proven CONCURRENT fan-out verbatim (a one-shot, five-call market read), so it is not throttled.
//   • Per-symbol result cache. `data(for:)` memoises its `SecurityData`, and the market/sector index
//     bars (shared across tickers) are cached by symbol, so a universe run fetches each index once.
//   • Archetype-first classification. `/emitten/info` (an ESSENTIAL leg) is read FIRST so the sector
//     classifies the company before the TTM is built: a bank's keystats omits current ratio / D-E
//     ("-"), so the adapter is told `archetype: .financial` and relaxes those required fields rather
//     than throwing `missingField` (§14 / Phase 3.6). Industrials keep the full required set.
//   • Graceful degradation. ESSENTIAL legs (the sector from `/emitten/info`, keystats→TTM, fundachart
//     annuals, the daily bars) propagate their errors — a name that can't be valued is surfaced, not
//     silently mis-scored. BEST-EFFORT legs (balance-sheet overlay, profile free-float, sector-index
//     bars, broker signal) degrade to their no-evidence value on paywall/failure rather than aborting
//     the whole run.
//
// Universe source (§10) is deliberately left to the caller: 1.8 takes an explicit candidate list,
// matching "run Tier-A v1 against a small candidate universe" — picking screener vs. watchlist vs.
// sector is an open decision that doesn't block assembly.

/// Errors `StockbitDataProvider` raises that aren't a service's own domain error.
nonisolated enum SelectionProviderError: Error, Equatable, LocalizedError {
    /// The daily-bar feed returned no bars, so there's no price to value the name on.
    case noPriceData(Ticker)
    /// Every market-wide regime input failed/was absent — refuse to score a phantom regime
    /// (mirrors `RegimeViewModel` surfacing an error rather than reading an empty factor list, §1.7).
    case noRegimeInputs
    /// The cache-backed provider (`CachedDataProvider`) has no fresh entry for this name yet — the
    /// sweep hasn't reached it. Surfaced as a SKIP (not a fetch): the cached read never falls back to
    /// the network, per the screen's "show what's cached" contract.
    case notCached(Ticker)

    /// `LocalizedError` so a propagated/skipped provider error reads as a sentence, not "error 0".
    var errorDescription: String? {
        switch self {
        case let .noPriceData(t):  return "\(t): no price data — can't value this name."
        case .noRegimeInputs:      return "No market regime inputs available."
        case let .notCached(t):    return "\(t): not yet swept — waiting for the data sweep."
        }
    }
}

/// The SLOW half of a `SecurityData` — fundamentals that change at most quarterly. Cached/persisted
/// across the trading day and refreshed once per close-capture sweep. `sectorIndexSymbol` is resolved
/// from `/emitten/info` here so the FAST leg can fetch sector bars without re-reading info on an
/// intraday-only pass.
struct FundamentalSlice: Sendable, Codable {
    let sector: String
    let sharesOutstanding: Decimal
    let freeFloatPct: Ratio
    let financials: [AnnualFinancials]
    let ttm: TTMFinancials
    let sectorIndexSymbol: String?
    let peerComparison: PeerComparison?
    let seasonality: Seasonality?
    let analystCoverage: AnalystCoverage?
    let governance: GovernanceAssessment?
}

/// The FAST half — price/flow signals that move intraday (re-fetched every sweep).
struct LiveSlice: Sendable {
    let price: Rupiah
    let dailyBars: [OHLCV]
    let foreignNetFlow: [Rupiah]
    let brokerAccumulationSignal: Double
    let sectorIndexBars: [OHLCV]
    let marketIndexBars: [OHLCV]
    let brokerDistribution: BrokerDistribution?
}

/// Narrow seam the cache warmer fetches through: the two cadence legs plus the regime context.
/// `StockbitDataProvider` is the only production conformer; the warmer holds this (not the full
/// `DataProvider`) so splitting the per-symbol fetch by cadence never touches the engine's read-side
/// conformers (`CachedDataProvider`, the test stubs).
protocol LegProvider: Sendable {
    func fundamentals(for t: Ticker) async throws -> FundamentalSlice
    func liveSignals(for t: Ticker, sectorIndexSymbol: String?) async throws -> LiveSlice
    func marketContext() async throws -> MarketContext
}

actor StockbitDataProvider: DataProvider, LegProvider {

    // Per-ticker fundamentals, price/flow and company metadata.
    private let keystats: any KeystatsRatioServicing
    private let fundachart: any FundachartServicing
    private let statements: any FinancialStatementServicing
    private let emitten: any EmittenServicing
    private let priceFeed: any CompanyPriceFeedServicing
    private let broker: any BrokerActivityServicing
    // Captured-endpoint best-effort overlays (Slice 4): peer ratios, monthly seasonality, and the
    // per-ticker broker distribution; `orderFlowService` also serves the market-wide leaderboard.
    private let comparisonService: any ComparisonRatiosServicing
    private let seasonalityService: any SeasonalityServicing
    private let orderFlowService: any OrderTradeFlowServicing
    // Gate-3 consensus (Slice — analyst coverage): best-effort, degrades to nil "no coverage".
    private let analyst: any AnalystRatingsServicing
    // Gate-2 governance veto (insider/dilution): best-effort; the Pro-paywalled insider feed degrades
    // to nil, so an un-entitled run simply never vetoes on governance.
    private let governance: any GovernanceServicing

    // Market-wide regime inputs — the identical set `RegimeFactorBuilder` consumes (§3).
    private let snapshotProvider: any RegimeSnapshotProviding
    private let flowService: any AggregateForeignFlowServicing
    private let chartService: any ChartServicing
    private let commodityService: any CommodityPriceServicing
    private let breadthService: any BreadthServicing
    private let breadthConstituents: [String]

    private let tickers: [Ticker]
    private let config: SelectionConfig
    private let history: TimeInterval
    private let now: @Sendable () -> Date
    private let throttle: RequestThrottle

    // Actor-isolated caches.
    private var securityCache: [Ticker: SecurityData] = [:]
    private var indexBarsCache: [String: [OHLCV]] = [:]
    private var contextCache: MarketContext?

    /// IDX Composite — the market index whose bars feed the engine's timing/beta leg.
    static let marketIndexSymbol = "IHSG"
    /// S&P 500 — the global risk-appetite leg of the regime read (Stockbit serves it on
    /// the same `charts/{symbol}/daily` path as IHSG).
    private static let globalEquitySymbol = "SP500"
    /// USD/IDR — the rupiah leg of the regime read (a currency, price-only).
    private static let rupiahSymbol = "USDIDR"
    /// One calendar year of daily bars (~244 IDX trading days) — comfortably clears
    /// `dataIntegrity.minTradingDays` (200) and over-covers the engine's longest lookback
    /// (`timing.betaLookback` = 252, which degrades gracefully below its ideal). Capped at one
    /// year because Stockbit's `company-price-feed/historical/summary` rejects a wider range with
    /// HTTP 400 `INVALID_PARAMETER` (the ELSA bug); this is the only live-verified span. Do not widen.
    static let defaultHistory: TimeInterval = 365 * 24 * 60 * 60

    init(
        universe: [Ticker],
        config: SelectionConfig = .balanced,
        keystats: any KeystatsRatioServicing,
        fundachart: any FundachartServicing,
        statements: any FinancialStatementServicing,
        emitten: any EmittenServicing,
        priceFeed: any CompanyPriceFeedServicing,
        broker: any BrokerActivityServicing,
        comparisonService: any ComparisonRatiosServicing,
        seasonalityService: any SeasonalityServicing,
        orderFlowService: any OrderTradeFlowServicing,
        analyst: any AnalystRatingsServicing,
        governance: any GovernanceServicing,
        snapshotProvider: any RegimeSnapshotProviding,
        flowService: any AggregateForeignFlowServicing,
        chartService: any ChartServicing,
        commodityService: any CommodityPriceServicing,
        breadthService: any BreadthServicing,
        breadthConstituents: [String] = LQ45Constituents.symbols,
        history: TimeInterval = StockbitDataProvider.defaultHistory,
        throttleRange: ClosedRange<UInt64> = RequestThrottle.defaultRange,
        sleeper: @escaping RequestThrottle.Sleeper = { try await Task.sleep(nanoseconds: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.tickers = universe
        self.config = config
        self.keystats = keystats
        self.fundachart = fundachart
        self.statements = statements
        self.emitten = emitten
        self.priceFeed = priceFeed
        self.broker = broker
        self.comparisonService = comparisonService
        self.seasonalityService = seasonalityService
        self.orderFlowService = orderFlowService
        self.analyst = analyst
        self.governance = governance
        self.snapshotProvider = snapshotProvider
        self.flowService = flowService
        self.chartService = chartService
        self.commodityService = commodityService
        self.breadthService = breadthService
        self.breadthConstituents = breadthConstituents
        self.history = history
        self.now = now
        self.throttle = RequestThrottle(range: throttleRange, sleeper: sleeper)
    }

    // MARK: - DataProvider

    func universe() async throws -> [Ticker] { tickers }

    func data(for t: Ticker) async throws -> SecurityData {
        if let cached = securityCache[t] { return cached }
        let security = try await fetchSecurity(t)
        securityCache[t] = security
        return security
    }

    func marketContext() async throws -> MarketContext {
        if let cached = contextCache { return cached }
        let context = try await fetchMarketContext()
        contextCache = context
        return context
    }

    // MARK: - Per-ticker assembly

    private func fetchSecurity(_ t: Ticker) async throws -> SecurityData {
        // Split by cadence: SLOW fundamentals (≈quarterly) then FAST live signals (intraday).
        // `data(for:)` still composes both, so the assembled `SecurityData` is byte-for-byte the same
        // as the old single fan-out (pinned by the compose-equivalence test). The split is what lets
        // an intraday sweep refresh only the fast leg against a cached/persisted slow leg.
        let fundamentals = try await self.fundamentals(for: t)
        let live = try await self.liveSignals(for: t, sectorIndexSymbol: fundamentals.sectorIndexSymbol)
        return Self.compose(t, fundamentals: fundamentals, live: live)
    }

    /// SLOW leg — fundamentals that change at most quarterly. Essential legs (sector from
    /// `/emitten/info`, keystats→TTM, fundachart annuals) propagate; best-effort overlays degrade to
    /// nil. Resolves `sectorIndexSymbol` from info so the fast leg can run alone on an intraday pass.
    func fundamentals(for t: Ticker) async throws -> FundamentalSlice {
        // Classify by sector FIRST. A bank's keystats omits current ratio / D-E ("-"), so the TTM
        // adapter must know the archetype to relax the right required fields (§14 / Phase 3.6):
        // otherwise it throws `missingField` and the name never reaches the engine to be routed to
        // the financial profile. `/emitten/info` is fetched essential.
        let info = try await paced { try await self.emitten.info(symbol: t) }
        let archetype = CompanyArchetype.classify(sector: info.sector)

        let fields = try await paced { try await self.keystats.fields(symbol: t) }
        let ttm = try SelectionFundamentals.ttm(fromKeystats: fields, archetype: archetype)

        let income = try await paced {
            try await self.fundachart.financials(symbol: t, dataset: .incomeStatement, report: .annual)
        }
        let balance = try await paced {
            try await self.fundachart.financials(symbol: t, dataset: .balanceSheet, report: .annual)
        }
        let cashFlow = try await paced {
            try await self.fundachart.financials(symbol: t, dataset: .cashFlow, report: .annual)
        }
        var annuals = SelectionFundamentals.annualFinancials(income: income, balance: balance, cashFlow: cashFlow)

        // Balance-sheet overlay (the 3 tree-only items). Absent ⇒ keep the fundachart annuals as-is.
        if let balanceSheet = try? await paced({
            try await self.statements.load(symbol: t, report: .balanceSheet, basis: .annual)
        }) {
            annuals = SelectionFundamentals.merging(annuals, balanceSheet: balanceSheet)
        }

        // Shares outstanding (derived from keystats) → stamp the latest annual only (NCAV reads `.last`).
        let shares = SelectionFundamentals.sharesOutstanding(fromKeystats: fields)
        if let shares {
            annuals = SelectionFundamentals.assigning(sharesOutstanding: shares, toLatestOf: annuals)
        }

        // Free float: an unverifiable float defaults to 0 so `LiquidityGate` conservatively screens
        // the name out (we don't recommend a position whose float we can't confirm).
        let profile = try? await paced { try await self.emitten.profile(symbol: t) }
        let freeFloat = profile.flatMap(SelectionFundamentals.freeFloat(fromProfile:)) ?? 0

        // Resolve the sector-index symbol here (it comes from `/emitten/info`) so the FAST leg can
        // fetch the sector bars without re-fetching info on an intraday-only pass.
        let sectorIndexSymbol = SelectionFundamentals.sectorIndexSymbol(for: info)

        // Captured-endpoint overlays (Slice 4) — carried context only, each best-effort: a paywall /
        // no-coverage / failure degrades the leg to nil rather than aborting the name's valuation.
        let peers = try? await paced { try await self.comparisonService.comparison(symbol: t) }
        // Phase 5: the seasonality tilt was dropped from the engine, so the slow leg no longer fetches
        // it (one fewer request per name); the slice's `seasonality` is left nil.
        // Gate-3 consensus: sell-side coverage. `coverage` already yields nil for an uncovered name,
        // so the double-optional from `try?` is flattened to a single "no coverage / no fetch" nil.
        let coverage: AnalystCoverage? = (try? await paced { try await self.analyst.coverage(symbol: t) }) ?? nil
        // Gate-2 governance: assemble the facts, then assess them with the pure rules (clock injected
        // here so the engine stays deterministic). A failed/paywalled fetch ⇒ nil ⇒ no veto.
        let govReport = try? await paced { try await self.governance.report(symbol: t, period: config.governance.period) }
        let governanceAssessment = govReport.map { GovernanceRules.assess($0, now: now()) }

        return FundamentalSlice(
            sector: info.sector,
            sharesOutstanding: shares ?? 0,
            freeFloatPct: freeFloat,
            financials: annuals,
            ttm: ttm,
            sectorIndexSymbol: sectorIndexSymbol,
            peerComparison: peers,
            seasonality: nil,
            analystCoverage: coverage,
            governance: governanceAssessment)
    }

    /// FAST leg — price/flow signals that move intraday. `sectorIndexSymbol` comes from the slow leg
    /// so this can run alone on an intraday-only sweep. A missing price is an essential failure.
    func liveSignals(for t: Ticker, sectorIndexSymbol: String?) async throws -> LiveSlice {
        let from = now().addingTimeInterval(-history)
        let to = now()

        let stockBars = try await paced { try await self.priceFeed.dailyBars(symbol: t, from: from, to: to) }
        let dailyBars = stockBars.ohlcvSeries
        guard let price = dailyBars.last?.close else { throw SelectionProviderError.noPriceData(t) }

        // Sector-index bars (shared/cached). Absent ⇒ empty; the timing modifier guards on count.
        var sectorIndexBars: [OHLCV] = []
        if let sectorIndexSymbol {
            sectorIndexBars = (try? await indexBars(sectorIndexSymbol, from: from, to: to)) ?? []
        }
        let marketIndexBars = (try? await indexBars(Self.marketIndexSymbol, from: from, to: to)) ?? []

        // Broker accumulation signal → 0 on failure / no activity (no information → no tilt).
        let brokerRecords = (try? await paced { try await self.broker.dailyActivity(symbol: t) }) ?? []
        let brokerSignal = SelectionFundamentals.brokerAccumulationSignal(
            from: brokerRecords, window: config.flow.foreignWindow)

        let distribution = try? await paced { try await self.orderFlowService.distribution(symbol: t) }

        return LiveSlice(
            price: price,
            dailyBars: dailyBars,
            foreignNetFlow: stockBars.foreignNetFlowSeries,
            brokerAccumulationSignal: brokerSignal,
            sectorIndexBars: sectorIndexBars,
            marketIndexBars: marketIndexBars,
            brokerDistribution: distribution)
    }

    /// Reassemble a `SecurityData` from the two cadence legs. Pure (no actor state) so it composes a
    /// freshly-fetched leg or a cached/persisted one identically — the read-side merge in later phases.
    static func compose(_ t: Ticker, fundamentals f: FundamentalSlice, live l: LiveSlice) -> SecurityData {
        SecurityData(
            ticker: t,
            sector: f.sector,
            price: l.price,
            sharesOutstanding: f.sharesOutstanding,
            freeFloatPct: f.freeFloatPct,
            financials: f.financials,
            ttm: f.ttm,
            dailyBars: l.dailyBars,
            foreignNetFlow: l.foreignNetFlow,
            brokerAccumulationSignal: l.brokerAccumulationSignal,
            sectorIndexBars: l.sectorIndexBars,
            marketIndexBars: l.marketIndexBars,
            peerComparison: f.peerComparison,
            seasonality: f.seasonality,
            brokerDistribution: l.brokerDistribution,
            analystCoverage: f.analystCoverage,
            governance: f.governance)
    }

    /// Daily bars for a market/sector index, fetched once per run and cached by symbol.
    private func indexBars(_ symbol: String, from: Date, to: Date) async throws -> [OHLCV] {
        if let cached = indexBarsCache[symbol] { return cached }
        let bars = try await paced { try await self.priceFeed.dailyBars(symbol: symbol, from: from, to: to) }
        let series = bars.ohlcvSeries
        indexBarsCache[symbol] = series
        return series
    }

    // MARK: - Market context (RegimeViewModel fan-out, reused verbatim — §1.7 / §3)

    private func fetchMarketContext() async throws -> MarketContext {
        async let snapshotTask = snapshotProvider.snapshot()
        async let flowTask = flowService.marketFlow()
        async let ihsgTask = chartService.candles(symbol: Self.marketIndexSymbol, timeframe: .oneYear)
        // SP500 advertises only the LINE chart type — a CANDLE request fails to decode (no OHLC
        // per point); the global-equities factor needs closes only, so fetch the line series.
        async let sp500Task = chartService.candles(symbol: Self.globalEquitySymbol, timeframe: .oneYear, chartType: .line)
        async let rupiahTask = commodityService.quote(symbol: Self.rupiahSymbol)
        async let breadthTask = breadthService.reading(symbols: breadthConstituents)
        // Market-wide flow leaderboard (Slice 4) — best-effort carried context; joins the same
        // one-shot concurrent fan-out (not throttled), degrading to nil on failure.
        async let flowLeadersTask = orderFlowService.topStocks(valueType: .net)

        let snapshot = try? await snapshotTask
        let flow = try? await flowTask
        let ihsg = try? await ihsgTask
        let sp500 = try? await sp500Task
        let rupiah = try? await rupiahTask
        let breadth = await breadthTask
        let flowLeaders = try? await flowLeadersTask
        let distance = ihsg.flatMap { MovingAverage.distanceFromSMA($0, period: 200) }
        let sp500Distance = sp500.flatMap { MovingAverage.distanceFromSMA($0, period: 200) }

        // Decide emptiness exactly as the regime screen does: if no factor resolves, refuse to
        // score a phantom regime (§1.7). `RegimeFactorBuilder` is the single source of that rule.
        let factors = RegimeFactorBuilder.factors(
            snapshot: snapshot,
            netForeignRaw: flow?.netForeign.raw,
            netForeignText: flow?.netForeign.formatted,
            ihsgDistanceFrom200dma: distance,
            sp500DistanceFrom200dma: sp500Distance,
            usdIdrChangePercent: rupiah?.changePercent,
            breadth: breadth)
        guard !factors.isEmpty else { throw SelectionProviderError.noRegimeInputs }

        var context = SelectionFundamentals.marketContext(
            snapshot: snapshot,
            marketForeignFlowNet: flow?.netForeign.raw,
            ihsgDistanceFrom200dma: distance,
            usdIdrChangePercent: rupiah?.changePercent,
            breadth: breadth,
            // v1: no single market-wide "relevant" commodity to read — left neutral (§3 note).
            commodityChangePercent: nil)
        context.flowLeaders = flowLeaders
        return context
    }

    // MARK: - Throttle helper

    /// Awaits the shared anti-burst gap, then runs `body`. The first call is free; each subsequent
    /// call sleeps a randomized interval, serialising the fan-out.
    private func paced<T>(_ body: () async throws -> T) async throws -> T {
        try await throttle.wait()
        return try await body()
    }
}
