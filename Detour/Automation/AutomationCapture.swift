import AppKit
import ScreenCaptureKit
import WebKit

/// Pictures of Detour's own views for the automation endpoint (TASK-228.1,
/// AC #4), taken inside the app, so they need no Screen Recording grant.
/// What the wiki's in-process automation playbook found, applied here:
/// - `cacheDisplay` draws a window's content, web content included, but
///   leaves the sidebar blank: the sidebar is drawn again from its layer.
/// - A page on its own comes from WebKit's snapshot of its web view.
/// - Neither draws what the window server composites: glass and
///   vibrancy (the sidebar's material, which comes out light in dark mode;
///   the command palette, find bar, toasts and hover cards, which come out
///   blank). For those, `screen` asks the window server through
///   ScreenCaptureKit, which needs the Screen Recording grant.
enum AutomationCapture {

    /// The window as the window server composites it, glass and all, without
    /// its shadow. Needs Screen Recording for Detour, or for the app that
    /// launched it (a test run from a terminal that has the grant). Checked
    /// first without asking: the system prompt never appears from here.
    static func screen(_ window: NSWindow) async throws -> NSBitmapImageRep {
        guard CGPreflightScreenCaptureAccess() else {
            throw AutomationToolError(.permissionDenied,
                                      "Screen Recording is not granted to Detour (or the app that launched it); "
                                        + "use source app, or grant it in System Settings")
        }
        let windowID = CGWindowID(window.windowNumber)
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw AutomationToolError(.permissionDenied, "ScreenCaptureKit refused: \(error.localizedDescription)")
        }
        guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
            throw AutomationToolError(.notDisplayed, "The window server does not list the window")
        }
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        let filter: SCContentFilter
        let scale: CGFloat
        if let region = pointerFreeRegion(of: window, in: content) {
            // The agent pointer's overlay (TASK-228.11) is a child window, and
            // a desktop-independent window's picture includes its child
            // windows (seen at runtime). The display, cropped to the window,
            // with every window excluded but this one and its other child
            // windows, leaves the overlay out and keeps everything else the
            // window's own picture would show. Not `including:` the kept
            // windows: that drew the overlay too (seen at runtime), as if a
            // window brought its children along.
            let kept = Set([windowID] + (window.childWindows ?? [])
                .filter { !($0 is AutomationAgentPointerWindow) }.map { CGWindowID($0.windowNumber) })
            filter = SCContentFilter(display: region.display,
                                     excludingWindows: content.windows.filter { !kept.contains($0.windowID) })
            scale = CGFloat(filter.pointPixelScale)
            configuration.sourceRect = region.rect
            configuration.width = Int(region.rect.width * scale)
            configuration.height = Int(region.rect.height * scale)
            configuration.ignoreShadowsDisplay = true
            configuration.backgroundColor = .clear
        } else {
            filter = SCContentFilter(desktopIndependentWindow: scWindow)
            scale = CGFloat(filter.pointPixelScale)
            configuration.width = Int(filter.contentRect.width * scale)
            configuration.height = Int(filter.contentRect.height * scale)
            configuration.ignoreShadowsSingleWindow = true
        }
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            throw AutomationToolError(.internalError, "The window server made no image: \(error.localizedDescription)")
        }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        return rep
    }

    /// Where to crop a display to `window`, when the agent pointer's overlay
    /// is over it and the window lies on one display on the active Space; nil
    /// otherwise (the window's own picture then has no overlay to leave out,
    /// or the overlay shows in it, for a window across displays or on another
    /// Space, which a display picture would not have at all).
    private static func pointerFreeRegion(of window: NSWindow,
                                          in content: SCShareableContent) -> (display: SCDisplay, rect: CGRect)? {
        guard window.childWindows?.contains(where: { $0 is AutomationAgentPointerWindow && $0.isVisible }) == true,
              window.isOnActiveSpace,
              let screen = window.screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let display = content.displays.first(where: { $0.displayID == number.uint32Value }),
              screen.frame.contains(window.frame) else { return nil }
        // The display's points, top-left origin.
        let frame = window.frame
        return (display, CGRect(x: frame.minX - screen.frame.minX, y: screen.frame.maxY - frame.maxY,
                                width: frame.width, height: frame.height))
    }

    /// The window's content: AppKit's drawing of the content view, with a
    /// browser window's `sidebar` drawn over it from its layer.
    static func window(_ window: NSWindow, sidebar: NSView?) throws -> NSBitmapImageRep {
        guard let content = window.contentView else {
            throw AutomationToolError(.unknownWindow, "The window has no content")
        }
        content.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bounds = content.bounds
        guard let rep = content.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw AutomationToolError(.internalError, "Could not make a bitmap for the window")
        }
        content.cacheDisplay(in: bounds, to: rep)

        if let sidebar, !sidebar.isHiddenOrHasHiddenAncestor, sidebar.window === window, let layer = sidebar.layer,
           let context = NSGraphicsContext(bitmapImageRep: rep) {
            let rect = sidebar.convert(sidebar.bounds, to: content)
            let scale = CGFloat(rep.pixelsWide) / max(1, bounds.width)
            let cg = context.cgContext
            cg.saveGState()
            // The bitmap's context is in pixels with a bottom-left origin.
            let originY = content.isFlipped ? bounds.height - rect.maxY : rect.minY
            cg.translateBy(x: rect.minX * scale, y: originY * scale)
            cg.scaleBy(x: scale, y: scale)
            layer.render(in: cg)
            cg.restoreGState()
            context.flushGraphics()
        }
        return rep
    }

    /// The sidebar on its own, from its layer.
    static func sidebar(_ controller: BrowserWindowController) throws -> NSBitmapImageRep {
        let view = controller.tabSidebar.view
        guard !view.isHiddenOrHasHiddenAncestor, view.bounds.width >= 1, view.bounds.height >= 1,
              let layer = view.layer else {
            throw AutomationToolError(.notDisplayed, "The sidebar is hidden")
        }
        let scale = controller.window?.backingScaleFactor ?? 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale),
                                         pixelsHigh: Int(view.bounds.height * scale), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw AutomationToolError(.internalError, "Could not make a bitmap for the sidebar")
        }
        rep.size = view.bounds.size
        context.cgContext.scaleBy(x: scale, y: scale)
        layer.render(in: context.cgContext)
        context.flushGraphics()
        return rep
    }

    /// A page as WebKit draws it, at its web view's size.
    static func page(_ webView: WKWebView) async throws -> NSBitmapImageRep {
        let image: NSImage
        do {
            image = try await webView.takeSnapshot(configuration: nil)
        } catch {
            throw AutomationToolError(.internalError, "WebKit made no snapshot: \(error.localizedDescription)")
        }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw AutomationToolError(.internalError, "The snapshot has no bitmap")
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = image.size
        return rep
    }

    /// `rep` at `scale` pixels per point (1 makes a smaller image for a
    /// model; 2 keeps a Retina capture's pixels).
    static func scaled(_ rep: NSBitmapImageRep, to scale: CGFloat) -> NSBitmapImageRep {
        let size = rep.size
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width != rep.pixelsWide || height != rep.pixelsHigh,
              let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: out) else { return rep }
        out.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        // A bitmap's context is in pixels, whatever its size in points says.
        context.cgContext.scaleBy(x: scale, y: scale)
        rep.draw(in: NSRect(x: 0, y: 0, width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    static func png(_ rep: NSBitmapImageRep) throws -> Data {
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw AutomationToolError(.internalError, "Could not encode the PNG")
        }
        return data
    }
}
