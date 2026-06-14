import Foundation
import Testing
@testable import Autoscreener

/// The pure render model behind the global title-bar fetch indicator. `resolve(…)` maps the
/// coordinator/store state to exactly one status with a fixed precedence so the bar never lies;
/// `displayLabel`/`tint`/`showsSpinner` are the deterministic view inputs. No SwiftUI here.
@Suite struct FetchStatusTests {
    private let sweepAt = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - resolve precedence (sweeping > error > paywall > updated > idle)

    @Test func sweepingWinsOverEverything() {
        let status = FetchStatus.resolve(
            isSweeping: true, loaded: 7, total: 20,
            lastError: "boom", paywall: "locked", lastSweepAt: sweepAt)
        #expect(status == .fetching(loaded: 7, total: 20))
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

    // MARK: - spinner + tint

    @Test func onlyFetchingShowsTheSpinner() {
        #expect(FetchStatus.fetching(loaded: 1, total: 20).showsSpinner)
        #expect(!FetchStatus.error("x").showsSpinner)
        #expect(!FetchStatus.paywall("x").showsSpinner)
        #expect(!FetchStatus.updated(sweepAt).showsSpinner)
        #expect(!FetchStatus.idle.showsSpinner)
    }

    @Test func tintFlagsErrorAndPaywall() {
        #expect(FetchStatus.error("x").tint == .error)
        #expect(FetchStatus.paywall("x").tint == .warning)
        #expect(FetchStatus.fetching(loaded: 1, total: 20).tint == .normal)
        #expect(FetchStatus.updated(sweepAt).tint == .normal)
        #expect(FetchStatus.idle.tint == .normal)
    }
}
