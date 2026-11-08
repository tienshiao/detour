import Foundation
import WebKit
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "extension-polyfill")

/// The parked-request channel Detour pushes events into extension contexts
/// through (there is no push channel into a context): each context that
/// listens parks an `…awaitEvent` request, which is answered with the events
/// it has not acknowledged yet, and parks again with the last `seq` it
/// dispatched. Used by the tab group events (TASK-132.12) and the debugger
/// events (TASK-132.13); the notifications channel predates it.
///
/// Pages park as well as the background. Each JS context (its
/// `__detourContextInstance`) has a slot of its own. A page's slot holds its
/// web view weakly and is dropped once the view is gone; an extension keeps at
/// most `pageSlotLimit` page slots, the one that parked longest ago going
/// first (a reloaded page leaves its old slot behind until then). The
/// background has one slot: a newer incarnation supersedes the parked request
/// in place and an older one is refused from then on, and an event wakes a
/// background that has parked this launch. A slot keeps at most
/// `backlogLimit` unacknowledged events, dropping the oldest.
final class ExtensionEventParking {

    struct Event {
        let seq: Int
        let payload: [String: Any]
    }

    private struct Slot {
        var parked: ((Any?, String?) -> Void)?
        /// Events not yet acknowledged, oldest first, at most `backlogLimit`.
        var backlog: [Event] = []
        let isBackground: Bool
        /// A page's web view; nil for the background.
        weak var webView: WKWebView?
        /// When the slot last parked (`parkCount`), for evicting the stalest
        /// page slot.
        var lastParked: Int
    }

    static let pageSlotLimit = 8
    static let instanceHistoryLimit = 8
    static let backgroundSlotKey = "background"

    /// Names the channel in errors and the log, e.g. "tabGroups events".
    let label: String
    let backlogLimit: Int
    let supersededError: String
    let unloadedError: String
    /// Starts an extension's background content for an event (a no-op while
    /// it runs). A seam for tests.
    var wakeBackground: (String) -> Void

    /// extension id -> slot key (`backgroundSlotKey` or a page's instance) -> slot.
    private var slots: [String: [String: Slot]] = [:]
    /// The background incarnations that parked, oldest first, per extension.
    private var backgroundInstances: [String: [String]] = [:]
    /// Extensions whose background has parked this launch: only they are woken.
    private var listening: Set<String> = []
    private var seq = 0
    /// Counts parks, so page slots can be ranked by when they last parked.
    private var parkCount = 0

    init(label: String, backlogLimit: Int, supersededError: String, unloadedError: String,
         wakeBackground: @escaping (String) -> Void) {
        self.label = label
        self.backlogLimit = backlogLimit
        self.supersededError = supersededError
        self.unloadedError = unloadedError
        self.wakeBackground = wakeBackground
    }

    /// Parks `reply` for the context's next events, or answers at once with
    /// those not yet acknowledged. `ack` drops it and every earlier event
    /// first. A page needs its `instance` (no instance, no slot: refused).
    func awaitEvent(extensionID: String, isBackground: Bool, instance: String?, webView: WKWebView?,
                    ack: Int?, reply: @escaping (Any?, String?) -> Void) {
        sweepPageSlots()
        let key: String
        if isBackground {
            key = Self.backgroundSlotKey
            if let instance {
                var history = backgroundInstances[extensionID] ?? []
                if let index = history.firstIndex(of: instance) {
                    guard index == history.count - 1 else {
                        reply(nil, supersededError)
                        return
                    }
                } else {
                    history.append(instance)
                    if history.count > Self.instanceHistoryLimit {
                        history.removeFirst(history.count - Self.instanceHistoryLimit)
                    }
                    backgroundInstances[extensionID] = history
                }
            }
            listening.insert(extensionID)
        } else {
            guard let instance, !instance.isEmpty else {
                reply(nil, "\(label): a page must name its context")
                return
            }
            key = "page:" + instance
        }

        parkCount += 1
        var byKey = slots[extensionID] ?? [:]
        var slot = byKey[key] ?? Slot(isBackground: isBackground, webView: webView, lastParked: parkCount)
        if !isBackground { slot.webView = webView }
        slot.lastParked = parkCount
        if let ack { slot.backlog.removeAll { $0.seq <= ack } }
        let previous = slot.parked
        slot.parked = nil
        let pending = slot.backlog
        if pending.isEmpty { slot.parked = reply }
        byKey[key] = slot

        // The page slots past the limit go, the one parked longest ago first.
        let pageKeys = byKey.filter { !$0.value.isBackground }.sorted { $0.value.lastParked < $1.value.lastParked }.map(\.key)
        var evicted: [(Any?, String?) -> Void] = []
        if pageKeys.count > Self.pageSlotLimit {
            for stale in pageKeys.prefix(pageKeys.count - Self.pageSlotLimit) where stale != key {
                if let parked = byKey[stale]?.parked { evicted.append(parked) }
                byKey[stale] = nil
            }
        }
        slots[extensionID] = byKey

        previous?(nil, supersededError)
        for parked in evicted { parked(nil, supersededError) }
        if !pending.isEmpty { reply(Self.answer(pending), nil) }
    }

    /// Forgets the extension's slots, answering their waits: it was unloaded.
    func drop(extensionID: String) {
        let dropped = slots.removeValue(forKey: extensionID) ?? [:]
        backgroundInstances[extensionID] = nil
        listening.remove(extensionID)
        for slot in dropped.values { slot.parked?(nil, unloadedError) }
    }

    /// Whether any context of the extension is parked or has a slot.
    func hasSlots(for extensionID: String) -> Bool {
        sweepPageSlots()
        return !(slots[extensionID] ?? [:]).isEmpty
    }

    private static func answer(_ events: [Event]) -> [String: Any] {
        ["events": events.map { event -> [String: Any] in
            var payload = event.payload
            payload["seq"] = event.seq
            return payload
        }]
    }

    /// Drops the slots of pages whose web view is gone, answering their waits
    /// so no reply handler is released uncalled.
    private func sweepPageSlots() {
        var orphaned: [(Any?, String?) -> Void] = []
        for (extensionID, byKey) in slots {
            let alive = byKey.filter { $0.value.isBackground || $0.value.webView != nil }
            guard alive.count != byKey.count else { continue }
            for slot in byKey.values where !slot.isBackground && slot.webView == nil {
                if let parked = slot.parked { orphaned.append(parked) }
            }
            slots[extensionID] = alive.isEmpty ? nil : alive
        }
        for parked in orphaned { parked(nil, unloadedError) }
    }

    /// Queues the event for every slot of the extensions `recipients` accepts
    /// and answers the parked ones.
    func deliver(_ payload: [String: Any], to recipients: (String) -> Bool) {
        sweepPageSlots()
        guard !slots.isEmpty else { return }
        seq += 1
        let event = Event(seq: seq, payload: payload)
        var answers: [((Any?, String?) -> Void, [Event])] = []
        var wakes: [String] = []
        for (extensionID, byKey) in slots {
            if !recipients(extensionID) { continue }
            var updated = byKey
            for (key, var slot) in byKey {
                slot.backlog.append(event)
                if slot.backlog.count > backlogLimit {
                    let dropped = slot.backlog.count - backlogLimit
                    slot.backlog.removeFirst(dropped)
                    log.info("Dropped \(dropped) unacknowledged \(self.label, privacy: .public) for \(extensionID, privacy: .public)")
                }
                if let parked = slot.parked {
                    answers.append((parked, slot.backlog))
                    slot.parked = nil
                }
                if slot.isBackground, listening.contains(extensionID) { wakes.append(extensionID) }
                updated[key] = slot
            }
            slots[extensionID] = updated
        }
        for (reply, events) in answers { reply(Self.answer(events), nil) }
        for extensionID in wakes { wakeBackground(extensionID) }
    }

    /// Queues the event for `extensionID`'s contexts only.
    func deliver(_ payload: [String: Any], toExtension extensionID: String) {
        deliver(payload, to: { $0 == extensionID })
    }

    #if DEBUG
    /// Slot keys and backlog sizes, for tests.
    func slotsForTesting(_ extensionID: String) -> [String: (parked: Bool, backlog: Int)] {
        (slots[extensionID] ?? [:]).mapValues { ($0.parked != nil, $0.backlog.count) }
    }
    #endif
}
