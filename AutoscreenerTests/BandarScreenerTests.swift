import Foundation
import Testing
@testable import Autoscreener

// MARK: - PaywallService

@Suite struct PaywallServiceTests {
    @Test func checkSendsExpectedPathAndParsesEligibleTrue() async throws {
        let store = InMemoryTokenStore(initial: TokenPair(accessToken: "A", refreshToken: "R"))
        let session = StubSession([.init(
            status: 200,
            body: Data(#"{"data":{"is_eligible":true}}"#.utf8)
        )])
        let client = APIClient(session: session, tokens: store)
        let svc = PaywallService(apiClient: client)

        let result = await svc.check(.screener)

        #expect(result.eligible == true)
        let req = session.received[0]
        #expect(req.url?.path == "/paywall/eligibility/check")
        #expect(req.url?.query?.contains("features=PAYWALL_FEATURE_SCREENER") == true)
        #expect(req.value(forHTTPHeaderField: "authorization") == "Bearer A")
    }

    @Test func checkReturnsEligibleOnUnknownEnvelopeRatherThanFailing() async {
        let store = InMemoryTokenStore(initial: TokenPair(accessToken: "A", refreshToken: "R"))
        let session = StubSession([.init(status: 200, body: Data("garbage".utf8))])
        let client = APIClient(session: session, tokens: store)
        let svc = PaywallService(apiClient: client)
        let result = await svc.check(.screener)
        #expect(result.eligible == true)
    }

    @Test func incrementPostsFeatureName() async throws {
        let store = InMemoryTokenStore(initial: TokenPair(accessToken: "A", refreshToken: "R"))
        let session = StubSession([.init(status: 200, body: Data("{}".utf8))])
        let client = APIClient(session: session, tokens: store)
        let svc = PaywallService(apiClient: client)

        await svc.increment(.screener)

        let req = session.received[0]
        #expect(req.url?.path == "/paywall/counter/increment")
        #expect(req.httpMethod == "POST")
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: String]
        #expect(body["feature"] == "PAYWALL_FEATURE_SCREENER")
        #expect(body["company"] == "")
    }
}

// MARK: - ScreenerTemplateService

@Suite struct ScreenerTemplateServiceTests {
    @Test func loadParsesStringifiedFiltersAndUniverse() async throws {
        let store = InMemoryTokenStore(initial: TokenPair(accessToken: "A", refreshToken: "R"))
        // Template response with filters/universe as stringified JSON, like the wire format
        let body = Data(#"""
        {"data":{
          "name":"bandar-accumulating",
          "description":"",
          "filters":"[{\"operator\":\">\",\"item1_name\":\"Bandar Value\",\"multiplier\":\"1\",\"type\":\"compare\",\"item1\":14399,\"item2\":\"14426\",\"item2_name\":\"Bandar Value MA 20\"}]",
          "universe":"{\"scopeID\":\"0\",\"name\":\"IHSG\",\"scope\":\"IHSG\"}",
          "sequence":"14399,14426",
          "ordercol":2,"ordertype":"desc","limit":25}}
        """#.utf8)
        let session = StubSession([.init(status: 200, body: body)])
        let client = APIClient(session: session, tokens: store)
        let svc = ScreenerTemplateService(apiClient: client)

        let config = try await svc.load(templateID: "6676213")

        #expect(config.name == "bandar-accumulating")
        #expect(config.filters.count == 1)
        #expect(config.filters[0].item1 == 14399)
        #expect(config.filters[0].type == .compare)
        #expect(config.universe == .ihsg)
        #expect(config.sequence == [14399, 14426])
        #expect(config.orderColumn == 2)
        #expect(config.orderType == "desc")
        #expect(config.screenerID == "6676213")
    }

    @Test func loadFallsBackToCannedDefaultsWhenFieldsMissing() async throws {
        let store = InMemoryTokenStore(initial: TokenPair(accessToken: "A", refreshToken: "R"))
        let session = StubSession([.init(status: 200, body: Data(#"{"data":{}}"#.utf8))])
        let client = APIClient(session: session, tokens: store)
        let svc = ScreenerTemplateService(apiClient: client)
        let config = try await svc.load(templateID: "X")
        #expect(config.sequence == [14399, 14426])  // fell back to canned defaults
        #expect(config.universe == .ihsg)
    }
}

// MARK: - ScreenerService row enrichment

@Suite struct ScreenerRowEnrichmentTests {
    @Test func parsesLastPriceAndPercentChangeWhenPresent() throws {
        let body = Data(#"""
        {"data":[
          {"symbol":"BBCA","name":"BCA","values":[1,2],"last_price":10500,"pct_change":1.25},
          {"symbol":"BBRI","name":"BRI","values":[3,4],"close":4200,"change_percent":-0.5}
        ]}
        """#.utf8)
        let page = try ScreenerService.decodeResponse(body, sequence: [14399, 14426], page: 1)
        #expect(page.rows[0].lastPrice == 10500)
        #expect(page.rows[0].pctChange == 1.25)
        #expect(page.rows[1].lastPrice == 4200)        // picked up "close"
        #expect(page.rows[1].pctChange == -0.5)        // picked up "change_percent"
    }

    @Test func lastPriceAndChangeAreNilWhenAbsent() throws {
        let body = Data(#"{"data":[{"symbol":"X","name":"X","values":[1]}]}"#.utf8)
        let page = try ScreenerService.decodeResponse(body, sequence: [14399], page: 1)
        #expect(page.rows[0].lastPrice == nil)
        #expect(page.rows[0].pctChange == nil)
    }
}

// MARK: - ScreenerViewModel bootstrap

final class FakePaywallService: PaywallServicing, @unchecked Sendable {
    var eligibility = PaywallEligibility(eligible: true, message: nil)
    private(set) var checkCalls: [PaywallFeature] = []
    private(set) var incrementCalls: [PaywallFeature] = []
    func check(_ feature: PaywallFeature) async -> PaywallEligibility {
        checkCalls.append(feature)
        return eligibility
    }
    func increment(_ feature: PaywallFeature) async {
        incrementCalls.append(feature)
    }
}

final class FakeTemplateService: ScreenerTemplateServicing, @unchecked Sendable {
    var result: Result<ScreenerConfig, Error> = .success({
        var c = ScreenerConfig()
        c.name = "loaded-template"
        c.sequence = [14399, 14426]
        c.orderColumn = 2
        c.orderType = "desc"
        return c
    }())
    private(set) var loadCalls: [String] = []
    func load(templateID: String) async throws -> ScreenerConfig {
        loadCalls.append(templateID)
        return try result.get()
    }
}

@MainActor
@Suite struct ScreenerBootstrapTests {
    private func screener(rows: [ScreenerRow], total: Int = 2) -> FakeScreenerService {
        let svc = FakeScreenerService()
        svc.outcomes = [.success(ScreenerPage(rows: rows, total: total, page: 1))]
        return svc
    }

    @Test func autoRunCallsPaywallCheckIncrementTemplateLoadThenRun() async {
        let paywall = FakePaywallService()
        let templates = FakeTemplateService()
        let screenerSvc = screener(rows: [
            ScreenerRow(symbol: "A", name: "A", values: [1, 2], lastPrice: nil, pctChange: nil),
            ScreenerRow(symbol: "B", name: "B", values: [3, 4], lastPrice: nil, pctChange: nil),
        ])
        let vm = ScreenerViewModel(service: screenerSvc, paywall: paywall, templates: templates)

        await vm.autoRunIfNeeded()

        #expect(paywall.checkCalls == [.screener])
        #expect(paywall.incrementCalls == [.screener])
        #expect(templates.loadCalls == ["6676213"])
        #expect(vm.config.name == "loaded-template")
        #expect(vm.rows.count == 2)
    }

    @Test func autoRunIsIdempotentAcrossMultipleCalls() async {
        let paywall = FakePaywallService()
        let templates = FakeTemplateService()
        let svc = screener(rows: [])
        let vm = ScreenerViewModel(service: svc, paywall: paywall, templates: templates)

        await vm.autoRunIfNeeded()
        await vm.autoRunIfNeeded()
        await vm.autoRunIfNeeded()

        #expect(paywall.checkCalls.count == 1)
        #expect(paywall.incrementCalls.count == 1)
    }

    @Test func templateLoadFailureFallsBackToCannedConfig() async {
        let paywall = FakePaywallService()
        let templates = FakeTemplateService()
        templates.result = .failure(ScreenerError.malformedResponse)
        let svc = screener(rows: [
            ScreenerRow(symbol: "X", name: "X", values: [1, 2], lastPrice: nil, pctChange: nil),
        ])
        let vm = ScreenerViewModel(service: svc, paywall: paywall, templates: templates)

        await vm.autoRunIfNeeded()

        #expect(vm.config.name == "bandar-accumulating") // canned default
        #expect(vm.rows.count == 1)
    }

    @Test func runResetsSortToTemplateDefault() async {
        let paywall = FakePaywallService()
        let templates = FakeTemplateService()
        let svc = FakeScreenerService()
        svc.outcomes = [.success(ScreenerPage(rows: [
            ScreenerRow(symbol: "A", name: "A", values: [10, 0], lastPrice: nil, pctChange: nil),
            ScreenerRow(symbol: "B", name: "B", values: [50, 0], lastPrice: nil, pctChange: nil),
            ScreenerRow(symbol: "C", name: "C", values: [30, 0], lastPrice: nil, pctChange: nil),
        ], total: 3, page: 1))]
        let vm = ScreenerViewModel(service: svc, paywall: paywall, templates: templates)

        await vm.autoRunIfNeeded()

        // ordercol=2, ordertype=desc → sort by first metric descending: B(50), C(30), A(10)
        #expect(vm.rows.map(\.symbol) == ["B", "C", "A"])
        #expect(vm.sort.isEmpty) // no header chevron after reset
    }

    @Test func paywallIneligibleSurfacesBannerButRunsAnyway() async {
        let paywall = FakePaywallService()
        paywall.eligibility = PaywallEligibility(eligible: false, message: "Upgrade to use the screener.")
        let templates = FakeTemplateService()
        let svc = screener(rows: [
            ScreenerRow(symbol: "A", name: "A", values: [1, 2], lastPrice: nil, pctChange: nil),
        ])
        let vm = ScreenerViewModel(service: svc, paywall: paywall, templates: templates)

        await vm.autoRunIfNeeded()

        #expect(vm.paywallMessage == "Upgrade to use the screener.")
        #expect(vm.rows.count == 1) // still attempts; server-side will gate if needed
    }
}
