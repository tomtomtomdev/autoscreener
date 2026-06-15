import Foundation

// Reads Stockbit's per-company metadata, two endpoints under `/emitten/{SYMBOL}`:
//   GET /emitten/{SYMBOL}/info     → sector / sub-sector / index memberships
//   GET /emitten/{SYMBOL}/profile  → public free float + listed-share count
//
// These are the §1.4 company-level fields the selection engine needs that no other wired endpoint
// carries: `sector` (drives the §1.5 sector→IDX-index map and the §14 bank archetype classifier)
// and `freeFloatPct` (the `LiquidityGate` floor). Wire shapes verified against the WIFI capture
// (2026-06-06). Values stay as their raw display strings here; `SelectionFundamentals` does the
// typed conversion so the string→number parsing is unit-tested at the engine boundary.

/// `GET /emitten/{SYMBOL}/info` — the company's taxonomy. `sector`/`subSector` are the Indonesian
/// display names ("Teknologi", "Perangkat Lunak & Jasa TI"); `indexes` lists index memberships
/// (e.g. "IDXTECHNO", "LQ45").
nonisolated struct EmittenInfo: Sendable, Equatable {
    let symbol: String
    let name: String
    let sector: String
    let subSector: String
    let indexes: [String]
}

/// `GET /emitten/{SYMBOL}/profile` — public ownership snapshot. Values are display strings.
/// `sharesDisplay` is a history snapshot that can lag corporate actions (rights issues), so the
/// engine derives shares from keystats (NetIncome÷EPS) instead and keeps this only as a cross-check.
nonisolated struct EmittenProfile: Sendable, Equatable {
    /// Public free float, e.g. "40.00%". nil when the field is absent.
    let freeFloatDisplay: String?
    /// Listed share count, e.g. "156,558,200". nil when absent.
    let sharesDisplay: String?
}

nonisolated enum EmittenError: Error, Equatable {
    case unauthorized
    case paywall
    case network(String)
    case malformedResponse
}

nonisolated protocol EmittenServicing: Sendable {
    func info(symbol: String) async throws -> EmittenInfo
    func profile(symbol: String) async throws -> EmittenProfile
}

nonisolated final class EmittenService: EmittenServicing {
    private let apiClient: APIClient
    init(apiClient: APIClient) { self.apiClient = apiClient }

    func info(symbol: String) async throws -> EmittenInfo {
        let data = try await fetch(Self.infoEndpoint(symbol: symbol))
        do { return try Self.parseInfo(data) } catch { throw EmittenError.malformedResponse }
    }

    func profile(symbol: String) async throws -> EmittenProfile {
        let data = try await fetch(Self.profileEndpoint(symbol: symbol))
        do { return try Self.parseProfile(data) } catch { throw EmittenError.malformedResponse }
    }

    /// Shared transport + error mapping (mirrors the other `exodus` services).
    private func fetch(_ endpoint: Endpoint) async throws -> Data {
        do {
            return try await apiClient.sendRaw(endpoint)
        } catch APIError.unauthorized, APIError.notSignedIn {
            throw EmittenError.unauthorized
        } catch APIError.http(let status, _) where status == 402 || status == 403 {
            throw EmittenError.paywall
        } catch let err as APIError {
            throw EmittenError.network(String(describing: err))
        }
    }

    // MARK: - Wire format

    static func infoEndpoint(symbol: String) -> Endpoint {
        Endpoint(method: .get, path: "emitten/\(symbol)/info")
    }

    static func profileEndpoint(symbol: String) -> Endpoint {
        Endpoint(method: .get, path: "emitten/\(symbol)/profile")
    }

    static func parseInfo(_ data: Data) throws -> EmittenInfo {
        let dto = try JSONDecoder().decode(InfoResponseDTO.self, from: data)
        return EmittenInfo(
            symbol: dto.data.symbol,
            name: dto.data.name,
            sector: dto.data.sector,
            subSector: dto.data.subSector,
            indexes: dto.data.indexes)
    }

    static func parseProfile(_ data: Data) throws -> EmittenProfile {
        let dto = try JSONDecoder().decode(ProfileResponseDTO.self, from: data)
        return EmittenProfile(
            freeFloatDisplay: dto.data.history?.freeFloat,
            sharesDisplay: dto.data.history?.shares)
    }
}

// MARK: - DTOs

/// `GET /emitten/{SYMBOL}/info`. Fields are decoded tolerantly (default to empty) so a minor schema
/// drift degrades to blanks rather than failing the whole parse; only a non-JSON body / missing
/// `data` envelope is treated as malformed.
private nonisolated struct InfoResponseDTO: Decodable {
    let data: DataDTO

    nonisolated struct DataDTO: Decodable {
        let symbol: String
        let name: String
        let sector: String
        let subSector: String
        let indexes: [String]

        enum CodingKeys: String, CodingKey {
            case symbol, name, sector, indexes
            case subSector = "sub_sector"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            symbol = (try? c.decode(String.self, forKey: .symbol)) ?? ""
            name = (try? c.decode(String.self, forKey: .name)) ?? ""
            sector = (try? c.decode(String.self, forKey: .sector)) ?? ""
            subSector = (try? c.decode(String.self, forKey: .subSector)) ?? ""
            indexes = (try? c.decode([String].self, forKey: .indexes)) ?? []
        }
    }
}

/// `GET /emitten/{SYMBOL}/profile`. Only the `history.{free_float, shares}` display strings are read.
private nonisolated struct ProfileResponseDTO: Decodable {
    let data: DataDTO

    nonisolated struct DataDTO: Decodable {
        let history: HistoryDTO?
    }
    nonisolated struct HistoryDTO: Decodable {
        let freeFloat: String?
        let shares: String?
        enum CodingKeys: String, CodingKey {
            case shares
            case freeFloat = "free_float"
        }
    }
}
