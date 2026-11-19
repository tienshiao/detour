import AppKit
import ApplicationServices
// dockclick <app bundle path> <menu item title>: real (HID) right-click on that app's Dock tile, then a real click
// on the named item of the tile's menu. Positions from the Dock's accessibility tree; refuses unless the point is the Dock's.
let a = CommandLine.arguments
let appURL = URL(fileURLWithPath: a[1]).standardizedFileURL.resolvingSymlinksInPath()
guard AXIsProcessTrusted() else { print("NOT TRUSTED"); exit(2) }
let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first!
let dockAX = AXUIElementCreateApplication(dock.processIdentifier)
func attr<T>(_ e: AXUIElement, _ name: String) -> T? { var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, name as CFString, &v); return v as? T }
func children(_ e: AXUIElement) -> [AXUIElement] { attr(e, kAXChildrenAttribute) ?? [] }
func frame(_ e: AXUIElement) -> CGRect {
  var p = CGPoint.zero, s = CGSize.zero
  if let pv: AXValue = attr(e, kAXPositionAttribute) { AXValueGetValue(pv, .cgPoint, &p) }
  if let sv: AXValue = attr(e, kAXSizeAttribute) { AXValueGetValue(sv, .cgSize, &s) }
  return CGRect(origin: p, size: s)
}
func all(_ e: AXUIElement, depth: Int = 0) -> [AXUIElement] { depth > 4 ? [] : children(e).flatMap { [$0] + all($0, depth: depth + 1) } }
var tile: AXUIElement?
for e in all(dockAX) {
  if let u: URL = attr(e, kAXURLAttribute), u.standardizedFileURL.resolvingSymlinksInPath().path == appURL.path { tile = e }
}
guard let tile else { print("NO TILE"); exit(3) }
func click(_ p: CGPoint, right: Bool) {
  // Refuse unless the topmost window at the point belongs to the Dock.
  let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
  let owner = list.first { w in
    let b = w[kCGWindowBounds as String] as! [String: CGFloat]
    return CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!).contains(p) && (w[kCGWindowAlpha as String] as? Double ?? 1) > 0
  }?[kCGWindowOwnerName as String] as? String
  guard owner == "Dock" || owner == "DockHelper" else { print("REFUSED click at \(p): top window \(owner ?? "-")"); exit(4) }
  let src = CGEventSource(stateID: .hidSystemState)
  let (d, u, b): (CGEventType, CGEventType, CGMouseButton) = right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
  CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap); usleep(150000)
  CGEvent(mouseEventSource: src, mouseType: d, mouseCursorPosition: p, mouseButton: b)?.post(tap: .cghidEventTap); usleep(60000)
  CGEvent(mouseEventSource: src, mouseType: u, mouseCursorPosition: p, mouseButton: b)?.post(tap: .cghidEventTap)
}
let tf = frame(tile)
click(CGPoint(x: tf.midX, y: tf.midY), right: true)
usleep(900000)
let items = all(tile).filter { (attr($0, kAXRoleAttribute) as String?) == kAXMenuItemRole }
print("MENU \(items.compactMap { attr($0, kAXTitleAttribute) as String? })")
guard let item = items.first(where: { (attr($0, kAXTitleAttribute) as String?) == a[2] }) else {
  // Close the menu without choosing anything.
  let esc = CGEventSource(stateID: .hidSystemState)
  CGEvent(keyboardEventSource: esc, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
  CGEvent(keyboardEventSource: esc, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
  print("NO ITEM \(a[2])"); exit(5)
}
let f = frame(item)
click(CGPoint(x: f.midX, y: f.midY), right: false)
print("CLICKED \(a[2])")
