import CoreGraphics
import Foundation
let pid = Int(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerPID as String] as? Int) == pid {
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print(w[kCGWindowNumber as String]!, w[kCGWindowName as String] ?? "-", w[kCGWindowLayer as String]!, b["X"]!, b["Y"]!, b["Width"]!, b["Height"]!)
}
