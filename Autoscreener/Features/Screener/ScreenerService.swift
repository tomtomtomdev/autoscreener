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
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ScreenerError.malformedResponse
        }
        // Try common envelopes:
        //   { data: [rows] }, { data: { data: [rows], total } }, { rows: [...] }, top-level [...]
        let rowsArray: [[String: Any]]
        var total: Int? = nil

        if let arr = json["data"] as? [[String: Any]] {
            rowsArray = arr
        } else if let inner = json["data"] as? [String: Any] {
            rowsArray = (inner["data"] as? [[String: Any]]) ?? (inner["rows"] as? [[String: Any]]) ?? []
            total = inner["total"] as? Int
        } else if let arr = json["rows"] as? [[String: Any]] {
            rowsArray = arr
            total = json["total"] as? Int
        } else {
            throw ScreenerError.malformedResponse
        }

        let rows = rowsArray.map { row(from: $0, sequence: sequence) }
        return ScreenerPage(rows: rows, total: total, page: page)
    }

    /// Build a ScreenerRow from a row dict — tolerant of several field names and value layouts.
    /// Shared with ScreenerTemplateService for the page-1 rows embedded in the GET response.
    static func row(from dict: [String: Any], sequence: [Int]) -> ScreenerRow {
        let symbol = (dict["symbol"] as? String)
            ?? (dict["ticker"] as? String)
            ?? (dict["code"] as? String) ?? "?"
        let name = (dict["name"] as? String)
            ?? (dict["company_name"] as? String) ?? ""
        let values: [Double?] = sequence.map { id in
            if let arr = dict["values"] as? [Any], let idx = sequence.firstIndex(of: id), idx < arr.count {
                return asDouble(arr[idx])
            }
            return asDouble(dict[String(id)])
        }
        let last = asDouble(dict["last_price"])
            ?? asDouble(dict["last"])
            ?? asDouble(dict["price"])
            ?? asDouble(dict["close"])
        let change = asDouble(dict["pct_change"])
            ?? asDouble(dict["change_pct"])
            ?? asDouble(dict["change_percent"])
            ?? asDouble(dict["percent_change"])
        return ScreenerRow(symbol: symbol, name: name, values: values, lastPrice: last, pctChange: change)
    }

    private static func asDouble(_ v: Any?) -> Double? {
        switch v {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let s as String: return Double(s)
        default: return nil
        }
    }
}
