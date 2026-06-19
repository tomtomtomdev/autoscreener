import Foundation

// Dynamic IDX index-membership source. Stockbit models the IDX indices as subsectors of
// sector 88 ("Indeks"): subsector 467=IHSG, 550=LQ45, 555=KOMPAS100, 559=IDX30, … The
// company list under an index's subsector is that index's live constituent set, so one
// call returns all members — no per-constituent `/info` fan-out, and no hand-maintained
// rebalance config that silently goes stale (the committed LQ45 seed had already drifted:
// it listed GGRM/TBIG, which are no longer even in KOMPAS100, and LQ45 ⊂ KOMPAS100).
//
// Wire shape verified against the KOMPAS100 capture (2026-06-20):
//   GET /emitten/v3/sector/88/subsector/555/company → { data: [ { symbol, … } ×100 ] }.

/// An IDX index addressable by its sector-88 subsector id.
nonisolated enum IDXIndex: String, Sendable, CaseIterable {
    case ihsg, lq45, kompas100, idx30

    /// The subsector id (under sector 88, "Indeks") whose company list *is* this index's
    /// membership. Captured from `/emitten/sectors/88/subsectors` (2026-06-20).
    var subsectorId: String {
        switch self {
        case .ihsg: "467"
        case .lq45: "550"
        case .kompas100: "555"
        case .idx30: "559"
        }
    }
}

nonisolated enum IndexConstituentsError: Error, Equatable {
    case unauthorized
    case paywall
    case network(String)
    case malformedResponse
}

nonisolated protocol IndexConstituentsServicing: Sendable {
    func constituents(of index: IDXIndex) async throws -> [String]
}

nonisolated final class IndexConstituentsService: IndexConstituentsServicing {
    /// Sector 88 = "Indeks", the parent of every IDX index subsector (captured from
    /// `/emitten/sectors`).
    static let indexSectorId = "88"

    private let apiClient: APIClient
    init(apiClient: APIClient) { self.apiClient = apiClient }

    func constituents(of index: IDXIndex) async throws -> [String] {
        let data = try await fetch(Self.endpoint(subsectorId: index.subsectorId))
        do { return try Self.parse(data) } catch { throw IndexConstituentsError.malformedResponse }
    }

    /// Shared transport + error mapping (mirrors `EmittenService`).
    private func fetch(_ endpoint: Endpoint) async throws -> Data {
        do {
            return try await apiClient.sendRaw(endpoint)
        } catch APIError.unauthorized, APIError.notSignedIn {
            throw IndexConstituentsError.unauthorized
        } catch APIError.http(let status, _) where status == 402 || status == 403 {
            throw IndexConstituentsError.paywall
        } catch let err as APIError {
            throw IndexConstituentsError.network(String(describing: err))
        }
    }

    // MARK: - Wire format

    static func endpoint(subsectorId: String) -> Endpoint {
        Endpoint(method: .get, path: "emitten/v3/sector/\(indexSectorId)/subsector/\(subsectorId)/company")
    }

    /// The member symbols in feed order. Tolerant: a `data` block that's absent or empty
    /// yields `[]` (the breadth factor then drops gracefully); only a non-JSON body throws.
    static func parse(_ data: Data) throws -> [String] {
        let dto = try JSONDecoder().decode(ResponseDTO.self, from: data)
        return dto.data.map(\.symbol).filter { !$0.isEmpty }
    }

    private nonisolated struct ResponseDTO: Decodable {
        let data: [Company]

        enum CodingKeys: String, CodingKey { case data }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            data = (try? c.decode([Company].self, forKey: .data)) ?? []
        }

        nonisolated struct Company: Decodable {
            let symbol: String

            enum CodingKeys: String, CodingKey { case symbol }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                symbol = (try? c.decode(String.self, forKey: .symbol)) ?? ""
            }
        }
    }
}
