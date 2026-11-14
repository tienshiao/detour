// TASK-327 spike 3: path-form timing (parent titled before or after the items) and precedence over a plain title.
// Build: xcrun swiftc -module-cache-path "$TMPDIR/swift-mc" -o spike3 user-key-equivalents-3.swift (sandbox off to run: it talks to the window server).
// Run: ./spike3 -NSUserKeyEquivalents '{ "\033File\033Copy URL" = "@~1"; "\033Edit\033Copy URL" = "@~2"; "\033View\033Zoom\033Zoom In" = "@~3"; "Back" = "@~4"; "\033Navigate\033Back" = "@~5"; }'

import AppKit

final class Target: NSObject { @objc func fire(_ sender: NSMenuItem) {} }

func d(_ item: NSMenuItem, _ label: String) {
    let mask = item.keyEquivalentModifierMask
    var m = ""
    if mask.contains(.control) { m += "^" }; if mask.contains(.option) { m += "~" }
    if mask.contains(.shift) { m += "$" }; if mask.contains(.command) { m += "@" }
    print("[\(label)] parent='\(item.parent?.title ?? "-")' '\(item.title)': key=\(item.keyEquivalent.debugDescription) mask=\(m) user=\(item.userKeyEquivalent.debugDescription)")
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let t = Target()
    let main = NSMenu()
    // F: Detour's order with a titled parent: items added before the submenu is attached.
    let fParent = NSMenuItem(title: "File", action: nil, keyEquivalent: ""); main.addItem(fParent)
    let fMenu = NSMenu(title: "File")
    let f = NSMenuItem(title: "Copy URL", action: #selector(Target.fire(_:)), keyEquivalent: "C"); f.target = t
    fMenu.addItem(f)
    d(f, "F before attach")
    fParent.submenu = fMenu
    d(f, "F after attach")
    // G: untitled parent, retitled after the items are in.
    let gParent = NSMenuItem(); main.addItem(gParent)
    let gMenu = NSMenu(title: "Edit")
    let g = NSMenuItem(title: "Copy URL", action: #selector(Target.fire(_:)), keyEquivalent: "C"); g.target = t
    gMenu.addItem(g)
    gParent.submenu = gMenu
    gParent.title = "Edit"
    d(g, "G parent retitled after")
    // H: nested submenu path.
    let hParent = NSMenuItem(title: "View", action: nil, keyEquivalent: ""); main.addItem(hParent)
    let hMenu = NSMenu(title: "View"); hParent.submenu = hMenu
    let sub = NSMenuItem(title: "Zoom", action: nil, keyEquivalent: ""); hMenu.addItem(sub)
    let subMenu = NSMenu(title: "Zoom"); sub.submenu = subMenu
    let h = NSMenuItem(title: "Zoom In", action: #selector(Target.fire(_:)), keyEquivalent: "+"); h.target = t
    subMenu.addItem(h)
    d(h, "H nested")
    // I: plain title and path both present: which wins?
    let iParent = NSMenuItem(title: "Navigate", action: nil, keyEquivalent: ""); main.addItem(iParent)
    let iMenu = NSMenu(title: "Navigate"); iParent.submenu = iMenu
    let i = NSMenuItem(title: "Back", action: #selector(Target.fire(_:)), keyEquivalent: "["); i.target = t
    iMenu.addItem(i)
    d(i, "I plain+path")
    app.mainMenu = main
    d(f, "F after mainMenu"); d(g, "G after mainMenu")
    // A user key equivalent for an item with none of its own, then setting a key in code.
    exit(0)
}
NSApplication.shared.run()
