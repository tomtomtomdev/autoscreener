import Foundation

/// Pure render model for the global title-bar fetch indicator.
///
/// The continuous `DataSweepCoordinator` loop is the app's only fetch path; this maps its
/// published progress (`isSweeping`/`loadedScreenerCount`/`lastError`/`paywallMessage`) plus
/// `MarketDataStore.lastSweepAt` onto exactly one status, with a fixed precedence so the bar
/// never lies. No SwiftUI here — `GlobalFetchStatusView` renders `displayLabel`/`tint`/`showsSpinner`.
nonisolated enum FetchStatus: Equatable {
    /// A sweep is in flight: `loaded` of `total` screeners fetched so far.
    case fetching(loaded: Int, total: Int)
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
    static func resolve(isSweeping: Bool,
                        loaded: Int,
                        total: Int,
                        lastError: String?,
                        paywall: String?,
                        lastSweepAt: Date?) -> FetchStatus {
        if isSweeping { return .fetching(loaded: loaded, total: total) }
        if let lastError { return .error(lastError) }
        if let paywall { return .paywall(paywall) }
        if let lastSweepAt { return .updated(lastSweepAt) }
        return .idle
    }

    /// The text shown in the title bar.
    var displayLabel: String {
        switch self {
        case let .fetching(loaded, total): return "Fetching \(loaded)/\(total)…"
        case let .error(message):          return message
        case let .paywall(message):        return message
        case let .updated(date):           return "Updated \(Self.timeFormatter.string(from: date))"
        case .idle:                        return "—"
        }
    }

    /// Only an in-flight sweep animates a spinner.
    var showsSpinner: Bool {
        if case .fetching = self { return true }
        return false
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
