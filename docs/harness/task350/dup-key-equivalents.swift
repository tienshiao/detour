// TASK-350 spike (macOS 26, 2026-11-16): AppKit keeps a key equivalent on one item of the menu bar only.
// Installing a bar where File > New Window and Edit > Copy both have ⌘C leaves Copy with none; setting New
// Window to ⌘C after the bar is installed leaves New Window with none (Copy keeps it). Printed:
//   after install (dup set before): copy="" new="c" / dup set after install: copy="c" new=""
// Build: xcrun swiftc -module-cache-path "$TMPDIR/swift-mc" -o dup dup-key-equivalents.swift (sandbox off to run).
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
func bar(_ order: String) -> (NSMenu, NSMenuItem, NSMenuItem) {
    let main = NSMenu(title: "Main")
    let appItem = NSMenuItem(); appItem.submenu = NSMenu(title: "App"); main.addItem(appItem)
    let fileTop = NSMenuItem(); let file = NSMenu(title: "File"); fileTop.submenu = file; main.addItem(fileTop)
    let editTop = NSMenuItem(); let edit = NSMenu(title: "Edit"); editTop.submenu = edit; main.addItem(editTop)
    let newWindow = file.addItem(withTitle: "New Window", action: #selector(NSApplication.terminate(_:)), keyEquivalent: order == "before" ? "c" : "")
    let copy = edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    return (main, newWindow, copy)
}
var (main, newWindow, copy) = bar("before")
print("before install: copy=\(copy.keyEquivalent.debugDescription)")
app.mainMenu = main
print("after install (dup set before): copy=\(copy.keyEquivalent.debugDescription) new=\(newWindow.keyEquivalent.debugDescription)")
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
print("after runloop: copy=\(copy.keyEquivalent.debugDescription)")
(main, newWindow, copy) = bar("after")
app.mainMenu = main
newWindow.keyEquivalent = "c"
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
print("dup set after install: copy=\(copy.keyEquivalent.debugDescription) new=\(newWindow.keyEquivalent.debugDescription)")
