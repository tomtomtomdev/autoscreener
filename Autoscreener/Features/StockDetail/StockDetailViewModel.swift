import Foundation
import Observation

@MainActor
@Observable
final class StockDetailViewModel {
    let ticker: StockTicker
    var report: FinancialReportType = .income
    var basis: FinancialPeriodBasis = .annual

    private(set) var statement: FinancialStatement?
    /// Path ids of the currently-expanded account nodes.
    var expanded: Set<String> = []
    var isLoading: Bool = false
    var error: String?
    var paywallMessage: String?

    private let service: any FinancialStatementServicing

    init(ticker: StockTicker, service: any FinancialStatementServicing) {
        self.ticker = ticker
        self.service = service
    }

    /// Visible, render-ready rows for the current statement and expansion state.
    var rows: [FinancialRow] {
        statement?.flattened(expanded: expanded) ?? []
    }

    func load() async {
        isLoading = true
        error = nil
        paywallMessage = nil
        defer { isLoading = false }
        do {
            let result = try await service.load(symbol: ticker.symbol, report: report, basis: basis)
            statement = result
            // Honor the server's curated expansion when it offers one; otherwise
            // (e.g. the income statement marks nothing expanded) open everything so
            // the statement isn't a wall of empty header rows.
            let defaults = result.defaultExpandedIDs
            expanded = defaults.isEmpty ? result.allExpandableIDs : defaults
        } catch FinancialStatementError.unauthorized {
            statement = nil
            error = "Session expired. Please sign in again."
        } catch FinancialStatementError.paywall {
            statement = nil
            paywallMessage = "Financial data isn't available on your plan."
        } catch FinancialStatementError.malformedResponse {
            statement = nil
            error = "Couldn't read the financial statement."
        } catch FinancialStatementError.network(let detail) {
            statement = nil
            error = "Network error: \(detail)"
        } catch let err {
            statement = nil
            error = err.localizedDescription
        }
    }

    func toggle(_ rowID: String) {
        if expanded.contains(rowID) {
            expanded.remove(rowID)
        } else {
            expanded.insert(rowID)
        }
    }
}
