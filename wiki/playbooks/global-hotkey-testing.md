---
type: Playbook
title: Testing a global hotkey
description: How to exercise a system-wide hotkey from another app at runtime without a person — posting real key presses at the HID event tap, a scratch app to be the app in front, safe clicks, a command-file harness, and the traps (F-keys need the Fn flag, unicode-string events are dropped by an inactive app's panel, a stuck Shift, isActive lying while a non-activating panel is key).
tags: [playbook, harness, hotkey, input, runtime]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-26T05:10:00Z }
stale_after: 2027-06-01T00:00:00Z
sources:
  - id: harness
    resource: ../../docs/harness/task193-2-harness.patch
    title: TASK-193.2 runtime harness, with the scratch tools' and driver's sources
  - id: task-193-2
    resource: backlog:TASK-193.2
    title: "Quick Detour: a system-wide hotkey that opens it from any app"
---

The Quick Detour hotkey (TASK-193.2) had to be checked the way it is used:
pressed while **another app** is in front. A debug harness cannot do that
from inside Detour (its own posted events never reach the window server's
hotkey matching), so the input comes from small scratch tools run from the
shell, and Detour's harness only answers commands and logs state. Every
step below was used in the TASK-193.2 run; the tools' sources are in the
[harness patch](../../docs/harness/task193-2-harness.patch).[^harness]

# When to use

Anything that depends on the window server routing a key or a click: a
global hotkey, a non-activating panel taking typing over another app, what
comes forward on activation, focus returning to the previous app.

# Steps

1. **Check you may post events, without asking.** In a scratch CLI,
   `CGPreflightPostEventAccess()`. It was true for processes started from
   the Claude Code terminal with the sandbox off (the terminal's own
   grant). Never call `CGRequestPostEventAccess`; if preflight is false,
   stop and list the physical key presses for a person.
2. **Pick a test shortcut nobody uses**, such as Ctrl-Opt-Cmd-F12, and
   leave the default alone: the installed app shares the bundle ID and may
   own it. A Debug build registers the Quick Detour hotkey only with
   `DETOUR_GLOBAL_HOTKEY=1` in its environment, and an isolated data
   directory starts with it off: launch with the variable, then the harness
   sets the shortcut and turns it on.
3. **Make another app frontmost with a scratch app of your own**: an
   unbundled AppKit executable run directly (no `open`, so nothing is
   registered with LaunchServices), a centred window with a text field,
   logging activation, key-window changes and the keys it receives, and
   activating itself on SIGUSR1. Never script the user's apps.
4. **Post real input at the HID event tap** (`CGEvent.post(tap:
   .cghidEventTap)`), from a scratch CLI: `key <code> <modifiers>`,
   `type <text>` (virtual key codes of a US layout), and `click <x> <y>
   <pid>` that refuses unless the topmost window under the point (layer
   below 20, alpha above 0, `CGWindowListCopyWindowInfo` front to back)
   belongs to that PID, so a click never lands in one of the user's apps.
5. **Drive Detour through command files.** The harness polls
   `$DETOUR_VERIFY_DIR/cmd-<n>` every 0.1 s, runs the line and logs
   `DONE <n>`; the driver writes the next file and waits for it. Log, per
   step: `NSApp.isActive`, `NSWorkspace.frontmostApplication`, the panel's
   key state and its field's text, the registration state, and the
   window server's order of your windows (`CGWindowListCopyWindowInfo`,
   `.optionOnScreenOnly`, front to back: PID, window number, layer).
6. **Prove a conflict** with a scratch process that registers the same
   shortcut (`RegisterEventHotKey`, `kEventHotKeyExclusive`) and logs its
   presses.
7. **End by proving the registration is gone**: kill only the PIDs you
   started, then register the test shortcut exclusively from a scratch
   process; `noErr` means nothing holds it.

# Traps

- **A posted F-key needs the Fn flag** (`.maskSecondaryFn`) to match a
  Carbon hotkey, as a physical F-key press carries it; without it the
  hotkey never fired.[^harness]
- **Unicode-string key events are dropped by an inactive app's panel.**
  `keyboardSetUnicodeString` events (virtual key 0) reached the panel's
  field editor while another app was frontmost but inserted nothing until
  a real key code had been typed; they type fine into an active app. Type
  with virtual key codes, which is what a keyboard sends.[^harness]
- **Set every posted key's flags.** One event posted with `.maskShift`
  left the event source shifted: the keys after it came out as `*(#@?`.
- **`NSApp.isActive` is true while a non-activating panel is key**,
  although the other app keeps the menu bar and stays frontmost. Read
  `NSWorkspace.frontmostApplication` to know which app is in front.
- **Shell functions in `$(…)` run in a subshell**: a command counter
  incremented there is lost, and the command files go out of step.
- **An exclusive holder takes the key everywhere**, including from a
  recorder that is recording it.
- **Screenshots.** Capture the panel with `screencapture -R` over your
  scratch app's window only (it is glass; see
  [Quick Detour](../features/quick-detour.md)), and windows with
  `screencapture -l <windowNumber>`, so none of the user's windows are in
  a capture.

# Related

- [Quick Detour](../features/quick-detour.md) — the hotkey and what this found.
- [In-process UI automation](./in-process-ui-automation.md) — input from inside the app, and its limits.
- [Debug harness](./debug-harness.md) — the temporary harness pattern.
- [Runtime verification](./runtime-verification.md) — isolated data directories, the screen-lock probe.

[^harness]: TASK-193.2 runtime harness, with the scratch tools' and driver's sources
