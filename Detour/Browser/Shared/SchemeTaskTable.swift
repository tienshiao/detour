import Foundation
import WebKit

/// The URL scheme tasks a handler has started and WebKit has not stopped, for
/// handlers that answer later, from another queue. Calling a finished or
/// stopped task raises an Objective-C exception, so an answer goes through
/// `take` and is dropped when the task is gone. Main thread only, like the
/// handler's `start` and `stop`.
///
/// Only a `Ticket` crosses to the answering queue, never the task. A ticket
/// carries a serial as well as the task's identity: once a stopped task is
/// released, WebKit can allocate the next task at the same address, and an
/// identity alone would hand the old request's late answer to the new one.
struct SchemeTaskTable {
    nonisolated struct Ticket: Sendable {
        fileprivate let id: ObjectIdentifier
        fileprivate let serial: UInt64
    }

    private var tasks: [ObjectIdentifier: (serial: UInt64, task: any WKURLSchemeTask)] = [:]
    private var nextSerial: UInt64 = 0

    /// Records a task WebKit started; answer it with `take(_:)`.
    mutating func insert(_ task: any WKURLSchemeTask) -> Ticket {
        nextSerial += 1
        let ticket = Ticket(id: ObjectIdentifier(task as AnyObject), serial: nextSerial)
        tasks[ticket.id] = (ticket.serial, task)
        return ticket
    }

    /// Forgets a task WebKit stopped: a later `take` for it returns nil.
    mutating func remove(_ task: any WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(task as AnyObject))
    }

    /// The ticket's task, removed so it is answered once; nil when WebKit
    /// stopped it or it was already taken.
    mutating func take(_ ticket: Ticket) -> (any WKURLSchemeTask)? {
        guard tasks[ticket.id]?.serial == ticket.serial else { return nil }
        return tasks.removeValue(forKey: ticket.id)?.task
    }
}
