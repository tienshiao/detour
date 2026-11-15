// TASK-295 spike: does AppKit's menu matching fire a hidden item (with and without allowsKeyEquivalentWhenHidden) or a disabled one,
// is a menu delegate's menuHasKeyEquivalent asked for a Control+digit press, and what sender does a delegate `true` hit get?
// Build: xcrun swiftc -module-cache-path "$TMPDIR/swift-mc" -o spike hidden-items.swift (sandbox off to run). Results (macOS 26, 2026-11-14):
// hidden item not matched (handled=false) unless allowsKeyEquivalentWhenHidden (then fired, sender = the item); a disabled match is
// handled=false; the delegate is asked for every press; a delegate `true` sends the action with the NSMenu as sender.
// (This copy has allowsKeyEquivalentWhenHidden set; remove it to see the first result.)
import AppKit
import Carbon.HIToolbox

final class Target: NSObject, NSMenuDelegate, NSMenuItemValidation {
    var fired: [String] = []
    var asked: [String] = []
    var answerHidden = false
    @objc func fire(_ sender: Any?) { fired.append((sender as? NSMenuItem)?.title ?? "sender \(String(describing: sender))") }
    func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent,
                              target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
                              action: UnsafeMutablePointer<Selector?>) -> Bool {
        asked.append(event.charactersIgnoringModifiers ?? "nil")
        guard answerHidden,
              let item = menu.items.first(where: { $0.isHidden && $0.keyEquivalent == event.charactersIgnoringModifiers
                                                   && $0.keyEquivalentModifierMask == .control }) else { return false }
        target.pointee = self
        action.pointee = item.action
        return true
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool { item.title != "disabled-7" }
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
    let bar = NSMenuItem(title: "Spaces", action: nil, keyEquivalent: ""); main.addItem(bar)
    let spaces = NSMenu(title: "Spaces"); bar.submenu = spaces
    spaces.delegate = t
    func add(_ title: String, _ key: String, hidden: Bool = false) {
        let item = NSMenuItem(title: title, action: #selector(Target.fire(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = [.control]; item.target = t; item.isHidden = hidden; item.allowsKeyEquivalentWhenHidden = true; spaces.addItem(item)
    }
    add("visible-1", "1")
    add("hidden-5", "5", hidden: true)
    add("disabled-7", "7")
    app.mainMenu = main
    let cases: [(String, NSEvent)] = [
        ("⌃1 visible", cgKeyEvent(kVK_ANSI_1, [.maskControl])),
        ("⌃5 hidden", cgKeyEvent(kVK_ANSI_5, [.maskControl])),
        ("⌃6 no item", cgKeyEvent(kVK_ANSI_6, [.maskControl])),
        ("⌃7 disabled", cgKeyEvent(kVK_ANSI_7, [.maskControl])),
    ]
    for answer in [false, true] {
        t.answerHidden = answer
        print("-- delegate answers hidden items: \(answer)")
        for (label, event) in cases {
            t.fired = []; t.asked = []
            let handled = main.performKeyEquivalent(with: event)
            print("\(label): chars=\(event.characters?.debugDescription ?? "nil") ign=\(event.charactersIgnoringModifiers?.debugDescription ?? "nil") handled=\(handled) fired=\(t.fired) delegateAsked=\(t.asked)")
        }
    }
    exit(0)
}
NSApplication.shared.run()
