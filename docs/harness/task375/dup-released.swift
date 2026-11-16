// TASK-375 spike 2 (macOS 26, 2026-11-16): TASK-350 measured that AppKit keeps a key equivalent on one item of the
// menu bar (the other item reads ""). Is the emptied item's key kept underneath and given back once the holder moves?
// Build: xcrun swiftc -module-cache-path "$TMPDIR/swift-mc" -o dupreleased dup-released.swift (sandbox off to run).
// Result:
//   == Copy on AppKit's copy: with no target (as in TASK-350's spike and Detour's Edit menu)
//   1 installed with both on ⌘C: new="c" copy=""   ⌘C fires New Window
//   1 New Window moved to ⌘K:   new="k" copy="c"  (Copy has ⌘C back; not handled: nothing answers copy:)
//   2 New Window set to ⌘C:     new=""  copy="c"
//   2 Copy moved to ⌘X:         new="c" copy="x"  ⌘C fires New Window (New Window has ⌘C back)
//   == Copy on the app's own action and target
//   both read "c" throughout, and ⌘C fired Copy (the later item) until Copy moved to ⌘X.
// So the emptied item's key is kept underneath and comes back once the other item lets go of it. The one-item rule
// did not show between two items on the app's own action and target; which property decides (the standard action, the
// nil target) was not separated.
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
final class Target: NSObject { var fired: [String] = []; @objc func fire(_ s: NSMenuItem) { fired.append(s.title) } }
let t = Target()
func bar(newWindowKey: String, standardCopy: Bool) -> (NSMenu, NSMenuItem, NSMenuItem) {
    let main = NSMenu(title: "Main")
    let appItem = NSMenuItem(); appItem.submenu = NSMenu(title: "App"); main.addItem(appItem)
    let fileTop = NSMenuItem(); let file = NSMenu(title: "File"); fileTop.submenu = file; main.addItem(fileTop)
    let editTop = NSMenuItem(); let edit = NSMenu(title: "Edit"); editTop.submenu = edit; main.addItem(editTop)
    let newWindow = file.addItem(withTitle: "New Window", action: #selector(Target.fire(_:)), keyEquivalent: newWindowKey)
    // standardCopy: Copy on AppKit's own copy: action with no target, as TASK-350's spike and Detour's Edit menu have
    // it; else on the app's own action and target, as New Window is.
    let copy = edit.addItem(withTitle: "Copy", action: standardCopy ? #selector(NSText.copy(_:)) : #selector(Target.fire(_:)),
                            keyEquivalent: "c")
    newWindow.target = t
    if !standardCopy { copy.target = t }
    return (main, newWindow, copy)
}
func press(_ main: NSMenu) -> String {
    t.fired = []
    let e = CGEvent(keyboardEventSource: nil, virtualKey: 8 /* C */, keyDown: true)!; e.flags = .maskCommand
    let handled = main.performKeyEquivalent(with: NSEvent(cgEvent: e)!)
    return "handled=\(handled) fired=\(t.fired)"
}
func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
for standardCopy in [true, false] {
    print(standardCopy ? "== Copy on AppKit's copy: with no target" : "== Copy on the app's own action and target")
    // 1. Duplicate before install: Copy (the later item) reads "".
    var (main, newWindow, copy) = bar(newWindowKey: "c", standardCopy: standardCopy)
    app.mainMenu = main; settle()
    print("1 installed with both on ⌘C: new=\(newWindow.keyEquivalent.debugDescription) copy=\(copy.keyEquivalent.debugDescription) ⌘C \(press(main))")
    newWindow.keyEquivalent = "k"; settle()
    print("1 New Window moved to ⌘K:   new=\(newWindow.keyEquivalent.debugDescription) copy=\(copy.keyEquivalent.debugDescription) ⌘C \(press(main))")
    // 2. Duplicate set after install: New Window (set second) reads "".
    (main, newWindow, copy) = bar(newWindowKey: "", standardCopy: standardCopy)
    app.mainMenu = main; settle()
    newWindow.keyEquivalent = "c"; settle()
    print("2 New Window set to ⌘C:     new=\(newWindow.keyEquivalent.debugDescription) copy=\(copy.keyEquivalent.debugDescription) ⌘C \(press(main))")
    copy.keyEquivalent = "x"; settle()
    print("2 Copy moved to ⌘X:         new=\(newWindow.keyEquivalent.debugDescription) copy=\(copy.keyEquivalent.debugDescription) ⌘C \(press(main))")
}
exit(0)
