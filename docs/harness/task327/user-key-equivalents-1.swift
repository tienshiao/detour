// TASK-327 spike 1: when AppKit applies NSUserKeyEquivalents to a code-built menu, and whether a key set in code afterwards wins.
// Build: xcrun swiftc -module-cache-path "$TMPDIR/swift-mc" -o spike1 user-key-equivalents-1.swift (sandbox off to run: it talks to the window server).
// Run: ./spike1 -NSUserKeyEquivalents '{ "Reload Page" = "@~r"; "Unpin Tab" = "@~u"; "\033File\033Copy URL" = "@~c"; }' (the argument domain: nothing is written to defaults)

import AppKit

final class Target: NSObject {
    var fired: [String] = []
    @objc func fire(_ sender: NSMenuItem) { fired.append(sender.title) }
}

func describe(_ item: NSMenuItem, _ label: String) {
    let mask = item.keyEquivalentModifierMask
    var m = ""
    if mask.contains(.control) { m += "^" }
    if mask.contains(.option) { m += "~" }
    if mask.contains(.shift) { m += "$" }
    if mask.contains(.command) { m += "@" }
    print("[\(label)] '\(item.title)': keyEquivalent=\(item.keyEquivalent.debugDescription) mask=\(m) userKeyEquivalent=\(item.userKeyEquivalent.debugDescription)")
}

func key(_ chars: String, _ mods: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0,
                     context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 0)!
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    print("usesUserKeyEquivalents=\(NSMenuItem.usesUserKeyEquivalents)")
    print("NSUserKeyEquivalents (standard)=\(String(describing: UserDefaults.standard.dictionary(forKey: "NSUserKeyEquivalents")))")
    let target = Target()
    let main = NSMenu()
    let appItem = NSMenuItem(); main.addItem(appItem); appItem.submenu = NSMenu(title: "")
    let fileItem = NSMenuItem(); main.addItem(fileItem)
    let file = NSMenu(title: "File")
    let reload = NSMenuItem(title: "Reload Page", action: #selector(Target.fire(_:)), keyEquivalent: "r")
    reload.target = target
    describe(reload, "created")
    file.addItem(reload)
    describe(reload, "added to menu")
    let pin = NSMenuItem(title: "Pin Tab", action: #selector(Target.fire(_:)), keyEquivalent: "d")
    pin.target = target
    file.addItem(pin)
    let copy = NSMenuItem(title: "Copy URL", action: #selector(Target.fire(_:)), keyEquivalent: "C")
    copy.target = target
    file.addItem(copy)
    let none = NSMenuItem(title: "Import from Arc…", action: #selector(Target.fire(_:)), keyEquivalent: "")
    none.target = target
    file.addItem(none)
    fileItem.submenu = file
    app.mainMenu = main
    describe(reload, "mainMenu set")
    describe(pin, "mainMenu set")
    describe(copy, "mainMenu set")
    describe(none, "mainMenu set")

    // Detour sets a new key equivalent afterwards (a user binding).
    reload.keyEquivalent = "e"; reload.keyEquivalentModifierMask = [.command, .option]
    describe(reload, "after setting ~@e in code")
    // Retitled by validation.
    pin.title = "Unpin Tab"
    describe(pin, "retitled Unpin Tab")

    for (label, ev) in [("@~r", key("r", [.command, .option])), ("@~e", key("e", [.command, .option])),
                        ("@r", key("r", [.command])), ("@~u", key("u", [.command, .option])),
                        ("@d", key("d", [.command])), ("@~c", key("c", [.command, .option])),
                        ("@$C", key("C", [.command, .shift])), ("@~a", key("a", [.command, .option]))] {
        target.fired = []
        let handled = main.performKeyEquivalent(with: ev)
        print("performKeyEquivalent \(label): handled=\(handled) fired=\(target.fired)")
    }
    // After a run-loop turn (menu bar update).
    DispatchQueue.main.async {
        describe(reload, "after a run-loop turn")
        describe(pin, "after a run-loop turn")
        describe(none, "after a run-loop turn")
        exit(0)
    }
}
NSApplication.shared.run()
