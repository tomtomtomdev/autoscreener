import Foundation
import Observation
import OSLog
import SwiftUI

private let watchlistLog = Logger(subsystem: "com.tom.tom.tom.Autoscreener", category: "watchlist")

@MainActor
@Observable
final class WatchlistViewModel {
    typealias Sleeper = @Sendable (UInt64) async throws -> Void

    var rows: [WatchlistRow] = []
    var isLoading: Bool = false
    var error: String?
    var paywallMessage: String?
    /// Set when a liquidity veto gate could NOT be enforced this run (its cache was
    /// stale/missing, or its fetch failed) — so the "ILLIQUID" flags reflect only the
    /// gates we could actually evaluate. Surfaced as a soft warning in the status bar.
    var vetoNotice: String?
    /// Wall-clock when the currently-displayed composite landed (fresh fetch or
    /// persisted snapshot). Drives the toolbar's "as of HH:mm" badge.
    var lastFetchedAt: Date?

    private var didAutoRun: Bool = false
    private let paywall: any PaywallServicing
    private let templates: any ScreenerTemplateServicing
    private let screener: any ScreenerServicing
    private let snapshots: (any ScreenerSnapshotStoring)?
    private let safetyCap: Int
    private let throttleRange: ClosedRange<UInt64>
    private let sleeper: Sleeper
    /// Becomes true after the first request fires within a single `bootstrap()` run.
    /// Reset on every fresh bootstrap so a manual refresh doesn't pay the initial gap.
    private var hasIssuedFirstRequest: Bool = false

    init(paywall: any PaywallServicing,
         templates: any ScreenerTemplateServicing,
         screener: any ScreenerServicing,
         snapshots: (any ScreenerSnapshotStoring)? = nil,
         safetyCap: Int = 20,
         throttleRange: ClosedRange<UInt64> = 1_000_000_000...1_500_000_000,
         sleeper: @escaping Sleeper = { try await Task.sleep(nanoseconds: $0) }) {
        self.paywall = paywall
        self.templates = templates
        self.screener = screener
        self.snapshots = snapshots
        self.safetyCap = safetyCap
        self.throttleRange = throttleRange
        self.sleeper = sleeper
    }

    /// One-shot bootstrap. No-ops on repeat so re-appearing views don't re-fire
    /// the paywall counter or the template loads.
    ///
    /// Snapshot path: if a watchlist snapshot exists, render it first so the tab
    /// is never blank; only do real work when no snapshot is on disk (true first
    /// run). The `ScreenerScheduler` owns periodic refreshes.
    func autoRunIfNeeded() async {
        guard !didAutoRun else { return }
        didAutoRun = true
        let snapshotLoaded = await loadSnapshotIntoView()
        if snapshotLoaded { return }
        await refresh()
    }

    /// User-initiated refresh. Under a non-onDemand schedule this is a pure local
    /// **cache aggregation** — the per-screener caches are kept fresh by the
    /// scheduler, so the watchlist just unions them (no network, no throttle, no
    /// sequential delay). Cold start (no caches yet) falls back to one populate.
    /// On-demand keeps the live throttled fan-out, since nothing else fills caches.
    func refresh() async {
        if await persistenceEnabled() {
            if !(await aggregateFromCache()) {
                await scheduledRefresh()  // cold start: populate caches, then union
            }
        } else {
            await liveFanOut()
        }
    }

    /// Scheduler entry point (non-onDemand cadences only). Refreshes every
    /// per-screener cache with the throttled fan-out, then rebuilds the composite
    /// from those caches. Keeps the network fetch off the watchlist's reveal path.
    func scheduledRefresh() async {
        await refreshScreenerCaches()
        await aggregateFromCache()
    }

    /// True when the active schedule persists snapshots (any non-onDemand mode).
    /// We route on this so the watchlist composes from caches under a schedule and
    /// only hits the network on-demand. Nil store ⇒ on-demand (tests, previews).
    private func persistenceEnabled() async -> Bool {
        guard let snapshots else { return false }
        return await snapshots.persistenceEnabled
    }

    @discardableResult
    private func loadSnapshotIntoView() async -> Bool {
        guard let snapshots, let snapshot = await snapshots.loadWatchlist() else {
            return false
        }
        self.rows = snapshot.rows
        self.lastFetchedAt = snapshot.fetchedAt
        return true
    }

    /// Canonical order the screeners are fetched in. Every request (and every page
    /// within a screener) is separated by a randomized 1000–1500ms `throttle()` gap
    /// so Stockbit never sees a 15-way parallel burst at t=0.
    private static let fanOutOrder: [BandarScreenerKind] = [
        .accumulating, .aboveMA20, .shiftToday, .accumDistPositive,
        .foreignFlow1M, .foreignFlow6M, .foreignFlow3M, .foreignBuyStreak,
        .freshForeignBuy, .freqSpike, .volumeSpike, .above50MA, .above200MA,
        .earningsYield, .pbvBelow2, .roeQuality, .fcfPositive, .manageableDebt,
        .liquidityFloor, .intradayLiquidity,
    ]

    private struct FanOutResult {
        let perKind: [(BandarScreenerKind, Result<KindFetch, Error>)]
        let cancelled: Bool
    }

    /// Throttled fan-out across every screener. One paywall increment for the whole
    /// sweep. Does not compose or persist — callers decide what to do with the
    /// per-kind results.
    private func fanOut() async -> FanOutResult {
        hasIssuedFirstRequest = false  // fresh throttle window per sweep

        let eligibility = await paywall.check(.screener)
        if !eligibility.eligible {
            paywallMessage = eligibility.message ?? "Screener access is limited on your plan."
        }
        // One increment for the entire sweep — not one per screener.
        await paywall.increment(.screener)

        var results: [(BandarScreenerKind, Result<KindFetch, Error>)] = []
        var cancelled = false
        for kind in Self.fanOutOrder {
            let res = await fetchAll(kind)
            results.append((kind, res))
            // If the surrounding Task was cancelled (SwiftUI `.task` tear-down on
            // tab switch is the common case), every subsequent throttle() will
            // throw CancellationError. Stop iterating instead of marching through
            // remaining guaranteed-failure rounds.
            if Task.isCancelled || isCancellation(res) { cancelled = true; break }
        }
        return FanOutResult(perKind: results, cancelled: cancelled)
    }

    /// On-demand path: live throttled fan-out, composed in memory and persisted.
    /// Used when no schedule is active (no caches to trust).
    private func liveFanOut() async {
        rows = []
        error = nil
        paywallMessage = nil
        isLoading = true
        defer { isLoading = false }

        let out = await fanOut()
        // A veto gate is only enforceable if it was freshly fetched (succeeded) this
        // run; a failed gate must not flag every row ILLIQUID.
        let evaluableVeto = Set(out.perKind.compactMap { (kind, result) -> BandarScreenerKind? in
            guard kind.isVeto, case .success = result else { return nil }
            return kind
        })
        var byID: [String: WatchlistRow] = [:]
        for (kind, result) in out.perKind {
            guard case .success(let fetched) = result else { continue }
            watchlistLog.info("\(kind.displayName, privacy: .public): \(fetched.rows.count) rows")
            for row in fetched.rows { Self.union(&byID, row: row, kind: kind) }
        }
        rows = Self.ranked(byID.values, evaluableVeto: evaluableVeto)
        vetoNotice = Self.vetoNotice(skipped: BandarScreenerKind.vetoKinds.subtracting(evaluableVeto))
        lastFetchedAt = Date()
        await persist(out.perKind)
        if out.cancelled { didAutoRun = false }
        surfaceFailures(out.perKind)
    }

    /// Scheduled path, phase 1: refresh every per-screener cache via the throttled
    /// fan-out. Writes each screener's full snapshot to disk so the per-tab
    /// `ScreenerViewModel`s — and `aggregateFromCache()` — read fresh rows. No
    /// composite is built here (that's `aggregateFromCache`'s job).
    func refreshScreenerCaches() async {
        error = nil
        paywallMessage = nil
        isLoading = true
        defer { isLoading = false }

        let out = await fanOut()
        if let snapshots {
            let now = Date()
            for (kind, result) in out.perKind {
                guard case .success(let fetched) = result else { continue }
                watchlistLog.info("\(kind.displayName, privacy: .public): cached \(fetched.rows.count) rows")
                await snapshots.saveScreener(ScreenerSnapshot(
                    templateID: kind.templateID,
                    config: fetched.config,
                    rows: fetched.rows,
                    total: nil,
                    fetchedAt: now))
            }
        }
        if out.cancelled { didAutoRun = false }
        surfaceFailures(out.perKind)
    }

    /// Scheduled path, phase 2: compose the watchlist purely from the per-screener
    /// caches on disk — no network, no throttle. Writes `watchlist.json`. Returns
    /// `false` when no per-screener cache exists yet (cold start) so callers can
    /// fall back to a live populate.
    @discardableResult
    func aggregateFromCache() async -> Bool {
        guard let snapshots else { return false }

        var loaded: [(kind: BandarScreenerKind, snapshot: ScreenerSnapshot)] = []
        for kind in BandarScreenerKind.allCases {
            if let snap = await snapshots.loadScreener(templateID: kind.templateID) {
                loaded.append((kind, snap))
            }
        }
        guard !loaded.isEmpty else { return false }

        // Only union caches from the **dominant generation** — the `fetchedAt` shared
        // by the most caches (the scheduler stamps every screener in one sweep
        // identically). A lone stale or page-limited tab-written cache carries a
        // different stamp and is excluded, so it can neither pollute the composite nor
        // fire a blanket veto. This is the fix for "every row shows ILLIQUID": a veto
        // gate the sweep didn't refresh is simply not part of this generation.
        let generationStamp = Self.dominantStamp(loaded.map(\.snapshot.fetchedAt))
        let generation = loaded.filter { $0.snapshot.fetchedAt == generationStamp }

        var byID: [String: WatchlistRow] = [:]
        for (kind, snap) in generation {
            for row in snap.rows { Self.union(&byID, row: row, kind: kind) }
        }

        let evaluableVeto = Set(generation.map(\.kind).filter(\.isVeto))
        error = nil
        vetoNotice = Self.vetoNotice(skipped: BandarScreenerKind.vetoKinds.subtracting(evaluableVeto))
        rows = Self.ranked(byID.values, evaluableVeto: evaluableVeto)
        lastFetchedAt = generationStamp
        await snapshots.saveWatchlist(WatchlistSnapshot(rows: rows, fetchedAt: generationStamp))
        watchlistLog.info("aggregated \(self.rows.count) symbols from \(generation.count) cached screeners")
        return true
    }

    /// Most-common timestamp; ties broken toward the newest. Empty input is guarded
    /// by the caller.
    private static func dominantStamp(_ stamps: [Date]) -> Date {
        var counts: [Date: Int] = [:]
        for s in stamps { counts[s, default: 0] += 1 }
        return counts.sorted { ($0.value, $0.key) > ($1.value, $1.key) }.first?.key ?? (stamps.first ?? Date())
    }

    private static func union(_ byID: inout [String: WatchlistRow], row: ScreenerRow, kind: BandarScreenerKind) {
        if var existing = byID[row.symbol] {
            existing.matchedScreeners.insert(kind)
            byID[row.symbol] = existing
        } else {
            byID[row.symbol] = WatchlistRow(symbol: row.symbol, name: row.name, matchedScreeners: [kind])
        }
    }

    /// Materializes each row's `failedVetoGates` (against the gates we could actually
    /// evaluate) and sorts by score desc, then symbol asc.
    private static func ranked(_ rows: Dictionary<String, WatchlistRow>.Values,
                               evaluableVeto: Set<BandarScreenerKind>) -> [WatchlistRow] {
        rows.map { row -> WatchlistRow in
            var r = row
            r.failedVetoGates = evaluableVeto.filter { !row.matchedScreeners.contains($0) }
            return r
        }
        .sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.symbol < b.symbol
        }
    }

    private static func vetoNotice(skipped: Set<BandarScreenerKind>) -> String? {
        guard !skipped.isEmpty else { return nil }
        let names = skipped.map(\.displayName).sorted()
        return "Liquidity veto not enforced (stale/missing cache): \(names.joined(separator: ", "))"
    }

    /// Persists the composite plus per-kind snapshots so the next launch — and
    /// sibling ScreenerViewModels — boot from disk. No-op when persistence is
    /// disabled (onDemand schedule).
    private func persist(_ results: [(BandarScreenerKind, Result<KindFetch, Error>)]) async {
        guard let snapshots else { return }
        let stamp = lastFetchedAt ?? Date()
        await snapshots.saveWatchlist(WatchlistSnapshot(rows: rows, fetchedAt: stamp))
        for (kind, result) in results {
            guard case .success(let fetched) = result else { continue }
            await snapshots.saveScreener(ScreenerSnapshot(
                templateID: kind.templateID,
                config: fetched.config,
                rows: fetched.rows,
                total: nil,
                fetchedAt: stamp))
        }
    }

    /// Surfaces a per-kind error banner (cancellation is treated as internal
    /// lifecycle noise and skipped).
    private func surfaceFailures(_ results: [(BandarScreenerKind, Result<KindFetch, Error>)]) {
        var failed: [(BandarScreenerKind, Error)] = []
        for (kind, result) in results {
            guard case .failure(let err) = result else { continue }
            if err is CancellationError {
                watchlistLog.info("\(kind.displayName, privacy: .public): cancelled mid-sweep")
                continue
            }
            watchlistLog.error("\(kind.displayName, privacy: .public) FAILED: \(String(reflecting: err), privacy: .public)")
            failed.append((kind, err))
        }
        if !failed.isEmpty {
            let parts = failed.map { "\($0.0.displayName) (\(String(describing: $0.1)))" }
            error = "Couldn't load: \(parts.joined(separator: " · "))"
        }
    }

    private nonisolated func isCancellation(_ res: Result<KindFetch, Error>) -> Bool {
        if case .failure(let err) = res, err is CancellationError { return true }
        return false
    }

    /// Bundled per-kind fetch result — both the screener's config (sequence,
    /// columns, etc.) and all collected rows. The config is required so the
    /// per-tab ScreenerViewModel can render correct columns when bootstrapping
    /// from a watchlist-seeded snapshot.
    private struct KindFetch {
        let config: ScreenerConfig
        let rows: [ScreenerRow]
    }

    /// Pulls every page for `kind`: page 1 via template-load (GET), pages 2+ via run (POST).
    /// Every outgoing request is preceded by `throttle()` so requests are spaced
    /// 1000–1500ms apart (the first request in a bootstrap pays no gap).
    /// Stops when a page is partial, total is reached, or the safety cap fires.
    private func fetchAll(_ kind: BandarScreenerKind) async -> Result<KindFetch, Error> {
        watchlistLog.info("\(kind.displayName, privacy: .public): GET templates/\(kind.templateID, privacy: .public)")
        do {
            try await throttle()
            let initial = try await templates.load(templateID: kind.templateID)
            var all = initial.page.rows
            let limit = initial.config.limit
            let total = initial.page.total
            watchlistLog.info("\(kind.displayName, privacy: .public): page 1 → \(all.count) rows (limit=\(limit), total=\(total ?? -1))")

            if all.count < limit { return .success(KindFetch(config: initial.config, rows: all)) }
            if let total, all.count >= total { return .success(KindFetch(config: initial.config, rows: all)) }

            var page = 2
            while page <= safetyCap {
                try await throttle()
                let next = try await screener.run(initial.config, page: page)
                watchlistLog.info("\(kind.displayName, privacy: .public): page \(page) → \(next.rows.count) rows")
                all.append(contentsOf: next.rows)
                if next.rows.isEmpty || next.rows.count < limit { break }
                if let total, all.count >= total { break }
                page += 1
            }
            return .success(KindFetch(config: initial.config, rows: all))
        } catch {
            watchlistLog.error("\(kind.displayName, privacy: .public): threw \(String(reflecting: error), privacy: .public)")
            return .failure(error)
        }
    }

    /// Sleeps a randomized 1000–1500ms before each outgoing screener request,
    /// except for the very first one in this bootstrap. Stockbit has shown signs
    /// of penalising parallel bursts, and the four-screener Watchlist used to fire
    /// 4 GETs at t=0 plus immediate POSTs — easy to flag.
    private func throttle() async throws {
        if hasIssuedFirstRequest {
            try await sleeper(UInt64.random(in: throttleRange))
        }
        hasIssuedFirstRequest = true
    }
}
