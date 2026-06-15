import SwiftUI
import Observation

@MainActor
@Observable
final class BrokerSummaryViewModel {
    let ticker: StockTicker
    var period: BrokerSummaryPeriod = .latest

    private(set) var summary: BrokerSummary?
    var isLoading = false
    var error: String?

    private let service: any BrokerSummaryServicing
    private var loadedPeriod: BrokerSummaryPeriod?

    init(ticker: StockTicker, service: any BrokerSummaryServicing) {
        self.ticker = ticker
        self.service = service
    }

    func load(force: Bool = false) async {
        if !force, summary != nil, loadedPeriod == period { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            summary = try await service.summary(symbol: ticker.symbol, period: period)
            loadedPeriod = period
        } catch APIError.unauthorized, APIError.notSignedIn {
            summary = nil
            error = "Session expired. Please sign in again."
        } catch let APIError.http(status, _) {
            summary = nil
            error = "Couldn't load broker summary (HTTP \(status))."
        } catch {
            summary = nil
            self.error = "Couldn't load broker summary."
        }
    }
}

struct BrokerFlowTab: View {
    @Bindable var vm: BrokerSummaryViewModel

    var body: some View {
        VStack(spacing: 0) {
            periodPicker
            Divider()
            content
        }
        .accessibilityIdentifier("BrokerFlowTab")
        .task { await vm.load() }
        .onChange(of: vm.period) { _, _ in Task { await vm.load(force: true) } }
    }

    private var periodPicker: some View {
        HStack {
            Picker("Period", selection: $vm.period) {
                Text("Latest").tag(BrokerSummaryPeriod.latest)
                Text("7 Days").tag(BrokerSummaryPeriod.last7Days)
                Text("1 Month").tag(BrokerSummaryPeriod.last1Month)
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
        if vm.isLoading && vm.summary == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = vm.error, vm.summary == nil {
            ContentUnavailableView("Couldn't load broker summary",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else if let summary = vm.summary {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    detectorCard(summary.detector)
                    HStack(alignment: .top, spacing: 24) {
                        brokerColumn("Top Buyers", summary.buyers, tint: .green)
                        brokerColumn("Top Sellers", summary.sellers, tint: .red)
                    }
                }
                .padding()
            }
        } else {
            ContentUnavailableView("No broker data",
                                   systemImage: "person.2.slash",
                                   description: Text("\(vm.ticker.symbol) has no broker summary for this period."))
        }
    }

    private func detectorCard(_ d: BandarDetector) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Bandar Detector").font(.headline)
                accdistBadge(d.accdist)
                Spacer()
                Text("avg \(BrokerFlowTab.price(d.averagePrice))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(spacing: 20) {
                stat("Buyers", "\(d.totalBuyer)")
                stat("Sellers", "\(d.totalSeller)")
                stat("Active brokers", "\(d.numberBrokerBuySell)")
                stat("Top 5", BrokerFlowTab.money(d.top5.amount), tint: d.top5.amount < 0 ? .red : .green)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func stat(_ label: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium)).monospacedDigit().foregroundStyle(tint)
        }
    }

    private func accdistBadge(_ raw: String) -> some View {
        let isDist = raw.localizedCaseInsensitiveContains("dist")
        return Text(raw)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background((isDist ? Color.red : Color.green).opacity(0.18), in: Capsule())
            .foregroundStyle(isDist ? Color.red : Color.green)
    }

    private func brokerColumn(_ title: String, _ legs: [BrokerLeg], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("Broker").gridColumnAlignment(.leading)
                    Text("Net").gridColumnAlignment(.trailing)
                    Text("Avg").gridColumnAlignment(.trailing)
                }
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Divider().gridCellColumns(3)
                ForEach(legs) { leg in
                    GridRow {
                        HStack(spacing: 5) {
                            Text(leg.brokerCode).font(.callout.weight(.medium)).monospaced()
                            categoryTag(leg.category)
                        }
                        Text(BrokerFlowTab.money(leg.value))
                            .monospacedDigit().foregroundStyle(tint)
                            .gridColumnAlignment(.trailing)
                        Text(BrokerFlowTab.price(leg.averagePrice))
                            .monospacedDigit().foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                    }
                    .font(.callout)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func categoryTag(_ c: InvestorCategory) -> some View {
        switch c {
        case .foreign:
            Text("F").font(.caption2.weight(.bold)).foregroundStyle(.orange)
        case .domestic:
            Text("D").font(.caption2.weight(.bold)).foregroundStyle(.blue)
        case .government:
            Text("G").font(.caption2.weight(.bold)).foregroundStyle(.purple)
        case .unknown:
            EmptyView()
        }
    }

    // MARK: - Formatting

    /// Abbreviates an IDR amount: T / B / M with a kept sign, e.g. `568.66 B`.
    static func money(_ value: Double) -> String {
        let sign = value < 0 ? "-" : ""
        let abs = Swift.abs(value)
        switch abs {
        case 1e12...: return "\(sign)\(String(format: "%.2f", abs / 1e12)) T"
        case 1e9...:  return "\(sign)\(String(format: "%.2f", abs / 1e9)) B"
        case 1e6...:  return "\(sign)\(String(format: "%.2f", abs / 1e6)) M"
        default:      return "\(sign)\(String(format: "%.0f", abs))"
        }
    }

    static func price(_ value: Double) -> String {
        String(format: "%.0f", value)
    }
}
