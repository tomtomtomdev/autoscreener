import SwiftUI

struct ScreenerView: View {
    @State private var vm: ScreenerViewModel
    @State private var log = NetworkLog.shared
    @State private var showingLogs = false

    init() {
        let deps = AppDependencies.shared
        _vm = State(initialValue: ScreenerViewModel(
            service: deps.screenerService,
            paywall: deps.paywallService,
            templates: deps.screenerTemplateService
        ))
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
        .sheet(isPresented: $showingLogs) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Network log").font(.title3).fontWeight(.semibold)
                    Spacer()
                    Button("Done") { showingLogs = false }
                        .keyboardShortcut(.cancelAction)
                }
                NetworkLogPanel(log: log)
            }
            .padding()
            .frame(minWidth: 700, idealWidth: 820, minHeight: 480, idealHeight: 600)
        }
    }

    private var toolbar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(vm.config.name).font(.headline)
                Text(vm.config.universe.scope).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if vm.isLoading {
                ProgressView().controlSize(.small)
            }
            Button {
                showingLogs = true
            } label: {
                Label("Logs (\(log.entries.count))", systemImage: "doc.text.magnifyingglass")
            }
            .keyboardShortcut("l", modifiers: [.command])
            Button("Refresh") { Task { await vm.refresh() } }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(vm.isLoading)
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
            ContentUnavailableView("Couldn't run screener",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else if vm.rows.isEmpty && !vm.isLoading {
            ContentUnavailableView("No matches",
                                   systemImage: "tablecells",
                                   description: Text("Press Refresh to re-run \(vm.config.name)."))
        } else {
            resultsTable
        }
    }

    private var resultsTable: some View {
        let cols = vm.config.columns
        let firstName = cols.first?.name ?? "Metric 1"
        let secondName = cols.count > 1 ? cols[1].name : "Metric 2"
        let lastSymbol = vm.rows.last?.symbol
        return Table(vm.rows, sortOrder: $vm.sort) {
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

            TableColumn("Last") { row in
                priceCell(row.lastPrice)
            }
            .width(min: 70, ideal: 90)

            TableColumn("Δ%") { row in
                changeCell(row.pctChange)
            }
            .width(min: 60, ideal: 70)

            TableColumn(firstName) { row in metricCell(row.value(at: 0)) }
            TableColumn(secondName) { row in metricCell(row.value(at: 1)) }
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

    @ViewBuilder
    private func priceCell(_ value: Double?) -> some View {
        if let v = value {
            Text(formatPrice(v)).monospacedDigit()
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func changeCell(_ value: Double?) -> some View {
        if let v = value {
            Text(formatPercent(v))
                .monospacedDigit()
                .foregroundStyle(v >= 0 ? .green : .red)
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
                if vm.hasMore {
                    Button("Load more") { Task { await vm.loadMore() } }
                        .disabled(vm.isLoading)
                }
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

    private func formatPrice(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = v < 100 ? 2 : 0
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }

    private func formatPercent(_ v: Double) -> String {
        let sign = v >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", v))%"
    }
}

#Preview { ScreenerView() }
