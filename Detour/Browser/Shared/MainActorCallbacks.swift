import AppKit

// Main-actor forms of AppKit and Foundation callbacks that always run on the
// main thread but that the SDK types as nonisolated `@Sendable` closures, so
// main-actor state they touch would otherwise go unchecked (TASK-231.6). Each
// states the main thread once and checks it with `MainActor.assumeIsolated`,
// which traps if the callback ever arrives elsewhere.

extension NSAnimationContext {
    /// `runAnimationGroup(_:completionHandler:)` with the completion on the
    /// main actor: AppKit calls it on the main thread.
    static func runAnimationGroup(_ changes: (NSAnimationContext) -> Void,
                                  onMain completion: @escaping @MainActor @Sendable () -> Void) {
        runAnimationGroup(changes, completionHandler: { MainActor.assumeIsolated(completion) })
    }
}

extension Timer {
    /// `scheduledTimer(withTimeInterval:repeats:block:)` from the main thread,
    /// so on the main run loop, with the block on the main actor.
    @discardableResult
    static func scheduledMainTimer(withTimeInterval interval: TimeInterval, repeats: Bool,
                                   block: @escaping @MainActor @Sendable (Timer) -> Void) -> Timer {
        scheduledTimer(withTimeInterval: interval, repeats: repeats) { timer in
            // Not a crossing: the timer fires on the main thread it is handed to.
            nonisolated(unsafe) let timer = timer
            MainActor.assumeIsolated { block(timer) }
        }
    }
}

extension NotificationCenter {
    /// `addObserver(forName:object:queue:using:)` on the main queue, with the
    /// block on the main actor.
    func addMainObserver(forName name: Notification.Name?, object: Any?,
                         using block: @escaping @MainActor @Sendable (Notification) -> Void) -> any NSObjectProtocol {
        addObserver(forName: name, object: object, queue: .main) { notification in
            // Not a crossing: the main queue runs this on the main thread.
            nonisolated(unsafe) let notification = notification
            MainActor.assumeIsolated { block(notification) }
        }
    }
}
