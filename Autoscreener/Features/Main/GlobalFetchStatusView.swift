import SwiftUI

/// The single global fetch indicator, centred in the window title bar as a `.principal` toolbar item.
///
/// A thin renderer over `FetchStatus.resolve(…)`: it reads the shared `DataSweepCoordinator`'s sweep
/// progress and `MarketDataStore.lastSweepAt`, and shows one label (with a colour tint). The
/// continuous sweep loop is the app's only fetch path, so this status bar — not a per-screen button —
/// is how fetching is made legible. Both sources are `@Observable`, so reading them here re-renders
/// the bar as a sweep starts, progresses, errors, or lands.
struct GlobalFetchStatusView: View {
    private let coordinator: DataSweepCoordinator
    private let marketStore: MarketDataStore

    @MainActor
    init(coordinator: DataSweepCoordinator = AppDependencies.shared.dataSweepCoordinator,
         marketStore: MarketDataStore = AppDependencies.shared.marketDataStore) {
        self.coordinator = coordinator
        self.marketStore = marketStore
    }

    private var status: FetchStatus {
        FetchStatus.resolve(
            isSweeping: coordinator.isSweeping,
            isThrottling: coordinator.isThrottling,
            loaded: coordinator.loadedScreenerCount,
            total: coordinator.totalScreenerCount,
            page: coordinator.currentPage >= 2 ? coordinator.currentPage : nil,
            lastError: coordinator.lastError,
            paywall: coordinator.paywallMessage,
            lastSweepAt: marketStore.lastSweepAt)
    }

    var body: some View {
        let status = self.status
        Text(status.displayLabel)
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(color(for: status.tint))
            .lineLimit(1)
            .help(status.displayLabel)
            .accessibilityIdentifier("globalfetchstatus")
            .accessibilityValue(status.displayLabel)
    }

    private func color(for tint: FetchStatus.Tint) -> Color {
        switch tint {
        case .normal:  return .secondary
        case .warning: return .orange
        case .error:   return .red
        }
    }
}
