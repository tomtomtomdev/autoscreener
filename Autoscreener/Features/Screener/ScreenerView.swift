import SwiftUI

struct ScreenerView: View {
    @State private var vm: ScreenerViewModel

    init() {
        let deps = AppDependencies.shared
        _vm = State(initialValue: ScreenerViewModel(
            service: ScreenerService(apiClient: deps.apiClient)
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
            Divider()
            statusBar
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    private var toolbar: some View {
        HStack {
            Text(vm.config.name).font(.headline)
            Spacer()
            if vm.isLoading {
                ProgressView().controlSize(.small)
            }
            Button("Run") { Task { await vm.run() } }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(vm.isLoading)
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        if let error = vm.error, vm.rows.isEmpty {
            ContentUnavailableView("Couldn't run screener",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else if vm.rows.isEmpty && !vm.isLoading {
            ContentUnavailableView("Press Run to fetch results",
                                   systemImage: "tablecells",
                                   description: Text("Filter: \(vm.config.name)"))
        } else {
            resultsTable
        }
    }

    private var resultsTable: some View {
        let cols = vm.config.columns
        let firstName = cols.first?.name ?? "Metric 1"
        let secondName = cols.count > 1 ? cols[1].name : "Metric 2"
        return Table(vm.rows, sortOrder: $vm.sort) {
            TableColumn("Symbol", value: \.symbol) { row in
                Text(row.symbol).monospaced()
            }
            .width(min: 80, ideal: 100)

            TableColumn("Name", value: \.name)
                .width(min: 160, ideal: 220)

            TableColumn(firstName) { row in metricCell(row.value(at: 0)) }
            TableColumn(secondName) { row in metricCell(row.value(at: 1)) }
        }
        .onChange(of: vm.sort) { _, _ in
            vm.rows.sort(using: vm.sort)
        }
    }

    @ViewBuilder
    private func metricCell(_ value: Double?) -> some View {
        if let v = value {
            Text(format(v)).monospacedDigit()
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

    private func format(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }
}

#Preview { ScreenerView() }
