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

    /// One-shot bootstrap. No-ops on repeat so re-appearing views don't re-fire
    /// the paywall counter or the 3 template loads.
    func autoRunIfNeeded() async {
        guard !didAutoRun else { return }
        didAutoRun = true
        await bootstrap()
    }

    func refresh() async {
        didAutoRun = false
        await autoRunIfNeeded()
    }

    private func bootstrap() async {
        rows = []
        error = nil
        paywallMessage = nil
        hasIssuedFirstRequest = false  // fresh throttle window per bootstrap
        isLoading = true
        defer { isLoading = false }

        let eligibility = await paywall.check(.screener)
        if !eligibility.eligible {
            paywallMessage = eligibility.message ?? "Screener access is limited on your plan."
        }
        // One increment for the entire watchlist — not 4.
        await paywall.increment(.screener)

        // Serial fan-out: every screener (and every page within each screener) is
        // separated by a randomized 1000–1500ms gap via `throttle()`. Stops Stockbit
        // from seeing a 4-way parallel burst at t=0.
        let order: [BandarScreenerKind] = [.accumulating, .aboveMA20, .shiftToday, .accumDistPositive, .foreignFlow1M]
        var results: [(BandarScreenerKind, Result<[ScreenerRow], Error>)] = []
        var cancelled = false
        for kind in order {
            let res = await fetchAll(kind)
            results.append((kind, res))
            // If the surrounding Task was cancelled (SwiftUI `.task` tear-down on
            // tab switch is the common case), every subsequent throttle() will
            // throw CancellationError. Stop iterating instead of marching through
            // four guaranteed-failure rounds.
            if Task.isCancelled || isCancellation(res) { cancelled = true; break }
        }

        var byID: [String: WatchlistRow] = [:]
        var failed: [(BandarScreenerKind, Error)] = []

        for (kind, result) in results {
            switch result {
            case .success(let fetched):
                watchlistLog.info("\(kind.displayName, privacy: .public): \(fetched.count) rows")
                for row in fetched {
                    if var existing = byID[row.symbol] {
                        existing.matchedScreeners.insert(kind)
                        byID[row.symbol] = existing
                    } else {
                        byID[row.symbol] = WatchlistRow(
                            symbol: row.symbol,
                            name: row.name,
                            matchedScreeners: [kind]
                        )
                    }
                }
            case .failure(let err):
                // CancellationError = user navigated away mid-bootstrap. Don't
                // turn that into a red banner — it's internal lifecycle noise.
                if err is CancellationError {
                    watchlistLog.info("\(kind.displayName, privacy: .public): cancelled mid-bootstrap")
                    continue
                }
                watchlistLog.error("\(kind.displayName, privacy: .public) FAILED: \(String(reflecting: err), privacy: .public)")
                failed.append((kind, err))
            }
        }

        rows = byID.values.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.symbol < b.symbol
        }

        if cancelled {
            // Allow the next view-appearance to re-bootstrap from scratch so the
            // missing kinds get a fresh attempt. Partial rows remain visible until
            // the next run replaces them.
            didAutoRun = false
        }

        if !failed.isEmpty {
            // Surface the underlying error per kind so the banner is actionable.
            let parts = failed.map { "\($0.0.displayName) (\(String(describing: $0.1)))" }
            error = "Couldn't load: \(parts.joined(separator: " · "))"
        }
    }

    private nonisolated func isCancellation(_ res: Result<[ScreenerRow], Error>) -> Bool {
        if case .failure(let err) = res, err is CancellationError { return true }
        return false
    }

    /// Pulls every page for `kind`: page 1 via template-load (GET), pages 2+ via run (POST).
    /// Every outgoing request is preceded by `throttle()` so requests are spaced
    /// 1000–1500ms apart (the first request in a bootstrap pays no gap).
    /// Stops when a page is partial, total is reached, or the safety cap fires.
    private func fetchAll(_ kind: BandarScreenerKind) async -> Result<[ScreenerRow], Error> {
        watchlistLog.info("\(kind.displayName, privacy: .public): GET templates/\(kind.templateID, privacy: .public)")
        do {
            try await throttle()
            let initial = try await templates.load(templateID: kind.templateID)
            var all = initial.page.rows
            let limit = initial.config.limit
            let total = initial.page.total
            watchlistLog.info("\(kind.displayName, privacy: .public): page 1 → \(all.count) rows (limit=\(limit), total=\(total ?? -1))")

            if all.count < limit { return .success(all) }
            if let total, all.count >= total { return .success(all) }

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
            return .success(all)
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
