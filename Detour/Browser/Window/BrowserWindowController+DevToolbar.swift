import AppKit
import Combine
import WebKit

/// Dev mode's in-page toolbar (TASK-186.2), per hosted pane. The toolbar lives
/// in the tab's `WebViewContainerView` (which lays it out); the window decides
/// whether each pane it hosts shows one and wires its controls to itself, so
/// whichever window owns the container drives it.
extension BrowserWindowController {

    /// The tabs whose containers this window has on screen: the selected
    /// tab, or both panes of its split. Empty while it shows a snapshot.
    var hostedPaneTabs: [BrowserTab] {
        guard let tab = selectedTab else { return [] }
        return splitMembers(of: tab).filter {
            $0.webViewContainer?.isDescendant(of: contentContainerView) == true
        }
    }

    /// Re-decides every hosted pane's toolbar and follows each pane's URL
    /// from here on. Runs at the end of every claim; the claim that hosts a
    /// container again replaces the sinks of the one before.
    func refreshDevToolbars() {
        devToolbarSubscriptions.removeAll()
        for tab in hostedPaneTabs {
            updateDevToolbar(for: tab)
            tab.$url
                .dropFirst()
                .removeDuplicates()
                .receive(on: RunLoop.main)
                .sink { [weak self, weak tab] _ in
                    guard let self, let tab else { return }
                    self.updateDevToolbar(for: tab)
                }
                .store(in: &devToolbarSubscriptions)
        }
        updateFindBarPlacement()
    }

    /// Shows or hides `tab`'s toolbar by `DevMode.isActive` for this window's
    /// profile, and points its controls at this window. Not for a pane hosted
    /// elsewhere: that window decides.
    func updateDevToolbar(for tab: BrowserTab) {
        guard let container = tab.webViewContainer, container.isDescendant(of: contentContainerView) else { return }
        let url = tab.url
        let shown = DevMode.isActive(for: url, profileID: activeSpace?.profile?.id)
        container.onDevToolbarLayoutChange = { [weak self] in self?.updateFindBarPlacement() }
        container.updateDevToolbar(shown: shown, url: url)
        if let toolbar = container.devToolbar {
            wireDevToolbar(toolbar, to: tab)
        }
    }

    /// The per-site switch (TASK-186.5) changes a pane's state with no
    /// navigation: follow it at once, as the sidebar rows do.
    @objc func handleSiteSettingsDidChange(_ notification: Notification) {
        guard notification.userInfo?[SiteSettingsStore.settingKey] as? SiteSetting == .devMode,
              let profileID = notification.userInfo?[SiteSettingsStore.profileIDKey] as? UUID,
              profileID == activeSpace?.profile?.id else { return }
        for tab in hostedPaneTabs {
            updateDevToolbar(for: tab)
        }
    }

    private func wireDevToolbar(_ toolbar: DevToolbarView, to tab: BrowserTab) {
        toolbar.onURLClick = { [weak self, weak tab] view in
            guard let self, let tab, self.focusPane(tab) else { return }
            self.openCommandPaletteInPlace(anchorFrame: self.paletteAnchorFrame(for: view))
        }
        toolbar.onInfoClick = { [weak self, weak tab] view in
            guard let self, let tab, self.focusPane(tab) else { return }
            self.showSiteSettingsPopover(relativeTo: view, fromAddressBar: false)
        }
        toolbar.onCopyClick = { [weak self, weak tab] in
            self?.copyURL(tab?.url)
        }
        wireCaptureButtons(of: toolbar, to: tab)
        wireInspectorButtons(of: toolbar, to: tab)
    }

    /// The capture buttons (TASK-186.3) capture this pane's own web view,
    /// which in a split may be the unfocused pane: like the inspector
    /// buttons, they focus the pane but act on their web view either way.
    private func wireCaptureButtons(of toolbar: DevToolbarView, to tab: BrowserTab) {
        let group = DevToolbarCaptureGroup.install(in: toolbar)
        group.onCapture = { [weak self, weak tab, weak group] kind, toFile in
            guard let self, let tab, let group else { return }
            _ = self.focusPane(tab)
            self.capturePage(kind, of: tab, toFile: toFile, group: group)
        }
    }

    /// Captures `tab`'s page and puts the PNG on the clipboard, or saves it
    /// to Downloads, with a toast either way.
    private func capturePage(_ kind: PageCapture.Kind, of tab: BrowserTab, toFile: Bool, group: DevToolbarCaptureGroup) {
        guard let webView = tab.webView else {
            toastManager.show(message: "Couldn’t capture the page")
            return
        }
        group.isCapturing = true
        let host = devModeHostLabel(for: tab.url)
        let date = Date()   // the click, not the end of a slow full-page capture
        PageCapture.capture(kind, of: webView) { [weak self, weak group] result in
            guard let self, case .success(let capture) = result else {
                group?.isCapturing = false
                self?.toastManager.show(message: "Couldn’t capture the page")
                return
            }
            let scaled = capture.scaledDown ? " (scaled down)" : ""
            guard toFile else {
                group?.isCapturing = false
                CaptureDelivery.copy(png: capture.png, to: self.capturePasteboard)
                let what = kind == .fullPage ? "Full-page screenshot" : "Screenshot"
                self.toastManager.show(message: "\(what) copied\(scaled)")
                return
            }
            let directory = self.captureSaveDirectory()
            let name = CaptureFileName.make(host: host, date: date, fullPage: kind == .fullPage)
            // A tall page's PNG is tens of MB: written off the main thread, on
            // one serial queue so two saves never pick the same free name.
            CaptureDelivery.saveQueue.async {
                let saved = Swift.Result { try CaptureDelivery.save(png: capture.png, name: name, in: directory) }
                DispatchQueue.main.async { [weak self, weak group] in
                    group?.isCapturing = false
                    guard let self else { return }
                    switch saved {
                    case .success(let url):
                        let folder = FileManager.default.displayName(atPath: directory.path)
                        self.toastManager.show(message: "Saved “\(url.lastPathComponent)” to \(folder)\(scaled)")
                    case .failure:
                        self.toastManager.show(message: "Couldn’t save the screenshot")
                    }
                }
            }
        }
    }

    /// The Console, Network and element picker buttons (TASK-186.4) act on
    /// this pane's own web view, which in a split may be the unfocused pane.
    /// They focus the pane first, as a click in its page would, but go on
    /// even if it did not take focus: unlike the palette and the popover,
    /// the inspector call names its web view, so it cannot land on the other
    /// pane.
    private func wireInspectorButtons(of toolbar: DevToolbarView, to tab: BrowserTab) {
        guard let group = DevToolbarInspectorGroup.install(in: toolbar) else { return }
        group.onToggle = { [weak self, weak tab] inspectorTab in
            guard let self, let tab, let webView = tab.webView else { return }
            _ = self.focusPane(tab)
            self.webInspectorToggler.toggle(inspectorTab, for: webView)
        }
        let toggler = webInspectorToggler
        let pickerState: (WKWebView) -> () -> Bool = { webView in
            { [weak webView] in webView.map { toggler.isElementSelectionActive(for: $0) } ?? false }
        }
        group.onPickElement = { [weak self, weak tab, weak group] in
            guard let self, let tab, let webView = tab.webView, let group else { return }
            _ = self.focusPane(tab)
            toggler.toggleElementSelection(for: webView)
            group.followElementPicker(pickerState(webView))
        }
        if let webView = tab.webView {
            group.syncElementPicker(pickerState(webView))
        }
    }

    /// The palette and the popover act on the focused pane (`displayTab`), so
    /// a click in the other pane's toolbar focuses that pane first, as a click
    /// in its page would. False when the pane did not take focus, so the
    /// caller does not act on the other pane instead.
    private func focusPane(_ tab: BrowserTab) -> Bool {
        guard tab.id != selectedTabID else { return true }
        guard let webView = tab.webView else { return false }
        window?.makeFirstResponder(webView)
        return selectedTabID == tab.id
    }

    /// Where the palette opens for a click on the URL: its top-left at the
    /// toolbar's top, level with the URL, kept inside the window.
    private func paletteAnchorFrame(for urlView: NSView) -> NSRect {
        let frame = urlView.convert(urlView.bounds, to: nil)
        guard let toolbar = urlView.superview else { return frame }
        let bar = toolbar.convert(toolbar.bounds, to: nil)
        let windowWidth = window?.contentView?.bounds.width ?? .greatestFiniteMagnitude
        let x = max(0, min(frame.minX - 8, windowWidth - CommandPaletteView.width - 8))
        return NSRect(x: x, y: bar.minY, width: frame.width, height: bar.height)
    }
}
