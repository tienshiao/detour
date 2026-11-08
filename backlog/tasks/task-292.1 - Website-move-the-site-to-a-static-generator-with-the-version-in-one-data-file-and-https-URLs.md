---
id: TASK-292.1
title: >-
  Website: move the site to a static generator, with the version in one data
  file and https URLs
status: To Do
assignee: []
created_date: '2026-11-08T06:59:00Z'
labels:
  - website
dependencies: []
references:
  - ../detour-website
  - scripts/publish-release.sh
parent_task_id: TASK-292
priority: medium
ordinal: 342000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The feature pages (TASK-292) add twenty-odd pages that share a nav, footer, download button and version. Hand-written HTML will drift. scripts/publish-release.sh also rewrites the version, links and size in index.html with a Python regex and bumps the sitemap lastmod, which does not scale past one page. Planning leaned to Eleventy or Astro (Markdown per feature with frontmatter for the title tag, description, Arc comparison and FAQ; zero client JS); the worker picks after looking at both.

The canonical link, og:url, og:image, sitemap and robots.txt all use http://detourbrowser.com, which tells search engines the http URL is the real one.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The home page builds from the generator and renders the same as the current index.html (checked side by side at desktop and phone widths)
- [ ] #2 Version, DMG URL and size live in one data file that every page reads
- [ ] #3 publish-release.sh updates that data file instead of regex-editing index.html, and a dry run of its website step shows the expected diff
- [ ] #4 Canonical, og:url, og:image, the sitemap and robots.txt use https; http requests redirect to https
- [ ] #5 The sitemap is generated from the pages that exist
- [ ] #6 wrangler deploys the built output; the README says how to build and preview locally
<!-- AC:END -->
