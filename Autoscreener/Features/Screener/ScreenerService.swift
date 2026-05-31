import Foundation

nonisolated enum ScreenerError: Error, Equatable {
    case unauthorized
    case paywall
    case network(String)
    case malformedResponse
}

nonisolated protocol ScreenerServicing: Sendable {
    func run(_ config: ScreenerConfig, page: Int) async throws -> ScreenerPage
}

nonisolated final class ScreenerService: ScreenerServicing {
    private let apiClient: APIClient
    init(apiClient: APIClient) { self.apiClient = apiClient }

    func run(_ config: ScreenerConfig, page: Int) async throws -> ScreenerPage {
        let body = try Self.encodeRunBody(config, page: page)
        let endpoint = Endpoint(method: .post, path: "screener/templates", body: body)
        let data: Data
        do {
            data = try await apiClient.sendRaw(endpoint)
        } catch APIError.unauthorized, APIError.notSignedIn {
            throw ScreenerError.unauthorized
        } catch APIError.http(let status, _) where status == 402 || status == 403 {
            throw ScreenerError.paywall
        } catch let err as APIError {
            throw ScreenerError.network(String(describing: err))
        }
        do {
            return try Self.decodeResponse(data, sequence: config.sequence, page: page)
        } catch {
            throw ScreenerError.malformedResponse
        }
    }

    // MARK: - Wire format

    static func encodeRunBody(_ config: ScreenerConfig, page: Int) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let filtersData = try encoder.encode(config.filters)
        let universeData = try encoder.encode(config.universe)

        let dict: [String: Any] = [
            "save": "0",
            "limit": config.limit,
            "page": page,
            "ordercol": config.orderColumn,
            "ordertype": config.orderType,
            "sequence": config.sequence.map(String.init).joined(separator: ","),
            "filters": String(data: filtersData, encoding: .utf8) ?? "[]",
            "universe": String(data: universeData, encoding: .utf8) ?? "{}",
            "type": "TEMPLATE_TYPE_CUSTOM",
            "name": config.name,
            "description": config.description,
            "screenerid": config.screenerID,
        ]
        return try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    }

    static func decodeResponse(_ data: Data, sequence: [Int], page: Int) throws -> ScreenerPage {
        // Primary path: real Stockbit envelope via Codable.
        if let dto = try? JSONDecoder().decode(ScreenerResponseDTO.self, from: data),
           let calcs = dto.data.calcs {
            let rows = calcs.map { $0.toRow(sequence: sequence) }
            return ScreenerPage(rows: rows, total: dto.data.total, page: page)
        }

        // Fallback path: tolerate legacy / sibling shapes via dict-walking, in case
        // some endpoint we haven't seen yet ships a different envelope.
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ScreenerError.malformedResponse
        }
        let rowsArray: [[String: Any]]
        var total: Int? = nil
        if let inner = json["data"] as? [String: Any] {
            rowsArray = (inner["calcs"] as? [[String: Any]])
                ?? (inner["data"] as? [[String: Any]])
                ?? (inner["rows"] as? [[String: Any]])
                ?? (inner["results"] as? [[String: Any]])
                ?? []
            total = (inner["total"] as? Int) ?? (inner["total_count"] as? Int)
        } else if let arr = json["data"] as? [[String: Any]] {
            rowsArray = arr
        } else if let arr = json["rows"] as? [[String: Any]] {
            rowsArray = arr
            total = json["total"] as? Int
        } else if let arr = json["calcs"] as? [[String: Any]] {
            rowsArray = arr
        } else {
            throw ScreenerError.malformedResponse
        }
        let rows = rowsArray.map { row(from: $0, sequence: sequence) }
        return ScreenerPage(rows: rows, total: total, page: page)
    }

    /// Build a ScreenerRow from a row dict — tolerant of several field names and value layouts.
    /// Shared with ScreenerTemplateService for the page-1 rows embedded in the GET response.
    ///
    /// Stockbit's actual shape (confirmed 2026-05-31) is:
    ///   { "company": { "symbol", "name", … },
    ///     "results": [ { "id": 14399, "item": "Bandar Value", "raw": "14925216921719.91", "display": "14,925.22 B" }, … ] }
    /// We also tolerate flatter variants in case other endpoints use them.
    static func row(from dict: [String: Any], sequence: [Int]) -> ScreenerRow {
        let company = dict["company"] as? [String: Any] ?? [:]

        let symbol = (dict["symbol"] as? String)
            ?? (company["symbol"] as? String)
            ?? (dict["ticker"] as? String)
            ?? (company["ticker"] as? String)
            ?? (dict["code"] as? String) ?? "?"
        let name = (dict["name"] as? String)
            ?? (company["name"] as? String)
            ?? (dict["company_name"] as? String) ?? ""

        // Build a metric-id → Double map from "results" if present.
        let resultsByID: [Int: Double] = {
            guard let results = dict["results"] as? [[String: Any]] else { return [:] }
            var map: [Int: Double] = [:]
            for r in results {
                guard let id = r["id"] as? Int else { continue }
                if let d = asDouble(r["raw"]) ?? asDouble(r["value"]) ?? asDouble(r["display"]) {
                    map[id] = d
                }
            }
            return map
        }()

        let values: [Double?] = sequence.map { id in
            // 1. Stockbit: results[].id == metric id, .raw is a decimal string
            if let v = resultsByID[id] { return v }
            // 2. parallel values array
            if let arr = dict["values"] as? [Any], let idx = sequence.firstIndex(of: id), idx < arr.count {
                return asDouble(arr[idx])
            }
            // 3. id-keyed flat layout
            return asDouble(dict[String(id)])
        }

        let last = asDouble(dict["last_price"])
            ?? asDouble(company["last_price"])
            ?? asDouble(dict["last"])
            ?? asDouble(dict["price"])
            ?? asDouble(dict["close"])
        let change = asDouble(dict["pct_change"])
            ?? asDouble(company["pct_change"])
            ?? asDouble(dict["change_pct"])
            ?? asDouble(dict["change_percent"])
            ?? asDouble(dict["percent_change"])

        return ScreenerRow(symbol: symbol, name: name, values: values, lastPrice: last, pctChange: change)
    }

    static func asDouble(_ v: Any?) -> Double? {
        switch v {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let s as String: return Double(s)
        default: return nil
        }
    }
}
