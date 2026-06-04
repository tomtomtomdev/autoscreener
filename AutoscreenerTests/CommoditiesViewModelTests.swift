import Foundation
import Testing
@testable import Autoscreener

final class FakeCommodityPriceService: CommodityPriceServicing, @unchecked Sendable {
    var failingSymbols: Set<String> = []
    var failAll = false

    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }

    func quote(symbol: String) async throws -> CommodityQuote {
        lock.lock(); _calls.append(symbol); lock.unlock()
        if failAll || failingSymbols.contains(symbol) {
            throw CommodityPriceError.network("boom")
        }
        return CommodityQuote(
            symbol: symbol, name: symbol, price: 100, previousClose: 99,
            change: 1, changePercent: 1.0, volume: 10, formattedPrice: "100", asOf: "now")
    }
}

private func symbol(_ s: String) -> MarketSymbol {
    MarketSymbol(symbol: s, name: s, group: .commodity)
}

private let threeSymbols = [symbol("OIL"), symbol("XAU"), symbol("CPO")]

@MainActor
@Suite struct CommoditiesViewModelTests {
    @Test func loadPopulatesQuotesForEverySymbol() async {
        let svc = FakeCommodityPriceService()
        let vm = CommoditiesViewModel(symbols: threeSymbols, service: svc)

        await vm.load()

        #expect(vm.quotes.count == 3)
        #expect(vm.error == nil)
        #expect(Set(svc.calls) == ["OIL", "XAU", "CPO"])
    }

    @Test func partialFailureKeepsOtherQuotes() async {
        let svc = FakeCommodityPriceService()
        svc.failingSymbols = ["OIL"]
        let vm = CommoditiesViewModel(symbols: threeSymbols, service: svc)

        await vm.load()

        #expect(vm.quotes["OIL"] == nil)
        #expect(vm.quotes["XAU"] != nil)
        #expect(vm.quotes["CPO"] != nil)
        #expect(vm.error == nil)            // partial failure isn't a screen-level error
    }

    @Test func totalFailureSetsError() async {
        let svc = FakeCommodityPriceService()
        svc.failAll = true
        let vm = CommoditiesViewModel(symbols: threeSymbols, service: svc)

        await vm.load()

        #expect(vm.quotes.isEmpty)
        #expect(vm.error != nil)
    }

    @Test func reloadIsSkippedWhenAlreadyLoadedAndNotForced() async {
        let svc = FakeCommodityPriceService()
        let vm = CommoditiesViewModel(symbols: threeSymbols, service: svc)

        await vm.load()
        await vm.load()                     // no force, already loaded

        #expect(svc.calls.count == 3)       // one round only
    }

    @Test func forceReloadRefetches() async {
        let svc = FakeCommodityPriceService()
        let vm = CommoditiesViewModel(symbols: threeSymbols, service: svc)

        await vm.load()
        await vm.load(force: true)

        #expect(svc.calls.count == 6)       // two rounds
    }

    @Test func totalFailureThenRetryOnNextLoad() async {
        let svc = FakeCommodityPriceService()
        svc.failAll = true
        let vm = CommoditiesViewModel(symbols: threeSymbols, service: svc)

        await vm.load()                     // total failure leaves hasLoaded false
        svc.failAll = false
        await vm.load()                     // non-forced retry should re-run

        #expect(vm.error == nil)
        #expect(vm.quotes.count == 3)
    }
}
