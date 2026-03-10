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
    @Published var favicon: NSImage?
    private(set) var faviconURL: URL?

    private var faviconCancellables = Set<AnyCancellable>()
    private var previousHost: String?

    init(id: UUID = UUID(), configuration: WKWebViewConfiguration = WKWebViewConfiguration()) {
        self.id = id
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        self.webView.isInspectable = true
        setupObservers()
    }

    convenience init(id: UUID, title: String, archivedInteractionState: Data?, fallbackURL: URL?, faviconURL: URL? = nil, configuration: WKWebViewConfiguration = WKWebViewConfiguration()) {
        self.init(id: id, configuration: configuration)
        self.title = title
        if let faviconURL {
            self.faviconURL = faviconURL
            downloadFavicon(from: faviconURL)
        }
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

        webView.publisher(for: \.url)
            .compactMap { $0?.host }
            .removeDuplicates()
            .sink { [weak self] host in
                guard let self else { return }
                if self.previousHost != nil, self.previousHost != host {
                    self.favicon = nil
                    self.faviconURL = nil
                }
                self.previousHost = host
            }
            .store(in: &faviconCancellables)

        $isLoading
            .removeDuplicates()
            .filter { !$0 }
            .dropFirst()
            .sink { [weak self] _ in self?.fetchFavicon() }
            .store(in: &faviconCancellables)
    }

    private func fetchFavicon() {
        let js = "document.querySelector(\"link[rel~='icon'], link[rel='shortcut icon']\")?.href"
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self else { return }
            if let urlString = result as? String, let url = URL(string: urlString) {
                self.downloadFavicon(from: url)
            } else if let pageURL = self.url,
                      let scheme = pageURL.scheme,
                      let host = pageURL.host {
                let fallback = URL(string: "\(scheme)://\(host)/favicon.ico")!
                self.downloadFavicon(from: fallback)
            }
        }
    }

    private func downloadFavicon(from url: URL) {
        URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
            guard let data,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                self?.faviconURL = url
                self?.favicon = image
            }
        }.resume()
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }
}
