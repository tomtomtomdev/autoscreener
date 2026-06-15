import Foundation
import Testing
@testable import Autoscreener

final class FakeBrokerSummaryService: BrokerSummaryServicing, @unchecked Sendable {
    enum Outcome { case success(BrokerSummary), failure(Error) }
    var outcomes: [Outcome] = []
    private(set) var calls: [(symbol: String, period: BrokerSummaryPeriod, limit: Int)] = []

    func summary(symbol: String, period: BrokerSummaryPeriod, limit: Int) async throws -> BrokerSummary {
        calls.append((symbol, period, limit))
        switch outcomes.isEmpty ? .success(UITestFixtures.brokerSummary(symbol: symbol)) : outcomes.removeFirst() {
        case .success(let s): return s
        case .failure(let e): throw e
        }
    }
}

final class FakeForeignFlowService: ForeignFlowServicing, @unchecked Sendable {
    enum Outcome { case success(ForeignFlow), failure(Error) }
    var outcomes: [Outcome] = []
    private(set) var calls: [(symbol: String, period: ForeignFlowPeriod)] = []

    func flow(symbol: String, period: ForeignFlowPeriod, marketType: ForeignFlowMarketType) async throws -> ForeignFlow {
        calls.append((symbol, period))
        switch outcomes.isEmpty ? .success(UITestFixtures.foreignFlow(symbol: symbol)) : outcomes.removeFirst() {
        case .success(let f): return f
        case .failure(let e): throw e
        }
    }
}

private let ticker = StockTicker(symbol: "TPIA", name: "Chandra Asri Pacific")

@MainActor
@Suite struct BrokerSummaryViewModelTests {
    @Test func loadPopulatesSummaryWithDefaultPeriod() async {
        let svc = FakeBrokerSummaryService()
        let vm = BrokerSummaryViewModel(ticker: ticker, service: svc)

        await vm.load()

        #expect(vm.summary != nil)
        #expect(vm.error == nil)
        #expect(svc.calls.first?.symbol == "TPIA")
        #expect(svc.calls.first?.period == .latest)
    }

    @Test func reloadIsSkippedWhenAlreadyLoadedForSamePeriod() async {
        let svc = FakeBrokerSummaryService()
        let vm = BrokerSummaryViewModel(ticker: ticker, service: svc)

        await vm.load()
        await vm.load()   // no force, same period

        #expect(svc.calls.count == 1)
    }

    @Test func changingPeriodForcesReloadWithNewParam() async {
        let svc = FakeBrokerSummaryService()
        let vm = BrokerSummaryViewModel(ticker: ticker, service: svc)

        await vm.load()
        vm.period = .last1Month
        await vm.load(force: true)

        #expect(svc.calls.count == 2)
        #expect(svc.calls.last?.period == .last1Month)
    }

    @Test func unauthorizedSurfacesSessionError() async {
        let svc = FakeBrokerSummaryService()
        svc.outcomes = [.failure(APIError.unauthorized)]
        let vm = BrokerSummaryViewModel(ticker: ticker, service: svc)

        await vm.load()

        #expect(vm.summary == nil)
        #expect(vm.error == "Session expired. Please sign in again.")
    }
}

@MainActor
@Suite struct ForeignFlowViewModelTests {
    @Test func loadPopulatesFlowWithDefaultPeriod() async {
        let svc = FakeForeignFlowService()
        let vm = ForeignFlowViewModel(ticker: ticker, service: svc)

        await vm.load()

        #expect(vm.flow?.netForeign.raw == -360_701_021_000)
        #expect(vm.error == nil)
        #expect(svc.calls.first?.period == .oneDay)
    }

    @Test func changingPeriodForcesReloadWithNewParam() async {
        let svc = FakeForeignFlowService()
        let vm = ForeignFlowViewModel(ticker: ticker, service: svc)

        await vm.load()
        vm.period = .oneMonth
        await vm.load(force: true)

        #expect(svc.calls.last?.period == .oneMonth)
    }

    @Test func unauthorizedSurfacesSessionError() async {
        let svc = FakeForeignFlowService()
        svc.outcomes = [.failure(APIError.unauthorized)]
        let vm = ForeignFlowViewModel(ticker: ticker, service: svc)

        await vm.load()

        #expect(vm.flow == nil)
        #expect(vm.error == "Session expired. Please sign in again.")
    }
}
