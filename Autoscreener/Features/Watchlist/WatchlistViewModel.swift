import Foundation
import Observation
import OSLog
import SwiftUI

private let watchlistLog = Logger(subsystem: "com.tom.tom.tom.Autoscreener", category: "watchlist")

@MainActor
@Observable
final class WatchlistViewModel {
    var rows: [WatchlistRow] = []
    var isLoading: Bool = false
    var error: String?
    var paywallMessage: String?

    private var didAutoRun: Bool = false
    private let paywall: any PaywallServicing
    private let templates: any ScreenerTemplateServicing
    private let screener: any ScreenerServicing
    private let safetyCap: Int

    init(paywall: any PaywallServicing,
         templates: any ScreenerTemplateServicing,
         screener: any ScreenerServicing,
         safetyCap: Int = 20) {
        self.paywall = paywall
        self.templates = templates
        self.screener = screener
        self.safetyCap = safetyCap
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
        isLoading = true
        defer { isLoading = false }

        let eligibility = await paywall.check(.screener)
        if !eligibility.eligible {
            paywallMessage = eligibility.message ?? "Screener access is limited on your plan."
        }
        // One increment for the entire watchlist — not 3.
        await paywall.increment(.screener)

        async let accFetch   = fetchAll(.accumulating)
        async let aboveFetch = fetchAll(.aboveMA20)
        async let shiftFetch = fetchAll(.shiftToday)
        let accRes   = await accFetch
        let aboveRes = await aboveFetch
        let shiftRes = await shiftFetch

        var byID: [String: WatchlistRow] = [:]
        var failed: [(BandarScreenerKind, Error)] = []

        for (kind, result) in [(BandarScreenerKind.accumulating, accRes),
                               (.aboveMA20, aboveRes),
                               (.shiftToday, shiftRes)] {
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
                watchlistLog.error("\(kind.displayName, privacy: .public) FAILED: \(String(reflecting: err), privacy: .public)")
                failed.append((kind, err))
            }
        }

        rows = byID.values.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.symbol < b.symbol
        }

        if !failed.isEmpty {
            // Surface the underlying error per kind so the banner is actionable.
            let parts = failed.map { "\($0.0.displayName) (\(String(describing: $0.1)))" }
            error = "Couldn't load: \(parts.joined(separator: " · "))"
        }
    }

    /// Pulls every page for `kind`: page 1 via template-load (GET), pages 2+ via run (POST).
    /// Stops when a page is partial, total is reached, or the safety cap fires.
    private func fetchAll(_ kind: BandarScreenerKind) async -> Result<[ScreenerRow], Error> {
        watchlistLog.info("\(kind.displayName, privacy: .public): GET templates/\(kind.templateID, privacy: .public)")
        do {
            let initial = try await templates.load(templateID: kind.templateID)
            var all = initial.page.rows
            let limit = initial.config.limit
            let total = initial.page.total
            watchlistLog.info("\(kind.displayName, privacy: .public): page 1 → \(all.count) rows (limit=\(limit), total=\(total ?? -1))")

            if all.count < limit { return .success(all) }
            if let total, all.count >= total { return .success(all) }

            var page = 2
            while page <= safetyCap {
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
}
