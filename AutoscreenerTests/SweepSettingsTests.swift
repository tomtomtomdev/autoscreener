import Foundation
import Testing
@testable import Autoscreener

@MainActor
@Suite struct SweepSettingsTests {
    /// A private, isolated UserDefaults domain per test so the suite never touches the
    /// real `.standard` store and tests don't race each other on a shared key.
    private func freshDefaults(_ name: String) -> UserDefaults {
        let suite = "SweepSettingsTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func defaultsToContinuousOnWhenUnset() {
        let settings = SweepSettings(defaults: freshDefaults("default"))
        #expect(settings.continuousAutoFetch == true)
    }

    @Test func persistsToggleOffAcrossInstances() {
        let defaults = freshDefaults("persist")
        SweepSettings(defaults: defaults).continuousAutoFetch = false

        let reloaded = SweepSettings(defaults: defaults)
        #expect(reloaded.continuousAutoFetch == false)
    }

    @Test func persistsToggleBackOn() {
        let defaults = freshDefaults("toggleback")
        let settings = SweepSettings(defaults: defaults)
        settings.continuousAutoFetch = false
        settings.continuousAutoFetch = true

        #expect(SweepSettings(defaults: defaults).continuousAutoFetch == true)
    }
}
