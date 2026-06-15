import Foundation

/// Codable mirror of `GET findata-view/v2/financials/{symbol}`.
///
/// Confirmed shape (TPIA, 2026-06):
///   { "data": { "default_currency": "IDR",
///               "data_tables": { "periods": ["12M 2025", …],
///                                "accounts": [ <recursive AccountDTO> ] } } }
/// All `values` are pre-formatted display strings ("115,672 B", "(700 B)", "-").
nonisolated struct FinancialsResponseDTO: Decodable, Sendable {
    let data: DataDTO

    struct DataDTO: Decodable, Sendable {
        let defaultCurrency: String?
        let dataTables: TablesDTO

        enum CodingKeys: String, CodingKey {
            case defaultCurrency = "default_currency"
            case dataTables = "data_tables"
        }
    }

    struct TablesDTO: Decodable, Sendable {
        let periods: [String]
        let accounts: [AccountDTO]
    }

    /// Recursive — Swift's synthesized `Decodable` handles self-reference through
    /// the `accounts` array. `values`/`accounts` are tolerated as absent.
    struct AccountDTO: Decodable, Sendable {
        let id: Int
        let level: Int
        let name: String
        let values: [String]
        let accounts: [AccountDTO]
        let isDefaultExpanded: Bool

        enum CodingKeys: String, CodingKey {
            case id, level, name, values, accounts
            case isDefaultExpanded = "is_default_expanded"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? c.decode(Int.self, forKey: .id)) ?? 0
            level = (try? c.decode(Int.self, forKey: .level)) ?? 0
            name = (try? c.decode(String.self, forKey: .name)) ?? ""
            values = (try? c.decode([String].self, forKey: .values)) ?? []
            accounts = (try? c.decode([AccountDTO].self, forKey: .accounts)) ?? []
            isDefaultExpanded = (try? c.decode(Bool.self, forKey: .isDefaultExpanded)) ?? false
        }
    }

    /// Map the wire envelope to the domain model: strip bold tags, flag emphasis,
    /// and assign positional path ids so repeated server ids stay distinct.
    func toDomain() -> FinancialStatement {
        let accounts = data.dataTables.accounts.enumerated().map { index, dto in
            Self.account(from: dto, pathID: String(index))
        }
        return FinancialStatement(
            currency: data.defaultCurrency ?? "",
            periods: data.dataTables.periods,
            accounts: accounts)
    }

    private static func account(from dto: AccountDTO, pathID: String) -> FinancialAccount {
        let children = dto.accounts.enumerated().map { index, child in
            account(from: child, pathID: "\(pathID).\(index)")
        }
        return FinancialAccount(
            id: pathID,
            accountID: dto.id,
            name: stripBold(dto.name),
            level: dto.level,
            values: dto.values,
            isEmphasized: hasBold(dto.name),
            defaultExpanded: dto.isDefaultExpanded,
            children: children)
    }

    /// True when the raw name was wrapped in `<b>`/`<B>` tags (section headers/totals).
    private static func hasBold(_ raw: String) -> Bool {
        raw.range(of: "<b>", options: .caseInsensitive) != nil
    }

    private static func stripBold(_ raw: String) -> String {
        var s = raw
        for tag in ["<b>", "</b>", "<B>", "</B>"] {
            s = s.replacingOccurrences(of: tag, with: "", options: .caseInsensitive)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
