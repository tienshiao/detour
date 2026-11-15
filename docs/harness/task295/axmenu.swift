// TASK-295 runtime helper: reads a bar menu of a running app through Accessibility. Build: xcrun swiftc -module-cache-path "$TMPDIR/swift-mc" -o axmenu axmenu.swift; sandbox off.
// The rest of the runtime check used axdrive.swift here (key events posted to the pid, focus for the Shortcuts search field) and world.json (ten spaces, for seed_world).
// TASK-295 runtime helper: reads a bar menu of an app through Accessibility (titles, shortcut char and modifiers, hidden items are absent).
// Usage: axmenu <pid> <menu title>
import AppKit
import ApplicationServices
func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
}
let pid = pid_t(CommandLine.arguments[1])!
let wanted = CommandLine.arguments[2]
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 5)
guard let bar = attr(app, kAXMenuBarAttribute) else { print("no menu bar"); exit(1) }
let barItems = attr(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] ?? []
for item in barItems where (attr(item, kAXTitleAttribute) as? String) == wanted {
    let menus = attr(item, kAXChildrenAttribute) as? [AXUIElement] ?? []
    for menu in menus {
        for child in attr(menu, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            let title = attr(child, kAXTitleAttribute) as? String ?? ""
            let char = attr(child, "AXMenuItemCmdChar") as? String ?? ""
            let mods = attr(child, "AXMenuItemCmdModifiers") as? Int ?? -1
            let mark = attr(child, "AXMenuItemMarkChar") as? String ?? ""
            let enabled = attr(child, kAXEnabledAttribute) as? Bool ?? false
            print("\(title.isEmpty ? "---" : title) | cmd=\(char) mods=\(mods) mark=\(mark) enabled=\(enabled)")
        }
    }
}
