import Foundation

/// The History page's document, stylesheet, favicons and script.
///
/// The document itself runs no script at all (`InternalPageSchemeHandler`'s CSP
/// has no script source); everything below the markup is the page's user
/// script, which runs in `InternalPageBridge.contentWorld`.
enum HistoryPageContent {

    /// Serves one resource of `detour://history/`. The completion may be called
    /// on any queue — the favicon route answers from a background queue.
    static func resource(for url: URL, completion: @escaping (InternalPageResource?) -> Void) {
        switch url.path {
        case "", "/": completion(.text(html, mimeType: "text/html; charset=utf-8"))
        case "/page.css": completion(.text(css, mimeType: "text/css; charset=utf-8"))
        case "/favicon": favicon(for: url, completion: completion)
        default: completion(nil)
        }
    }

    /// `favicon?pageUrl=…&size=…`: the icon of a page in the history, as PNG.
    ///
    /// The page may only name a *page* URL, never an icon URL — the icon that
    /// gets fetched is the one Detour already recorded for that page, so this
    /// route cannot be used to reach an arbitrary host. Unknown pages 404, which
    /// the page renders as a blank placeholder (no image, no second request).
    private static func favicon(for url: URL, completion: @escaping (InternalPageResource?) -> Void) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let pageURL = items.first(where: { $0.name == "pageUrl" })?.value, !pageURL.isEmpty else {
            completion(nil)
            return
        }
        let size = items.first(where: { $0.name == "size" }).flatMap { $0.value.flatMap(Int.init) } ?? 32
        FaviconPNGLoader.shared.pngData(forPageURL: pageURL, resizedTo: size) { data in
            completion(data.map { InternalPageResource(mimeType: "image/png", data: $0) })
        }
    }

    static let html = #"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>History</title>
    <link rel="stylesheet" href="page.css">
    </head>
    <body>
    <header class="bar">
        <div class="bar-inner">
            <h1>History</h1>
            <input id="search" type="search" placeholder="Search History"
                   autocomplete="off" autocorrect="off" spellcheck="false" autofocus>
        </div>
    </header>
    <main class="column">
        <div id="entries"></div>
        <div id="empty" class="empty" hidden></div>
        <div id="sentinel"></div>
    </main>
    </body>
    </html>
    """#

    /// All of the page's styling: the CSP has no `'unsafe-inline'`, so there is
    /// no inline `<style>` block and no element `style` attribute anywhere —
    /// the script toggles classes and the `hidden` property instead.
    ///
    /// Colours follow the error page (`ErrorSchemeHandler`): white on #333,
    /// #1e1e1e on #ccc in the dark.
    static let css = #"""
    :root {
        color-scheme: light dark;
        --bg: #ffffff;
        --fg: #333333;
        --muted: #86868b;
        --hairline: rgba(0, 0, 0, 0.08);
        --hover: rgba(0, 0, 0, 0.05);
        --bar-bg: rgba(255, 255, 255, 0.82);
        --field-bg: rgba(0, 0, 0, 0.05);
        --field-border: rgba(0, 0, 0, 0.1);
        --placeholder: rgba(0, 0, 0, 0.12);
    }

    @media (prefers-color-scheme: dark) {
        :root {
            --bg: #1e1e1e;
            --fg: #cccccc;
            --muted: #8e8e93;
            --hairline: rgba(255, 255, 255, 0.1);
            --hover: rgba(255, 255, 255, 0.07);
            --bar-bg: rgba(30, 30, 30, 0.82);
            --field-bg: rgba(255, 255, 255, 0.08);
            --field-border: rgba(255, 255, 255, 0.12);
            --placeholder: rgba(255, 255, 255, 0.12);
        }
    }

    [hidden] { display: none !important; }

    html { -webkit-text-size-adjust: 100%; }

    body {
        margin: 0;
        background: var(--bg);
        color: var(--fg);
        font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
        font-size: 13px;
        line-height: 1.4;
    }

    .bar {
        position: sticky;
        top: 0;
        z-index: 1;
        background: var(--bar-bg);
        -webkit-backdrop-filter: saturate(180%) blur(20px);
        backdrop-filter: saturate(180%) blur(20px);
        border-bottom: 1px solid var(--hairline);
    }

    .bar-inner,
    .column {
        max-width: 760px;
        margin: 0 auto;
        padding: 0 20px;
        box-sizing: border-box;
    }

    .bar-inner {
        display: flex;
        align-items: center;
        gap: 16px;
        height: 52px;
    }

    h1 {
        margin: 0;
        font-size: 17px;
        font-weight: 600;
        letter-spacing: -0.01em;
        white-space: nowrap;
    }

    #search {
        flex: 1 1 auto;
        min-width: 0;
        margin: 0;
        padding: 5px 10px;
        font: inherit;
        color: inherit;
        background: var(--field-bg);
        border: 1px solid var(--field-border);
        border-radius: 7px;
        outline: none;
        -webkit-appearance: none;
        appearance: none;
    }

    #search::placeholder { color: var(--muted); }
    #search:focus { border-color: rgba(10, 100, 210, 0.6); }

    .column { padding-bottom: 60px; }

    .day {
        margin: 26px 0 6px;
        font-size: 12px;
        font-weight: 600;
        text-transform: uppercase;
        letter-spacing: 0.05em;
        color: var(--muted);
    }

    .row {
        display: flex;
        align-items: center;
        gap: 10px;
        padding: 7px 8px;
        margin: 0 -8px;
        border-radius: 7px;
        color: inherit;
        text-decoration: none;
    }

    a.row:hover { background: var(--hover); }

    .icon {
        flex: 0 0 auto;
        width: 16px;
        height: 16px;
        border-radius: 3px;
        background: var(--placeholder);
        overflow: hidden;
    }

    .favicon {
        display: block;
        width: 16px;
        height: 16px;
    }

    .text {
        flex: 1 1 auto;
        min-width: 0;
        display: flex;
        align-items: baseline;
        gap: 8px;
    }

    .title {
        flex: 0 1 auto;
        overflow: hidden;
        white-space: nowrap;
        text-overflow: ellipsis;
    }

    .where {
        flex: 0 1 auto;
        overflow: hidden;
        white-space: nowrap;
        text-overflow: ellipsis;
        color: var(--muted);
    }

    .when {
        flex: 0 0 auto;
        font-variant-numeric: tabular-nums;
        color: var(--muted);
    }

    .empty {
        margin: 90px auto;
        max-width: 420px;
        text-align: center;
    }

    .empty-title {
        margin: 0 0 6px;
        font-size: 15px;
        font-weight: 600;
    }

    .empty-detail {
        margin: 0;
        color: var(--muted);
    }

    #sentinel { height: 1px; }
    """#
}

extension InternalPage {
    /// Body of the page's user script; see `InternalPageBridge.userScriptSource`
    /// for the wrapper that scopes it to the page and defines `native(method, params)`.
    var scriptSource: String {
        switch self {
        case .history: return HistoryPageContent.script
        }
    }
}

extension HistoryPageContent {
    /// The History page's logic. Runs in `InternalPageBridge.contentWorld` at
    /// document start, so it waits for `DOMContentLoaded` before touching the DOM.
    ///
    /// Every string in an entry — its title and its URL — was written by a page
    /// the user visited, so nothing here ever assigns markup: no `innerHTML`,
    /// `insertAdjacentHTML`, `outerHTML` or `document.write`. Rows are built with
    /// `createElement` and filled with `textContent`, and a row only becomes a
    /// link when its URL parses as `http(s)` (TASK-86).
    static let script = #"""
    const PAGE_SIZE = 100;
    /// How far past the bottom of the viewport the sentinel may be and still
    /// pull the next page in.
    const PREFETCH_MARGIN = 400;

    const state = {
        // Bumped by every search and every refresh. A reply that does not carry
        // the current generation belongs to a query the user has moved on from
        // and is dropped, so a slow first page can never land under a newer one.
        generation: 0,
        query: '',
        cursor: null,
        done: false,
        loading: false,
        count: 0,
        // The id of the newest entry on screen, so a refresh can tell "nothing
        // new" (leave the list and the scroll position alone) from "reload".
        topID: null,
        // The day heading last written, so groups continue across pages.
        lastDay: null,
        incognito: false,
    };

    let listEl = null;
    let emptyEl = null;
    let searchEl = null;
    let sentinelEl = null;
    let searchTimer = null;

    // MARK: - Formatting

    /// The entry's URL when it is one we may link to, else null: an entry with
    /// any other scheme is rendered as plain text rather than an anchor.
    const webURL = (raw) => {
        try {
            const parsed = new URL(raw);
            if (parsed.protocol === 'http:' || parsed.protocol === 'https:') return parsed;
        } catch (error) {
            // Not a URL at all — render it as text.
        }
        return null;
    };

    const displayHost = (parsed) => {
        const host = parsed.host;
        return host.startsWith('www.') ? host.slice(4) : host;
    };

    const dateOf = (entry) => {
        const seconds = Number(entry && entry.time);
        if (!Number.isFinite(seconds)) return null;
        const date = new Date(seconds * 1000);
        return Number.isFinite(date.getTime()) ? date : null;
    };

    const dayKey = (date) => `${date.getFullYear()}-${date.getMonth()}-${date.getDate()}`;

    const dayLabel = (date) => {
        const today = new Date();
        if (dayKey(date) === dayKey(today)) return 'Today';
        const yesterday = new Date(today.getTime());
        yesterday.setDate(today.getDate() - 1);
        if (dayKey(date) === dayKey(yesterday)) return 'Yesterday';
        return date.toLocaleDateString(undefined, {
            weekday: 'long', month: 'long', day: 'numeric', year: 'numeric',
        });
    };

    const timeLabel = (date) =>
        date.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });

    // Search results are one row per URL and span every day, so they carry a
    // date of their own instead of sitting under a day heading.
    const searchTimeLabel = (date) =>
        `${date.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })}, ${timeLabel(date)}`;

    // MARK: - Rendering

    const buildRow = (entry, date) => {
        const parsed = webURL(entry.url);
        const row = document.createElement(parsed ? 'a' : 'div');
        row.className = 'row';
        if (parsed) {
            // An href, not a bridge call: the click is then an ordinary
            // navigation, so Cmd-click and middle-click open a tab in this
            // tab's own space exactly as they do on any other page.
            row.setAttribute('href', parsed.href);
            row.setAttribute('rel', 'noreferrer');
        }

        const icon = document.createElement('span');
        icon.className = 'icon';
        if (parsed) {
            const img = document.createElement('img');
            img.className = 'favicon';
            img.setAttribute('width', '16');
            img.setAttribute('height', '16');
            img.setAttribute('alt', '');
            // Only rows the user actually scrolls to ask for an icon, and the
            // native side answers from its cache when it can: opening History
            // must not fire a request at every site in the list.
            img.setAttribute('loading', 'lazy');
            img.setAttribute('src', `favicon?pageUrl=${encodeURIComponent(entry.url)}&size=32`);
            // No icon on record (a 404): leave the neutral placeholder, and do
            // not ask again.
            img.addEventListener('error', () => { img.hidden = true; });
            icon.appendChild(img);
        }
        row.appendChild(icon);

        const text = document.createElement('span');
        text.className = 'text';
        const title = document.createElement('span');
        title.className = 'title';
        title.textContent = entry.title ? String(entry.title) : String(entry.url);
        const where = document.createElement('span');
        where.className = 'where';
        where.textContent = parsed ? displayHost(parsed) : String(entry.url);
        text.appendChild(title);
        text.appendChild(where);
        row.appendChild(text);

        const when = document.createElement('span');
        when.className = 'when';
        if (date) when.textContent = state.query ? searchTimeLabel(date) : timeLabel(date);
        row.appendChild(when);
        return row;
    };

    const appendEntries = (entries) => {
        const fragment = document.createDocumentFragment();
        for (const entry of entries) {
            if (!entry || typeof entry.url !== 'string') continue;
            const date = dateOf(entry);
            if (date && !state.query) {
                const key = dayKey(date);
                if (key !== state.lastDay) {
                    state.lastDay = key;
                    const heading = document.createElement('h2');
                    heading.className = 'day';
                    heading.textContent = dayLabel(date);
                    fragment.appendChild(heading);
                }
            }
            fragment.appendChild(buildRow(entry, date));
        }
        listEl.appendChild(fragment);
    };

    const showEmpty = (heading, detail) => {
        const title = document.createElement('p');
        title.className = 'empty-title';
        title.textContent = heading;
        const body = document.createElement('p');
        body.className = 'empty-detail';
        body.textContent = detail;
        emptyEl.replaceChildren(title, body);
        emptyEl.hidden = false;
    };

    const updateEmptyState = () => {
        if (state.count > 0) {
            emptyEl.hidden = true;
            return;
        }
        if (state.incognito) {
            showEmpty('Private browsing keeps no history',
                      'Pages you visit in a private space are never recorded, so there is nothing to show here.');
        } else if (state.query) {
            showEmpty(`No results for “${state.query}”`,
                      'Try a different word, or clear the search to see everything.');
        } else {
            showEmpty('No history yet', 'Pages you visit will appear here.');
        }
    };

    // MARK: - Loading

    /// Abandons everything in flight and returns the generation replies must
    /// now carry. The loading flag belongs to the request that set it, so it is
    /// released here rather than by the reply that will be dropped.
    const nextGeneration = () => {
        state.loading = false;
        state.generation += 1;
        return state.generation;
    };

    const queryParams = (cursor) => {
        const params = { limit: PAGE_SIZE };
        if (state.query) params.search = state.query;
        if (cursor) params.cursor = cursor;
        return params;
    };

    const receive = (result, replace) => {
        const entries = Array.isArray(result && result.entries) ? result.entries : [];
        state.incognito = !!(result && result.incognito);
        if (replace) {
            listEl.replaceChildren();
            state.count = 0;
            state.lastDay = null;
            state.topID = null;
        }
        if (state.count === 0 && entries.length) state.topID = entries[0].id;
        appendEntries(entries);
        state.count += entries.length;
        state.cursor = (result && result.nextCursor) || null;
        state.done = !state.cursor;
        updateEmptyState();
        // A short page can leave the sentinel on screen, and an observer that
        // is already intersecting fires no second callback.
        if (!state.done) requestAnimationFrame(loadMoreIfNeeded);
    };

    const fetchPage = (generation, cursor, replace) => {
        state.loading = true;
        native('history.query', queryParams(cursor)).then((result) => {
            if (generation !== state.generation) return;
            state.loading = false;
            receive(result, replace);
        }, () => {
            if (generation !== state.generation) return;
            state.loading = false;
            state.done = true;
            updateEmptyState();
        });
    };

    const loadMoreIfNeeded = () => {
        if (state.loading || state.done || !sentinelEl) return;
        if (sentinelEl.getBoundingClientRect().top > window.innerHeight + PREFETCH_MARGIN) return;
        fetchPage(state.generation, state.cursor, false);
    };

    /// Starts the list again from the top — the first load, and every change of
    /// search term.
    const reload = () => {
        const generation = nextGeneration();
        state.cursor = null;
        state.done = false;
        fetchPage(generation, null, true);
    };

    /// Re-reads the newest page when the tab comes back into view. When the
    /// first entry is the one already at the top nothing is re-rendered, so the
    /// scroll position and everything paged in below it survive. No live push.
    ///
    /// A refresh is a bystander until it finds something new: it neither claims
    /// the loading flag nor starts a generation, because focus and visibility
    /// events arrive while a load-more is in flight, and abandoning that reply
    /// for a refresh that then changes nothing would stall paging for good — the
    /// sentinel is already intersecting, so its observer never fires again.
    const refresh = () => {
        const generation = state.generation;
        native('history.query', queryParams(null)).then((result) => {
            if (generation !== state.generation) return;
            const entries = Array.isArray(result && result.entries) ? result.entries : [];
            const top = entries.length ? entries[0].id : null;
            if (state.count > 0 && top === state.topID) return;
            nextGeneration();
            state.cursor = null;
            state.done = false;
            receive(result, true);
        }, () => {});
    };

    const onSearchInput = () => {
        clearTimeout(searchTimer);
        searchTimer = setTimeout(() => {
            const next = searchEl.value.trim();
            if (next === state.query) return;
            state.query = next;
            // Keep the term in the URL: the tab persists its URL, so a reload
            // and a session restore both come back to the same search.
            try {
                history.replaceState(null, '',
                                     next ? `?q=${encodeURIComponent(next)}` : location.pathname);
            } catch (error) {
                // A custom scheme may refuse the rewrite; the search still works.
            }
            reload();
        }, 150);
    };

    const start = () => {
        listEl = document.getElementById('entries');
        emptyEl = document.getElementById('empty');
        searchEl = document.getElementById('search');
        sentinelEl = document.getElementById('sentinel');
        if (!listEl || !emptyEl || !searchEl || !sentinelEl) return;

        const initial = new URLSearchParams(location.search).get('q');
        if (initial) {
            state.query = initial.trim();
            searchEl.value = state.query;
        }
        searchEl.addEventListener('input', onSearchInput);
        searchEl.focus();

        new IntersectionObserver((records) => {
            if (records.some((record) => record.isIntersecting)) loadMoreIfNeeded();
        }, { rootMargin: `${PREFETCH_MARGIN}px` }).observe(sentinelEl);

        document.addEventListener('visibilitychange', () => {
            if (!document.hidden) refresh();
        });
        window.addEventListener('focus', refresh);

        reload();
    };

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', start);
    } else {
        start();
    }
    """#
}
