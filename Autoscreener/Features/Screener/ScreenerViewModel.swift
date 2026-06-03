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

    /// Live stock-code search term (bound to the toolbar search field on the
    /// screeners that opt into search). Empty = no filtering.
    var searchText: String = ""

    /// Wall-clock when the currently-displayed rows landed (from a fresh fetch or a
    /// persisted snapshot). Surfaced to the toolbar as an "as of HH:mm" badge.
    var lastFetchedAt: Date?

    private(set) var currentPage: Int = 0
    private var didAutoRun: Bool = false
    private var serverSaysDone: Bool = false  // set when last fetch returned 0 rows or < limit rows
    private var isExhaustingPages: Bool = false  // guards re-entrant loadAllForSearch
    private let service: any ScreenerServicing
    private let paywall: (any PaywallServicing)?
    private let templates: (any ScreenerTemplateServicing)?
    private let snapshots: (any ScreenerSnapshotStoring)?
    let templateID: String

    init(service: any ScreenerServicing,
         paywall: (any PaywallServicing)? = nil,
         templates: (any ScreenerTemplateServicing)? = nil,
         snapshots: (any ScreenerSnapshotStoring)? = nil,
         templateID: String = "6676213") {
        self.service = service
        self.paywall = paywall
        self.templates = templates
        self.snapshots = snapshots
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

    /// Rows after applying the stock-code search. The view renders these instead
    /// of `rows`; an empty `searchText` returns everything unchanged.
    var visibleRows: [ScreenerRow] {
        rows.filteredBySymbol(searchText)
    }

    /// One-shot bootstrap — runs once per ViewModel lifetime (per screener tab).
    /// No-ops on subsequent calls so re-appearing views don't re-trigger paywall counters.
    ///
    /// Snapshot path (when a persisted snapshot is available):
    ///   1. Render snapshot rows immediately so the tab is never blank on first reveal.
    ///   2. Only re-fetch when there's no snapshot at all (a true first run for this
    ///      template). Periodic catch-up fetches are the `ScreenerScheduler`'s job —
    ///      not the per-tab `.task` modifier — to avoid every tab independently
    ///      racing to refresh.
    func autoRunIfNeeded() async {
        guard !didAutoRun else { return }
        didAutoRun = true
        let snapshotLoaded = await loadSnapshotIntoView()
        if snapshotLoaded { return }
        await bootstrap(templateID: templateID)
    }

    /// User-initiated refresh — re-runs the full bootstrap path and writes a fresh
    /// snapshot to disk (when persistence is enabled).
    func refresh() async {
        await bootstrap(templateID: templateID)
    }

    @discardableResult
    private func loadSnapshotIntoView() async -> Bool {
        guard let snapshots, let snapshot = await snapshots.loadScreener(templateID: templateID) else {
            return false
        }
        self.config = snapshot.config
        self.rows = snapshot.rows
        self.total = snapshot.total
        self.lastFetchedAt = snapshot.fetchedAt
        // Treat a restored snapshot as a single completed page — `loadMore` is
        // disabled until the user fires a fresh refresh.
        self.currentPage = 1
        self.serverSaysDone = true
        applyTemplateSort()
        return true
    }

    private func persistSnapshotIfPossible() async {
        guard let snapshots else { return }
        let snap = ScreenerSnapshot(
            templateID: templateID,
            config: config,
            rows: rows,
            total: total,
            fetchedAt: lastFetchedAt ?? Date())
        await snapshots.saveScreener(snap)
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
                self.lastFetchedAt = Date()
                updateServerSaysDone(returnedRowCount: initial.page.rows.count)
                applyTemplateSort()
                isLoading = false
                await persistSnapshotIfPossible()
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

    /// Eagerly pulls every remaining page so a stock-code search isn't fooled by
    /// lazy pagination — a symbol on a not-yet-scrolled page must still surface.
    /// Driven by the view when the search field transitions from empty to filled.
    /// Re-entrant calls (rapid keystrokes) no-op via `isExhaustingPages`; once all
    /// pages are in, `hasMore` is false and the loop ends immediately.
    func loadAllForSearch() async {
        guard !isExhaustingPages else { return }
        isExhaustingPages = true
        defer { isExhaustingPages = false }
        while hasMore && !Task.isCancelled {
            await loadMore()
        }
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
            lastFetchedAt = Date()
            updateServerSaysDone(returnedRowCount: result.rows.count)
            await persistSnapshotIfPossible()
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
