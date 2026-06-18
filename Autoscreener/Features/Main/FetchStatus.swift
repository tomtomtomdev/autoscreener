import Foundation

/// Pure render model for the global title-bar fetch indicator.
///
/// The continuous `DataSweepCoordinator` loop is the app's only fetch path; this maps its
/// published progress (`isSweeping`/`loadedScreenerCount`/`lastError`/`paywallMessage`) plus
/// `MarketDataStore.lastSweepAt` onto exactly one status, with a fixed precedence so the bar
/// never lies. No SwiftUI here — `GlobalFetchStatusView` renders `displayLabel`/`tint`.
nonisolated enum FetchStatus: Equatable {
    /// A sweep is in flight and actively pulling a request: `loaded` of `total` so far.
    /// `page` is the current page of a multi-page screener fetch (≥2), or nil on the first
    /// page / non-paginated legs — surfaced as a "page x" suffix so the bar shows progress
    /// through a deep paginated screener instead of looking stuck on one counter.
    case fetching(loaded: Int, total: Int, page: Int? = nil)
    /// A sweep is in flight but paused in the anti-burst throttle gap between two
    /// requests — waiting rather than fetching this instant. Carries the same progress
    /// fields as `.fetching` for `resolve`/`Equatable`, but `displayLabel` renders a bare
    /// "Throttling…" (no counts/page) so the brief pause reads as waiting, not progress.
    case throttling(loaded: Int, total: Int, page: Int? = nil)
    /// The last sweep surfaced a fetch error.
    case error(String)
    /// The plan paywall limited the last sweep.
    case paywall(String)
    /// Idle, with a successful sweep landed at this instant.
    case updated(Date)
    /// Idle, with continuous auto-fetch turned off during the trading day — the loop is paused
    /// between session boundaries. Carries the next boundary instant (when known) so the bar can
    /// say when the next fetch lands.
    case autoFetchOff(next: Date?)
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
                        page: Int? = nil,
                        lastError: String?,
                        paywall: String?,
                        lastSweepAt: Date?,
                        autoFetchPaused: Bool = false,
                        nextBoundary: Date? = nil) -> FetchStatus {
        if isSweeping {
            return isThrottling
                ? .throttling(loaded: loaded, total: total, page: page)
                : .fetching(loaded: loaded, total: total, page: page)
        }
        if let lastError { return .error(lastError) }
        if let paywall { return .paywall(paywall) }
        // The paused mode is more useful to surface than a stale "updated" time, so it outranks it.
        if autoFetchPaused { return .autoFetchOff(next: nextBoundary) }
        if let lastSweepAt { return .updated(lastSweepAt) }
        return .idle
    }

    /// The text shown in the title bar.
    var displayLabel: String {
        switch self {
        case let .fetching(loaded, total, page):   return "Fetching \(loaded)/\(total)…" + Self.pageSuffix(page)
        case .throttling:                          return "Throttling…"
        case let .error(message):                  return message
        case let .paywall(message):                return message
        case let .updated(date):                   return "Updated \(Self.timeFormatter.string(from: date))"
        case let .autoFetchOff(next):
            guard let next else { return "Auto-fetch off" }
            return "Auto-fetch off · next \(Self.timeFormatter.string(from: next))"
        case .idle:                                return "—"
        }
    }

    /// " (page x)" tail appended to a `.fetching` label while a multi-page screener is being
    /// paginated, empty otherwise. Not used by `.throttling`, which renders bare.
    private static func pageSuffix(_ page: Int?) -> String {
        guard let page else { return "" }
        return " (page \(page))"
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
