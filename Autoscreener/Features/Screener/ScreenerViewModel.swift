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
    private var serverSaysDone: Bool = false  // set when last fetch returned 0 rows or < limit rows
    private let service: any ScreenerServicing
    private let paywall: (any PaywallServicing)?
    private let templates: (any ScreenerTemplateServicing)?
    let templateID: String

    init(service: any ScreenerServicing,
         paywall: (any PaywallServicing)? = nil,
         templates: (any ScreenerTemplateServicing)? = nil,
         templateID: String = "6676213") {
        self.service = service
        self.paywall = paywall
        self.templates = templates
        self.templateID = templateID
    }

    /// True only if we believe another page exists. False once the server gave us:
    ///  - an empty page, OR
    ///  - a partial page (< config.limit rows), OR
    ///  - total reached.
    var hasMore: Bool {
        if serverSaysDone { return false }
        if rows.isEmpty { return false }
        if let total { return rows.count < total }
        return rows.count % config.limit == 0
    }

    /// One-shot bootstrap — runs once per ViewModel lifetime (per screener tab).
    /// No-ops on subsequent calls so re-appearing views don't re-trigger paywall counters.
    func autoRunIfNeeded() async {
        guard !didAutoRun else { return }
        didAutoRun = true
        await bootstrap(templateID: templateID)
    }

    func refresh() async {
        await bootstrap(templateID: templateID)
    }

    private func bootstrap(templateID: String) async {
        paywallMessage = nil
        rows = []
        total = nil
        currentPage = 0
        serverSaysDone = false
        error = nil

        if let paywall {
            let eligibility = await paywall.check(.screener)
            if !eligibility.eligible {
                paywallMessage = eligibility.message ?? "Screener access is limited on your plan."
            }
            await paywall.increment(.screener)
        }
        // The GET /screener/templates/{id} response carries BOTH the template config
        // AND page 1 of rows — so we land the first page here without a POST.
        // Subsequent pages go through POST /screener/templates with page ≥ 2.
        if let templates {
            isLoading = true
            do {
                let initial = try await templates.load(templateID: templateID)
                self.config = initial.config
                self.rows = initial.page.rows
                self.total = initial.page.total
                self.currentPage = 1
                updateServerSaysDone(returnedRowCount: initial.page.rows.count)
                applyTemplateSort()
                isLoading = false
                return
            } catch ScreenerError.unauthorized {
                isLoading = false
                error = "Session expired. Please sign in again."
                return
            } catch {
                // No silent POST fallback: the canned ScreenerConfig() defaults are
                // bandar-accumulating's filters/screenerID, so falling back for any
                // other templateID would silently surface bandar-accumulating's rows.
                isLoading = false
                self.error = "Couldn't load screener configuration."
                return
            }
        }
        await run()
    }

    /// Explicit re-run via the POST endpoint with page=1. Used as a fallback when the
    /// GET template+page1 path failed, or when something other than the bootstrap is
    /// driving the screener (e.g. a future filter editor).
    func run() async {
        rows = []
        currentPage = 0
        serverSaysDone = false
        await load(page: 1)
        applyTemplateSort()
    }

    func loadMore() async {
        guard !isLoading, hasMore else { return }
        await load(page: currentPage + 1)
        applyTemplateSort()
    }

    /// Triggered by ScreenerView when the last row scrolls into view. Idempotent —
    /// re-firing while we're already loading is a no-op, and we stop once the server
    /// signals it's out of pages.
    func rowDidAppear(at index: Int) async {
        guard index >= rows.count - 1, hasMore, !isLoading else { return }
        await loadMore()
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
            updateServerSaysDone(returnedRowCount: result.rows.count)
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

    private func updateServerSaysDone(returnedRowCount: Int) {
        if returnedRowCount == 0 {
            serverSaysDone = true
            return
        }
        // Trust server-supplied `total` when present — it's authoritative.
        if let total {
            if rows.count >= total { serverSaysDone = true }
            return
        }
        // No total → infer end-of-list from a partial page.
        if returnedRowCount < config.limit { serverSaysDone = true }
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
