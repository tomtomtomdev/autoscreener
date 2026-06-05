import XCTest
#if canImport(AppKit)
import AppKit
#endif

/// Drives the sidebar → Market Regime flow against canned, offline fixtures
/// (`-UITestFixtures`). Under fixtures the read is deterministic: a mid-range
/// valuation (neutral) + a BI-rate cut (risk-on) + net foreign selling (risk-off)
/// + a weakening rupiah (risk-off) + broad LQ45 breadth (risk-on) net to a
/// **Neutral** stance, with the transparent factor breakdown rendered. No auth,
/// network, or Keychain involved.
final class RegimeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchWithFixtures() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestFixtures"]
        app.launch()
        return app
    }

    private func sidebarItem(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let button = app.buttons[label]
        return button.exists ? button : app.staticTexts[label].firstMatch
    }

    /// Query an element by accessibility identifier, type-agnostically (SwiftUI
    /// surfaces these as different element kinds across macOS builds).
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    func testRegimeShowsStanceAndFactorBreakdown() throws {
        // macOS gives each display its own Space; with multiple displays attached,
        // XCUITest can't snapshot a window on another Space (windows == 0). Skip on
        // multi-display dev machines — still runs on single-display / CI. Mirrors
        // `MarketsUITests` / `StockDetailUITests`.
        #if canImport(AppKit)
        try XCTSkipIf(NSScreen.screens.count > 1,
                      "XCUITest can't drive windows across separate Spaces on a multi-display setup")
        #endif

        let app = launchWithFixtures()

        let regime = sidebarItem(app, "Market Regime")
        XCTAssertTrue(regime.waitForExistence(timeout: 15), "Market Regime sidebar item should appear")
        regime.click()

        // The synthesised stance renders and is the deterministic fixture value.
        let stance = element(app, "regime.stance")
        XCTAssertTrue(stance.waitForExistence(timeout: 10), "Regime stance should render")
        XCTAssertEqual(stance.label, "Neutral", "Fixture inputs net to a Neutral stance")

        // The transparent factor breakdown renders, including the dominant valuation
        // factor, the BI-rate factor, and the LQ45 breadth factor.
        XCTAssertTrue(element(app, "regime.factor.Valuation").waitForExistence(timeout: 5),
                      "Valuation factor row should render")
        XCTAssertTrue(element(app, "regime.factor.BI rate").waitForExistence(timeout: 5),
                      "BI rate factor row should render")
        XCTAssertTrue(element(app, "regime.factor.Breadth (LQ45)").waitForExistence(timeout: 5),
                      "LQ45 breadth factor row should render")
    }
}
