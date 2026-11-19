import AppKit
// opener <app bundle path> <url>: opens the URL in that app through LaunchServices, activating it,
// as a link clicked in another app does. A new instance (if LaunchServices made one) gets the isolated profile.
let a = CommandLine.arguments
let configuration = NSWorkspace.OpenConfiguration()
configuration.activates = true
configuration.createsNewApplicationInstance = false
configuration.environment = ["DETOUR_DATA_DIR": "DetourVerifyQDFront", "DETOUR_GLOBAL_HOTKEY": "1"]
let done = DispatchSemaphore(value: 0)
NSWorkspace.shared.open([URL(string: a[2])!], withApplicationAt: URL(fileURLWithPath: a[1]), configuration: configuration) { app, error in
  print("OPENED pid=\(app?.processIdentifier ?? -1) error=\(String(describing: error))"); done.signal()
}
_ = done.wait(timeout: .now() + 10)
