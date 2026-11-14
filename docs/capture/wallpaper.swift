// wallpaper <RRGGBB> <png-path> [displayID]: a solid-colour desktop picture for
// captures (TASK-110, TASK-228.3). macOS applies it to EVERY display and Space,
// not only the one named, so run it only through `demo.sh wallpaper`, which
// snapshots the wallpaper store first for `demo.sh wallpaper-restore`.
import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 3, arguments[1].count == 6, let value = Int(arguments[1], radix: 16) else {
    print("usage: wallpaper <RRGGBB> <png-path> [displayID]")
    exit(2)
}
_ = NSApplication.shared
let wanted = arguments.count > 3 ? UInt32(arguments[3]) : nil
func displayID(_ screen: NSScreen) -> UInt32? {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
}
guard let screen = NSScreen.screens.first(where: { wanted == nil ? $0.backingScaleFactor >= 2 : displayID($0) == wanted }) else {
    print("no such display")
    exit(1)
}
let color = NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                    blue: CGFloat(value & 255) / 255, alpha: 1)
let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
    color.setFill()
    rect.fill()
    return true
}
let url = URL(fileURLWithPath: arguments[2])
guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    print("could not draw the picture")
    exit(1)
}
do {
    try png.write(to: url)
    try NSWorkspace.shared.setDesktopImageURL(url, for: screen,
                                              options: [.imageScaling: NSImageScaling.scaleAxesIndependently.rawValue])
    print("wallpaper set on \(screen.localizedName)")
} catch {
    print("wallpaper failed: \(error)")
    exit(1)
}
