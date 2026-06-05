import Foundation
import Testing
@testable import Autoscreener

@Suite struct RegimeSnapshotServiceTests {
    static let json = Data(#"""
    { "asOf": "2026-01-31",
      "biRate": { "value": 4.75, "direction": "cut", "asOf": "2026-01-15" },
      "indices": { "COMPOSITE": { "pe": 13.2, "pb": 2.1, "pePctile": 0.42, "pbPctile": 0.55 } } }
    """#.utf8)

    @Test func fetchesAndDecodesOn200() async throws {
        let svc = RegimeSnapshotService(session: StubSession([.init(status: 200, body: Self.json)]))
        let snap = try await svc.snapshot()
        #expect(snap.asOf == "2026-01-31")
        #expect(snap.biRate?.direction == .cut)
        #expect(snap.composite?.pePctile == 0.42)
    }

    @Test func mapsNotFoundWhenSnapshotNotPublishedYet() async {
        let svc = RegimeSnapshotService(session: StubSession([.init(status: 404, body: Data())]))
        await #expect(throws: RegimeSnapshotError.notFound) { _ = try await svc.snapshot() }
    }

    @Test func mapsMalformedJSON() async {
        let svc = RegimeSnapshotService(session: StubSession([.init(status: 200, body: Data("not json".utf8))]))
        await #expect(throws: RegimeSnapshotError.malformedResponse) { _ = try await svc.snapshot() }
    }

    @Test func mapsOtherHTTPStatusesToNetwork() async {
        let svc = RegimeSnapshotService(session: StubSession([.init(status: 500, body: Data())]))
        await #expect(throws: RegimeSnapshotError.self) { _ = try await svc.snapshot() }
    }
}
