// TASK-327 spike 5: AppKit's menu matching for a Shift+digit or Shift+punctuation item spelled unshifted, ⌥-only, ⌃⌥ and a bare function key, from real CGEvents.
// Build: xcrun swiftc -module-cache-path "$TMPDIR/swift-mc" -o spike5 menu-matching.swift (sandbox off to run: it talks to the window server).
// Run: ./spike5

import AppKit
import Carbon.HIToolbox

final class Target: NSObject {
    var fired: [String] = []
    @objc func fire(_ sender: NSMenuItem) { fired.append(sender.title) }
}

func cgKeyEvent(_ code: Int, _ flags: CGEventFlags) -> NSEvent {
    let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true)!
    e.flags = flags
    return NSEvent(cgEvent: e)!
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let t = Target()
    let main = NSMenu()
    let bar = NSMenuItem(title: "File", action: nil, keyEquivalent: ""); main.addItem(bar)
    let file = NSMenu(title: "File"); bar.submenu = file
    func add(_ title: String, _ key: String, _ mask: NSEvent.ModifierFlags) {
        let item = NSMenuItem(title: title, action: #selector(Target.fire(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = mask; item.target = t; file.addItem(item)
    }
    add("shift-cmd-1 as '1'+shift", "1", [.command, .shift])
    add("shift-cmd-= as '='+shift", "=", [.command, .shift])
    add("opt-cmd-e", "e", [.command, .option])
    add("opt-e", "e", [.option])
    add("F6 alone", String(UnicodeScalar(UInt16(NSF6FunctionKey))!), [])
    add("ctrl-opt-k", "k", [.control, .option])
    app.mainMenu = main
    let cases: [(String, NSEvent)] = [
        ("⇧⌘1 (real event)", cgKeyEvent(kVK_ANSI_1, [.maskShift, .maskCommand])),
        ("⇧⌘= (real event)", cgKeyEvent(kVK_ANSI_Equal, [.maskShift, .maskCommand])),
        ("⌥⌘E", cgKeyEvent(kVK_ANSI_E, [.maskAlternate, .maskCommand])),
        ("⌥E", cgKeyEvent(kVK_ANSI_E, [.maskAlternate])),
        ("F6", cgKeyEvent(kVK_F6, [.maskSecondaryFn])),
        ("⌃⌥K", cgKeyEvent(kVK_ANSI_K, [.maskControl, .maskAlternate])),
    ]
    for (label, event) in cases {
        t.fired = []
        let handled = main.performKeyEquivalent(with: event)
        print("\(label): chars=\(event.characters?.debugDescription ?? "nil") ign=\(event.charactersIgnoringModifiers?.debugDescription ?? "nil") handled=\(handled) fired=\(t.fired)")
    }
    exit(0)
}
NSApplication.shared.run()
