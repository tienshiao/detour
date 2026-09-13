# Chrome Runtime Patching in WebKit

## Root Cause: Weak JS Wrapper Cache

The binding architecture works like this:

1. `chrome`/`browser` are set on the global object once per frame in
   `WebExtensionControllerProxyCocoa.mm:94` with `kJSPropertyAttributeNone` (writable,
   configurable). The namespace C++ object is created once and its JS wrapper is strongly held
   by the global property.
2. `chrome.runtime` is a JSStaticValue getter on the namespace's class definition (from the IDL at
   `WebExtensionAPINamespace.idl:55` — note it's NOT MainWorldOnly or Dynamic). Every time you
   access `chrome.runtime`, the getter runs:
   - Calls `WebExtensionAPINamespace::runtime()` (`WebExtensionAPINamespaceCocoa.mm:233`) —
     returns the same C++ `m_runtime` object every time
   - Wraps it via `JSWebExtensionWrapper::wrap()` (`JSWebExtensionWrapper.cpp:449`) — looks up a
     `JSWeakObjectMapRef` cache
3. `getURL` is a JSStaticFunction on the runtime class definition (from
   `WebExtensionAPIRuntime.idl:33`), bound to the native C++ method at
   `WebExtensionAPIRuntimeCocoa.mm:172`.

The problem: When you do `chrome.runtime.getURL = myFunc`, you:
1. Access `chrome.runtime` — static value getter returns the JS wrapper from the weak cache
2. Set an own property `getURL` on that wrapper — this correctly shadows the native static function

But the JS wrapper for the runtime object is only weakly referenced in the `JSWeakObjectMapRef`
(`JSWebExtensionWrapper.cpp:467`). Nothing else holds a strong JS reference to it. When GC runs
(which commonly happens around event dispatch boundaries), the wrapper is collected. The next
access to `chrome.runtime` creates a fresh wrapper for the same C++ object — without your
monkey-patch.

## Workarounds

### Option 1: Pin the patched wrapper as an own property on chrome (most robust)

```js
// Capture the runtime wrapper and patch it
const runtime = chrome.runtime;
const originalGetURL = runtime.getURL.bind(runtime);
runtime.getURL = function(path) {
    // Your custom implementation
    return originalGetURL(path);
};

// Replace the static value getter with an own property.
// Own properties take precedence over JSStaticValue getters.
Object.defineProperty(chrome, 'runtime', {
    value: runtime,
    writable: false,
    configurable: true,
    enumerable: true
});
// Now `chrome.runtime` returns the pinned, patched wrapper
// instead of calling the native getter each time.
```

This works because:
- `Object.defineProperty` creates an own property on the `chrome` object, which shadows the
  class's JSStaticValue getter
- The runtime wrapper is now strongly referenced by the own property, so GC won't collect it
- Your `getURL` own property on the wrapper persists

### Option 2: Replace chrome itself with a Proxy — DO NOT USE (breaks messaging)

**Broken in service workers, and any other extension page (TASK-15, 2026-09-11).** WebKit's
runtime-message dispatcher (`WebExtensionContextProxy::enumerateFramesAndNamespaceObjects`) reads
the `browser` global, then `chrome`, from each extension frame or worker and unwraps it with
`toWebExtensionAPINamespace` to reach the native `onMessage` listener list. A Proxy (or any other
stand-in) fails the unwrap, so the frame is skipped, no listener "handles" the message, and
`internalDispatchRuntimeMessageEvent` sends the sender the empty default reply: every
`runtime.sendMessage` to that context resolves `undefined` with no `lastError`. This is what took
down 1Password's popup ("Oops, something went wrong while loading"). Kept here only as a record of
why the polyfill must never reassign `globalThis.chrome` / `globalThis.browser`;
`ExtensionPolyfillIntegrationTests.testRuntimeSendMessageReachesWorkerRunningThePolyfill` guards it.

```js
const patchedRuntime = chrome.runtime;
patchedRuntime.getURL = function(path) { /* ... */ };

window.chrome = new Proxy(chrome, {
    get(target, prop) {
        if (prop === 'runtime') return patchedRuntime;
        return target[prop];
    }
});
window.browser = window.chrome;
```

### Option 3: Intercept at a higher level

If you control the extension loading (since you're building the browser), you could inject a
WKUserScript at document-start that runs before extension code and sets up the patches using
Option 1.

---

Option 1 is the cleanest for regular (non-Dynamic, non-MainWorldOnly) members. The key insight is
that you need to prevent `chrome.runtime` from going through the native static value getter on
every access, because that getter returns a weakly-cached wrapper that can be GC'd, losing your
patches. Pinning the wrapper as an own property on chrome solves both problems at once.

---

## Caveat: [MainWorldOnly] and [Dynamic] members

Option 1 (pinning) does **not** work for `setUninstallURL` and other members marked
`[MainWorldOnly]` or `[Dynamic]` in the WebKit IDL.

These members are not in the JSStaticFunction table. Instead they are served through the class's
`getProperty` callback. In JSC, when a class's `hasProperty` returns true, the `getProperty`
callback is called and its result is used — even if there is an own property on the object. The
class callback takes precedence over own properties for class-backed objects.

### Why pinning fails for [MainWorldOnly] members

`setUninstallURL` is marked `[MainWorldOnly]` in the IDL:

    if (isForMainWorld && JSStringIsEqualToUTF8CString(propertyName, "setUninstallURL"))
        return JSObjectMakeFunctionWithCallback(context, propertyName, setUninstallURL);

And `hasProperty` returns true:

    if (JSStringIsEqualToUTF8CString(propertyName, "setUninstallURL"))
        return isForMainWorld;

So even if you pin the runtime wrapper and set `runtime.setUninstallURL = myFunc`, JSC bypasses
your own property and calls the native `getProperty` callback every time.

## Unpatchable properties reference

### Level 1: Properties on `chrome` itself

From `WebExtensionAPINamespace.idl`, these use `getProperty` callbacks and **cannot** be patched
via own properties:

| Property              | Attributes             |
|-----------------------|------------------------|
| action                | MainWorldOnly, Dynamic |
| alarms                | MainWorldOnly, Dynamic |
| bookmarks             | MainWorldOnly, Dynamic |
| browserAction         | MainWorldOnly, Dynamic |
| commands              | MainWorldOnly, Dynamic |
| contextMenus          | MainWorldOnly, Dynamic |
| cookies               | MainWorldOnly, Dynamic |
| declarativeNetRequest | MainWorldOnly, Dynamic |
| devtools              | Dynamic                |
| menus                 | MainWorldOnly, Dynamic |
| notifications         | MainWorldOnly, Dynamic |
| pageAction            | MainWorldOnly, Dynamic |
| permissions           | MainWorldOnly          |
| scripting             | MainWorldOnly, Dynamic |
| sidebarAction         | MainWorldOnly, Dynamic |
| sidePanel             | MainWorldOnly, Dynamic |
| storage               | Dynamic                |
| tabs                  | MainWorldOnly          |
| test                  | Dynamic                |
| webNavigation         | MainWorldOnly, Dynamic |
| webRequest            | MainWorldOnly, Dynamic |
| windows               | MainWorldOnly          |

**Patchable** via own properties (regular static values): `dom`, `extension`, `i18n`, `runtime`.

### Level 2: [Dynamic] members within sub-APIs

Sub-APIs that are `[MainWorldOnly]` at the interface level have their members in static
function/value tables (patchable). But some have additional `[Dynamic]` members that use
`getProperty` callbacks:

- **chrome.runtime** — `getPlatformInfo`, `getBackgroundPage`, `setUninstallURL`,
  `openOptionsPage`, `reload`, `lastError`, `sendNativeMessage`, `connectNative`,
  `onConnectExternal`, `onMessageExternal`, `onStartup`, `onInstalled`
- **chrome.extension** �� `getURL` (Dynamic), `getBackgroundPage`, `getViews`,
  `isAllowedIncognitoAccess`, `isAllowedFileSchemeAccess` (MainWorldOnly)
- **chrome.storage** — `session` (Dynamic)
- **chrome.storageArea** (local/sync/session) — `setAccessLevel` (Dynamic+MainWorldOnly),
  `QUOTA_BYTES_PER_ITEM`, `MAX_ITEMS`, `MAX_WRITE_OPERATIONS_PER_HOUR`,
  `MAX_WRITE_OPERATIONS_PER_MINUTE` (all Dynamic)
- **chrome.declarativeNetRequest** — `onRuleMatchedDebug` (Dynamic)
- **chrome.windows** — `create`, `update`, `remove` (Dynamic)
- **chrome.tabs** — `getSelected`, `executeScript`, `insertCSS`, `removeCSS` (Dynamic)

### Level 3: members that re-materialize on every read (probed 2026-09-11, module service worker)

`chrome.runtime.connectNative` is reported as an own property, and both assignment and
`Object.defineProperty` on it complete without throwing, but every read returns a freshly created
native function: the read-back equals neither the value just written nor the previous read. There
is no JS-side way to wrap it. Assume the same for the other `[Dynamic]` runtime members listed
above. The native-port keep-alive stopped trying: it now only *calls* `connectNative` to open its
port and Detour tells it when to ping, since the native side knows when a real host is connected
(TASK-16; `ExtensionAPIPolyfill.nativePortKeepAliveJS` reports `installMode: 'port'` in a worker
whose manifest declares `nativeMessaging`, and `'none'` / `'no-nativeMessaging-permission'`
otherwise — an extension that cannot open a native port has nothing to keep alive).

`chrome.runtime.lastError` is unwritable the same way (probed 2026-09-12, TASK-23, in both an
extension page and a module service worker, with `chrome.runtime` already pinned). It reports as
an own data property `{ value: null, writable: false, configurable: true, enumerable: false }`,
and `Object.defineProperty` (with a getter or a value), plain assignment and `delete` all complete
without throwing, yet every read keeps returning `null` and the descriptor never changes. So the
"only if configurable" check is not enough on its own: a write has to be verified by reading it
back. WebKit's own callbacks do set it: inside a failing native callback it is
`{ message: "Invalid call to <api>(). <reason>." }`, the callback gets no arguments, and it is
`null` again once the callback returns. The polyfill's callback wrappers (`__detourSettle` in
`ExtensionAPIPolyfill.preambleJS`) use exactly that: when a polyfilled API rejects and lastError
cannot be installed from JS, they bounce the message off Detour's polyfill host with the
callback form of `runtime.sendNativeMessage` (message type `runtime.lastErrorRelay`, which always
fails with the text it was given), and run the extension's callback from inside WebKit's callback.
The extension then sees `"Invalid call to runtime.sendNativeMessage(). <message>."`: WebKit's
prefix is the one visible difference from Chrome.

Pinning a *different* object under `chrome.runtime` (Option 1 with a proxy instead of the real
wrapper) is accepted by `defineProperty` but ignored on reads: the static getter keeps returning
the native runtime. Option 1 only works because it pins the *same* wrapper WebKit vends.

### Members inside a [MainWorldOnly, Dynamic] sub-namespace: patchable, but only while held

A member *inside* one of the Level 1 namespaces above (`chrome.action.getUserSettings`,
`chrome.webRequest.onAuthRequired`) can be patched in place — the wrapper takes the own property
and reads through `chrome.action` keep returning it, *as long as that wrapper is still alive*.
Two separate things are true of an own property on `chrome` for these namespaces, and they must
not be conflated:

- **Precedence.** While WebKit vends the namespace, the class's `getProperty` callback wins over an
  own property on `chrome`, so a pin cannot change *which* object a read returns (it hands back the
  wrapper from the same weak cache as `chrome.runtime`). When WebKit vends nothing — `chrome.webRequest`
  on macOS 26 — there is nothing to shadow and the own property is read normally, which is how the
  full `webRequest` stub works.
- **Lifetime.** A shadowed own property is still a strong JS reference, so it keeps the wrapper —
  and the weak cache entry — alive, and the callback keeps handing back the patched object. That is
  what `webNavigationJS`'s `Object.defineProperty(chrome, 'webNavigation', { value: nav })` does; it
  is load-bearing and must not be removed as a no-op.

Without any root the patch lives exactly as long as the wrapper does: the first garbage collection
collects it, the next read mints a fresh wrapper, and the member is gone with no error anywhere
(measured 2026-09-13, TASK-60 — the polyfill's `getUserSettings` disappeared after ~1M JS
allocations, and a `WeakRef` to the patched wrapper read back `undefined`).

Any strong reference works. The polyfill's shared form is `__detourHoldWrapper(name, wrapper)` in
`ExtensionAPIPolyfill.preambleJS`, which stores the wrapper in the non-enumerable, non-writable
`globalThis.__detourHeldWrappers` (so `__detourHeldWrappers.action === chrome.action` can be asserted,
and extension code enumerating or clearing globals cannot drop a root). `actionUserSettingsJS` and
the native-namespace path of `webRequestStubJS` root through it, then re-read the namespace and
check the patch is what it answers with; if not, they release the root and record
`polyfill-not-visible` / `native+onAuthRequired-not-visible` in `__detourPolyfillDiag.apis`.
`ExtensionPolyfillIntegrationTests.testActionGetUserSettingsSurvivesGarbageCollection` asserts the
root identity and forces a collection (churning garbage until a control `WeakRef` clears) to read
the API back afterwards.

### Bottom line

Patch members in place on the native wrappers where the IDL allows it (Option 1), accept that
`[Dynamic]`/`[MainWorldOnly]` members and re-materialized functions cannot be patched from JS, and
intercept those on the native side instead (delegate callbacks, `WKScriptMessageHandler`). Never
replace the `chrome`/`browser` globals: it silently disconnects the context from runtime messaging
(Option 2).
