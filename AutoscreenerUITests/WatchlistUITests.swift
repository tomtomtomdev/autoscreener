import XCTest
#if canImport(AppKit)
import AppKit
#endif

/// Drives the composite Watchlist against canned, offline fixtures (`-UITestFixtures`).
/// The Watchlist is now a **section of the default Recommendations screen** (rendered beneath the action
/// cards in one scroll), not a separate sidebar tab — so this lands on the default screen and scrolls
/// down to the watchlist rows. Its rows come entirely from the shared `ScreenerStore` cache, seeded once
/// by the sweep coordinator over the stub services. Verifies cache-backed rendering and that the
/// liquidity **veto excludes** a stock missing from the intraday-liquidity gate (GOTO) rather than
/// tagging it.
final class WatchlistUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchWithFixtures() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestFixtures"]
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func sidebarItem(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let button = app.buttons[label]
        return button.exists ? button : app.staticTexts[label].firstMatch
    }

    /// On this runner the default-selected detail column doesn't always surface to XCUITest until the
    /// sidebar selection changes. Bounce off another item and back to force the Recommendations detail
    /// (which now hosts the watchlist section) to realize.
    private func landOnRecommendations(_ app: XCUIApplication) {
        let markets = sidebarItem(app, "Markets")
        if markets.waitForExistence(timeout: 15) { markets.click() }
        let recommendations = sidebarItem(app, "Recommendations")
        if recommendations.waitForExistence(timeout: 10) { recommendations.click() }
    }

    /// The watchlist section sits below the recommendation cards in one `LazyVStack`/`ScrollView`, so its
    /// rows aren't instantiated until scrolled into view. Scroll the merged screen down until `target`
    /// appears (or the attempts run out).
    @discardableResult
    private func reveal(_ app: XCUIApplication, _ target: XCUIElement) -> Bool {
        if target.waitForExistence(timeout: 3) { return true }
        let scroll = app.scrollViews["RecommendationsView"].exists
            ? app.scrollViews["RecommendationsView"]
            : app.scrollViews.firstMatch
        // Try scrolling down first (the watchlist sits below the cards); if the sign convention is the
        // other way on this build, the trailing positive deltas cover it.
        for delta in [-160.0, -160, -160, -160, -160, 160, 160, 160, 160, 160] {
            guard !target.exists else { return true }
            if scroll.exists { scroll.scroll(byDeltaX: 0, deltaY: CGFloat(delta)) }
        }
        return target.exists
    }

    @MainActor
    func testWatchlistSectionRendersFromCacheAndExcludesVetoedStock() throws {
        // macOS gives each display its own Space; XCUITest can't snapshot a window on
        // another Space (windows == 0). Skip on multi-display dev machines; runs on CI.
        #if canImport(AppKit)
        try XCTSkipIf(NSScreen.screens.count > 1,
                      "XCUITest can't drive windows across separate Spaces on a multi-display setup")
        #endif

        let app = launchWithFixtures()

        // The unified Recommendations screen is the default landing; the Watchlist is its lower section.
        landOnRecommendations(app)
        XCTAssertTrue(element(app, "RecommendationsView").waitForExistence(timeout: 15),
                      "The merged Recommendations screen should render")

        // BBCA and TLKM appear in every screener (including both liquidity gates) → survive. Scroll the
        // merged screen down to bring the watchlist section into view.
        let bbca = element(app, "watchlist.stockcode-BBCA")
        XCTAssertTrue(reveal(app, bbca),
                      "A fully-liquid stock should appear in the watchlist section")
        XCTAssertTrue(element(app, "watchlist.stockcode-TLKM").exists,
                      "A fully-liquid stock should appear in the watchlist section")

        // Each surviving row shows its screener-provenance icon strip (right of the score). BBCA/TLKM
        // match every screener under fixtures, so their signal strips are non-empty → the cell exists.
        XCTAssertTrue(element(app, "watchlist.screeners-BBCA").exists,
                      "The screener-icon strip should render for a matched stock")
        XCTAssertTrue(element(app, "watchlist.screeners-TLKM").exists,
                      "The screener-icon strip should render for a matched stock")

        // GOTO is absent from the intraday-liquidity veto gate → excluded entirely (never rendered).
        XCTAssertFalse(element(app, "watchlist.stockcode-GOTO").exists,
                       "A stock failing a liquidity veto gate must be excluded, not shown")
    }
}
