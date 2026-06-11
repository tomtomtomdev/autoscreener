import Foundation
import Observation
import OSLog

private let sweepLog = Logger(subsystem: "com.tom.tom.tom.Autoscreener", category: "data-sweep")

/// Owns the only fetch path in the app: a single throttled fan-out that fills both the
/// `ScreenerStore` (the 20 bandar screeners) and the `MarketDataStore` (the Markets
/// price snapshots + the synthesised regime read). Every outgoing Stockbit request —
/// screener page, market quote, or regime input — is separated by the same anti-burst
/// throttle, so the whole app issues one request at a time and Stockbit never sees a
/// parallel burst. Every UI surface reads a store; nothing else touches the network.
///
/// **Cadence.** The loop always sweeps. While the IDX is open it refreshes everything
/// (5–10 min gap); while closed it refreshes only the around-the-clock legs (global
/// indices, commodities, FX) on a slower 20–30 min gap and leaves the IDX-session legs
/// — screeners, composite/index/sector quotes, and the regime read — frozen on their
/// last snapshot, since those values don't change after the close. A manual refresh
/// (`refreshNow`) forces a full sweep regardless of session.
@MainActor
@Observable
final class DataSweepCoordinator {
    typealias Sleeper = @Sendable (UInt64) async throws -> Void

    // UI-facing progress, observed by the Watchlist/Screener toolbars.
    private(set) var isSweeping: Bool = false
    private(set) var loadedScreenerCount: Int = 0
    var paywallMessage: String?
    var lastError: String?

    var totalScreenerCount: Int { Self.fanOutOrder.count }

    private let store: ScreenerStore
    private let marketStore: MarketDataStore
    private let clock: MarketClock
    private let paywall: any PaywallServicing
    private let templates: any ScreenerTemplateServicing
    private let screener: any ScreenerServicing
    private let commodity: any CommodityPriceServicing
    private let chart: any ChartServicing
    private let flow: any AggregateForeignFlowServicing
    private let snapshotProvider: any RegimeSnapshotProviding
    /// Markets symbols to price each sweep. Empty disables the market + regime legs
    /// entirely (the screener-only path used by the screener unit tests).
    private let catalog: [MarketSymbol]
    /// LQ45 constituents the regime breadth factor intersects against the screener's
    /// `.above200MA` snapshot.
    private let constituents: [String]
    private let safetyCap: Int
    private let throttleRange: ClosedRange<UInt64>
    /// Gap between sweeps while the IDX is open (default 5–10 min).
    private let openGapRange: ClosedRange<UInt64>
    /// Gap between sweeps while the IDX is closed (default 20–30 min) — slower because
    /// only the around-the-clock legs refresh.
    private let closedGapRange: ClosedRange<UInt64>
    /// When false, `start()` seeds the stores with a single sweep instead of running
    /// the continuous loop — used under UI-test fixtures so data is deterministic and
    /// the app doesn't fetch on a timer during a test.
    private let runsContinuousLoop: Bool
    private let sleeper: Sleeper

    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var didStart = false
    /// Reset at the top of every sweep — the first request pays no throttle gap.
    @ObservationIgnored private var hasIssuedFirstRequest = false

    /// IHSG — the composite index, for the regime's 200-day trend signal.
    private static let compositeSymbol = "IHSG"
    /// S&P 500 — the regime's live global risk-appetite leg (200-day trend).
    private static let globalEquitySymbol = "SP500"
    /// USD/IDR — the rupiah leg; read from the currency quote fetched this sweep
    /// rather than re-requested (the Markets list already prices it).
    private static let rupiahSymbol = "USDIDR"

    /// Canonical order screeners are fetched in. Every request (and every page within
    /// a screener) is separated by a randomized `throttleRange` gap so Stockbit never
    /// sees a 20-way parallel burst. The two veto gates come last.
    static let fanOutOrder: [BandarScreenerKind] = [
        .accumulating, .aboveMA20, .shiftToday, .accumDistPositive,
        .foreignFlow1M, .foreignFlow6M, .foreignFlow3M, .foreignBuyStreak,
        .freshForeignBuy, .freqSpike, .volumeSpike, .above50MA, .above200MA,
        .earningsYield, .pbvBelow2, .roeQuality, .fcfPositive, .manageableDebt,
        .liquidityFloor, .intradayLiquidity,
    ]

    init(store: ScreenerStore,
         marketStore: MarketDataStore,
         clock: MarketClock,
         paywall: any PaywallServicing,
         templates: any ScreenerTemplateServicing,
         screener: any ScreenerServicing,
         commodity: any CommodityPriceServicing,
         chart: any ChartServicing,
         flow: any AggregateForeignFlowServicing,
         snapshotProvider: any RegimeSnapshotProviding,
         catalog: [MarketSymbol] = MarketCatalog.all,
         constituents: [String] = LQ45Constituents.symbols,
         runsContinuousLoop: Bool = true,
         safetyCap: Int = 20,
         throttleRange: ClosedRange<UInt64> = 1_000_000_000...1_500_000_000,
         openGapRange: ClosedRange<UInt64> = 300_000_000_000...600_000_000_000,
         closedGapRange: ClosedRange<UInt64> = 1_200_000_000_000...1_800_000_000_000,
         sleeper: @escaping Sleeper = { try await Task.sleep(nanoseconds: $0) }) {
        self.store = store
        self.marketStore = marketStore
        self.clock = clock
        self.paywall = paywall
        self.templates = templates
        self.screener = screener
        self.commodity = commodity
        self.chart = chart
        self.flow = flow
        self.snapshotProvider = snapshotProvider
        self.catalog = catalog
        self.constituents = constituents
        self.runsContinuousLoop = runsContinuousLoop
        self.safetyCap = safetyCap
        self.throttleRange = throttleRange
        self.openGapRange = openGapRange
        self.closedGapRange = closedGapRange
        self.sleeper = sleeper
    }

    /// Idempotent. In production launches the continuous market-hours loop; under
    /// fixtures seeds the stores with a single sweep so the UI has deterministic data.
    func start() {
        guard !didStart else { return }
        didStart = true
        if runsContinuousLoop {
            loopTask = Task { [weak self] in await self?.runLoop() }
        } else {
            // Seed mode (fixtures): one full sweep regardless of session, so the UI has
            // deterministic screener + market + regime data however the clock reads.
            Task { [weak self] in await self?.runSweep(includeIDX: true) }
        }
    }

    /// The market-hours loop. Always sweeps, then sleeps a randomized gap — 5–10 min
    /// while open (full refresh), 20–30 min while closed (around-the-clock legs only).
    /// A thrown sleeper (cancellation) ends the loop. `internal` so tests can drive it
    /// directly with a fake clock + cancelling sleeper.
    func runLoop() async {
        while !Task.isCancelled {
            let open = clock.isOpen()
            await runSweep(includeIDX: open)
            let gap = open ? UInt64.random(in: openGapRange) : UInt64.random(in: closedGapRange)
            do { try await sleeper(gap) } catch { return }
        }
    }

    /// Manual one-off sweep — wired to every Refresh button. Forces a full refresh
    /// (screeners + IDX quotes + regime included) regardless of session, so the user
    /// can pull fresh data after the market closes.
    func refreshNow() async { await runSweep(includeIDX: true) }

    /// One full throttled sweep. `includeIDX` decides whether the IDX-session legs
    /// (screeners, composite/index/sector quotes, regime read) run or are left frozen;
    /// the around-the-clock legs (global/commodity/FX quotes) always run. Re-entrancy
    /// guarded so a manual refresh can't overlap a loop sweep.
    func runSweep(includeIDX: Bool? = nil) async {
        guard !isSweeping else { return }
        isSweeping = true
        loadedScreenerCount = 0
        hasIssuedFirstRequest = false
        lastError = nil
        defer { isSweeping = false }

        let idx = includeIDX ?? clock.isOpen()

        if idx { await sweepScreeners() }

        // No market catalog → screener-only path (the screener unit tests).
        guard !catalog.isEmpty else { return }

        await sweepMarketQuotes(includeIDX: idx)
        if idx { await sweepRegime() }
        marketStore.markSweepComplete(at: clock.now())
    }

    // MARK: - Screeners

    /// The 20-kind screener fan-out, writing each snapshot into the `ScreenerStore` as
    /// it lands. One paywall check/increment for the whole sweep.
    private func sweepScreeners() async {
        let eligibility = await paywall.check(.screener)
        if !eligibility.eligible {
            paywallMessage = eligibility.message ?? "Screener access is limited on your plan."
        } else {
            paywallMessage = nil
        }
        // One increment for the entire sweep — not one per screener.
        await paywall.increment(.screener)

        var perKind: [(BandarScreenerKind, Result<KindFetch, Error>)] = []
        for kind in Self.fanOutOrder {
            let result = await fetchAll(kind)
            perKind.append((kind, result))
            loadedScreenerCount += 1

            if case .success(let fetched) = result {
                sweepLog.info("\(kind.displayName, privacy: .public): \(fetched.rows.count) rows")
                store.apply(
                    ScreenerSnapshot(config: fetched.config, rows: fetched.rows, fetchedAt: clock.now()),
                    for: kind)
            }

            // SwiftUI `.task` tear-down cancels the surrounding task; every later
            // throttle would then throw. Stop instead of marching through failures.
            if Task.isCancelled || isCancellation(result) { break }
        }

        store.markSweepComplete(at: clock.now())
        surfaceFailures(perKind)
    }

    /// Bundled per-kind fetch result — the screener's config plus all collected rows.
    private struct KindFetch {
        let config: ScreenerConfig
        let rows: [ScreenerRow]
    }

    /// Pulls every page for `kind`: page 1 via template-load (GET), pages 2+ via run
    /// (POST). Each outgoing request is preceded by `throttle()`. Stops on a partial
    /// page, when `total` is reached, or at the safety cap — so each snapshot holds
    /// the screener's full result set (which lets the per-tab views drop pagination).
    private func fetchAll(_ kind: BandarScreenerKind) async -> Result<KindFetch, Error> {
        sweepLog.info("\(kind.displayName, privacy: .public): GET templates/\(kind.templateID, privacy: .public)")
        do {
            try await throttle()
            let initial = try await templates.load(templateID: kind.templateID)
            var all = initial.page.rows
            let limit = initial.config.limit
            let total = initial.page.total

            if all.count < limit { return .success(KindFetch(config: initial.config, rows: all)) }
            if let total, all.count >= total { return .success(KindFetch(config: initial.config, rows: all)) }

            var page = 2
            while page <= safetyCap {
                try await throttle()
                let next = try await screener.run(initial.config, page: page)
                all.append(contentsOf: next.rows)
                if next.rows.isEmpty || next.rows.count < limit { break }
                if let total, all.count >= total { break }
                page += 1
            }
            return .success(KindFetch(config: initial.config, rows: all))
        } catch {
            sweepLog.error("\(kind.displayName, privacy: .public): threw \(String(reflecting: error), privacy: .public)")
            return .failure(error)
        }
    }

    // MARK: - Market quotes

    /// Prices the Markets list through the shared throttle, one symbol per tick. IDX
    /// instruments (composite/index/sector) are fetched only when `includeIDX`; the
    /// around-the-clock groups (global/commodity/FX) are always fetched. A symbol that
    /// errors keeps its prior value (the store merges).
    private func sweepMarketQuotes(includeIDX: Bool) async {
        var fetched: [String: CommodityQuote] = [:]
        for item in catalog where includeIDX || !item.group.isIDXSession {
            do { try await throttle() } catch { break }
            if let quote = try? await commodity.quote(symbol: item.symbol) {
                fetched[item.symbol] = quote
            }
        }
        marketStore.applyQuotes(fetched)
    }

    // MARK: - Regime

    /// Gathers the regime inputs through the throttle, then synthesises the read.
    /// Breadth is derived from the `.above200MA` screener snapshot (no per-constituent
    /// chart fan-out); USD/IDR is read from the currency quote priced this sweep. Only
    /// runs when the IDX session leg is included, so the read freezes after the close.
    private func sweepRegime() async {
        // regime.json is public GitHub data off a different host — fetched untimed,
        // outside the Stockbit anti-burst throttle.
        let snapshot = try? await snapshotProvider.snapshot()

        do { try await throttle() } catch { return }
        let flow = try? await self.flow.marketFlow()

        do { try await throttle() } catch { return }
        let ihsg = try? await chart.candles(symbol: Self.compositeSymbol, timeframe: .oneYear)

        do { try await throttle() } catch { return }
        let sp500 = try? await chart.candles(symbol: Self.globalEquitySymbol, timeframe: .oneYear)

        let usdIdr = marketStore.quotes[Self.rupiahSymbol]?.changePercent
        let above = store.snapshot(for: .above200MA)

        if let read = RegimeComposer.compose(
            snapshot: snapshot, flow: flow, ihsg: ihsg, sp500: sp500,
            usdIdrChangePercent: usdIdr, aboveSnapshot: above, constituents: constituents) {
            marketStore.apply(regimeRead: read)
        }
    }

    // MARK: - Throttle + failure surfacing

    /// Sleeps a randomized `throttleRange` before each outgoing request, except the
    /// very first one in a sweep. Stockbit penalises parallel bursts.
    private func throttle() async throws {
        if hasIssuedFirstRequest {
            try await sleeper(UInt64.random(in: throttleRange))
        }
        hasIssuedFirstRequest = true
    }

    private func surfaceFailures(_ results: [(BandarScreenerKind, Result<KindFetch, Error>)]) {
        var failed: [(BandarScreenerKind, Error)] = []
        for (kind, result) in results {
            guard case .failure(let err) = result else { continue }
            if err is CancellationError {
                sweepLog.info("\(kind.displayName, privacy: .public): cancelled mid-sweep")
                continue
            }
            sweepLog.error("\(kind.displayName, privacy: .public) FAILED: \(String(reflecting: err), privacy: .public)")
            failed.append((kind, err))
        }
        if failed.isEmpty {
            lastError = nil
        } else {
            let parts = failed.map { "\($0.0.displayName) (\(String(describing: $0.1)))" }
            lastError = "Couldn't load: \(parts.joined(separator: " · "))"
        }
    }

    private nonisolated func isCancellation(_ res: Result<KindFetch, Error>) -> Bool {
        if case .failure(let err) = res, err is CancellationError { return true }
        return false
    }
}
