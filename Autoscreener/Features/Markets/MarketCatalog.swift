import Foundation

/// Section a market symbol belongs to in the Markets menu.
nonisolated enum MarketGroup: String, CaseIterable, Sendable {
    case global = "Global"
    case composite = "Composite"
    case index = "Indices"
    case sector = "Sectors"
    case commodity = "Commodities"
    case currency = "Currencies"

    /// Whether symbols in this group have historical OHLCV data to chart.
    /// Commodities and currencies only expose a live price snapshot — there's no
    /// `charts/{symbol}/daily` history for them — so their rows don't navigate.
    var hasChart: Bool {
        switch self {
        case .global, .composite, .index, .sector: true
        case .commodity, .currency: false
        }
    }
}

/// One market symbol — the composite, an index, an IDX-IC sector, a commodity,
/// or a currency. For chartable groups (`group.hasChart`), `symbol` is the exact
/// IDX ticker the `charts/{symbol}/daily` endpoint expects; commodities and
/// currencies only carry a live price snapshot.
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
        // Global indices — Stockbit serves world indices on the same
        // `emitten/{symbol}/info` (snapshot) and `charts/{symbol}/daily` (history)
        // paths as IDX symbols, so they price and chart like the composite. Symbols
        // are from the Stockbit request capture (see memory `regime-macro-data-sources`),
        // pending live `charts/{symbol}/daily` confirmation — unlike the IDX block
        // below, which was verified live 2026-06-04. SP500 already backs the regime's
        // global-equities factor (`RegimeViewModel.globalEquitySymbol`).
        MarketSymbol(symbol: "SP500", name: "S&P 500", group: .global),
        MarketSymbol(symbol: "DOW30", name: "Dow Jones", group: .global),
        MarketSymbol(symbol: "NASDAQ", name: "Nasdaq Composite", group: .global),
        MarketSymbol(symbol: "FTSE", name: "FTSE 100", group: .global),
        MarketSymbol(symbol: "DAX", name: "DAX", group: .global),
        MarketSymbol(symbol: "CAC40", name: "CAC 40", group: .global),
        MarketSymbol(symbol: "NIKKEI", name: "Nikkei 225", group: .global),
        MarketSymbol(symbol: "HANGSENG", name: "Hang Seng", group: .global),
        MarketSymbol(symbol: "KOSPI", name: "KOSPI", group: .global),
        MarketSymbol(symbol: "SHANGHAI", name: "Shanghai Composite", group: .global),
        MarketSymbol(symbol: "STI", name: "Straits Times", group: .global),

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

        // Commodities — names taken from the live `emitten/{symbol}/info` `name`
        // field (2026-06-04). Price snapshot only — no `charts/{symbol}/daily`
        // history, so these rows don't navigate to a detail chart.
        MarketSymbol(symbol: "OIL", name: "Crude Oil", group: .commodity),
        MarketSymbol(symbol: "BRENT", name: "Brent Oil", group: .commodity),
        MarketSymbol(symbol: "GAS", name: "Natural Gas", group: .commodity),
        MarketSymbol(symbol: "COAL-NEWCASTLE", name: "Newcastle Coal", group: .commodity),
        MarketSymbol(symbol: "CPO", name: "Palm Oil", group: .commodity),
        MarketSymbol(symbol: "XAU", name: "Gold", group: .commodity),
        MarketSymbol(symbol: "SILVER", name: "Silver", group: .commodity),
        MarketSymbol(symbol: "NICKEL", name: "Nickel", group: .commodity),
        MarketSymbol(symbol: "COPPER", name: "Copper", group: .commodity),
        MarketSymbol(symbol: "ALUMINIUM", name: "Aluminium", group: .commodity),
        MarketSymbol(symbol: "TIN", name: "Tin", group: .commodity),
        MarketSymbol(symbol: "ZINC-COMMODITIES", name: "Zinc", group: .commodity),
        MarketSymbol(symbol: "RUBBER", name: "Rubber", group: .commodity),

        // Currencies
        MarketSymbol(symbol: "USDIDR", name: "US Dollar / Rupiah", group: .currency),
    ]

    /// Symbols grouped in `MarketGroup` declaration order, for sectioned lists.
    static func grouped() -> [(MarketGroup, [MarketSymbol])] {
        MarketGroup.allCases.map { group in
            (group, all.filter { $0.group == group })
        }
    }
}
