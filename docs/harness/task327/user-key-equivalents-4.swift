// TASK-327 spike 4: retitles and code writes under an App Shortcut (the code's key is kept underneath).
// Build: xcrun swiftc -module-cache-path "$TMPDIR/swift-mc" -o spike4 user-key-equivalents-4.swift (sandbox off to run: it talks to the window server).
// Run: ./spike4 -NSUserKeyEquivalents '{ "Unpin Tab" = "@~u"; "Reload Page" = "@~r"; }'

import AppKit

final class Target: NSObject { @objc func fire(_ sender: NSMenuItem) {} }

func d(_ item: NSMenuItem, _ label: String) {
    let mask = item.keyEquivalentModifierMask
    var m = ""
    if mask.contains(.control) { m += "^" }; if mask.contains(.option) { m += "~" }
    if mask.contains(.shift) { m += "$" }; if mask.contains(.command) { m += "@" }
    print("[\(label)] '\(item.title)': key=\(item.keyEquivalent.debugDescription) mask=\(m) user=\(item.userKeyEquivalent.debugDescription)")
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let t = Target()
    let main = NSMenu()
    let bar = NSMenuItem(); main.addItem(bar)
    let file = NSMenu(title: "File"); bar.submenu = file
    // Case 1: created "d", code sets "e", retitled to an overridden title, retitled back.
    let pin = NSMenuItem(title: "Pin Tab", action: #selector(Target.fire(_:)), keyEquivalent: "d"); pin.target = t
    file.addItem(pin)
    app.mainMenu = main
    d(pin, "1 created")
    pin.keyEquivalent = "e"; pin.keyEquivalentModifierMask = [.command, .option]
    d(pin, "1 code set ~@e")
    pin.title = "Unpin Tab"
    d(pin, "1 retitled to overridden")
    pin.title = "Pin Tab"
    d(pin, "1 retitled back")
    // Case 2: created with an override; code writes "e" while it applies; retitled to a title without one.
    let reload = NSMenuItem(title: "Reload Page", action: #selector(Target.fire(_:)), keyEquivalent: "r"); reload.target = t
    file.addItem(reload)
    d(reload, "2 created (override)")
    reload.keyEquivalent = "e"; reload.keyEquivalentModifierMask = [.command, .option]
    d(reload, "2 code set ~@e while overridden")
    reload.title = "Reload"
    d(reload, "2 retitled to no override")
    reload.title = "Reload Page"
    d(reload, "2 retitled back to overridden")
    // Case 3: code writes while not overridden, then a write while overridden, then back.
    reload.title = "Reload"
    reload.keyEquivalent = "k"; reload.keyEquivalentModifierMask = [.command, .shift]
    d(reload, "3 code set $@k, no override")
    reload.title = "Reload Page"
    reload.keyEquivalent = "j"; reload.keyEquivalentModifierMask = [.command]
    d(reload, "3 overridden, code set @j")
    reload.title = "Reload"
    d(reload, "3 back to no override")
    // Case 4: an empty key in code, override title, back.
    let arc = NSMenuItem(title: "Import", action: #selector(Target.fire(_:)), keyEquivalent: "i"); arc.target = t
    file.addItem(arc)
    arc.keyEquivalent = ""
    d(arc, "4 cleared in code")
    arc.title = "Unpin Tab"
    d(arc, "4 retitled to overridden")
    arc.title = "Import"
    d(arc, "4 back")
    exit(0)
}
NSApplication.shared.run()
