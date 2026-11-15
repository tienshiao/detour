// TASK-335 spike 1: AppKit's menu matching for items spelled with a shifted character ("+", "?", "{", "!", ")", ":") against real CGEvents on the current layout, which wins when an exact "=" + ⇧⌘ item is also there, and UCKeyTranslate on installed layouts.
// Build: xcrun swiftc -module-cache-path "$TMPDIR/swift-mc" -o shifted shifted-characters.swift (sandbox off to run: it talks to the window server). Run: ./shifted
// Result (macOS 26, US layout, 2026-11-14): ⇧⌘= fired ⌘+, ⌘= fired nothing, ⇧⌘[ fired ⌘{, ⇧⌘1 ⌘!, ⇧⌘0 ⌘), ⇧⌘; ⌘:, keypad + with ⌘ fired ⌘+, ⌥⇧⌘= did not fire ⌘+;
// ⇧⌘/ fired neither ⌘? nor ⇧⌘? (this Mac has macOS's Show Help menu, ⇧⌘/, enabled); with "=" + ⇧⌘ in the menu too, it fired on ⇧⌘= whatever the order.
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
func translate(_ source: TISInputSource, _ code: Int, shift: Bool) -> String {
    guard let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "<no data>" }
    let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
    return data.withUnsafeBytes { raw -> String in
        let layout = raw.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self)
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let mods: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
        let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), mods, UInt32(LMGetKbdType()),
                                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, 4, &length, &chars)
        return status == noErr ? String(utf16CodeUnits: chars, count: length) : "<err \(status)>"
    }
}
func source(_ id: String) -> TISInputSource? {
    let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
    let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]
    return list?.first
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let current = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
    let id = Unmanaged<CFString>.fromOpaque(TISGetInputSourceProperty(current, kTISPropertyInputSourceID)).takeUnretainedValue()
    print("current layout: \(id)")
    for (name, src) in [("current", current), ("US", source("com.apple.keylayout.US")), ("French", source("com.apple.keylayout.French")), ("German", source("com.apple.keylayout.German"))] {
        guard let src else { print("\(name): not available"); continue }
        let codes = [kVK_ANSI_Equal, kVK_ANSI_Slash, kVK_ANSI_1, kVK_ANSI_LeftBracket, kVK_ANSI_0, kVK_ANSI_T]
        print(name, codes.map { "\($0):\(translate(src, $0, shift: false).debugDescription)/\(translate(src, $0, shift: true).debugDescription)" }.joined(separator: " "))
    }
    let t = Target()
    let main = NSMenu()
    let bar = NSMenuItem(title: "View", action: nil, keyEquivalent: ""); main.addItem(bar)
    let view = NSMenu(title: "View"); bar.submenu = view
    func add(_ title: String, _ key: String, _ mask: NSEvent.ModifierFlags) {
        let item = NSMenuItem(title: title, action: #selector(Target.fire(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = mask; item.target = t; view.addItem(item)
    }
    add("Zoom In ⌘+", "+", [.command])
    add("Help ⌘?", "?", [.command])
    add("Brace ⌘{", "{", [.command])
    add("Bang ⌘!", "!", [.command])
    add("Paren ⌘)", ")", [.command])
    add("Colon ⌘:", ":", [.command])
    add("Question ⇧⌘?", "?", [.command, .shift])
    app.mainMenu = main
    let cases: [(String, NSEvent)] = [
        ("⇧⌘= ", cgKeyEvent(kVK_ANSI_Equal, [.maskShift, .maskCommand])),
        ("⌘=  ", cgKeyEvent(kVK_ANSI_Equal, [.maskCommand])),
        ("⇧⌘/ ", cgKeyEvent(kVK_ANSI_Slash, [.maskShift, .maskCommand])),
        ("⌘/  ", cgKeyEvent(kVK_ANSI_Slash, [.maskCommand])),
        ("⇧⌘[ ", cgKeyEvent(kVK_ANSI_LeftBracket, [.maskShift, .maskCommand])),
        ("⇧⌘1 ", cgKeyEvent(kVK_ANSI_1, [.maskShift, .maskCommand])),
        ("⇧⌘0 ", cgKeyEvent(kVK_ANSI_0, [.maskShift, .maskCommand])),
        ("⇧⌘; ", cgKeyEvent(kVK_ANSI_Semicolon, [.maskShift, .maskCommand])),
        ("⌥⇧⌘=", cgKeyEvent(kVK_ANSI_Equal, [.maskShift, .maskCommand, .maskAlternate])),
        ("keypad+ ⌘", cgKeyEvent(kVK_ANSI_KeypadPlus, [.maskCommand])),
    ]
    for (label, event) in cases {
        t.fired = []
        let handled = main.performKeyEquivalent(with: event)
        print("\(label): ign=\(event.charactersIgnoringModifiers?.debugDescription ?? "nil") handled=\(handled) fired=\(t.fired)")
    }
    // Two items: a binding "=" + ⇧⌘ before Zoom In "+" ⌘ — which fires on ⇧⌘=?
    let both = NSMenuItem(title: "Binding ⇧⌘=", action: #selector(Target.fire(_:)), keyEquivalent: "=")
    both.keyEquivalentModifierMask = [.command, .shift]; both.target = t
    view.addItem(both)
    t.fired = []
    let handled = main.performKeyEquivalent(with: cgKeyEvent(kVK_ANSI_Equal, [.maskShift, .maskCommand]))
    print("with binding after Zoom In: handled=\(handled) fired=\(t.fired)")
    view.removeItem(both); view.insertItem(both, at: 0)
    t.fired = []
    _ = main.performKeyEquivalent(with: cgKeyEvent(kVK_ANSI_Equal, [.maskShift, .maskCommand]))
    print("with binding before Zoom In: fired=\(t.fired)")
    exit(0)
}
NSApplication.shared.run()
