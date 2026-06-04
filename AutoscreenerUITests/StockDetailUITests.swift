import XCTest
#if canImport(AppKit)
import AppKit
#endif

/// Drives the tap-a-stock-code → financial-detail flow end-to-end against canned,
/// offline fixtures (`-UITestFixtures`), so no auth/network/Keychain is involved.
final class StockDetailUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchWithFixtures() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestFixtures"]
        app.launch()
        return app
    }

    /// macOS segmented `Picker` options surface as radio buttons in most builds and
    /// plain buttons in others — query whichever exists.
    private func segment(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let radio = app.radioButtons[label]
        return radio.exists ? radio : app.buttons[label]
    }

    /// Finds the stock-code control by accessibility id, falling back to its label.
    private func stockButton(_ app: XCUIApplication, _ symbol: String) -> XCUIElement {
        let byID = app.buttons["stockcode-\(symbol)"]
        return byID.exists ? byID : app.buttons[symbol]
    }

    @MainActor
    func testTappingStockCodeOpensFinancialDetail() throws {
        // macOS gives each display its own Space; with multiple displays attached,
        // XCUITest can't snapshot a window that lands on a Space other than the
        // runner's (it sees only the menu bar → windows == 0). Skip on multi-display
        // dev machines — this still runs on single-display / CI.
        #if canImport(AppKit)
        try XCTSkipIf(NSScreen.screens.count > 1,
                      "XCUITest can't drive windows across separate Spaces on a multi-display setup")
        #endif

        let app = launchWithFixtures()

        // The screener renders the canned rows; the stock code is a tappable link.
        let bbca = stockButton(app, "BBCA")
        XCTAssertTrue(bbca.waitForExistence(timeout: 15),
                      "BBCA stock-code link should appear in the screener")
        bbca.click()

        // Detail opens on the Chart tab: its timeframe control (default 1Y) is present.
        XCTAssertTrue(segment(app, "1Y").waitForExistence(timeout: 5),
                      "Chart tab's timeframe picker should appear by default")

        // Switch to the Financials tab → Annual / Income Statement view.
        let financials = segment(app, "Financials")
        XCTAssertTrue(financials.waitForExistence(timeout: 5), "Financials tab should exist")
        financials.click()
        XCTAssertTrue(app.staticTexts["12M 2025"].waitForExistence(timeout: 5),
                      "Annual period header should appear on the pushed detail")
        XCTAssertTrue(app.staticTexts["Pendapatan"].waitForExistence(timeout: 5),
                      "Income-statement account should be shown")

        // Switch report → Balance Sheet replaces the income accounts.
        let balance = segment(app, "Balance")
        XCTAssertTrue(balance.waitForExistence(timeout: 5), "Balance segment should exist")
        balance.click()
        XCTAssertTrue(app.staticTexts["Aset"].waitForExistence(timeout: 5),
                      "Balance-sheet account should appear after switching report")

        // Switch period basis → Quarterly column headers replace the annual ones.
        let quarterly = segment(app, "Quarterly")
        XCTAssertTrue(quarterly.waitForExistence(timeout: 5), "Quarterly segment should exist")
        quarterly.click()
        XCTAssertTrue(app.staticTexts["Q1 2026"].waitForExistence(timeout: 5),
                      "Quarterly period header should appear after switching basis")
    }
}
