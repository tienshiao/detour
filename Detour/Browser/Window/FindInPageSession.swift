import WebKit

/// Find in page for one window: the query being searched, its match count and
/// which match is current, written to the window's `FindBarView`. Shared by a
/// browser window and a Quick Detour window (TASK-193.1), which differ only in
/// which web view the find runs in.
final class FindInPageSession {
    private let bar: FindBarView
    private var matchCount = 0
    private var matchIndex = 0
    private var lastQuery = ""

    init(bar: FindBarView) {
        self.bar = bar
    }

    /// Finds `text` in `webView`, forwards or backwards from the current
    /// match; a new query counts its matches first.
    func perform(_ text: String, backwards: Bool, in webView: WKWebView) {
        let isNewQuery = text != lastQuery
        if isNewQuery {
            lastQuery = text
            matchIndex = 0
            countMatches(for: text, in: webView)
        }

        let config = WKFindConfiguration()
        config.backwards = backwards
        config.wraps = true
        webView.find(text, configuration: config) { [weak self] result in
            guard let self else { return }
            if result.matchFound {
                if !isNewQuery {
                    if backwards {
                        self.matchIndex -= 1
                        if self.matchIndex < 1 { self.matchIndex = self.matchCount }
                    } else {
                        self.matchIndex += 1
                        if self.matchIndex > self.matchCount { self.matchIndex = 1 }
                    }
                }
                self.updateLabel()
            } else {
                self.matchCount = 0
                self.matchIndex = 0
                self.bar.updateResultLabel("Not found")
            }
        }
    }

    /// Forgets the query, as dismissing the bar does.
    func reset() {
        bar.searchField.stringValue = ""
        bar.updateResultLabel("")
        lastQuery = ""
        matchCount = 0
        matchIndex = 0
    }

    private func countMatches(for text: String, in webView: WKWebView) {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        let js = """
        (function() {
            var t = '\(escaped)'.toLowerCase();
            var body = document.body.innerText.toLowerCase();
            var count = 0, pos = 0;
            while ((pos = body.indexOf(t, pos)) !== -1) { count++; pos += t.length; }
            return count;
        })()
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self, self.lastQuery == text else { return }
            self.matchCount = (result as? Int) ?? 0
            if self.matchCount > 0 {
                self.matchIndex = 1
            }
            self.updateLabel()
        }
    }

    private func updateLabel() {
        if matchCount > 0 {
            bar.updateResultLabel("\(matchIndex) of \(matchCount)")
        } else {
            bar.updateResultLabel("Not found")
        }
    }
}
