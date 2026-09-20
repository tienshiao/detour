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
            <select id="range" class="picker" aria-label="Time range" hidden>
                <option value="">All time</option>
                <option value="today">Today</option>
                <option value="yesterday">Yesterday</option>
                <option value="week">Last 7 days</option>
                <option value="month">Last 30 days</option>
                <option value="day">Specific day…</option>
            </select>
            <input id="day" class="picker" type="date" aria-label="Day" hidden>
            <details id="clear" class="menu" hidden>
                <summary class="button">Clear History…</summary>
                <div class="menu-list">
                    <button class="menu-item" type="button" data-range="hour">Last hour</button>
                    <button class="menu-item" type="button" data-range="today">Today</button>
                    <button class="menu-item" type="button" data-range="all">All history</button>
                </div>
            </details>
        </div>
        <div id="selection" class="selection" hidden>
            <div class="bar-inner">
                <span id="selection-count" class="selection-count"></span>
                <button id="selection-delete" class="button danger" type="button">Delete</button>
                <button id="selection-cancel" class="button" type="button">Cancel</button>
            </div>
        </div>
    </header>
    <main class="column">
        <div id="notice" class="notice" role="status" hidden></div>
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
        --menu-bg: #ffffff;
        --menu-shadow: rgba(0, 0, 0, 0.18);
        --selected: rgba(10, 100, 210, 0.12);
        --focus: rgba(10, 100, 210, 0.85);
        /* Restrained enough to sit in a quiet list, loud enough to read as
           destructive in both themes (TASK-87). */
        --danger: #c22e1f;
        --danger-soft: rgba(194, 46, 31, 0.1);
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
            --menu-bg: #2b2b2b;
            --menu-shadow: rgba(0, 0, 0, 0.5);
            --selected: rgba(10, 132, 255, 0.24);
            --focus: rgba(10, 132, 255, 0.95);
            --danger: #ff6b5e;
            --danger-soft: rgba(255, 107, 94, 0.14);
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
        /* Tighter since the time filter joined the row (TASK-92): the search
           field is the only thing that shrinks, and it should still be a field
           rather than a sliver on a narrow window. */
        gap: 12px;
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

    .button {
        flex: 0 0 auto;
        font: inherit;
        color: inherit;
        padding: 4px 10px;
        background: var(--field-bg);
        border: 1px solid var(--field-border);
        border-radius: 7px;
        white-space: nowrap;
        cursor: default;
    }

    .button:hover { background: var(--hover); }
    .button.danger { color: var(--danger); }
    .button.danger:hover { background: var(--danger-soft); }

    /* The time filter (TASK-92): a native <select> and a native date field,
       dressed as the controls beside them so the bar reads as one row. The
       background is set as `background-color`, not the shorthand, because the
       select paints its own popup arrow over it below. */
    .picker {
        flex: 0 0 auto;
        min-width: 0;
        margin: 0;
        font: inherit;
        color: inherit;
        padding: 4px 8px;
        background-color: var(--field-bg);
        border: 1px solid var(--field-border);
        border-radius: 7px;
        white-space: nowrap;
        cursor: default;
        outline: none;
        -webkit-appearance: none;
        appearance: none;
    }

    .picker:hover { background-color: var(--hover); }

    /* `appearance: none` takes the select's own arrow with it, so one is drawn
       back on as a background image. A `data:` URI, which this page's CSP
       allows (`img-src detour: data:`) and which needs no element `style`
       attribute — those it forbids. One grey that reads in both themes. */
    #range {
        padding-right: 22px;
        background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 10 6'%3E%3Cpath d='M1 1l4 4 4-4' fill='none' stroke='%238e8e93' stroke-width='1.4' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E");
        background-repeat: no-repeat;
        background-position: right 7px center;
        background-size: 9px 6px;
    }

    #day { font-variant-numeric: tabular-nums; }
    #range:focus, #day:focus { border-color: rgba(10, 100, 210, 0.6); }

    /* The Clear History menu: a <details>, so it opens and closes with no
       script and nothing inline. */
    .menu {
        position: relative;
        flex: 0 0 auto;
    }

    .menu > summary {
        display: inline-block;
        list-style: none;
    }

    .menu > summary::-webkit-details-marker { display: none; }

    /* The UA hides a closed <details>' contents already; say so explicitly, so
       an absolutely positioned menu cannot escape it. */
    .menu:not([open]) .menu-list { display: none; }

    .menu-list {
        position: absolute;
        top: calc(100% + 6px);
        right: 0;
        z-index: 2;
        min-width: 170px;
        display: flex;
        flex-direction: column;
        padding: 4px;
        background: var(--menu-bg);
        border: 1px solid var(--hairline);
        border-radius: 9px;
        box-shadow: 0 8px 28px var(--menu-shadow);
    }

    .menu-item {
        font: inherit;
        color: inherit;
        text-align: left;
        padding: 5px 10px;
        background: none;
        border: 0;
        border-radius: 5px;
        cursor: default;
    }

    .menu-item:hover { background: var(--hover); }

    .selection { border-top: 1px solid var(--hairline); }

    .selection .bar-inner {
        height: 40px;
        gap: 10px;
    }

    .selection-count {
        flex: 1 1 auto;
        min-width: 0;
        color: var(--muted);
    }

    /* A failed delete says so here rather than in an alert(), which would block
       the page and, on an internal page, the window with it. */
    .notice {
        margin-top: 14px;
        padding: 7px 10px;
        border-radius: 7px;
        color: var(--danger);
        background: var(--danger-soft);
    }

    .button:focus-visible,
    .picker:focus-visible,
    .menu-item:focus-visible,
    .delete:focus-visible,
    .pick:focus-visible,
    .row:focus-visible,
    summary:focus-visible {
        outline: 2px solid var(--focus);
        outline-offset: 2px;
    }

    .column { padding-bottom: 60px; }

    .day {
        margin: 26px 0 6px;
        font-size: 12px;
        font-weight: 600;
        text-transform: uppercase;
        letter-spacing: 0.05em;
        color: var(--muted);
    }

    /* A row is two things: `.item` is the line the user selects and deletes,
       `.row` inside it is still the link itself, so a click on the title is an
       ordinary navigation and the selection controls are outside the anchor
       (interactive content inside an <a> is not) — TASK-87. */
    .item {
        display: flex;
        align-items: center;
        gap: 6px;
        padding: 0 8px;
        margin: 0 -8px;
        border-radius: 7px;
    }

    .item:hover { background: var(--hover); }
    .item.selected { background: var(--selected); }

    .row {
        flex: 1 1 auto;
        min-width: 0;
        display: flex;
        align-items: center;
        gap: 10px;
        padding: 7px 0;
        color: inherit;
        text-decoration: none;
    }

    /* The affordances stay in the layout when idle — revealing them with
       `opacity` rather than `display` keeps the row from jumping under the
       pointer, and keeps them clickable and tabbable throughout. */
    .pick {
        flex: 0 0 auto;
        width: 14px;
        height: 14px;
        margin: 0;
        opacity: 0;
    }

    .item:hover .pick,
    .item.selected .pick,
    .pick:focus { opacity: 1; }

    .delete {
        flex: 0 0 auto;
        width: 22px;
        height: 22px;
        padding: 0;
        font: inherit;
        font-size: 15px;
        line-height: 1;
        color: var(--muted);
        background: none;
        border: 0;
        border-radius: 5px;
        opacity: 0;
        cursor: default;
    }

    .item:hover .delete,
    .delete:focus { opacity: 1; }
    .delete:hover { color: var(--danger); background: var(--danger-soft); }

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
    ///
    /// Deleting (TASK-87) never confirms anything itself: `history.clear` is
    /// confirmed by a native sheet the page cannot see, fake or skip, and the
    /// page's only job is to ignore further clicks while that sheet is up.
    static let script = #"""
    const PAGE_SIZE = 100;
    /// How far past the bottom of the viewport the sentinel may be and still
    /// pull the next page in.
    const PREFETCH_MARGIN = 400;
    /// Most visit ids one `history.delete` may name — `HistoryPageBridge`
    /// rejects a longer list as malformed, so a bigger selection is sent as
    /// several messages.
    const MAX_DELETE_IDS = \#(HistoryPageBridge.maxDeleteCount);
    /// How long a failed delete says so before the message fades.
    const NOTICE_MS = 5000;

    const state = {
        // Bumped by every search and every refresh. A reply that does not carry
        // the current generation belongs to a query the user has moved on from
        // and is dropped, so a slow first page can never land under a newer one.
        generation: 0,
        query: '',
        // The period the list is filtered to (TASK-92), in the shape the bridge
        // parses: null (all time), `{preset}` or `{day}`. Never a timestamp —
        // the bounds are the native side's to compute.
        range: null,
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
        // A delete is in flight. Deliberately not a generation bump: a
        // load-more reply that lands after the delete must still be appended,
        // or paging stalls (see `refresh`).
        deleting: false,
        // A `history.clear` is in flight, which means the native confirmation
        // sheet may be up. The page cannot see the sheet, so this flag is the
        // only thing keeping a second question from being queued behind it.
        clearing: false,
        // Bumped every time a delete's reply is applied. `refresh` uses it to
        // tell a read that cannot predate a delete from one that might.
        deleteEpoch: 0,
    };

    /// What this page has deleted and must not let back in: visit ids, and — in
    /// search mode, where a row stands for a URL and takes every in-scope visit
    /// of it — the URLs. A reply that was read before the delete committed can
    /// still name those rows, and dropping them here is cheaper than abandoning
    /// the paging that reply belongs to. Forgotten again as soon as a read is
    /// known to have happened after the delete (`reload`, and `refresh` when its
    /// query outlived no delete).
    let deletedIDs = new Set();
    let deletedURLs = new Set();

    /// The row a Shift+click measures its range from: the last one toggled by
    /// hand. An id rather than an element, because rows come and go.
    let anchorID = null;

    let listEl = null;
    let emptyEl = null;
    let searchEl = null;
    let rangeEl = null;
    let dayEl = null;
    let sentinelEl = null;
    let clearEl = null;
    let selectionEl = null;
    let selectionCountEl = null;
    let noticeEl = null;
    let searchTimer = null;
    let noticeTimer = null;

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

    // MARK: - The time range (TASK-92)

    /// The presets the <select> offers, and what the empty state calls each of
    /// them. `day` is not here: it is the option that reveals the date field,
    /// not a preset the bridge would accept.
    const PRESETS = {
        today: 'today',
        yesterday: 'yesterday',
        week: 'the last 7 days',
        month: 'the last 30 days',
    };

    /// How far back the date field may go — the history's own retention window.
    const RETENTION_DAYS = 90;

    /// Whether `name` is one of the presets above. An own-property test, not a
    /// truthiness one: `PRESETS['constructor']` is inherited and truthy, and a
    /// hand-edited URL is a string the page did not write.
    const isPreset = (name) => Object.prototype.hasOwnProperty.call(PRESETS, name);

    /// A local date as `YYYY-MM-DD`. `toISOString` would answer in UTC, which
    /// is the wrong day for half of every evening.
    const isoDay = (date) => {
        const month = String(date.getMonth() + 1).padStart(2, '0');
        const day = String(date.getDate()).padStart(2, '0');
        return `${date.getFullYear()}-${month}-${day}`;
    };

    const daysAgo = (days) => {
        const date = new Date();
        date.setDate(date.getDate() - days);
        return date;
    };

    /// Whether `text` is a real day, spelled exactly `YYYY-MM-DD`. The regex
    /// alone would accept 2026-02-30, so the date is built back up and has to
    /// come out as the day that was asked for. The native side re-checks this
    /// — nothing here is a permission — but a page that sent junk would simply
    /// get "malformed" back and show nothing.
    const validDay = (text) => {
        if (typeof text !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(text)) return false;
        const parts = text.split('-').map(Number);
        const date = new Date(parts[0], parts[1] - 1, parts[2]);
        return Number.isFinite(date.getTime()) && isoDay(date) === text;
    };

    /// The range as a string, for the row bookkeeping and for comparisons.
    /// Both shapes hold a single key, so the JSON is stable.
    const rangeKey = (range) => (range ? JSON.stringify(range) : '');

    /// What the empty state calls the current period, or null when there is
    /// none. A day is spelled out in full: "No history from Tue" would be a
    /// riddle.
    const periodLabel = () => {
        if (!state.range) return null;
        if (state.range.preset) return isPreset(state.range.preset) ? PRESETS[state.range.preset] : null;
        if (!validDay(state.range.day)) return null;
        const parts = state.range.day.split('-').map(Number);
        return new Date(parts[0], parts[1] - 1, parts[2]).toLocaleDateString(undefined, {
            weekday: 'long', month: 'long', day: 'numeric', year: 'numeric',
        });
    };

    // MARK: - Selection

    const itemEls = () => Array.from(listEl.querySelectorAll('.item'));
    const selectedEls = () => Array.from(listEl.querySelectorAll('.item.selected'));
    const idOf = (item) => Number(item.dataset.id);
    const urlOf = (item) => String(item.dataset.url || '');
    /// What the row on screen stands for, as it was RENDERED: a single visit, or
    /// a URL (a search result, which the delete takes every in-scope visit of).
    /// Read from the row rather than from `state.query`, which can already have
    /// moved on to a search whose rows have not landed yet (TASK-87).
    const modeOf = (item) => (item.dataset.mode === 'url' ? 'url' : 'visit');

    /// Whether typing would go into a control rather than to the list. A row's
    /// checkbox is an `<input>` too, and Delete or Cmd+A with one focused is
    /// still meant for the list. The date field is an `<input>` whose type is
    /// not `checkbox`, so it is covered already; the range `<select>` takes the
    /// keys itself (Delete and the arrows change the choice), so it is named
    /// here (TASK-92).
    const isTextFieldFocused = () => {
        const el = document.activeElement;
        if (!el) return false;
        if (el.isContentEditable === true) return true;
        if (el.tagName === 'TEXTAREA' || el.tagName === 'SELECT') return true;
        return el.tagName === 'INPUT' && el.type !== 'checkbox';
    };

    const setSelected = (item, on) => {
        item.classList.toggle('selected', on);
        const box = item.querySelector('.pick');
        if (box) box.checked = on;
    };

    const updateSelectionBar = () => {
        const count = selectedEls().length;
        selectionCountEl.textContent = count === 1 ? '1 selected' : `${count} selected`;
        selectionEl.hidden = count === 0;
    };

    const clearSelection = () => {
        for (const item of selectedEls()) setSelected(item, false);
        anchorID = null;
        updateSelectionBar();
    };

    const selectAllLoaded = () => {
        const all = itemEls();
        for (const item of all) setSelected(item, true);
        anchorID = all.length ? idOf(all[all.length - 1]) : null;
        updateSelectionBar();
    };

    /// The checkbox was just clicked, so it already carries its new state.
    /// Shift extends from the anchor instead, in DOM order and across day
    /// groups, and leaves the anchor where it is so the range can be redrawn.
    const togglePick = (item, shiftKey) => {
        const all = itemEls();
        const index = all.indexOf(item);
        const anchorIndex = anchorID === null ? -1 : all.findIndex((el) => idOf(el) === anchorID);
        if (shiftKey && index >= 0 && anchorIndex >= 0) {
            const from = Math.min(anchorIndex, index);
            const to = Math.max(anchorIndex, index);
            for (let i = from; i <= to; i += 1) setSelected(all[i], true);
        } else {
            const box = item.querySelector('.pick');
            setSelected(item, box ? box.checked : !item.classList.contains('selected'));
            anchorID = idOf(item);
        }
        updateSelectionBar();
    };

    // MARK: - Rendering

    const buildRow = (entry, date, mode) => {
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
        if (date) when.textContent = mode === 'url' ? searchTimeLabel(date) : timeLabel(date);
        row.appendChild(when);
        return row;
    };

    /// The line the list actually holds: the link, with the controls that select
    /// and delete it on either side of it rather than inside it.
    const buildItem = (entry, date, mode, range) => {
        const item = document.createElement('div');
        item.className = 'item';
        item.dataset.id = String(entry.id);
        item.dataset.url = String(entry.url);
        // The mode these entries were read in, kept on the row so a delete asks
        // for what the user is actually looking at (TASK-87).
        item.dataset.mode = mode;
        // And the period they were read under, for the same reason: a URL-mode
        // row stands for the URL's visits *in that period*, whatever the
        // control has been changed to since (TASK-92).
        item.dataset.range = range;

        const pick = document.createElement('input');
        pick.className = 'pick';
        pick.setAttribute('type', 'checkbox');
        pick.setAttribute('aria-label', 'Select');
        pick.addEventListener('click', (event) => togglePick(item, event.shiftKey));
        item.appendChild(pick);

        item.appendChild(buildRow(entry, date, mode));

        const remove = document.createElement('button');
        remove.className = 'delete';
        remove.setAttribute('type', 'button');
        remove.setAttribute('aria-label', 'Delete');
        remove.textContent = '×';
        remove.addEventListener('click', () => deleteItems([item]));
        item.appendChild(remove);
        return item;
    };

    /// Appends the entries worth showing and answers how many that was — which
    /// is not `entries.length` once a reply carries rows this page has deleted.
    ///
    /// `mode` is the one the entries answer — the query they were read for, not
    /// whatever `state.query` says by the time they arrive — and `range` is the
    /// period they were read under, kept on each row for the same reason.
    const appendEntries = (entries, mode, range) => {
        const fragment = document.createDocumentFragment();
        let appended = 0;
        for (const entry of entries) {
            if (!entry || typeof entry.url !== 'string') continue;
            // A read that started before a delete committed still names the
            // rows it removed; they must not reappear under the user (TASK-87).
            // A deleted URL lost every in-scope visit, so its rows are stale in
            // either mode.
            if (deletedIDs.has(Number(entry.id))) continue;
            if (deletedURLs.has(String(entry.url))) continue;
            const date = dateOf(entry);
            if (date && mode === 'visit') {
                const key = dayKey(date);
                if (key !== state.lastDay) {
                    state.lastDay = key;
                    const heading = document.createElement('h2');
                    heading.className = 'day';
                    heading.dataset.day = key;
                    heading.textContent = dayLabel(date);
                    fragment.appendChild(heading);
                }
            }
            fragment.appendChild(buildItem(entry, date, mode, range));
            appended += 1;
        }
        listEl.appendChild(fragment);
        return appended;
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
        // An empty list is only empty once there is nothing left to load:
        // deleting every row that is on screen (Cmd+A, Delete) empties a long
        // history's first page while the next one is already on its way, and
        // "No history yet" would be a lie (TASK-87). A failed load sets `done`,
        // so a list that cannot be filled still says something.
        if (state.count > 0 || state.loading || !state.done) {
            emptyEl.hidden = true;
            return;
        }
        const period = periodLabel();
        if (state.incognito) {
            showEmpty('Private browsing keeps no history',
                      'Pages you visit in a private space are never recorded, so there is nothing to show here.');
        } else if (state.query) {
            showEmpty(`No results for “${state.query}”`,
                      period
                          ? `Nothing from ${period} matches. Try a different word, or a different period.`
                          : 'Try a different word, or clear the search to see everything.');
        } else if (period) {
            showEmpty(`No history from ${period}`, 'Try a different period.');
        } else {
            showEmpty('No history yet', 'Pages you visit will appear here.');
        }
    };

    /// Incognito records nothing, so there is nothing to select, nothing to
    /// filter and nothing to clear. The controls start hidden in the markup and
    /// are revealed only once a reply has said which kind of space this is. The
    /// date field is the exception: it belongs to the "Specific day…" choice,
    /// so it only shows while that choice is made.
    const applyChrome = () => {
        clearEl.hidden = state.incognito;
        rangeEl.hidden = state.incognito;
        dayEl.hidden = state.incognito || rangeEl.value !== 'day';
        if (state.incognito) clearEl.open = false;
    };

    const showNotice = (text) => {
        noticeEl.textContent = text;
        noticeEl.hidden = false;
        clearTimeout(noticeTimer);
        noticeTimer = setTimeout(() => { noticeEl.hidden = true; }, NOTICE_MS);
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

    /// Drops the deletion bookkeeping. Only safe where the read about to be
    /// rendered is known to have started *after* every applied delete — the
    /// native side serializes reads behind writes, so "issued after" is enough.
    /// Keeping the sets for the life of the page instead would hide a URL the
    /// user deleted and then visited again.
    const forgetDeletions = () => {
        deletedIDs = new Set();
        deletedURLs = new Set();
    };

    /// `topID` is what `refresh` compares a fresh first page against, so it
    /// follows the DOM rather than the last reply — including when the row at
    /// the top is the one just deleted.
    const syncTopID = () => {
        const first = listEl.querySelector('.item');
        state.topID = first ? idOf(first) : null;
    };

    const queryParams = (cursor, query, range) => {
        const params = { limit: PAGE_SIZE };
        if (query) params.search = query;
        // Omitted rather than sent as null when there is none: absent is what
        // the bridge reads as "all time".
        if (range) params.range = range;
        if (cursor) params.cursor = cursor;
        return params;
    };

    /// `query` is the term these entries answer and `range` the period they
    /// were read under; the rows are rendered — and later deleted — in those,
    /// not in whatever `state` has moved on to (TASK-87, TASK-92).
    const receive = (result, replace, query, range) => {
        const entries = Array.isArray(result && result.entries) ? result.entries : [];
        state.incognito = !!(result && result.incognito);
        if (replace) {
            listEl.replaceChildren();
            state.count = 0;
            state.lastDay = null;
            state.topID = null;
        }
        state.count += appendEntries(entries, query ? 'url' : 'visit', rangeKey(range));
        if (state.topID === null) syncTopID();
        state.cursor = (result && result.nextCursor) || null;
        state.done = !state.cursor;
        applyChrome();
        updateSelectionBar();
        updateEmptyState();
        // A short page can leave the sentinel on screen, and an observer that
        // is already intersecting fires no second callback.
        if (!state.done) requestAnimationFrame(loadMoreIfNeeded);
    };

    const fetchPage = (generation, cursor, replace) => {
        // Captured now: a reply belongs to the query — and the period — it was
        // asked with.
        const query = state.query;
        const range = state.range;
        state.loading = true;
        native('history.query', queryParams(cursor, query, range)).then((result) => {
            if (generation !== state.generation) return;
            state.loading = false;
            receive(result, replace, query, range);
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
        // Issued now, so it is served after every delete already applied.
        forgetDeletions();
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
        const epoch = state.deleteEpoch;
        const query = state.query;
        const range = state.range;
        native('history.query', queryParams(null, query, range)).then((result) => {
            if (generation !== state.generation) return;
            const entries = Array.isArray(result && result.entries) ? result.entries : [];
            const top = entries.length ? entries[0].id : null;
            if (state.count > 0 && top === state.topID) return;
            nextGeneration();
            // This reply is about to replace the whole list, so it is the one
            // read a delete could undo. Only forget the deletions when no
            // delete was applied while it was in flight (TASK-87).
            if (epoch === state.deleteEpoch) forgetDeletions();
            state.cursor = null;
            state.done = false;
            receive(result, true, query, range);
        }, () => {});
    };

    // MARK: - Deleting

    /// Drops a day heading that has no rows under it any more, and re-points
    /// `lastDay` at the last one still standing so the next page continues the
    /// grouping instead of repeating a heading.
    const pruneDayHeadings = () => {
        for (const heading of Array.from(listEl.querySelectorAll('.day'))) {
            let next = heading.nextElementSibling;
            while (next && !next.classList.contains('day') && !next.classList.contains('item')) {
                next = next.nextElementSibling;
            }
            if (!next || !next.classList.contains('item')) heading.remove();
        }
        const headings = listEl.querySelectorAll('.day');
        const last = headings.length ? headings[headings.length - 1] : null;
        state.lastDay = last ? last.dataset.day : null;
    };

    /// Takes what a committed batch deleted out of the list, without reloading
    /// it: the visits it named, and — for a URL-mode batch, which took every
    /// in-scope visit of those URLs — every row showing one of them.
    ///
    /// The rows are looked up in the list as it stands NOW rather than kept from
    /// when the delete was issued: a reply that landed while the delete was in
    /// flight can have re-rendered the list, and the elements captured then are
    /// no longer the ones on screen (TASK-87).
    const applyDeletion = (ids, urls) => {
        state.deleteEpoch += 1;
        for (const id of ids) deletedIDs.add(id);
        for (const url of urls) deletedURLs.add(url);
        let removed = 0;
        for (const item of itemEls()) {
            if (!ids.has(idOf(item)) && !urls.has(urlOf(item))) continue;
            item.remove();
            removed += 1;
        }
        state.count -= removed;
        if (state.count < 0) state.count = 0;
        pruneDayHeadings();
        syncTopID();
        anchorID = null;
        updateSelectionBar();
        updateEmptyState();
        // `state.cursor` is a (time, id) bound rather than a row, so it still
        // works when its row is one of these. Removing rows can pull the
        // sentinel back into view, and an observer that is already intersecting
        // fires no second callback.
        loadMoreIfNeeded();
    };

    /// Deletes the rows `targets` names. A row rendered in list mode is one
    /// visit; one rendered in search mode stands for a URL, so every in-scope
    /// visit of that URL goes with it — narrowed to the period the row was
    /// rendered under (TASK-92), which is what it stood for on screen. A
    /// selection can hold rows of either mode and of more than one period, so
    /// they are grouped by both and each group asks for exactly what it means.
    /// The scope itself is the native side's business — nothing here says whose
    /// history this is.
    const deleteItems = (targets) => {
        if (state.deleting || state.incognito) return;
        const groups = new Map();
        for (const item of targets) {
            if (!item.isConnected || !Number.isFinite(idOf(item))) continue;
            const mode = modeOf(item);
            const range = String(item.dataset.range || '');
            // Newline: neither a mode nor a JSON range can contain one, so the
            // two parts cannot run together into another group's key.
            const key = `${mode}\n${range}`;
            const group = groups.get(key);
            if (group) group.items.push(item);
            else groups.set(key, { mode, range, items: [item] });
        }
        if (!groups.size) return;

        const batches = [];
        for (const { mode, range, items } of groups.values()) {
            for (let i = 0; i < items.length; i += MAX_DELETE_IDS) {
                batches.push({ mode, range, items: items.slice(i, i + MAX_DELETE_IDS) });
            }
        }
        state.deleting = true;
        // One message at a time, and each batch's rows leave the list the moment
        // that batch is committed: a later batch failing must not put rows back
        // that the database no longer has. A failure stops the rest — rather
        // than leaving the page to guess which of several in flight got through
        // — and the list is then rebuilt from what the database says, because
        // `refresh` would see the same top row and change nothing (TASK-87).
        batches.reduce(
            (previous, batch) => previous.then(() => {
                const allVisitsOfURL = batch.mode === 'url';
                const ids = batch.items.map(idOf);
                const params = { ids, allVisitsOfURL };
                // Only a URL-mode delete fans out, so only it has a period to
                // be narrowed to; a per-visit delete names its row and sends
                // none.
                if (allVisitsOfURL && batch.range) params.range = JSON.parse(batch.range);
                return native('history.delete', params).then(() => {
                    applyDeletion(new Set(ids),
                                  new Set(allVisitsOfURL ? batch.items.map(urlOf) : []));
                });
            }),
            Promise.resolve()
        ).then(() => {
            state.deleting = false;
        }, () => {
            state.deleting = false;
            showNotice('Those entries could not be deleted.');
            reload();
        });
    };

    /// Asks native to clear a range. The question itself is a sheet on the
    /// window, so the page neither draws it nor knows its answer until the
    /// promise settles — and ignores further clicks until then. `cleared: false`
    /// is the user saying no: nothing on screen changes.
    const clearHistory = (range) => {
        if (state.clearing || state.incognito || !range) return;
        state.clearing = true;
        clearEl.open = false;
        native('history.clear', { range }).then((result) => {
            state.clearing = false;
            if (!result || !result.cleared) return;
            // A clear can touch any page of the list, so this one *is* a
            // generation change: start again from the top.
            clearSelection();
            reload();
        }, () => {
            state.clearing = false;
            showNotice('History could not be cleared.');
        });
    };

    const onKeyDown = (event) => {
        if (event.key === 'Escape') {
            if (clearEl.open) {
                clearEl.open = false;
                return;
            }
            if (selectedEls().length) {
                event.preventDefault();
                clearSelection();
            }
            return;
        }
        if (isTextFieldFocused()) return;
        if (event.metaKey && !event.ctrlKey && !event.altKey && event.key.toLowerCase() === 'a') {
            event.preventDefault();
            selectAllLoaded();
            return;
        }
        if (event.key === 'Delete' || event.key === 'Backspace') {
            const chosen = selectedEls();
            if (!chosen.length) return;
            event.preventDefault();
            deleteItems(chosen);
        }
    };

    /// Writes the search term and the period into the page's own URL. The tab
    /// persists its URL, so a reload and a session restore both come back to
    /// the same view (TASK-92: `?q=…&range=week`, or `&day=YYYY-MM-DD`; the
    /// bare path when neither is set).
    const writeLocation = () => {
        const parts = [];
        if (state.query) parts.push(`q=${encodeURIComponent(state.query)}`);
        if (state.range && state.range.preset) {
            parts.push(`range=${encodeURIComponent(state.range.preset)}`);
        } else if (state.range && state.range.day) {
            parts.push(`day=${encodeURIComponent(state.range.day)}`);
        }
        try {
            history.replaceState(null, '', parts.length ? `?${parts.join('&')}` : location.pathname);
        } catch (error) {
            // A custom scheme may refuse the rewrite; the page still works.
        }
    };

    const onSearchInput = () => {
        clearTimeout(searchTimer);
        searchTimer = setTimeout(() => {
            const next = searchEl.value.trim();
            if (next === state.query) return;
            state.query = next;
            writeLocation();
            reload();
        }, 150);
    };

    /// Starts the list again under `range` (null for all time). A change of
    /// period is a change of what every row on screen stands for, so it goes
    /// through `reload` — a new generation, the deletion bookkeeping forgotten
    /// — and the selection goes with it.
    const applyRange = (range) => {
        if (rangeKey(range) === rangeKey(state.range)) return;
        state.range = range;
        writeLocation();
        clearSelection();
        reload();
    };

    /// The <select> changed, or the date field did. "Specific day…" with no
    /// valid day yet is not a query: the previous listing stays until there is
    /// a day to ask about.
    const onRangeInput = () => {
        const choice = rangeEl.value;
        dayEl.hidden = state.incognito || choice !== 'day';
        if (choice === 'day') {
            if (validDay(dayEl.value)) applyRange({ day: dayEl.value });
            return;
        }
        applyRange(isPreset(choice) ? { preset: choice } : null);
    };

    const start = () => {
        listEl = document.getElementById('entries');
        emptyEl = document.getElementById('empty');
        searchEl = document.getElementById('search');
        rangeEl = document.getElementById('range');
        dayEl = document.getElementById('day');
        sentinelEl = document.getElementById('sentinel');
        clearEl = document.getElementById('clear');
        selectionEl = document.getElementById('selection');
        selectionCountEl = document.getElementById('selection-count');
        noticeEl = document.getElementById('notice');
        const deleteButton = document.getElementById('selection-delete');
        const cancelButton = document.getElementById('selection-cancel');
        if (!listEl || !emptyEl || !searchEl || !rangeEl || !dayEl || !sentinelEl || !clearEl ||
            !selectionEl || !selectionCountEl || !noticeEl || !deleteButton || !cancelButton) return;

        const initial = new URLSearchParams(location.search);
        const term = initial.get('q');
        if (term) {
            state.query = term.trim();
            searchEl.value = state.query;
        }
        // The date field can only reach as far back as the history does; the
        // attributes are set here rather than in the markup because "90 days
        // ago" is not a constant. Attributes, not styles — the CSP forbids the
        // latter, and these are the picker's own limits either way.
        dayEl.setAttribute('min', isoDay(daysAgo(RETENTION_DAYS)));
        dayEl.setAttribute('max', isoDay(new Date()));
        // The period the URL came back with. Anything unrecognizable — a hand-
        // edited URL, a preset from a later version — falls back to all time
        // rather than to an error the user cannot act on.
        const preset = initial.get('range');
        const day = initial.get('day');
        if (isPreset(preset)) {
            state.range = { preset };
            rangeEl.value = preset;
        } else if (validDay(day)) {
            state.range = { day };
            rangeEl.value = 'day';
            dayEl.value = day;
        }
        searchEl.addEventListener('input', onSearchInput);
        rangeEl.addEventListener('change', onRangeInput);
        // `change` fires when a date is complete; `input` also catches the
        // picker's own edits, and both are cheap — `applyRange` ignores a
        // period that has not actually changed.
        dayEl.addEventListener('change', onRangeInput);
        dayEl.addEventListener('input', onRangeInput);
        searchEl.focus();

        deleteButton.addEventListener('click', () => deleteItems(selectedEls()));
        cancelButton.addEventListener('click', clearSelection);
        for (const option of clearEl.querySelectorAll('.menu-item')) {
            option.addEventListener('click', () => clearHistory(option.dataset.range));
        }
        // A menu the user cannot close by clicking away is a trap, and one that
        // reopens while the sheet is up would queue a second question.
        clearEl.addEventListener('toggle', () => {
            if (state.clearing) clearEl.open = false;
        });
        document.addEventListener('click', (event) => {
            if (clearEl.open && !clearEl.contains(event.target)) clearEl.open = false;
        });
        document.addEventListener('keydown', onKeyDown);

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
