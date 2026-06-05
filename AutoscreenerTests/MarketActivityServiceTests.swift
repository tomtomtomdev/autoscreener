import Foundation
import Testing
@testable import Autoscreener

// MARK: - BrokerSummaryService

@Suite struct BrokerSummaryServiceTests {
    private func makeService(_ body: Data) -> (BrokerSummaryService, StubSession) {
        let store = InMemoryTokenStore(initial: TokenPair(accessToken: "A", refreshToken: "R"))
        let session = StubSession([.init(status: 200, body: body)])
        let client = APIClient(session: session, tokens: store)
        return (BrokerSummaryService(apiClient: client), session)
    }

    @Test func sendsExpectedRequest() async throws {
        let (svc, session) = makeService(MarketActivityFixtures.brokerSummaryTPIA)

        _ = try await svc.summary(symbol: "TPIA", period: .latest, limit: 25)

        let req = session.received[0]
        #expect(req.httpMethod == "GET")
        #expect(req.url?.path == "/marketdetectors/TPIA")
        let query = req.url?.query ?? ""
        #expect(query.contains("period=BROKER_SUMMARY_PERIOD_LATEST"))
        #expect(query.contains("limit=25"))
        #expect(query.contains("investor_type=1"))
        #expect(query.contains("market_board=2"))
        #expect(query.contains("transaction_type=1"))
        #expect(req.value(forHTTPHeaderField: "authorization") == "Bearer A")
    }

    @Test func periodSelectsQueryValue() async throws {
        let (svc, session) = makeService(MarketActivityFixtures.brokerSummaryTPIA)
        _ = try await svc.summary(symbol: "TPIA", period: .last7Days, limit: 25)
        #expect(session.received[0].url?.query?.contains("period=BROKER_SUMMARY_PERIOD_LAST_7_DAYS") == true)
    }

    @Test func decodesEnvelopeAndDetector() async throws {
        let (svc, _) = makeService(MarketActivityFixtures.brokerSummaryTPIA)

        let summary = try await svc.summary(symbol: "TPIA", period: .latest)

        #expect(summary.symbol == "TPIA")
        #expect(summary.from == "2026-06-03")
        #expect(summary.to == "2026-06-03")
        #expect(summary.buyers.count == 25)
        #expect(summary.sellers.count == 13)

        let d = summary.detector
        #expect(d.accdist == "Dist")
        #expect(d.numberBrokerBuySell == 52)
        #expect(d.totalBuyer == 65)
        #expect(d.totalSeller == 13)
        #expect(d.top5.accdist == "Big Dist")
        #expect(d.top5.amount == -322021520000)
        #expect(abs(d.averagePrice - 1702.2909) < 0.001)
    }

    @Test func parsesScientificNotationAndCategories() async throws {
        let (svc, _) = makeService(MarketActivityFixtures.brokerSummaryTPIA)

        let summary = try await svc.summary(symbol: "TPIA", period: .latest)

        // Top buyer ZP — foreign, value `"5.686627505e+11"`.
        let topBuyer = summary.buyers[0]
        #expect(topBuyer.brokerCode == "ZP")
        #expect(topBuyer.category == .foreign)
        #expect(abs(topBuyer.value - 568662750500) < 1)
        #expect(topBuyer.value > 0)
        #expect(topBuyer.frequency == 10758)

        // Top seller YU — net value parses negative from `"-1.0231197405e+12"`.
        let topSeller = summary.sellers[0]
        #expect(topSeller.brokerCode == "YU")
        #expect(topSeller.value < 0)
        #expect(abs(topSeller.value - -1023119740500) < 1)
    }
}

// MARK: - ForeignFlowService

@Suite struct ForeignFlowServiceTests {
    private func makeService(_ body: Data) -> (ForeignFlowService, StubSession) {
        let store = InMemoryTokenStore(initial: TokenPair(accessToken: "A", refreshToken: "R"))
        let session = StubSession([.init(status: 200, body: body)])
        let client = APIClient(session: session, tokens: store)
        return (ForeignFlowService(apiClient: client), session)
    }

    @Test func sendsExpectedRequest() async throws {
        let (svc, session) = makeService(MarketActivityFixtures.foreignFlowTPIA)

        _ = try await svc.flow(symbol: "TPIA", period: .oneDay, marketType: .regular)

        let req = session.received[0]
        #expect(req.httpMethod == "GET")
        #expect(req.url?.path == "/findata-view/foreign-domestic/v1/chart-data/TPIA")
        let query = req.url?.query ?? ""
        #expect(query.contains("market_type=MARKET_TYPE_REGULAR"))
        #expect(query.contains("period=PERIOD_RANGE_1D"))
        #expect(req.value(forHTTPHeaderField: "authorization") == "Bearer A")
    }

    @Test func periodSelectsQueryValue() async throws {
        let (svc, session) = makeService(MarketActivityFixtures.foreignFlowTPIA)
        _ = try await svc.flow(symbol: "TPIA", period: .oneMonth)
        #expect(session.received[0].url?.query?.contains("period=PERIOD_RANGE_1M") == true)
    }

    @Test func decodesSummaryAndBreakdown() async throws {
        let (svc, _) = makeService(MarketActivityFixtures.foreignFlowTPIA)

        let flow = try await svc.flow(symbol: "TPIA", period: .oneDay)

        #expect(flow.symbol == "TPIA")
        #expect(flow.dateRange == "3 Jun 2026")
        #expect(flow.from == "2026-06-03")

        // Headline value flow — net foreign sell on the day.
        #expect(flow.foreignBuy.raw == 1142496692500)
        #expect(flow.foreignBuy.formatted == "1.14 T")
        #expect(flow.netForeign.raw == -360701021000)
        #expect(flow.netForeign.raw < 0)

        // Value (IDR) breakdown with foreign share.
        #expect(flow.value.label == "Value (IDR)")
        #expect(flow.value.total.raw == 2594529577500)
        #expect(abs(flow.value.foreignPercentage - 50.986015) < 0.001)
    }
}

// MARK: - AggregateForeignFlowService

@Suite struct AggregateForeignFlowServiceTests {
    /// Reuses the per-stock foreign-flow fixture as a representative payload: the
    /// market-wide endpoint is the same `chart-data/{symbol}` family pointed at the
    /// composite index, so the response shape is identical. (Pending a real IHSG
    /// capture — see `idx-regime-data-research.md` §2.)
    private func makeService(_ body: Data) -> (AggregateForeignFlowService, StubSession) {
        let store = InMemoryTokenStore(initial: TokenPair(accessToken: "A", refreshToken: "R"))
        let session = StubSession([.init(status: 200, body: body)])
        let client = APIClient(session: session, tokens: store)
        let service = AggregateForeignFlowService(flowService: ForeignFlowService(apiClient: client))
        return (service, session)
    }

    @Test func targetsCompositeIndexSymbol() async throws {
        let (svc, session) = makeService(MarketActivityFixtures.foreignFlowTPIA)

        _ = try await svc.marketFlow(period: .oneDay)

        let req = session.received[0]
        #expect(req.httpMethod == "GET")
        #expect(req.url?.path == "/findata-view/foreign-domestic/v1/chart-data/IHSG")
        let query = req.url?.query ?? ""
        #expect(query.contains("market_type=MARKET_TYPE_REGULAR"))
        #expect(query.contains("period=PERIOD_RANGE_1D"))
        #expect(req.value(forHTTPHeaderField: "authorization") == "Bearer A")
    }

    @Test func defaultPeriodIsOneDay() async throws {
        let (svc, session) = makeService(MarketActivityFixtures.foreignFlowTPIA)
        _ = try await svc.marketFlow()
        #expect(session.received[0].url?.query?.contains("period=PERIOD_RANGE_1D") == true)
    }

    @Test func decodesFlowTaggedAsComposite() async throws {
        let (svc, _) = makeService(MarketActivityFixtures.foreignFlowTPIA)

        let flow = try await svc.marketFlow(period: .oneDay)

        // Domain symbol comes from the service (pinned to IHSG), not the payload body.
        #expect(flow.symbol == "IHSG")
        // Negative net foreign = market-wide risk-off tell (the regime signal).
        #expect(flow.netForeign.raw == -360701021000)
        #expect(flow.netForeign.raw < 0)
        #expect(flow.value.label == "Value (IDR)")
    }
}
