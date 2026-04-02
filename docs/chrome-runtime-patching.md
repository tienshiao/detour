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

### Option 2: Replace chrome itself with a Proxy

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

### Bottom line

The Proxy approach (Option 2) is the only reliable way to intercept everything uniformly, since
the patchability of any given property depends on its IDL attributes.
