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
    var sort: [KeyPathComparator<ScreenerRow>] = [.init(\.symbol, order: .forward)]

    private(set) var currentPage: Int = 0
    private let service: any ScreenerServicing

    init(service: any ScreenerServicing) {
        self.service = service
    }

    var hasMore: Bool {
        guard let total else { return !rows.isEmpty && rows.count % config.limit == 0 }
        return rows.count < total
    }

    func run() async {
        rows = []
        currentPage = 0
        await load(page: 1)
    }

    func loadMore() async {
        guard !isLoading, hasMore else { return }
        await load(page: currentPage + 1)
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
}
