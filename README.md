# Detour

A native macOS web browser built with Swift and WebKit.

## Features

- **Spaces** — Organize tabs into color-coded workspaces, each with isolated cookies and storage. Each space has a name, emoji, and color.
- **Tab Pinning** — Pin frequently used tabs to the top of the sidebar. Pinned tabs reset to their home URL instead of closing.
- **Command Palette** — Cmd+T for new tab, Cmd+L to navigate. Searches open tabs, browsing history (FTS5), and web suggestions in one unified input.
- **Downloads** — Built-in download manager with progress tracking, cancel, reveal in Finder, and persistence across sessions.
- **Peek Preview** — Long-click links to preview them in an overlay without leaving the current page. Expand to open in a new tab.
- **Audio Controls** — Detects tabs playing audio and shows a mute toggle per tab.
- **Link Status Bar** — Hovering over a link shows the destination URL at the bottom of the window.
- **Find in Page** — Cmd+F with match counting and prev/next navigation.
- **Multi-Window** — Each window tracks its own active space. WebView ownership transfers automatically on window focus; inactive windows show tab snapshots.
- **Incognito** — Private browsing with non-persistent data stores. No history recorded. Cleaned up on window close.
- **Session Restore** — Tabs persist across launches with full scroll position and form state via WebKit interaction state archiving.
- **Tab Management** — Drag-and-drop reordering, close tabs, reopen recently closed tabs (Cmd+Shift+T).
- **Sidebar Auto-Hide** — Toggle sidebar visibility with Cmd+S; auto-hide mode reopens on edge hover.
- **Context Menus** — Right-click links to open in a new tab or new window.
- **Web Inspector** — Cmd+Option+I to open developer tools.

## Requirements

- macOS 14.0+
- Xcode with Swift 5.10
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Getting Started

```bash
# Generate the Xcode project
xcodegen generate

# Build
xcodebuild -scheme Detour -configuration Debug build

# Run tests
xcodebuild -scheme DetourTests -configuration Debug test
```

Or open `Detour.xcodeproj` in Xcode after running `xcodegen generate`.

## Dependencies

- [GRDB.swift](https://github.com/groue/GRDB.swift) — SQLite database for session and history storage
