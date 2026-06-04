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
    /// Live stock-code search term (bound to the toolbar search field). Empty =
    /// no filtering. The watchlist isn't paginated, so the filter is always
    /// complete — no page exhaust needed.
    var searchText: String = ""
    var paywallMessage: String?
    /// Set when a liquidity veto gate could NOT be enforced this run (its cache was
    /// stale/missing, or its fetch failed) — so the "ILLIQUID" flags reflect only the
    /// gates we could actually evaluate. Surfaced as a soft warning in the status bar.
    var vetoNotice: String?
    /// Wall-clock when the currently-displayed composite landed. Drives the
    /// toolbar's "as of HH:mm" badge.
    var lastFetchedAt: Date?
    /// Number of screeners whose fetch has completed in the current sweep. Paired
    /// with `totalScreenerCount`, it drives the "Loading… x/y" label beside the
    /// spinner so the user sees the throttled sweep advance one screener at a time.
    var loadedScreenerCount: Int = 0

    /// Total screeners fetched per sweep. Derived from the fan-out order rather
    /// than hardcoded so it can't drift when the kind list grows.
    var totalScreenerCount: Int { Self.fanOutOrder.count }

    private var didAutoRun: Bool = false
    private let paywall: any PaywallServicing
    private let templates: any ScreenerTemplateServicing
    private let screener: any ScreenerServicing
    private let safetyCap: Int
    private let throttleRange: ClosedRange<UInt64>
    private let sleeper: Sleeper
    /// Becomes true after the first request fires within a single `bootstrap()` run.
    /// Reset on every fresh bootstrap so a manual refresh doesn't pay the initial gap.
    private var hasIssuedFirstRequest: Bool = false

    init(paywall: any PaywallServicing,
         templates: any ScreenerTemplateServicing,
         screener: any ScreenerServicing,
         safetyCap: Int = 20,
         throttleRange: ClosedRange<UInt64> = 1_000_000_000...1_500_000_000,
         sleeper: @escaping Sleeper = { try await Task.sleep(nanoseconds: $0) }) {
        self.paywall = paywall
        self.templates = templates
        self.screener = screener
        self.safetyCap = safetyCap
        self.throttleRange = throttleRange
        self.sleeper = sleeper
    }

    /// Rows after applying the stock-code search. The view renders these instead
    /// of `rows`; an empty `searchText` returns everything unchanged.
    var visibleRows: [WatchlistRow] {
        rows.filteredBySymbol(searchText)
    }

    /// One-shot bootstrap — fetches live on first reveal. No-ops on repeat so
    /// re-appearing views don't re-fire the paywall counter or the template loads.
    func autoRunIfNeeded() async {
        guard !didAutoRun else { return }
        didAutoRun = true
        await refresh()
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

    /// User-initiated refresh — the live throttled fan-out across every screener,
    /// composed in memory. This is the only fetch path: the watchlist always reads
    /// live (on first reveal and on the Refresh button), never from a cache.
    ///
    /// Each screener's rows are folded into the running composite and `rows` is
    /// republished the moment that screener lands — so the table fills in
    /// progressively across the ~1000–1500ms-spaced sweep instead of staying empty
    /// until all 20 requests finish.
    func refresh() async {
        rows = []
        error = nil
        paywallMessage = nil
        loadedScreenerCount = 0
        isLoading = true
        defer { isLoading = false }

        hasIssuedFirstRequest = false  // fresh throttle window per sweep

        let eligibility = await paywall.check(.screener)
        if !eligibility.eligible {
            paywallMessage = eligibility.message ?? "Screener access is limited on your plan."
        }
        // One increment for the entire sweep — not one per screener.
        await paywall.increment(.screener)

        var byID: [String: WatchlistRow] = [:]
        // A veto gate is only enforceable if it was freshly fetched (succeeded)
        // this run; a failed gate must not flag every row ILLIQUID.
        var evaluableVeto: Set<BandarScreenerKind> = []
        var perKind: [(BandarScreenerKind, Result<KindFetch, Error>)] = []
        var cancelled = false

        for kind in Self.fanOutOrder {
            let result = await fetchAll(kind)
            perKind.append((kind, result))
            // Count every completed screener (success or failure) so the "x/y"
            // progress reflects the throttled sweep advancing, not just hits.
            loadedScreenerCount += 1

            if case .success(let fetched) = result {
                watchlistLog.info("\(kind.displayName, privacy: .public): \(fetched.rows.count) rows")
                if kind.isVeto { evaluableVeto.insert(kind) }
                for row in fetched.rows { Self.union(&byID, row: row, kind: kind) }
                // Publish progressively — the table updates as each screener lands.
                rows = Self.ranked(byID.values, evaluableVeto: evaluableVeto)
            }

            // If the surrounding Task was cancelled (SwiftUI `.task` tear-down on
            // tab switch is the common case), every subsequent throttle() will
            // throw CancellationError. Stop iterating instead of marching through
            // remaining guaranteed-failure rounds.
            if Task.isCancelled || isCancellation(result) { cancelled = true; break }
        }

        vetoNotice = Self.vetoNotice(skipped: BandarScreenerKind.vetoKinds.subtracting(evaluableVeto))
        lastFetchedAt = Date()
        if cancelled { didAutoRun = false }
        surfaceFailures(perKind)
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
