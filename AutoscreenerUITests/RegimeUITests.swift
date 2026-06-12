import XCTest
#if canImport(AppKit)
import AppKit
#endif

/// Drives the sidebar → Markets → inline regime breakdown against canned, offline
/// fixtures (`-UITestFixtures`). The regime read renders in full atop the Markets
/// dashboard (no longer behind a banner tap). Under fixtures the read is
/// deterministic: a mid-range valuation (neutral) + a BI-rate hike (risk-off) + net
/// foreign selling (risk-off) + a weakening rupiah (risk-off) + LQ45 breadth derived
/// from the stub `.above200MA` screener (risk-off), softened only by falling US 10y
/// (risk-on), net to a **Risk-off** stance, with the transparent factor breakdown
/// rendered. No auth, network, or Keychain involved.
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

        // Market Regime is no longer its own sidebar entry — it renders inline atop Markets.
        let markets = sidebarItem(app, "Markets")
        XCTAssertTrue(markets.waitForExistence(timeout: 15), "Markets sidebar item should appear")
        markets.click()

        // The full breakdown renders inline — no banner tap. The stance is the
        // synthesised, deterministic fixture value.
        let stance = element(app, "regime.stance")
        XCTAssertTrue(stance.waitForExistence(timeout: 10), "Breakdown stance should render inline on Markets")
        XCTAssertEqual(stance.label, "Risk-off", "Fixture inputs (BI-rate hike + foreign selling + weak rupiah + soft breadth) net to a Risk-off stance")

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
