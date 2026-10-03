---
id: TASK-132
title: 'Epic: support the Claude extension (side panel, tab groups, chrome.debugger)'
status: To Do
assignee: []
created_date: '2026-10-03 23:06'
updated_date: '2026-10-03 23:09'
labels: []
dependencies: []
priority: medium
ordinal: 132000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Make Anthropic's Claude extension (Chrome Web Store id fcoeoabgfenejglbffodgkkbkcdhcgfn, reviewed at version 1.0.98) install, sign in and drive pages in Detour.

**Branch:** all work for this epic lands on the epic branch `epic-claude-extension`, not on main. The branch starts from the main commit that added these Backlog tasks; the tasks themselves were committed to main first so task numbers cannot collide. Subtask branches/worktrees branch from and merge back into it.

**Product decisions (user, 2026-10-03):**
- Tab groups get a colour stripe on member rows first; header rows / collapse / drag come later.
- Claude must be able to drive tabs that are not selected (screenshots and input on background tabs), from the first version.
- A space per tab group was rejected: opening the panel groups the current tab at once, which would move it to another space.

**What the extension uses (from its 1.0.98 bundle; a copy is in ~/Library/Application Support/Google/Chrome/Default/Extensions/<id>/):**
- Manifest permissions: sidePanel, storage, activeTab, scripting, debugger, tabGroups, tabs, alarms, notifications, webNavigation, declarativeNetRequestWithHostAccess, offscreen, nativeMessaging, unlimitedStorage, downloads, identity; host <all_urls>; externally_connectable for claude.ai; command toggle-side-panel (Cmd+E); no action popup.
- sidePanel.setOptions({tabId, path: 'sidepanel.html?tabId=N', enabled}) + sidePanel.open({tabId}) from action.onClicked and the command. With chrome.sidePanel undefined it posts a 'Browser not supported' notification and stops.
- tabs.group / tabs.ungroup, tabGroups.get/query/update, tabGroups.Color, TAB_GROUP_ID_NONE, tab.groupId, tabs.query({groupId}). One group per session; tools only act on tabs in the group.
- chrome.debugger attach/detach/getTargets/sendCommand/onEvent/onDetach with CDP: Page.enable, Page.captureScreenshot, Page.handleJavaScriptDialog, Input.dispatchMouseEvent, Input.dispatchKeyEvent, Input.insertText, Runtime.enable, Runtime.evaluate, Network.enable/disable; events Page.javascriptDialogOpening, Page.frameNavigated, Runtime.consoleAPICalled, Runtime.exceptionThrown, Network.requestWillBeSent/responseReceived/loadingFailed.
- runtime.getContexts + runtime.ContextType.SIDE_PANEL, runtime.onMessageExternal (sign-in), identity.getRedirectURL/launchWebAuthFlow, declarativeNetRequest.updateSessionRules (modifyHeaders), downloads.download/search/onChanged, tabs.create({url: 'chrome://newtab'}), windows.create({type: 'popup'}), connectNative to com.anthropic.claude_browser_extension and com.anthropic.claude_code_browser_extension.

**WebKit facts found during the review:**
- The installed WebKit (macOS 26.7) has private _WKWebExtensionSidebar and -[WKWebExtensionContext sidebarForTab:]; WebKit main gates chrome.sidePanel on the WebExtensionSidebarEnabled preference (default false) plus the sidePanel permission.
- WebKit vends no tabs.group/ungroup, tabGroups, debugger, identity, downloads or runtime.getContexts.
- WebKit gives externally_connectable web pages a `browser` global only, never `chrome`.
- No polyfill handler today resolves a WebKit tabId to a BrowserTab.

See docs/extensions.md and docs/chrome-runtime-patching.md for the polyfill rules (never replace the chrome/browser globals; patch members in place and root the wrapper).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Every subtask of this epic is Done or explicitly dropped with a reason
- [ ] #2 The Claude extension installs from the Chrome Web Store, signs in, opens its side panel and completes a multi-tab task in a signed build
- [ ] #3 docs/extensions.md describes side panel, tab groups and debugger support and their limits
<!-- AC:END -->
