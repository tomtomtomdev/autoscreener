import Foundation

/// Section a market symbol belongs to in the Markets menu.
nonisolated enum MarketGroup: String, CaseIterable, Sendable {
    case composite = "Composite"
    case index = "Indices"
    case sector = "Sectors"
}

/// One chartable market symbol (the composite, an index, or an IDX-IC sector).
/// `symbol` is the exact IDX ticker the `charts/{symbol}/daily` endpoint expects.
nonisolated struct MarketSymbol: Identifiable, Hashable, Sendable {
    let symbol: String
    let name: String
    let group: MarketGroup
    var id: String { symbol }
}

/// Curated, static list of the composite + headline indices + the 11 IDX-IC
/// sectors. Every symbol here was verified live against `charts/{symbol}/daily`
/// (2026-06-04). Kept static on purpose — no extra network call or paywall, and
/// it matches how the screeners are hardcoded in `SidebarItem`.
nonisolated enum MarketCatalog {
    static let all: [MarketSymbol] = [
        // Composite
        MarketSymbol(symbol: "IHSG", name: "Jakarta Composite", group: .composite),

        // Headline indices
        MarketSymbol(symbol: "LQ45", name: "LQ45", group: .index),
        MarketSymbol(symbol: "IDX30", name: "IDX30", group: .index),
        MarketSymbol(symbol: "IDX80", name: "IDX80", group: .index),
        MarketSymbol(symbol: "KOMPAS100", name: "Kompas100", group: .index),
        MarketSymbol(symbol: "JII", name: "Jakarta Islamic Index", group: .index),
        MarketSymbol(symbol: "ISSI", name: "Indonesia Sharia Stock Index", group: .index),
        MarketSymbol(symbol: "IDXBUMN20", name: "IDX BUMN20", group: .index),
        MarketSymbol(symbol: "SRI-KEHATI", name: "SRI-KEHATI", group: .index),

        // IDX-IC sectors (all 11)
        MarketSymbol(symbol: "IDXENERGY", name: "Energy", group: .sector),
        MarketSymbol(symbol: "IDXBASIC", name: "Basic Materials", group: .sector),
        MarketSymbol(symbol: "IDXINDUST", name: "Industrials", group: .sector),
        MarketSymbol(symbol: "IDXNONCYC", name: "Consumer Non-Cyclicals", group: .sector),
        MarketSymbol(symbol: "IDXCYCLIC", name: "Consumer Cyclicals", group: .sector),
        MarketSymbol(symbol: "IDXHEALTH", name: "Healthcare", group: .sector),
        MarketSymbol(symbol: "IDXFINANCE", name: "Financials", group: .sector),
        MarketSymbol(symbol: "IDXPROPERT", name: "Properties & Real Estate", group: .sector),
        MarketSymbol(symbol: "IDXTECHNO", name: "Technology", group: .sector),
        MarketSymbol(symbol: "IDXINFRA", name: "Infrastructures", group: .sector),
        MarketSymbol(symbol: "IDXTRANS", name: "Transportation & Logistic", group: .sector),
    ]

    /// Symbols grouped in `MarketGroup` declaration order, for sectioned lists.
    static func grouped() -> [(MarketGroup, [MarketSymbol])] {
        MarketGroup.allCases.map { group in
            (group, all.filter { $0.group == group })
        }
    }
}
