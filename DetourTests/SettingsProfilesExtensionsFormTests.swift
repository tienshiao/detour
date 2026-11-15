import XCTest
import AppKit
@testable import Detour

/// TASK-338 phase 2: the detail columns of Profiles and Extensions are
/// grouped forms. Every control ends on the form's right edge and every name
/// starts on its left edge; Profiles shows and hides its rows and sections by
/// `ProfileSettingsLayout`, turns the filter lists off while blocking is off
/// and an extension's row off while the extension is off everywhere; every
/// identifier and Learn more link survives. Also the two form additions they
/// need: a section whose rows are replaced, and a row that is one view.
nonisolated final class SettingsProfilesExtensionsFormTests: XCTestCase {

    private var createdProfiles: [Profile] = []
    private var savedExtensions: [WebExtension]?

    @MainActor override func tearDown() async throws {
        if let savedExtensions {
            ExtensionManager.shared.extensions = savedExtensions
            // Observers outside Settings (the toolbars, the Develop menu) may
            // have read the test's extensions: they read the list again.
            NotificationCenter.default.post(name: ExtensionManager.extensionsDidChangeNotification, object: nil)
        }
        savedExtensions = nil
        for profile in createdProfiles {
            TabStore.shared.forceRemoveProfile(id: profile.id)
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
        }
        createdProfiles.removeAll()
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// A profile of the test's own, removed in tearDown.
    @MainActor private func makeProfile(_ configure: (Profile) -> Void = { _ in }) -> Profile {
        let profile = TabStore.shared.addProfile(name: "Form Test \(UUID().uuidString.prefix(6))")
        createdProfiles.append(profile)
        configure(profile)
        return profile
    }

    @MainActor private func privateProfile() throws -> Profile {
        try XCTUnwrap(TabStore.shared.profiles.first { $0.id == TabStore.incognitoProfileID })
    }

    /// An extension in memory only (no files, no database rows): what the
    /// panes read of one. Installed for the test, the previous list restored
    /// in tearDown.
    @MainActor private func install(_ manifest: String, isEnabled: Bool = true) throws -> WebExtension {
        let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: Data(manifest.utf8))
        let id = "settings-form-\(UUID().uuidString.prefix(8))"
        let ext = WebExtension(id: id, manifest: manifest,
                               basePath: FileManager.default.temporaryDirectory.appendingPathComponent(id),
                               isEnabled: isEnabled)
        if savedExtensions == nil { savedExtensions = ExtensionManager.shared.extensions }
        ExtensionManager.shared.extensions.append(ext)
        return ext
    }

    @MainActor private static let fullManifest = """
        {"manifest_version": 3, "name": "Form Test Extension", "version": "2.1.0",
         "description": "An extension with every kind of permission row.",
         "options_page": "options.html",
         "permissions": ["storage", "tabs"], "host_permissions": ["<all_urls>"],
         "optional_permissions": ["cookies"], "optional_host_permissions": ["https://example.org/*"]}
        """

    @MainActor private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    /// A view's alignment rectangle (a label's frame is 2 pt wider on each
    /// side) in `host`'s coordinates.
    @MainActor private func placed(_ view: NSView, in host: NSView) -> NSRect {
        guard let superview = view.superview else { return .zero }
        return superview.convert(view.alignmentRect(forFrame: view.frame), to: host)
    }

    @MainActor private func laidOut<Pane: SettingsPaneViewController>(_ pane: Pane) -> Pane {
        pane.view.setFrameSize(NSSize(width: SettingsMetrics.windowWidth, height: 900))
        pane.viewWillAppear()
        pane.view.layoutSubtreeIfNeeded()
        // A wrapping label re-measures at the width the first pass gave it.
        pane.view.layoutSubtreeIfNeeded()
        return pane
    }

    /// Selects `profile` in the pane's list, as a click does, and lays the
    /// pane out unless `layOut` is false.
    @MainActor private func show(_ profile: Profile, in pane: ProfilesSettingsViewController,
                                 layOut: Bool = true) throws {
        let table = try XCTUnwrap(descendants(of: pane.view).compactMap { $0 as? NSTableView }.first)
        let listed = TabStore.shared.profiles.filter { !$0.isIncognito || $0.id == TabStore.incognitoProfileID }
        let index = try XCTUnwrap(listed.firstIndex { $0.id == profile.id }, "the profile is in the list")
        // A row selected again posts no change: go through none first.
        table.deselectAll(nil)
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        guard layOut else { return }
        pane.view.layoutSubtreeIfNeeded()
        pane.view.layoutSubtreeIfNeeded()
    }

    /// Overlay scrollers, so a column is as wide laid out as it is estimated
    /// (with "always show scroll bars" it is 15 pt narrower, and the pane
    /// re-measures once laid out, by design).
    @MainActor private func useOverlayScrollers(in pane: SettingsPaneViewController) {
        for scroll in descendants(of: pane.view).compactMap({ $0 as? NSScrollView }) { scroll.scrollerStyle = .overlay }
    }

    @MainActor private func form(in pane: SettingsPaneViewController) throws -> SettingsForm {
        try XCTUnwrap(descendants(of: pane.view).compactMap { $0 as? SettingsForm }.first)
    }

    /// The visible rows of a form, top to bottom.
    @MainActor private func visibleRows(of form: SettingsForm) -> [SettingsFormRow] {
        form.sections.filter { !$0.isHidden }.flatMap(\.rows).filter { !$0.isHidden }
    }

    /// Every visible control of `form` ends on its right edge less the row
    /// inset, and every visible name (a footnote's text) starts on its left
    /// edge plus the inset; the form is the detail column's width.
    @MainActor private func assertSharedEdges(_ form: SettingsForm, in pane: SettingsPaneViewController,
                                              _ place: String, file: StaticString = #filePath, line: UInt = #line) {
        let frame = placed(form, in: pane.view)
        let scroll = form.enclosingScrollView
        XCTAssertEqual(frame.width, scroll?.contentView.bounds.width ?? 0, accuracy: 0.5,
                       "\(place): the form fills the detail column", file: file, line: line)
        let right = frame.maxX - SettingsMetrics.formRowInsetX
        let left = frame.minX + SettingsMetrics.formRowInsetX
        var controls = 0
        for row in visibleRows(of: form) {
            let name = row.titleLabel?.stringValue ?? row.helpLabel.stringValue
            if let title = row.titleLabel {
                XCTAssertEqual(placed(title, in: pane.view).minX, left, accuracy: 0.5,
                               "\(place): \(name)'s name", file: file, line: line)
            } else if !row.helpLabel.isHidden {
                XCTAssertEqual(placed(row.helpLabel, in: pane.view).minX, left, accuracy: 0.5,
                               "\(place): the footnote \(name)", file: file, line: line)
            }
            if let accessory = row.accessoryView, row.titleLabel != nil {
                XCTAssertEqual(placed(accessory, in: pane.view).maxX, right, accuracy: 0.5,
                               "\(place): \(name)'s control", file: file, line: line)
                controls += 1
            }
        }
        XCTAssertGreaterThan(controls, 0, "\(place): controls were checked", file: file, line: line)
    }

    // MARK: - Profiles

    @MainActor func testProfilesDetailIsOneFormSectionPerProfileSection() throws {
        let pane = laidOut(ProfilesSettingsViewController())
        let form = try form(in: pane)
        XCTAssertEqual(form.sections.count, ProfileSettingsSection.allCases.count)
        for (index, section) in ProfileSettingsSection.allCases.enumerated() {
            let formSection = try XCTUnwrap(pane.formSections[section])
            XCTAssertTrue(form.sections[index] === formSection, "\(section) in reading order")
            XCTAssertEqual(formSection.titleLabel?.stringValue, section.title)
            // Learn more beside the title (TASK-292.11).
            XCTAssertEqual((formSection.headerAccessory as? SettingsGuideLink)?.page, section.guidePage, "\(section)")
            if section.guidePage != nil {
                XCTAssertEqual((formSection.headerAccessory as? SettingsGuideLink)?.title, "Learn more")
            }
        }
        // The private note closes the first section, with its own link.
        let note = try XCTUnwrap(pane.formRows[.privateNote]?.first)
        XCTAssertNil(note.titleLabel, "a footnote")
        XCTAssertEqual(note.helpLabel.stringValue, "This profile is used for Private Windows.")
        XCTAssertTrue(pane.formSections[.profile]?.rows.last === note)
        XCTAssertEqual(descendants(of: note).compactMap { ($0 as? SettingsGuideLink)?.page }, [.privateBrowsing])
        // Each filter list a row of its own.
        XCTAssertEqual(pane.formRows[.filterLists]?.map { $0.titleLabel?.stringValue },
                       ["EasyList (ads)", "EasyPrivacy (trackers)", "Cookie notices", "Malicious URLs"])
    }

    /// Every switch, pop-up and field in a normal profile's and the Private
    /// profile's details ends on the form's right edge, every name starts on
    /// its left edge, and each control is named by its row.
    @MainActor func testProfilesControlsShareTheFormsEdges() throws {
        _ = try install(Self.fullManifest)
        let normal = makeProfile { $0.userAgentMode = .custom; $0.customUserAgent = "Test Agent/1.0" }
        let pane = laidOut(ProfilesSettingsViewController())
        for profile in [normal, try privateProfile()] {
            try show(profile, in: pane)
            let form = try form(in: pane)
            assertSharedEdges(form, in: pane, profile.isIncognito ? "Private" : "normal")
            for row in visibleRows(of: form) {
                // A push button keeps its own title; a pop-up is named by its row.
                guard let title = row.titleLabel?.stringValue, let control = row.accessoryView as? NSControl,
                      !(control is NSButton) || control is NSPopUpButton else { continue }
                XCTAssertEqual(control.accessibilityLabel(), title, "\(title) is named by its row")
            }
        }
    }

    /// Rows and sections show as `ProfileSettingsLayout` says for the
    /// selected profile; the isolation warning is the isolation row's warning
    /// line and the user agent preview the Identify as row's help.
    @MainActor func testProfilesRowsFollowTheLayoutRules() throws {
        _ = try install(Self.fullManifest)
        let plain = makeProfile { $0.sleepThreshold = .never }
        let isolated = makeProfile { $0.isPerTabIsolation = true; $0.sleepThreshold = .oneHour }
        let custom = makeProfile { $0.userAgentMode = .custom; $0.customUserAgent = "Test Agent/1.0" }
        let pane = laidOut(ProfilesSettingsViewController())
        var warnings = 0
        for profile in [plain, isolated, custom, try privateProfile()] {
            try show(profile, in: pane)
            let state = ProfileSettingsState(
                isPrivate: profile.isIncognito, isPerTabIsolation: profile.isPerTabIsolation,
                sleepsTabs: profile.sleepThreshold != .never, usesCustomUserAgent: profile.userAgentMode == .custom,
                hasExtensions: true)
            let place = profile.name
            for row in ProfileSettingsRow.allCases {
                for formRow in pane.formRows[row] ?? [] {
                    XCTAssertEqual(formRow.isHidden, !ProfileSettingsLayout.isVisible(row, in: state), "\(place): \(row)")
                }
            }
            let visible = ProfileSettingsLayout.visibleSections(in: state)
            for section in ProfileSettingsSection.allCases {
                XCTAssertEqual(pane.formSections[section]?.isHidden, !visible.contains(section), "\(place): \(section)")
            }
            let warns = ProfileSettingsLayout.isVisible(.isolationWarning, in: state)
            XCTAssertEqual(pane.isolationRow.warning, warns ? ProfilesSettingsViewController.isolationWarningText : nil, place)
            if warns { warnings += 1 }
            XCTAssertEqual(pane.userAgentRow.helpLabel.stringValue, profile.resolvedUserAgent(), place)
            XCTAssertFalse(pane.userAgentRow.helpLabel.isHidden, place)
            XCTAssertTrue(pane.userAgentRow.helpLabel.isSelectable, "\(place): the preview can be copied")
        }
        XCTAssertEqual(warnings, 1, "the isolated, sleeping profile shows the warning")
        // A hidden row takes no room: the custom string row comes and goes.
        try show(plain, in: pane)
        XCTAssertEqual(pane.formRows[.customUserAgent]?.first?.isHidden, true)
        XCTAssertEqual(pane.formRows[.archiveTabs]?.first?.isHidden, false)
    }

    @MainActor func testWithoutExtensionsTheExtensionsSectionIsHidden() throws {
        savedExtensions = ExtensionManager.shared.extensions
        ExtensionManager.shared.extensions = []
        let profile = makeProfile()
        let pane = laidOut(ProfilesSettingsViewController())
        try show(profile, in: pane)
        XCTAssertEqual(pane.formSections[.extensions]?.isHidden, true)
        XCTAssertEqual(pane.formSections[.extensions]?.rows.count, 0)
    }

    /// The filter lists' rows are off (switch disabled, name dimmed) while
    /// blocking is off, and on again with it.
    @MainActor func testFilterListRowsAreOffWhileBlockingIsOff() throws {
        let profile = makeProfile { $0.isAdBlockingEnabled = false }
        let pane = laidOut(ProfilesSettingsViewController())
        try show(profile, in: pane)
        let rows = try XCTUnwrap(pane.formRows[.filterLists])
        XCTAssertEqual(rows.count, 4)
        for row in rows {
            XCTAssertFalse(row.isEnabled)
            XCTAssertEqual((row.accessoryView as? NSSwitch)?.isEnabled, false)
            XCTAssertEqual(row.titleLabel?.textColor, .tertiaryLabelColor)
            XCTAssertFalse(row.isHidden, "shown, not hidden")
        }
        profile.isAdBlockingEnabled = true
        try show(profile, in: pane)
        for row in rows {
            XCTAssertTrue(row.isEnabled)
            XCTAssertEqual((row.accessoryView as? NSSwitch)?.isEnabled, true)
        }
    }

    /// An extension's row shows the profile's own choice; while the
    /// extension is off everywhere the row is off and says why.
    @MainActor func testExtensionRowsFollowTheInstalledExtensions() throws {
        let on = try install(Self.fullManifest)
        let off = try install(#"{"manifest_version": 3, "name": "Off Everywhere", "version": "1.0"}"#, isEnabled: false)
        let profile = makeProfile()
        let pane = laidOut(ProfilesSettingsViewController())
        try show(profile, in: pane)
        let rows = try XCTUnwrap(pane.formRows[.extensionSwitches])
        let section = try XCTUnwrap(pane.formSections[.extensions])
        XCTAssertEqual(section.rows.count, ExtensionManager.shared.extensions.count)
        let onRow = try XCTUnwrap(rows.first { ($0.accessoryView as? NSSwitch)?.identifier?.rawValue == on.id })
        let offRow = try XCTUnwrap(rows.first { ($0.accessoryView as? NSSwitch)?.identifier?.rawValue == off.id })
        XCTAssertEqual(onRow.titleLabel?.stringValue, "Form Test Extension")
        XCTAssertTrue(onRow.isEnabled)
        XCTAssertTrue(onRow.helpLabel.isHidden)
        XCTAssertFalse(offRow.isEnabled)
        XCTAssertEqual((offRow.accessoryView as? NSSwitch)?.isEnabled, false)
        XCTAssertEqual(offRow.helpLabel.stringValue, ProfilesSettingsViewController.extensionOffEverywhereHelp)
        XCTAssertNotNil(offRow.titleLabel?.toolTip)
        // Rebuilt when the extensions change: one fewer, one fewer row.
        ExtensionManager.shared.extensions.removeAll { $0.id == off.id }
        NotificationCenter.default.post(name: ExtensionManager.extensionsDidChangeNotification, object: nil)
        XCTAssertEqual(section.rows.count, ExtensionManager.shared.extensions.count)
        XCTAssertFalse(section.rows.contains { $0 === offRow })
        pane.viewWillDisappear()
    }

    /// Measured before its first layout (as the window measures it before
    /// showing it), the pane asks for the height it has once laid out.
    @MainActor func testProfilesFirstMeasurementIsItsLaidOutHeight() throws {
        _ = try install(Self.fullManifest)
        let profile = makeProfile { $0.userAgentMode = .custom; $0.customUserAgent = "Test Agent/1.0" }
        let pane = ProfilesSettingsViewController()
        _ = pane.view
        useOverlayScrollers(in: pane)
        pane.viewWillAppear()
        try show(profile, in: pane, layOut: false)
        let cold = pane.naturalContentHeight
        pane.view.setFrameSize(NSSize(width: SettingsMetrics.windowWidth, height: cold))
        pane.view.layoutSubtreeIfNeeded()
        pane.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(pane.naturalContentHeight, cold, accuracy: 0.5)
    }

    /// Another profile with other rows asks for another height: the window
    /// follows the selection (Private has the note and no archiving or
    /// External Apps; a custom user agent adds its row).
    @MainActor func testSelectingAnotherProfileChangesTheNaturalHeight() throws {
        _ = try install(Self.fullManifest)
        let custom = makeProfile { $0.userAgentMode = .custom; $0.customUserAgent = "Test Agent/1.0" }
        let plain = makeProfile()
        let pane = laidOut(ProfilesSettingsViewController())
        useOverlayScrollers(in: pane)
        // Each profile's natural height and its Identify as row's height
        // (the preview under it is as long as the profile's user agent).
        var heights: [CGFloat] = [], previews: [CGFloat] = []
        for profile in [try privateProfile(), plain, custom] {
            try show(profile, in: pane)
            heights.append(pane.naturalContentHeight)
            previews.append(pane.userAgentRow.frame.height)
        }
        let rows = { (row: ProfileSettingsRow) in pane.formRows[row]?.first?.frame.height ?? 0 }
        // Plain: the archive row and External Apps in, the private note out.
        let externalApps = try XCTUnwrap(pane.formSections[.externalApps])
        XCTAssertEqual(heights[1] - heights[0],
                       rows(.archiveTabs) + SettingsMetrics.formSectionGap + externalApps.frame.height
                        - (try XCTUnwrap(pane.formRows[.privateNote]?.first).frame.height)
                        + previews[1] - previews[0], accuracy: 1)
        // Custom: its string's row in, its shorter preview.
        XCTAssertEqual(heights[2] - heights[1], rows(.customUserAgent) + previews[2] - previews[1], accuracy: 1)
    }

    // MARK: - Extensions

    /// The header row (icon, name, version, description, Settings…), the
    /// source row with Reload, Enabled, Profiles with Turn On in All Profiles
    /// and its summary, Allow in Private with its note, and the permissions:
    /// one named switch per permission, the optional ones in a section of
    /// their own; every control on the form's right edge.
    @MainActor func testExtensionsDetailIsAForm() throws {
        let ext = try install(Self.fullManifest)
        ext.sourcePath = URL(fileURLWithPath: "/tmp/form-test-extension")
        ExtensionManager.shared.extensions = [ext]  // the pane shows the first one
        let pane = laidOut(ExtensionsSettingsViewController())
        let form = try form(in: pane)
        assertSharedEdges(form, in: pane, "extension")

        XCTAssertEqual(form.sections.map { $0.titleLabel?.stringValue },
                       [nil, nil, "Permissions", "Optional Permissions"])
        // The header and source, as System Settings' top group.
        let top = form.sections[0].rows
        XCTAssertNil(top[0].titleLabel, "the header is a row of its own")
        let headerTexts = descendants(of: top[0]).compactMap { view -> String? in
            guard let label = view as? NSTextField, !label.isHidden else { return nil }
            return label.stringValue
        }
        XCTAssertEqual(headerTexts, ["Form Test Extension", "Version 2.1.0", "An extension with every kind of permission row."])
        let settings = try XCTUnwrap(descendants(of: top[0]).compactMap { $0 as? NSButton }.first)
        XCTAssertEqual(settings.title, "Settings…")
        XCTAssertEqual(placed(settings, in: pane.view).maxX,
                       placed(form, in: pane.view).maxX - SettingsMetrics.formRowInsetX, accuracy: 0.5)
        XCTAssertEqual(top[1].titleLabel?.stringValue, "Loaded unpacked")
        XCTAssertEqual((top[1].accessoryView as? NSButton)?.title, "Reload")

        let enabling = form.sections[1].rows
        XCTAssertEqual(enabling.map { $0.titleLabel?.stringValue }, ["Enabled", "Profiles", "Allow in Private"])
        let allProfiles = try XCTUnwrap(enabling[1].accessoryView as? NSButton)
        XCTAssertEqual(allProfiles.identifier?.rawValue, "turnOnInAllProfiles")
        XCTAssertEqual(allProfiles.title, "Turn On in All Profiles")
        XCTAssertEqual(enabling[1].helpLabel.identifier?.rawValue, "extensionProfilesSummary")
        XCTAssertTrue(enabling[1].helpLabel.stringValue.hasSuffix("Turn it on or off per profile in Settings › Profiles."))
        XCTAssertTrue(enabling[2].helpLabel.stringValue.hasPrefix("Extensions allowed in Private windows"))
        XCTAssertEqual((enabling[0].accessoryView as? NSSwitch)?.accessibilityLabel(), "Enabled")
        XCTAssertEqual((enabling[2].accessoryView as? NSSwitch)?.accessibilityLabel(), "Allow in Private")

        // A switch per permission, its identifier what `permissionToggled` parses.
        let required = form.sections[2].rows
        let optional = form.sections[3].rows
        XCTAssertEqual(required.count, 3, "storage, tabs, all websites")
        XCTAssertEqual(optional.count, 2, "cookies, example.org")
        XCTAssertEqual(required.last?.titleLabel?.stringValue, "All websites")
        let api = ExtensionPermissionType.apiPermission.rawValue, pattern = ExtensionPermissionType.matchPattern.rawValue
        XCTAssertEqual((required + optional).compactMap { ($0.accessoryView as? NSSwitch)?.identifier?.rawValue },
                       ["\(ext.id)\tstorage\t\(api)", "\(ext.id)\ttabs\t\(api)", "\(ext.id)\t<all_urls>\t\(pattern)",
                        "\(ext.id)\tcookies\t\(api)", "\(ext.id)\thttps://example.org/*\t\(pattern)"])
        for row in required + optional {
            let toggle = try XCTUnwrap(row.accessoryView as? NSSwitch)
            XCTAssertEqual(toggle.accessibilityLabel(), row.titleLabel?.stringValue)
            XCTAssertEqual(toggle.state, .off, "nothing saved, nothing granted")
        }
    }

    /// Turned off everywhere, Allow in Private keeps its choice but is off
    /// (switch disabled, name dimmed), with the reason as its tooltip.
    @MainActor func testAllowInPrivateIsOffWhileTheExtensionIsOff() throws {
        let ext = try install(Self.fullManifest, isEnabled: false)
        ExtensionManager.shared.extensions = [ext]
        let pane = laidOut(ExtensionsSettingsViewController())
        let row = try XCTUnwrap(visibleRows(of: try form(in: pane)).first { $0.titleLabel?.stringValue == "Allow in Private" })
        XCTAssertFalse(row.isEnabled)
        XCTAssertEqual((row.accessoryView as? NSSwitch)?.isEnabled, false)
        XCTAssertEqual(row.titleLabel?.toolTip, "Form Test Extension is turned off for all profiles")
    }

    /// Permissions an update added wait in a row of their own, between the
    /// source and Enabled, with the one button that accepts them.
    @MainActor func testPendingPermissionsAreARowWithTheirButton() throws {
        let ext = try install(Self.fullManifest)
        ext.pendingPermissionApproval = .init(version: "2.2.0",
                                              delta: .init(permissions: ["history"], hostPermissions: []))
        ExtensionManager.shared.extensions = [ext]
        let pane = laidOut(ExtensionsSettingsViewController())
        let form = try form(in: pane)
        XCTAssertEqual(Array(form.sections.map { $0.rows.first?.titleLabel?.stringValue }.prefix(3).dropFirst()),
                       ["Version 2.2.0 needs new permissions", "Enabled"])
        let row = try XCTUnwrap(form.sections[1].rows.first)
        XCTAssertEqual((row.accessoryView as? NSButton)?.title, "Accept and Enable")
        XCTAssertEqual(row.helpLabel.stringValue,
                       ExtensionPermissionDescriptions.formatForAlert(permissions: ["history"], hostPermissions: []))
        XCTAssertEqual(row.warning, ExtensionsSettingsViewController.pendingPermissionsWarning)
        assertSharedEdges(form, in: pane, "pending")
    }

    @MainActor func testAnExtensionWithoutPermissionsSaysSo() throws {
        let ext = try install(#"{"manifest_version": 3, "name": "Bare", "version": "1.0"}"#)
        ExtensionManager.shared.extensions = [ext]
        let pane = laidOut(ExtensionsSettingsViewController())
        let last = try XCTUnwrap(try form(in: pane).sections.last)
        XCTAssertEqual(last.titleLabel?.stringValue, "Permissions")
        XCTAssertEqual(last.rows.map(\.helpLabel.stringValue), ["No special permissions requested."])
        XCTAssertNil(last.rows.first?.titleLabel, "a footnote")
    }

    /// The pane keeps only its own Learn more link (an extension's details
    /// link none), and its first measurement is its laid-out height.
    @MainActor func testExtensionsLinksAndFirstMeasurement() throws {
        ExtensionManager.shared.extensions = [try install(Self.fullManifest)]
        let pane = ExtensionsSettingsViewController()
        _ = pane.view
        useOverlayScrollers(in: pane)
        pane.viewWillAppear()
        let cold = pane.naturalContentHeight
        pane.view.setFrameSize(NSSize(width: SettingsMetrics.windowWidth, height: cold))
        pane.view.layoutSubtreeIfNeeded()
        pane.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(pane.naturalContentHeight, cold, accuracy: 0.5)
        XCTAssertEqual(descendants(of: pane.view).compactMap { ($0 as? SettingsGuideLink)?.page }, [.webExtensions])
    }

    // MARK: - The form's additions

    /// A section's rows can be replaced: the group takes the new rows'
    /// height, wraps them at its width and draws separators between them.
    @MainActor func testASectionsRowsCanBeReplaced() throws {
        let section = SettingsFormSection(title: "Extensions", rows: [SettingsFormRow(title: "One")])
        let form = SettingsForm(sections: [section], estimatedWidth: SettingsMetrics.detailColumnWidth)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: SettingsMetrics.detailColumnWidth, height: 600))
        host.addSubview(form)
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: host.topAnchor),
            form.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            form.widthAnchor.constraint(equalToConstant: SettingsMetrics.detailColumnWidth),
        ])
        host.layoutSubtreeIfNeeded()
        let one = section.group.frame.height
        let longName = String(repeating: "A long extension name ", count: 6)
        let rows = [SettingsFormRow(title: "Two", accessory: .toggle(NSSwitch())),
                    SettingsFormRow(title: longName, accessory: .toggle(NSSwitch()))]
        section.setRows(rows)
        // Measured before the next layout: already wrapped at the group's width.
        let measured = form.fittingSize.height
        host.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(section.rows.count, 2)
        XCTAssertTrue(section.rows[0] === rows[0])
        XCTAssertEqual(section.group.frame.height, rows[0].frame.height + rows[1].frame.height, accuracy: 0.5)
        XCTAssertGreaterThan(section.group.frame.height, one)
        XCTAssertGreaterThan(try XCTUnwrap(rows[1].titleLabel).frame.height, SettingsFormRow.titleLineHeight * 1.5,
                             "the long name wraps")
        XCTAssertEqual(measured, form.frame.height, accuracy: 0.5)
        section.setRows([])
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(section.group.frame.height, 0, accuracy: 0.5)
    }

    /// A content row is its view across the row, inside the row's insets.
    @MainActor func testAContentRowSpansTheRowInsideItsInsets() {
        let content = NSView()
        content.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let row = SettingsFormRow(content: content)
        let section = SettingsFormSection(rows: [row])
        let form = SettingsForm(sections: [section], estimatedWidth: 400)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        host.addSubview(form)
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: host.topAnchor),
            form.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            form.widthAnchor.constraint(equalToConstant: 400),
        ])
        host.layoutSubtreeIfNeeded()
        let frame = content.convert(content.bounds, to: row)
        XCTAssertEqual(frame.minX, SettingsMetrics.formRowInsetX, accuracy: 0.5)
        XCTAssertEqual(frame.width, 400 - 2 * SettingsMetrics.formRowInsetX, accuracy: 0.5)
        XCTAssertEqual(row.frame.height, 40 + 2 * SettingsMetrics.formRowInsetY, accuracy: 0.5)
        XCTAssertNil(row.titleLabel)
        XCTAssertTrue(row.helpLabel.isHidden)
    }
}
