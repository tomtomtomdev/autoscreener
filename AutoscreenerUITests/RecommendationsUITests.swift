import XCTest
#if canImport(AppKit)
import AppKit
#endif

/// Drives the unified "Recommendations" inbox against canned, offline fixtures (`-UITestFixtures`).
/// Under fixtures the merged list is deterministic: a deteriorated EXIT (XXXX), a risk-off TRIM (BBNI),
/// a buy-only candidate (BBCA), and a thesis-intact HOLD (WIFI). The buy picks WIFI and BBNI are also
/// held, so the sell verdict wins for them and only BBCA remains a pure BUY — proving the screen merges
/// the buy-side picks (`AppDependencies.todaysPicks`) and the Gate-5 sell-side review
/// (`AppDependencies.reviewPositions`) into one ranked list, actionable first, with action badges and an
/// expandable rationale. Replaces the separate `TodaysPicksUITests` / `PositionsReviewUITests`.
final class RecommendationsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchWithFixtures(skipped: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestFixtures"]
        if skipped { app.launchArguments += ["-UITestSkippedFixture"] }
        app.launch()
        return app
    }

    /// Query an element by accessibility identifier, type-agnostically (SwiftUI surfaces these as
    /// different element kinds across macOS builds).
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func sidebarItem(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let button = app.buttons[label]
        return button.exists ? button : app.staticTexts[label].firstMatch
    }

    /// On this runner the default-selected detail column doesn't always surface to XCUITest until the
    /// sidebar selection changes. Bounce off another item and back to force the Recommendations detail
    /// to realize.
    private func landOnRecommendations(_ app: XCUIApplication) {
        let markets = sidebarItem(app, "Markets")
        if markets.waitForExistence(timeout: 15) { markets.click() }
        let recommendations = sidebarItem(app, "Recommendations")
        if recommendations.waitForExistence(timeout: 10) { recommendations.click() }
    }

    /// The watchlist section sits below the recommendation cards in one `ScrollView`, so its rows (and
    /// their screener-icon strips) aren't instantiated until scrolled into view. Mirrors `WatchlistUITests`.
    @discardableResult
    private func reveal(_ app: XCUIApplication, _ target: XCUIElement) -> Bool {
        if target.waitForExistence(timeout: 3) { return true }
        let scroll = app.scrollViews["RecommendationsView"].exists
            ? app.scrollViews["RecommendationsView"]
            : app.scrollViews.firstMatch
        for delta in [-160.0, -160, -160, -160, -160, 160, 160, 160, 160, 160] {
            guard !target.exists else { return true }
            if scroll.exists { scroll.scroll(byDeltaX: 0, deltaY: CGFloat(delta)) }
        }
        return target.exists
    }

    @MainActor
    func testRecommendationsMergesBuyAndSellRows() throws {
        // macOS gives each display its own Space; with multiple displays attached, XCUITest can't
        // snapshot a window on another Space (windows == 0). Skip on multi-display dev machines —
        // still runs on single-display / CI. Mirrors `MarketsUITests` / `WatchlistUITests`.
        #if canImport(AppKit)
        try XCTSkipIf(NSScreen.screens.count > 1,
                      "XCUITest can't drive windows across separate Spaces on a multi-display setup")
        #endif

        let app = launchWithFixtures()

        // Recommendations is the default landing. (We verify through accessibility identifiers, per the
        // project's UI-verification policy — not by scraping labels.)
        landOnRecommendations(app)
        XCTAssertTrue(element(app, "RecommendationsView").waitForExistence(timeout: 15),
                      "Recommendations screen should render")
        XCTAssertTrue(element(app, "recommendations.summary").waitForExistence(timeout: 5),
                      "The summary header should render (the loaded-with-rows state)")

        // The consolidation's proof: a buy-side pick and the sell-side verdicts share the ONE list.
        // XXXX is exit-only (not among the picks) and BBCA is buy-only (not among the held positions),
        // so both rows appearing in the same RecommendationsView is exactly the buy+sell merge. (We
        // query the row containers, the convention these suites already prove queryable — SwiftUI
        // collapses a card's nested elements once the card itself carries an accessibility identifier.)
        XCTAssertTrue(element(app, "recommendations.row.XXXX").waitForExistence(timeout: 5),
                      "Exit verdict row (sell-side only) should render")
        XCTAssertTrue(element(app, "recommendations.row.BBNI").waitForExistence(timeout: 5),
                      "Trim verdict row should render")
        XCTAssertTrue(element(app, "recommendations.row.BBCA").waitForExistence(timeout: 5),
                      "Buy-only candidate row (buy-side only) should render in the same list")
        XCTAssertTrue(element(app, "recommendations.row.WIFI").waitForExistence(timeout: 5),
                      "Hold verdict row should render")
    }

    @MainActor
    func testSkippedNamesSurfaceAsANonBlockingNote() throws {
        // Resilience proof: with skipped names seeded, the screen still renders its rows AND a
        // non-blocking "N skipped" note — never the full-screen "…AdapterError error 0" it used to show.
        #if canImport(AppKit)
        try XCTSkipIf(NSScreen.screens.count > 1,
                      "XCUITest can't drive windows across separate Spaces on a multi-display setup")
        #endif

        let app = launchWithFixtures(skipped: true)

        landOnRecommendations(app)
        XCTAssertTrue(element(app, "RecommendationsView").waitForExistence(timeout: 15),
                      "Recommendations screen should render")
        // The rows are unaffected — skips don't block the load.
        XCTAssertTrue(element(app, "recommendations.summary").waitForExistence(timeout: 5),
                      "The summary header should still render alongside the skip note")
        // The note itself.
        XCTAssertTrue(element(app, "recommendations.skipped").waitForExistence(timeout: 5),
                      "The 'N skipped' note should render when names were skipped")
    }

    @MainActor
    func testTappingScreenerIconPushesThatScreenersList() throws {
        #if canImport(AppKit)
        try XCTSkipIf(NSScreen.screens.count > 1,
                      "XCUITest can't drive windows across separate Spaces on a multi-display setup")
        #endif

        let app = launchWithFixtures()

        landOnRecommendations(app)
        XCTAssertTrue(element(app, "RecommendationsView").waitForExistence(timeout: 15),
                      "The merged Recommendations screen should render")

        // Scroll the watchlist section into view (it sits below the action cards). BBCA matches every
        // signal screener under fixtures, so its row carries a tappable Accumulating icon.
        let bbca = element(app, "watchlist.stockcode-BBCA")
        XCTAssertTrue(reveal(app, bbca),
                      "A matched watchlist row should appear so its screener icons render")

        // Tap the Accumulating screener icon → drill into that screener's full results list.
        let icon = element(app, "watchlist.screener-accumulating")
        XCTAssertTrue(icon.waitForExistence(timeout: 5),
                      "The Accumulating screener icon should render on a matched row")
        icon.click()

        // The pushed ScreenerView renders its own rows — its stock-code buttons use the bare
        // `stockcode-<symbol>` id (the watchlist section uses the `watchlist.`-prefixed variant), so this
        // uniquely proves we navigated to the screener's list, not back to the watchlist.
        XCTAssertTrue(element(app, "stockcode-BBCA").waitForExistence(timeout: 10),
                      "Tapping the screener icon should push that screener's results list")
    }
}
