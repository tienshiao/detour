import AppKit
import WebKit
import Combine

class BrowserTab {
    let id: UUID
    let webView: WKWebView

    @Published var title: String = "New Tab"
    @Published var url: URL?
    @Published var isLoading: Bool = false
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var estimatedProgress: Double = 0
    @Published var latestSnapshot: NSImage?

    init(id: UUID = UUID(), configuration: WKWebViewConfiguration = WKWebViewConfiguration()) {
        self.id = id
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        setupObservers()
    }

    convenience init(id: UUID, title: String, archivedInteractionState: Data?, fallbackURL: URL?) {
        self.init(id: id)
        self.title = title
        if let archivedInteractionState,
           let state = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(archivedInteractionState) {
            webView.interactionState = state
        } else if let fallbackURL {
            load(fallbackURL)
        }
    }

    func takeSnapshot(completion: ((NSImage?) -> Void)? = nil) {
        webView.takeSnapshot(with: nil) { [weak self] image, _ in
            self?.latestSnapshot = image
            completion?(image)
        }
    }

    private func setupObservers() {
        webView.publisher(for: \.title)
            .map { $0 ?? "New Tab" }
            .assign(to: &$title)

        webView.publisher(for: \.url)
            .assign(to: &$url)

        webView.publisher(for: \.isLoading)
            .assign(to: &$isLoading)

        webView.publisher(for: \.canGoBack)
            .assign(to: &$canGoBack)

        webView.publisher(for: \.canGoForward)
            .assign(to: &$canGoForward)

        webView.publisher(for: \.estimatedProgress)
            .assign(to: &$estimatedProgress)
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }
}
