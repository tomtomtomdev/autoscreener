import SwiftUI

struct WatchlistView: View {
    @Bindable var vm: WatchlistViewModel
    let title: String

    /// Set when a stock code is tapped — drives the push to `StockDetailView`.
    @State private var selectedTicker: StockTicker?

    init(vm: WatchlistViewModel, title: String = "Watchlist") {
        self.vm = vm
        self.title = title
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                toolbar
                if let msg = vm.paywallMessage {
                    paywallBanner(msg)
                }
                Divider()
                content
                Divider()
                statusBar
            }
            .frame(minWidth: 720, minHeight: 480)
            .searchable(text: $vm.searchText, placement: .toolbar, prompt: "Search stock code")
            .task { await vm.autoRunIfNeeded() }
            .navigationDestination(item: $selectedTicker) { ticker in
                StockDetailView(ticker: ticker)
            }
        }
    }

    private var toolbar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
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
            if vm.isLoading {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await vm.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refetch every screener live and rebuild the composite")
            .disabled(vm.isLoading)
        }
        .padding()
    }

    private func asOfText(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        if Calendar.current.isDateInToday(date) { return f.string(from: date) }
        f.dateStyle = .short
        return f.string(from: date)
    }

    @ViewBuilder
    private func paywallBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal).padding(.vertical, 6)
        .background(Color.orange.opacity(0.1))
    }

    @ViewBuilder
    private var content: some View {
        if let error = vm.error, vm.rows.isEmpty {
            ContentUnavailableView("Couldn't load watchlist",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else if vm.rows.isEmpty && !vm.isLoading {
            ContentUnavailableView("No matches",
                                   systemImage: "tablecells",
                                   description: Text("None of the bandar screeners returned rows in IHSG."))
        } else if vm.visibleRows.isEmpty && !vm.searchText.isEmpty {
            ContentUnavailableView.search(text: vm.searchText)
        } else {
            resultsTable
        }
    }

    private var resultsTable: some View {
        let rows = vm.visibleRows
        return Table(rows) {
            TableColumn("No") { row in
                if let i = rows.firstIndex(where: { $0.id == row.id }) {
                    Text("\(i + 1)").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            // Row index never exceeds the IHSG universe (~900 rows), so 4 digits
            // is the most it ever shows — pin it so the column can't grow wider.
            .width(44)

            TableColumn("Symbol") { row in
                Button {
                    selectedTicker = StockTicker(symbol: row.symbol, name: row.name)
                } label: {
                    Text(row.symbol).monospaced()
                        .foregroundStyle(row.isVetoed ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                }
                .buttonStyle(.plain)
                .help("View \(row.symbol) financials")
            }
            // IDX tickers are 4 letters (occasionally 5) — pin to 5 monospaced
            // chars so the code column stays tight and doesn't steal width.
            .width(60)

            TableColumn("Name") { row in
                Text(row.name)
                    .foregroundStyle(row.isVetoed ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            }
            .width(min: 160, ideal: 240)

            TableColumn("Score") { row in
                Text(formatScore(row.score)).monospacedDigit()
            }
            .width(min: 60, ideal: 80)

            TableColumn("Flag") { row in
                if row.isVetoed {
                    Label("ILLIQUID", systemImage: "exclamationmark.octagon.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                        .help(vetoReason(row))
                }
            }
            .width(min: 110, ideal: 130)
        }
    }

    /// Lists which veto gates the row fails (e.g. "Fails: Liquidity Floor, Intraday Liquidity").
    /// Shown as a tooltip on the ILLIQUID badge so the user can see *why* without
    /// adding more columns. Reads the materialized `failedVetoGates` so it reflects
    /// only the gates that were actually evaluated.
    private func vetoReason(_ row: WatchlistRow) -> String {
        let missing = row.failedVetoGates.map(\.displayName).sorted()
        return missing.isEmpty ? "" : "Fails: \(missing.joined(separator: ", "))"
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
        .padding(.horizontal).padding(.vertical, 6)
    }

    private var rowCountText: String {
        if !vm.searchText.isEmpty {
            return "\(vm.visibleRows.count) of \(vm.rows.count) rows match"
        }
        return "\(vm.rows.count) rows"
    }

    private func formatScore(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }
}
