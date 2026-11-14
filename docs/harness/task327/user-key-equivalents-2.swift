// TASK-327 spike 2: the menu-path form is matched against the parent items' titles (Detour's bar items are untitled).
// Build: xcrun swiftc -module-cache-path "$TMPDIR/swift-mc" -o spike2 user-key-equivalents-2.swift (sandbox off to run: it talks to the window server).
// Run: ./spike2 -NSUserKeyEquivalents '{ "\033File\033Copy URL" = "@~1"; "\033Edit\033Copy URL" = "@~2"; "\033View\033Copy URL" = "@~3"; }'

import AppKit

final class Target: NSObject { @objc func fire(_ sender: NSMenuItem) {} }

func d(_ item: NSMenuItem, _ label: String) {
    let mask = item.keyEquivalentModifierMask
    var m = ""
    if mask.contains(.control) { m += "^" }; if mask.contains(.option) { m += "~" }
    if mask.contains(.shift) { m += "$" }; if mask.contains(.command) { m += "@" }
    print("[\(label)] parent='\(item.parent?.title ?? "-")' menu='\(item.menu?.title ?? "-")' '\(item.title)': key=\(item.keyEquivalent.debugDescription) mask=\(m) user=\(item.userKeyEquivalent.debugDescription)")
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let t = Target()
    let main = NSMenu()
    // A: Detour's order: parent NSMenuItem() added to the bar, items added to the submenu, then submenu attached.
    let aParent = NSMenuItem(); main.addItem(aParent)
    print("NSMenuItem() title=\(aParent.title.debugDescription)")
    let aMenu = NSMenu(title: "File")
    let a = NSMenuItem(title: "Copy URL", action: #selector(Target.fire(_:)), keyEquivalent: "C"); a.target = t
    aMenu.addItem(a)
    d(a, "A before attach")
    aParent.submenu = aMenu
    d(a, "A after attach")
    print("A parent title after submenu=\(aParent.title.debugDescription)")
    // B: submenu attached first, then item added.
    let bParent = NSMenuItem(); main.addItem(bParent)
    let bMenu = NSMenu(title: "Edit"); bParent.submenu = bMenu
    let b = NSMenuItem(title: "Copy URL", action: #selector(Target.fire(_:)), keyEquivalent: "C"); b.target = t
    bMenu.addItem(b)
    d(b, "B added after attach")
    // C: parent titled explicitly.
    let cParent = NSMenuItem(title: "View", action: nil, keyEquivalent: ""); main.addItem(cParent)
    let cMenu = NSMenu(title: "View"); cParent.submenu = cMenu
    let c = NSMenuItem(title: "Copy URL", action: #selector(Target.fire(_:)), keyEquivalent: "C"); c.target = t
    cMenu.addItem(c)
    d(c, "C titled parent")
    app.mainMenu = main
    d(a, "A after mainMenu"); d(b, "B after mainMenu"); d(c, "C after mainMenu")
    // D: an item re-added (removed and inserted again) after the main menu is set.
    aMenu.removeItem(a); aMenu.addItem(a)
    d(a, "A re-added after mainMenu")
    // E: title set again to the same value.
    b.title = "Copy URL"
    d(b, "B title set again")
    DispatchQueue.main.async {
        d(a, "A later"); d(b, "B later"); d(c, "C later")
        exit(0)
    }
}
NSApplication.shared.run()
