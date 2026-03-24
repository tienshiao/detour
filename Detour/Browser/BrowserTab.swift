import AppKit
import WebKit
import Combine

// Private C API to enable PiP support in WKWebView on macOS
@_silgen_name("WKPreferencesSetAllowsPictureInPictureMediaPlayback")
private func WKPreferencesSetAllowsPictureInPictureMediaPlayback(_ preferences: AnyObject, _ allowed: Bool)

class BrowserTab: NSObject {
    let id: UUID
    private(set) var webView: WKWebView?

    private static func unarchiveInteractionState(_ data: Data) -> Any? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = false
        return unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
    }

    @Published var title: String = "New Tab"
    @Published var url: URL?
    @Published var isLoading: Bool = false
    @Published var isSleeping: Bool = false
    @Published var isPlayingAudio: Bool = false
    @Published var isMuted: Bool = false
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var blockedCount: Int = 0
    @Published var estimatedProgress: Double = 0
    @Published var favicon: NSImage?
    private(set) var faviconURL: URL?
    var spaceID: UUID?
    var parentID: UUID?
    private var cachedInteractionState: Data?

    // MARK: - Peek State
    var peekTab: BrowserTab?
    var peekURL: URL?
    var peekInteractionState: Data?
    var peekFaviconURL: URL?
    @Published var peekFavicon: NSImage?

    func savePeekStateForPersistence() {
        peekURL = peekTab?.webView?.url ?? peekURL
        peekFaviconURL = peekTab?.faviconURL ?? peekFaviconURL
        if let data = peekTab?.currentInteractionStateData() {
            peekInteractionState = data
        }
    }

    var displayPeekFavicon: NSImage? {
        peekTab?.favicon ?? peekFavicon
    }

    func clearPeekState() {
        peekTab = nil
        peekURL = nil
        peekInteractionState = nil
        peekFaviconURL = nil
        peekFavicon = nil
    }

    func downloadPeekFavicon() {
        guard let url = peekFaviconURL else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
            guard let data,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.peekFavicon = image
            }
        }.resume()
    }

    // MARK: - Archiving

    var lastDeselectedAt: Date?

    private var faviconCancellables = Set<AnyCancellable>()
    private var lastAttemptedURL: URL?
    private var navigationPending = false
    private var previousHost: String?
    private var faviconGeneration: Int = 0

    private static func makeWebView(configuration: WKWebViewConfiguration) -> BrowserWebView {
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        WKPreferencesSetAllowsPictureInPictureMediaPlayback(configuration.preferences, true)
        if configuration.urlSchemeHandler(forURLScheme: ErrorPage.scheme) == nil {
            configuration.setURLSchemeHandler(ErrorSchemeHandler(), forURLScheme: ErrorPage.scheme)
        }
        let webView = BrowserWebView(frame: .zero, configuration: configuration)
        webView.isInspectable = true
        return webView
    }

    init(id: UUID = UUID(), configuration: WKWebViewConfiguration = WKWebViewConfiguration()) {
        self.id = id
        self.webView = Self.makeWebView(configuration: configuration)
        super.init()
        applyUserAgent()
        setupObservers()
        NotificationCenter.default.addObserver(self, selector: #selector(userAgentDidChange(_:)), name: .init("UserAgentDidChange"), object: nil)
    }

    /// Creates a tab that adopts an existing, already-loaded WKWebView.
    init(id: UUID = UUID(), webView: WKWebView) {
        self.id = id
        self.webView = webView
        super.init()
        self.webView?.isInspectable = true
        // Seed published properties from the existing webView state
        self.url = webView.url
        if let t = webView.title, !t.isEmpty { self.title = t }
        self.isLoading = webView.isLoading
        self.canGoBack = webView.canGoBack
        self.canGoForward = webView.canGoForward
        setupObservers()
        if !webView.isLoading {
            fetchFavicon()
        }
    }

    /// Creates a sleeping tab that retains metadata but has no WebView.
    init(id: UUID, title: String, url: URL?, faviconURL: URL?,
         cachedInteractionState: Data?, spaceID: UUID) {
        self.id = id
        self.webView = nil
        self.isSleeping = true
        self.cachedInteractionState = cachedInteractionState
        self.spaceID = spaceID
        super.init()
        self.title = title
        self.url = url
        if let faviconURL {
            self.faviconURL = faviconURL
            self.previousHost = url?.host
            downloadFavicon(from: faviconURL, generation: self.faviconGeneration)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(userAgentDidChange(_:)), name: .init("UserAgentDidChange"), object: nil)
    }

    convenience init(id: UUID, title: String, archivedInteractionState: Data?, fallbackURL: URL?, faviconURL: URL? = nil, configuration: WKWebViewConfiguration = WKWebViewConfiguration()) {
        self.init(id: id, configuration: configuration)
        self.title = title
        if let faviconURL {
            self.faviconURL = faviconURL
            self.previousHost = fallbackURL?.host
            downloadFavicon(from: faviconURL, generation: self.faviconGeneration)
        }
        self.url = fallbackURL
        if let archivedInteractionState,
           let state = Self.unarchiveInteractionState(archivedInteractionState) {
            webView?.interactionState = state
        } else if let fallbackURL {
            load(fallbackURL)
        }
    }

    func takeSnapshot(completion: ((NSImage?) -> Void)? = nil) {
        guard let webView else { completion?(nil); return }
        webView.takeSnapshot(with: nil) { image, _ in
            completion?(image)
        }
    }

    deinit {
        webView?.removeObserver(self, forKeyPath: "_isPlayingAudio")
        NotificationCenter.default.removeObserver(self, name: .init("UserAgentDidChange"), object: nil)
    }

    private func applyUserAgent() {
        if let spaceID, let profile = TabStore.shared.space(withID: spaceID)?.profile {
            webView?.customUserAgent = profile.resolvedUserAgent()
        } else {
            // Fallback for tabs not yet assigned to a space
            webView?.customUserAgent = "\(UserAgentMode.safariUserAgent) \(UserAgentMode.detourAppName)"
        }
    }

    /// Override the UA for domains that require Chrome (e.g. Chrome Web Store).
    /// Restores the normal UA when navigating away.
    func applySpoofedUserAgent(for url: URL) {
        if let spoofed = UserAgentMode.spoofedUserAgent(for: url.host) {
            webView?.customUserAgent = spoofed
        } else {
            applyUserAgent()
        }
    }

    @objc private func userAgentDidChange(_ notification: Notification) {
        if let profileID = notification.userInfo?["profileID"] as? UUID {
            guard let spaceID, let space = TabStore.shared.space(withID: spaceID),
                  space.profileID == profileID else { return }
        }
        applyUserAgent()
    }

    func enterPictureInPicture() {
        guard let webView else { return }
        let js = """
        (function search(doc) {
            for (const video of doc.querySelectorAll('video')) {
                if (!video.paused && video.webkitSupportsPresentationMode
                    && video.webkitSupportsPresentationMode('picture-in-picture')) {
                    video.webkitSetPresentationMode('picture-in-picture');
                    return true;
                }
            }
            for (const iframe of doc.querySelectorAll('iframe')) {
                try { if (search(iframe.contentDocument)) return true; } catch(e) {}
            }
            return false;
        })(document)
        """
        webView.evaluateJavaScript(js)
    }

    func exitPictureInPicture() {
        guard let webView else { return }
        let js = """
        (function search(doc) {
            for (const video of doc.querySelectorAll('video')) {
                if (video.webkitPresentationMode === 'picture-in-picture') {
                    video.webkitSetPresentationMode('inline');
                    return true;
                }
            }
            for (const iframe of doc.querySelectorAll('iframe')) {
                try { if (search(iframe.contentDocument)) return true; } catch(e) {}
            }
            return false;
        })(document)
        """
        webView.evaluateJavaScript(js)
    }

    func toggleMute() {
        guard let webView else { return }
        isMuted.toggle()
        let muted = isMuted
        let js = """
        (function search(doc) {
            doc.querySelectorAll('video, audio').forEach(el => el.muted = \(muted));
            for (const iframe of doc.querySelectorAll('iframe')) {
                try { search(iframe.contentDocument); } catch(e) {}
            }
        })(document)
        """
        webView.evaluateJavaScript(js)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "_isPlayingAudio" {
            DispatchQueue.main.async { [weak self] in
                self?.isPlayingAudio = change?[.newKey] as? Bool ?? false
            }
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }

    private func setupObservers() {
        guard let webView else { return }

        webView.publisher(for: \.url)
            .sink { [weak self] url in
                guard let self else { return }
                if let url, !self.navigationPending { self.lastAttemptedURL = url }
                if url?.scheme == ErrorPage.scheme { return }
                self.url = url
            }
            .store(in: &faviconCancellables)

        webView.publisher(for: \.title)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &faviconCancellables)

        webView.publisher(for: \.url)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &faviconCancellables)

        webView.publisher(for: \.isLoading)
            .sink { [weak self] loading in
                guard let self else { return }
                self.isLoading = loading
                if !loading && self.navigationPending {
                    self.navigationPending = false
                    self.updateTitle()
                }
            }
            .store(in: &faviconCancellables)

        webView.publisher(for: \.canGoBack)
            .assign(to: &$canGoBack)

        webView.publisher(for: \.canGoForward)
            .assign(to: &$canGoForward)

        webView.publisher(for: \.estimatedProgress)
            .assign(to: &$estimatedProgress)

        webView.addObserver(self, forKeyPath: "_isPlayingAudio", options: [.new], context: nil)

        webView.publisher(for: \.url)
            .compactMap { url -> (String, String)? in
                guard let host = url?.host, let scheme = url?.scheme else { return nil }
                return (host, scheme)
            }
            .removeDuplicates { $0.0 == $1.0 }
            .sink { [weak self] host, scheme in
                guard let self, !self.navigationPending else { return }
                guard scheme != ErrorPage.scheme else { return }
                guard self.previousHost != host else { return }
                if self.previousHost != nil {
                    self.favicon = nil
                    self.faviconURL = nil
                }
                self.faviconGeneration += 1
                let generation = self.faviconGeneration
                self.previousHost = host
                let optimisticURL = URL(string: "\(scheme)://\(host)/favicon.ico")!
                self.downloadFavicon(from: optimisticURL, generation: generation)
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
        guard let webView, webView.url?.scheme != ErrorPage.scheme else { return }
        let generation = self.faviconGeneration
        let js = "document.querySelector(\"link[rel~='icon'], link[rel='shortcut icon']\")?.href"
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self, self.faviconGeneration == generation else { return }
            if let urlString = result as? String,
               let url = URL(string: urlString),
               url != self.faviconURL {
                self.downloadFavicon(from: url, generation: generation)
            }
        }
    }

    private func downloadFavicon(from url: URL, generation: Int) {
        URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
            guard let data,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                guard let self, self.faviconGeneration == generation else { return }
                self.faviconURL = url
                self.favicon = image
            }
        }.resume()
    }

    // MARK: - Sleep / Wake

    func sleep() {
        guard let webView, !isSleeping, !isPlayingAudio else { return }

        if let peek = peekTab {
            savePeekStateForPersistence()
            peek.sleep()
        }

        // Capture interaction state for later restoration
        if let state = webView.interactionState {
            cachedInteractionState = try? NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: false)
        }

        // Tear down observers and webView
        webView.removeObserver(self, forKeyPath: "_isPlayingAudio")
        faviconCancellables.removeAll()
        webView.removeFromSuperview()
        self.webView = nil

        isSleeping = true
        isLoading = false
        estimatedProgress = 0
        canGoBack = false
        canGoForward = false
    }

    func wake() {
        guard webView == nil else { return }

        let config: WKWebViewConfiguration
        if let spaceID, let space = TabStore.shared.space(withID: spaceID) {
            config = space.makeWebViewConfiguration()
        } else {
            config = WKWebViewConfiguration()
        }

        self.webView = Self.makeWebView(configuration: config)
        applyUserAgent()
        setupObservers()

        if let cachedInteractionState,
           let state = Self.unarchiveInteractionState(cachedInteractionState) {
            webView?.interactionState = state
        } else if let url {
            webView?.load(URLRequest(url: url))
        }

        isSleeping = false
        cachedInteractionState = nil
    }

    func currentInteractionStateData() -> Data? {
        if let webView, let state = webView.interactionState {
            return try? NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: false)
        }
        return cachedInteractionState
    }

    func load(_ url: URL) {
        if isSleeping { wake() }
        lastAttemptedURL = url
        self.url = url
        blockedCount = 0
        navigationPending = true
        applySpoofedUserAgent(for: url)
        if url.host != previousHost {
            favicon = nil
            faviconURL = nil
        }
        // Optimistic favicon fetch for programmatic navigations
        if let host = url.host, let scheme = url.scheme, scheme != ErrorPage.scheme {
            if host != previousHost {
                faviconGeneration += 1
                let generation = faviconGeneration
                previousHost = host
                let optimisticURL = URL(string: "\(scheme)://\(host)/favicon.ico")!
                downloadFavicon(from: optimisticURL, generation: generation)
            } else {
                previousHost = host
            }
        }
        updateTitle()
        webView?.load(URLRequest(url: url))
    }

    func reload() {
        if isSleeping { wake() }
        if webView?.url?.scheme == ErrorPage.scheme, let lastAttemptedURL {
            load(lastAttemptedURL)
        } else {
            webView?.reload()
        }
    }

    func didCommitNavigation() {
        navigationPending = false
        blockedCount = 0
        updateTitle()
    }

    func didFailProvisionalNavigation(error: Error) {
        guard let lastAttemptedURL else { return }

        url = lastAttemptedURL
        favicon = nil
        faviconURL = nil
        faviconGeneration += 1
        previousHost = nil

        webView?.load(URLRequest(url: ErrorPage.url(for: lastAttemptedURL, error: error)))
    }

    private func updateTitle() {
        if navigationPending, let lastAttemptedURL {
            title = strippedScheme(lastAttemptedURL)
        } else if let webTitle = webView?.title, !webTitle.isEmpty {
            title = webTitle
        } else if let displayURL = webView?.url ?? lastAttemptedURL {
            title = strippedScheme(displayURL)
        } else if !isSleeping {
            title = "New Tab"
        }
    }

    var displayHost: String {
        guard let host = url?.host else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func strippedScheme(_ url: URL) -> String {
        var str = url.absoluteString
        for prefix in ["https://www.", "http://www.", "https://", "http://"] {
            if str.hasPrefix(prefix) {
                str = String(str.dropFirst(prefix.count))
                break
            }
        }
        return str
    }
}

