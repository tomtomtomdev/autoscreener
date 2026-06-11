import Foundation
import Observation

/// Loads price snapshots for every Markets row — the composite, indices, IDX-IC
/// sectors, commodities, and currencies. Stockbit's `emitten/{symbol}/info`
/// returns the same price-snapshot shape for indices and stocks as it does for
/// commodities, so one fan-out covers the whole list. Tolerates per-symbol
/// failure: a symbol that errors (e.g. paywalled, or an index that doesn't
/// resolve) is simply absent from `quotes` rather than failing the whole screen.
/// A top-level `error` is surfaced only when *every* symbol fails.
@MainActor
@Observable
final class MarketQuotesViewModel {
    let symbols: [MarketSymbol]
    private(set) var quotes: [String: CommodityQuote] = [:]
    var isLoading = false
    var error: String?

    private let service: any CommodityPriceServicing
    private var hasLoaded = false

    init(symbols: [MarketSymbol] = MarketCatalog.all,
         service: any CommodityPriceServicing = AppDependencies.shared.commodityPriceService) {
        self.symbols = symbols
        self.service = service
    }

    func load(force: Bool = false) async {
        if !force, hasLoaded { return }
        guard !symbols.isEmpty else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }

        let service = self.service
        let fetched = await withTaskGroup(of: (String, CommodityQuote?).self) { group in
            for item in symbols {
                group.addTask { (item.symbol, try? await service.quote(symbol: item.symbol)) }
            }
            var acc: [String: CommodityQuote] = [:]
            for await (symbol, quote) in group where quote != nil {
                acc[symbol] = quote
            }
            return acc
        }

        if fetched.isEmpty {
            // Total failure — keep any previously loaded quotes, surface an error,
            // and leave `hasLoaded` false so the next appearance retries.
            error = "Couldn't load market prices."
        } else {
            // Merge so a symbol that failed this round keeps its prior value.
            for (symbol, quote) in fetched { quotes[symbol] = quote }
            hasLoaded = true
        }
    }
}
