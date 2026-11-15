// TASK-334 runtime helper: the titles of a running app's menu-bar items through Accessibility (the "looks the same" check, before and after).
// Build: xcrun swiftc -module-cache-path "$TMPDIR/swift-mc" -o axbar axbar.swift; sandbox off to run. Usage: axbar <pid>
// The rest of the check: Detour launched (DETOUR_DATA_DIR + DETOUR_MCP=1) with
//   -NSUserKeyEquivalents '{ "\033File\033Close Tab" = "@~w"; "\033Detour\033Settings…" = "@~,"; "\033View\033Zoom In" = "@~="; "Show All History" = "@~y"; }'
// as a launch argument (never defaults write), then ../task295/axmenu.swift for each menu's shortcuts, run_menu_item key=cmd+opt+w,
// and ../task327/axdrive.swift find <pid> shortcut.tab.close in Settings > Shortcuts.
import AppKit
import ApplicationServices
func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
}
let app = AXUIElementCreateApplication(pid_t(CommandLine.arguments[1])!)
AXUIElementSetMessagingTimeout(app, 5)
guard let bar = attr(app, kAXMenuBarAttribute) else { print("no menu bar"); exit(1) }
for item in attr(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
    print("bar item: \((attr(item, kAXTitleAttribute) as? String ?? "nil").debugDescription)")
}
