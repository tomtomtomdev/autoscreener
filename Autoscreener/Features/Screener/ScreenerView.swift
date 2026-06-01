import SwiftUI

struct ScreenerView: View {
    @Bindable var vm: ScreenerViewModel
    let title: String

    init(vm: ScreenerViewModel, title: String) {
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
        } else {
            resultsTable
        }
    }

    private var resultsTable: some View {
        let cols = vm.config.columns
        let firstName = cols.first?.name ?? "Metric 1"
        let lastSymbol = vm.rows.last?.symbol
        return Table(vm.rows, sortOrder: $vm.sort) {
            TableColumn("No") { row in
                if let i = vm.rows.firstIndex(where: { $0.id == row.id }) {
                    Text("\(i + 1)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 36, ideal: 48)

            TableColumn("Symbol", value: \.symbol) { row in
                Text(row.symbol)
                    .monospaced()
                    .onAppear {
                        // Last row scrolled into view → kick the next page.
                        // Idempotent and no-op once the server signals we're done.
                        if row.symbol == lastSymbol {
                            Task { await vm.rowDidAppear(at: vm.rows.count - 1) }
                        }
                    }
            }
            .width(min: 80, ideal: 100)

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
        .onChange(of: vm.sort) { _, _ in
            if !vm.sort.isEmpty { vm.rows.sort(using: vm.sort) }
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
        if let total = vm.total { "\(vm.rows.count) of \(total) rows · page \(vm.currentPage)" }
        else { "\(vm.rows.count) rows · page \(vm.currentPage)" }
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
            service: deps.screenerService,
            paywall: deps.paywallService,
            templates: deps.screenerTemplateService
        ),
        title: "Preview"
    )
}
