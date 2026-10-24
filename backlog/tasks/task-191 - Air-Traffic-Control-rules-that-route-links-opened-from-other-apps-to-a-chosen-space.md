---
id: TASK-191
title: 'Air Traffic Control: rules that route links and typed URLs to a chosen space'
status: To Do
assignee: []
created_date: '2026-10-24 09:44'
updated_date: '2026-10-24 10:18'
labels:
  - links
  - spaces
  - feature
  - epic
dependencies: []
priority: medium
ordinal: 218000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested by the user 2026-10-24, modelled on Arc's Air Traffic Control (screenshots: docs/air-traffic-control/arc-atc-1.png … -3.png). Other browsers have similar features (e.g. per-site profile routing).

**Today.** A link opened from another app (`AppDelegate.application(_:open:)`, http/https only) becomes a new tab in the key window's active space, or a new window when there is none; typed URLs and clicked links stay in the current space. Nothing chooses the space by URL, so a work link lands in whatever space is in front, with that space's profile and cookies.

**Arc's model** (from the screenshots): a list of routes, each `URL <Is equal to | Contains> <text>` → `Open in <a space | Most Recent Space | Little Arc>`, added with New Route and removed with ⊖, plus a **Default** target for links no route matches. Arc applies it to links from other apps, typed URLs and links clicked inside the browser.

**Detour:**
- Applies to links opened from other apps (TASK-191.2), typed URLs and links clicked in a page (TASK-191.4), each with its own exclusions.
- Match kinds: Arc's "Is equal to" and "Contains" (full URL, case-insensitive), plus a host match ("Domain is": the host or a subdomain), which is what most rules mean and is safer than a substring.
- Optional source-app condition (decided in scope 2026-10-24): a route can require that the link came from a given app (bundle ID from the Get URL Apple Event's sender), e.g. everything from Slack to Work; such a route only matches external links.
- Targets: a specific space; Most Recent Space (today's behaviour); **Private Window** (the most recent open Private window, else a new one; decided 2026-10-24); **Quarantine** (TASK-194: a throwaway Quick Detour window, links from other apps only); possibly Little/Quick Detour itself (TASK-193.5). Routing is one-way at the Private boundary: into Private is allowed, out of a Private window into a normal space never happens.
- First matching route wins; routes are reorderable. Default target: Most Recent Space unless set (Quarantine is a valid Default).

Subtasks: 191.1 model, resolver and storage; 191.2 links from other apps (with the source app); 191.3 Settings UI; 191.4 typed URLs and in-browser clicks.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Scope corrected by the user 2026-10-24: Arc does not limit Air Traffic Control to links from other apps — it also routes **typed URLs** and **links clicked inside the browser**. Detour does the same: external links (TASK-191.2) and typed URLs / in-browser clicks (TASK-191.4). The 'links from other apps only' proposal in the description is withdrawn.

Also decided 2026-10-24: the optional **source app** condition is in scope. A route can additionally require that the link came from a given app (bundle ID, from the Get URL Apple Event's sender); such a route only ever matches external links. Model in TASK-191.1, routing in TASK-191.2, picker in TASK-191.3.

2026-10-24: Little Detour (TASK-193, Detour's equivalent of Little Arc) is now planned, so it can become an Open in target after all, as in Arc; TASK-193.5 decides how its 'links from other apps' setting and the routes fit together.

Decided (user, 2026-10-24): **Private is an Open in target**, reversing "Private spaces are never targets" in the description. A Private space exists only while its window is open, so the target is "Private window", not a space: open the link as a tab in the most recent open Private window, else in a new Private window. It applies to all three origins (other apps, typed, in-browser clicks). The boundary rule becomes one-way: routing *into* Private is allowed; routing *out of* a Private window into a normal space never happens (a click or typed URL in a Private window ignores routes that target normal spaces). Distinct from Quarantine (TASK-194), which is a throwaway Quick Detour window for links from other apps only.
<!-- SECTION:NOTES:END -->
