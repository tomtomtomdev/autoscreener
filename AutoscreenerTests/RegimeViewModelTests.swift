import Foundation
import Testing
@testable import Autoscreener

@Suite @MainActor struct RegimeViewModelTests {
    private struct Boom: Error {}
    private struct ThrowingSnapshot: RegimeSnapshotProviding {
        func snapshot() async throws -> RegimeSnapshot { throw Boom() }
    }
    private struct ThrowingFlow: AggregateForeignFlowServicing {
        func marketFlow(period: ForeignFlowPeriod) async throws -> ForeignFlow { throw Boom() }
    }
    private struct ThrowingChart: ChartServicing {
        func candles(symbol: String, timeframe: ChartTimeframe, chartType: ChartType) async throws -> PriceSeries { throw Boom() }
    }
    private struct ThrowingCommodity: CommodityPriceServicing {
        func quote(symbol: String) async throws -> CommodityQuote { throw Boom() }
    }
    private struct EmptyBreadth: BreadthServicing {
        func reading(symbols: [String], period: Int) async -> BreadthReading { BreadthReading(above: 0, measured: 0) }
    }

    /// All stub inputs available. Stub chart has < 200 candles, so the trend factor
    /// is absent; valuation (neutral), policy rate (cut/risk-on), flow (net sell/
    /// risk-off), rupiah (USD/IDR up/risk-off) and breadth (62%/risk-on) net to neutral.
    @Test func synthesisesANeutralReadFromTheStubInputs() async {
        let vm = RegimeViewModel(
            snapshotProvider: StubRegimeSnapshotService(),
            flowService: AggregateForeignFlowService(flowService: StubForeignFlowService()),
            chartService: StubChartService(),
            commodityService: StubCommodityPriceService(),
            breadthService: StubBreadthService(),
            constituents: ["BBCA"])
        await vm.load()

        #expect(vm.error == nil)
        #expect(vm.read?.stance == .neutral)
        #expect(vm.read?.factors.contains { $0.kind == .valuation } == true)
        #expect(vm.read?.factors.contains { $0.kind == .breadth } == true)
        #expect(vm.read?.factors.contains { $0.kind == .trend } == false)   // insufficient history
        #expect(vm.read?.asOf == "2026-01-31")
    }

    @Test func surfacesAnErrorWhenEveryInputFails() async {
        let vm = RegimeViewModel(
            snapshotProvider: ThrowingSnapshot(),
            flowService: ThrowingFlow(),
            chartService: ThrowingChart(),
            commodityService: ThrowingCommodity(),
            breadthService: EmptyBreadth(),
            constituents: [])
        await vm.load()
        #expect(vm.read == nil)
        #expect(vm.error != nil)
    }

    @Test func degradesToLiveFactorsWhenTheSnapshotIsUnavailable() async {
        let vm = RegimeViewModel(
            snapshotProvider: ThrowingSnapshot(),       // regime.json not published yet
            flowService: AggregateForeignFlowService(flowService: StubForeignFlowService()),
            chartService: StubChartService(),
            commodityService: StubCommodityPriceService(),
            breadthService: StubBreadthService(),
            constituents: ["BBCA"])
        await vm.load()

        #expect(vm.read != nil)
        #expect(vm.read?.factors.contains { $0.kind == .valuation } == false)
        #expect(vm.read?.factors.contains { $0.kind == .policyRate } == false)
        #expect(vm.read?.factors.contains { $0.kind == .breadth } == true)
    }
}
