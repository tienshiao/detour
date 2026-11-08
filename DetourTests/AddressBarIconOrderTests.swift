import XCTest
@testable import Detour

/// TASK-299: the sidebar's address bar and a Quick Detour's title bar order
/// their trailing icons the same way, host … [extensions] [Copy Link]
/// [Site Settings], with the same labels, and Copy and Site Settings stay in
/// place whatever extensions are pinned.
nonisolated final class AddressBarIconOrderTests: XCTestCase {

    @MainActor private func icons(_ count: Int) -> [(id: String, image: NSImage)] {
        (0..<count).map { index in
            (id: "test-extension-\(index)", image: NSImage(size: NSSize(width: 16, height: 16)))
        }
    }

    @MainActor private func frame(of view: NSView, in container: NSView) -> NSRect {
        view.convert(view.bounds, to: container)
    }

    // MARK: - Sidebar

    @MainActor private func makeSidebarBar() -> FauxAddressBar {
        let bar = FauxAddressBar(frame: NSRect(x: 0, y: 0, width: 260, height: 32))
        bar.displayText = "example.com"
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    @MainActor func testTheSidebarBarsCopyAndSettingsStayPutAsExtensionsArePinned() {
        let bar = makeSidebarBar()
        var copyFrames: [NSRect] = []
        var settingsFrames: [NSRect] = []
        for count in [0, 1, 3, 0] {
            bar.setPinnedExtensions(icons(count))
            bar.layoutSubtreeIfNeeded()
            copyFrames.append(frame(of: bar.copyButton, in: bar))
            settingsFrames.append(frame(of: bar.settingsButton, in: bar))
        }
        XCTAssertEqual(Set(copyFrames.map { NSStringFromRect($0) }).count, 1, "\(copyFrames)")
        XCTAssertEqual(Set(settingsFrames.map { NSStringFromRect($0) }).count, 1, "\(settingsFrames)")
    }

    @MainActor func testTheSidebarBarOrdersExtensionsThenCopyThenSettings() throws {
        let bar = makeSidebarBar()
        bar.setPinnedExtensions(icons(2))
        bar.layoutSubtreeIfNeeded()
        let copy = frame(of: bar.copyButton, in: bar)
        let settings = frame(of: bar.settingsButton, in: bar)
        let lastExtension = try XCTUnwrap(bar.pinnedExtensionStack.arrangedSubviews.last)
        XCTAssertLessThanOrEqual(frame(of: lastExtension, in: bar).maxX, copy.minX)
        XCTAssertLessThanOrEqual(copy.maxX, settings.minX)
        XCTAssertLessThanOrEqual(settings.maxX, bar.bounds.maxX)
    }

    // MARK: - Quick Detour

    @MainActor private func makeTitleBar() -> (QuickDetourTitleBar, NSView) {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 40))
        let bar = QuickDetourTitleBar()
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        bar.setProfile(name: "Personal", isPrivate: false)
        bar.setHost("example.com", isSecure: true)
        bar.setOpenIn(destination: "Home", reloads: false, hasDropdown: true)
        container.layoutSubtreeIfNeeded()
        return (bar, container)
    }

    @MainActor func testTheQuickDetourBarsCopyAndSettingsStayPutAsExtensionsArePinned() {
        let (bar, container) = makeTitleBar()
        var copyFrames: [NSRect] = []
        var settingsFrames: [NSRect] = []
        for count in [0, 1, 3, 0] {
            bar.setExtensions(icons(count))
            container.layoutSubtreeIfNeeded()
            copyFrames.append(frame(of: bar.copyButton, in: container))
            settingsFrames.append(frame(of: bar.pageSettingsButton, in: container))
        }
        XCTAssertEqual(Set(copyFrames.map { NSStringFromRect($0) }).count, 1, "\(copyFrames)")
        XCTAssertEqual(Set(settingsFrames.map { NSStringFromRect($0) }).count, 1, "\(settingsFrames)")
    }

    @MainActor func testTheQuickDetourBarOrdersExtensionsThenCopyThenSettings() throws {
        let (bar, container) = makeTitleBar()
        bar.setExtensions(icons(2))
        container.layoutSubtreeIfNeeded()
        let copy = frame(of: bar.copyButton, in: container)
        let settings = frame(of: bar.pageSettingsButton, in: container)
        let lastExtension = try XCTUnwrap(bar.extensionStack.arrangedSubviews.last)
        XCTAssertLessThanOrEqual(frame(of: lastExtension, in: container).maxX, copy.minX)
        XCTAssertLessThanOrEqual(copy.maxX, settings.minX)
        XCTAssertLessThan(settings.maxX, frame(of: bar.openInControl, in: container).minX)
    }

    // MARK: - Labels

    @MainActor func testBothBarsLabelCopyAndSettingsTheSameWay() {
        let sidebar = makeSidebarBar()
        let (quickDetour, _) = makeTitleBar()
        for (copy, settings) in [(sidebar.copyButton, sidebar.settingsButton),
                                 (quickDetour.copyButton, quickDetour.pageSettingsButton)] {
            XCTAssertEqual(copy.toolTip, "Copy Link")
            XCTAssertEqual(copy.image?.accessibilityDescription, "Copy Link")
            XCTAssertEqual(settings.toolTip, "Site Settings")
            XCTAssertEqual(settings.image?.accessibilityDescription, "Site Settings")
        }
    }
}
