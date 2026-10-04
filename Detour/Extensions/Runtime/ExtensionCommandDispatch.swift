import AppKit
import WebKit
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "ext-commands")

/// Extension command shortcuts (`chrome.commands`, the manifest's `commands`).
///
/// WebKit keeps the commands and fires `commands.onCommand`, but it is the
/// app that has to notice the key press: nothing happens unless the host calls
/// `WKWebExtensionContext.performCommand(for:)`. Detour does so from
/// `BrowserWindow.performKeyEquivalent`, for a key equivalent that nothing in
/// the window's view tree took (TASK-132.8: the Claude extension's Cmd+E opens
/// and closes its side panel).
///
/// Who gets a key first:
///  1. the page — WebKit sends a Command-key press to the focused page before
///     anything else, and only an event the page declined comes back here;
///  2. Detour's own menu — an extension cannot take over Cmd+T or Cmd+W;
///  3. the extensions loaded in the window's profile, in id order, the first
///     one with a command for the key.
enum ExtensionCommandDispatch {

    /// Performs the extension command `event` is the shortcut of, if there is
    /// one in the profile `controller` is showing. False — nothing done, and
    /// the event is still AppKit's to route — when no loaded extension has a
    /// command for it.
    static func perform(_ event: NSEvent, in controller: BrowserWindowController,
                        mainMenu: NSMenu? = NSApp.mainMenu) -> Bool {
        guard event.type == .keyDown, let profile = controller.activeSpace?.profile,
              !profile.extensionContexts.isEmpty else { return false }
        // Snapshot: performing a command can load or unload a context.
        let contexts = profile.extensionContexts.sorted { $0.key < $1.key }
        guard let (extensionID, context) = contexts.first(where: { $0.value.command(for: event) != nil }) else {
            return false
        }
        // Detour's menu comes first. AppKit would ask it next anyway; asking
        // here only settles who wins when both claim the key.
        if let mainMenu, mainMenu.performKeyEquivalent(with: event) { return true }
        // The shortcut is a user gesture: a side panel the extension opens in
        // answer to it may take keyboard focus.
        profile.sidePanels.noteUserGesture(extensionID: extensionID)
        let performed = context.performCommand(for: event)
        if performed {
            log.info("Performed a command shortcut of \(extensionID, privacy: .public)")
        }
        return performed
    }
}
