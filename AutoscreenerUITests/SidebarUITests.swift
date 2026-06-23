import XCTest
#if canImport(AppKit)
import AppKit
#endif

/// Guards the sidebar's item set. The in-app "Settings" tab (`AppSettingsView`) was
/// removed; this proves it's gone from the navigation while the surfaces that stay —
/// Recommendations, Markets, Watchlist, Paper Trading — still render. (Sign-out lives
/// in the macOS ⌘, Settings scene, which is a separate window, not this sidebar.)
final class SidebarUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchWithFixtures() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestFixtures"]
        app.launch()
        return app
    }

    /// Sidebar rows surface as buttons in some builds and plain static texts in others.
    private func sidebarItem(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let button = app.buttons[label]
        return button.exists ? button : app.staticTexts[label].firstMatch
    }

    @MainActor
    func testSidebarHasNoSettingsTab() throws {
        // macOS gives each display its own Space; XCUITest can't snapshot a window on
        // another Space (windows == 0). Skip on multi-display dev machines; runs on CI.
        #if canImport(AppKit)
        try XCTSkipIf(NSScreen.screens.count > 1,
                      "XCUITest can't drive windows across separate Spaces on a multi-display setup")
        #endif

        let app = launchWithFixtures()

        // Anchor on a stable surviving item so we know the sidebar finished rendering
        // before making the negative assertion below.
        let paperTrading = sidebarItem(app, "RAPaTS (Regime-Aware)")
        XCTAssertTrue(paperTrading.waitForExistence(timeout: 15),
                      "RAPaTS paper-trading sidebar item should still appear")

        // The remaining navigation surfaces are intact. (Watchlist is no longer its own sidebar item —
        // it was merged into the Recommendations screen as a lower section — so it's not asserted here.)
        XCTAssertTrue(sidebarItem(app, "Recommendations").exists, "Recommendations should remain")
        XCTAssertTrue(sidebarItem(app, "Markets").exists, "Markets should remain")
        // The two paper-trading books are each their own tab.
        XCTAssertTrue(sidebarItem(app, "RiBeTS (Regime-Blind)").exists,
                      "The regime-blind RiBeTS book should have its own sidebar item")

        // The Settings tab is gone from the sidebar.
        XCTAssertFalse(app.buttons["Settings"].exists,
                       "Settings sidebar button should be removed")
        XCTAssertFalse(app.staticTexts["Settings"].exists,
                       "Settings sidebar label should be removed")
    }
}
