import Foundation
import WebKit

/// Records what pages log and load while the automation endpoint is on
/// (TASK-228.4), for `console_messages` and `network_requests`.
///
/// A user script in the page world, at document start in every frame, wraps
/// `console.*`, listens for uncaught errors and unhandled rejections,
/// observes Resource Timing (the navigation and every resource) and wraps
/// `fetch` and `XMLHttpRequest` for method, status and failures. It posts
/// each record to a script message handler; the tab comes from
/// `message.webView`, and each tab keeps a bounded ring buffer per kind.
///
/// Installed only while the endpoint is listening (`AutomationController`
/// starts and stops it), and never into a Private profile's web views: new
/// web views get it from `Space.makeUserContentController(for:)`, live ones
/// when capture starts, with the script run once in pages already loaded
/// (main frame only: their subframes are captured from their next load).
/// Stopping removes the script and the handler; a page that already ran the
/// script keeps its wrappers until it reloads, posting to a handler that is
/// gone (each post is in a try/catch, so the page never sees it fail).
///
/// The wrappers can be noticed by a page (`console.log.toString()`, the
/// handler under `window.webkit.messageHandlers`), and a page can post
/// records of its own: accepted while automation is on (TASK-228.4).
final class AutomationPageCapture: NSObject, WKScriptMessageHandler {

    static let shared = AutomationPageCapture()

    static let handlerName = "detourAutomationCapture"
    /// Entries a tab keeps per kind; older ones are dropped (`dropped` in the
    /// tools' results says how many a cursor missed).
    static let capacity = 1000
    /// Longest text a record keeps (a message, a stack, a URL).
    static let maximumTextLength = 8000

    /// Whether the endpoint is listening, so pages are being recorded.
    private(set) var isActive = false
    private var store: TabStore?
    /// The controllers the script and handler were added to, so stopping
    /// removes them again.
    private let installed = NSHashTable<WKUserContentController>.weakObjects()
    /// Web view to tab, filled on a tab's first message.
    private let tabsByWebView = NSMapTable<WKWebView, BrowserTab>.weakToWeakObjects()
    private var buffers: [UUID: TabBuffers] = [:]
    private var lastPrune = Date.distantPast

    struct TabBuffers {
        var console = AutomationRingBuffer(capacity: AutomationPageCapture.capacity)
        var network = AutomationRingBuffer(capacity: AutomationPageCapture.capacity)
    }

    // MARK: Starting and stopping

    /// Starts recording: the script goes into every live, reachable tab's
    /// web view (and runs once in its page), and into every web view made
    /// from now on.
    func start(store: TabStore) {
        self.store = store
        guard !isActive else { return }
        isActive = true
        for tab in Self.reachableTabs(in: store) {
            guard let webView = tab.webView else { continue }
            install(on: webView.configuration.userContentController)
            // A page loaded before the endpoint started: run the script once.
            // Its guard makes this harmless where the user script already ran.
            webView.evaluateJavaScript(Self.captureScript, in: nil, in: .page) { _ in }
        }
    }

    /// Stops recording: removes the script and the handler everywhere and
    /// forgets every tab's records.
    func stop() {
        guard isActive else { return }
        isActive = false
        for controller in installed.allObjects {
            let others = controller.userScripts.filter { $0.source != Self.captureScript }
            controller.removeAllUserScripts()
            for script in others { controller.addUserScript(script) }
            controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: .page)
        }
        installed.removeAllObjects()
        buffers.removeAll()
        tabsByWebView.removeAllObjects()
    }

    /// Adds the script and the handler to a new web view's controller while
    /// recording. The caller has already left out Private profiles.
    func installIfActive(on controller: WKUserContentController) {
        guard isActive else { return }
        install(on: controller)
    }

    private func install(on controller: WKUserContentController) {
        // Registering a handler name twice in one world raises; extension
        // pages share one configuration between tabs.
        guard !installed.contains(controller),
              !controller.userScripts.contains(where: { $0.source == Self.captureScript }) else { return }
        controller.add(self, contentWorld: .page, name: Self.handlerName)
        controller.addUserScript(WKUserScript(source: Self.captureScript, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: .page))
        installed.add(controller)
    }

    /// Whether `controller` has the capture script (tests).
    static func isInstalled(on controller: WKUserContentController) -> Bool {
        controller.userScripts.contains { $0.source == captureScript }
    }

    // MARK: Tabs

    /// The tabs automation may reach: those of non-Private spaces (normal
    /// and pinned) and the favorites of non-Private profiles.
    static func reachableTabs(in store: TabStore) -> [BrowserTab] {
        store.spaces.filter { !$0.isIncognito }.flatMap { $0.tabs + $0.pinnedTabs }
            + store.profiles.filter { !$0.isIncognito }.flatMap(\.favoriteTabs)
    }

    private func tab(for webView: WKWebView) -> BrowserTab? {
        if let cached = tabsByWebView.object(forKey: webView), cached.webView === webView { return cached }
        guard let store, let tab = Self.reachableTabs(in: store).first(where: { $0.webView === webView }) else {
            return nil
        }
        tabsByWebView.setObject(tab, forKey: webView)
        return tab
    }

    /// Forgets the records of tabs that have closed. At most every few
    /// seconds, from incoming records and reads.
    private func pruneClosedTabs(now: Date = Date()) {
        guard now.timeIntervalSince(lastPrune) > 5, let store else { return }
        lastPrune = now
        let live = Set(Self.reachableTabs(in: store).map(\.id))
        buffers = buffers.filter { live.contains($0.key) }
    }

    // MARK: Reading

    /// A tab's console records after `seq`.
    func console(for tabID: UUID) -> AutomationRingBuffer? {
        pruneClosedTabs()
        return buffers[tabID]?.console
    }

    func network(for tabID: UUID) -> AutomationRingBuffer? {
        pruneClosedTabs()
        return buffers[tabID]?.network
    }

    // MARK: Messages

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard isActive, let webView = message.webView, let tab = tab(for: webView),
              let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        let frame = message.frameInfo
        var fields: [String: JSONValue] = [
            "frame_url": .nullable(frame.request.url?.absoluteString),
            "main_frame": .bool(frame.isMainFrame),
        ]
        let category: String
        switch kind {
        case "console":
            let level = Self.pick(body["level"], from: Self.consoleLevels, else: "log")
            let source = Self.pick(body["source"], from: Self.consoleSources, else: "console")
            category = level
            fields["level"] = .string(level)
            fields["source"] = .string(source)
            fields["text"] = .string(Self.text(body["text"]) ?? "")
            fields["stack"] = .nullable(Self.text(body["stack"]))
            fields["source_url"] = .nullable(Self.text(body["source_url"]))
            fields["line"] = Self.number(body["line"])
            fields["column"] = Self.number(body["column"])
        case "network":
            let source = Self.pick(body["source"], from: Self.networkSources, else: "resource")
            category = source
            fields["source"] = .string(source)
            fields["url"] = .string(Self.text(body["url"]) ?? "")
            fields["method"] = .nullable(Self.text(body["method"]))
            fields["status"] = Self.number(body["status"])
            fields["ok"] = (body["ok"] as? Bool).map(JSONValue.bool) ?? .null
            fields["error"] = .nullable(Self.text(body["error"]))
            fields["initiator_type"] = .nullable(Self.text(body["initiator_type"]))
            fields["protocol"] = .nullable(Self.text(body["protocol"]))
            for key in ["start_ms", "duration_ms", "transfer_size", "encoded_size", "decoded_size"] {
                fields[key] = Self.number(body[key])
            }
        default:
            return
        }
        fields["timestamp"] = Self.number(body["timestamp"])
        pruneClosedTabs()
        var tabBuffers = buffers[tab.id] ?? TabBuffers()
        if kind == "console" {
            tabBuffers.console.append(category: category, fields: fields)
        } else {
            tabBuffers.network.append(category: category, fields: fields)
        }
        buffers[tab.id] = tabBuffers
    }

    static let consoleLevels: Set<String> = ["log", "info", "warn", "error", "debug"]
    static let consoleSources: Set<String> = ["console", "uncaught", "unhandledrejection"]
    static let networkSources: Set<String> = ["navigation", "resource", "fetch", "xhr"]

    private static func pick(_ value: Any?, from allowed: Set<String>, else fallback: String) -> String {
        guard let string = value as? String, allowed.contains(string) else { return fallback }
        return string
    }

    /// A string field, cut to `maximumTextLength`: the page sends what it
    /// likes, so nothing it sends is kept unbounded.
    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        return string.count > maximumTextLength ? String(string.prefix(maximumTextLength)) + "…" : string
    }

    private static func number(_ value: Any?) -> JSONValue {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return .null }
        let double = number.doubleValue
        guard double.isFinite else { return .null }
        if double.rounded() == double, abs(double) < 9.0e15 { return .int(Int(double)) }
        return .double((double * 10).rounded() / 10)
    }

    // MARK: The script

    /// The page-world script. `let`/`const` only; every hook is in a
    /// try/catch, and the wrapped console still calls the original, so a
    /// page behaves as it did. Run twice (the user script and the one-off
    /// evaluation for a page loaded before capture started), it installs once.
    static let captureScript = """
        (() => {
          const key = Symbol.for('detour.automation.capture');
          try {
            if (window[key]) return;
            Object.defineProperty(window, key, { value: true });
          } catch (error) { return; }
          const limit = \(maximumTextLength);
          const cut = (text) => {
            const string = String(text);
            return string.length > limit ? string.slice(0, limit) + '\\u2026' : string;
          };
          const post = (record) => {
            try { window.webkit.messageHandlers.\(handlerName).postMessage(record); } catch (error) {}
          };
          const round = (value) => typeof value === 'number' && Number.isFinite(value) ? Math.round(value * 10) / 10 : null;
          const describe = (value) => {
            try {
              if (typeof value === 'string') return value;
              if (value === undefined) return 'undefined';
              if (value === null) return 'null';
              if (value instanceof Error) return String(value.name) + ': ' + String(value.message);
              if (typeof Node === 'function' && value instanceof Node) {
                if (value.nodeType !== 1) return value.nodeName;
                let text = '<' + value.localName;
                if (value.id) text += '#' + value.id;
                if (value.classList && value.classList.length) text += '.' + Array.from(value.classList).join('.');
                return text + '>';
              }
              if (typeof value === 'function') return '[Function' + (value.name ? ' ' + value.name : '') + ']';
              if (typeof value === 'object') {
                const seen = new WeakSet();
                const json = JSON.stringify(value, (name, item) => {
                  if (typeof item === 'bigint') return item.toString() + 'n';
                  if (typeof item === 'object' && item !== null) {
                    if (typeof Node === 'function' && item instanceof Node) return describe(item);
                    if (seen.has(item)) return '[Circular]';
                    seen.add(item);
                  }
                  return item;
                });
                if (json !== undefined) return json;
              }
              return String(value);
            } catch (error) {
              try { return Object.prototype.toString.call(value); } catch (inner) { return '[Unreadable]'; }
            }
          };
          const stackOf = (value) => {
            try { return value && value.stack ? cut(value.stack) : null; } catch (error) { return null; }
          };

          for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
            try {
              const original = console[level];
              if (typeof original !== 'function') continue;
              console[level] = function (...args) {
                try {
                  post({ kind: 'console', level, source: 'console', text: cut(args.map(describe).join(' ')),
                         timestamp: Date.now() });
                } catch (error) {}
                return original.apply(console, args);
              };
            } catch (error) {}
          }

          try {
            window.addEventListener('error', (event) => {
              try {
                if (typeof ErrorEvent === 'function' && !(event instanceof ErrorEvent)) return;
                post({ kind: 'console', level: 'error', source: 'uncaught',
                       text: cut(event.message || describe(event.error)), stack: stackOf(event.error),
                       source_url: event.filename ? cut(event.filename) : null,
                       line: event.lineno || null, column: event.colno || null, timestamp: Date.now() });
              } catch (error) {}
            });
            window.addEventListener('unhandledrejection', (event) => {
              try {
                post({ kind: 'console', level: 'error', source: 'unhandledrejection',
                       text: cut('Unhandled promise rejection: ' + describe(event.reason)),
                       stack: stackOf(event.reason), timestamp: Date.now() });
              } catch (error) {}
            });
          } catch (error) {}

          const timing = (entry) => {
            const status = typeof entry.responseStatus === 'number' && entry.responseStatus > 0 ? entry.responseStatus : null;
            return { kind: 'network', source: entry.entryType === 'navigation' ? 'navigation' : 'resource',
                     url: cut(entry.name), initiator_type: entry.initiatorType || null, status,
                     start_ms: round(entry.startTime), duration_ms: round(entry.duration),
                     transfer_size: round(entry.transferSize), encoded_size: round(entry.encodedBodySize),
                     decoded_size: round(entry.decodedBodySize), protocol: entry.nextHopProtocol || null,
                     timestamp: Math.round(performance.timeOrigin + entry.startTime) };
          };
          try {
            new PerformanceObserver((list) => {
              try { for (const entry of list.getEntries()) post(timing(entry)); } catch (error) {}
            }).observe({ type: 'resource', buffered: true });
          } catch (error) {}
          // The navigation's entry exists from the start but is complete only
          // after the load event, so it is sent then, once.
          try {
            const navigation = () => {
              setTimeout(() => {
                try {
                  const entry = performance.getEntriesByType('navigation')[0];
                  if (entry) post(timing(entry));
                } catch (error) {}
              }, 0);
            };
            if (document.readyState === 'complete') navigation();
            else window.addEventListener('load', navigation, { once: true });
          } catch (error) {}

          const absolute = (url) => {
            try { return cut(new URL(String(url), location.href).href); } catch (error) { return cut(url); }
          };
          const request = (source, method, url, started, fields) => {
            post(Object.assign({ kind: 'network', source, method, url, start_ms: round(started),
                                 duration_ms: round(performance.now() - started),
                                 timestamp: Math.round(performance.timeOrigin + started) }, fields));
          };
          try {
            const originalFetch = window.fetch;
            if (typeof originalFetch === 'function') {
              window.fetch = function (input, init) {
                const started = performance.now();
                let method = 'GET';
                let url = '';
                try {
                  const isRequest = typeof Request === 'function' && input instanceof Request;
                  method = String((init && init.method) || (isRequest ? input.method : 'GET')).toUpperCase();
                  url = absolute(isRequest ? input.url : input);
                } catch (error) {}
                const promise = originalFetch.apply(this, arguments);
                try {
                  // A promise that settles as the page's would, so a fetch the
                  // page leaves unhandled is still reported to it as unhandled.
                  return promise.then((response) => {
                    try {
                      request('fetch', method, response.url ? cut(response.url) : url, started,
                              { status: response.status, ok: response.ok });
                    } catch (error) {}
                    return response;
                  }, (failure) => {
                    try { request('fetch', method, url, started, { error: cut(describe(failure)) }); } catch (error) {}
                    throw failure;
                  });
                } catch (error) {
                  return promise;
                }
              };
            }
          } catch (error) {}
          try {
            const prototype = window.XMLHttpRequest && window.XMLHttpRequest.prototype;
            if (prototype) {
              const open = prototype.open;
              const send = prototype.send;
              const requests = new WeakMap();
              prototype.open = function (method, url) {
                try { requests.set(this, { method: String(method).toUpperCase(), url: absolute(url) }); } catch (error) {}
                return open.apply(this, arguments);
              };
              prototype.send = function () {
                try {
                  const info = requests.get(this);
                  if (info) {
                    const started = performance.now();
                    const xhr = this;
                    let reported = false;
                    const report = (failure) => {
                      try {
                        if (reported) return;
                        reported = true;
                        const status = xhr.status || null;
                        request('xhr', info.method, info.url, started,
                                failure ? { error: failure, status } : { status, ok: status >= 200 && status < 300 });
                      } catch (error) {}
                    };
                    this.addEventListener('load', () => report(null));
                    this.addEventListener('error', () => report('network error'));
                    this.addEventListener('abort', () => report('aborted'));
                    this.addEventListener('timeout', () => report('timed out'));
                  }
                } catch (error) {}
                return send.apply(this, arguments);
              };
            }
          } catch (error) {}
        })();
        """
}

/// A tab's records of one kind, oldest first, each with an increasing
/// `seq` (TASK-228.4). Bounded: past `capacity` the oldest go.
struct AutomationRingBuffer {

    struct Entry {
        let seq: Int
        /// A console record's level, a network record's source: what the
        /// tools filter on.
        let category: String
        let fields: [String: JSONValue]

        var json: JSONValue {
            var all = fields
            all["seq"] = .int(seq)
            return .object(all)
        }
    }

    let capacity: Int
    /// The kept entries in a ring: `storage[start]` is the oldest once full.
    private var storage: [Entry] = []
    private var start = 0
    /// The newest entry's seq (0 before the first).
    private(set) var lastSeq = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int { storage.count }

    /// The oldest kept entry's seq, or `lastSeq + 1` when there is none.
    var firstSeq: Int { lastSeq - storage.count + 1 }

    mutating func append(category: String, fields: [String: JSONValue]) {
        lastSeq += 1
        let entry = Entry(seq: lastSeq, category: category, fields: fields)
        if storage.count < capacity {
            storage.append(entry)
        } else {
            storage[start] = entry
            start = (start + 1) % capacity
        }
    }

    /// The kept entries, oldest first.
    var entries: [Entry] {
        Array(storage[start...] + storage[..<start])
    }

    /// Entries newer than `seq`, oldest first.
    func entries(after seq: Int) -> [Entry] {
        entries.filter { $0.seq > seq }
    }

    /// How many entries newer than `seq` were dropped before they could be
    /// read.
    func dropped(after seq: Int) -> Int {
        max(0, firstSeq - (seq + 1))
    }
}
