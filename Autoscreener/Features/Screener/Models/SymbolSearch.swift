import Foundation

/// A row that can be searched by its stock code. Both `ScreenerRow` and
/// `WatchlistRow` already carry a `symbol`, so conformance is empty.
protocol SymbolSearchable {
    var symbol: String { get }
}

extension ScreenerRow: SymbolSearchable {}
extension WatchlistRow: SymbolSearchable {}

extension Array where Element: SymbolSearchable {
    /// Filters rows by a case-insensitive substring match on the stock code.
    /// A blank/whitespace-only query returns the array unchanged. Matches the
    /// `symbol` only — company name is intentionally not searched.
    func filteredBySymbol(_ query: String) -> [Element] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return self }
        let needle = trimmed.uppercased()
        return filter { $0.symbol.uppercased().contains(needle) }
    }
}
