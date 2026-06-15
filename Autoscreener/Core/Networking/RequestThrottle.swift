import Foundation

/// Spaces outgoing requests by a randomized gap so a burst of calls to Stockbit's
/// `exodus` API doesn't look like an automated parallel sweep. Stockbit has shown
/// signs of penalising parallel bursts (the original `WatchlistViewModel.throttle()`
/// note), so any service that fans out across several endpoints serialises them through
/// one of these instead of firing concurrently.
///
/// The first `wait()` returns immediately — there's no point delaying before the first
/// request — and every subsequent `wait()` sleeps a uniform-random interval in `range`.
/// Create one throttle per logical operation (e.g. one governance report) so each
/// operation's first request is free. `sleeper` is injectable so tests run without real
/// delay.
actor RequestThrottle {
    typealias Sleeper = @Sendable (UInt64) async throws -> Void

    /// Randomized inter-request gap, in nanoseconds. Default 1000–1500ms — the cadence
    /// the Watchlist fan-out uses and that Stockbit tolerates.
    static let defaultRange: ClosedRange<UInt64> = 1_000_000_000...1_500_000_000

    private let range: ClosedRange<UInt64>
    private let sleeper: Sleeper
    private var started = false

    init(range: ClosedRange<UInt64> = RequestThrottle.defaultRange,
         sleeper: @escaping Sleeper = { try await Task.sleep(nanoseconds: $0) }) {
        self.range = range
        self.sleeper = sleeper
    }

    /// Awaits the throttle gap before the caller issues its next request: a no-op on the
    /// first call, then a randomized `range` delay on every call after it.
    func wait() async throws {
        if started {
            try await sleeper(UInt64.random(in: range))
        }
        started = true
    }
}
