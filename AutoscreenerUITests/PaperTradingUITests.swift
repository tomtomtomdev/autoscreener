import XCTest
#if canImport(AppKit)
import AppKit
#endif

/// Drives the sidebar → Paper Trading flow against canned, offline fixtures
/// (`-UITestFixtures`). The portfolio is seeded with 100M IDR; the watchlist + regime
/// come from the same stub-fed stores the other screens use. Verifies the propose →
/// execute → holdings loop: generate a regime-weighted plan, then execute it and see
/// the bought names land in Holdings.
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
    func testGeneratePlanThenExecuteOpensHoldings() throws {
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

        // Generate the regime-weighted allocation from the seeded watchlist.
        let generate = element(app, "PaperTradingGenerateButton")
        XCTAssertTrue(generate.waitForExistence(timeout: 10), "Generate button should appear")
        // Wait until enabled — the watchlist + prices must finish seeding first.
        let enabled = NSPredicate(format: "isEnabled == true")
        expectation(for: enabled, evaluatedWith: generate)
        waitForExpectations(timeout: 15)
        generate.click()

        // A buy line for a fully-liquid, priced name (BBCA) should be proposed.
        XCTAssertTrue(element(app, "PaperTradingPlanRow_BBCA").waitForExistence(timeout: 10),
                      "The plan should propose a buy for a priced watchlist name")

        // Execute the plan → the name moves into Holdings.
        let execute = element(app, "PaperTradingExecuteButton")
        XCTAssertTrue(execute.waitForExistence(timeout: 5), "Execute button should appear")
        execute.click()

        XCTAssertTrue(element(app, "PaperTradingHoldingRow_BBCA").waitForExistence(timeout: 10),
                      "Executed buys should appear in Holdings")
    }
}
