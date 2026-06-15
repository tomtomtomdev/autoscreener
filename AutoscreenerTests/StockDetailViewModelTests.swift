import Foundation
import Testing
@testable import Autoscreener

final class FakeFinancialStatementService: FinancialStatementServicing, @unchecked Sendable {
    enum Outcome { case success(FinancialStatement), failure(FinancialStatementError) }
    var outcomes: [Outcome] = []
    private(set) var calls: [(symbol: String, report: FinancialReportType, basis: FinancialPeriodBasis)] = []

    func load(symbol: String,
              report: FinancialReportType,
              basis: FinancialPeriodBasis) async throws -> FinancialStatement {
        calls.append((symbol, report, basis))
        guard !outcomes.isEmpty else {
            return FinancialStatement(currency: "IDR", periods: [], accounts: [])
        }
        switch outcomes.removeFirst() {
        case .success(let s): return s
        case .failure(let e): throw e
        }
    }
}

private let ticker = StockTicker(symbol: "TPIA", name: "Chandra Asri Pacific")

private func incomeStatement() -> FinancialStatement {
    // "Beban Usaha" has children but is NOT default-expanded → exercises the
    // "expand everything when the server curates nothing" fallback.
    try! FinancialStatementService.parse(FinancialStatementParseTests.incomeAnnual)
}

private func balanceSheet() -> FinancialStatement {
    try! FinancialStatementService.parse(FinancialStatementFlattenTests.balanceSheet)
}

@MainActor
@Suite struct StockDetailViewModelTests {
    @Test func loadPopulatesStatementWithDefaults() async {
        let svc = FakeFinancialStatementService()
        svc.outcomes = [.success(incomeStatement())]
        let vm = StockDetailViewModel(ticker: ticker, service: svc)

        await vm.load()

        #expect(vm.statement != nil)
        #expect(vm.rows.isEmpty == false)
        #expect(vm.error == nil)
        #expect(svc.calls.first?.symbol == "TPIA")
        #expect(svc.calls.first?.report == .income)   // defaults
        #expect(svc.calls.first?.basis == .annual)
    }

    @Test func switchingReportReloadsWithNewParam() async {
        let svc = FakeFinancialStatementService()
        svc.outcomes = [.success(incomeStatement()), .success(balanceSheet())]
        let vm = StockDetailViewModel(ticker: ticker, service: svc)

        await vm.load()
        vm.report = .balanceSheet
        await vm.load()

        #expect(svc.calls.last?.report == .balanceSheet)
        #expect(svc.calls.last?.basis == .annual)
    }

    @Test func expandsEverythingWhenServerCuratesNothing() async {
        let svc = FakeFinancialStatementService()
        svc.outcomes = [.success(incomeStatement())]
        let vm = StockDetailViewModel(ticker: ticker, service: svc)

        await vm.load()

        // Income fixture marks nothing default-expanded → fall back to all parents.
        #expect(vm.expanded == ["3"])
        #expect(vm.rows.contains { $0.name == "Beban Penjualan" }) // child visible
    }

    @Test func honorsServerDefaultExpansion() async {
        let svc = FakeFinancialStatementService()
        svc.outcomes = [.success(balanceSheet())]
        let vm = StockDetailViewModel(ticker: ticker, service: svc)

        await vm.load()

        #expect(vm.expanded == ["0", "0.0", "1"])
    }

    @Test func toggleFlipsExpansion() async {
        let svc = FakeFinancialStatementService()
        svc.outcomes = [.success(balanceSheet())]
        let vm = StockDetailViewModel(ticker: ticker, service: svc)
        await vm.load()

        vm.toggle("0")            // collapse Aset
        #expect(vm.expanded.contains("0") == false)
        vm.toggle("0")            // expand again
        #expect(vm.expanded.contains("0"))
    }

    @Test func paywallSetsMessageAndClearsStatement() async {
        let svc = FakeFinancialStatementService()
        svc.outcomes = [.failure(.paywall)]
        let vm = StockDetailViewModel(ticker: ticker, service: svc)

        await vm.load()

        #expect(vm.paywallMessage != nil)
        #expect(vm.statement == nil)
    }

    @Test func unauthorizedSetsSessionExpiredError() async {
        let svc = FakeFinancialStatementService()
        svc.outcomes = [.failure(.unauthorized)]
        let vm = StockDetailViewModel(ticker: ticker, service: svc)

        await vm.load()

        #expect(vm.error == "Session expired. Please sign in again.")
        #expect(vm.statement == nil)
    }
}
