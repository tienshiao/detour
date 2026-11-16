// TASK-346 runtime helper: reads the Quick Detour launcher panel's field and Detour's Edit menu through
// Accessibility. Needs Accessibility for the shell's host; build:
//   xcrun swiftc -module-cache-path "$TMPDIR/swift-mc" -o axlauncher axlauncher.swift   (sandbox off to run)
// usage:
//   axlauncher field <pid>     -> the launcher panel's text field value ("<none>" when no panel is up)
//   axlauncher editmenu <pid>  -> opens Detour's Edit menu, prints Undo's and Redo's titles and enabled
//                                 state as validation left them, and closes the menu (Detour must be active)
import AppKit
import ApplicationServices

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
}
func children(_ e: AXUIElement) -> [AXUIElement] { attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func str(_ e: AXUIElement, _ name: String) -> String? { attr(e, name) as? String }

let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[2]) else { print("usage: axlauncher field|editmenu <pid>"); exit(2) }
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 5)

switch args[1] {
case "field":
    let windows = attr(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
    guard let panel = windows.first(where: { str($0, kAXTitleAttribute) == "Quick Detour" }) else { print("<none>"); exit(0) }
    var found: AXUIElement?
    func look(_ e: AXUIElement, _ d: Int) {
        if found != nil || d > 12 { return }
        if str(e, kAXRoleAttribute) == "AXTextField" { found = e; return }
        for c in children(e) { look(c, d + 1) }
    }
    look(panel, 0)
    guard let field = found else { print("<no field>"); exit(1) }
    print("value=\"\(str(field, kAXValueAttribute) ?? "")\"")
case "editmenu":
    guard let bar = attr(app, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() else { print("no menu bar"); exit(1) }
    guard let edit = children(bar as! AXUIElement).first(where: { str($0, kAXTitleAttribute) == "Edit" }) else { print("no Edit"); exit(1) }
    AXUIElementPerformAction(edit, kAXPressAction as CFString)
    usleep(400_000)
    for menu in children(edit) where str(menu, kAXRoleAttribute) == "AXMenu" {
        for item in children(menu) {
            guard let title = str(item, kAXTitleAttribute), title.hasPrefix("Undo") || title.hasPrefix("Redo") else { continue }
            print("\(title) enabled=\((attr(item, kAXEnabledAttribute) as? Bool) ?? false)")
        }
        AXUIElementPerformAction(menu, kAXCancelAction as CFString)
    }
    AXUIElementPerformAction(edit, kAXCancelAction as CFString)
default:
    print("unknown"); exit(2)
}
