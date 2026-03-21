import Foundation
import CoreGraphics
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "extension-idle")

/// Monitors system idle state and dispatches `chrome.idle.onStateChanged` events to extensions.
///
/// States:
/// - `"active"`: User has interacted recently (within the detection interval)
/// - `"idle"`: No user interaction for longer than the detection interval
/// - `"locked"`: Screen is locked
class IdleMonitor {
    static let shared = IdleMonitor()

    /// Per-extension detection interval in seconds (default 60).
    private var detectionIntervals: [String: Int] = [:]
    /// Per-extension last known state.
    private var lastStates: [String: String] = [:]

    private var timer: Timer?
    private var isRunning = false

    private init() {}

    /// Start monitoring if not already running.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkState()
        }
    }

    /// Stop monitoring.
    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    /// Set the detection interval for a specific extension.
    func setDetectionInterval(_ seconds: Int, for extensionID: String) {
        detectionIntervals[extensionID] = max(15, seconds) // Chrome enforces minimum 15s
        // Ensure monitoring is started
        start()
    }

    /// Query the current idle state for a given detection interval.
    func queryState(detectionIntervalSeconds: Int) -> String {
        if isScreenLocked() { return "locked" }

        let idleTime = secondsSinceLastInput()
        return idleTime >= Double(detectionIntervalSeconds) ? "idle" : "active"
    }

    // MARK: - Private

    private func checkState() {
        let enabledExtensions = ExtensionManager.shared.enabledExtensions
        var hasIdleExtension = false

        for ext in enabledExtensions {
            guard ExtensionPermissionChecker.hasPermission("idle", extension: ext) else { continue }
            hasIdleExtension = true

            let interval = detectionIntervals[ext.id] ?? 60
            let newState = queryState(detectionIntervalSeconds: interval)
            let oldState = lastStates[ext.id]

            if newState != oldState {
                lastStates[ext.id] = newState
                dispatchStateChanged(newState, to: ext.id)
            }
        }

        // Auto-stop when no extensions need idle monitoring
        if !hasIdleExtension {
            stop()
        }
    }

    private func dispatchStateChanged(_ state: String, to extensionID: String) {
        log.info("Idle state changed to \(state, privacy: .public) for extension \(extensionID, privacy: .public)")
        let js = "if (window.__extensionDispatchIdleStateChanged) { window.__extensionDispatchIdleStateChanged('\(state)'); }"
        ExtensionManager.shared.backgroundHost(for: extensionID)?.evaluateJavaScript(js)
    }

    private func secondsSinceLastInput() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
    }

    private func isScreenLocked() -> Bool {
        guard let sessionDict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        // kCGSessionOnConsoleKey is false when the screen is locked
        if let onConsole = sessionDict["CGSSessionScreenIsLocked"] as? Bool {
            return onConsole
        }
        return false
    }
}
