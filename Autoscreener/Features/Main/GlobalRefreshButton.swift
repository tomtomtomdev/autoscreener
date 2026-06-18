import SwiftUI

/// A manual Refresh control in the window title bar, shown **only when nothing is auto-refreshing**:
/// the market is closed, OR it's open but the user turned continuous auto-fetch off (§3.x / SPEC §15).
/// During normal open-hours auto-sweeping it's hidden — the continuous loop already keeps data fresh.
///
/// Tapping it forces a full sweep (`DataSweepCoordinator.refreshNow`): the 20 screeners → watchlist,
/// the market quotes, the regime read, and the recommendations cache. The Recommendations and Markets
/// screens reload automatically when the sweep lands, so there's no per-screen wiring.
struct GlobalRefreshButton: View {
    private let coordinator: DataSweepCoordinator
    private let settings: SweepSettings
    private let clock: MarketClock

    @MainActor
    init(coordinator: DataSweepCoordinator = AppDependencies.shared.dataSweepCoordinator,
         settings: SweepSettings = AppDependencies.shared.sweepSettings,
         clock: MarketClock = AppDependencies.shared.marketClock) {
        self.coordinator = coordinator
        self.settings = settings
        self.clock = clock
    }

    /// Visible whenever the auto-sweep isn't continuously running — i.e. hidden only while the
    /// market is open AND continuous auto-fetch is on. Pure so it's unit-testable.
    static func isVisible(marketOpen: Bool, continuousAutoFetch: Bool) -> Bool {
        !(marketOpen && continuousAutoFetch)
    }

    var body: some View {
        // Re-evaluate on a timer so the button appears/disappears as the market opens and closes,
        // not only when a sweep event re-renders the bar. Reading `settings`/`isSweeping` in here
        // also re-renders on a toggle change or while a sweep is in flight.
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            if Self.isVisible(marketOpen: clock.isOpen(), continuousAutoFetch: settings.continuousAutoFetch) {
                Button {
                    Task { await coordinator.refreshNow() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(coordinator.isSweeping)
                .help("Fetch the latest screeners, watchlist, and recommendations now")
                .accessibilityIdentifier("globalrefresh")
            }
        }
    }
}
