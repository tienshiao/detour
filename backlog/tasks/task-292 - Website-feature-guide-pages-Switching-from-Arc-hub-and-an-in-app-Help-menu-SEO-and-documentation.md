---
id: TASK-292
title: >-
  Website: feature guide pages, Switching from Arc hub, and an in-app Help menu
  (SEO and documentation)
status: To Do
assignee: []
created_date: '2026-11-08T06:57:00Z'
updated_date: '2026-11-08T06:58:00Z'
labels:
  - website
dependencies: []
priority: medium
ordinal: 341000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The website (../detour-website, a separate repo, deployed with wrangler to Cloudflare) is one static index.html: six headline features with a capture each and a grid of 25 one-line small features. Nothing on it explains how to use a feature, there is one URL for search engines to rank, and the people the hero addresses ("FOR ARC REFUGEES") search for things like "Arc browser alternative", "browser like Arc for Mac", "separate work and personal tabs", which the page barely matches.

Goal: every feature worth a guide gets its own page that says what it does, why you would want it, shows it (loop or screenshots with real alt text), and walks through how to use it, with a short "Coming from Arc" comparison and an FAQ. A "Switching from Arc" hub ties the comparisons together. The app gets a Help menu that opens these pages, so the website doubles as the user guide.

Decisions from planning (user, Nov 7 2026):
- The guide stays a clear manual. Search phrasing goes in the title tag, meta description, URL slug, lede and FAQ headings; the H1 is the feature name with a plain one-line outcome, never a search question. Coined names (Quarantine, Link Routes, Quick Detour) are always paired with the generic phrase people search for.
- Not every feature gets a page: one only when there is a real guide to write (steps or settings) or real search demand. The rest are listed on a /features/ index and the /shortcuts/ page; thin pages are worse than none.
- Quarantine and Private Browsing are separate pages. Quarantine is pitched to privacy-conscious users as a way to triage incoming links without leaking data (cookies, history, tracking parameters), which is a different job from a private window.
- Detour is positioned as its own browser, no longer as an Arc clone (user, Nov 7 2026: "I can evolve away from being just an Arc clone"). Arc users are one audience with one entry point, the Switching from Arc hub, not the frame for every page. Several features have no Arc counterpart (Quarantine, Dev Mode, Site Search among them) and their pages say nothing about Arc. A "Coming from Arc" box appears only on pages whose feature Arc had in comparable form.
- Arc comparisons are factual and name Arc only to compare (no Arc logos or screenshots), including an honest "not in Detour" list.
- Google no longer shows HowTo rich results and limits FAQ rich results to government and health sites, so no effort goes into chasing them; BreadcrumbList on subpages, SoftwareApplication on the home page.
- Order: site generator and https fixes, then a pilot (Spaces, Split Tabs, Arc hub) to settle the template, then the remaining pages, then the Help menu, then a Search Console review that rewrites FAQs and titles from real queries.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Each feature chosen for a page has one at /features/<slug>/ following the shared template, linked from the home page
- [ ] #2 The Switching from Arc hub is live and every feature page links to it
- [ ] #3 The app has a Help menu that opens the guide pages
- [ ] #4 Search Console and Bing Webmaster Tools are set up and a first query review has fed back into titles and FAQs
<!-- AC:END -->
