// TASK-375 spike 1: does AppKit's menu matching treat Fn (the Globe key, NSEvent.ModifierFlags.function) as part of an
// item's key equivalent? AppKit's own Fn items (Edit's Start Dictation fn-D and Emoji & Symbols fn-E, which it inserts
// into a menu titled "Edit") and an app's items against CGEvents with and without the Fn flag.
// Build: xcrun swiftc -module-cache-path "$TMPDIR/swift-mc" -o fn fn-items.swift (sandbox off to run: it shows a window).
// Result (macOS 26, US layout, 2026-11-16):
//   - An app's own item cannot hold Fn: AppKit logs "NSEventModifierFlagFunction specified to
//     -setKeyEquivalentModifierMask: ... is only supported for system-provided menu items; will not be used" and drops it
//     (the "App fn⌃K" item reads ⌃K, fires on ⌃K and not on fn+⌃K).
//   - AppKit inserted Start Dictation "d" fn and Emoji & Symbols "e" fn (hidden, allowsKeyEquivalentWhenHidden) next to
//     Emoji & Symbols on ⌘Space and ⌃⌘Space; no Window menu tiling items appeared (windowsMenu set, one window).
//   - fn+E opened the character palette (handled), E alone did nothing: the Fn item needs Fn.
//   - ⌘E fired a ⌘E item, fn+⌘E fired nothing; ⌃G fired a ⌃G item, fn+⌃G nothing: an item without Fn does not fire
//     on a press holding Fn, on a key with a character. (fn+D was not handled either: dictation is off on this Mac.)
//   - Arrow and function keys carry Fn on every press (a key event's default flags: ← fn+numericPad, F5 fn, F none),
//     and a ⌃→ item fired on ⌃→ with or without the Fn flag set by hand.
import AppKit
import Carbon.HIToolbox

final class Target: NSObject {
    var fired: [String] = []
    @objc func fire(_ sender: NSMenuItem) { fired.append(sender.title) }
}
func cgKeyEvent(_ code: Int, _ flags: CGEventFlags?) -> NSEvent {
    let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true)!
    if let flags { e.flags = flags }
    return NSEvent(cgEvent: e)!
}
func describe(_ flags: NSEvent.ModifierFlags) -> String {
    var s = ""
    if flags.contains(.function) { s += "fn" }
    if flags.contains(.numericPad) { s += "#" }
    if flags.contains(.control) { s += "⌃" }
    if flags.contains(.option) { s += "⌥" }
    if flags.contains(.shift) { s += "⇧" }
    if flags.contains(.command) { s += "⌘" }
    return s
}

func dump(_ menu: NSMenu, _ indent: String = "   ") {
    for item in menu.items where !item.isSeparatorItem {
        let fn = item.keyEquivalentModifierMask.contains(.function)
        if !item.keyEquivalent.isEmpty || item.submenu != nil {
            print("\(indent)\(item.title) key=\(item.keyEquivalent.debugDescription) mask=\(describe(item.keyEquivalentModifierMask))\(fn ? " (Fn)" : "") hidden=\(item.isHidden) whenHidden=\(item.allowsKeyEquivalentWhenHidden) action=\(item.action.map(NSStringFromSelector) ?? "nil")")
        }
        if let sub = item.submenu { dump(sub, indent + "   ") }
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    let t = Target()
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = NSApplication.shared
        // What a key event for an arrow key carries when its flags are not set by hand.
        for code in [kVK_LeftArrow, kVK_F5, kVK_ANSI_F] {
            let e = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: CGKeyCode(code), keyDown: true)!
            print("default flags of key \(code): ns=\(describe(NSEvent(cgEvent: e)!.modifierFlags))")
        }
        let main = NSMenu()
        func add(_ title: String, _ items: [(String, String, NSEvent.ModifierFlags)]) -> NSMenu {
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: ""); main.addItem(top)
            let menu = NSMenu(title: title); top.submenu = menu
            for (title, key, mask) in items {
                let item = NSMenuItem(title: title, action: #selector(Target.fire(_:)), keyEquivalent: key)
                item.keyEquivalentModifierMask = mask; item.target = t; menu.addItem(item)
            }
            return menu
        }
        _ = add("App", [])
        _ = add("Edit", [("Copy", "c", [.command])])
        let windowMenu = add("Window", [("Minimize", "m", [.command])])
        // An app's own item given Fn: AppKit logs that it is only supported for system-provided items and drops it.
        _ = add("Plain", [("Plain ⌃G", "g", [.control]), ("Plain ⌘E", "e", [.command]), ("Right ⌃→", "\u{F703}", [.control]),
                          ("App fn⌃K", "k", [.control, .function])])
        app.mainMenu = main
        app.windowsMenu = windowMenu
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 200), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.run(main) }
    }
    func run(_ main: NSMenu) {
        // AppKit inserts its items when a menu updates.
        for item in main.items { item.submenu?.update() }
        print("== the bar after AppKit's insertions")
        dump(main)
        let cases: [(String, Int, CGEventFlags)] = [
            ("⌃F      ", kVK_ANSI_F, [.maskControl]),
            ("fn⌃F    ", kVK_ANSI_F, [.maskControl, .maskSecondaryFn]),
            ("⌃C      ", kVK_ANSI_C, [.maskControl]),
            ("fn⌃C    ", kVK_ANSI_C, [.maskControl, .maskSecondaryFn]),
            ("⌃K      ", kVK_ANSI_K, [.maskControl]),
            ("fn⌃K    ", kVK_ANSI_K, [.maskControl, .maskSecondaryFn]),
            ("⌃G      ", kVK_ANSI_G, [.maskControl]),
            ("fn⌃G    ", kVK_ANSI_G, [.maskControl, .maskSecondaryFn]),
            ("E       ", kVK_ANSI_E, []),
            ("fnE     ", kVK_ANSI_E, [.maskSecondaryFn]),
            ("D       ", kVK_ANSI_D, []),
            ("fnD     ", kVK_ANSI_D, [.maskSecondaryFn]),
            ("⌘E      ", kVK_ANSI_E, [.maskCommand]),
            ("fn⌘E    ", kVK_ANSI_E, [.maskCommand, .maskSecondaryFn]),
            ("⌃←      ", kVK_LeftArrow, [.maskControl]),
            ("fn#⌃←   ", kVK_LeftArrow, [.maskControl, .maskSecondaryFn, .maskNumericPad]),
            ("⌃→      ", kVK_RightArrow, [.maskControl]),
            ("fn#⌃→   ", kVK_RightArrow, [.maskControl, .maskSecondaryFn, .maskNumericPad]),
        ]
        for (label, code, flags) in cases {
            t.fired = []
            let event = cgKeyEvent(code, flags)
            let handled = main.performKeyEquivalent(with: event)
            print("\(label): ns=\(describe(event.modifierFlags)) handled=\(handled) fired=\(t.fired)")
        }
        exit(0)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = Delegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
