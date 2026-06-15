import SwiftUI
import Observation

@MainActor
@Observable
final class ForeignFlowViewModel {
    let ticker: StockTicker
    var period: ForeignFlowPeriod = .oneDay

    private(set) var flow: ForeignFlow?
    var isLoading = false
    var error: String?

    private let service: any ForeignFlowServicing
    private var loadedPeriod: ForeignFlowPeriod?

    init(ticker: StockTicker, service: any ForeignFlowServicing) {
        self.ticker = ticker
        self.service = service
    }

    func load(force: Bool = false) async {
        if !force, flow != nil, loadedPeriod == period { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            flow = try await service.flow(symbol: ticker.symbol, period: period)
            loadedPeriod = period
        } catch APIError.unauthorized, APIError.notSignedIn {
            flow = nil
            error = "Session expired. Please sign in again."
        } catch let APIError.http(status, _) {
            flow = nil
            error = "Couldn't load foreign flow (HTTP \(status))."
        } catch {
            flow = nil
            self.error = "Couldn't load foreign flow."
        }
    }
}

struct ForeignFlowTab: View {
    @Bindable var vm: ForeignFlowViewModel

    var body: some View {
        VStack(spacing: 0) {
            periodPicker
            Divider()
            content
        }
        .accessibilityIdentifier("ForeignFlowTab")
        .task { await vm.load() }
        .onChange(of: vm.period) { _, _ in Task { await vm.load(force: true) } }
    }

    private var periodPicker: some View {
        HStack {
            Picker("Period", selection: $vm.period) {
                Text("1 Day").tag(ForeignFlowPeriod.oneDay)
                Text("1 Month").tag(ForeignFlowPeriod.oneMonth)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            Spacer()
            if vm.isLoading { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if vm.isLoading && vm.flow == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = vm.error, vm.flow == nil {
            ContentUnavailableView("Couldn't load foreign flow",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else if let flow = vm.flow {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    netCard(flow)
                    legGrid(flow)
                    breakdownCard(flow.value)
                }
                .padding()
            }
        } else {
            ContentUnavailableView("No foreign flow",
                                   systemImage: "arrow.left.arrow.right",
                                   description: Text("\(vm.ticker.symbol) has no foreign-flow data for this period."))
        }
    }

    private func netCard(_ flow: ForeignFlow) -> some View {
        let net = flow.netForeign.raw
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Net Foreign")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(flow.dateRange).font(.caption).foregroundStyle(.secondary)
            }
            Text(flow.netForeign.formatted)
                .font(.system(.title, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(net < 0 ? Color.red : Color.green)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func legGrid(_ flow: ForeignFlow) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
            GridRow {
                metric("Foreign Buy", flow.foreignBuy, tint: .green)
                metric("Foreign Sell", flow.foreignSell, tint: .red)
            }
            GridRow {
                metric("Domestic Buy", flow.domesticBuy, tint: .green)
                metric("Domestic Sell", flow.domesticSell, tint: .red)
            }
            GridRow {
                metric("Net Foreign", flow.netForeign, tint: flow.netForeign.raw < 0 ? .red : .green)
                metric("Net Domestic", flow.netDomestic, tint: flow.netDomestic.raw < 0 ? .red : .green)
            }
        }
    }

    private func metric(_ label: String, _ value: FlowMetric, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value.formatted).font(.callout.weight(.medium)).monospacedDigit().foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Foreign vs. domestic share of the period's total value.
    private func breakdownCard(_ b: ForeignFlowBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(b.label).font(.subheadline.weight(.semibold))
                Spacer()
                Text(b.total.formatted).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            GeometryReader { geo in
                let foreignFrac = max(0, min(1, b.foreignPercentage / 100))
                HStack(spacing: 0) {
                    Rectangle().fill(.orange)
                        .frame(width: geo.size.width * foreignFrac)
                    Rectangle().fill(.blue)
                }
                .clipShape(Capsule())
            }
            .frame(height: 10)
            HStack {
                Label("Foreign \(String(format: "%.1f", b.foreignPercentage))%", systemImage: "circle.fill")
                    .foregroundStyle(.orange)
                Spacer()
                Label("Domestic \(String(format: "%.1f", b.domesticPercentage))%", systemImage: "circle.fill")
                    .foregroundStyle(.blue)
            }
            .font(.caption2)
            .labelStyle(.titleAndIcon)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}
