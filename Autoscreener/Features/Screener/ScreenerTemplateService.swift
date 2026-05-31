import Foundation

nonisolated protocol ScreenerTemplateServicing: Sendable {
    func load(templateID: String) async throws -> ScreenerConfig
}

nonisolated final class ScreenerTemplateService: ScreenerTemplateServicing {
    private let apiClient: APIClient
    init(apiClient: APIClient) { self.apiClient = apiClient }

    func load(templateID: String) async throws -> ScreenerConfig {
        let endpoint = Endpoint(
            method: .get,
            path: "screener/templates/\(templateID)",
            query: [URLQueryItem(name: "limit", value: "25"),
                    URLQueryItem(name: "type", value: "TEMPLATE_TYPE_CUSTOM")]
        )
        let data = try await apiClient.sendRaw(endpoint)
        return try Self.parse(data, templateID: templateID)
    }

    static func parse(_ data: Data, templateID: String) throws -> ScreenerConfig {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ScreenerError.malformedResponse
        }
        let payload = (json["data"] as? [String: Any]) ?? json

        let name = (payload["name"] as? String) ?? "screener"
        let description = (payload["description"] as? String) ?? ""

        // filters & universe arrive as JSON-encoded strings, same shape as the request body.
        let filters: [ScreenerFilter] = parseFilters(payload["filters"])
        let universe: ScreenerUniverse = parseUniverse(payload["universe"]) ?? .ihsg

        // sequence may be a comma-separated string OR an array of ints.
        let sequence: [Int] = parseSequence(payload["sequence"])

        let orderColumn = (payload["ordercol"] as? Int) ?? (payload["order_col"] as? Int) ?? 2
        let orderType = (payload["ordertype"] as? String) ?? (payload["order_type"] as? String) ?? "desc"
        let limit = (payload["limit"] as? Int) ?? 25

        var config = ScreenerConfig()
        config.name = name
        config.description = description
        config.filters = filters.isEmpty ? ScreenerFilter.bandarValueAboveMA20 : filters
        config.universe = universe
        config.sequence = sequence.isEmpty ? [14399, 14426] : sequence
        config.orderColumn = orderColumn
        config.orderType = orderType
        config.limit = limit
        config.screenerID = templateID
        return config
    }

    private static func parseFilters(_ raw: Any?) -> [ScreenerFilter] {
        // `filters` may be: a String (JSON-encoded), or an array of dicts already.
        if let str = raw as? String, let d = str.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {
            return arr.compactMap(filter(from:))
        }
        if let arr = raw as? [[String: Any]] {
            return arr.compactMap(filter(from:))
        }
        return []
    }

    private static func filter(from dict: [String: Any]) -> ScreenerFilter? {
        guard let typeRaw = dict["type"] as? String,
              let type = ScreenerFilter.FilterType(rawValue: typeRaw),
              let op = dict["operator"] as? String,
              let item1 = dict["item1"] as? Int
        else { return nil }
        return ScreenerFilter(
            type: type,
            operator_: op,
            item1: item1,
            item1_name: (dict["item1_name"] as? String) ?? "",
            item2: stringValue(dict["item2"]) ?? "",
            item2_name: (dict["item2_name"] as? String) ?? "",
            multiplier: stringValue(dict["multiplier"]) ?? "0"
        )
    }

    private static func stringValue(_ any: Any?) -> String? {
        switch any {
        case let s as String: return s
        case let i as Int: return String(i)
        case let d as Double: return String(d)
        default: return nil
        }
    }

    private static func parseUniverse(_ raw: Any?) -> ScreenerUniverse? {
        if let str = raw as? String, let d = str.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            return universe(from: dict)
        }
        if let dict = raw as? [String: Any] {
            return universe(from: dict)
        }
        return nil
    }

    private static func universe(from dict: [String: Any]) -> ScreenerUniverse? {
        guard let scope = dict["scope"] as? String else { return nil }
        let scopeID = stringValue(dict["scopeID"]) ?? stringValue(dict["scope_id"]) ?? "0"
        let name = (dict["name"] as? String) ?? scope
        return ScreenerUniverse(scopeID: scopeID, name: name, scope: scope)
    }

    private static func parseSequence(_ raw: Any?) -> [Int] {
        if let s = raw as? String {
            return s.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        }
        if let arr = raw as? [Int] { return arr }
        if let arr = raw as? [String] { return arr.compactMap(Int.init) }
        return []
    }
}
