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
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = Int(filter.contentRect.width * scale)
        configuration.height = Int(filter.contentRect.height * scale)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
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

    /// The window's content: AppKit's drawing of the content view, with the
    /// sidebar drawn over it from its layer.
    static func window(_ controller: BrowserWindowController) throws -> NSBitmapImageRep {
        guard let window = controller.window, let content = window.contentView else {
            throw AutomationToolError(.unknownWindow, "The window has no content")
        }
        content.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bounds = content.bounds
        guard let rep = content.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw AutomationToolError(.internalError, "Could not make a bitmap for the window")
        }
        content.cacheDisplay(in: bounds, to: rep)

        let sidebar = controller.tabSidebar.view
        if !sidebar.isHiddenOrHasHiddenAncestor, sidebar.window === window, let layer = sidebar.layer,
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
