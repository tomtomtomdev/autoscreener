import Foundation

/// Pure render model for the global title-bar fetch indicator.
///
/// The continuous `DataSweepCoordinator` loop is the app's only fetch path; this maps its
/// published progress (`isSweeping`/`loadedScreenerCount`/`lastError`/`paywallMessage`) plus
/// `MarketDataStore.lastSweepAt` onto exactly one status, with a fixed precedence so the bar
/// never lies. No SwiftUI here — `GlobalFetchStatusView` renders `displayLabel`/`tint`/`showsSpinner`.
nonisolated enum FetchStatus: Equatable {
    /// A sweep is in flight and actively pulling a request: `loaded` of `total` so far.
    case fetching(loaded: Int, total: Int)
    /// A sweep is in flight but paused in the anti-burst throttle gap between two
    /// requests — same progress, but waiting rather than fetching this instant.
    case throttling(loaded: Int, total: Int)
    /// The last sweep surfaced a fetch error.
    case error(String)
    /// The plan paywall limited the last sweep.
    case paywall(String)
    /// Idle, with a successful sweep landed at this instant.
    case updated(Date)
    /// Nothing has happened yet (no sweep, no error).
    case idle

    /// Colour intent, mapped to an actual `Color` in the view so this type stays SwiftUI-free.
    enum Tint { case normal, warning, error }

    /// Maps the raw coordinator/store state to a status. Precedence (highest first):
    /// a live sweep > a fetch error > a paywall message > a landed sweep > idle.
    /// Within a live sweep, `isThrottling` distinguishes the inter-request gap (waiting)
    /// from an in-flight request (fetching). The flag is meaningless outside a sweep, so
    /// it's only consulted when `isSweeping` and defaults off for callers that don't track it.
    static func resolve(isSweeping: Bool,
                        isThrottling: Bool = false,
                        loaded: Int,
                        total: Int,
                        lastError: String?,
                        paywall: String?,
                        lastSweepAt: Date?) -> FetchStatus {
        if isSweeping {
            return isThrottling
                ? .throttling(loaded: loaded, total: total)
                : .fetching(loaded: loaded, total: total)
        }
        if let lastError { return .error(lastError) }
        if let paywall { return .paywall(paywall) }
        if let lastSweepAt { return .updated(lastSweepAt) }
        return .idle
    }

    /// The text shown in the title bar.
    var displayLabel: String {
        switch self {
        case let .fetching(loaded, total):   return "Fetching \(loaded)/\(total)…"
        case let .throttling(loaded, total): return "Waiting \(loaded)/\(total)…"
        case let .error(message):            return message
        case let .paywall(message):          return message
        case let .updated(date):             return "Updated \(Self.timeFormatter.string(from: date))"
        case .idle:                          return "—"
        }
    }

    /// An in-flight sweep animates a spinner — whether it's pulling a request or waiting
    /// in the throttle gap — so the bar reads as continuously busy across the sweep.
    var showsSpinner: Bool {
        switch self {
        case .fetching, .throttling: return true
        default:                     return false
        }
    }

    var tint: Tint {
        switch self {
        case .error:   return .error
        case .paywall: return .warning
        default:       return .normal
        }
    }

    /// Short local clock time ("14:32") for the `.updated` label — the user's zone/locale,
    /// which is exactly what the title bar should show.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
