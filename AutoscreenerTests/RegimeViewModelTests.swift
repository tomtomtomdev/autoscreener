import Foundation
import Testing
@testable import Autoscreener

/// `RegimeViewModel` is now a thin projection over the shared `MarketDataStore` (the
/// `DataSweepCoordinator` gathers the inputs and `RegimeComposer` synthesises the
/// read — covered by `RegimeComposerTests` and `DataSweepCoordinatorRegimeTests`).
/// These tests pin the projection contract.
@MainActor
@Suite struct RegimeViewModelTests {
    private func read(_ stance: RegimeStance) -> RegimeRead {
        RegimeRead(stance: stance, score: 0.1,
                   factors: [RegimeFactor(kind: .breadth, signal: .riskOn, detail: "62% above")],
                   asOf: "2026-06-11", valuationCapped: false)
    }

    private func vm(_ store: MarketDataStore) -> RegimeViewModel {
        RegimeViewModel(
            store: store,
            coordinator: SweepTestKit.coordinator(store: SweepTestKit.store(), marketStore: store))
    }

    @Test func readProjectsTheStore() {
        let store = SweepTestKit.marketStore()
        store.apply(regimeRead: read(.riskOff))
        #expect(vm(store).read?.stance == .riskOff)
    }

    @Test func emptyStoreHasNoRead() {
        #expect(vm(SweepTestKit.marketStore()).read == nil)
    }

    @Test func notLoadingOnceAReadHasLanded() {
        let store = SweepTestKit.marketStore()
        store.apply(regimeRead: read(.neutral))
        #expect(vm(store).isLoading == false)
    }

    // MARK: - loadState (cold-launch empty/loading)

    @Test func loadStateIsLoadingBeforeAnySweep() {
        #expect(vm(SweepTestKit.marketStore()).loadState == .loading)
    }

    /// The regime leg only runs while the IDX session is open, so a completed sweep with
    /// no read (market closed, no cache) is `.empty` — the banner shows guidance instead
    /// of spinning forever.
    @Test func loadStateIsEmptyAfterASweepWithNoRead() {
        let store = SweepTestKit.marketStore()
        store.markSweepComplete(at: Date(timeIntervalSince1970: 0))
        #expect(vm(store).loadState == .empty)
    }

    @Test func loadStateIsReadyOnceAReadHasLanded() {
        let store = SweepTestKit.marketStore()
        store.apply(regimeRead: read(.neutral))
        #expect(vm(store).loadState == .ready)
    }
}
