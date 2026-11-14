import AppKit
import XCTest
@testable import Detour

/// The real approval panel of TASK-228.5 (the user's endpoint has no other
/// way in): a click before the buttons are armed approves nothing, Allow
/// answers allow once armed, Escape denies, and a panel dismissed from the
/// outside (timeout, the client hung up) answers nothing. The flow around it
/// is tested with a fake prompter in AutomationClientApprovalTests.
nonisolated final class AutomationApprovalPanelTests: XCTestCase {

    private var prompts: [AutomationApprovalPrompt] = []

    @MainActor override func tearDown() async throws {
        for prompt in prompts { prompt.dismiss() }
        prompts.removeAll()
        try await super.tearDown()
    }

    @MainActor private func present(_ name: String, answers: @escaping (AutomationApprovalAnswer) -> Void) throws
        -> AutomationApprovalPanel {
        let request = AutomationApprovalRequest(name: name, title: nil, version: nil)
        let prompt = AutomationApprovalPanelPrompter().present(request, answer: answers)
        prompts.append(prompt)
        return try XCTUnwrap(prompt as? AutomationApprovalPanel)
    }

    @MainActor private func waitUntilArmed(_ panel: AutomationApprovalPanel) async throws {
        let deadline = Date().addingTimeInterval(AutomationApprovalPanelPrompter.armDelay + 3)
        while !panel.allowButton.isEnabled, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(panel.allowButton.isEnabled, "armed after armDelay")
        XCTAssertTrue(panel.denyButton.isEnabled)
    }

    @MainActor func testAClickBeforeTheButtonsAreArmedApprovesNothingAndAllowAnswersOnceArmed() async throws {
        var answers: [AutomationApprovalAnswer] = []
        let panel = try present("claude-code") { answers.append($0) }
        XCTAssertTrue(panel.panel.isVisible)
        XCTAssertEqual(panel.panel.identifier, AutomationApprovalPanel.panelIdentifier)
        XCTAssertFalse(NSApp.isActive && NSApp.keyWindow === panel.panel,
                       "shown without taking the keyboard from the app in use")

        XCTAssertFalse(panel.allowButton.isEnabled, "not armed at first")
        panel.allowButton.performClick(nil)
        panel.denyButton.performClick(nil)
        XCTAssertTrue(answers.isEmpty, "a click meant for the app in front cannot answer")
        XCTAssertTrue(panel.panel.isVisible)

        try await waitUntilArmed(panel)
        panel.allowButton.performClick(nil)
        XCTAssertEqual(answers, [.allow])
        XCTAssertFalse(panel.panel.isVisible, "the panel closes with the answer")

        panel.allowButton.performClick(nil)
        XCTAssertEqual(answers, [.allow], "answered once")
    }

    @MainActor func testEscapeDeniesAndReturnApprovesNothing() async throws {
        var answers: [AutomationApprovalAnswer] = []
        let panel = try present("cursor") { answers.append($0) }
        try await waitUntilArmed(panel)

        func key(_ characters: String, code: UInt16) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: panel.panel.windowNumber, context: nil,
                                           characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: code))
        }
        _ = panel.panel.performKeyEquivalent(with: try key("\r", code: 36))
        XCTAssertTrue(answers.isEmpty, "Allow is not the default button")
        XCTAssertTrue(panel.panel.performKeyEquivalent(with: try key("\u{1b}", code: 53)))
        XCTAssertEqual(answers, [.deny])
        XCTAssertFalse(panel.panel.isVisible)
    }

    @MainActor func testAPanelDismissedFromOutsideAnswersNothing() async throws {
        var answers: [AutomationApprovalAnswer] = []
        let panel = try present("hung-up") { answers.append($0) }
        try await waitUntilArmed(panel)
        panel.dismiss()
        XCTAssertFalse(panel.panel.isVisible)
        panel.allowButton.performClick(nil)
        XCTAssertTrue(answers.isEmpty, "a withdrawn or timed-out prompt cannot be approved afterwards")
    }
}
