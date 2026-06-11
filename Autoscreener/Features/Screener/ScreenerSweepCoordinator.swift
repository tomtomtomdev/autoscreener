import Foundation
import Observation
import OSLog

private let sweepLog = Logger(subsystem: "com.tom.tom.tom.Autoscreener", category: "screener-sweep")

/// Owns the only fetch path in the app: a throttled fan-out across all 20 screeners
/// (bandar-accumulating → intraday-liquidity), writing each result into the
/// `ScreenerStore` as it lands. While the IDX market is open it sweeps continuously
/// (one full sweep, then a randomized 5–10 min gap, repeat); while closed it idles
/// on the cache. Every UI surface reads the store, so nothing else hits the network.
///
/// This is where the fan-out, pagination, and anti-burst throttle that used to live
/// in `WatchlistViewModel` now run. The view models became thin store projections.
@MainActor
@Observable
final class ScreenerSweepCoordinator {
    typealias Sleeper = @Sendable (UInt64) async throws -> Void

    // UI-facing progress, observed by the Watchlist/Screener toolbars.
    private(set) var isSweeping: Bool = false
    private(set) var loadedScreenerCount: Int = 0
    var paywallMessage: String?
    var lastError: String?

    var totalScreenerCount: Int { Self.fanOutOrder.count }

    private let store: ScreenerStore
    private let clock: MarketClock
    private let paywall: any PaywallServicing
    private let templates: any ScreenerTemplateServicing
    private let screener: any ScreenerServicing
    private let safetyCap: Int
    private let throttleRange: ClosedRange<UInt64>
    /// Gap between consecutive sweeps while the market is open (default 5–10 min).
    private let sweepGapRange: ClosedRange<UInt64>
    /// When false, `start()` seeds the store with a single sweep instead of running
    /// the continuous loop — used under UI-test fixtures so data is deterministic
    /// and the app doesn't fetch on a timer during a test.
    private let runsContinuousLoop: Bool
    private let sleeper: Sleeper

    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var didStart = false
    /// Reset at the top of every sweep — the first request pays no throttle gap.
    @ObservationIgnored private var hasIssuedFirstRequest = false

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
         clock: MarketClock,
         paywall: any PaywallServicing,
         templates: any ScreenerTemplateServicing,
         screener: any ScreenerServicing,
         runsContinuousLoop: Bool = true,
         safetyCap: Int = 20,
         throttleRange: ClosedRange<UInt64> = 1_000_000_000...1_500_000_000,
         sweepGapRange: ClosedRange<UInt64> = 300_000_000_000...600_000_000_000,
         sleeper: @escaping Sleeper = { try await Task.sleep(nanoseconds: $0) }) {
        self.store = store
        self.clock = clock
        self.paywall = paywall
        self.templates = templates
        self.screener = screener
        self.runsContinuousLoop = runsContinuousLoop
        self.safetyCap = safetyCap
        self.throttleRange = throttleRange
        self.sweepGapRange = sweepGapRange
        self.sleeper = sleeper
    }

    /// Idempotent. In production launches the continuous market-hours loop; under
    /// fixtures seeds the store with a single sweep so the UI has deterministic data.
    func start() {
        guard !didStart else { return }
        didStart = true
        if runsContinuousLoop {
            loopTask = Task { [weak self] in await self?.runLoop() }
        } else {
            Task { [weak self] in await self?.runSweep() }
        }
    }

    /// The market-hours loop. Open → sweep, then sleep a random 5–10 min. Closed →
    /// sleep until the next session opens (capped so we re-check periodically and
    /// survive clock drift). A thrown sleeper (cancellation) ends the loop.
    /// `internal` so tests can drive it directly with a fake clock + cancelling sleeper.
    func runLoop() async {
        while !Task.isCancelled {
            if clock.isOpen() {
                await runSweep()
                do { try await sleeper(UInt64.random(in: sweepGapRange)) } catch { return }
            } else {
                let now = clock.now()
                let secondsUntilOpen = clock.nextOpen(after: now).timeIntervalSince(now)
                let capped = min(max(secondsUntilOpen, 60), 15 * 60)  // re-check at least every 15 min
                do { try await sleeper(UInt64(capped * 1_000_000_000)) } catch { return }
            }
        }
    }

    /// Manual one-off sweep — wired to every Refresh button so the user can force a
    /// refresh regardless of session (e.g. after the market closes).
    func refreshNow() async { await runSweep() }

    /// One full throttled fan-out, writing each screener's snapshot into the store as
    /// it lands. Re-entrancy guarded so a manual refresh can't overlap a loop sweep.
    func runSweep() async {
        guard !isSweeping else { return }
        isSweeping = true
        loadedScreenerCount = 0
        hasIssuedFirstRequest = false
        lastError = nil
        defer { isSweeping = false }

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
