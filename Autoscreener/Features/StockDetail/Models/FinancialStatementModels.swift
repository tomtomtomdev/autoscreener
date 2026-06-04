import Foundation

/// Which financial statement to fetch. Raw value is Stockbit's `report_type`
/// query parameter on `findata-view/v2/financials/{symbol}`.
nonisolated enum FinancialReportType: Int, CaseIterable, Hashable, Sendable {
    case income = 1
    case balanceSheet = 2
    case cashFlow = 3

    var title: String {
        switch self {
        case .income:       return "Income Statement"
        case .balanceSheet: return "Balance Sheet"
        case .cashFlow:     return "Cash Flow"
        }
    }

    /// Compact label for the segmented picker.
    var shortTitle: String {
        switch self {
        case .income:       return "Income"
        case .balanceSheet: return "Balance"
        case .cashFlow:     return "Cash Flow"
        }
    }
}

/// Annual vs. quarterly periods. Raw value is Stockbit's `statement_type`
/// query parameter (1 = quarterly `Q1 2026…`, 2 = annual `12M 2025…`).
nonisolated enum FinancialPeriodBasis: Int, CaseIterable, Hashable, Sendable {
    case quarterly = 1
    case annual = 2

    var title: String {
        switch self {
        case .quarterly: return "Quarterly"
        case .annual:    return "Annual"
        }
    }
}

/// The navigation value pushed when a stock code is tapped. Carries the company
/// name already present on the tapped row, so the detail screen needs no extra
/// `/emitten/{symbol}/info` round-trip.
nonisolated struct StockTicker: Identifiable, Hashable, Sendable {
    let symbol: String
    let name: String
    var id: String { symbol }
}

/// One line item in a financial statement. The tree is recursive via `children`
/// (Stockbit nests up to ~5 levels). `values` are the server's pre-formatted
/// display strings, parallel to `FinancialStatement.periods` by index.
nonisolated struct FinancialAccount: Identifiable, Hashable, Sendable {
    /// Positional path id, e.g. "0", "0.2", "0.2.1". Unique even when two sibling
    /// subtrees reuse the same server `accountID` (e.g. "Pihak Berelasi" id=6
    /// appears under several parents).
    let id: String
    /// Stockbit's own account id (not unique within a statement).
    let accountID: Int
    /// Display name with any `<b>`/`<B>` emphasis tags stripped.
    let name: String
    let level: Int
    let values: [String]
    /// True when the server wrapped the name in bold tags — section headers and
    /// total rows (e.g. "Pendapatan", "Laba Kotor", "Aset").
    let isEmphasized: Bool
    /// The server's `is_default_expanded` hint for this node.
    let defaultExpanded: Bool
    let children: [FinancialAccount]
}

/// A fully decoded financial statement: the period columns plus the account tree.
nonisolated struct FinancialStatement: Hashable, Sendable {
    let currency: String
    let periods: [String]
    let accounts: [FinancialAccount]

    /// Every node that has children — the full set of expandable rows. Used by the
    /// view model to expand everything when the server's defaults would hide data.
    var allExpandableIDs: Set<String> {
        var ids: Set<String> = []
        func walk(_ accounts: [FinancialAccount]) {
            for a in accounts where !a.children.isEmpty {
                ids.insert(a.id)
                walk(a.children)
            }
        }
        walk(accounts)
        return ids
    }

    /// Nodes the server marked `is_default_expanded`. The view model seeds the
    /// initial expansion from this so the detail opens matching Stockbit's layout.
    var defaultExpandedIDs: Set<String> {
        var ids: Set<String> = []
        func walk(_ accounts: [FinancialAccount]) {
            for a in accounts {
                if a.defaultExpanded && !a.children.isEmpty { ids.insert(a.id) }
                walk(a.children)
            }
        }
        walk(accounts)
        return ids
    }

    /// Depth-first flatten of the visible tree. A node's children are emitted only
    /// when its id is in `expanded`; everything else stays collapsed. Pure — the
    /// view renders the returned rows directly.
    func flattened(expanded: Set<String>) -> [FinancialRow] {
        var out: [FinancialRow] = []
        func walk(_ accounts: [FinancialAccount], depth: Int) {
            for acct in accounts {
                let hasChildren = !acct.children.isEmpty
                let isExpanded = hasChildren && expanded.contains(acct.id)
                out.append(FinancialRow(
                    id: acct.id,
                    name: acct.name,
                    depth: depth,
                    values: acct.values,
                    isEmphasized: acct.isEmphasized,
                    hasChildren: hasChildren,
                    isExpanded: isExpanded))
                if isExpanded { walk(acct.children, depth: depth + 1) }
            }
        }
        walk(accounts, depth: 0)
        return out
    }
}

/// A flattened, render-ready row produced by `FinancialStatement.flattened`.
nonisolated struct FinancialRow: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let depth: Int
    let values: [String]
    let isEmphasized: Bool
    let hasChildren: Bool
    let isExpanded: Bool

    /// A pure spacer the server emits between sections (empty name, no values, no
    /// children). Rendered as a blank gap.
    var isSpacer: Bool { name.isEmpty && values.isEmpty && !hasChildren }
}
