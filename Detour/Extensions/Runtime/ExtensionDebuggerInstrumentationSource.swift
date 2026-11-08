import Foundation

// TASK-132.16: the scripts behind `Runtime.consoleAPICalled`,
// `Runtime.exceptionThrown` and the `Network` events on a tab an extension's
// debugger holds. WebKit reports neither console messages nor requests to the
// app, so a tab is instrumented while it is attached, and only then:
//
// - **Page world, main frame, document start** (`pageSource`): wraps the
//   console methods, `fetch` and `XMLHttpRequest`, and listens for uncaught
//   errors and unhandled rejections. Each wrapper calls the original with the
//   same receiver and arguments and returns what it returns; `fetch` returns a
//   promise derived from the original's, settled with the same value, so an
//   unhandled failure still reaches the page's `unhandledrejection`. The
//   wrappers are methods named as the originals, with their `length`, and
//   `Function.prototype.toString` gives the original's text for each (and its
//   own for itself): `fetch.toString()` reads `[native code]`. A `Proxy` would
//   not do: JSC prints a callable proxy as `function ProxyObject()`. What the
//   page can still notice: a wrapper frame (`user-script:N`) in a stack trace
//   taken inside one, and `toString` called on a non-function failing from
//   inside the replacement.
// - **Detour's content world (`DetourDebugger`), main frame, document start**
//   (`isolatedSource`): takes the page half's reports through a DOM event whose
//   name is the session's random token (the page cannot guess it, and the
//   isolated world's globals and handler are invisible to it), keeps console
//   messages (the last 1,000 of the document, replayed on `Runtime.enable` as
//   V8 replays its message storage), reads resource timing and element load
//   errors for the requests the page half does not see, and posts batches to
//   the `detourDebuggerEvents` handler, which only this world can reach.
//
// Both halves are also run in the document that is current when the session
// starts. When it ends, the current document's halves take their wrappers back
// out (a wrapper the page has since replaced is left alone).

enum ExtensionDebuggerInstrumentationSource {

    static let handlerName = "detourDebuggerEvents"
    /// The console messages a document keeps (V8's `maxConsoleMessageCount`).
    static let storedMessageLimit = 1000
    /// Longest string argument or request body a report carries, in UTF-16
    /// units; longer ones are cut.
    static let stringLimit = 65536

    static func pageSource(token: String) -> String {
        pageTemplate
            .replacingOccurrences(of: "__DESCRIBER__", with: ExtensionDebuggerEvaluation.describerSource)
            .replacingOccurrences(of: "__TOKEN__", with: token)
            .replacingOccurrences(of: "__STRING_LIMIT__", with: String(stringLimit))
    }

    static func isolatedSource(token: String) -> String {
        isolatedTemplate
            .replacingOccurrences(of: "__TOKEN__", with: token)
            .replacingOccurrences(of: "__HANDLER__", with: handlerName)
            .replacingOccurrences(of: "__STORED_LIMIT__", with: String(storedMessageLimit))
    }

    // Report kinds, the first character of each report: console message,
    // exception, exception revoked, request, response, failure, finished,
    // and (from the isolated half) a resource timing entry, an element's load
    // error, and the document's own body having arrived (`n`).

    private static let pageTemplate = #"""
        (() => {
          const TOKEN = '__TOKEN__';
          const STRING_LIMIT = __STRING_LIMIT__;
          const doc = document;
          const EventTargetProto = EventTarget.prototype;
          const dispatch = EventTargetProto.dispatchEvent, listen = EventTargetProto.addEventListener;
          const unlisten = EventTargetProto.removeEventListener;
          const Custom = CustomEvent;
          // Run twice in one document (the session started while it loaded):
          // the half already there cancels the probe.
          if (!dispatch.call(doc, new Custom(TOKEN + ':probe', { cancelable: true }))) return;
          const ErrorRef = Error, ErrorEventRef = ErrorEvent, JSONRef = JSON, DateRef = Date, URLRef = URL;
          const RequestRef = typeof Request === 'function' ? Request : null;
          const HeadersRef = typeof Headers === 'function' ? Headers : null;
          const URLSearchParamsRef = typeof URLSearchParams === 'function' ? URLSearchParams : null;
          const PromiseThen = Promise.prototype.then;
          const apply = Reflect.apply, getDescriptor = Object.getOwnPropertyDescriptor, defineProperty = Object.defineProperty;
          const WeakMapRef = WeakMap, MapRef = Map;
          const weakGet = WeakMap.prototype.get, weakSet = WeakMap.prototype.set;
          const mapGet = Map.prototype.get, mapSet = Map.prototype.set, mapHas = Map.prototype.has, mapDelete = Map.prototype.delete;
          const stringify = JSONRef.stringify, now = DateRef.now;
          const StringRef0 = String;
          const slice = String.prototype.slice, split = String.prototype.split, indexOf = String.prototype.indexOf;
          const toLower = String.prototype.toLowerCase, toUpper = String.prototype.toUpperCase, trim = String.prototype.trim;
          const startsWith = String.prototype.startsWith, lastIndexOf = String.prototype.lastIndexOf;
          const push = Array.prototype.push, arraySlice = Array.prototype.slice, isArrayRef = Array.isArray;
          const objectKeys = Object.keys;
          const perfNow = performance.now.bind(performance);
        __DESCRIBER__
          const report = (text) => {
            try { dispatch.call(doc, new Custom(TOKEN, { detail: text })); } catch (e) {}
          };
          const cut = (text) => (text.length > STRING_LIMIT ? apply(slice, text, [0, STRING_LIMIT]) : text);

          // A JSC stack, `name@url:line:column` per line, as CDP call frames
          // (0-based). Detour's own frames (`user-script:N`) and native ones
          // are left out.
          const callFrames = (stack) => {
            const frames = [];
            if (typeof stack !== 'string') return frames;
            const lines = apply(split, stack, ['\n']);
            for (let i = 0; i < lines.length && frames.length < 50; i++) {
              const line = lines[i];
              const at = apply(indexOf, line, ['@']);
              if (at < 0) continue;
              const name = apply(slice, line, [0, at]);
              const place = apply(slice, line, [at + 1]);
              const columnAt = apply(lastIndexOf, place, [':']);
              const lineAt = columnAt > 0 ? apply(lastIndexOf, place, [':', columnAt - 1]) : -1;
              if (lineAt <= 0) continue;
              const url = apply(slice, place, [0, lineAt]);
              if (!url || apply(startsWith, url, ['user-script:'])) continue;
              const lineNumber = +apply(slice, place, [lineAt + 1, columnAt]);
              const columnNumber = +apply(slice, place, [columnAt + 1]);
              if (!(lineNumber >= 1) || !(columnNumber >= 1)) continue;
              push.call(frames, { functionName: name === 'global code' ? '' : name, url,
                                  lineNumber: lineNumber - 1, columnNumber: columnNumber - 1 });
            }
            return frames;
          };
          const describe = (value) => {
            let object;
            try { object = remote(value, false); } catch (e) { object = { type: 'object', className: 'Object', description: 'Object' }; }
            if (object.type === 'string' && object.value.length > STRING_LIMIT) object.value = cut(object.value);
            if (typeof object.description === 'string' && object.description.length > STRING_LIMIT) object.description = cut(object.description);
            return object;
          };

          // --- Wrapping -----------------------------------------------------
          const originalToString = Function.prototype.toString;
          const originals = new WeakMapRef();
          const replaced = [];
          const disguise = (wrapper, original) => {
            try {
              defineProperty(wrapper, 'name', { value: original.name, configurable: true });
              defineProperty(wrapper, 'length', { value: original.length, configurable: true });
            } catch (e) {}
            apply(weakSet, originals, [wrapper, original]);
            return wrapper;
          };
          const replace = (target, key, makeWrapper) => {
            const descriptor = target && getDescriptor(target, key);
            if (!descriptor || typeof descriptor.value !== 'function' || !descriptor.configurable) return;
            const wrapper = disguise(makeWrapper(descriptor.value), descriptor.value);
            defineProperty(target, key, { value: wrapper, writable: descriptor.writable,
                                          enumerable: descriptor.enumerable, configurable: true });
            push.call(replaced, { target, key, wrapper, descriptor });
          };
          replace(Function.prototype, 'toString', (original) => ({
            toString() {
              const shown = apply(weakGet, originals, [this]);
              return apply(original, shown === undefined ? this : shown, []);
            },
          }).toString);
          const toStringWrapper = Function.prototype.toString;
          if (toStringWrapper !== originalToString) apply(weakSet, originals, [toStringWrapper, originalToString]);

          // --- Console ------------------------------------------------------
          let reporting = false;
          const consoleMessage = (type, args, stack) => {
            const described = [];
            for (let i = 0; i < args.length && i < 100; i++) push.call(described, describe(args[i]));
            report('c' + stringify({ type, args: described, timestamp: now(), frames: callFrames(stack) }));
          };
          const counts = new MapRef(), timers = new MapRef();
          const labelOf = (args) => (args.length && args[0] !== undefined ? StringRef0(args[0]) : 'default');
          const elapsed = (label) => {
            const ms = perfNow() - apply(mapGet, timers, [label]);
            return label + ': ' + ms + ' ms';
          };
          // What V8 reports for each method (v8-console.cc): its type, and the
          // arguments when they are not the call's own.
          const consoleReport = (name, args) => {
            switch (name) {
            case 'warn': return ['warning', args];
            case 'group': return ['startGroup', args.length ? args : ['console.group']];
            case 'groupCollapsed': return ['startGroupCollapsed', args.length ? args : ['console.groupCollapsed']];
            case 'groupEnd': return ['endGroup', ['console.groupEnd']];
            case 'clear': return ['clear', ['console.clear']];
            case 'assert': {
              if (args.length && args[0]) return null;
              const rest = apply(arraySlice, args, [1]);
              return ['assert', rest.length ? rest : ['console.assert']];
            }
            case 'count': {
              const label = labelOf(args);
              const count = (apply(mapGet, counts, [label]) || 0) + 1;
              apply(mapSet, counts, [label, count]);
              return ['count', [label + ': ' + count]];
            }
            case 'countReset': {
              const label = labelOf(args);
              if (apply(mapHas, counts, [label])) { apply(mapSet, counts, [label, 0]); return null; }
              return ['warning', ["Count for '" + label + "' does not exist"]];
            }
            case 'time': {
              const label = labelOf(args);
              if (apply(mapHas, timers, [label])) return ['warning', ["Timer '" + label + "' already exists"]];
              apply(mapSet, timers, [label, perfNow()]);
              return null;
            }
            case 'timeLog': case 'timeEnd': {
              const label = labelOf(args);
              if (!apply(mapHas, timers, [label])) return ['warning', ["Timer '" + label + "' does not exist"]];
              const text = elapsed(label);
              if (name === 'timeEnd') { apply(mapDelete, timers, [label]); return ['timeEnd', [text]]; }
              const rest = apply(arraySlice, args, [1]);
              return ['log', [text, ...rest]];
            }
            default: return [name, args];
            }
          };
          const consoleObject = console;
          const methods = ['log', 'debug', 'info', 'warn', 'error', 'dir', 'dirxml', 'table', 'trace', 'clear',
                           'group', 'groupCollapsed', 'groupEnd', 'assert', 'count', 'countReset', 'time', 'timeLog', 'timeEnd'];
          for (const name of methods) {
            replace(consoleObject, name, (original) => ({
              [name](...args) {
                if (!reporting) {
                  reporting = true;
                  try {
                    const message = consoleReport(name, args);
                    if (message) consoleMessage(message[0], message[1], new ErrorRef().stack);
                  } catch (e) {} finally { reporting = false; }
                }
                return apply(original, this, args);
              },
            })[name]);
          }

          // --- Exceptions -----------------------------------------------------
          const exceptionReport = (kind, value, fallback) => {
            const exception = describe(value);
            const details = { text: kind, exception, frames: [] };
            if (value !== null && (typeof value === 'object' || typeof value === 'function') && isError(value)) {
              exception.subtype = 'error';
              let name = '', message = '';
              try { name = StringRef0(value.name); } catch (e) {}
              try { message = StringRef0(value.message); } catch (e) {}
              let stack;
              try { stack = value.stack; } catch (e) {}
              details.frames = callFrames(stack);
              details.name = name;
              details.message = message;
              details.isError = true;
            }
            if (fallback) { details.url = fallback.url; details.line = fallback.line; details.column = fallback.column; }
            return details;
          };
          let nextExceptionKey = 1;
          const rejections = new WeakMapRef();
          const onError = (event) => {
            if (!(event instanceof ErrorEventRef)) return;
            try {
              let value = event.error;
              const place = { url: StringRef0(event.filename || ''), line: event.lineno || 0, column: event.colno || 0 };
              let details;
              if (value === undefined || value === null) {
                // A muted error from a script of another origin ("Script error.").
                details = { text: StringRef0(event.message || 'Uncaught'), frames: [], url: place.url, line: place.line, column: place.column };
              } else {
                details = exceptionReport('Uncaught', value, place);
              }
              details.timestamp = now();
              report('x' + stringify(details));
            } catch (e) {}
          };
          const onRejection = (event) => {
            try {
              const details = exceptionReport('Uncaught (in promise)', event.reason, null);
              details.timestamp = now();
              const key = nextExceptionKey++;
              details.key = key;
              if (event.promise) apply(weakSet, rejections, [event.promise, key]);
              report('x' + stringify(details));
            } catch (e) {}
          };
          const onRejectionHandled = (event) => {
            try {
              const key = event.promise ? apply(weakGet, rejections, [event.promise]) : undefined;
              if (key !== undefined) report('r' + stringify({ key, timestamp: now() }));
            } catch (e) {}
          };
          listen.call(window, 'error', onError, true);
          listen.call(window, 'unhandledrejection', onRejection, true);
          listen.call(window, 'rejectionhandled', onRejectionHandled, true);

          // --- Requests -----------------------------------------------------
          const requestPrefix = now().toString(36) + '.' + Math.random().toString(36).slice(2, 8) + '.';
          let nextRequest = 1;
          const standardMethods = ['DELETE', 'GET', 'HEAD', 'OPTIONS', 'POST', 'PUT'];
          const normalizedMethod = (method) => {
            const text = StringRef0(method);
            const upper = apply(toUpper, text, []);
            for (const m of standardMethods) if (m === upper) return upper;
            return text;
          };
          const absolute = (url) => {
            try { return new URLRef(StringRef0(url), doc.baseURI).href; } catch (e) { return StringRef0(url); }
          };
          const headersObject = (headers) => {
            const out = {};
            if (!headers) return out;
            try {
              if (HeadersRef && headers instanceof HeadersRef) {
                headers.forEach((value, name) => { out[name] = value; });
              } else if (isArrayRef(headers)) {
                for (const pair of headers) if (pair && pair.length >= 2) out[StringRef0(pair[0])] = StringRef0(pair[1]);
              } else if (typeof headers === 'object') {
                for (const name of objectKeys(headers)) out[name] = StringRef0(headers[name]);
              }
            } catch (e) {}
            return out;
          };
          // A body longer than the limit is left out rather than cut: a cut
          // one would read as the whole body to a large `maxPostDataSize`.
          const bodyFields = (body, fields) => {
            if (body === undefined || body === null) return;
            fields.hasPostData = true;
            try {
              let text;
              if (typeof body === 'string') text = body;
              else if (URLSearchParamsRef && body instanceof URLSearchParamsRef) text = StringRef0(body);
              if (text !== undefined && text.length <= STRING_LIMIT) fields.postData = text;
            } catch (e) {}
          };
          const mimeOf = (contentType) => {
            if (!contentType) return '';
            return apply(trim, apply(toLower, apply(split, StringRef0(contentType), [';'])[0], []), []);
          };
          const requestReport = (id, type, url, method, headers, body, stack) => {
            const fields = { id, type, url, method, headers, timestamp: now(), doc: doc.URL, frames: callFrames(stack) };
            bodyFields(body, fields);
            report('q' + stringify(fields));
          };

          if (typeof window.fetch === 'function') {
            replace(window, 'fetch', (original) => ({
              fetch(input, init) {
                let id = null;
                try {
                  id = requestPrefix + nextRequest++;
                  let url, method = 'GET', headers = {}, body;
                  if (RequestRef && input instanceof RequestRef) {
                    url = input.url; method = input.method; headers = headersObject(input.headers);
                  } else {
                    url = absolute(input);
                  }
                  if (init && typeof init === 'object') {
                    if (init.method !== undefined && init.method !== null) method = normalizedMethod(init.method);
                    if (init.headers !== undefined) headers = headersObject(init.headers);
                    body = init.body;
                  }
                  requestReport(id, 'Fetch', url, method, headers, body, new ErrorRef().stack);
                } catch (e) { id = null; }
                const promise = apply(original, this, arguments);
                if (id === null) return promise;
                return apply(PromiseThen, promise, [(response) => {
                  try {
                    const headers = headersObject(response.headers);
                    report('s' + stringify({ id, type: 'Fetch', url: response.url, status: response.status,
                                             statusText: response.statusText, headers,
                                             mimeType: mimeOf(response.headers.get('content-type')), timestamp: now() }));
                  } catch (e) {}
                  return response;
                }, (error) => {
                  try {
                    const aborted = !!error && error.name === 'AbortError';
                    report('f' + stringify({ id, type: 'Fetch', canceled: aborted,
                                             errorText: aborted ? 'net::ERR_ABORTED' : 'net::ERR_FAILED', timestamp: now() }));
                  } catch (e) {}
                  throw error;
                }]);
              },
            }).fetch);
          }

          const XHR = typeof XMLHttpRequest === 'function' ? XMLHttpRequest.prototype : null;
          if (XHR) {
            const states = new WeakMapRef();
            const stateOf = (xhr) => apply(weakGet, states, [xhr]);
            replace(XHR, 'open', (original) => ({
              open(method, url) {
                const result = apply(original, this, arguments);
                try {
                  const previous = stateOf(this);
                  if (previous && previous.current) previous.current.end('abort');
                  apply(weakSet, states, [this, { method: normalizedMethod(method), url: absolute(url), headers: {}, current: null }]);
                } catch (e) {}
                return result;
              },
            }).open);
            replace(XHR, 'setRequestHeader', (original) => ({
              setRequestHeader(name, value) {
                const result = apply(original, this, arguments);
                try {
                  const state = stateOf(this);
                  if (state) {
                    const key = StringRef0(name);
                    state.headers[key] = key in state.headers ? state.headers[key] + ', ' + StringRef0(value) : StringRef0(value);
                  }
                } catch (e) {}
                return result;
              },
            }).setRequestHeader);
            replace(XHR, 'send', (original) => ({
              send(body) {
                try {
                  const state = stateOf(this);
                  if (state) {
                    const xhr = this;
                    const id = requestPrefix + nextRequest++;
                    let responded = false;
                    const respond = () => {
                      if (responded || xhr.readyState < 2) return;
                      responded = true;
                      const headers = {};
                      try {
                        for (const line of apply(split, StringRef0(xhr.getAllResponseHeaders() || ''), ['\r\n'])) {
                          const colon = apply(indexOf, line, [':']);
                          if (colon > 0) headers[apply(slice, line, [0, colon])] = apply(trim, apply(slice, line, [colon + 1]), []);
                        }
                      } catch (e) {}
                      report('s' + stringify({ id, type: 'XHR', url: xhr.responseURL || state.url, status: xhr.status,
                                               statusText: xhr.statusText, headers,
                                               mimeType: mimeOf(xhr.getResponseHeader('content-type')), timestamp: now() }));
                    };
                    const events = ['readystatechange', 'load', 'error', 'abort', 'timeout'];
                    const request = {
                      end(how) {
                        if (state.current !== request) return;
                        state.current = null;
                        for (const type of events) unlisten.call(xhr, type, handle);
                        if (how === 'load') {
                          respond();
                          report('d' + stringify({ id, timestamp: now() }));
                        } else {
                          report('f' + stringify({ id, type: 'XHR', canceled: how === 'abort',
                                                   errorText: how === 'abort' ? 'net::ERR_ABORTED' : how === 'timeout' ? 'net::ERR_TIMED_OUT' : 'net::ERR_FAILED',
                                                   timestamp: now() }));
                        }
                      },
                    };
                    const handle = (event) => {
                      try {
                        if (event.type === 'readystatechange') {
                          if (xhr.readyState >= 2 && xhr.status !== 0) respond();
                        } else {
                          request.end(event.type);
                        }
                      } catch (e) {}
                    };
                    state.current = request;
                    for (const type of events) listen.call(xhr, type, handle);
                    requestReport(id, 'XHR', state.url, state.method, state.headers, body, new ErrorRef().stack);
                  }
                } catch (e) {}
                return apply(original, this, arguments);
              },
            }).send);
          }

          // --- Teardown -------------------------------------------------------
          const stop = () => {
            unlisten.call(doc, TOKEN + ':probe', onProbe);
            unlisten.call(doc, TOKEN + ':stop', stop);
            unlisten.call(window, 'error', onError, true);
            unlisten.call(window, 'unhandledrejection', onRejection, true);
            unlisten.call(window, 'rejectionhandled', onRejectionHandled, true);
            for (let i = replaced.length - 1; i >= 0; i--) {
              const { target, key, wrapper, descriptor } = replaced[i];
              try {
                const current = getDescriptor(target, key);
                if (current && current.value === wrapper) defineProperty(target, key, descriptor);
              } catch (e) {}
            }
          };
          const onProbe = (event) => { event.preventDefault(); };
          listen.call(doc, TOKEN + ':probe', onProbe);
          listen.call(doc, TOKEN + ':stop', stop);
        })();
        """#

    private static let isolatedTemplate = #"""
        (() => {
          const TOKEN = '__TOKEN__';
          const LIMIT = __STORED_LIMIT__;
          const existing = window.__detourDebuggerInstrumentation;
          if (existing && existing.token === TOKEN) return;
          const post = (message) => {
            try { window.webkit.messageHandlers.__HANDLER__.postMessage(message); } catch (e) {}
          };
          // Console and exception reports this document has made, for a
          // later Runtime.enable; network reports made before the state is
          // known (the first moments of a document), for Network.enable.
          const stored = [];
          let early = [];
          let consoleOn = false, networkOn = false, known = false, networkSince = 0;
          let queue = [], scheduled = false;
          const flush = () => {
            scheduled = false;
            const events = queue;
            queue = [];
            if (events.length) post({ token: TOKEN, events });
          };
          const send = (text) => {
            queue.push(text);
            if (!scheduled) { scheduled = true; queueMicrotask(flush); }
          };
          const onReport = (event) => {
            const text = event.detail;
            if (typeof text !== 'string' || !text) return;
            const kind = text[0];
            if (kind === 'c' || kind === 'x' || kind === 'r') {
              stored.push(text);
              if (stored.length > LIMIT) stored.shift();
              if (consoleOn) send(text);
            } else if (networkOn) {
              send(text);
            } else if (!known) {
              early.push(text);
              if (early.length > LIMIT) early.shift();
            }
          };
          document.addEventListener(TOKEN, onReport);

          // Requests the page half does not wrap: scripts, style sheets,
          // images, frames, beacons… — from resource timing, after they load,
          // without a status (WebKit's entries have no `responseStatus`).
          const timeOrigin = performance.timeOrigin;
          const fromEntry = (entry) => {
            const type = entry.initiatorType;
            if (type === 'fetch' || type === 'xmlhttprequest') return;
            return 't' + JSON.stringify({
              url: entry.name, initiatorType: type, doc: document.URL,
              start: timeOrigin + entry.startTime, end: timeOrigin + entry.responseEnd,
              transferSize: entry.transferSize || 0,
            });
          };
          let observer = null;
          try {
            observer = new PerformanceObserver((list) => {
              for (const entry of list.getEntries()) {
                if (entry.startTime < networkSince) continue;
                const text = fromEntry(entry);
                if (text) onReport({ detail: text });
              }
            });
            observer.observe({ type: 'resource', buffered: true });
          } catch (e) {}
          // A request that failed before any response leaves no timing entry,
          // only the element's error event.
          const onLoadError = (event) => {
            const target = event.target;
            if (!target || target === window || target.nodeType !== 1 || event instanceof ErrorEvent) return;
            let url = target.currentSrc || target.src || target.href;
            if (typeof url !== 'string' || !url) return;
            try { if (performance.getEntriesByName(url, 'resource').length) return; } catch (e) {}
            onReport({ detail: 'e' + JSON.stringify({ url, tag: String(target.localName || ''), doc: document.URL, at: Date.now() }) });
          };
          window.addEventListener('error', onLoadError, true);
          // The document's own request is finished once the parser has its
          // whole body.
          const onContentLoaded = () => {
            let transferSize = 0;
            try {
              const entry = performance.getEntriesByType('navigation')[0];
              if (entry) transferSize = entry.transferSize || 0;
            } catch (e) {}
            onReport({ detail: 'n' + JSON.stringify({ at: Date.now(), transferSize }) });
          };
          if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', onContentLoaded, { once: true });
          // Back from the back/forward cache: with the session over (its
          // handler gone) the halves come out; otherwise native is told the
          // document is current again, and answers with the state — or, for
          // a later session, replaces these halves with its own.
          const onPageShow = (event) => {
            if (!event.persisted) return;
            let handler;
            try { handler = window.webkit.messageHandlers.__HANDLER__; } catch (e) {}
            if (!handler) { instrumentation.stop(); return; }
            post({ token: TOKEN, hello: true });
          };
          window.addEventListener('pageshow', onPageShow);

          const instrumentation = {
            token: TOKEN,
            setState(consoleEnabled, networkEnabled) {
              const consoleWasOn = consoleOn;
              consoleOn = !!consoleEnabled;
              if (networkEnabled && !networkOn) {
                networkSince = known ? performance.now() : 0;
                for (const text of early) send(text);
              }
              early = [];
              networkOn = !!networkEnabled;
              known = true;
              // Runtime.enable replays what the document logged, as V8 does.
              if (consoleOn && !consoleWasOn) for (const text of stored) send(text);
            },
            discard() { stored.length = 0; },
            stop() {
              document.dispatchEvent(new CustomEvent(TOKEN + ':stop'));
              document.removeEventListener(TOKEN, onReport);
              window.removeEventListener('error', onLoadError, true);
              window.removeEventListener('pageshow', onPageShow);
              document.removeEventListener('DOMContentLoaded', onContentLoaded);
              if (observer) observer.disconnect();
              consoleOn = networkOn = false;
              stored.length = 0;
              early = [];
              queue = [];
              if (window.__detourDebuggerInstrumentation === instrumentation) delete window.__detourDebuggerInstrumentation;
            },
          };
          window.__detourDebuggerInstrumentation = instrumentation;
          post({ token: TOKEN, hello: true });
        })();
        """#
}
