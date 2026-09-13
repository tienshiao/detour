---
id: TASK-51
title: >-
  Extensions: make a presented Peek the extension-visible active tab while it is
  open
status: Done
assignee:
  - '@claude'
created_date: '2026-09-13 08:36'
updated_date: '2026-09-13 10:15'
labels:
  - extensions
  - peek
dependencies:
  - TASK-50
priority: medium
ordinal: 51000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Since TASK-50 a Peek tab is a registered, script-running tab of its window (listed by BrowserWindowController.extensionTabs, closable via tabs.remove), but it is never the active tab: BrowserWindowController.activeTab(for:) returns selectedTab (the host behind the overlay), and no didActivateTab path can resolve a peek — ExtensionTabObserver.dispatchActivated is driven by the tabActivatedNotification, which fires for the host. So while a peek is presented, tabs.query({active: true, currentWindow: true}) and toolbar popups name the host page, and an activeTab grant or a password manager fill targets the hidden host instead of the page the user is looking at. docs/split-tabs-design.md §12 'Follow-up: extensions in peek views' lists deciding active-tab semantics as the remaining open item (didOpenTab/didCloseTab and enumeration landed in TASK-50). Decide and implement: while the overlay is presented the peek is the window's active tab (activeTab(for:) returns it and didActivateTab fires with previousActiveTab = host); when the overlay hides, closes or expands to a real tab, activation reverts to the host (or moves to the expanded tab). Consider window focus changes and the split-pane case (selectedTabID is the focused pane).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 While a Peek overlay is presented, BrowserWindowController.activeTab(for:) returns the peek tab and the contexts receive didActivateTab(peek, previousActiveTab: host)
- [x] #2 Hiding or closing the overlay, and expanding the peek to a tab, re-activates the host (or the new tab) so tabs.query({active:true}) never names a hidden page
- [x] #3 The 1Password toolbar popup opened over a presented peek fills the peek page, not the host
- [x] #4 Unit tests cover present → activate peek, hide/close → re-activate host, expand → activate new tab, using the ExtensionTabLifecycle recording notifier
- [x] #5 docs/split-tabs-design.md §12 is updated to record the chosen active-tab semantics
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Semantics: while a Peek overlay is presented (peekOverlayView != nil and the host's peekTab has a web view) the peek is the window's extension-visible active tab; otherwise the selected tab (the focused pane of a split). selectedTabID is unchanged — it still names the focused pane/host.
2. BrowserWindowController.extensionActiveTab computes that; activeTab(for:) returns it; ExtensionPopoverController.show and ExtensionManager.notifyExistingTabs use it instead of selectedTab (audit other 'the page the user is looking at' uses of selectedTab in Detour/Extensions).
3. Activation announcements funnel through one window method (announceExtensionActiveTabIfChanged) that dedupes by identity against the last announced tab and calls ExtensionTabLifecycle.didActivate(tab, previousActiveTab:, in:) — the seam gains previousActiveTab and forwards it to didActivateTab. Called from selectTab (after members are woken/claimed so open precedes activate), pane focus (browserWebViewDidBecomeFirstResponder), presentPeekWebView (present/re-present/restore), closePeekOverlay; expand goes through selectTab(newTab). hidePeekUI announces nothing: every caller either selects another tab next or deselects all. The tabActivatedNotification / dispatchActivated path is replaced by the direct call. wakeIfNeeded keeps its explicit re-open + re-activate.
4. Tests: a small ExtensionActiveTabTracker (or equivalent) unit-tested with the recording notifier for present → peek activated with previous = host, close → host with previous = peek, same tab twice → one event, expand → new tab; plus the pure extensionActiveTab rule; plus a window-level test if BrowserWindowController can be built in the test host.
5. docs/split-tabs-design.md §12 follow-up records the chosen semantics.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Semantics: while a Peek overlay is presented the peek is the window's extension-visible active tab; selectedTabID still names the host/focused pane. BrowserWindowController.extensionActiveTab (pure rule extensionActiveTab(selected:peekPresented:)) backs activeTab(for:), ExtensionPopoverController.show and notifyExistingTabs. Activation announcements funnel through ExtensionActiveTabTracker (identity-deduped, weak last-announced) via announceExtensionActiveTabIfChanged(), called from selectTab (after members are woken and claimed), pane focus, presentPeekWebView, closePeekOverlay and deselectAllTabs; hidePeekUI announces nothing (a selection, deselection, window close or ownership loss always follows); expand hands over through the new tab's selection. The seam's didActivate now carries previousActiveTab. tabActivatedNotification / handleTabActivated / dispatchActivated were removed. Tests: ExtensionActiveTabTests (rule, tracker, and a real BrowserWindowController end-to-end present/close test); docs/split-tabs-design.md §12 updated.

Review fixes folded in: previousActiveTab is reported only when the previous tab is still registered with the same profile (a cross-profile space switch or an expanded peek would otherwise make WebKit resurrect it as a phantom tab); selectTab announces once at its end so switching onto a tab with a saved peek announces only the peek; wakeIfNeeded re-opens every woken split member but re-activates only the focused pane; deselectAllTabs hides the peek UI before clearing selectedTabID so the peek's script handler is unclaimed; BrowserTab.window(for:) prefers the window whose extensionActiveTab is the peek so isActive is computed against the presenting window; the API Explorer's tabs.onActivated logger shows previousTabId.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A presented Peek is now the tab extensions see as active: tabs.query({active:true}), toolbar popups and activeTab grants target the page under the overlay, and activation events carry the previous tab and revert to the host (or move to the expanded tab) when the overlay goes. Verified with ExtensionActiveTabTests, ExtensionTabLifecycleTests, PeekAnchorTests, SidebarVisibilityStateTests and WKExtensionIntegrationTests.
<!-- SECTION:FINAL_SUMMARY:END -->
