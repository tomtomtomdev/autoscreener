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

    @Test func warmingShownWhenSweepingPastTheScreeners() {
        // Once the sweep enters the per-symbol cache-warming phase, the bar shows that phase's own
        // progress — not a frozen "Fetching 20/20" left over from the completed screener leg.
        let status = FetchStatus.resolve(
            isSweeping: true, loaded: 20, total: 20,
            isWarming: true, warmedCount: 37, warmingTotal: 142,
            lastError: nil, paywall: nil, lastSweepAt: nil)
        #expect(status == .warming(loaded: 37, total: 142))
    }

    @Test func warmingCarriesTheCurrentTickerThroughResolve() {
        // The name being fetched this instant flows onto the warming status so the bar can name it.
        let status = FetchStatus.resolve(
            isSweeping: true, loaded: 20, total: 20,
            isWarming: true, warmedCount: 3, warmingTotal: 20, warmingTicker: "BBCA",
            lastError: nil, paywall: nil, lastSweepAt: nil)
        #expect(status == .warming(loaded: 3, total: 20, current: "BBCA"))
    }

    @Test func warmingFallsBackToFetchingUntilTheUniverseIsKnown() {
        // isWarming flips true a beat before the warmer reports the universe size; until then
        // (warmingTotal == 0) the bar keeps the screener fetching label rather than "Warming 0/0".
        let status = FetchStatus.resolve(
            isSweeping: true, loaded: 20, total: 20,
            isWarming: true, warmedCount: 0, warmingTotal: 0,
            lastError: nil, paywall: nil, lastSweepAt: nil)
        #expect(status == .fetching(loaded: 20, total: 20))
    }

    @Test func warmingFlagIgnoredWhenNotSweeping() {
        // Like the throttle flag, warming is meaningless outside a sweep — a landed sweep still wins.
        let status = FetchStatus.resolve(
            isSweeping: false, loaded: 0, total: 20,
            isWarming: true, warmedCount: 5, warmingTotal: 10,
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

    // MARK: - Auto-fetch off (boundary-only mode)

    @Test func autoFetchOffShownWhenPausedAndIdle() {
        // Continuous off + inside the trading day → the bar advertises the paused mode and the
        // next boundary, outranking a stale "updated" sweep.
        let next = Date(timeIntervalSince1970: 1_700_001_000)
        let status = FetchStatus.resolve(
            isSweeping: false, loaded: 0, total: 20,
            lastError: nil, paywall: nil, lastSweepAt: sweepAt,
            autoFetchPaused: true, nextBoundary: next)
        #expect(status == .autoFetchOff(next: next))
    }

    @Test func liveSweepStillWinsOverAutoFetchOff() {
        let status = FetchStatus.resolve(
            isSweeping: true, loaded: 3, total: 20,
            lastError: nil, paywall: nil, lastSweepAt: nil,
            autoFetchPaused: true, nextBoundary: nil)
        #expect(status == .fetching(loaded: 3, total: 20))
    }

    @Test func errorStillWinsOverAutoFetchOff() {
        let status = FetchStatus.resolve(
            isSweeping: false, loaded: 0, total: 20,
            lastError: "boom", paywall: nil, lastSweepAt: nil,
            autoFetchPaused: true, nextBoundary: nil)
        #expect(status == .error("boom"))
    }

    @Test func autoFetchOffLabelShowsModeAndOptionalNextEdge() {
        #expect(FetchStatus.autoFetchOff(next: nil).displayLabel == "Auto-fetch off")
        #expect(FetchStatus.autoFetchOff(next: sweepAt).displayLabel.hasPrefix("Auto-fetch off · next "))
    }

    @Test func autoFetchOffTintIsNormal() {
        #expect(FetchStatus.autoFetchOff(next: nil).tint == .normal)
    }

    // MARK: - Manual refresh visibility (closed, or open with auto-fetch off)

    @Test func refreshButtonHiddenOnlyWhileOpenAndContinuous() {
        #expect(GlobalRefreshButton.isVisible(marketOpen: true, continuousAutoFetch: true) == false)
        #expect(GlobalRefreshButton.isVisible(marketOpen: true, continuousAutoFetch: false) == true)
        #expect(GlobalRefreshButton.isVisible(marketOpen: false, continuousAutoFetch: true) == true)
        #expect(GlobalRefreshButton.isVisible(marketOpen: false, continuousAutoFetch: false) == true)
    }

    // MARK: - displayLabel

    @Test func fetchingLabelShowsProgress() {
        #expect(FetchStatus.fetching(loaded: 7, total: 20).displayLabel == "Fetching 7/20…")
    }

    @Test func warmingLabelShowsProgress() {
        #expect(FetchStatus.warming(loaded: 37, total: 142).displayLabel == "Considering 37/142…")
    }

    @Test func warmingLabelNamesTheCurrentTickerWhenPresent() {
        #expect(FetchStatus.warming(loaded: 3, total: 20, current: "BBCA").displayLabel
                == "Considering BBCA 3/20…")
    }

    @Test func warmingLabelFallsBackToBareCountWhenNoTicker() {
        // nil or empty ticker (between names / final tick) renders the plain counter.
        #expect(FetchStatus.warming(loaded: 3, total: 20, current: nil).displayLabel == "Considering 3/20…")
        #expect(FetchStatus.warming(loaded: 3, total: 20, current: "").displayLabel == "Considering 3/20…")
    }

    @Test func warmingLabelAppendsTheInFlightStepWhenPresent() {
        // The API leg in flight is appended after the stock, before the counts.
        #expect(FetchStatus.warming(loaded: 3, total: 20, current: "MBMA", step: "insider activity").displayLabel
                == "Considering MBMA insider activity… 3/20")
    }

    @Test func warmingLabelFallsBackToTickerOnlyWhenStepNil() {
        // No step (between legs / at the per-name boundary) keeps the existing ticker-only label.
        #expect(FetchStatus.warming(loaded: 3, total: 20, current: "MBMA", step: nil).displayLabel
                == "Considering MBMA 3/20…")
        #expect(FetchStatus.warming(loaded: 3, total: 20, current: "MBMA", step: "").displayLabel
                == "Considering MBMA 3/20…")
    }

    @Test func warmingStepCarriesThroughResolve() {
        let status = FetchStatus.resolve(
            isSweeping: true,
            loaded: 0, total: 0,
            isWarming: true, warmedCount: 3, warmingTotal: 20, warmingTicker: "MBMA",
            warmingStep: "insider activity",
            lastError: nil, paywall: nil, lastSweepAt: nil)
        #expect(status == .warming(loaded: 3, total: 20, current: "MBMA", step: "insider activity"))
    }

    @Test func throttlingLabelIsBareRegardlessOfProgress() {
        // The throttle gap is a brief pause between requests; it shows just "Throttling…"
        // without counts or page, so the bar reads as "waiting" rather than progressing.
        #expect(FetchStatus.throttling(loaded: 7, total: 20).displayLabel == "Throttling…")
        #expect(FetchStatus.throttling(loaded: 7, total: 20, page: 3).displayLabel == "Throttling…")
    }

    @Test func paginatedFetchingAppendsParenthesizedPageSuffix() {
        #expect(FetchStatus.fetching(loaded: 7, total: 20, page: 3).displayLabel == "Fetching 7/20… (page 3)")
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
        #expect(FetchStatus.warming(loaded: 1, total: 20).tint == .normal)
        #expect(FetchStatus.updated(sweepAt).tint == .normal)
        #expect(FetchStatus.idle.tint == .normal)
    }
}
