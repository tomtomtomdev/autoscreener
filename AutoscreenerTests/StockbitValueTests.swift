import Foundation
import Testing
@testable import Autoscreener

// `StockbitValue` is the `{ raw, formatted }` pair the `order-trade/*` endpoints wrap every
// number in. The contract under test is its TOLERANT `raw` decoding: across the captured feeds
// `raw` arrives as a JSON Int (broker payloads), a JSON Double, or a numeric String (top-stock /
// broker/top / running-trade), and is sometimes absent. `formatted` is the display string and is
// never load-bearing for selection — `raw` is the source of truth.
@Suite struct StockbitValueTests {
    private func decode(_ json: String) throws -> StockbitValue {
        try JSONDecoder().decode(StockbitValue.self, from: Data(json.utf8))
    }

    @Test func decodesRawFromJSONInt() throws {
        let v = try decode(#"{"raw":455039317500,"formatted":"455.0B"}"#)
        #expect(v.raw == 455_039_317_500)
        #expect(v.formatted == "455.0B")
    }

    @Test func decodesRawFromJSONDouble() throws {
        let v = try decode(#"{"raw":12.5,"formatted":"12.5"}"#)
        #expect(v.raw == 12.5)
    }

    @Test func decodesRawFromNumericString() throws {
        // top-stock wraps raw as a numeric String, not a JSON number.
        let v = try decode(#"{"raw":"41185802500","formatted":"41.2B"}"#)
        #expect(v.raw == 41_185_802_500)
        #expect(v.formatted == "41.2B")
    }

    @Test func decodesNegativeNumericString() throws {
        let v = try decode(#"{"raw":"-23592060000","formatted":"-23.6B"}"#)
        #expect(v.raw == -23_592_060_000)
    }

    @Test func absentRawDecodesToNilWithoutThrowing() throws {
        let v = try decode(#"{"formatted":"-"}"#)
        #expect(v.raw == nil)
        #expect(v.formatted == "-")
    }

    @Test func absentFormattedDecodesToEmptyString() throws {
        let v = try decode(#"{"raw":7}"#)
        #expect(v.raw == 7)
        #expect(v.formatted == "")
    }
}
