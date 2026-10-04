---
okf_version: "0.2"
---

# Start here

* [Wiki conventions](meta/conventions.md) - What belongs in this wiki, the page types and frontmatter, and how to query, ingest and lint.
* [Architecture overview](architecture/overview.md) - The whole app on one page, with pointers into each area.
* [Extensions overview](extensions/overview.md) - Web Extension support: what WebKit provides and what Detour adds.
* [Build and test](playbooks/build-and-test.md) - Building, running the tests, and the traps around both.
* [Update log](log.md) - What changed in the wiki, newest first.

# Areas

* [Architecture](architecture/) - Profiles, spaces, TabStore, windows, web view ownership, persistence and the two databases.
* [Tabs](tabs/) - The tab model and its rules: lifecycle, insertion and close selection, sleeping and archiving, pinning, favorites, splits, Peek.
* [Sidebar](sidebar/) - Row layout, drag and drop, space paging, auto-hide, keyboard focus.
* [Features](features/) - Command palette, history, internal pages, content blocking, downloads, favicons, error pages, settings.
* [Extensions](extensions/) - The extension manager, polyfill layer, permissions, installer and updates, native messaging, and the integrations that drove them.
* [Platform](platform/) - WebKit and AppKit behaviour found by investigation: quirks, root causes, what was ruled out.
* [Playbooks](playbooks/) - Procedures for building, verifying at runtime, debugging and diagnosing.
* [Decisions](decisions/) - Design decisions and the alternatives they rejected.
* [Meta](meta/) - The wiki's own schema.
