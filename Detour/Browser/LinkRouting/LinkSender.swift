import Foundation
import CoreServices

// Who sent a link from another app, for a route's source-app condition
// (TASK-191.2). `AppDelegate.application(_:open:)` reads the Get URL Apple
// Event being handled with `linkSenderPID`, then names the app with
// `linkSenderBundleID`. Observed (macOS 26, 2026-10-25): LaunchServices sends
// the event from the opening app's process, so `keySenderPIDAttr` (type
// 'magn') is that app's PID; `open` from a shell is the `open` process, which
// has no bundle ID; the URL that cold-launches Detour arrives with no current
// event.

/// The process that sent `event`: its `keySenderPIDAttr`, which the Apple
/// Event Manager stamps on every event it delivers (and which cannot be set
/// on an event built in process), else its address (`keyAddressAttr`) when
/// that is a process ID. Nil when the event names neither.
func linkSenderPID(of event: NSAppleEventDescriptor?) -> pid_t? {
    guard let event else { return nil }
    for keyword in [keySenderPIDAttr, keyAddressAttr] {
        if let descriptor = event.attributeDescriptor(forKeyword: AEKeyword(keyword)),
           let pid = processID(in: descriptor), pid > 0 {
            return pid
        }
    }
    return nil
}

/// The bundle ID of the sending process. Nil when there is no sender, the
/// sender is this process, or it has no bundle ID (a command-line tool, or a
/// process LaunchServices does not know, such as one that already exited):
/// such a link matches no source-app route.
func linkSenderBundleID(senderPID: pid_t?, ownPID: pid_t, bundleIDForPID: (pid_t) -> String?) -> String? {
    guard let pid = senderPID, pid > 0, pid != ownPID,
          let bundleID = bundleIDForPID(pid)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !bundleID.isEmpty else { return nil }
    return bundleID
}

/// A process ID held as a kernel PID or a 32-bit integer. `int32Value` cannot
/// read a `typeKernelProcessID` descriptor (it has no coercion to a number and
/// reads as 0), so its four bytes are read directly.
private func processID(in descriptor: NSAppleEventDescriptor) -> pid_t? {
    switch descriptor.descriptorType {
    case DescType(typeKernelProcessID), DescType(typeSInt32):
        let data = descriptor.data
        guard data.count == MemoryLayout<pid_t>.size else { return nil }
        return data.withUnsafeBytes { $0.loadUnaligned(as: pid_t.self) }
    default:
        return descriptor.coerce(toDescriptorType: DescType(typeSInt32))?.int32Value
    }
}
