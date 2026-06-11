import SwiftUI

struct ScreenerView: View {
    @Bindable var vm: ScreenerViewModel
    let title: String
    /// Opt-in stock-code search field. Off by default so only the screeners that
    /// want it (Liquidity Floor, Intraday Liquidity) show the search box.
    let enableSearch: Bool

    /// Set when a stock code is tapped — drives the push to `StockDetailView`.
    @State private var selectedTicker: StockTicker?

    init(vm: ScreenerViewModel, title: String, enableSearch: Bool = false) {
        self.vm = vm
        self.title = title
        self.enableSearch = enableSearch
    }

    var body: some View {
        NavigationStack {
            listView
                .navigationDestination(item: $selectedTicker) { ticker in
                    StockDetailView(ticker: ticker)
                }
        }
    }

    @ViewBuilder
    private var listView: some View {
        if enableSearch {
            coreView
                .searchable(text: $vm.searchText, placement: .toolbar, prompt: "Search stock code")
        } else {
            coreView
        }
    }

    private var coreView: some View {
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
        .task { await vm.autoRunIfNeeded() }
    }

    private var toolbar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                HStack(spacing: 6) {
                    Text(vm.config.universe.scope)
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
            .help("Refetch this screener")
            .disabled(vm.isLoading)
        }
        .padding()
    }

    private func asOfText(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        let isToday = Calendar.current.isDateInToday(date)
        if isToday { return f.string(from: date) }
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
            ContentUnavailableView("Couldn't run screener",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else if vm.rows.isEmpty && !vm.isLoading {
            ContentUnavailableView("No matches",
                                   systemImage: "tablecells",
                                   description: Text("\(title) returned no rows in IHSG."))
        } else if vm.visibleRows.isEmpty && !vm.searchText.isEmpty {
            ContentUnavailableView.search(text: vm.searchText)
        } else {
            resultsTable
        }
    }

    private var resultsTable: some View {
        let cols = vm.config.columns
        let firstName = cols.first?.name ?? "Metric 1"
        // Render the filtered view; with an empty search term this is identical to
        // `vm.rows`. The cached snapshot holds the full result set, so there's no
        // pagination — the table renders every matching row at once.
        let visible = vm.visibleRows
        return Table(visible, sortOrder: $vm.sort) {
            TableColumn("No") { row in
                if let i = visible.firstIndex(where: { $0.id == row.id }) {
                    Text("\(i + 1)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            // Row index never exceeds the IHSG universe (~900 rows), so 4 digits
            // is the most it ever shows — pin it so the column can't grow wider.
            .width(44)

            TableColumn("Symbol", value: \.symbol) { row in
                Button {
                    selectedTicker = StockTicker(symbol: row.symbol, name: row.name)
                } label: {
                    Text(row.symbol).monospaced()
                }
                .buttonStyle(.link)
                .accessibilityIdentifier("stockcode-\(row.symbol)")
                .help("View \(row.symbol) financials")
            }
            // IDX tickers are 4 letters (occasionally 5) — pin to 5 monospaced
            // chars so the code column stays tight and doesn't steal width.
            .width(60)

            TableColumn("Name", value: \.name)
                .width(min: 160, ideal: 220)

            TableColumn(firstName) { row in metricCell(row.value(at: 0)) }
            // Render the second metric column only when the screener actually has one.
            // accum-dist-positive's sequence is [14400] (single column) — without this
            // guard the view shows an empty "Metric 2" placeholder.
            if cols.count > 1 {
                TableColumn(cols[1].name) { row in metricCell(row.value(at: 1)) }
            }
        }
    }

    @ViewBuilder
    private func metricCell(_ value: Double?) -> some View {
        if let v = value {
            Text(formatDecimal(v)).monospacedDigit()
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    private var statusBar: some View {
        HStack {
            if let error = vm.error, !vm.rows.isEmpty {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            Spacer()
            if !vm.rows.isEmpty {
                Text(statusText).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private var statusText: String {
        if !vm.searchText.isEmpty {
            return "\(vm.visibleRows.count) of \(vm.rows.count) rows match"
        }
        return "\(vm.rows.count) rows"
    }

    private func formatDecimal(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }
}

#Preview {
    let deps = AppDependencies.shared
    return ScreenerView(
        vm: ScreenerViewModel(
            store: deps.screenerStore,
            coordinator: deps.dataSweepCoordinator,
            kind: .accumulating
        ),
        title: "Preview"
    )
}
