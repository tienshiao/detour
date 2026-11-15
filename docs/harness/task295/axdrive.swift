// TASK-327 runtime helper (copied for TASK-295 with a "focus <pid> <identifier>" verb): Accessibility press, read and focus by identifier in Detour's Settings window, and key events posted to a process. Needs Accessibility for the shell's host; on a locked screen AX returns no windows.
// Build: xcrun swiftc -module-cache-path "$TMPDIR/swift-mc" -o axdrive axdrive.swift (sandbox off to run: it talks to the window server).
// Usage: see the comment below. AXWINDOW=<title> walks another window (a browser window's tree is slow to walk).

import AppKit
import ApplicationServices

// usage:
//   axdrive trusted
//   axdrive find <pid> <identifier>          -> prints role, value, enabled
//   axdrive press <pid> <identifier>
//   axdrive ids <pid> [prefix]               -> every AXIdentifier in the app's windows
//   axdrive key <pid> <keycode> [cmd,opt,ctrl,shift,fn]   (posted to the pid)
//   axdrive hidkey <keycode> [mods]          (posted at the HID tap: the frontmost app)

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
}

func walk(_ e: AXUIElement, depth: Int = 0, _ visit: (AXUIElement) -> Bool) -> Bool {
    if visit(e) { return true }
    guard depth < 40, let children = attr(e, kAXChildrenAttribute) as? [AXUIElement] else { return false }
    for child in children where walk(child, depth: depth + 1, visit) { return true }
    return false
}

func windows(_ pid: pid_t) -> [AXUIElement] {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 5)
    let all = attr(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
    // Only the Settings window unless AXWINDOW names another.
    let wanted = ProcessInfo.processInfo.environment["AXWINDOW"] ?? "Settings"
    return all.filter { (attr($0, kAXTitleAttribute) as? String) == wanted }
}

func find(_ pid: pid_t, _ identifier: String) -> AXUIElement? {
    var found: AXUIElement?
    for window in windows(pid) {
        if walk(window, { e in
            if (attr(e, kAXIdentifierAttribute) as? String) == identifier { found = e; return true }
            return false
        }) { break }
    }
    return found
}

func flags(_ text: String?) -> CGEventFlags {
    var f: CGEventFlags = []
    for part in (text ?? "").split(separator: ",") {
        switch part {
        case "cmd": f.insert(.maskCommand)
        case "opt": f.insert(.maskAlternate)
        case "ctrl": f.insert(.maskControl)
        case "shift": f.insert(.maskShift)
        case "fn": f.insert(.maskSecondaryFn)
        default: break
        }
    }
    return f
}

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage"); exit(2) }
switch args[1] {
case "trusted":
    print(AXIsProcessTrusted())
case "find":
    guard let e = find(pid_t(args[2])!, args[3]) else { print("not found"); exit(1) }
    print("role=\(attr(e, kAXRoleAttribute) ?? "nil" as AnyObject) value=\(attr(e, kAXValueAttribute) ?? "nil" as AnyObject) enabled=\(attr(e, kAXEnabledAttribute) ?? "nil" as AnyObject) title=\(attr(e, kAXTitleAttribute) ?? "nil" as AnyObject) desc=\(attr(e, kAXDescriptionAttribute) ?? "nil" as AnyObject)")
case "press":
    guard let e = find(pid_t(args[2])!, args[3]) else { print("not found"); exit(1) }
    let status = AXUIElementPerformAction(e, kAXPressAction as CFString)
    print("press \(args[3]): \(status.rawValue)")
case "ids":
    let prefix = args.count > 3 ? args[3] : ""
    for window in windows(pid_t(args[2])!) {
        print("window: \(attr(window, kAXTitleAttribute) ?? "" as AnyObject)")
        _ = walk(window, { e in
            if let id = attr(e, kAXIdentifierAttribute) as? String, id.hasPrefix(prefix) {
                print("  \(id) value=\(attr(e, kAXValueAttribute) ?? "nil" as AnyObject) enabled=\(attr(e, kAXEnabledAttribute) ?? "nil" as AnyObject)")
            }
            return false
        })
    }
case "focus":
    guard let e = find(pid_t(args[2])!, args[3]) else { print("not found"); exit(1) }
    print("focus: \(AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue).rawValue)")
case "key", "hidkey":
    let hid = args[1] == "hidkey"
    let pid = hid ? 0 : pid_t(args[2])!
    let code = CGKeyCode(args[hid ? 2 : 3])!
    let mods = flags(args.count > (hid ? 3 : 4) ? args[hid ? 3 : 4] : nil)
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { print("no event"); exit(1) }
        event.flags = mods
        if hid { event.post(tap: .cghidEventTap) } else { event.postToPid(pid) }
        usleep(30_000)
    }
    print("posted \(code) \(mods.rawValue) \(hid ? "hid" : "pid \(pid)")")
default:
    print("unknown"); exit(2)
}
