import Foundation
import Testing
@testable import Autoscreener

/// The pure render model behind the global title-bar fetch indicator. `resolve(…)` maps the
/// coordinator/store state to exactly one status with a fixed precedence so the bar never lies;
/// `displayLabel`/`tint` are the deterministic view inputs. No SwiftUI here.
@Suite struct FetchStatusTests {
    private let sweepAt = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - resolve precedence (sweeping > error > paywall > updated > idle)

    @Test func sweepingWinsOverEverything() {
        let status = FetchStatus.resolve(
            isSweeping: true, loaded: 7, total: 20,
            lastError: "boom", paywall: "locked", lastSweepAt: sweepAt)
        #expect(status == .fetching(loaded: 7, total: 20))
    }

    @Test func throttlingShownWhenSweepingAndInTheThrottleGap() {
        // A live sweep that's currently paused between requests reads as throttling,
        // still outranking a stale error/paywall/landed sweep.
        let status = FetchStatus.resolve(
            isSweeping: true, isThrottling: true, loaded: 7, total: 20,
            lastError: "boom", paywall: "locked", lastSweepAt: sweepAt)
        #expect(status == .throttling(loaded: 7, total: 20))
    }

    @Test func pageCarriesThroughIntoFetchingAndThrottling() {
        // A deep paginated screener feeds its page through resolve onto whichever
        // live-sweep state applies.
        let fetching = FetchStatus.resolve(
            isSweeping: true, isThrottling: false, loaded: 7, total: 20, page: 3,
            lastError: nil, paywall: nil, lastSweepAt: nil)
        #expect(fetching == .fetching(loaded: 7, total: 20, page: 3))

        let throttling = FetchStatus.resolve(
            isSweeping: true, isThrottling: true, loaded: 7, total: 20, page: 3,
            lastError: nil, paywall: nil, lastSweepAt: nil)
        #expect(throttling == .throttling(loaded: 7, total: 20, page: 3))
    }

    @Test func throttleFlagIgnoredWhenNotSweeping() {
        // The throttle gap only exists inside a sweep; if the flag lingers while idle,
        // the landed-sweep status must still win — the bar never claims to be working.
        let status = FetchStatus.resolve(
            isSweeping: false, isThrottling: true, loaded: 0, total: 20,
            lastError: nil, paywall: nil, lastSweepAt: sweepAt)
        #expect(status == .updated(sweepAt))
    }

    @Test func errorWinsOverPaywallAndUpdatedWhenNotSweeping() {
        let status = FetchStatus.resolve(
            isSweeping: false, loaded: 0, total: 20,
            lastError: "boom", paywall: "locked", lastSweepAt: sweepAt)
        #expect(status == .error("boom"))
    }

    @Test func paywallWinsOverUpdatedWhenNoError() {
        let status = FetchStatus.resolve(
            isSweeping: false, loaded: 0, total: 20,
            lastError: nil, paywall: "locked", lastSweepAt: sweepAt)
        #expect(status == .paywall("locked"))
    }

    @Test func updatedWhenOnlyASweepHasLanded() {
        let status = FetchStatus.resolve(
            isSweeping: false, loaded: 0, total: 20,
            lastError: nil, paywall: nil, lastSweepAt: sweepAt)
        #expect(status == .updated(sweepAt))
    }

    @Test func idleWhenNothingHasHappened() {
        let status = FetchStatus.resolve(
            isSweeping: false, loaded: 0, total: 20,
            lastError: nil, paywall: nil, lastSweepAt: nil)
        #expect(status == .idle)
    }

    // MARK: - displayLabel

    @Test func fetchingLabelShowsProgress() {
        #expect(FetchStatus.fetching(loaded: 7, total: 20).displayLabel == "Fetching 7/20…")
    }

    @Test func throttlingLabelShowsThrottlingWithProgress() {
        #expect(FetchStatus.throttling(loaded: 7, total: 20).displayLabel == "Throttling 7/20…")
    }

    @Test func paginatedLabelsAppendThePageSuffix() {
        #expect(FetchStatus.fetching(loaded: 7, total: 20, page: 3).displayLabel == "Fetching 7/20… page 3")
        #expect(FetchStatus.throttling(loaded: 7, total: 20, page: 3).displayLabel == "Throttling 7/20… page 3")
    }

    @Test func firstPageHasNoPageSuffix() {
        // nil page (first page / non-paginated leg) renders the bare counter.
        #expect(FetchStatus.fetching(loaded: 7, total: 20).displayLabel == "Fetching 7/20…")
    }

    @Test func errorLabelIsTheMessage() {
        #expect(FetchStatus.error("Couldn't load").displayLabel == "Couldn't load")
    }

    @Test func paywallLabelIsTheMessage() {
        #expect(FetchStatus.paywall("Upgrade to continue").displayLabel == "Upgrade to continue")
    }

    @Test func idleLabelIsADash() {
        #expect(FetchStatus.idle.displayLabel == "—")
    }

    @Test func updatedLabelStartsWithUpdated() {
        // The clock-time portion is locale/zone dependent; pin only the stable prefix.
        #expect(FetchStatus.updated(sweepAt).displayLabel.hasPrefix("Updated "))
    }

    // MARK: - tint

    @Test func tintFlagsErrorAndPaywall() {
        #expect(FetchStatus.error("x").tint == .error)
        #expect(FetchStatus.paywall("x").tint == .warning)
        #expect(FetchStatus.fetching(loaded: 1, total: 20).tint == .normal)
        #expect(FetchStatus.throttling(loaded: 1, total: 20).tint == .normal)
        #expect(FetchStatus.updated(sweepAt).tint == .normal)
        #expect(FetchStatus.idle.tint == .normal)
    }
}
