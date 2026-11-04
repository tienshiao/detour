import AppKit
import WebKit

/// Every private WebKit call the now-playing bar and the sidebar's speaker
/// button make, in one place (TASK-192). Muting a whole page — every frame,
/// cross-origin iframes and Web Audio included — has no public API: it is
/// `-[WKWebView _setPageMuted:]` with a `_WKMediaMutedState` bit set, read
/// back through `_mediaMutedState`. See wiki/platform/media-controls.md.
///
/// Each selector is checked with `responds(to:)` before it is sent, so a
/// WebKit that drops one hides the control that needs it (`canMutePage`)
/// instead of crashing.
struct PageMediaControl {
    /// Built from strings: the SPI is not in the SDK headers.
    enum Selectors {
        static let setPageMuted = NSSelectorFromString("_setPageMuted:")
        static let mediaMutedState = NSSelectorFromString("_mediaMutedState")
    }

    /// `_WKMediaMutedState`'s audio bit (`_WKMediaAudioMuted`). The other bits
    /// mute camera, microphone and screen capture, and must survive a change
    /// to this one.
    static let audioMutedBit: UInt = 1 << 0

    /// The flags to send for `audioMuted`, keeping every other bit of
    /// `current` as it is: `_setPageMuted:` replaces the whole set, so passing
    /// only the audio bit would unmute a muted camera or microphone.
    static func mutedState(from current: UInt, audioMuted: Bool) -> UInt {
        audioMuted ? current | audioMutedBit : current & ~audioMutedBit
    }

    /// Whether this WebKit can mute a page, given which selectors a web view
    /// answers. Both are needed: the setter replaces every bit, so the current
    /// ones have to be read first.
    static func canMutePage(webViewResponds: (Selector) -> Bool) -> Bool {
        webViewResponds(Selectors.setPageMuted) && webViewResponds(Selectors.mediaMutedState)
    }

    /// This process's WebKit, read once from the class.
    static let canMutePage: Bool = canMutePage(webViewResponds: { WKWebView.instancesRespond(to: $0) })

    let webView: WKWebView

    /// Whether the page's audio is muted; false when this WebKit cannot say.
    var isPageAudioMuted: Bool {
        (currentMutedState() & Self.audioMutedBit) != 0
    }

    /// Mutes or unmutes every frame's audio, Web Audio included. Returns false
    /// (and does nothing) when this WebKit has no `_setPageMuted:`.
    @discardableResult
    func setPageAudioMuted(_ muted: Bool) -> Bool {
        guard Self.canMutePage, webView.responds(to: Selectors.setPageMuted) else { return false }
        typealias SetMuted = @convention(c) (AnyObject, Selector, UInt) -> Void
        let send = unsafeBitCast(webView.method(for: Selectors.setPageMuted), to: SetMuted.self)
        send(webView, Selectors.setPageMuted, Self.mutedState(from: currentMutedState(), audioMuted: muted))
        return true
    }

    private func currentMutedState() -> UInt {
        guard webView.responds(to: Selectors.mediaMutedState) else { return 0 }
        typealias MutedState = @convention(c) (AnyObject, Selector) -> UInt
        let read = unsafeBitCast(webView.method(for: Selectors.mediaMutedState), to: MutedState.self)
        return read(webView, Selectors.mediaMutedState)
    }
}
