import CoreGraphics
import AppKit
// order <label>: frontmost app + front-to-back layer 0-19 windows; Detour windows by size, others by initial, until the last Detour window.
let label = CommandLine.arguments.dropFirst().first ?? ""
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
var out: [String] = []
var lastDetour = -1
for w in list {
  let owner = w[kCGWindowOwnerName as String] as? String ?? ""
  let layer = w[kCGWindowLayer as String] as? Int ?? 0
  let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
  let h = b["Height"] as? Double ?? 0
  guard layer < 20, h > 60 else { continue }
  let pid = w[kCGWindowOwnerPID as String] as? Int ?? 0
  if owner == "Detour", pid == (Int(ProcessInfo.processInfo.environment["QDFRONT_PROD_PID"] ?? "") ?? -1) { out.append("Dprod"); continue }
  if owner == "Detour" {
    out.append("D(\(Int(b["Width"] as? Double ?? 0))x\(Int(h))@L\(layer))"); lastDetour = out.count
  } else { out.append(String(owner.prefix(6))) }
}
print("ORDER \(label) front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-") :: " + out.prefix(max(lastDetour, 3)).joined(separator: " "))
