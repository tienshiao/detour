import XCTest
import AppKit
@testable import Detour

/// TASK-340: a list pane opened on another row refits while its resize
/// animation runs, often to the same height. The animation that refit
/// replaces still calls its completion; that completion must not end the
/// newer animation's bookkeeping, or the next refit reads the window's
/// mid-animation height as one the user dragged to and keeps it.
///
/// The window controller's animator is replaced so the test decides when
/// each animation ends: one that is started moves the window halfway, as a
/// running animation has; one that ends puts the window at its frame and
/// calls its completion.
nonisolated final class SettingsWindowFitTests: XCTestCase {

    @MainActor private final class Animator {
        var pending: [(frame: NSRect, completion: @MainActor @Sendable () -> Void)] = []

        func animate(_ window: NSWindow, to frame: NSRect, completion: @escaping @MainActor @Sendable () -> Void) {
            pending.append((frame, completion))
            let old = window.frame
            window.setFrame(NSRect(x: frame.minX, y: (old.minY + frame.minY) / 2, width: frame.width,
                                   height: ((old.height + frame.height) / 2).rounded()), display: false)
        }

        /// Ends animation `index` (in the order they started).
        func end(_ index: Int, in window: NSWindow) {
            let animation = pending[index]
            window.setFrame(animation.frame, display: false)
            animation.completion()
        }
    }

    private var savedAnimator: ((NSWindow, NSRect, @escaping @MainActor @Sendable () -> Void) -> Void)?

    @MainActor override func tearDown() async throws {
        let controller = SettingsWindowController.shared
        if let savedAnimator { controller.animateFrame = savedAnimator }
        controller.screenUsableHeightOverride = nil
        controller.window?.close()
        try await super.tearDown()
    }

    @MainActor private func contentHeight(_ window: NSWindow) -> CGFloat {
        window.contentLayoutRect.height
    }

    /// The pane's fit by the height rule.
    @MainActor private func fit(of pane: SettingsPaneViewController, in window: NSWindow) -> SettingsPaneHeight {
        SettingsPaneHeight.fit(natural: pane.naturalContentHeight, minimum: pane.minimumContentHeight,
                               screenUsableHeight: 2000,
                               chromeHeight: window.frame.height - contentHeight(window))
    }

    /// The height the pane opens at.
    @MainActor private func openingHeight(of pane: SettingsPaneViewController, in window: NSWindow) -> CGFloat {
        fit(of: pane, in: window).initial
    }

    /// Switch to Profiles (animation 1), a refit to the same height while it
    /// runs (animation 2 replaces it), animation 1's completion arriving
    /// late, then another refit: the window still ends at the pane's height.
    @MainActor func testASupersededAnimationDoesNotStrandTheWindowMidResize() throws {
        let controller = SettingsWindowController.shared
        savedAnimator = controller.animateFrame
        let animator = Animator()
        controller.animateFrame = { window, frame, completion in animator.animate(window, to: frame, completion: completion) }
        controller.screenUsableHeightOverride = 2000
        XCTAssertTrue(controller.showPane(named: "general"))
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.isVisible)
        for index in animator.pending.indices { animator.end(index, in: window) }
        animator.pending.removeAll()

        XCTAssertTrue(controller.showPane(named: "profiles"))
        let pane = try XCTUnwrap(window.contentViewController as? SettingsPaneViewController)
        let full = openingHeight(of: pane, in: window)
        XCTAssertEqual(animator.pending.count, 1, "the switch animates")
        XCTAssertNotEqual(contentHeight(window), full, accuracy: 1, "halfway")

        // The pane reports a change mid-animation: same height, a new animation.
        pane.onContentHeightChange?()
        XCTAssertEqual(animator.pending.count, 2)
        // The replaced animation's completion arrives while animation 2 runs:
        // it must leave animation 2's target in place.
        let midAnimation = window.frame
        animator.pending[0].completion()
        XCTAssertEqual(controller.animationTargetHeight ?? -1, full, accuracy: 0.5,
                       "the window is still heading to the pane's height")
        XCTAssertEqual(window.frame, midAnimation)
        // Another report while animation 2 runs (a label re-measuring).
        pane.onContentHeightChange?()
        for index in 1..<animator.pending.count { animator.end(index, in: window) }

        XCTAssertEqual(contentHeight(window), full, accuracy: 0.5, "the window ends at the pane's height")
        XCTAssertEqual(window.contentMaxSize.height, fit(of: pane, in: window).maxHeight, accuracy: 0.5)
    }

    /// A refit that really comes after the animation (nothing in flight) and
    /// a window the user dragged shorter keep the drag, as before.
    @MainActor func testADraggedHeightIsStillKept() throws {
        let controller = SettingsWindowController.shared
        savedAnimator = controller.animateFrame
        let animator = Animator()
        controller.animateFrame = { window, frame, completion in animator.animate(window, to: frame, completion: completion) }
        controller.screenUsableHeightOverride = 2000
        XCTAssertTrue(controller.showPane(named: "profiles"))
        let window = try XCTUnwrap(controller.window)
        for index in animator.pending.indices { animator.end(index, in: window) }
        animator.pending.removeAll()
        let pane = try XCTUnwrap(window.contentViewController as? SettingsPaneViewController)
        let full = openingHeight(of: pane, in: window)
        XCTAssertEqual(contentHeight(window), full, accuracy: 0.5)

        // The user drags it 100 pt shorter; a refit keeps that.
        window.setFrame(NSRect(x: window.frame.minX, y: window.frame.minY + 100, width: window.frame.width,
                               height: window.frame.height - 100), display: false)
        pane.onContentHeightChange?()
        for index in animator.pending.indices { animator.end(index, in: window) }
        XCTAssertEqual(contentHeight(window), full - 100, accuracy: 0.5)
    }
}
