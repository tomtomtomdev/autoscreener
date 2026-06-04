import Foundation
import Testing
@testable import Autoscreener

// A stub that records calls and returns a canned series or a chosen error.
private final class StubChartServicing: ChartServicing, @unchecked Sendable {
    private(set) var calls: [(symbol: String, timeframe: ChartTimeframe)] = []
    var result: Result<PriceSeries, Error>

    init(result: Result<PriceSeries, Error>) { self.result = result }

    func candles(symbol: String, timeframe: ChartTimeframe, chartType: ChartType) async throws -> PriceSeries {
        calls.append((symbol, timeframe))
        return try result.get()
    }

    static func series(symbol: String = "CUAN", timeframe: ChartTimeframe = .oneYear) -> PriceSeries {
        PriceSeries(
            symbol: symbol, timeframe: timeframe, previousClose: 1_000,
            candles: [
                PriceCandle(date: Date(timeIntervalSince1970: 1_748_000_000), open: 1_000, high: 1_020, low: 990, close: 1_010, volume: 5_000),
            ])
    }
}

@MainActor
@Suite struct OHLCVChartViewModelTests {
    @Test func loadPopulatesSeries() async {
        let stub = StubChartServicing(result: .success(StubChartServicing.series()))
        let vm = OHLCVChartViewModel(symbol: "CUAN", name: "Petrindo", service: stub)

        await vm.load()

        #expect(vm.series?.candles.count == 1)
        #expect(vm.error == nil)
        #expect(stub.calls.map(\.symbol) == ["CUAN"])
        #expect(stub.calls.first?.timeframe == .oneYear)   // default
    }

    @Test func mapsUnauthorizedToSessionMessage() async {
        let stub = StubChartServicing(result: .failure(ChartError.unauthorized))
        let vm = OHLCVChartViewModel(symbol: "CUAN", name: "Petrindo", service: stub)

        await vm.load()

        #expect(vm.series == nil)
        #expect(vm.error == "Session expired. Please sign in again.")
    }

    @Test func mapsPaywallAndNetworkErrors() async {
        let paywallVM = OHLCVChartViewModel(symbol: "X", name: "X", service: StubChartServicing(result: .failure(ChartError.paywall)))
        await paywallVM.load()
        #expect(paywallVM.error == "Chart data isn't available on your plan.")

        let netVM = OHLCVChartViewModel(symbol: "X", name: "X", service: StubChartServicing(result: .failure(ChartError.network("timeout"))))
        await netVM.load()
        #expect(netVM.error == "Couldn't load chart (timeout).")
    }

    @Test func skipsReloadWhenSameTimeframeAlreadyLoaded() async {
        let stub = StubChartServicing(result: .success(StubChartServicing.series()))
        let vm = OHLCVChartViewModel(symbol: "CUAN", name: "Petrindo", service: stub)

        await vm.load()
        await vm.load()   // no-op: same timeframe, already have data

        #expect(stub.calls.count == 1)
    }

    @Test func changingTimeframeForcesReload() async {
        let stub = StubChartServicing(result: .success(StubChartServicing.series()))
        let vm = OHLCVChartViewModel(symbol: "CUAN", name: "Petrindo", service: stub)

        await vm.load()
        vm.timeframe = .today
        await vm.load(force: true)

        #expect(stub.calls.count == 2)
        #expect(stub.calls.last?.timeframe == .today)
    }
}
