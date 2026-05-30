import Foundation
import Testing
@testable import Autoscreener

// MARK: - ScreenerService wire format

@Suite struct ScreenerServiceWireFormatTests {
    @Test func bodyContainsDoubleEncodedFiltersAndUniverse() throws {
        let data = try ScreenerService.encodeRunBody(ScreenerConfig(), page: 1)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["save"] as? String == "0")
        #expect(json["limit"] as? Int == 25)
        #expect(json["page"] as? Int == 1)
        #expect(json["ordercol"] as? Int == 2)
        #expect(json["ordertype"] as? String == "desc")
        #expect(json["type"] as? String == "TEMPLATE_TYPE_CUSTOM")
        #expect(json["sequence"] as? String == "14399,14426")
        #expect(json["screenerid"] as? String == "6676213")
        #expect(json["name"] as? String == "bandar-accumulating")

        // filters is a JSON-encoded string of an array
        let filters = json["filters"] as! String
        let parsed = try JSONSerialization.jsonObject(with: Data(filters.utf8)) as! [[String: Any]]
        #expect(parsed.count == 2)
        #expect(parsed[0]["operator"] as? String == ">")
        #expect(parsed[0]["item1"] as? Int == 14399)
        #expect(parsed[0]["type"] as? String == "compare")

        let universe = json["universe"] as! String
        let u = try JSONSerialization.jsonObject(with: Data(universe.utf8)) as! [String: Any]
        #expect(u["scope"] as? String == "IHSG")
        #expect(u["scopeID"] as? String == "0")
    }

    @Test func paginationIncrementsPage() throws {
        let data = try ScreenerService.encodeRunBody(ScreenerConfig(), page: 3)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["page"] as? Int == 3)
    }
}

// MARK: - ScreenerService response parsing

@Suite struct ScreenerServiceParseTests {
    @Test func parsesDataArrayEnvelope() throws {
        let body = Data(#"""
        {"data":[
          {"symbol":"BBCA","name":"Bank Central Asia","values":[123.45, 100.0]},
          {"symbol":"BBRI","name":"BRI","values":[80.1, 70.0]}
        ]}
        """#.utf8)
        let page = try ScreenerService.decodeResponse(body, sequence: [14399, 14426], page: 1)
        #expect(page.rows.count == 2)
        #expect(page.rows[0].symbol == "BBCA")
        #expect(page.rows[0].name == "Bank Central Asia")
        #expect(page.rows[0].values == [123.45, 100.0])
    }

    @Test func parsesNestedDataEnvelopeWithTotal() throws {
        let body = Data(#"""
        {"data":{"data":[{"symbol":"BBCA","name":"BCA","values":[1.0, 2.0]}], "total": 50}}
        """#.utf8)
        let page = try ScreenerService.decodeResponse(body, sequence: [14399, 14426], page: 2)
        #expect(page.total == 50)
        #expect(page.page == 2)
        #expect(page.rows.count == 1)
    }

    @Test func parsesIDKeyedMetrics() throws {
        let body = Data(#"""
        {"data":[{"symbol":"BBCA","name":"BCA","14399":99.5,"14426":80.0}]}
        """#.utf8)
        let page = try ScreenerService.decodeResponse(body, sequence: [14399, 14426], page: 1)
        #expect(page.rows[0].values == [99.5, 80.0])
    }

    @Test func tolerantOfMissingValues() throws {
        let body = Data(#"{"data":[{"symbol":"BBCA","name":"BCA"}]}"#.utf8)
        let page = try ScreenerService.decodeResponse(body, sequence: [14399, 14426], page: 1)
        #expect(page.rows[0].values == [nil, nil])
    }
}

// MARK: - ScreenerService error mapping

final class StubScreenerAPIClient {
    // Wraps APIClient via a fake HTTPSession to drive ScreenerService end-to-end.
    static func make(_ session: HTTPSession, tokens: TokenStoring) -> APIClient {
        APIClient(session: session, tokens: tokens)
    }
}

@Suite struct ScreenerServiceErrorMappingTests {
    @Test func mapsUnauthorizedWhenNoToken() async {
        let store = InMemoryTokenStore()
        let session = StubSession([])
        let client = APIClient(session: session, tokens: store)
        let svc = ScreenerService(apiClient: client)

        await #expect(throws: ScreenerError.unauthorized) {
            _ = try await svc.run(ScreenerConfig(), page: 1)
        }
    }

    @Test func mapsPaywallFromHttp403() async {
        let store = InMemoryTokenStore(initial: TokenPair(accessToken: "A", refreshToken: "R"))
        let session = StubSession([.init(status: 403, body: Data())])
        let client = APIClient(session: session, tokens: store)
        let svc = ScreenerService(apiClient: client)

        await #expect(throws: ScreenerError.paywall) {
            _ = try await svc.run(ScreenerConfig(), page: 1)
        }
    }
}

// MARK: - ScreenerViewModel

final class FakeScreenerService: ScreenerServicing, @unchecked Sendable {
    enum Outcome { case success(ScreenerPage), failure(ScreenerError) }
    var outcomes: [Outcome] = []
    private(set) var calls: [(config: ScreenerConfig, page: Int)] = []

    func run(_ config: ScreenerConfig, page: Int) async throws -> ScreenerPage {
        calls.append((config, page))
        guard !outcomes.isEmpty else {
            return ScreenerPage(rows: [], total: 0, page: page)
        }
        switch outcomes.removeFirst() {
        case .success(let p): return p
        case .failure(let e): throw e
        }
    }
}

private func makeRow(_ symbol: String, _ a: Double, _ b: Double) -> ScreenerRow {
    ScreenerRow(symbol: symbol, name: symbol + " Co", values: [a, b])
}

@MainActor
@Suite struct ScreenerViewModelTests {
    @Test func runLoadsFirstPage() async {
        let svc = FakeScreenerService()
        svc.outcomes = [.success(.init(rows: [makeRow("BBCA", 1, 2), makeRow("BBRI", 3, 4)], total: 2, page: 1))]
        let vm = ScreenerViewModel(service: svc)

        await vm.run()

        #expect(vm.rows.count == 2)
        #expect(vm.total == 2)
        #expect(vm.currentPage == 1)
        #expect(svc.calls[0].page == 1)
        #expect(vm.error == nil)
    }

    @Test func loadMoreAppendsAndIncrementsPage() async {
        let svc = FakeScreenerService()
        svc.outcomes = [
            .success(.init(rows: [makeRow("A", 1, 1)], total: 2, page: 1)),
            .success(.init(rows: [makeRow("B", 2, 2)], total: 2, page: 2)),
        ]
        let vm = ScreenerViewModel(service: svc)
        await vm.run()
        await vm.loadMore()

        #expect(vm.rows.map(\.symbol) == ["A", "B"])
        #expect(vm.currentPage == 2)
        #expect(vm.hasMore == false)
    }

    @Test func runClearsPreviousRows() async {
        let svc = FakeScreenerService()
        svc.outcomes = [
            .success(.init(rows: [makeRow("A", 1, 1)], total: 1, page: 1)),
            .success(.init(rows: [makeRow("X", 9, 9)], total: 1, page: 1)),
        ]
        let vm = ScreenerViewModel(service: svc)
        await vm.run()
        await vm.run()
        #expect(vm.rows.map(\.symbol) == ["X"])
    }

    @Test func surfacesUnauthorizedError() async {
        let svc = FakeScreenerService()
        svc.outcomes = [.failure(.unauthorized)]
        let vm = ScreenerViewModel(service: svc)
        await vm.run()
        #expect(vm.error == "Session expired. Please sign in again.")
        #expect(vm.rows.isEmpty)
    }
}
