import SwiftUI

/// Pushed into the detail pane when a stock code is tapped. Shows the company's
/// financial statements from `findata-view/v2/financials`, switchable by report
/// (Income / Balance Sheet / Cash Flow) and period basis (Annual / Quarterly).
struct StockDetailView: View {
    enum DetailTab: String, CaseIterable, Identifiable {
        case financials = "Financials"
        case broker = "Broker"
        case foreign = "Foreign Flow"
        var id: String { rawValue }
    }

    @State private var tab: DetailTab = .financials
    @State private var vm: StockDetailViewModel
    @State private var brokerVM: BrokerSummaryViewModel
    @State private var foreignVM: ForeignFlowViewModel

    init(ticker: StockTicker,
         service: any FinancialStatementServicing = AppDependencies.shared.financialStatementService,
         brokerService: any BrokerSummaryServicing = AppDependencies.shared.brokerSummaryService,
         foreignService: any ForeignFlowServicing = AppDependencies.shared.foreignFlowService) {
        _vm = State(initialValue: StockDetailViewModel(ticker: ticker, service: service))
        _brokerVM = State(initialValue: BrokerSummaryViewModel(ticker: ticker, service: brokerService))
        _foreignVM = State(initialValue: ForeignFlowViewModel(ticker: ticker, service: foreignService))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tabBar
            Divider()
            if tab == .financials {
                controls
                Divider()
            }
            tabContent
        }
        .frame(minWidth: 600, minHeight: 460)
        .accessibilityIdentifier("StockDetailView")
        .navigationTitle(vm.ticker.symbol)
        .task { await vm.load() }
        .onChange(of: vm.report) { _, _ in Task { await vm.load() } }
        .onChange(of: vm.basis) { _, _ in Task { await vm.load() } }
    }

    private var tabBar: some View {
        Picker("Section", selection: $tab) {
            ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal)
        .padding(.vertical, 8)
        .accessibilityIdentifier("StockDetailTabPicker")
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .financials: content
        case .broker: BrokerFlowTab(vm: brokerVM)
        case .foreign: ForeignFlowTab(vm: foreignVM)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(vm.ticker.symbol)
                .font(.title2.weight(.semibold))
                .monospaced()
            Text(vm.ticker.name)
                .font(.headline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if let currency = vm.statement?.currency, !currency.isEmpty {
                Text("in \(currency)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if vm.isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .padding()
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Picker("Report", selection: $vm.report) {
                ForEach([FinancialReportType.income, .balanceSheet, .cashFlow], id: \.self) {
                    Text($0.shortTitle).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            Picker("Period", selection: $vm.basis) {
                ForEach([FinancialPeriodBasis.annual, .quarterly], id: \.self) {
                    Text($0.title).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            Spacer()
        }
        .labelsHidden()
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if vm.isLoading && vm.statement == nil {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = vm.error, vm.statement == nil {
            ContentUnavailableView("Couldn't load financials",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else if let message = vm.paywallMessage, vm.statement == nil {
            ContentUnavailableView("Financials unavailable",
                                   systemImage: "lock",
                                   description: Text(message))
        } else if let statement = vm.statement, !statement.periods.isEmpty {
            statementGrid(statement)
        } else {
            ContentUnavailableView("No financial data",
                                   systemImage: "tablecells",
                                   description: Text("\(vm.ticker.symbol) has no \(vm.report.title.lowercased()) on record."))
        }
    }

    private func statementGrid(_ statement: FinancialStatement) -> some View {
        let columns = Array(statement.periods.indices)
        return ScrollView([.vertical, .horizontal]) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    Text("Account")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(columns, id: \.self) { i in
                        Text(statement.periods[i])
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                    }
                }
                Divider()
                ForEach(vm.rows) { row in
                    if row.isSpacer {
                        Color.clear.frame(height: 4)
                    } else {
                        GridRow {
                            nameCell(row)
                            ForEach(columns, id: \.self) { i in
                                valueCell(row, column: i)
                            }
                        }
                    }
                }
            }
            .padding()
        }
    }

    private func nameCell(_ row: FinancialRow) -> some View {
        HStack(spacing: 4) {
            if row.hasChildren {
                Button { vm.toggle(row.id) } label: {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 12, height: 1)
            }
            Text(row.name)
                .fontWeight(row.isEmphasized ? .semibold : .regular)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(row.depth) * 14)
    }

    @ViewBuilder
    private func valueCell(_ row: FinancialRow, column: Int) -> some View {
        let raw = column < row.values.count
            ? row.values[column].trimmingCharacters(in: .whitespaces)
            : ""
        if raw.isEmpty || raw == "-" {
            Text("—")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        } else {
            Text(raw)
                .monospacedDigit()
                .fontWeight(row.isEmphasized ? .semibold : .regular)
                // Parenthesised figures are negatives — tint them red.
                .foregroundStyle(raw.hasPrefix("(") ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
        }
    }
}
