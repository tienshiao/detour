import AppKit

/// Where the dev toolbar (TASK-186.2) and the web view under it go inside a
/// tab's `WebViewContainerView`. Pure, so the geometry is unit-tested
/// (`DevToolbarLayoutTests`).
///
/// The container is laid out by frames, never Auto Layout, because WebKit's
/// docked Web Inspector is a sibling of the web view in the same container and
/// re-frames both itself. When it docks (bottom, left or right) or detaches,
/// WebKit keeps the web view's top edge (`NSMaxY` of its frame) where it was,
/// "so banners in Safari still work" (`WebInspectorUIProxy::inspectedViewFrameDidChange`
/// and `platformDetach`). So the toolbar is such a banner: the web view's top
/// is lowered by the toolbar's height, and docking keeps it there.
///
/// - Bottom dock: the inspector takes the bottom; the web view's `minY` rises.
/// - Left or right dock: the inspector spans the container's full height and
///   the web view narrows, so the toolbar follows the web view's x and width,
///   not the container's.
enum DevToolbarLayout {
    static let height: CGFloat = 30

    /// Corner masks in an unflipped layer's coordinates (y up). While the
    /// toolbar shows in a rounded pane, it rounds only the pane's top corners
    /// and the web view only the bottom ones, so there is no notch between them.
    static let topCorners: CACornerMask = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    static let bottomCorners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    static let allCorners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner,
                                           .layerMinXMaxYCorner, .layerMaxXMaxYCorner]

    struct Frames: Equatable {
        /// Nil when the toolbar is hidden.
        var toolbar: NSRect?
        var webView: NSRect
    }

    /// The web view keeps its x, width and bottom edge (a bottom-docked
    /// inspector's height); only its top moves: `toolbarHeight` below the
    /// container's top while the toolbar shows, at the container's top when it
    /// does not. Toggling the toolbar on and off therefore returns the web
    /// view's original frame, docked inspector or not.
    static func frames(containerBounds: NSRect, webViewFrame: NSRect,
                       toolbarHeight: CGFloat = height, showsToolbar: Bool) -> Frames {
        let top = containerBounds.maxY - (showsToolbar ? toolbarHeight : 0)
        let webView = NSRect(x: webViewFrame.minX, y: webViewFrame.minY,
                             width: webViewFrame.width, height: max(0, top - webViewFrame.minY))
        let toolbar = showsToolbar
            ? toolbarFrame(containerBounds: containerBounds, webViewFrame: webView, toolbarHeight: toolbarHeight)
            : nil
        return Frames(toolbar: toolbar, webView: webView)
    }

    /// The toolbar over a web view at `webViewFrame`: across the web view's
    /// width, at the container's top. Used on its own when something else
    /// (WebKit docking the inspector) re-frames the web view.
    static func toolbarFrame(containerBounds: NSRect, webViewFrame: NSRect,
                             toolbarHeight: CGFloat = height) -> NSRect {
        NSRect(x: webViewFrame.minX, y: containerBounds.maxY - toolbarHeight,
               width: webViewFrame.width, height: toolbarHeight)
    }
}
