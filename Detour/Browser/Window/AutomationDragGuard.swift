import AppKit
import ObjectiveC
import WebKit

// TASK-132.14: a drag an extension's synthesized mouse input starts in a page
// never becomes an OS drag session.
//
// When a page's drag begins (a draggable element, a link, selected text, an
// image), WebKit starts an AppKit drag with the mouse down that started it
// (`WebViewImpl::startDrag`): the shipped WebKit with the window's legacy
// `dragImage(_:at:offset:event:pasteboard:source:slideBack:)` (measured:
// a test host sat in `NSCoreDragManager`'s drag loop), newer ones with the
// view's `beginDraggingSession(with:event:source:)`. Both are guarded. AppKit
// then runs the drag with the real pointer: with no button held it ends at
// once, dropping onto whatever is under the user's pointer — another app's
// text field, the sidebar. So a drag begun by a press `AutomationInput.sendMouse`
// sent is refused, and WebKit is told it ended with no drop (the page sees
// `dragend`), which is what Chrome's `Input.cancelDragging` leaves too.
// The page's own mouse events (mousedown, mousemove with the button held,
// mouseup) all still arrive: text selection, sliders and canvas drags work;
// HTML drag and drop between elements does not.
//
// Why the Objective-C runtime: AppKit declares `beginDraggingSession`'s
// result nonnull, so a Swift override cannot decline to make a session (WebKit
// ignores the result), and the window method is deprecated. The replacements
// are added to `WKWebView` (a tab's web view is a `BrowserWebView`, except an
// extension page's, which is a plain `WKWebView`) and to the windows a tab's
// web view can be in, parked or displayed (`BrowserWindow`, `QuickDetourWindow`),
// only, the first time synthesized input is sent.

enum AutomationDragGuard {
    /// How many drags were refused — for tests.
    private(set) static var refusedDragCount = 0
    private static var isInstalled = false

    private typealias Begin = @convention(c) (NSView, Selector, NSArray, NSEvent, AnyObject) -> NSDraggingSession?
    private typealias Ended = @convention(c) (NSView, Selector, AnyObject?, NSPoint, UInt) -> Void

    private typealias DragImage = @convention(c) (NSWindow, Selector, NSImage, NSPoint, NSSize, NSEvent, NSPasteboard,
                                                  AnyObject, ObjCBool) -> Void
    private typealias ImageEnded = @convention(c) (AnyObject, Selector, NSImage?, NSPoint, UInt) -> Void

    static func installIfNeeded() {
        guard !isInstalled else { return }
        isInstalled = true
        installSessionGuard()
        installWindowGuard(on: BrowserWindow.self)
        installWindowGuard(on: QuickDetourWindow.self)
    }

    /// The window's legacy drag, which the shipped WebKit uses.
    private static func installWindowGuard(on windowClass: NSWindow.Type) {
        let selector = NSSelectorFromString("dragImage:at:offset:event:pasteboard:source:slideBack:")
        guard let inherited = class_getInstanceMethod(windowClass, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(inherited), to: DragImage.self)
        let replacement: @convention(block) (NSWindow, NSImage, NSPoint, NSSize, NSEvent, NSPasteboard, AnyObject, ObjCBool)
            -> Void = { window, image, location, offset, event, pasteboard, source, slideBack in
            // AppKit and WebKit begin drags on the main thread.
            nonisolated(unsafe) let window = window
            nonisolated(unsafe) let event = event
            nonisolated(unsafe) let source = source
            let refused = MainActor.assumeIsolated {
                guard AutomationInput.isDrivenMouseDown(event) else { return false }
                refusedDragCount += 1
                let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
                DispatchQueue.main.async {
                    // WebKit's legacy drag source ends on `draggedImage:endedAt:operation:`.
                    let ended = NSSelectorFromString("draggedImage:endedAt:operation:")
                    guard let method = class_getInstanceMethod(type(of: source), ended) else { return }
                    let call = unsafeBitCast(method_getImplementation(method), to: ImageEnded.self)
                    call(source, ended, nil, screenPoint, NSDragOperation().rawValue)
                }
                return true
            }
            if !refused { original(window, selector, image, location, offset, event, pasteboard, source, slideBack) }
        }
        let implementation = imp_implementationWithBlock(replacement)
        if !class_addMethod(windowClass, selector, implementation, method_getTypeEncoding(inherited)) {
            method_setImplementation(inherited, implementation)
        }
    }

    /// The view's drag session, which newer WebKit uses.
    private static func installSessionGuard() {
        let selector = #selector(NSView.beginDraggingSession(with:event:source:))
        guard let inherited = class_getInstanceMethod(WKWebView.self, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(inherited), to: Begin.self)
        let replacement: @convention(block) (NSView, NSArray, NSEvent, AnyObject) -> NSDraggingSession? = {
            view, items, event, source in
            // AppKit and WebKit begin drags on the main thread.
            nonisolated(unsafe) let view = view
            nonisolated(unsafe) let event = event
            let refused = MainActor.assumeIsolated {
                guard AutomationInput.isDrivenMouseDown(event) else { return false }
                AutomationDragGuard.refuse(view, event)
                return true
            }
            return refused ? nil : original(view, selector, items, event, source)
        }
        let implementation = imp_implementationWithBlock(replacement)
        if !class_addMethod(WKWebView.self, selector, implementation, method_getTypeEncoding(inherited)) {
            method_setImplementation(inherited, implementation)
        }
    }

    /// Ends the drag WebKit thinks it began — after it has finished beginning it.
    private static func refuse(_ view: NSView, _ event: NSEvent) {
        refusedDragCount += 1
        let screenPoint = view.window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
        DispatchQueue.main.async {
            let selector = NSSelectorFromString("draggingSession:endedAtPoint:operation:")
            guard let method = class_getInstanceMethod(type(of: view), selector) else { return }
            let ended = unsafeBitCast(method_getImplementation(method), to: Ended.self)
            // No session exists; WebKit's handler reads only the point and the operation.
            ended(view, selector, nil, screenPoint, NSDragOperation().rawValue)
        }
    }
}
