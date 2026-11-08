import Foundation
import CoreServices

// Who sent a link from another app, for a route's source-app condition
// (TASK-191.2). Detour's own Get URL handler (`AppDelegate.handleGetURLEvent`,
// TASK-304) reads the event with `linkSenderPID`, then names the app with
// `linkSenderBundleID`. Observed (macOS 26.7): LaunchServices sends the event
// from the opening app's process, so `keySenderPIDAttr` (type 'magn') is that
// app's PID; `open` from a shell is the `open` process, which has no bundle ID.
// The URL that cold-launches Detour reaches a handler installed in
// `applicationWillFinishLaunching` before `applicationDidFinishLaunching`,
// with the opener's PID like any other (TASK-304 spike, 2026-11-08). Under
// AppKit's own handler it had none: AppKit queued the launch URLs and called
// `application(_:open:)` after launch, outside the event.

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

/// The URLs a Get URL event carries: its direct object, a string or a list of
/// strings (one event can carry several). Strings that are not URLs are
/// dropped.
func linkURLs(in event: NSAppleEventDescriptor) -> [URL] {
    guard let direct = event.paramDescriptor(forKeyword: keyDirectObject) else { return [] }
    let strings: [String?]
    if direct.descriptorType == DescType(typeAEList) {
        strings = direct.numberOfItems > 0 ? (1...direct.numberOfItems).map { direct.atIndex($0)?.stringValue } : []
    } else {
        strings = [direct.stringValue]
    }
    return strings.compactMap { $0.flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) } }
}

/// Which links from other apps launched Detour (TASK-304). The event that
/// launches Detour reaches its Get URL handler before
/// `applicationDidFinishLaunching`; the other URLs of the same open follow as
/// their own events right after it, from the same sender (spike, 2026-11-08).
/// Those count too: an event from a launch sender's process up to
/// `followUpWindow` seconds after launch finished. Anything later, or from
/// another process, is a link while Detour runs.
struct LaunchLinkTracker {
    /// How long after launch an event from a launch sender still counts as
    /// part of the open that launched Detour. The second URL of an open
    /// arrived 0.11 s after launch in the spike.
    static let followUpWindow: TimeInterval = 10

    /// When `applicationDidFinishLaunching` finished; nil while launching.
    private(set) var launchFinishedAt: TimeInterval?
    /// The senders of the events handled while launching.
    private(set) var launchSenderPIDs: Set<pid_t> = []

    var isLaunching: Bool { launchFinishedAt == nil }

    /// Whether an event from `senderPID`, handled at `now`, carries links that
    /// launched Detour. While launching it always does, and its sender is
    /// remembered.
    mutating func isLaunchLink(senderPID: pid_t?, now: TimeInterval) -> Bool {
        guard let finished = launchFinishedAt else {
            if let senderPID { launchSenderPIDs.insert(senderPID) }
            return true
        }
        guard let senderPID, launchSenderPIDs.contains(senderPID) else { return false }
        return now - finished <= Self.followUpWindow
    }

    mutating func launchDidFinish(at now: TimeInterval) {
        if launchFinishedAt == nil { launchFinishedAt = now }
    }
}
