import XCTest
@testable import Detour

/// The Settings window's height rule (TASK-189): open at the pane's natural
/// height, capped to the screen; drag between the pane's minimum and that height.
final class SettingsPaneHeightTests: XCTestCase {
    // A 1000-point visible frame with 80 points of title bar and toolbar
    // leaves 1000 - 80 - 80 (screen margin) = 840 points of content.
    private let screen: CGFloat = 1000
    private let chrome: CGFloat = 80
    private let cap: CGFloat = 840

    private func fit(_ natural: CGFloat, minimum: CGFloat? = nil) -> SettingsPaneHeight {
        SettingsPaneHeight.fit(natural: natural, minimum: minimum, screenUsableHeight: screen, chromeHeight: chrome)
    }

    // MARK: - cap

    func testCapLeavesTheScreenMarginAndTheChrome() {
        XCTAssertEqual(SettingsPaneHeight.cap(screenUsableHeight: screen, chromeHeight: chrome), cap)
    }

    func testCapNeverFallsBelowTheFloor() {
        XCTAssertEqual(SettingsPaneHeight.cap(screenUsableHeight: 250, chromeHeight: chrome),
                       SettingsMetrics.minimumCappedHeight)
    }

    // MARK: - Panes without a minimum (General, Content Blocking)

    func testShortPaneIsFixedAtItsNaturalHeight() {
        XCTAssertEqual(fit(160), SettingsPaneHeight(initial: 160, minHeight: 160, maxHeight: 160))
    }

    func testTallPaneIsFixedAtTheCapAndScrolls() {
        XCTAssertEqual(fit(1200), SettingsPaneHeight(initial: cap, minHeight: cap, maxHeight: cap))
    }

    func testFractionalNaturalHeightRoundsUpSoNothingIsCut() {
        XCTAssertEqual(fit(159.2).initial, 160)
    }

    // MARK: - List panes (minimum 400)

    func testListPaneOpensAtItsNaturalHeightAndShrinksToItsMinimum() {
        XCTAssertEqual(fit(620, minimum: 400), SettingsPaneHeight(initial: 620, minHeight: 400, maxHeight: 620))
    }

    func testListPaneShorterThanItsMinimumIsFixedAtTheMinimum() {
        XCTAssertEqual(fit(250, minimum: 400), SettingsPaneHeight(initial: 400, minHeight: 400, maxHeight: 400))
    }

    func testTallListPaneIsCappedAndStillShrinksToItsMinimum() {
        XCTAssertEqual(fit(1500, minimum: 400), SettingsPaneHeight(initial: cap, minHeight: 400, maxHeight: cap))
    }

    func testMinimumAboveTheCapComesDownToTheCap() {
        let small = SettingsPaneHeight.fit(natural: 900, minimum: 400, screenUsableHeight: 500, chromeHeight: chrome)
        // cap = 500 - 80 - 80 = 340
        XCTAssertEqual(small, SettingsPaneHeight(initial: 340, minHeight: 340, maxHeight: 340))
    }

    // MARK: - Short screens (a laptop display)

    func testShortScreenKeepsAListPaneAtItsMinimumWhenThatFits() {
        // 600 usable - 80 chrome - 80 margin = 440: the 400 minimum still fits.
        let f = SettingsPaneHeight.fit(natural: 250, minimum: 400, screenUsableHeight: 600, chromeHeight: chrome)
        XCTAssertEqual(f, SettingsPaneHeight(initial: 400, minHeight: 400, maxHeight: 400))
    }

    func testShortScreenCapsATallListPaneAndKeepsItsMinimum() {
        let f = SettingsPaneHeight.fit(natural: 900, minimum: 400, screenUsableHeight: 600, chromeHeight: chrome)
        XCTAssertEqual(f, SettingsPaneHeight(initial: 440, minHeight: 400, maxHeight: 440))
    }

    func testScreenShorterThanTheMinimumBringsTheMinimumDownToTheCap() {
        // 520 - 80 - 80 = 360 < 400: a pane below its minimum is fixed at the cap.
        let f = SettingsPaneHeight.fit(natural: 250, minimum: 400, screenUsableHeight: 520, chromeHeight: chrome)
        XCTAssertEqual(f, SettingsPaneHeight(initial: 360, minHeight: 360, maxHeight: 360))
    }

    func testMovingToAShorterScreenPullsAFullHeightWindowDown() {
        let tall = fit(700, minimum: 400)
        let short = SettingsPaneHeight.fit(natural: 700, minimum: 400, screenUsableHeight: 600, chromeHeight: chrome)
        XCTAssertEqual(SettingsPaneHeight.refit(current: 700, from: tall, to: short), 440)
    }

    func testMovingToAShorterScreenPullsAShortenedWindowIntoTheCap() {
        let tall = fit(800, minimum: 400)
        let short = SettingsPaneHeight.fit(natural: 800, minimum: 400, screenUsableHeight: 600, chromeHeight: chrome)
        XCTAssertEqual(SettingsPaneHeight.refit(current: 600, from: tall, to: short), 440)
    }

    func testMinimumNeverExceedsMaximum() {
        for natural in stride(from: CGFloat(0), through: 2000, by: 50) {
            for minimum in [nil, CGFloat(400), CGFloat(1200)] {
                let f = fit(natural, minimum: minimum)
                for screenHeight in [CGFloat(300), 520, 600, 900] {
                    let s = SettingsPaneHeight.fit(natural: natural, minimum: minimum, screenUsableHeight: screenHeight, chromeHeight: chrome)
                    XCTAssertLessThanOrEqual(s.minHeight, s.maxHeight, "screen \(screenHeight) natural \(natural)")
                    XCTAssertLessThanOrEqual(s.maxHeight, SettingsPaneHeight.cap(screenUsableHeight: screenHeight, chromeHeight: chrome))
                }
                XCTAssertLessThanOrEqual(f.minHeight, f.maxHeight, "natural \(natural) minimum \(String(describing: minimum))")
                XCTAssertEqual(f.initial, f.maxHeight, "the window opens at its tallest allowed height")
                XCTAssertLessThanOrEqual(f.maxHeight, cap)
            }
        }
    }

    // MARK: - refit (the shown pane's height changes)

    func testWindowAtFullHeightFollowsThePaneUp() {
        let old = fit(500, minimum: 400), new = fit(560, minimum: 400)
        XCTAssertEqual(SettingsPaneHeight.refit(current: 500, from: old, to: new), 560)
    }

    func testWindowAtFullHeightFollowsThePaneDown() {
        let old = fit(560, minimum: 400), new = fit(480, minimum: 400)
        XCTAssertEqual(SettingsPaneHeight.refit(current: 560, from: old, to: new), 480)
    }

    func testWindowTheUserShortenedKeepsItsHeight() {
        let old = fit(700, minimum: 400), new = fit(760, minimum: 400)
        XCTAssertEqual(SettingsPaneHeight.refit(current: 450, from: old, to: new), 450)
    }

    func testShortenedWindowIsPulledIntoTheNewBounds() {
        let old = fit(700, minimum: 400), new = fit(420, minimum: 400)
        XCTAssertEqual(SettingsPaneHeight.refit(current: 600, from: old, to: new), 420)
    }

    func testFixedPaneFollowsItsNewHeight() {
        let old = fit(160), new = fit(200)
        XCTAssertEqual(SettingsPaneHeight.refit(current: 160, from: old, to: new), 200)
    }
}
