import AppKit
import ApplicationServices
// axwin <bundleID> <titleSubstring> <x> <y> <w> <h>  (Quartz global, top-left)
let a = CommandLine.arguments
print("trusted=\(AXIsProcessTrusted())")
guard a.count == 7, let app = NSRunningApplication.runningApplications(withBundleIdentifier: a[1]).first else { print("no app"); exit(1) }
let el = AXUIElementCreateApplication(app.processIdentifier)
var v: CFTypeRef?
AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &v)
let wins = (v as? [AXUIElement]) ?? []
for w in wins {
    var t: CFTypeRef?
    AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t)
    let title = (t as? String) ?? ""
    print("window \(title)")
    guard title.contains(a[2]) else { continue }
    var p = CGPoint(x: Double(a[3])!, y: Double(a[4])!), s = CGSize(width: Double(a[5])!, height: Double(a[6])!)
    let pv = AXValueCreate(.cgPoint, &p)!, sv = AXValueCreate(.cgSize, &s)!
    print("pos", AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv).rawValue,
          "size", AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sv).rawValue,
          "pos2", AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv).rawValue)
}
