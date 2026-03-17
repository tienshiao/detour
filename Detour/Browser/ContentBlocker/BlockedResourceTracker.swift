import Foundation
import WebKit

class BlockedResourceTracker {
    static let messageName = "blockedCount"

    static let userScript: WKUserScript = {
        let source = """
        (function() {
            if (window.__detourBlockTracker) return;
            window.__detourBlockTracker = true;
            var count = 0;
            document.addEventListener('error', function(e) {
                var tag = e.target.tagName;
                if (tag === 'IMG' || tag === 'SCRIPT' || tag === 'LINK' ||
                    tag === 'IFRAME' || tag === 'VIDEO' || tag === 'AUDIO' ||
                    tag === 'SOURCE' || tag === 'OBJECT') {
                    count++;
                    window.webkit.messageHandlers.blockedCount.postMessage(count);
                }
            }, true);
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }()
}
