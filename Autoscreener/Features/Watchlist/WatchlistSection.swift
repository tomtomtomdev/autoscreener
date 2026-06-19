import SwiftUI

/// The composite Watchlist rendered as a **section** of plain, scrollable rows (not a `Table`), so it
/// can sit beneath the Recommendations inbox inside one shared `ScrollView` (the merged "Recommendations"
/// screen). It is a thin projection over `WatchlistViewModel` — the same store-backed VM the standalone
/// screen used — and keeps the row accessibility ids (`watchlist.stockcode-<TICKER>` /
/// `watchlist.screeners-<TICKER>`) so the existing UI tests still target the same rows.
///
/// Rows arrive pre-sorted by composite score (desc) from `WatchlistComposer`, so dropping the `Table`
/// loses no interactive sorting (the `Table` exposed none). A `LazyVStack` keeps the long IHSG list cheap.
struct WatchlistSection: View {
    var vm: WatchlistViewModel
    /// Tapping a row's stock code asks the host to push the financial detail (the host owns the
    /// `NavigationStack` destination, so this section stays navigation-agnostic).
    let onSelect: (StockTicker) -> Void
    /// Tapping a row's screener icon asks the host to push that screener's full results list.
    let onSelectScreener: (BandarScreenerKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let msg = vm.paywallMessage {
                paywallBanner(msg)
            }
            content
            statusBar
        }
        .accessibilityIdentifier("WatchlistSection")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Watchlist").font(.title3.bold())
                HStack(spacing: 6) {
                    Text("Composite Bandar score · max \(formatScore(BandarScreenerKind.maxCompositeScore))")
                    if let asOf = vm.lastFetchedAt {
                        Text("·")
                        Text("as of \(asOfText(asOf))")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func paywallBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal).padding(.vertical, 6)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var content: some View {
        let rows = vm.visibleRows
        if let error = vm.error, vm.rows.isEmpty {
            ContentUnavailableView("Couldn't load watchlist",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else if vm.rows.isEmpty && !vm.isLoading {
            ContentUnavailableView("No matches",
                                   systemImage: "tablecells",
                                   description: Text("None of the bandar screeners returned rows in IHSG."))
        } else if rows.isEmpty && !vm.searchText.isEmpty {
            ContentUnavailableView.search(text: vm.searchText)
        } else {
            LazyVStack(spacing: 0) {
                WatchlistColumnHeader()
                Divider()
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    WatchlistRowView(rank: index + 1, row: row,
                                     onSelect: onSelect, onSelectScreener: onSelectScreener)
                    if row.id != rows.last?.id { Divider() }
                }
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if let error = vm.error, !vm.rows.isEmpty {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            if let notice = vm.vetoNotice, !vm.rows.isEmpty {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary).font(.callout)
                    .help("These liquidity gates weren't refreshed this cycle, so no ILLIQUID flag is applied for them.")
            }
            Spacer()
            if !vm.rows.isEmpty {
                Text(rowCountText).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var rowCountText: String {
        if !vm.searchText.isEmpty {
            return "\(vm.visibleRows.count) of \(vm.rows.count) rows match"
        }
        return "\(vm.rows.count) rows"
    }
}

/// Fixed-width column labels above the watchlist rows. The widths match `WatchlistRowView` so the plain
/// rows line up like the old `Table` columns did.
private struct WatchlistColumnHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("No").frame(width: WatchlistRowMetrics.rank, alignment: .trailing)
            Text("Symbol").frame(width: WatchlistRowMetrics.symbol, alignment: .leading)
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            Text("Screeners").frame(width: WatchlistRowMetrics.screeners, alignment: .leading)
            Text("Score").frame(width: WatchlistRowMetrics.score, alignment: .trailing)
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.vertical, 4)
    }
}

/// One plain watchlist row — rank · tappable symbol · name · score · screener-icon strip. Mirrors the
/// columns the removed `Table` rendered, preserving the row accessibility ids the UI tests target.
struct WatchlistRowView: View {
    let rank: Int
    let row: WatchlistRow
    let onSelect: (StockTicker) -> Void
    let onSelectScreener: (BandarScreenerKind) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .monospacedDigit().foregroundStyle(.secondary)
                .frame(width: WatchlistRowMetrics.rank, alignment: .trailing)

            Button {
                onSelect(StockTicker(symbol: row.symbol, name: row.name))
            } label: {
                Text(row.symbol).monospaced()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("watchlist.stockcode-\(row.symbol)")
            .help("View \(row.symbol) financials")
            .frame(width: WatchlistRowMetrics.symbol, alignment: .leading)

            Text(row.name)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            ScreenerIconStrip(kinds: row.matchedScreeners, onSelect: onSelectScreener)
                .accessibilityIdentifier("watchlist.screeners-\(row.symbol)")
                .frame(width: WatchlistRowMetrics.screeners, alignment: .leading)

            Text(formatScore(row.score))
                .monospacedDigit()
                .frame(width: WatchlistRowMetrics.score, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// Shared column widths so the header and the rows align like the old `Table`.
private enum WatchlistRowMetrics {
    static let rank: CGFloat = 32
    static let symbol: CGFloat = 56
    static let score: CGFloat = 56
    static let screeners: CGFloat = 200
}

// MARK: - Formatting (file-private, shared by the section + its rows)

private func formatScore(_ v: Double) -> String {
    // Weights are scaled so every matched-weight sum is a whole number — show it as one.
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.minimumFractionDigits = 0
    f.maximumFractionDigits = 0
    return f.string(from: NSNumber(value: v)) ?? String(v)
}

private func asOfText(_ date: Date) -> String {
    let f = DateFormatter()
    f.timeStyle = .short
    f.dateStyle = .none
    if Calendar.current.isDateInToday(date) { return f.string(from: date) }
    f.dateStyle = .short
    return f.string(from: date)
}
