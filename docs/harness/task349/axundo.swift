// TASK-349 runtime helper: reads and focuses text fields in Detour's windows (Settings, its sheets, an
// extension's popup) and reads Detour's Edit menu, through Accessibility. Needs Accessibility for the
// shell's host; build:
//   xcrun swiftc -module-cache-path "$TMPDIR/swift-mc" -o axundo axundo.swift   (sandbox off to run)
// usage:
//   axundo windows <pid>               -> every window's title and role
//   axundo focused <pid>               -> the focused element's role and value
//   axundo focusedwindow <pid>         -> the focused window's title, role and subrole
//   axundo fields <pid> <window>       -> the text fields in the window titled <window> (index, value)
//   axundo focus <pid> <window> <n>    -> focuses the window and its n-th text field
//   axundo press <pid> <window> <name> -> presses the button with that title, description or identifier
//   axundo editmenu <pid>              -> opens Detour's Edit menu, prints Undo's and Redo's titles and
//                                         enabled state as validation left them, and closes the menu
import AppKit
import ApplicationServices

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
}
func children(_ e: AXUIElement) -> [AXUIElement] { attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func str(_ e: AXUIElement, _ name: String) -> String? { attr(e, name) as? String }

let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[2]) else { print("usage: axundo windows|focused|fields|focus|editmenu <pid> ..."); exit(2) }
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 5)

func windows() -> [AXUIElement] { attr(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] }
func window(titled title: String) -> AXUIElement? { windows().first { str($0, kAXTitleAttribute) == title } }
func textFields(in e: AXUIElement) -> [AXUIElement] {
    var found: [AXUIElement] = []
    func look(_ e: AXUIElement, _ d: Int) {
        if d > 25 { return }
        if str(e, kAXRoleAttribute) == "AXTextField" { found.append(e); return }
        for c in children(e) { look(c, d + 1) }
    }
    look(e, 0)
    return found
}

switch args[1] {
case "windows":
    for w in windows() {
        print("\(str(w, kAXTitleAttribute) ?? "") role=\(str(w, kAXRoleAttribute) ?? "") subrole=\(str(w, kAXSubroleAttribute) ?? "")")
    }
case "focusedwindow":
    guard let e = attr(app, kAXFocusedWindowAttribute), CFGetTypeID(e) == AXUIElementGetTypeID() else { print("<none>"); exit(0) }
    let w = e as! AXUIElement
    print("title=\"\(str(w, kAXTitleAttribute) ?? "")\" role=\(str(w, kAXRoleAttribute) ?? "") subrole=\(str(w, kAXSubroleAttribute) ?? "")")
case "focused":
    guard let e = attr(app, kAXFocusedUIElementAttribute), CFGetTypeID(e) == AXUIElementGetTypeID() else { print("<none>"); exit(0) }
    let el = e as! AXUIElement
    print("role=\(str(el, kAXRoleAttribute) ?? "") value=\"\(str(el, kAXValueAttribute) ?? "")\"")
case "fields":
    guard args.count >= 4, let w = window(titled: args[3]) else { print("<no window>"); exit(1) }
    for (i, f) in textFields(in: w).enumerated() { print("\(i) value=\"\(str(f, kAXValueAttribute) ?? "")\" id=\(str(f, kAXIdentifierAttribute) ?? "")") }
case "focus":
    guard args.count >= 5, let w = window(titled: args[3]), let n = Int(args[4]) else { print("<no window>"); exit(1) }
    AXUIElementPerformAction(w, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
    let fields = textFields(in: w)
    guard fields.indices.contains(n) else { print("<no field \(n)>"); exit(1) }
    let status = AXUIElementSetAttributeValue(fields[n], kAXFocusedAttribute as CFString, kCFBooleanTrue)
    print("focus \(n): \(status.rawValue)")
case "press":
    guard args.count >= 5, let w = window(titled: args[3]) else { print("<no window>"); exit(1) }
    var target: AXUIElement?
    func look(_ e: AXUIElement, _ d: Int) {
        if target != nil || d > 25 { return }
        if str(e, kAXRoleAttribute) == "AXButton",
           [str(e, kAXTitleAttribute), str(e, kAXDescriptionAttribute), str(e, kAXIdentifierAttribute)].contains(args[4]) {
            target = e; return
        }
        for c in children(e) { look(c, d + 1) }
    }
    look(w, 0)
    guard let button = target else { print("<no button \(args[4])>"); exit(1) }
    print("press \(args[4]): \(AXUIElementPerformAction(button, kAXPressAction as CFString).rawValue)")
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
