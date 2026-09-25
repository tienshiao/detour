import AppKit
import WebKit
import Combine

// Private C API to enable PiP support in WKWebView on macOS
@_silgen_name("WKPreferencesSetAllowsPictureInPictureMediaPlayback")
private func WKPreferencesSetAllowsPictureInPictureMediaPlayback(_ preferences: AnyObject, _ allowed: Bool)

/// Container for a tab's webView plus whatever WebKit docks next to it (the
/// Web Inspector attaches as a sibling of the webView at any time). When the
/// container is hosted as a split pane its content must clip to the card's
/// rounded corners — the clipping lives here, on didAddSubview, so views that
/// attach AFTER the pane chrome was applied are clipped too. The container's
/// own layer must not clip (masksToBounds kills the pane's shadow).
final class WebViewContainerView: NSView {
    /// Rounded-card clipping applied to every subview; 0 restores defaults.
    var contentCornerRadius: CGFloat = 0 {
        didSet {
            guard contentCornerRadius != oldValue else { return }
            subviews.forEach(applyContentClipping)
        }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        applyContentClipping(subview)
    }

    private func applyContentClipping(_ view: NSView) {
        view.wantsLayer = true
        view.layer?.cornerRadius = contentCornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = contentCornerRadius > 0
    }
}

class BrowserTab: NSObject {
    let id: UUID
    private(set) var webView: WKWebView? {
        didSet {
            // Every web view a tab holds is one Detour created, so it can never
            // be an extension's background page however it is navigated
            // (TASK-66). A class check would miss it: extension tabs adopt a
            // plain WKWebView (TabStore.addExtensionTab), not a BrowserWebView.
            // Property observers do not run during init, so the two inits that
            // take a web view register theirs explicitly.
            if let webView {
                ExtensionPageHostRegistry.register(webView)
                FaviconLinkBridge.register(webView, for: self)
            }
        }
    }

    /// Wraps `webView` so WebKit's docked Web Inspector (a sibling view)
    /// travels with the webView across detach/reattach.
    private(set) var webViewContainer: WebViewContainerView?

    func ensureWebViewContainer() {
        guard let webView else { return }
        if let container = webViewContainer {
            // Self-heal: a container that lost its webView would host as an
            // empty (white, unresponsive) pane — re-wrap the live webView.
            if webView.superview !== container {
                webView.translatesAutoresizingMaskIntoConstraints = true
                webView.autoresizingMask = [.width, .height]
                webView.frame = container.bounds
                container.addSubview(webView)
            }
            return
        }
        let container = WebViewContainerView()
        container.translatesAutoresizingMaskIntoConstraints = true
        container.autoresizingMask = [.width, .height]
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]
        webView.frame = container.bounds
        container.addSubview(webView)
        webViewContainer = container
    }

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
    /// The URLs behind `blockedCount`: WebKit reports a blocked load once per
    /// content rule list that acted on it, and the filter lists overlap, so a
    /// resource is counted once per page (TASK-69).
    private var blockedURLs: Set<URL> = []
    @Published var estimatedProgress: Double = 0
    @Published var favicon: NSImage?
    private(set) var faviconURL: URL?
    /// The space this tab belongs to. `wake()` resolves it to pick the
    /// configuration a new web view is built from, the profile and history
    /// lookups below go through it, and the session save and history visits are
    /// recorded under it — so it must always name a live space of the tab's
    /// profile.
    ///
    /// A favourite's backing tab has no space of its own (favourites belong to a
    /// *profile* and show in every space that shares it): it keeps the space it
    /// was brought to life in until a section move rehomes it onto the space it
    /// was dropped in, or that space is deleted and `TabStore` moves it onto
    /// another of the profile's (TASK-58).
    var spaceID: UUID?
    var parentID: UUID?
    /// The profile whose `WKWebExtensionContext`s were told this tab is open
    /// (`ExtensionTabLifecycle.didOpen`); nil means the tab is not registered
    /// with any context. Weak: a removed profile must not be kept alive by a
    /// tab, and an unregistered tab reads as nil either way. Held here rather
    /// than derived from `spaceID` because favourite and Peek tabs belong to a
    /// profile without living in any space's tab list.
    weak var extensionRegisteredProfile: Profile?
    /// The profile whose settings govern this tab's pages (its content blocker
    /// whitelist, TASK-69): its space's, or — for a peek or favourite tab that
    /// lives in no space's list — the one its extension registration named.
    var owningProfile: Profile? {
        spaceID.flatMap { TabStore.shared.space(withID: $0)?.profile } ?? extensionRegisteredProfile
    }
    /// Combine sinks installed by `ExtensionTabLifecycle.didOpen` that forward
    /// url/title/loading changes to the registered profile's contexts; cleared by
    /// `didClose`. Lives on the tab so every registered tab — normal, pinned,
    /// favourite, peek — is covered regardless of which list (if any) holds it.
    var extensionPropertyObservers = Set<AnyCancellable>()
    /// Non-nil when this tab is a member of a split group (two adjacent tabs
    /// rendered side by side as one sidebar item). Members of a group are always
    /// contiguous in `space.tabs`, in visual order (left pane first) — TabStore
    /// enforces this in every mutation.
    var splitGroupID: UUID?
    /// Width fraction of the split's left pane. Stored on every member; readers
    /// take the first member's value.
    var splitFraction: Double?
    /// Set by `load(_:typed:)` when the next load was deliberately submitted by
    /// the user (command palette URL/suggestion), so its history visit records as
    /// typed. Consumed via `consumeNextVisitIsTyped()`.
    private var nextVisitIsTyped = false
    /// The URL this tab last got a `historyURL` row for — written now, or already
    /// there and skipped by the 30 s dedup. A single-page app finishes loading
    /// the new URL *before* it rewrites `document.title`, so the recorded title
    /// is the previous page's; the late title is written back onto this URL and
    /// no other, so a tab that has since moved on never renames the page it left
    /// (TASK-88). Set only by `TabStore.recordHistoryVisit`, together with
    /// `lastRecordedHistoryAt`.
    var lastRecordedHistoryURL: URL?
    /// When the visit `lastRecordedVisitID` names was recorded — the start of
    /// the window in which a late title may still correct it
    /// (`HistoryTitleUpdatePolicy.correctionWindow`). Outside it the page is no
    /// longer settling, it is just rewriting its own title, and the history
    /// stops following (TASK-88). The window belongs to the *visit*: a later
    /// recorder pass that the 30 s dedup skips leaves it where it is, so a
    /// reload ten minutes on cannot write today's title onto this morning's
    /// visit (TASK-91).
    var lastRecordedHistoryAt: Date?
    /// The space that recording was filed under. A tab moved to another space
    /// (TASK-63) is writing another profile's history, so it may not keep
    /// correcting the visit it left behind (TASK-91).
    var lastRecordedHistorySpaceID: UUID?
    /// The id of the `historyVisit` row the recorder last wrote for this tab
    /// (TASK-91). A late title corrects *that* visit and no other — the shared
    /// `historyURL` row is one per URL, so correcting by URL renamed every visit
    /// of it, another profile's included. Nil while the insert is still in
    /// flight, or when the visit was skipped by the dedup for a URL this tab had
    /// not recorded itself; a correction with no id is dropped, and the next
    /// title event (or the dedup branch's retry) writes it.
    var lastRecordedVisitID: Int64?
    /// The web view's back/forward entry that was current when the recorder last
    /// ran (TASK-91). Same-document navigations are recognized by item identity:
    /// `pushState` and a popstate traversal select a *different* item, while
    /// `replaceState` rewrites this same item's URL — so query-string churn
    /// never becomes a visit. Weak: the list owns its items, and an entry that
    /// has fallen out of it must not be kept alive here.
    weak var lastRecordedBackForwardItem: WKBackForwardListItem?
    /// Bumped by every pass of `TabStore.recordHistoryVisit` that decides
    /// something — a visit written, or one left standing by the dedup. The
    /// insert hands its id back asynchronously, and the generation is what says
    /// whether that id is still the one this tab is holding: record A, record B,
    /// record A again, and A's first insert must not install its id over the
    /// third recording's (TASK-91).
    var historyRecordingGeneration: Int = 0
    /// How many times a window has hosted this tab's web view since that web
    /// view was created — the "show budget" `TabStore.sleepStaleTabs` uses to
    /// sleep tabs that are shown constantly but never idle long enough to sleep
    /// on time alone (pinned entries' and favourites' backing tabs). Every
    /// hide -> show of a web view strands a few purged IOSurfaces in the GPU
    /// process's per-WebContent-process pool, and only the WebContent process
    /// going away frees them (TASK-104 — see `TabStore.sleepShowBudget`).
    ///
    /// Reset wherever a fresh web view is built (`wake()`, and the inits that
    /// construct one — where the property simply starts at 0); the other
    /// assignments to `webView` set it to nil, which leaves the count
    /// meaningless rather than wrong. Never persisted: a restored tab starts
    /// asleep with no web view to have shown.
    private(set) var showsSinceWake: Int = 0
    private var cachedInteractionState: Data?

    // MARK: - Peek State
    /// A live peek is enumerated right after its host, so pointing at it here is
    /// what reports it open (TASK-52, see `ExtensionTabLifecycle`).
    var peekTab: BrowserTab? {
        didSet { peekTab.map(ExtensionTabLifecycle.didPlace) }
    }
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
        FaviconLoader.shared.load(from: url) { [weak self] image in
            guard let self, let image else { return }
            self.peekFavicon = image
        }
    }

    /// Restores the persisted peek columns of a session record and starts the
    /// peek favicon download; the shared tail of every TabRecord → BrowserTab
    /// rebuild in `TabStore.restoreSession`.
    func applyPersistedPeekState(from record: TabRecord) {
        peekURL = record.peekURL.flatMap { URL(string: $0) }
        peekInteractionState = record.peekInteractionState
        peekFaviconURL = record.peekFaviconURL.flatMap { URL(string: $0) }
        downloadPeekFavicon()
    }

    // MARK: - Archiving

    var lastDeselectedAt: Date?

    /// The Control+Tab switcher's picture of this tab (TASK-108), taken when
    /// the tab was last left on screen, and when. In memory only: a tab not
    /// left since launch is not offered by the switcher. Survives sleep.
    var switcherPreview: NSImage?
    var switcherPreviewAt: Date?
    /// Bumped per capture so a slower, older snapshot never overwrites a newer one.
    var switcherPreviewRequest = 0

    private var faviconCancellables = Set<AnyCancellable>()
    private var lastAttemptedURL: URL?
    /// Set from `wake()` until the fresh web view reports its first real URL.
    /// While it is set the URL observer ignores the web view's nil URL so `url`
    /// survives the wake; it is deliberately *not* `lastAttemptedURL`, which
    /// means "a navigation this tab asked for" and drives the error page (TASK-45).
    private var awaitingFirstURL = false
    /// Set from `wake()` when the fresh web view is handed the tab's cached
    /// session state, until a navigation commits, a user `load()` replaces the
    /// session, or the web view is released. While it is set a provisional
    /// failure keeps the restored session — no error page, and the persisted
    /// title stays — because nothing was asked for: the load that fails is the
    /// restore itself, whether WebKit started it or `loadIfStalled()` kicked it
    /// (TASK-45). `awaitingFirstURL` cannot stand in for this: the kick reports
    /// its URL synchronously, and the URL observer then also records it as
    /// `lastAttemptedURL`.
    private(set) var restoringSession = false
    /// The internal page this tab may navigate to, set only by
    /// `loadInternalPage(_:)` and by `wake()` for a tab that was already showing
    /// one. `InternalPageNavigationPolicy` refuses every other navigation to the
    /// internal scheme, so nothing that merely hands the tab a URL — an
    /// extension, a link, another app — can open a privileged page.
    private(set) var armedInternalPage: InternalPage?
    private static let blankURL = URL(string: "about:blank")!
    /// Whether the web view shows no page at all: it never navigated, or it fell
    /// back to `about:blank` after a provisional failure with nothing committed.
    private var webViewShowsNothing: Bool {
        webView?.url == nil || webView?.url == Self.blankURL
    }
    private var processTerminationCount = 0
    private var lastProcessTerminationAt: Date?
    private var navigationPending = false
    private var previousHost: String?
    private var faviconGeneration: Int = 0
    /// The generation whose page-declared icon (a `<link rel=icon>`) has
    /// landed. The optimistic `/favicon.ico` guess must not overwrite it when
    /// it finishes second — `FaviconLinkBridge` reports the link early enough
    /// that the two downloads race (TASK-112).
    private var declaredFaviconGeneration: Int?

    private static func makeWebView(configuration: WKWebViewConfiguration) -> BrowserWebView {
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        WKPreferencesSetAllowsPictureInPictureMediaPlayback(configuration.preferences, true)
        if configuration.urlSchemeHandler(forURLScheme: ErrorPage.scheme) == nil {
            configuration.setURLSchemeHandler(ErrorSchemeHandler(), forURLScheme: ErrorPage.scheme)
        }
        if configuration.urlSchemeHandler(forURLScheme: InternalPage.scheme) == nil {
            configuration.setURLSchemeHandler(InternalPageSchemeHandler(), forURLScheme: InternalPage.scheme)
        }
        InternalPageBridge.install(on: configuration)
        FaviconLinkBridge.install(on: configuration)
        let webView = BrowserWebView(frame: .zero, configuration: configuration)
        webView.isInspectable = true
        return webView
    }

    init(id: UUID = UUID(), configuration: WKWebViewConfiguration = WKWebViewConfiguration()) {
        self.id = id
        self.webView = Self.makeWebView(configuration: configuration)
        super.init()
        if let webView {
            ExtensionPageHostRegistry.register(webView)
            FaviconLinkBridge.register(webView, for: self)
        }
        webView?.navigationDelegate = self
        applyUserAgent()
        setupObservers()
        NotificationCenter.default.addObserver(self, selector: #selector(userAgentDidChange(_:)), name: .init("UserAgentDidChange"), object: nil)
    }

    /// Creates a tab that adopts an existing, already-loaded WKWebView.
    init(id: UUID = UUID(), webView: WKWebView) {
        self.id = id
        self.webView = webView
        super.init()
        ExtensionPageHostRegistry.register(webView)
        FaviconLinkBridge.register(webView, for: self)
        webView.navigationDelegate = self
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
        if let page = url.flatMap(InternalPage.init(url:)) {
            // A restored internal page has no favicon URL to download, and its
            // icon must be there while the tab is still asleep (TASK-86).
            applyInternalPageIcon(page)
        } else if let faviconURL {
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
        } else if let fallbackURL, InternalPage(url: fallbackURL) != nil {
            // Rebuilding a tab that *was* showing an internal page — Reopen
            // Closed Tab, Undo Delete Space, a dormant pinned entry or
            // favourite going live — arms it, exactly as `wake()` does. Plain
            // `load(_:)` would refuse the scheme and leave the tab blank with
            // no way back (TASK-86). The URL can only be internal because an
            // armed load put it there in the first place: nothing else ever
            // commits one.
            loadRecordedURL(fallbackURL)
        } else if let fallbackURL {
            load(fallbackURL)
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
                if url != nil { self.awaitingFirstURL = false }
                if let url, !InternalPage.isInternal(url) {
                    self.armedInternalPage = nil
                } else if let page = url.flatMap(InternalPage.init(url:)) {
                    self.applyInternalPageIcon(page)
                }
                // A session restore that fails before committing leaves the web
                // view on about:blank; that is not a page this tab is showing,
                // and must not become its URL or its retry target (TASK-45).
                let blankAfterFailedRestore = self.restoringSession && url == Self.blankURL
                if let url, !self.navigationPending, url.scheme != ErrorPage.scheme, !blankAfterFailedRestore {
                    self.lastAttemptedURL = url
                }
                if url?.scheme == ErrorPage.scheme { return }
                // A freshly woken web view emits nil before it has loaded anything —
                // keep the restored/pending URL (TASK-45).
                if url == nil, self.awaitingFirstURL { return }
                // After cancellation, webView URL reverts to nil — keep showing the attempted URL.
                if url == nil, self.lastAttemptedURL != nil { return }
                if blankAfterFailedRestore { return }
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
                self.downloadFavicon(from: optimisticURL, generation: generation, optimistic: true)
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
        let js = "document.querySelector(\"\(FaviconLinkBridge.iconLinkSelector)\")?.href"
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self, self.faviconGeneration == generation else { return }
            if let urlString = result as? String,
               let url = URL(string: urlString),
               url != self.faviconURL {
                self.downloadFavicon(from: url, generation: generation)
            }
        }
    }

    /// A `<link rel=icon>` the page's document reported through
    /// `FaviconLinkBridge` — while it is still loading, which for a hidden
    /// background tab can be until it is first shown (TASK-112). Ignored unless
    /// it comes from the page the tab is showing now: a report still in flight
    /// from the document being left must not land on the next page's row.
    /// Downloads under the current generation, so a navigation that changes
    /// host after this drops the result like any other stale download.
    func pageDidReportFaviconLink(_ url: URL, originHost: String) {
        guard let pageURL = webView?.url, let host = pageURL.host,
              host.caseInsensitiveCompare(originHost) == .orderedSame,
              pageURL.scheme != ErrorPage.scheme, !InternalPage.isInternal(pageURL),
              url != faviconURL else { return }
        downloadFavicon(from: url, generation: faviconGeneration)
    }

    /// Gives the tab an internal page's SF Symbol instead of a favicon, and
    /// stops any download still in flight for the page it replaced from landing
    /// on top of it (TASK-86). Called wherever a `detour://` URL becomes the
    /// tab's: an armed load, and a URL that committed by itself (a reload, or
    /// back/forward from a page the user had navigated on to).
    private func applyInternalPageIcon(_ page: InternalPage) {
        // Every `replaceState` of the page's `?q=` reports a new URL.
        guard previousHost != page.url.host || favicon == nil else { return }
        faviconGeneration += 1
        faviconURL = nil
        previousHost = page.url.host
        favicon = NSImage(systemSymbolName: page.symbolName, accessibilityDescription: page.title)
    }

    private func downloadFavicon(from url: URL, generation: Int, optimistic: Bool = false) {
        FaviconLoader.shared.load(from: url) { [weak self] image in
            guard let self, self.faviconGeneration == generation, let image else { return }
            if optimistic {
                guard self.declaredFaviconGeneration != generation else { return }
            } else {
                self.declaredFaviconGeneration = generation
            }
            self.faviconURL = url
            self.favicon = image
        }
    }

    /// Used when closing a tab to immediately stop media and release the webview.
    func teardown() {
        peekTab?.teardown()
        peekTab = nil
        // The close point for every kind of tab (TASK-50). Teardown is the last
        // moment the web view still exists, and it is what every off-list path
        // calls — deactivateFavorite, removeFavorite, the favourite half of a
        // profile swap (its space tabs sleep instead and are closed in
        // `updateSpace`), the peek close paths — none of which produce a
        // TabStore remove notification.
        // No-op (and idempotent) when the tab was never reported open.
        ExtensionTabLifecycle.didClose(self)
        webView?.pauseAllMediaPlayback(completionHandler: nil)
        releaseWebView()
    }

    /// Tears down observers, removes the webView and its container from the
    /// view hierarchy, and nils out both references. Shared by `teardown()`
    /// and `sleep()`.
    private func releaseWebView() {
        guard let webView else { return }
        webView.removeObserver(self, forKeyPath: "_isPlayingAudio")
        // The KVO observer above is the only writer of `isPlayingAudio`, and it
        // dispatches async — so a forced release mid-playback would otherwise pin
        // the flag true on a tab with no web view (sticky sidebar indicator, and
        // `sleepStaleTabs` would never auto-sleep the tab again).
        isPlayingAudio = false
        // Scoped to the web view being released: a stale flag would make the
        // *next* web view's cancellation look like a wake (TASK-45).
        awaitingFirstURL = false
        restoringSession = false
        faviconCancellables.removeAll()
        webView.removeFromSuperview()
        webViewContainer?.removeFromSuperview()
        webViewContainer = nil
        self.webView = nil
    }

    /// A window just hosted this tab's web view — the pane was attached, or an
    /// occluded window carrying it came back on screen (TASK-104). Only
    /// meaningful while `webView != nil`; the count is reset by the next wake.
    func noteShown() {
        showsSinceWake += 1
    }

    /// Whether this tab is showing a page from the `webkit-extension://<host>/`
    /// origin. A live web view has already moved on when `url` has not (the
    /// published property only follows it through a KVO publisher), so the web
    /// view is preferred while one is attached; `url` covers a sleeping tab, or
    /// one whose web view another window owns.
    func showsExtensionPage(ofOriginHost host: String) -> Bool {
        guard let url = webView?.url ?? url else { return false }
        return isExtensionPage(url, ofOriginHost: host)
    }

    // MARK: - Sleep / Wake

    /// `force` sleeps the tab even while it is playing audio (pausing the media
    /// first). Used when the tab must release its webView regardless of playback,
    /// e.g. a profile swap rebinding the tab to a different data store.
    func sleep(force: Bool = false) {
        guard let webView, !isSleeping, force || !isPlayingAudio else { return }
        if force {
            webView.pauseAllMediaPlayback(completionHandler: nil)
        }

        parkPeek(force: force)

        if let state = webView.interactionState {
            cachedInteractionState = try? NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: false)
        }

        releaseWebView()

        isSleeping = true
        isLoading = false
        estimatedProgress = 0
        canGoBack = false
        canGoForward = false
    }

    /// Parks this tab's peek — saves its state, sleeps it, and closes it to the
    /// extension contexts (TASK-57).
    ///
    /// The state has to be captured *before* the sleep, or a later save restores
    /// the peek to its open-time URL.
    ///
    /// A parked peek's sleep is a close as far as the contexts are concerned: it
    /// is never woken as the same object — `showPeekOverlay` builds a *new*
    /// `BrowserTab` and tears the parked one down — so leaving it registered
    /// would be a phantom open tab with no web view. The host keeps its
    /// `peekTab` reference regardless: the badge reads it through
    /// `displayPeekFavicon`.
    ///
    /// The close is gated on the peek having actually released its web view: a
    /// non-forced sleep spares an audible peek, which is still a live, reachable
    /// page the contexts must keep.
    ///
    /// Idempotent, and callable on a host that has no web view of its own:
    /// `sleep` parks the peek only while releasing the host's web view, so a
    /// path that must not leave a peek live behind a sleeping host (a move
    /// across profiles, `TabStore.carry`) parks it directly.
    func parkPeek(force: Bool) {
        guard let peek = peekTab else { return }
        savePeekStateForPersistence()
        peek.sleep(force: force)
        if peek.webView == nil {
            ExtensionTabLifecycle.didClose(peek)
        }
    }

    /// Rehomes the tab onto `url`, discarding the page it is currently showing.
    ///
    /// Used when a tab's origin dies under it: a reloaded `WKWebExtensionContext`
    /// gets a fresh `webkit-extension://<UUID>/` base URL, so the open page's
    /// native bindings are gone and only a load from the new origin revives it.
    ///
    /// Unlike `sleep(force:)` this *discards* `cachedInteractionState` — restoring
    /// it would put the tab straight back on the dead URL — and unlike `load` it
    /// does not navigate the existing web view: that view was built from the old
    /// context's configuration and cannot load the new origin at all. The tab is
    /// left sleeping so the display path (`claimWebView` → `wakeIfNeeded` →
    /// `wake`) rebuilds it against the new origin's configuration, which is also
    /// what makes this correct for a tab whose web view is owned by another
    /// window (or by none).
    func retarget(to url: URL) {
        webView?.pauseAllMediaPlayback(completionHandler: nil)
        parkPeek(force: true)
        releaseWebView()
        cachedInteractionState = nil

        isSleeping = true
        isLoading = false
        estimatedProgress = 0
        canGoBack = false
        canGoForward = false
        navigationPending = false

        self.url = url
        lastAttemptedURL = url
        // Title and favicon are deliberately kept, unlike `load`: this is the
        // *same page* coming back from a new internal origin, not a navigation to
        // somewhere else, so replacing them would flash a raw
        // `webkit-extension://<uuid>/…` title and drop an icon that is still
        // right. Adopting the new host also keeps the host-change observer in
        // `setupObservers` from clearing them when the page loads — which matters,
        // because an extension page's icon lives at an extension URL and could
        // not be fetched again.
        previousHost = url.host
    }

    /// - Parameter supersededByLoad: the caller loads another URL right away,
    ///   so a plain load of the tab's own URL is skipped. Arming is single-use
    ///   (`authorizesNavigation`): were both loads armed, whichever policy
    ///   decision came first would spend it and the other be refused.
    func wake(supersededByLoad: Bool = false) {
        guard webView == nil else { return }

        let space = spaceID.flatMap { TabStore.shared.space(withID: $0) }
        self.webView = Self.makeWebView(configuration: wakeConfiguration(in: space))
        webView?.navigationDelegate = self
        // A fresh web view means a fresh WebContent process and a fresh slice of
        // the GPU process's IOSurface pool: the show budget starts over (TASK-104).
        showsSinceWake = 0

        // The URL observer installed below replaces `url` with the fresh web
        // view's nil URL on its very first emission, which would lose:
        //
        //  - an extension page on a pending origin — restored from the previous
        //    launch before its extension's context loaded (TASK-24) — which is
        //    left unloaded below because its origin is dead, and which
        //    `Profile.resolvePendingExtensionPages` finds again *by `url`*;
        //  - the URL of a tab that has never had a web view — one created
        //    sleeping, like an extension page from `TabStore.makeTab(loading:)`
        //    (TASK-28) — before the load below reads it.
        //
        // `awaitingFirstURL` makes the observer ignore that nil until the web
        // view reports a real URL. It replaces seeding `lastAttemptedURL` here,
        // which also told `didFailProvisionalNavigation` that the user asked for
        // this navigation — so a restored tab whose wake failed offline got an
        // error page over its just-restored session (TASK-45).
        awaitingFirstURL = true
        let awaitingExtensionContext = space?.profile?.isAwaitingExtensionContext(url) == true
        let restoredState = awaitingExtensionContext
            ? nil : cachedInteractionState.flatMap(Self.unarchiveInteractionState)
        // Decided before the observers below run `updateTitle()` on their first
        // emission: while a session is being restored the persisted title stays.
        restoringSession = restoredState != nil

        applyUserAgent()
        setupObservers()

        if awaitingExtensionContext {
            // Nothing to load until the context does.
        } else if let restoredState {
            // An internal page among the restored entries needs no arming:
            // the policy admits it as a revisit of a session entry.
            webView?.interactionState = restoredState
        } else if let url, !supersededByLoad {
            // `url` is only ever internal because an armed load committed it:
            // `load(_:)` refuses the scheme and the policy cancels the rest.
            armedInternalPage = InternalPage(url: url)
            webView?.load(URLRequest(url: url))
        }

        isSleeping = false
        cachedInteractionState = nil

        // Notify extension contexts that this tab is now available.
        // WKWebExtension needs didOpenTab to associate the *new* webView with
        // this tab for content script messaging, so a placed tab is re-reported
        // on every wake. The profile comes from the configuration the web view
        // was actually built from, which for an extension page is the context's,
        // not the space's (TASK-52).
        ExtensionTabLifecycle.didCreateWebView(for: self)
    }

    /// The configuration a fresh web view for this tab must be built from.
    ///
    /// A `webkit-extension://` page can only load in the configuration of the
    /// context that serves its origin — the space's own configuration has no
    /// handler for the scheme, which is why `TabStore.addExtensionTab` takes the
    /// context's configuration in the first place. So an extension tab is woken
    /// from its owning context's configuration, resolved by *origin host* because
    /// WebKit gives every loaded context a fresh base URL.
    ///
    /// Falls back to the space's configuration when no loaded context claims the
    /// origin (the extension was disabled or uninstalled, or this is a page
    /// restored from the previous launch whose context has not loaded yet — see
    /// `Profile.pendingExtensionOrigins`): the tab still gets a web view rather
    /// than crashing the wake.
    private func wakeConfiguration(in space: Space?) -> WKWebViewConfiguration {
        if let url, let host = url.host,
           url.scheme?.caseInsensitiveCompare(ExtensionPageURL.scheme) == .orderedSame,
           let profile = space?.profile,
           let extensionID = profile.extensionID(forOriginScheme: ExtensionPageURL.scheme, host: host),
           let extensionConfig = profile.extensionContext(for: extensionID)?.webViewConfiguration {
            return extensionConfig
        }
        return space?.makeWebViewConfiguration() ?? WKWebViewConfiguration()
    }

    /// Records a web content process termination and returns how many have hit
    /// this tab in quick succession. Terminations more than 30s apart count as
    /// fresh incidents (an occasional crash always earns an auto-reload); a
    /// rapid streak means the page itself kills its process, and the caller
    /// should stop reload-looping it.
    func noteProcessTermination() -> Int {
        let now = Date()
        if let last = lastProcessTerminationAt, now.timeIntervalSince(last) < 30 {
            processTerminationCount += 1
        } else {
            processTerminationCount = 1
        }
        lastProcessTerminationAt = now
        return processTerminationCount
    }

    /// Returns whether the pending navigation was user-typed, resetting the flag.
    func consumeNextVisitIsTyped() -> Bool {
        defer { nextVisitIsTyped = false }
        return nextVisitIsTyped
    }

    func currentInteractionStateData() -> Data? {
        if let webView, let state = webView.interactionState {
            return try? NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: false)
        }
        return cachedInteractionState
    }

    /// Starts the tab's own URL in a woken web view that never began loading —
    /// `claimWebView`'s safety net for a restore that did not navigate, or a web
    /// content process that died while unparented. Unlike `load(_:)` this is not
    /// a navigation the user asked for: it leaves `lastAttemptedURL`,
    /// `navigationPending`, title and favicon alone, so a restored session whose
    /// kick fails offline is kept rather than replaced by an error page (TASK-45).
    func loadIfStalled() {
        guard let webView, webView.url == nil, !webView.isLoading, let url else { return }
        webView.load(URLRequest(url: url))
    }

    /// Applies `InternalPageNavigationPolicy` for this tab, for whichever
    /// navigation delegate the web view has. Arming is single-use, spent by the
    /// navigation it lets through: left armed for as long as the page is
    /// showing, the tab would wave through a redirect back to the internal
    /// scheme from the first history entry the user clicked. (An arming whose
    /// load never reaches the policy is dropped by the URL observer once a web
    /// page commits.)
    func authorizesNavigation(_ action: WKNavigationAction, in webView: WKWebView) -> Bool {
        let decision = InternalPageNavigationPolicy.decision(
            for: action.request.url, targetsMainFrame: action.targetFrame?.isMainFrame == true,
            navigationType: action.navigationType, armedPage: armedInternalPage,
            sessionEntryURLs: InternalPageNavigationPolicy.sessionEntryURLs(of: webView))
        if decision == .allowedByArming { armedInternalPage = nil }
        return decision.allows
    }

    /// Navigates to a page Detour serves itself. The only way in: `load(_:)`
    /// refuses the internal scheme, because its callers include web content and
    /// extensions.
    func loadInternalPage(_ page: InternalPage) {
        load(page.url, arming: page)
        // After the load, which clears the favicon of the page being left.
        applyInternalPageIcon(page)
    }

    func load(_ url: URL, typed: Bool = false) {
        load(url, typed: typed, arming: nil)
    }

    /// Returns the tab to a URL Detour itself recorded from a committed
    /// navigation — this tab's own `url`/`lastAttemptedURL`, or the stored URL
    /// of the favourite, pinned entry or closed tab it backs — keeping an
    /// internal page's `?q=` state. Never for a URL that came from anywhere
    /// else (a page, an extension, another app, an error page's query string):
    /// for an internal URL this arms the tab.
    func loadRecordedURL(_ url: URL) {
        load(url, arming: InternalPage(url: url))
    }

    private func load(_ url: URL, typed: Bool = false, arming page: InternalPage?) {
        guard page != nil || !InternalPage.isInternal(url) else { return }
        nextVisitIsTyped = typed
        if isSleeping { wake(supersededByLoad: true) }
        armedInternalPage = page
        // The user (or a caller acting for them) asked for this page: it
        // replaces whatever session was being restored, and a failure now earns
        // the error page.
        restoringSession = false
        lastAttemptedURL = url
        self.url = url
        resetBlockedCount()
        navigationPending = true
        applySpoofedUserAgent(for: url)
        if url.host != previousHost {
            favicon = nil
            faviconURL = nil
        }
        // Optimistic favicon fetch for programmatic navigations
        if let host = url.host, let scheme = url.scheme, scheme != ErrorPage.scheme, page == nil {
            if host != previousHost {
                faviconGeneration += 1
                let generation = faviconGeneration
                previousHost = host
                let optimisticURL = URL(string: "\(scheme)://\(host)/favicon.ico")!
                downloadFavicon(from: optimisticURL, generation: generation, optimistic: true)
            } else {
                previousHost = host
            }
        }
        updateTitle()
        webView?.load(URLRequest(url: url))
    }

    func reload() {
        if isSleeping { wake() }
        // The user asked for this page again: a failure from here on earns the
        // error page even if the session restore never committed (TASK-45).
        restoringSession = false
        if webView?.url?.scheme == ErrorPage.scheme {
            // The error page's own query string is not a recorded URL: a web
            // page can navigate to an error URL naming any `failedURL`.
            if let lastAttemptedURL {
                loadRecordedURL(lastAttemptedURL)
            } else if let retryURL = webView?.url.flatMap({ ErrorPage.originalURL(from: $0) }) {
                load(retryURL)
            }
        } else if webViewShowsNothing, let retryURL = lastAttemptedURL ?? url {
            // `url` is the fallback for a restored tab whose wake never
            // committed a navigation — nothing was "attempted" then (TASK-45),
            // but the user asking to reload must still retry the page.
            loadRecordedURL(retryURL)
        } else {
            webView?.reload()
        }
    }

    func didCommitNavigation() {
        // A session restore that fails falls back to about:blank, and WebKit
        // commits that: it is not a page the tab is showing, so the restored
        // session, title and pending state stay (TASK-45, the URL observer's
        // `blankAfterFailedRestore`). A session restored *onto* about:blank
        // (`window.open('')`, `tabs.create({url: 'about:blank'})`) is the one
        // exception: its commit is the restore succeeding.
        if restoringSession, webView?.url == Self.blankURL, url != Self.blankURL { return }
        navigationPending = false
        restoringSession = false
        resetBlockedCount()
        updateTitle()
    }

    /// Counts a load a content rule list blocked — once per resource, however
    /// many lists acted on it (TASK-69).
    func recordBlockedLoad(of url: URL) {
        guard blockedURLs.insert(url).inserted else { return }
        blockedCount += 1
    }

    private func resetBlockedCount() {
        blockedURLs.removeAll()
        blockedCount = 0
    }

    func didFailProvisionalNavigation(error: Error) {
        // The restore of a cached session dying before it commits is not a
        // failed request of the user's: keep the session, title and favicon
        // (TASK-45). `reload()` goes through `load(_:)`, so retrying it still
        // shows the error page on failure.
        guard !restoringSession, let lastAttemptedURL else { return }
        showErrorPage(for: lastAttemptedURL, error: error)
    }

    func didFailNavigation(error: Error) {
        guard let failedURL = webView?.url ?? lastAttemptedURL else { return }
        showErrorPage(for: failedURL, error: error)
    }

    private func showErrorPage(for failedURL: URL, error: Error) {
        url = failedURL
        favicon = nil
        faviconURL = nil
        faviconGeneration += 1
        previousHost = nil
        webView?.load(URLRequest(url: ErrorPage.url(for: failedURL, error: error)))
    }

    private func updateTitle() {
        // An internal page is named before it loads (TASK-86): without this the
        // sidebar would show the raw `detour://history/` for as long as the
        // navigation is pending, and again for a restored tab that has not
        // woken and so has no document title to read.
        if let page = ((navigationPending ? lastAttemptedURL : webView?.url) ?? url)
            .flatMap(InternalPage.init(url:)) {
            title = page.title
        } else if navigationPending, let lastAttemptedURL {
            title = strippedScheme(lastAttemptedURL)
        } else if let webTitle = webView?.title, !webTitle.isEmpty {
            title = webTitle
        } else if restoringSession {
            // The persisted title outranks the raw URL of a session still being
            // restored; a commit clears the flag and re-derives it (TASK-45).
        } else if let displayURL = webView?.url ?? lastAttemptedURL ?? url {
            // `url` is the fallback for a woken web view that has nothing to
            // report — an extension page waiting for its context — now that
            // `wake()` no longer seeds `lastAttemptedURL` (TASK-45).
            title = strippedScheme(displayURL)
        } else if !isSleeping {
            title = "New Tab"
        }
    }

    var displayHost: String {
        // `detour://history/` has a host, but "history" is not what the faux
        // address bar should read: an internal page goes by its name (TASK-86).
        if let page = url.flatMap(InternalPage.init(url:)) { return page.title }
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

// MARK: - Unclaimed web views

/// The navigation delegate of a web view no window has claimed yet. A tab
/// opened in the background — Cmd+click, "Open in New Tab", an extension's
/// `tabs.create({active: false})` — loads before any window installs itself as
/// delegate (`wireOwnedWebView` does that on claim), and with none WebKit uses
/// the configuration's default preferences: the per-site content blocker
/// switch would never be consulted for that page (TASK-69). Besides the policy
/// decision that carries the preferences, only the tab's own bookkeeping is
/// implemented — what the window forwards once it owns the web view. The
/// commit: without it a background load that stalls (hidden web views can stay
/// loading until first shown) kept the URL as its title until the load
/// finished (TASK-114). The two failures: without them a failing background
/// load never showed the error page (TASK-122). Every other callback stays at
/// WebKit's default, exactly as with no delegate; a window replaces this the
/// moment it claims the tab.
extension BrowserTab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        guard authorizesNavigation(navigationAction, in: webView) else { return (.cancel, preferences) }
        if navigationAction.targetFrame?.isMainFrame == true, let profile = owningProfile {
            ContentBlockerManager.shared.configure(preferences,
                                                   forNavigationTo: navigationAction.request.url,
                                                   profile: profile)
        }
        return (.allow, preferences)
    }

    /// Mirrors `BrowserWindowController`'s `didCommit`: an error page is not a
    /// page the tab is showing.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if webView.url?.scheme == ErrorPage.scheme { return }
        didCommitNavigation()
    }

    /// Mirrors `BrowserWindowController`'s failure handlers: a failing
    /// background load otherwise never shows the error page, and selecting the
    /// tab later does not surface it (TASK-122).
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        guard !error.isIgnoredNavigationError else { return }
        didFailProvisionalNavigation(error: error)
    }

    /// See `webView(_:didFailProvisionalNavigation:withError:)`.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !error.isIgnoredNavigationError else { return }
        didFailNavigation(error: error)
    }
}

