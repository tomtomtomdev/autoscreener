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

// MARK: - ScreenerViewModel (store projection)

private func makeRow(_ symbol: String, _ a: Double, _ b: Double) -> ScreenerRow {
    ScreenerRow(symbol: symbol, name: symbol + " Co", values: [a, b], lastPrice: nil, pctChange: nil)
}

@MainActor
@Suite struct ScreenerViewModelTests {
    /// Seeds a store with one snapshot for `kind` and returns a VM bound to it.
    private func makeVM(kind: BandarScreenerKind = .accumulating,
                        rows: [ScreenerRow],
                        config: ScreenerConfig = ScreenerConfig()) -> (ScreenerViewModel, ScreenerStore) {
        let store = ScreenerStore(fileURL: nil, loadFromDisk: false)
        store.apply(ScreenerSnapshot(config: config, rows: rows, fetchedAt: Date(timeIntervalSince1970: 0)), for: kind)
        let vm = ScreenerViewModel(store: store, coordinator: SweepTestKit.coordinator(store: store), kind: kind)
        return (vm, store)
    }

    @Test func rendersRowsFromStoreSnapshot() {
        let (vm, _) = makeVM(rows: [makeRow("BBCA", 1, 2), makeRow("BBRI", 3, 4)])
        #expect(Set(vm.rows.map(\.symbol)) == ["BBCA", "BBRI"])
        #expect(vm.total == 2)
        #expect(vm.error == nil)
    }

    @Test func appliesTemplateDefaultSortDescendingByFirstMetric() {
        // Default ScreenerConfig: ordercol=2, ordertype=desc → sort by values[0] desc.
        let (vm, _) = makeVM(rows: [makeRow("A", 10, 0), makeRow("B", 50, 0), makeRow("C", 30, 0)])
        #expect(vm.rows.map(\.symbol) == ["B", "C", "A"])
    }

    @Test func headerSortOverridesTemplateDefault() {
        let (vm, _) = makeVM(rows: [makeRow("A", 10, 0), makeRow("B", 50, 0), makeRow("C", 30, 0)])
        vm.sort = [KeyPathComparator(\ScreenerRow.symbol, order: .forward)]
        #expect(vm.rows.map(\.symbol) == ["A", "B", "C"])
    }

    @Test func searchFiltersBySymbol() {
        let (vm, _) = makeVM(rows: [makeRow("BBCA", 1, 1), makeRow("BBRI", 2, 2), makeRow("TLKM", 3, 3)])
        vm.searchText = "bb"
        #expect(Set(vm.visibleRows.map(\.symbol)) == ["BBCA", "BBRI"])
    }

    @Test func noSnapshotYieldsNoRows() {
        let store = ScreenerStore(fileURL: nil, loadFromDisk: false)
        let vm = ScreenerViewModel(store: store, coordinator: SweepTestKit.coordinator(store: store), kind: .roeQuality)
        #expect(vm.rows.isEmpty)
        #expect(vm.total == nil)
    }

    // MARK: - loadState (cold-launch empty/loading)

    /// Regression: a cold launch with no cached snapshot must read as `.loading`, not
    /// flash the false "No matches" empty state before the screener has even run.
    @Test func loadStateIsLoadingWhenNoSnapshotAndNoError() {
        let store = ScreenerStore(fileURL: nil, loadFromDisk: false)
        let vm = ScreenerViewModel(store: store, coordinator: SweepTestKit.coordinator(store: store), kind: .roeQuality)
        #expect(vm.loadState == .loading)
    }

    @Test func loadStateIsFailedWhenNoSnapshotAndSweepErrored() {
        let store = ScreenerStore(fileURL: nil, loadFromDisk: false)
        let coordinator = SweepTestKit.coordinator(store: store)
        coordinator.lastError = "Couldn't load: ROE Quality (boom)"
        let vm = ScreenerViewModel(store: store, coordinator: coordinator, kind: .roeQuality)
        #expect(vm.loadState == .failed("Couldn't load: ROE Quality (boom)"))
    }

    @Test func loadStateIsEmptyWhenSnapshotHasNoRows() {
        let (vm, _) = makeVM(rows: [])
        #expect(vm.loadState == .empty)
    }

    @Test func loadStateIsReadyWhenSnapshotHasRows() {
        let (vm, _) = makeVM(rows: [makeRow("BBCA", 1, 2)])
        #expect(vm.loadState == .ready)
    }
}
