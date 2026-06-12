import Foundation
import Testing
@testable import Autoscreener

// The shared `{ "message", "data" }` envelope every exodus endpoint returns. `data` must
// survive being `null` (uncovered analyst-ratings) and `[]` (empty consensus) as well as the
// populated case — these tests pin that contract since several services lean on it.
@Suite struct StockbitEnvelopeTests {
    private struct Row: Decodable, Equatable { let symbol: String }

    @Test func decodesPresentData() throws {
        let data = Data(#"{"message":"ok","data":{"symbol":"TPIA"}}"#.utf8)
        let env = try JSONDecoder().decode(StockbitEnvelope<Row>.self, from: data)
        #expect(env.message == "ok")
        #expect(env.data == Row(symbol: "TPIA"))
    }

    @Test func decodesNullDataAsNil() throws {
        let data = Data(#"{"message":"no coverage","data":null}"#.utf8)
        let env = try JSONDecoder().decode(StockbitEnvelope<Row>.self, from: data)
        #expect(env.data == nil)
    }

    @Test func decodesEmptyArrayDataAsEmptyNotNil() throws {
        let data = Data(#"{"message":"ok","data":[]}"#.utf8)
        let env = try JSONDecoder().decode(StockbitEnvelope<[Row]>.self, from: data)
        #expect(env.data == [])
    }

    @Test func toleratesMissingMessage() throws {
        let data = Data(#"{"data":{"symbol":"BBCA"}}"#.utf8)
        let env = try JSONDecoder().decode(StockbitEnvelope<Row>.self, from: data)
        #expect(env.data == Row(symbol: "BBCA"))
    }
}
