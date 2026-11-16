---
type: Feature
title: chrome.permissions for history and management
description: How the polyfill's chrome.permissions wrappers answer request, contains and remove for history and management, which WebKit refuses as unknown names — Chrome's request rule, Detour's prompt, and the mixed request that must keep WebKit's user gesture.
tags: [extensions, polyfill, permissions]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T10:06:25Z }
sources:
  - id: polyfill
    resource: ../../Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
    title: ExtensionAPIPolyfill.swift (the permissions wrappers, callOutsideWebKit)
  - id: handler
    resource: ../../Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
    title: ExtensionPolyfillHandler.swift (permissionRequestPlan, permissionRemovalRefusal)
  - id: extension-manager
    resource: ../../Detour/Extensions/Runtime/ExtensionManager.swift
    title: ExtensionManager.swift (promptUserForPermission, setPermissionDecision)
  - id: web-extension
    resource: ../../Detour/Extensions/Model/WebExtension.swift
    title: WebExtension.swift (permissionsOutsideWebKit)
  - id: task-260
    resource: backlog:TASK-260
    title: "Extensions: chrome.permissions.request, contains and remove do not work for history and management"
  - id: history-scope-tests
    resource: ../../DetourTests/ExtensionHistoryScopeTests.swift
    title: ExtensionHistoryScopeTests
---
WebKit refuses `history` and `management` in its own `permissions.request`,
`contains` and `remove`, because it does not implement them, so the polyfill
answers for those two names itself. Whether the permission is active is the
[request gates](./polyfill-request-gates.md#the-active-permission-rule) rule;
this page is how the `chrome.permissions` calls read and change it.

# The wrappers

The polyfill's `chrome.permissions` / `browser.permissions` wrappers (the
same ones that [strip origin ports](./permissions.md#origin-patterns-with-a-port),
`permissionsOriginPortJS`) take `history`
and `management` (`WebExtension.permissionsOutsideWebKit`) out of
`details.permissions`; the handler answers for them and the rest of the call
still goes to WebKit.[^task-260]

- `contains` answers from `permissionIsActive`; an undeclared name answers
  false, as in Chrome. A mixed call is true only when Detour's names and
  WebKit's part all hold.
- `request` follows Chrome's rule (`permissionRequestPlan`): a name in
  neither manifest list is refused ("Only permissions specified in the
  manifest may be requested."); a required one is held already; a denied
  one, or a required one switched off, answers false without a prompt, as
  WebKit answers for a permission it holds denied (only the Settings switch
  turns it back on); the rest get Detour's prompt, the same alert and
  wording as WebKit's (`promptUserForPermission`), answerable through
  `permissionPromptAnswerOverride`. The answer is saved through
  `setPermissionDecision`, so it reaches every loaded context, is restored at
  load and posts `permissionDecisionsDidChangeNotification`. A second request
  while the prompt is pending is refused ("A permissions request is already
  pending."), like [`uninstallSelf`](./polyfill-management.md#uninstallself)'s confirmation. Unlike that
  confirmation it needs no cooldown after a refusal: the saved denial already
  stops the next request from asking.
- `remove` refuses a required name ("You cannot remove required
  permissions.") or an undeclared one ("Only permissions specified in the
  manifest may be removed."; `permissionRemovalRefusal`), then deletes the
  saved grant and re-applies, as for
  [WebKit's own removals](./permissions.md#the-extensions-own-permissionsremove):
  the row is deleted, not saved as denied, so the next request prompts
  again. In a mixed call Detour's names are checked first, WebKit removes
  the rest, and only then are Detour's names removed.

**WebKit requires a user gesture for its own `permissions.request`**
("Invalid call to permissions.request(). Must be called during a user
gesture.", measured: refused from a service worker, and from a page once an
await has passed; `callAsyncJavaScript` counts as a gesture). So a mixed
request (`['history', 'notifications']`) calls WebKit first, synchronously
inside the caller's gesture, and asks Detour only after WebKit grants. If
Detour's prompt is then denied, the wrapper takes back with WebKit's
`remove` exactly what the request added (each WebKit item is asked about
with `contains` before the request), so the request is granted whole or not
at all, as in Chrome. The extension does see `onAdded` then `onRemoved` for
the taken-back items. Asking Detour first was rejected: WebKit's half then
always failed for want of a gesture. From a worker a mixed request is
refused by WebKit before anyone is asked.

Detour does not require a gesture for `history` / `management`: the handler
gets no gesture signal, a worker has none, and a check in the polyfill would
be the extension's own code to skip. The prompt is the guard.

# Gaps

- A request made past the wrapper, straight to WebKit's function (the
  `_detourNative` the wrapper keeps), still gets WebKit's "'history' is not a
  valid permission".
- A mixed request whose Detour half is denied fires `permissions.onAdded`
  and `onRemoved` for the WebKit items it took back.[^task-260]
- A mixed request whose Detour half will be answered false without a
  prompt (the name is denied, or required and switched off) still shows
  WebKit's prompt first, and takes that grant back afterwards. Knowing the
  Detour answer first takes a native round trip, which would spend the user
  gesture WebKit requires.[^task-260]

# Tests

`permissions.request` / `contains` / `remove` of `history` and `management`
from a real context: `ExtensionHistoryScopeTests` (section 7).

# Related

- [Polyfill request gates](./polyfill-request-gates.md) — `permissionIsActive`, which `contains` answers from and `request` plans with.
- [Permissions](./permissions.md) — saved decisions, the restore and the Settings switches a grant or removal goes through; the same wrappers' origin-port rewrite.
- [chrome.management](./polyfill-management.md) — the `uninstallSelf` confirmation whose pending-request rule `request` shares.
- [Chrome runtime patching](./chrome-runtime-patching.md) — how the `permissions` wrappers stay in place.

[^task-260]: Extensions: chrome.permissions.request, contains and remove do not work for history and management
