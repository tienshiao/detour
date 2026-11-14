import Foundation
import WebKit

/// Running scripts in a tab's page for the page tools (TASK-228.4):
/// `callAsyncJavaScript` with a deadline, a client's script wrapped so its
/// result always comes back as JSON, and the scripts behind `read_page` and
/// `wait_for`. Works on any live web view, shown in a window or not.
enum AutomationPage {

    /// Detour's own world for automation scripts: the page's DOM, but not its
    /// globals or its patched prototypes, and invisible to the page.
    static let isolatedWorld = WKContentWorld.world(name: "DetourAutomation")

    /// The longest JSON a script's result may come back as; past it the
    /// result is cut and marked `truncated`.
    static let maximumResultLength = 1_000_000

    /// `world` as the tools name it: `page` (default) or `isolated`.
    static func world(named name: String?) throws -> WKContentWorld {
        switch name ?? "page" {
        case "page": return .page
        case "isolated": return isolatedWorld
        default: throw AutomationToolError(.invalidArguments, "world is page or isolated")
        }
    }

    // MARK: Calling into the page

    /// Runs `body` (a function body, as `callAsyncJavaScript` takes it) in the
    /// main frame and returns the string it returns. Gives up with `timeout`
    /// after `limit`; the script itself cannot be stopped and runs on.
    ///
    /// A JavaScript exception WebKit reports (the body did not compile, or
    /// threw outside the wrappers' own catch) is `script_error`; any other
    /// failure (the web content process went away, the frame is gone) is
    /// `internal_error`.
    static func callString(_ body: String, arguments: [String: Any] = [:], in webView: WKWebView,
                           world: WKContentWorld, limit: Duration) async throws -> String {
        let once = ResumeOnce()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            // Cancelled when the reply comes, so a poll (wait_for calls ten
            // times a second) leaves no sleeping deadline tasks behind.
            let deadline = Task { @MainActor in
                try? await Task.sleep(for: limit)
                guard !Task.isCancelled, once.claim() else { return }
                continuation.resume(throwing: AutomationToolError(
                    .timeout, "The page did not answer within \(Self.milliseconds(limit)) ms (the script keeps running)"))
            }
            webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: world) { result in
                deadline.cancel()
                guard once.claim() else { return }
                switch result {
                case .success(let value):
                    if let string = value as? String {
                        continuation.resume(returning: string)
                    } else {
                        continuation.resume(throwing: AutomationToolError(.internalError, "The page returned no result"))
                    }
                case .failure(let error):
                    continuation.resume(throwing: Self.toolError(for: error))
                }
            }
        }
    }

    /// `callString`, with the string read as JSON.
    static func callJSON(_ body: String, arguments: [String: Any] = [:], in webView: WKWebView,
                         world: WKContentWorld, limit: Duration) async throws -> JSONValue {
        let string = try await callString(body, arguments: arguments, in: webView, world: world, limit: limit)
        do {
            return try JSONValue.parse(Data(string.utf8))
        } catch {
            throw AutomationToolError(.internalError, "The page's result is not JSON")
        }
    }

    static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    /// What WebKit's failure means for a client.
    static func toolError(for error: Error) -> AutomationToolError {
        let nsError = error as NSError
        guard nsError.domain == WKErrorDomain, nsError.code == WKError.javaScriptExceptionOccurred.rawValue else {
            return AutomationToolError(.internalError, "The page did not run the script: \(nsError.localizedDescription)")
        }
        let message = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String ?? nsError.localizedDescription
        // "SyntaxError: Unexpected token ')'" names its own kind.
        let name = message.range(of: #"^[A-Za-z]*Error(?=:)"#, options: .regularExpression).map { String(message[$0]) }
        let details: JSONValue = [
            "name": .nullable(name),
            "message": .string(message),
            "stack": .null,
            "line": (nsError.userInfo["WKJavaScriptExceptionLineNumber"] as? NSNumber).map { .int($0.intValue) } ?? .null,
            "column": (nsError.userInfo["WKJavaScriptExceptionColumnNumber"] as? NSNumber).map { .int($0.intValue) } ?? .null,
        ]
        return AutomationToolError(.scriptError, "The script did not run: \(message)", details: details)
    }

    // MARK: evaluate_js

    /// `script` (a function body that uses `return`) or `expression`, wrapped
    /// so the result always arrives as JSON: `{ok, type, truthy, value, truncated}`,
    /// or `{ok: false, name, message, stack}` for what it threw. Promises are
    /// awaited. A value JSON cannot hold is converted in the page by
    /// `plainFunction` (cycles, DOM nodes, functions, undefined).
    static func evaluationBody(script: String?, expression: String?) -> String {
        let user = if let expression { "return (\n\(expression)\n);" } else { script ?? "" }
        return """
            const __detourUser = async () => {
            \(user)
            };
            \(plainFunction)
            const __detourMaximum = \(maximumResultLength);
            const __detourType = (value) => {
              if (value === null) return 'null';
              if (Array.isArray(value)) return 'array';
              if (typeof Node === 'function' && value instanceof Node) return 'node';
              if (value instanceof Error) return 'error';
              return typeof value;
            };
            try {
              const value = await __detourUser();
              // Converted once: the walk runs the value's getters and toJSON.
              const plain = __detourPlain(value);
              const type = __detourType(value);
              let json = JSON.stringify({ ok: true, type, truthy: !!value, value: plain });
              if (json.length > __detourMaximum) {
                json = JSON.stringify({ ok: true, type, truthy: !!value, truncated: true,
                                        value: JSON.stringify(plain).slice(0, __detourMaximum) });
              }
              return json;
            } catch (error) {
              const isError = error instanceof Error;
              let message;
              try { message = isError ? String(error.message) : JSON.stringify(__detourPlain(error)); }
              catch (inner) { message = '[Unreadable]'; }
              return JSON.stringify({ ok: false, name: isError ? String(error.name) : null, message,
                                      stack: isError && error.stack ? String(error.stack) : null,
                                      thrown_type: __detourType(error) });
            }
            """
    }

    /// A function, `__detourPlain(value)`, that turns any value into one JSON
    /// can hold: a DOM node becomes a description (`<div#id.class>`), a cycle
    /// `[Circular]`, a function `[Function name]`, a non-finite number or a
    /// bigint a string, undefined null; an Error its name, message and stack;
    /// a Map its entries, a Set its values. Bounded in depth and in the
    /// number of values visited, so returning `window`-sized graphs answers.
    static let plainFunction = """
        const __detourPlain = (root) => {
          let budget = 50000;
          const ancestors = [];
          const nodeText = (node) => {
            if (node.nodeType === 1) {
              let text = '<' + node.localName;
              if (node.id) text += '#' + node.id;
              if (node.classList && node.classList.length) text += '.' + Array.from(node.classList).join('.');
              return text + '>';
            }
            if (node.nodeType === 3) return '#text ' + JSON.stringify(String(node.nodeValue).slice(0, 80));
            if (node.nodeType === 9) return '#document ' + String(node.URL || '');
            return String(node.nodeName);
          };
          const walk = (value, depth) => {
            if (--budget < 0) return '[\\u2026]';
            if (value === null || value === undefined) return null;
            const type = typeof value;
            if (type === 'string' || type === 'boolean') return value;
            if (type === 'number') return Number.isFinite(value) ? value : String(value);
            if (type === 'bigint') return value.toString() + 'n';
            if (type === 'symbol') return value.toString();
            if (type === 'function') return '[Function' + (value.name ? ' ' + value.name : '') + ']';
            try {
              if (typeof Node === 'function' && value instanceof Node) return nodeText(value);
              if (typeof Window === 'function' && value instanceof Window) return '[Window]';
            } catch (error) {}
            if (ancestors.includes(value)) return '[Circular]';
            if (depth >= 32) return '[\\u2026]';
            ancestors.push(value);
            try {
              if (value instanceof Error) {
                return { name: String(value.name), message: String(value.message),
                         stack: value.stack ? String(value.stack) : null };
              }
              if (value instanceof Date) return Number.isNaN(value.getTime()) ? 'Invalid Date' : value.toISOString();
              if (value instanceof RegExp) return String(value);
              if (Array.isArray(value) || ArrayBuffer.isView(value)) {
                const out = [];
                const length = Math.min(value.length, 10000);
                for (let index = 0; index < length; index++) out.push(walk(value[index], depth + 1));
                if (value.length > length) out.push('[\\u2026 ' + (value.length - length) + ' more]');
                return out;
              }
              if (value instanceof Map) return Array.from(value, ([key, item]) => [walk(key, depth + 1), walk(item, depth + 1)]);
              if (value instanceof Set) return Array.from(value, (item) => walk(item, depth + 1));
              if (typeof value.then === 'function') return '[Promise]';
              if (typeof value.toJSON === 'function') return walk(value.toJSON(), depth + 1);
              const out = {};
              for (const key of Object.keys(value)) {
                let item;
                try { item = value[key]; } catch (error) { item = '[Threw: ' + String(error) + ']'; }
                if (item !== undefined) out[key] = walk(item, depth + 1);
              }
              return out;
            } catch (error) {
              return '[Unserialisable: ' + String(error) + ']';
            } finally {
              ancestors.pop();
            }
          };
          return walk(root, 0);
        };
        """

    // MARK: read_page

    /// Reads the page in Detour's isolated world (the page cannot patch what
    /// it uses). Arguments: `mode` (summary, text, html, elements),
    /// `selector` (or null), `maxLength`, `maxElements`.
    static let readPageBody = """
        const result = { url: location.href, title: document.title, ready_state: document.readyState,
                 viewport: { width: innerWidth, height: innerHeight } };
        let root = document.documentElement;
        if (selector) {
          let found;
          try { found = document.querySelector(selector); }
          catch (error) { return JSON.stringify({ error: 'invalid', message: String(error) }); }
          if (!found) return JSON.stringify({ error: 'nomatch' });
          root = found;
        }
        const cut = (text) => {
          const string = String(text || '');
          result.length = string.length;
          result.truncated = string.length > maxLength;
          return string.slice(0, maxLength);
        };
        if (mode === 'text') {
          const element = selector ? root : (document.body || document.documentElement);
          result.text = cut(element ? element.innerText : '');
        } else if (mode === 'html') {
          result.html = cut(root ? root.outerHTML : '');
        } else if (mode === 'elements') {
          \(elementsFunction)
          const listed = __detourElements(root, maxElements);
          result.elements = listed.elements;
          result.element_count = listed.count;
          result.truncated = listed.count > listed.elements.length;
        }
        return JSON.stringify(result);
        """

    /// `__detourElements(root, limit)`: the interactive elements under `root`
    /// in document order, each with its role, an accessible name (best
    /// effort), a CSS selector unique in the document (what `click` and
    /// `type_text` take), its rect in CSS pixels and whether it is visible.
    static let elementsFunction = """
        const __detourElements = (root, limit) => {
          const interactive = 'a[href], area[href], button, input:not([type="hidden"]), select, textarea, summary, '
            + '[contenteditable]:not([contenteditable="false"]), [role="button"], [role="link"], [role="checkbox"], '
            + '[role="radio"], [role="tab"], [role="menuitem"], [role="menuitemcheckbox"], [role="menuitemradio"], '
            + '[role="option"], [role="switch"], [role="textbox"], [role="searchbox"], [role="combobox"], '
            + '[role="slider"], [role="spinbutton"], [role="treeitem"]';
          const squash = (text) => String(text || '').replace(/\\s+/g, ' ').trim();
          const short = (text) => text.length > 120 ? text.slice(0, 120) + '\\u2026' : text;
          const isUnique = (selector, element) => {
            try {
              const all = document.querySelectorAll(selector);
              return all.length === 1 && all[0] === element;
            } catch (error) { return false; }
          };
          const selectorFor = (element) => {
            const escape = (value) => CSS.escape(value);
            if (element.id && isUnique('#' + escape(element.id), element)) return '#' + escape(element.id);
            for (const attribute of ['data-testid', 'data-test', 'name', 'aria-label']) {
              const value = element.getAttribute(attribute);
              if (!value) continue;
              const selector = element.localName + '[' + attribute + '="' + value.replace(/["\\\\]/g, '\\\\$&') + '"]';
              if (isUnique(selector, element)) return selector;
            }
            const parts = [];
            let node = element;
            while (node && node.nodeType === 1 && node !== document.documentElement) {
              if (node !== element && node.id && isUnique('#' + escape(node.id), node)) {
                parts.unshift('#' + escape(node.id));
                break;
              }
              let part = escape(node.localName);
              const parent = node.parentElement;
              if (parent) {
                const same = Array.from(parent.children).filter((child) => child.localName === node.localName);
                if (same.length > 1) part += ':nth-of-type(' + (same.indexOf(node) + 1) + ')';
              }
              parts.unshift(part);
              node = parent;
              if (!node || node === document.documentElement) parts.unshift('html');
            }
            const selector = parts.join(' > ');
            return isUnique(selector, element) ? selector : null;
          };
          const implicitRole = (element) => {
            const tag = element.localName;
            if (tag === 'a' || tag === 'area') return 'link';
            if (tag === 'button' || tag === 'summary') return 'button';
            if (tag === 'select') return element.multiple || element.size > 1 ? 'listbox' : 'combobox';
            if (tag === 'textarea') return 'textbox';
            if (tag === 'input') {
              const type = (element.getAttribute('type') || 'text').toLowerCase();
              const roles = { button: 'button', submit: 'button', reset: 'button', image: 'button',
                              checkbox: 'checkbox', radio: 'radio', range: 'slider', number: 'spinbutton',
                              search: 'searchbox' };
              return roles[type] || 'textbox';
            }
            if (element.isContentEditable) return 'textbox';
            return 'generic';
          };
          const nameOf = (element) => {
            const labelledBy = element.getAttribute('aria-labelledby');
            if (labelledBy) {
              const text = squash(labelledBy.split(/\\s+/)
                .map((id) => { const label = document.getElementById(id); return label ? label.textContent : ''; })
                .join(' '));
              if (text) return text;
            }
            const aria = squash(element.getAttribute('aria-label'));
            if (aria) return aria;
            const tag = element.localName;
            const isField = tag === 'input' || tag === 'textarea' || tag === 'select';
            if (isField && element.labels && element.labels.length) {
              const text = squash(Array.from(element.labels, (label) => label.innerText || label.textContent).join(' '));
              if (text) return text;
            }
            if (tag === 'input') {
              const type = (element.type || '').toLowerCase();
              if (type === 'button' || type === 'submit' || type === 'reset') return squash(element.value) || type;
              if (type === 'image') return squash(element.alt);
            }
            if (!isField && !element.isContentEditable) {
              const text = squash(element.innerText || element.textContent);
              if (text) return text;
              const image = element.querySelector('img[alt]');
              if (image && squash(image.alt)) return squash(image.alt);
            }
            return squash(element.getAttribute('title') || element.getAttribute('placeholder'));
          };
          const candidates = Array.from(root.querySelectorAll(interactive));
          if (root.matches && root.matches(interactive)) candidates.unshift(root);
          const elements = [];
          for (const element of candidates) {
            if (elements.length >= limit) break;
            const rect = element.getBoundingClientRect();
            let visible = rect.width > 0 && rect.height > 0;
            if (visible && element.checkVisibility) {
              visible = element.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true });
            }
            const inViewport = visible && rect.right > 0 && rect.bottom > 0 && rect.left < innerWidth && rect.top < innerHeight;
            const entry = {
              tag: element.localName,
              role: (element.getAttribute('role') || '').trim().split(/\\s+/)[0] || implicitRole(element),
              name: short(nameOf(element)),
              selector: selectorFor(element),
              rect: { x: Math.round(rect.x * 10) / 10, y: Math.round(rect.y * 10) / 10,
                      width: Math.round(rect.width * 10) / 10, height: Math.round(rect.height * 10) / 10 },
              visible,
              in_viewport: inViewport,
              disabled: element.matches(':disabled') || element.getAttribute('aria-disabled') === 'true',
            };
            if (element.localName === 'input') entry.type = (element.getAttribute('type') || 'text').toLowerCase();
            if (element.href) entry.href = String(element.href);
            elements.push(entry);
          }
          return { elements, count: candidates.length };
        };
        """

    // MARK: wait_for

    /// Whether `selector` matches (and, with `visible`, whether any element
    /// it matches has a visible box, not only the first), in the isolated
    /// world. `{matched}` or `{error: 'invalid'}`.
    static let selectorMatchBody = """
        let elements;
        try {
          if (!visible) return JSON.stringify({ matched: document.querySelector(selector) !== null });
          elements = document.querySelectorAll(selector);
        } catch (error) { return JSON.stringify({ error: 'invalid', message: String(error) }); }
        for (const element of elements) {
          const rect = element.getBoundingClientRect();
          if (rect.width <= 0 || rect.height <= 0) continue;
          if (element.checkVisibility && !element.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })) continue;
          return JSON.stringify({ matched: true });
        }
        return JSON.stringify({ matched: false });
        """

    static let readyStateBody = "return JSON.stringify(document.readyState);"
}

/// Resumes a continuation once, whichever of a reply and a deadline comes
/// first. Main-actor state: both run on the main actor.
private final class ResumeOnce {
    private var claimed = false

    func claim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
