import XCTest
#if canImport(AppKit)
import AppKit
#endif

/// Drives the sidebar → Paper Trading flow against canned, offline fixtures
/// (`-UITestFixtures`). The portfolio is seeded with 100M IDR; the watchlist + regime
/// come from the same stub-fed stores the other screens use. The screen is hands-free
/// (no Generate/Execute buttons) — it verifies the READ-ONLY autopilot plan preview
/// renders a regime-weighted buy line for a priced watchlist name on its own.
final class PaperTradingUITests: XCTestCase {
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

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    func testAutopilotPlanPreviewAppearsAutomatically() throws {
        // macOS gives each display its own Space; XCUITest can't snapshot a window on
        // another Space (windows == 0). Skip on multi-display dev machines; runs on CI.
        #if canImport(AppKit)
        try XCTSkipIf(NSScreen.screens.count > 1,
                      "XCUITest can't drive windows across separate Spaces on a multi-display setup")
        #endif

        let app = launchWithFixtures()

        // Navigate the sidebar to Paper Trading (the app lands on the Watchlist).
        let item = sidebarItem(app, "Paper Trading")
        XCTAssertTrue(item.waitForExistence(timeout: 15), "Paper Trading sidebar item should appear")
        item.click()

        XCTAssertTrue(element(app, "PaperTradingView").waitForExistence(timeout: 10),
                      "Paper Trading screen should render")

        // Hands-free: with no Generate button, the read-only plan preview computes on its own once the
        // seeded watchlist + prices land — a buy line for a fully-liquid, priced name (BBCA) should show.
        XCTAssertTrue(element(app, "PaperTradingPlanRow_BBCA").waitForExistence(timeout: 15),
                      "The autopilot preview should propose a buy for a priced watchlist name automatically")

        // The manual controls are gone — this is autopilot-only.
        XCTAssertFalse(element(app, "PaperTradingGenerateButton").exists,
                       "There should be no manual Generate button")
        XCTAssertFalse(element(app, "PaperTradingExecuteButton").exists,
                       "There should be no manual Execute button")
    }
}
