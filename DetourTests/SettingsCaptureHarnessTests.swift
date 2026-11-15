import XCTest
import AppKit
import GRDB
@testable import Detour

/// TASK-338: a capture harness, not a check. With
/// `TEST_RUNNER_SETTINGS_CAPTURE_DIR` set it draws every Settings pane in
/// light and dark with Increase Contrast on (`SettingsGroupStyle`'s
/// override: a process cannot turn the system setting on for itself, and an
/// `accessibilityHighContrast…` appearance resolves to the plain one while
/// it is off) and writes PNGs there; without it, it is skipped. The system
/// colours do not take their high-contrast variants this way, only the
/// groups' own border does.
nonisolated final class SettingsCaptureHarnessTests: XCTestCase {

    @MainActor private final class Backdrop: NSView {
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.windowBackgroundColor.setFill()
            dirtyRect.fill()
        }
    }

    @MainActor func testCaptureEveryPaneWithIncreaseContrast() throws {
        guard let folder = ProcessInfo.processInfo.environment["SETTINGS_CAPTURE_DIR"], !folder.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_SETTINGS_CAPTURE_DIR to capture the panes")
        }
        SettingsGroupStyle.increaseContrastOverride = true
        defer { SettingsGroupStyle.increaseContrastOverride = nil }
        let suite = "SettingsCaptureHarnessTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for (look, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let panes: [(String, SettingsPaneViewController)] = [
                ("general", GeneralSettingsViewController()), ("spaces", SpacesSettingsViewController()),
                ("links", LinksSettingsViewController(linkRoutes: TabStore.shared.linkRoutes)),
                ("quickdetour", QuickDetourSettingsViewController()), ("profiles", ProfilesSettingsViewController()),
                ("search", SearchSettingsViewController(
                    siteSearches: SiteSearchStore(database: try AppDatabase(dbQueue: DatabaseQueue())))),
                ("shortcuts", ShortcutsSettingsViewController(store: ShortcutBindingStore(defaults: defaults))),
                ("extensions", ExtensionsSettingsViewController()), ("contentblocker", ContentBlockerSettingsViewController()),
            ]
            for (id, pane) in panes {
                let height = min(max(pane.naturalContentHeight, pane.minimumContentHeight ?? 0), 1100)
                let size = NSSize(width: SettingsMetrics.windowWidth, height: height)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                                      backing: .buffered, defer: false)
                // Closed below: ARC owns it (released on close, it was freed twice).
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: name)
                let backdrop = Backdrop(frame: NSRect(origin: .zero, size: size))
                window.contentView = backdrop
                pane.view.frame = backdrop.bounds
                backdrop.addSubview(pane.view)
                pane.viewWillAppear()
                backdrop.layoutSubtreeIfNeeded()
                backdrop.layoutSubtreeIfNeeded()
                let rep = try XCTUnwrap(backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds))
                backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
                let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("ic-\(id)-\(look).png"))
                pane.viewDidDisappear()
                pane.view.removeFromSuperview()
                window.close()
            }
        }
    }
}
