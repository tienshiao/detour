---
type: Concept
title: Link Routes resolver
description: "The Link Routes model (routes with a URL condition, a source-app condition or both, five targets, one Default) and the pure resolveLinkRoute: first usable match wins, http/https only, source-app routes external-only, one-way into Private, Quick Detour external-only, Quarantine for links from other apps and the clicks a route to it matches, the Default for every origin, and exactly how each match kind compares a URL."
tags: [links, spaces, privacy, incognito]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:00:20Z }
sources:
  - id: model
    resource: ../../Detour/Browser/LinkRouting/LinkRoute.swift
    title: LinkRoute.swift (LinkRoute, LinkRouteMatch, LinkRouteTarget)
  - id: resolver
    resource: ../../Detour/Browser/LinkRouting/LinkRouteResolver.swift
    title: LinkRouteResolver.swift (resolveLinkRoute, LinkRouteContext, linkRouteMatch, linkRouteDomain)
  - id: eligibility
    resource: ../../Detour/Browser/LinkRouting/LinkRoutingEligibility.swift
    title: LinkRoutingEligibility.swift (linkRoutingEligibility, typedURLIsRoutable)
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift (linkRouteContext)
  - id: resolver-tests
    resource: ../../DetourTests/LinkRouteResolverTests.swift
    title: LinkRouteResolverTests.swift
  - id: task-191-1
    resource: backlog:TASK-191.1
    title: "TASK-191.1: route model, matching rule and storage"
  - id: task-193-5
    resource: backlog:TASK-193.5
    title: "Quick Detour: Opt-Cmd-click entry points, links from other apps, and auto-archive"
  - id: task-194
    resource: backlog:TASK-194
    title: "Quarantine: links in a throwaway Quick Detour window, then moved to a profile and space on purpose"
  - id: task-302
    resource: backlog:TASK-302
    title: "Link Routes: an app-only route is flagged invalid until its URL condition is switched to Any URL"
---

What a route is, and where `resolveLinkRoute` sends a link once it is
routed at all. The resolver is pure and has no exclusions of its own: which
links inside Detour reach it is the click and typed-URL rule on
[Typed URLs and links clicked in a page](./link-routing-in-page.md); which
window a decision opens in is [Link placement](./link-routing-placement.md).
Part of [Link Routes](./link-routing.md).

# Model

| Type | Fields / cases |
|---|---|
| `LinkRoute` | `id`, `match: LinkRouteMatch?`, `sourceApp: String?` (bundle ID), `target`, `sortOrder` |
| `LinkRouteMatch` | `kind` (`isEqualTo`, `contains`, `domainIs`) and `pattern` |
| `LinkRouteTarget` | `.space(UUID)`, `.mostRecentSpace`, `.privateWindow`, `.quarantine` (TASK-194), `.quickDetour` (TASK-193.5) |

- A route needs at least one condition (`hasCondition`): a non-empty pattern
  or a source app. App-only routes are allowed (user, 2026-10-25): either
  "Any URL" (`match == nil`) or, since TASK-302, a URL condition whose
  pattern is empty or blank (the editor's "Domain is" with nothing typed);
  the resolver already read both as any web URL from that app.[^task-302]
  The store refuses a route with neither (and, since TASK-191.3, any route
  with a problem: [validation](./link-routing-store.md#validation)), and the
  resolver ignores one.
- With both conditions, both must hold.
- One **Default** target, `.mostRecentSpace` unless set.
- Routes are app-wide, not per profile: spaces are global.

# The resolver

`resolveLinkRoute(url:origin:routes:defaultTarget:context:) -> LinkRouteDecision`
is pure. `LinkOrigin` is `.external(sourceApp:)`, `.typed(fromSpace:isPrivateWindow:)`
or `.clicked(inSpace:isPrivateWindow:)`. `LinkRouteContext`
(`TabStore.linkRouteContext`) holds the ids of the normal spaces that exist
(`spaceIDs`, which the resolver reads) and, since TASK-191.3, of the Private
windows' spaces (`privateSpaceIDs`, which only
[validation](./link-routing-store.md#validation) reads, to tell a Private
space from a deleted one). The decision is `.openInSpace(id)`,
`.mostRecentSpace`, `.privateWindow`, `.quarantine`, `.quickDetour` or
`.stay`.

Links from other apps go through `resolveExternalLinkRoute`, which is
`resolveLinkRoute` for `.external(sourceApp:)` plus the rule for the link
that launched Detour; see
[Links from other apps](./link-routing-external-links.md#the-link-that-launched-detour).

## Two layers: whether, then where

A link inside Detour is decided in two steps. **Whether** it is routed at
all is TASK-191.4's pure click rule, `linkRoutingEligibility` (and its
typed-URL rule, `typedURLIsRoutable`: a URL, not a search, from the new-tab
palette; see [Typed URLs and links clicked in a page](./link-routing-in-page.md)):
same-host plain clicks, redirects, script navigations, popups that keep
their opener, Opt-Cmd- (Quick Detour, TASK-193.5), Option- and Shift-clicks
and links in a Peek never get past it. **Where** a routed link goes is
`resolveLinkRoute`, which has no exclusions of its own: every `.typed` or
`.clicked` origin it is handed gets the routes and then the Default. The
contract is written where a caller meets it: the doc comments on
`LinkOrigin.typed`/`.clicked` and on `resolveLinkRoute`, and the header of
`LinkRouteResolver.swift`. The case names were kept (`.clicked`, not
`.routableClick`): the vocabulary matches the task notes, and the comment
on the case states the precondition.

## Rules

| Rule | Why |
|---|---|
| Routes are tried in `sortOrder` (ties by array order); the first that matches **and** can be used from this origin wins. One that matches but cannot be used is skipped and the next is tried. | A deleted space, a normal space from a Private window or Quarantine for a typed URL must never route into nothing. |
| Only `http`/`https` URLs match any route. | A `detour://` page, a file or `data:` URL belongs where it was opened. |
| A source-app route matches only `.external` with that bundle ID (compared without case). An external link with no known sender matches no source-app route. | The sender only exists for an Apple Event; `open` from a shell names none. (A link that launched Detour with no known sender has one exception, toward Quarantine: [the launch rule](./link-routing-external-links.md#the-link-that-launched-detour).) |
| `.privateWindow` matches from every origin. From a Private window it is `.stay`. | Routing into Private is allowed, from anywhere (user, 2026-10-24). |
| From a Private window, routes to a space or to Most Recent Space (and Quick Detour and Quarantine) are skipped; the next matching route, then the Default, decides, and every one of them ends in `.stay`. | Nothing routes out of Private: one early rule in the resolver's `decision(for:)` (TASK-194 follow-up), ahead of the per-target cases. |
| A route to the space the link is already in is `.stay`, and stops the search. | First match wins; it already is where the route sends it. |
| `.mostRecentSpace` is `.mostRecentSpace` for an external link and `.stay` for a typed URL or click. | A typed URL or click is in the key window, whose space is the most recent one. |
| `.quickDetour` applies to external links only; elsewhere it is skipped. | Decided in TASK-193.5 (2026-10-26): links from other apps reach Quick Detour through this target; inside Detour, Opt-Cmd-click opens one. Widening it is one line.[^task-193-5] |
| `.quarantine`: external links, and a click **a route** to it matches (never from a Private window); never a typed URL. The Default naming it takes external links only. | The user's decision of 2026-10-26 (TASK-194), replacing the 2026-10-24 "links from other apps only". A Default of Quarantine taking clicks would quarantine every link clicked to another site; a quarantine's Open in reaches normal spaces, so a Private window's click stays (nothing routes out of Private). See [Quarantine](./quarantine.md).[^task-194] |
| A route to a space not in the context is skipped. | Deletion is blocked ([space deletion](./link-routing-space-deletion.md)), but a space removed some other way must not route into nothing. A Private window's space is never in the context, so no route can name one. |
| No route: the **Default applies from every origin**, with the same rules as a route's target (below). | User decision 2026-10-25.[^task-191-1] |
| Default = a normal space: a typed URL or click from another normal space opens there; from that space it is `.stay`. | As a route to that space. |
| Default = Most Recent Space: a typed URL or click is `.stay`; an external link goes to the most recent space. | The key window's space is the most recent one. |
| Default = Private window: `.privateWindow` from every normal origin, `.stay` from a Private window. | As a Private route. |
| Default = Quarantine or Quick Detour: external links only; a typed URL or click is `.stay` (a click to Quarantine only by a route). | The user is already in a space, so it stays rather than going to the most recent space. |
| From a Private window, a Default naming a normal space (or Most Recent Space) is ignored: `.stay`. | The one-way Private rule. |
| A Default that cannot be used (a deleted space): an external link goes to `.mostRecentSpace`, a typed URL or click is `.stay`. | An external link needs a window; a typed URL or click already has one. |

**Rejected: the Default for links from other apps only.** The first version
applied the Default to external links and left every unmatched typed URL or
click where it was, reading "Quarantine routes (and the Default) apply only
to external links" from the task notes, so that a Default of "Work" would not
pull every typed URL into Work. The user decided on 2026-10-25 that the
Default is a route like any other, for every origin; which clicks are routed
at all is the click rule's job (above), not the Default's.[^task-191-1]

## Match text

| Kind | Compared |
|---|---|
| `contains` | The pattern, lowercased, as a substring of `url.absoluteString` lowercased: the whole URL including the query and the **fragment**, in its encoded form (punycode host, percent-encoded path). A hash-routed app's `#/inbox` can be matched. |
| `isEqualTo` | Both sides normalised: lowercased, fragment, user info and a default port dropped, an empty path as `/`. `https://Example.com` equals `https://example.com/#top`; `:8443` does not equal no port. A pattern without a scheme is not a URL and equals nothing. |
| `domainIs` | The URL's host (`authorityHost`, lowercased, trailing dot dropped) equals the pattern's domain or ends with `.` + domain. `example.com` covers `a.example.com`, not `badexample.com` or `example.com.evil.test`. |

How `linkRouteDomain(fromPattern:)` reads a `domainIs` pattern:

- whitespace trimmed; a pasted URL, a path or a port is reduced to the host
  (`https://example.com/x`, `example.com:8080` → `example.com`). **Ports are
  ignored** on both sides: `localhost:3000` covers `localhost:4000`; a rule
  that needs a port uses `contains`.
- a leading `*.` or `.` is dropped (`*.example.com` also covers the apex).
- a leading **`www.` is dropped**: `www.example.com` means the site, so it
  covers `example.com` and all its subdomains. `example.com` covers
  `www.example.com` anyway. A bare `www` stays a host.
- **IDN**: the host is parsed with `URL(string:)`, which IDNA-encodes it, so
  both sides compare in punycode (`münchen.de` → `xn--mnchen-3ya.de`, the form
  WebKit's URLs and `authorityHost` carry).
- **IP literals** match exactly, with no subdomain rule: `0.1` must not
  cover `10.0.0.1`. A bare IPv6 pattern (`::1`) is bracketed to match
  `authorityHost` (`[::1]`); see [IPv6 hosts in URL APIs](../platform/ipv6-url-hosts.md).

# Tests

`LinkRouteResolverTests`: every rule above, each match kind, `www.`, ports,
IDN, IP literals, the Default from each origin; TASK-304: a launch link with
a known sender, with none and a From app route to Quarantine (its URL
condition holding, ahead of the Default, behind another From app route),
with none and a Quarantine route that is decided (its URL condition fails, a
route ahead of it matches, a URL-only route), with none and no Quarantine
route, and links while running unchanged. Both layers together (Private
both ways, Quarantine, the Default, a route to the current space) are in
`LinkRoutingEligibilityTests`, on
[Typed URLs and links clicked in a page](./link-routing-in-page.md#tests).

# Related

- [Link Routes](./link-routing.md): the hub.
- [Link Routes store](./link-routing-store.md): how routes are stored and validated.
- [Site settings](../architecture/site-settings.md): the host-or-parent rule `domainIs` shares in spirit.
- [Incognito](../architecture/incognito.md): the one-way Private boundary.
- [Quarantine](./quarantine.md): the Quarantine target.

[^task-191-1]: TASK-191.1: route model, matching rule and storage
[^task-193-5]: Quick Detour: Opt-Cmd-click entry points, links from other apps, and auto-archive
[^task-194]: Quarantine: links in a throwaway Quick Detour window, then moved to a profile and space on purpose
[^task-302]: Link Routes: an app-only route is flagged invalid until its URL condition is switched to Any URL
