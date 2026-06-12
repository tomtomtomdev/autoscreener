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
nonisolated enum SelectionProviderError: Error, Equatable {
    /// The daily-bar feed returned no bars, so there's no price to value the name on.
    case noPriceData(Ticker)
    /// Every market-wide regime input failed/was absent — refuse to score a phantom regime
    /// (mirrors `RegimeViewModel` surfacing an error rather than reading an empty factor list, §1.7).
    case noRegimeInputs
}

actor StockbitDataProvider: DataProvider {

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
    /// Two calendar years of daily bars comfortably clears `dataIntegrity.minTradingDays` (200).
    static let defaultHistory: TimeInterval = 2 * 365 * 24 * 60 * 60

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
        let from = now().addingTimeInterval(-history)
        let to = now()

        // --- Essential legs: a failure here means the name can't be valued (propagates). ---

        // Classify by sector FIRST. A bank's keystats omits current ratio / D-E ("-"), so the TTM
        // adapter must know the archetype to relax the right required fields (§14 / Phase 3.6):
        // otherwise it throws `missingField` and the name never reaches the engine to be routed to
        // the financial profile. `/emitten/info` was always fetched essential — only its order moves.
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

        let stockBars = try await paced { try await self.priceFeed.dailyBars(symbol: t, from: from, to: to) }
        let dailyBars = stockBars.ohlcvSeries
        guard let price = dailyBars.last?.close else { throw SelectionProviderError.noPriceData(t) }

        // --- Best-effort legs: degrade to a no-evidence value rather than abort the run. ---

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

        // Sector-index bars (shared/cached). Absent ⇒ empty; the timing modifier guards on count.
        var sectorIndexBars: [OHLCV] = []
        if let sectorSymbol = SelectionFundamentals.sectorIndexSymbol(for: info) {
            sectorIndexBars = (try? await indexBars(sectorSymbol, from: from, to: to)) ?? []
        }
        let marketIndexBars = (try? await indexBars(Self.marketIndexSymbol, from: from, to: to)) ?? []

        // Broker accumulation signal → 0 on failure / no activity (no information → no tilt).
        let brokerRecords = (try? await paced { try await self.broker.dailyActivity(symbol: t) }) ?? []
        let brokerSignal = SelectionFundamentals.brokerAccumulationSignal(
            from: brokerRecords, window: config.flow.foreignWindow)

        // Captured-endpoint overlays (Slice 4) — carried context only, each best-effort: a paywall /
        // no-coverage / failure degrades the leg to nil rather than aborting the name's valuation.
        let peers = try? await paced { try await self.comparisonService.comparison(symbol: t) }
        let year = Calendar(identifier: .gregorian).component(.year, from: now())
        let seasonality = try? await paced { try await self.seasonalityService.seasonality(symbol: t, year: year) }
        let distribution = try? await paced { try await self.orderFlowService.distribution(symbol: t) }

        return SecurityData(
            ticker: t,
            sector: info.sector,
            price: price,
            sharesOutstanding: shares ?? 0,
            freeFloatPct: freeFloat,
            financials: annuals,
            ttm: ttm,
            dailyBars: dailyBars,
            foreignNetFlow: stockBars.foreignNetFlowSeries,
            brokerAccumulationSignal: brokerSignal,
            sectorIndexBars: sectorIndexBars,
            marketIndexBars: marketIndexBars,
            peerComparison: peers,
            seasonality: seasonality,
            brokerDistribution: distribution)
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
        async let sp500Task = chartService.candles(symbol: Self.globalEquitySymbol, timeframe: .oneYear)
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
