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
    @Test func loadParsesStringifiedFiltersAndUniverseAndPage1Rows() async throws {
        let store = InMemoryTokenStore(initial: TokenPair(accessToken: "A", refreshToken: "R"))
        // Template GET response carries both the template metadata AND page 1 rows.
        let body = Data(#"""
        {"data":{
          "template":{
            "name":"bandar-accumulating",
            "description":"",
            "filters":"[{\"operator\":\">\",\"item1_name\":\"Bandar Value\",\"multiplier\":\"1\",\"type\":\"compare\",\"item1\":14399,\"item2\":\"14426\",\"item2_name\":\"Bandar Value MA 20\"}]",
            "universe":"{\"scopeID\":\"0\",\"name\":\"IHSG\",\"scope\":\"IHSG\"}",
            "sequence":"14399,14426",
            "ordercol":2,"ordertype":"desc","limit":25
          },
          "screener":{
            "data":[
              {"symbol":"BBCA","name":"BCA","values":[1.0, 0.5]},
              {"symbol":"BBRI","name":"BRI","values":[2.0, 1.0]}
            ],
            "total":120
          }
        }}
        """#.utf8)
        let session = StubSession([.init(status: 200, body: body)])
        let client = APIClient(session: session, tokens: store)
        let svc = ScreenerTemplateService(apiClient: client)

        let result = try await svc.load(templateID: "6676213")

        #expect(result.config.name == "bandar-accumulating")
        #expect(result.config.filters.count == 1)
        #expect(result.config.filters[0].item1 == 14399)
        #expect(result.config.universe == .ihsg)
        #expect(result.config.sequence == [14399, 14426])
        #expect(result.config.screenerID == "6676213")

        #expect(result.page.rows.map(\.symbol) == ["BBCA", "BBRI"])
        #expect(result.page.total == 120)
        #expect(result.page.page == 1)
    }

    @Test func loadFallsBackToCannedDefaultsWhenFieldsMissing() async throws {
        let store = InMemoryTokenStore(initial: TokenPair(accessToken: "A", refreshToken: "R"))
        let session = StubSession([.init(status: 200, body: Data(#"{"data":{}}"#.utf8))])
        let client = APIClient(session: session, tokens: store)
        let svc = ScreenerTemplateService(apiClient: client)
        let result = try await svc.load(templateID: "X")
        #expect(result.config.sequence == [14399, 14426])  // fell back to canned defaults
        #expect(result.config.universe == .ihsg)
        #expect(result.page.rows.isEmpty)
    }

    /// Regression: when the GET response ships only rows (no template metadata),
    /// the parser must use a templateID-specific filter default — not a single shared
    /// canned set. Otherwise bandar-above-ma20's page 2+ POSTs run with bandar-accumulating's
    /// 2-filter set and silently cap the results at bandar-accumulating's total.
    @Test func parseChoosesTemplateSpecificFiltersWhenServerOmitsMetadata() async throws {
        let store = InMemoryTokenStore(initial: TokenPair(accessToken: "A", refreshToken: "R"))
        // Real-world Stockbit GET response: just data.calcs, no template field.
        let body = Data(#"{"data":{"calcs":[]}}"#.utf8)
        let session = StubSession([
            .init(status: 200, body: body),
            .init(status: 200, body: body),
            .init(status: 200, body: body),
        ])
        let client = APIClient(session: session, tokens: store)
        let svc = ScreenerTemplateService(apiClient: client)

        let accumulating = try await svc.load(templateID: "6676213")
        let aboveMA20    = try await svc.load(templateID: "6676217")
        let shiftToday   = try await svc.load(templateID: "6676221")

        // bandar-accumulating: compare (value > MA20) + basic (value > 0) = 2 filters
        #expect(accumulating.config.filters.count == 2)
        // bandar-above-ma20: compare-only = 1 filter (this is the "less criteria" the
        // sidebar advertises). With the wrong fallback, this would be 2.
        #expect(aboveMA20.config.filters.count == 1)
        #expect(aboveMA20.config.filters.first?.type == .compare)
        // bandar-shift-today: Bandar Value (14399) > Previous Bandar Value (14425).
        // Sequence and item2 differ from above-ma20; if we reused above-ma20's filter
        // set the POST would compare against 14426 (Bandar Value MA 20) instead.
        #expect(shiftToday.config.filters.count == 1)
        #expect(shiftToday.config.filters.first?.item1 == 14399)
        #expect(shiftToday.config.filters.first?.item2 == "14425")
        #expect(shiftToday.config.sequence == [14399, 14425])
    }
}

// MARK: - ScreenerService row enrichment

@Suite struct ScreenerStockbitShapeTests {
    /// Pins the real-world envelope captured 2026-05-31:
    ///   data.calcs[].company.{symbol,name}
    ///   data.calcs[].results[].{id, raw, item}
    @Test func parsesCalcsEnvelopeWithNestedCompanyAndResults() throws {
        let body = Data(#"""
        {"data":{"calcs":[
          {"company":{"symbol":"BOGA","name":"Apollo Global Interactive Tbk.","exchange":"IDX"},
           "results":[
             {"id":14399,"item":"Bandar Value","raw":"14925216921719.91","display":"14,925.22 B"},
             {"id":14426,"item":"Bandar Value MA 20","raw":"14925216260264.54","display":"14,925.22 B"}]},
          {"company":{"symbol":"CARE","name":"Metro Healthcare Indonesia Tbk."},
           "results":[
             {"id":14399,"item":"Bandar Value","raw":"6168555478468.97"},
             {"id":14426,"item":"Bandar Value MA 20","raw":"6168183877350.62"}]}
        ]}}
        """#.utf8)
        let page = try ScreenerService.decodeResponse(body, sequence: [14399, 14426], page: 1)
        #expect(page.rows.count == 2)
        #expect(page.rows[0].symbol == "BOGA")
        #expect(page.rows[0].name == "Apollo Global Interactive Tbk.")
        #expect(page.rows[0].values[0] == 14925216921719.91)
        #expect(page.rows[0].values[1] == 14925216260264.54)
        #expect(page.rows[1].symbol == "CARE")
        #expect(page.rows[1].values[0] == 6168555478468.97)
    }

    /// ScreenerTemplateService walks the tree to find the rows array — it must also
    /// recognise calcs entries (which don't have a top-level "symbol" field).
    @Test func templateServiceFindsCalcsRowsViaTreeWalk() async throws {
        let store = InMemoryTokenStore(initial: TokenPair(accessToken: "A", refreshToken: "R"))
        let body = Data(#"""
        {"data":{"calcs":[
          {"company":{"symbol":"BBCA","name":"BCA"},
           "results":[{"id":14399,"item":"Bandar Value","raw":"100.5"},
                      {"id":14426,"item":"Bandar Value MA 20","raw":"80.0"}]}
        ]}}
        """#.utf8)
        let session = StubSession([.init(status: 200, body: body)])
        let client = APIClient(session: session, tokens: store)
        let svc = ScreenerTemplateService(apiClient: client)

        let result = try await svc.load(templateID: "6676213")

        #expect(result.page.rows.count == 1)
        #expect(result.page.rows[0].symbol == "BBCA")
        #expect(result.page.rows[0].values == [100.5, 80.0])
    }
}

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
    var result: Result<ScreenerInitialResult, Error> = .success({
        var c = ScreenerConfig()
        c.name = "loaded-template"
        c.sequence = [14399, 14426]
        c.orderColumn = 2
        c.orderType = "desc"
        return ScreenerInitialResult(
            config: c,
            page: ScreenerPage(rows: [], total: 0, page: 1)
        )
    }())
    /// When non-nil, takes precedence over `result` — returns the entry whose key matches
    /// the requested templateID. Lets a single fake serve multiple screeners.
    var resultsByTemplateID: [String: Result<ScreenerInitialResult, Error>]?
    private(set) var loadCalls: [String] = []
    func load(templateID: String) async throws -> ScreenerInitialResult {
        loadCalls.append(templateID)
        if let byID = resultsByTemplateID, let scoped = byID[templateID] {
            return try scoped.get()
        }
        return try result.get()
    }
}

@MainActor
@Suite struct ScreenerBootstrapTests {
    private func templateWithRows(_ rows: [ScreenerRow], total: Int? = nil) -> FakeTemplateService {
        let templates = FakeTemplateService()
        var c = ScreenerConfig()
        c.name = "loaded-template"
        c.sequence = [14399, 14426]
        c.orderColumn = 2
        c.orderType = "desc"
        templates.result = .success(ScreenerInitialResult(
            config: c,
            page: ScreenerPage(rows: rows, total: total, page: 1)
        ))
        return templates
    }

    @Test func autoRunCallsPaywallCheckIncrementAndUsesTemplatePage1Rows() async {
        let paywall = FakePaywallService()
        let templates = templateWithRows([
            ScreenerRow(symbol: "A", name: "A", values: [1, 2], lastPrice: nil, pctChange: nil),
            ScreenerRow(symbol: "B", name: "B", values: [3, 4], lastPrice: nil, pctChange: nil),
        ], total: 100)
        let screenerSvc = FakeScreenerService()  // should NOT be called for page 1
        let vm = ScreenerViewModel(service: screenerSvc, paywall: paywall, templates: templates)

        await vm.autoRunIfNeeded()

        #expect(paywall.checkCalls == [.screener])
        #expect(paywall.incrementCalls == [.screener])
        #expect(templates.loadCalls == ["6676213"])
        #expect(vm.config.name == "loaded-template")
        #expect(vm.rows.count == 2)
        #expect(vm.currentPage == 1)
        #expect(vm.total == 100)
        #expect(screenerSvc.calls.isEmpty)  // POST never fires when GET supplied page 1
    }

    @Test func rowDidAppearAtLastIndexTriggersNextPage() async {
        let paywall = FakePaywallService()
        let templates = templateWithRows([
            ScreenerRow(symbol: "A", name: "A", values: [10, 0], lastPrice: nil, pctChange: nil),
            ScreenerRow(symbol: "B", name: "B", values: [5, 0], lastPrice: nil, pctChange: nil),
        ], total: 50)
        let screenerSvc = FakeScreenerService()
        screenerSvc.outcomes = [
            // Page 2: full 25 limit — should still have more
            .success(ScreenerPage(
                rows: (0..<25).map { i in
                    ScreenerRow(symbol: "P2_\(i)", name: "P2_\(i)", values: [Double(100 - i), 0],
                                lastPrice: nil, pctChange: nil)
                }, total: 50, page: 2))
        ]
        let vm = ScreenerViewModel(service: screenerSvc, paywall: paywall, templates: templates)
        await vm.autoRunIfNeeded()
        #expect(vm.rows.count == 2)
        #expect(vm.hasMore)

        // Simulate the last row appearing on screen.
        await vm.rowDidAppear(at: vm.rows.count - 1)

        #expect(screenerSvc.calls.count == 1)
        #expect(screenerSvc.calls.first?.page == 2)
        #expect(vm.rows.count == 27)
    }

    @Test func emptyPageEndsAutoPagination() async {
        let paywall = FakePaywallService()
        // Full first page (== config.limit) + an advertised total so bootstrap leaves us "more available".
        let firstPage = (0..<25).map { i in
            ScreenerRow(symbol: "R\(i)", name: "R\(i)", values: [Double(100 - i), 0],
                        lastPrice: nil, pctChange: nil)
        }
        let templates = templateWithRows(firstPage, total: 50)
        let screenerSvc = FakeScreenerService()
        screenerSvc.outcomes = [
            .success(ScreenerPage(rows: [], total: nil, page: 2)),  // server says done
        ]
        let vm = ScreenerViewModel(service: screenerSvc, paywall: paywall, templates: templates)
        await vm.autoRunIfNeeded()

        await vm.rowDidAppear(at: vm.rows.count - 1)  // triggers POST page 2
        #expect(screenerSvc.calls.count == 1)
        #expect(vm.hasMore == false)

        // Subsequent triggers must NOT fire another request.
        await vm.rowDidAppear(at: vm.rows.count - 1)
        await vm.rowDidAppear(at: vm.rows.count - 1)
        #expect(screenerSvc.calls.count == 1)
    }

    @Test func partialPageBelowLimitMarksDone() async {
        let paywall = FakePaywallService()
        // Page 1 returns 25 rows (== config.limit), still has more
        let firstPage = (0..<25).map { i in
            ScreenerRow(symbol: "R\(i)", name: "R\(i)", values: [Double(100 - i), 0],
                        lastPrice: nil, pctChange: nil)
        }
        let templates = templateWithRows(firstPage)
        let screenerSvc = FakeScreenerService()
        // Page 2 returns 10 rows (< limit) → that's the last page
        screenerSvc.outcomes = [
            .success(ScreenerPage(
                rows: (0..<10).map { i in
                    ScreenerRow(symbol: "P2_\(i)", name: "P2_\(i)", values: [Double(10 - i), 0],
                                lastPrice: nil, pctChange: nil)
                }, total: nil, page: 2))
        ]
        let vm = ScreenerViewModel(service: screenerSvc, paywall: paywall, templates: templates)
        await vm.autoRunIfNeeded()
        await vm.rowDidAppear(at: vm.rows.count - 1)

        #expect(vm.rows.count == 35)
        #expect(vm.hasMore == false)
    }

    @Test func rowAppearBeforeLastIsIgnored() async {
        let paywall = FakePaywallService()
        let templates = templateWithRows([
            ScreenerRow(symbol: "A", name: "A", values: [10, 0], lastPrice: nil, pctChange: nil),
            ScreenerRow(symbol: "B", name: "B", values: [5, 0], lastPrice: nil, pctChange: nil),
        ], total: 50)
        let screenerSvc = FakeScreenerService()
        let vm = ScreenerViewModel(service: screenerSvc, paywall: paywall, templates: templates)
        await vm.autoRunIfNeeded()

        // Appears reported for non-last rows must not page.
        await vm.rowDidAppear(at: 0)

        #expect(screenerSvc.calls.isEmpty)
    }

    @Test func loadMoreUsesPOSTPage2AfterBootstrap() async {
        let paywall = FakePaywallService()
        let templates = templateWithRows([
            ScreenerRow(symbol: "A", name: "A", values: [10, 0], lastPrice: nil, pctChange: nil),
        ], total: 2)
        let screenerSvc = FakeScreenerService()
        screenerSvc.outcomes = [.success(ScreenerPage(
            rows: [ScreenerRow(symbol: "B", name: "B", values: [5, 0], lastPrice: nil, pctChange: nil)],
            total: 2, page: 2))]
        let vm = ScreenerViewModel(service: screenerSvc, paywall: paywall, templates: templates)

        await vm.autoRunIfNeeded()
        await vm.loadMore()

        #expect(screenerSvc.calls.count == 1)
        #expect(screenerSvc.calls.first?.page == 2)
        // ordercol=2 desc → A(10) before B(5)
        #expect(vm.rows.map(\.symbol) == ["A", "B"])
        #expect(vm.currentPage == 2)
    }

    @Test func autoRunIsIdempotentAcrossMultipleCalls() async {
        let paywall = FakePaywallService()
        let templates = templateWithRows([])
        let svc = FakeScreenerService()
        let vm = ScreenerViewModel(service: svc, paywall: paywall, templates: templates)

        await vm.autoRunIfNeeded()
        await vm.autoRunIfNeeded()
        await vm.autoRunIfNeeded()

        #expect(paywall.checkCalls.count == 1)
        #expect(paywall.incrementCalls.count == 1)
    }

    @Test func templateLoadFailureSurfacesErrorWithoutPOSTFallback() async {
        // The canned ScreenerConfig() defaults match bandar-accumulating only, so falling
        // back to POST for any other templateID would silently leak bandar-accumulating's
        // rows. Surface an error instead — no implicit POST.
        let paywall = FakePaywallService()
        let templates = FakeTemplateService()
        templates.result = .failure(ScreenerError.malformedResponse)
        let svc = FakeScreenerService()
        let vm = ScreenerViewModel(service: svc, paywall: paywall, templates: templates)

        await vm.autoRunIfNeeded()

        #expect(svc.calls.isEmpty)
        #expect(vm.rows.isEmpty)
        #expect(vm.error != nil)
    }

    @Test func bootstrapAppliesTemplateSortOrderToReturnedRows() async {
        let paywall = FakePaywallService()
        let templates = templateWithRows([
            ScreenerRow(symbol: "A", name: "A", values: [10, 0], lastPrice: nil, pctChange: nil),
            ScreenerRow(symbol: "B", name: "B", values: [50, 0], lastPrice: nil, pctChange: nil),
            ScreenerRow(symbol: "C", name: "C", values: [30, 0], lastPrice: nil, pctChange: nil),
        ])
        let vm = ScreenerViewModel(service: FakeScreenerService(), paywall: paywall, templates: templates)

        await vm.autoRunIfNeeded()

        // ordercol=2, ordertype=desc → sort by first metric descending: B(50), C(30), A(10)
        #expect(vm.rows.map(\.symbol) == ["B", "C", "A"])
        #expect(vm.sort.isEmpty) // no header chevron after reset
    }

    @Test func paywallIneligibleSurfacesBannerButRunsAnyway() async {
        let paywall = FakePaywallService()
        paywall.eligibility = PaywallEligibility(eligible: false, message: "Upgrade to use the screener.")
        let templates = templateWithRows([
            ScreenerRow(symbol: "A", name: "A", values: [1, 2], lastPrice: nil, pctChange: nil),
        ])
        let vm = ScreenerViewModel(service: FakeScreenerService(), paywall: paywall, templates: templates)

        await vm.autoRunIfNeeded()

        #expect(vm.paywallMessage == "Upgrade to use the screener.")
        #expect(vm.rows.count == 1) // still attempts; server-side will gate if needed
    }

    /// Regression: two ScreenerViewModels for different screeners must keep independent
    /// rows after bootstrap. If switching tabs accidentally shared state, bandar-above-ma20
    /// would surface bandar-accumulating's rows (and counts).
    @Test func twoScreenerVMsBootstrapIndependentlyByTemplateID() async {
        func config(named name: String, screenerID: String) -> ScreenerConfig {
            var c = ScreenerConfig()
            c.name = name
            c.screenerID = screenerID
            c.sequence = [14399, 14426]
            c.orderColumn = 2
            c.orderType = "desc"
            return c
        }
        let templates = FakeTemplateService()
        templates.resultsByTemplateID = [
            "6676213": .success(ScreenerInitialResult(
                config: config(named: "bandar-accumulating", screenerID: "6676213"),
                page: ScreenerPage(
                    rows: (0..<25).map { ScreenerRow(symbol: "ACC\($0)", name: "A", values: [Double(100 - $0), 0], lastPrice: nil, pctChange: nil) },
                    total: 120, page: 1
                ))),
            "6676217": .success(ScreenerInitialResult(
                config: config(named: "bandar-above-ma20", screenerID: "6676217"),
                page: ScreenerPage(
                    rows: (0..<3).map { ScreenerRow(symbol: "ABV\($0)", name: "B", values: [Double(10 - $0), 0], lastPrice: nil, pctChange: nil) },
                    total: 3, page: 1
                ))),
        ]
        let svc = FakeScreenerService()
        let accumVM = ScreenerViewModel(service: svc, paywall: FakePaywallService(),
                                        templates: templates, templateID: "6676213")
        let aboveVM = ScreenerViewModel(service: svc, paywall: FakePaywallService(),
                                        templates: templates, templateID: "6676217")

        await accumVM.autoRunIfNeeded()
        await aboveVM.autoRunIfNeeded()

        #expect(templates.loadCalls == ["6676213", "6676217"])
        #expect(accumVM.rows.count == 25)
        #expect(aboveVM.rows.count == 3)
        #expect(accumVM.config.screenerID == "6676213")
        #expect(aboveVM.config.screenerID == "6676217")
        #expect(accumVM.rows.first?.symbol.hasPrefix("ACC") == true)
        #expect(aboveVM.rows.first?.symbol.hasPrefix("ABV") == true)
    }

    /// Regression: when the GET template+page1 path fails for a non-default screener
    /// (e.g. bandar-above-ma20 / 6676217), bootstrap must NOT silently POST with the
    /// canned `ScreenerConfig()` defaults (which are bandar-accumulating's filters and
    /// screenerID). Otherwise both screeners surface bandar-accumulating's data whenever
    /// the GET path fails.
    @Test func templateLoadFailureForNonDefaultTemplateDoesNotLeakBandarAccumulatingRows() async {
        let paywall = FakePaywallService()
        let templates = FakeTemplateService()
        templates.result = .failure(ScreenerError.malformedResponse)
        let svc = FakeScreenerService()
        svc.outcomes = [.success(ScreenerPage(rows: [
            ScreenerRow(symbol: "ACCUM_LEAK", name: "leak", values: [1, 2], lastPrice: nil, pctChange: nil),
        ], total: 1, page: 1))]
        let vm = ScreenerViewModel(service: svc, paywall: paywall,
                                   templates: templates, templateID: "6676217")

        await vm.autoRunIfNeeded()

        // No silent fallback to POST with bandar-accumulating's canned filters.
        #expect(svc.calls.isEmpty)
        #expect(vm.rows.isEmpty)
        #expect(vm.error != nil)
    }
}
