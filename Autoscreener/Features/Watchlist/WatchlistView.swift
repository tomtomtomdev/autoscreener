import SwiftUI

struct WatchlistView: View {
    @Bindable var vm: WatchlistViewModel
    let title: String

    init(vm: WatchlistViewModel, title: String = "Watchlist") {
        self.vm = vm
        self.title = title
    }

    var body: some View {
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
                Text("Composite Bandar score · max 5.5").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if vm.isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .padding()
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
        } else {
            resultsTable
        }
    }

    private var resultsTable: some View {
        let rows = vm.rows
        return Table(rows) {
            TableColumn("No") { row in
                if let i = rows.firstIndex(where: { $0.id == row.id }) {
                    Text("\(i + 1)").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .width(min: 36, ideal: 48)

            TableColumn("Symbol") { row in
                Text(row.symbol).monospaced()
            }
            .width(min: 80, ideal: 100)

            TableColumn("Name") { row in
                Text(row.name)
            }
            .width(min: 160, ideal: 240)

            TableColumn("Score") { row in
                Text(formatScore(row.score)).monospacedDigit()
            }
            .width(min: 60, ideal: 80)
        }
    }

    private var statusBar: some View {
        HStack {
            if let error = vm.error, !vm.rows.isEmpty {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            Spacer()
            if !vm.rows.isEmpty {
                Text("\(vm.rows.count) rows").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal).padding(.vertical, 6)
    }

    private func formatScore(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }
}
