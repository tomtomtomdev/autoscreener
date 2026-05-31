import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class ScreenerViewModel {
    var config: ScreenerConfig = ScreenerConfig()
    var rows: [ScreenerRow] = []
    var total: Int?
    var isLoading: Bool = false
    var error: String?
    var paywallMessage: String?
    var sort: [KeyPathComparator<ScreenerRow>] = []

    private(set) var currentPage: Int = 0
    private var didAutoRun: Bool = false
    private let service: any ScreenerServicing
    private let paywall: (any PaywallServicing)?
    private let templates: (any ScreenerTemplateServicing)?

    init(service: any ScreenerServicing,
         paywall: (any PaywallServicing)? = nil,
         templates: (any ScreenerTemplateServicing)? = nil) {
        self.service = service
        self.paywall = paywall
        self.templates = templates
    }

    var hasMore: Bool {
        guard let total else { return !rows.isEmpty && rows.count % config.limit == 0 }
        return rows.count < total
    }

    /// One-shot bootstrap intended for app launch — auto-runs the bandar-accumulating
    /// screener after a paywall eligibility check + counter increment + template load.
    /// No-ops on subsequent calls so re-appearing views don't re-trigger paywall counters.
    func autoRunIfNeeded(templateID: String = "6676213") async {
        guard !didAutoRun else { return }
        didAutoRun = true
        await bootstrap(templateID: templateID)
    }

    func refresh(templateID: String = "6676213") async {
        await bootstrap(templateID: templateID)
    }

    private func bootstrap(templateID: String) async {
        paywallMessage = nil
        // Eligibility — surface a banner, but never hard-block; the user might still hit quota.
        if let paywall {
            let eligibility = await paywall.check(.screener)
            if !eligibility.eligible {
                paywallMessage = eligibility.message ?? "Screener access is limited on your plan."
            }
            await paywall.increment(.screener)
        }
        // Load the saved template so the view doesn't hardcode metric IDs / order.
        // Fall back to the in-code ScreenerConfig if the load fails.
        if let templates, let loaded = try? await templates.load(templateID: templateID) {
            self.config = loaded
        }
        await run()
    }

    func run() async {
        rows = []
        currentPage = 0
        await load(page: 1)
        // Reset sort to template's preferred order — first metric, descending by default.
        applyTemplateSort()
    }

    func loadMore() async {
        guard !isLoading, hasMore else { return }
        await load(page: currentPage + 1)
        applyTemplateSort()
    }

    private func load(page: Int) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let result = try await service.run(config, page: page)
            rows.append(contentsOf: result.rows)
            total = result.total
            currentPage = page
        } catch ScreenerError.unauthorized {
            error = "Session expired. Please sign in again."
        } catch ScreenerError.paywall {
            error = "Screener access is not available on your plan."
        } catch ScreenerError.malformedResponse {
            error = "Couldn't read screener response."
        } catch ScreenerError.network(let detail) {
            error = "Network error: \(detail)"
        } catch let err {
            error = err.localizedDescription
        }
    }

    /// Stockbit's `ordercol` is 1-based; columns 1 = symbol, 2 = first metric, etc. The canned
    /// template defaults to `ordercol=2, ordertype=desc` — sort by the first metric descending.
    private func applyTemplateSort() {
        let ascending = config.orderType.lowercased() == "asc"
        // `ordercol` ≥ 2 → metric column at index (ordercol - 2). Anything else → first metric.
        let metricIndex = max(0, config.orderColumn - 2)
        rows.sort { a, b in
            ScreenerRow.sortNilLast(a.value(at: metricIndex), b.value(at: metricIndex), ascending: ascending)
        }
        // Clear the Table sortOrder so no header chevron is shown after a reset run.
        sort = []
    }
}
