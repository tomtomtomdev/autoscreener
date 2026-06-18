import Foundation
import Observation

/// User control over the data-sweep cadence while the IDX is **open**.
///
/// - `true` (default): the continuous market-hours loop refreshes everything every 5–10 min.
/// - `false`: the loop pauses between session edges and fires a full sweep only at the
///   boundaries (open / break / resume / close) — see `DataSweepCoordinator.runLoop`.
///
/// Closed-market behaviour (around-the-clock legs + the one-shot 16:00 close capture, plus
/// the manual Refresh button) is unaffected by this setting.
///
/// Backed by `UserDefaults` so the choice survives relaunch; injectable for tests.
@MainActor
@Observable
final class SweepSettings {
    private static let continuousKey = "sweep.continuousAutoFetch"

    @ObservationIgnored private let defaults: UserDefaults

    /// Whether the open-hours loop refreshes continuously (vs only at session boundaries).
    /// Defaults to `true` when unset, preserving the original always-on cadence.
    var continuousAutoFetch: Bool {
        didSet { defaults.set(continuousAutoFetch, forKey: Self.continuousKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `didSet` does not fire for this initial assignment, so reading an unset key as
        // `true` here never writes back — the default stays implicit until the user changes it.
        self.continuousAutoFetch = defaults.object(forKey: Self.continuousKey) as? Bool ?? true
    }
}
