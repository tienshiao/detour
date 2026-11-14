---
id: TASK-330
title: >-
  Isolation: design Temporary Containers-style throwaway identities (automatic,
  per tab or per site, deleted when their tabs close)
status: To Do
assignee: []
created_date: '2026-11-14T20:20:00Z'
labels:
  - privacy
  - profiles
  - research
dependencies: []
references:
  - https://addons.mozilla.org/en-US/firefox/addon/temporary-containers/
  - wiki/architecture/profiles-and-spaces.md
  - wiki/architecture/incognito.md
  - wiki/features/quarantine.md
  - wiki/extensions/data-store-and-itp.md
  - TASK-194
priority: low
type: feature
ordinal: 404000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested 2026-11-14 by the user ("for another time", expected to be big). A friend relies on the Firefox add-on Temporary Containers. The user wants to know how Detour could offer that kind of isolation: in effect many small, short-lived profiles, so sites cannot follow you from tab to tab.

What the add-on does, as understood from its listing (confirm when researching): it opens new tabs in a fresh temporary container (its own cookies and site storage), either automatically for every new tab or on request. Isolation rules can move a navigation into a new container when it goes to another domain, or always for chosen sites, or when a link is middle- or Cmd-clicked. A container lasts while its tabs are open, and its data is deleted shortly after the last one closes. Some sites can be kept in permanent containers (with Multi-Account Containers), so logins survive where wanted.

Detour already has pieces that overlap:
- Profiles: each has its own persistent WKWebsiteDataStore(forIdentifier:), extensions and history, but they are heavy and long-lived.
- The Private profile: one shared .nonPersistent() store per Private session.
- Profile.isPerTabIsolation: every new web view gets its own .nonPersistent() store. The store dies with the web view, so a sleeping or relaunched tab is logged out. Extensions probably cannot see those tabs (suspected, not confirmed).
- Quarantine (TASK-194): a link opened in a throwaway Quick Detour window with a store of its own, then moved into a profile on purpose.

The design has to answer what is missing between these (lifetime tied to tabs rather than web views, automatic rules, per-site rules, cleanup), and how this fits the Profile / Space model rather than becoming a third concept beside them.

Known constraints to check rather than assume:
- About 190 data stores have exhausted WebKit's network process in the test host (errno 12); see the full-run test clusters notes. Per-tab stores at browsing scale may hit the same limit.
- A persistent store per container (forIdentifier + WKWebsiteDataStore.remove(forIdentifier:) at cleanup) would survive sleep and relaunch, but costs disk and cleanup bookkeeping. A crash must not leave stores behind forever.
- Extensions are per profile (WKWebExtensionController). Whether 1Password and other extensions work in tabs on a different store decides whether this is usable day to day.
- History, session restore, Reopen Closed Tab, splits, Peek and Quick Detour all have to say which container a tab is in.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A design document in docs/ compares the add-on's features with Detour's existing isolation (profiles, Private, per-tab isolation, quarantine) and proposes how temporary identities fit the Profile / Space model, with rejected alternatives
- [ ] #2 WebKit limits are measured, not assumed: how many data stores one app can keep alive (memory, network-process limit), store lifetime across sleep and relaunch, and how cleanup (remove(forIdentifier:)) behaves, with the spike checked into docs/harness
- [ ] #3 Extension behaviour in tabs on a separate store is measured with at least a content-script extension and 1Password (whether content scripts, popups and messaging reach those tabs)
- [ ] #4 The UX is proposed: how a tab gets a temporary identity (automatic, per site, per click), how the user sees which identity a tab is in, how a site is kept permanently, and when data is deleted
- [ ] #5 The work is split into implementation tasks, created only after the user has reviewed the design
- [ ] #6 Findings that outlive the task (WebKit store limits, extension visibility) are recorded in the wiki
<!-- AC:END -->
