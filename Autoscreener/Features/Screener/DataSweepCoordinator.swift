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
    /// True only while the sweep is parked in the anti-burst throttle gap between two
    /// requests. Lets the title-bar status flip "Fetching" → "Throttling" during the pause
    /// instead of looking stalled. Always false outside a sweep.
    private(set) var isThrottling: Bool = false
    private(set) var loadedScreenerCount: Int = 0
    /// Page currently being pulled within a multi-page screener fetch. 1 on the first page
    /// (and 0 between screeners / on the non-paginated market+regime legs); ≥2 once a screener
    /// runs deep, which the title-bar status surfaces as a "page x" suffix.
    private(set) var currentPage: Int = 0
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
    /// BI policy rate, fetched on-device (bi.go.id / FRED) — replaces the daily Python
    /// `refresh_bi` patch. Merged over the published snapshot's `biRate`.
    private let biRateProvider: any BIRateProviding
    /// FRED global anchors (US fed funds / 10y / broad dollar), fetched on-device —
    /// replaces the scraper's `macro` block. Merged over the published snapshot's `macro`.
    private let macroProvider: any FREDMacroProviding
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
    /// Max age of the cached BI rate / FRED macro before a sweep refetches them.
    private let macroTTL: TimeInterval
    /// When false, `start()` seeds the stores with a single sweep instead of running
    /// the continuous loop — used under UI-test fixtures so data is deterministic and
    /// the app doesn't fetch on a timer during a test.
    private let runsContinuousLoop: Bool
    private let sleeper: Sleeper
    /// Reads the live "continuous auto-fetch" setting each loop tick (`SweepSettings`). When it
    /// returns false and the IDX is open, the loop fires a full sweep only at session boundaries
    /// instead of every 5–10 min (see `runLoop`). Defaulted to always-on so existing callers and
    /// tests are byte-for-byte unchanged.
    private let continuousAutoFetch: @MainActor () -> Bool
    /// Optional post-sweep step, run on the main actor after a full IDX-inclusive sweep completes (so
    /// prices + regime are fresh). The app wires this to the paper-trading autopilot's once-per-day
    /// auto-rebalance; defaulted `nil` so every existing caller and test is byte-for-byte unchanged.
    private let postSweep: PostSweep?
    /// Optional cache-warming step, run on the main actor after a full IDX-inclusive sweep's prices +
    /// regime land, BEFORE `postSweep`. The app wires this to fill `SecurityDataStore` (the per-symbol
    /// data the Recommendations engine ranks from) so the screen reads cache instead of fetching live —
    /// and so the autopilot in `postSweep` rebalances off a warm cache. Defaulted `nil` so existing
    /// callers/tests are unchanged. Like `postSweep`, it only runs on full IDX sweeps (frozen at close).
    private let securitySweep: SecuritySweep?

    typealias PostSweep = @MainActor () async -> Void
    typealias SecuritySweep = @MainActor () async -> Void

    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var didStart = false
    /// Reset at the top of every sweep — the first request pays no throttle gap.
    @ObservationIgnored private var hasIssuedFirstRequest = false
    /// When the last full (IDX-inclusive) sweep ran — the sweep that refreshes the screeners, regime,
    /// and the selection cache. The loop compares it against `clock.mostRecentClose` to capture each
    /// session's official close exactly once after the market closes (see `runLoop`). nil until the
    /// first full sweep; injectable so tests can stand the coordinator up as already-captured.
    @ObservationIgnored private(set) var lastFullSweepAt: Date?

    /// BI rate + FRED macro change at most daily; refetching them every open sweep
    /// (5–10 min) would hammer bi.go.id/FRED for nothing. Cached in-memory across sweeps
    /// and refreshed only when older than `macroTTL` — the on-device equivalent of the
    /// old once-a-day Python refresh job. A transient fetch failure keeps the prior value
    /// (and leaves the timestamp unset) so the next sweep retries rather than blanking.
    @ObservationIgnored private var cachedBIRate: RegimeSnapshot.BIRate?
    @ObservationIgnored private var cachedMacro: RegimeSnapshot.MacroBlock?
    @ObservationIgnored private var lastMacroFetchAt: Date?

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
         biRateProvider: any BIRateProviding,
         macroProvider: any FREDMacroProviding,
         catalog: [MarketSymbol] = MarketCatalog.all,
         constituents: [String] = LQ45Constituents.symbols,
         runsContinuousLoop: Bool = true,
         safetyCap: Int = 20,
         throttleRange: ClosedRange<UInt64> = 1_000_000_000...1_500_000_000,
         openGapRange: ClosedRange<UInt64> = 300_000_000_000...600_000_000_000,
         closedGapRange: ClosedRange<UInt64> = 1_200_000_000_000...1_800_000_000_000,
         macroTTL: TimeInterval = 12 * 60 * 60,
         sleeper: @escaping Sleeper = { try await Task.sleep(nanoseconds: $0) },
         continuousAutoFetch: @escaping @MainActor () -> Bool = { true },
         postSweep: PostSweep? = nil,
         securitySweep: SecuritySweep? = nil,
         lastFullSweepAt: Date? = nil) {
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
        self.biRateProvider = biRateProvider
        self.macroProvider = macroProvider
        self.macroTTL = macroTTL
        self.catalog = catalog
        self.constituents = constituents
        self.runsContinuousLoop = runsContinuousLoop
        self.safetyCap = safetyCap
        self.throttleRange = throttleRange
        self.openGapRange = openGapRange
        self.closedGapRange = closedGapRange
        self.sleeper = sleeper
        self.continuousAutoFetch = continuousAutoFetch
        self.postSweep = postSweep
        self.securitySweep = securitySweep
        self.lastFullSweepAt = lastFullSweepAt
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
    ///
    /// **Closing capture.** While closed, if the last full sweep predates the most recent 16:00 close
    /// (`needsClosingCapture`), the loop forces one full sweep to lock in the official closing figures —
    /// the regular session ends at 15:50, so the in-hours sweeps never saw the closing-auction print, and
    /// without this the selection cache would either hold pre-close numbers or age out entirely over a
    /// weekend/holiday (stranding the Recommendations screen). The forced sweep warms data only
    /// (`runAutopilot: false`); the once-a-day autopilot stays tied to live sessions. It's one-shot:
    /// `lastFullSweepAt` then sits past the close, so later closed ticks fall through to around-the-clock.
    func runLoop() async {
        while !Task.isCancelled {
            // Boundary-only mode: the user turned continuous auto-fetch off and we're inside the
            // trading day (09:00–16:00, lunch break included). Fire a full sweep only when a session
            // boundary (open / break / resume) has been crossed since the last one; otherwise fetch
            // nothing at all and sleep until the next edge. The 16:00 close is handled by the
            // closed-market path below, once `now` leaves the window.
            if clock.isWithinTradingDay(at: clock.now()) && !continuousAutoFetch() {
                if needsBoundaryCapture() {
                    await runSweep(includeIDX: true, runAutopilot: clock.isOpen())
                }
                do { try await sleeper(boundaryGap(from: clock.now())) } catch { return }
                continue
            }

            let open = clock.isOpen()
            let capturingClose = !open && needsClosingCapture()
            await runSweep(includeIDX: open || capturingClose, runAutopilot: open)
            let gap = open ? UInt64.random(in: openGapRange) : UInt64.random(in: closedGapRange)
            do { try await sleeper(gap) } catch { return }
        }
    }

    /// True when a session boundary has been crossed since the last full sweep, so a boundary
    /// capture is owed. Mirrors `needsClosingCapture`: a nil last-sweep means owed (cold start).
    private func needsBoundaryCapture() -> Bool {
        guard let boundary = clock.mostRecentBoundary(asOf: clock.now()) else { return false }
        guard let last = lastFullSweepAt else { return true }
        return last < boundary
    }

    /// Nanoseconds until the next session boundary, floored at 1s so we never busy-spin if we wake
    /// a hair early. Lets boundary-only mode sleep precisely until the next edge instead of polling.
    private func boundaryGap(from now: Date) -> UInt64 {
        let seconds = max(clock.nextBoundary(after: now).timeIntervalSince(now), 1)
        return UInt64(seconds * 1_000_000_000)
    }

    /// True when the market is between sessions and we haven't yet captured the most recent session's
    /// official close: no full sweep has run (`lastFullSweepAt == nil`), or the last one predates that
    /// close. False once captured, so the loop forces the closing sweep exactly once per session.
    private func needsClosingCapture() -> Bool {
        guard let close = clock.mostRecentClose(asOf: clock.now()) else { return false }
        guard let last = lastFullSweepAt else { return true }
        return last < close
    }

    /// Manual one-off sweep — wired to every Refresh button. Forces a full refresh
    /// (screeners + IDX quotes + regime included) regardless of session, so the user
    /// can pull fresh data after the market closes.
    func refreshNow() async { await runSweep(includeIDX: true) }

    /// One full throttled sweep. `includeIDX` decides whether the IDX-session legs
    /// (screeners, composite/index/sector quotes, regime read) run or are left frozen;
    /// the around-the-clock legs (global/commodity/FX quotes) always run. Re-entrancy
    /// guarded so a manual refresh can't overlap a loop sweep.
    /// `runAutopilot` lets the closing-capture sweep warm data WITHOUT triggering the once-a-day
    /// autopilot rebalance (the loop passes `false` for it; every other caller keeps the default).
    func runSweep(includeIDX: Bool? = nil, runAutopilot: Bool = true) async {
        guard !isSweeping else { return }
        isSweeping = true
        loadedScreenerCount = 0
        currentPage = 0
        hasIssuedFirstRequest = false
        lastError = nil
        defer { isSweeping = false }

        let idx = includeIDX ?? clock.isOpen()

        if idx {
            await sweepScreeners()
            // Stamp the full-sweep time so the loop's closing capture is one-shot. Set here (not after
            // the catalog guard) so it also covers the screener-only path the unit tests exercise.
            lastFullSweepAt = clock.now()
        }

        // No market catalog → screener-only path (the screener unit tests).
        guard !catalog.isEmpty else { return }

        await sweepMarketQuotes(includeIDX: idx)
        if idx { await sweepRegime() }
        marketStore.markSweepComplete(at: clock.now())

        // After a full IDX sweep (fresh prices + regime), warm the per-symbol selection cache so the
        // Recommendations engine ranks from `SecurityDataStore` instead of fetching live on tab open.
        // Runs before `postSweep` so the autopilot rebalances off the freshly-warmed cache. Frozen on
        // closed-only sweeps (like the IDX legs above); a manual `refreshNow()` forces it after close.
        if idx, let securitySweep { await securitySweep() }

        // After a full IDX sweep (fresh prices + regime), run the optional post-sweep step — the
        // paper-trading autopilot's once-per-day auto-rebalance. Skipped on closed-only sweeps so it
        // never trades on stale data, on the screener-only path (returns above), and on the loop's
        // closing-capture sweep (`runAutopilot == false`) — that warms the close without trading.
        if idx, runAutopilot, let postSweep { await postSweep() }
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

        currentPage = 0
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
        currentPage = 1
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
                currentPage = page
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
        print("[regime] ── sweep starting ──")

        // regime.json (the valuation/percentile leg) is public GitHub data off a
        // different host — fetched untimed, outside the Stockbit anti-burst throttle.
        let published = try? await snapshotProvider.snapshot()
        if let p = published {
            print("[regime] published snapshot: asOf=\(p.asOf) · biRate=\(p.biRate.map { "\($0.value)% \($0.direction)" } ?? "—") · macro=\(p.macro != nil ? "present" : "—") · indices=\(p.indices.count)")
        } else {
            print("[regime] published snapshot: unavailable — falling back to on-device + cached")
        }

        // BI rate + FRED macro are now sourced on-device (bi.go.id / FRED, plain HTTPS off
        // their own hosts — also untimed), refreshed at most daily, then merged *over* the
        // published snapshot so the device value wins and the published one is a fallback.
        await refreshMacroIfStale()
        let snapshot = mergedSnapshot(published: published)
        if let s = snapshot {
            print("[regime] merged inputs: asOf=\(s.asOf) · biRate=\(s.biRate != nil) · macro=\(s.macro != nil) · indices=\(s.indices.count)")
        } else {
            print("[regime] merged inputs: none (no snapshot/biRate/macro) — read built from market legs only")
        }

        do { try await throttle() } catch { print("[regime] cancelled before foreign-flow fetch"); return }
        let flow = try? await self.flow.marketFlow()
        print("[regime] foreign flow: \(flow.map { "net \($0.netForeign.formatted)" } ?? "unavailable")")

        do { try await throttle() } catch { print("[regime] cancelled before IHSG fetch"); return }
        let ihsg = try? await chart.candles(symbol: Self.compositeSymbol, timeframe: .oneYear)
        print("[regime] IHSG: \(Self.trendSummary(ihsg))")

        do { try await throttle() } catch { print("[regime] cancelled before SP500 fetch"); return }
        let sp500 = try? await chart.candles(symbol: Self.globalEquitySymbol, timeframe: .oneYear)
        print("[regime] SP500: \(Self.trendSummary(sp500))")

        let usdIdr = marketStore.quotes[Self.rupiahSymbol]?.changePercent
        let above = store.snapshot(for: .above200MA)
        let breadth = LQ45Breadth.reading(aboveSnapshot: above, constituents: constituents)
        print("[regime] USD/IDR today=\(usdIdr.map { String(format: "%+.2f%%", $0) } ?? "—") · breadth=\(breadth.map { "\($0.above)/\($0.measured) above 200dma" } ?? "—")")

        if let read = RegimeComposer.compose(
            snapshot: snapshot, flow: flow, ihsg: ihsg, sp500: sp500,
            usdIdrChangePercent: usdIdr, aboveSnapshot: above, constituents: constituents) {
            print("[regime] READ → \(read.stance.rawValue) · score \(String(format: "%+.3f", read.score)) · \(read.factors.count) factors\(read.valuationCapped ? " · valuation-capped" : "")")
            for f in read.factors {
                print("[regime]    · \(f.kind.rawValue): \(f.signal.rawValue) — \(f.detail)")
            }
            marketStore.apply(regimeRead: read)
        } else {
            print("[regime] compose produced no read (no factors available) — keeping prior read")
        }
    }

    /// One-line trend summary of a price series for the regime log: candle count and the
    /// latest close's distance from its 200-day average (the input the trend factor uses).
    private static func trendSummary(_ series: PriceSeries?) -> String {
        guard let series else { return "unavailable" }
        let dist = MovingAverage.distanceFromSMA(series, period: 200)
            .map { String(format: "%+.2f%% vs 200dma", $0 * 100) } ?? "200dma n/a"
        return "\(series.candles.count) candles · \(dist)"
    }

    /// Refreshes the cached BI rate + FRED macro when the cache is older than `macroTTL`
    /// (or never fetched). Each source degrades independently: a failed fetch keeps the
    /// prior value, and the timestamp only advances when *something* was fetched, so a
    /// transient outage retries on the next sweep instead of freezing for the whole TTL.
    private func refreshMacroIfStale() async {
        let now = clock.now()
        if let last = lastMacroFetchAt, now.timeIntervalSince(last) < macroTTL { return }

        let bi = await biRateProvider.biRate()
        let macro = await macroProvider.macro()
        if let bi { cachedBIRate = bi }
        if let macro { cachedMacro = macro }
        if bi != nil || macro != nil { lastMacroFetchAt = now }
    }

    /// Merges the on-device BI rate / macro *over* the published snapshot (device wins,
    /// published is the fallback), keeping the server-only valuation `indices`. Returns
    /// `nil` when there's nothing to compose from at all, so the caller keeps any prior
    /// read — the same graceful-degradation contract a missing snapshot had before.
    private func mergedSnapshot(published: RegimeSnapshot?) -> RegimeSnapshot? {
        let biRate = cachedBIRate ?? published?.biRate
        let macro = cachedMacro ?? published?.macro
        let indices = published?.indices ?? [:]
        guard biRate != nil || macro != nil || !indices.isEmpty else { return nil }
        return RegimeSnapshot(
            asOf: freshestAsOf(published: published, biRate: biRate, macro: macro),
            biRate: biRate, macro: macro, indices: indices)
    }

    /// The freshest dated input feeding the read (`RegimeRead.asOf`). ISO `yyyy-MM-dd`
    /// sorts chronologically, so the max string is the most recent — usually the live BI
    /// or FRED date now, rather than the monthly valuation vintage.
    private func freshestAsOf(published: RegimeSnapshot?,
                              biRate: RegimeSnapshot.BIRate?,
                              macro: RegimeSnapshot.MacroBlock?) -> String {
        var candidates: [String] = []
        if let p = published?.asOf { candidates.append(p) }
        if let b = biRate?.asOf { candidates.append(b) }
        if let macro {
            candidates.append(contentsOf:
                [macro.usFedFunds?.asOf, macro.us10y?.asOf, macro.broadDollar?.asOf].compactMap { $0 })
        }
        return candidates.max() ?? MacroParsing.isoString(clock.now())
    }

    // MARK: - Throttle + failure surfacing

    /// Sleeps a randomized `throttleRange` before each outgoing request, except the
    /// very first one in a sweep. Stockbit penalises parallel bursts. `isThrottling` is
    /// raised for the duration of the gap (and cleared even if the sleeper throws on
    /// cancellation) so the status bar reads "Throttling" while paused.
    private func throttle() async throws {
        if hasIssuedFirstRequest {
            isThrottling = true
            defer { isThrottling = false }
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
