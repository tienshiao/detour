// TASK-336 runtime helper: reads Detour's Settings window through Accessibility, as VoiceOver's object
// model sees it, and switches its panes. Needs Accessibility for the shell's host; on a locked screen AX
// returns no windows.
// Build: xcrun swiftc -module-cache-path "$TMPDIR/swift-mc" -o axsettings axsettings.swift (sandbox off to run).
//
// usage:
//   axsettings tree <pid>              -> the Settings window's tree: role, name (title / description /
//                                         title UI element), value, identifier, one element per line
//   axsettings reading <pid>           -> what a VoiceOver cursor stops on, in order (text, controls), then
//                                         SWITCHES (each switch and its name), DUPLICATES (a text followed by
//                                         a control named the same) and UNNAMED (switches without a name)
//   axsettings pane <pid> <title>      -> presses the toolbar item <title>
//   axsettings pressnamed <pid> <name>  -> presses the first button of that name in any window
//   axsettings choose <pid> <pop-up> <item> -> picks an item of a pop-up in the Settings window (TASK-342)
//   axsettings search <pid> <text>     -> types into the window's search field (TASK-343)
//   axsettings popover <pid>           -> the same reading for the sidebar settings popover's window, if open
// TASK-342: `reading` also ends with CONTROLS: every pop-up, field, button, link and recorder with its name,
// UNNAMED ones (images included; the window's own buttons and scroll bar parts left out), LABELS READ TOO (a
// text next to a control, or in the same container, whose name is that text, "Name:" and "Name" alike; a
// stated, more specific name such as "About Detour shortcut" beside "About Detour" is not caught) and READ TWICE (a control whose value or name is
// also a static text inside it).

import AppKit
import ApplicationServices

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
}
func str(_ e: AXUIElement, _ name: String) -> String? {
    guard let v = attr(e, name) else { return nil }
    if let s = v as? String { return s.isEmpty ? nil : s }
    if let n = v as? NSNumber { return n.stringValue }
    return nil
}
func children(_ e: AXUIElement) -> [AXUIElement] { attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }

/// The accessible name as VoiceOver composes it: title, else the title UI element's value, else description.
func name(_ e: AXUIElement) -> String? {
    if let t = str(e, kAXTitleAttribute) { return t }
    if let tui = attr(e, kAXTitleUIElementAttribute), CFGetTypeID(tui) == AXUIElementGetTypeID() {
        let el = tui as! AXUIElement
        if let v = str(el, kAXValueAttribute) ?? str(el, kAXTitleAttribute) { return v }
    }
    return str(e, kAXDescriptionAttribute)
}

func settingsWindow(_ pid: pid_t, title: String = "Settings") -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 5)
    let all = attr(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
    return all.first { str($0, kAXTitleAttribute)?.hasPrefix(title) == true }
        ?? all.first { (str($0, kAXTitleAttribute) ?? "").isEmpty == false && title == "Settings" && ["General", "Spaces", "Links", "Quick Detour", "Profiles", "Search", "Shortcuts", "Extensions", "Content Blocking"].contains(str($0, kAXTitleAttribute)!) }
}

func line(_ e: AXUIElement) -> String {
    let role = str(e, kAXRoleAttribute) ?? "?"
    var parts = [role]
    if let sub = str(e, kAXSubroleAttribute) { parts[0] += "/" + sub }
    if let t = str(e, kAXTitleAttribute) { parts.append("title=\"\(t)\"") }
    if let tui = attr(e, kAXTitleUIElementAttribute), CFGetTypeID(tui) == AXUIElementGetTypeID() {
        parts.append("titleUI=\"\(str(tui as! AXUIElement, kAXValueAttribute) ?? "?")\"")
    }
    if let d = str(e, kAXDescriptionAttribute) { parts.append("desc=\"\(d)\"") }
    if let v = str(e, kAXValueAttribute) { parts.append("value=\"\(v.prefix(60))\"") }
    if let i = str(e, kAXIdentifierAttribute) { parts.append("id=\(i)") }
    if let en = attr(e, kAXEnabledAttribute) as? Bool, !en { parts.append("disabled") }
    return parts.joined(separator: " ")
}

func tree(_ e: AXUIElement, depth: Int = 0, maxDepth: Int = 30, rowsCap: Int = 6) {
    print(String(repeating: "  ", count: depth) + line(e))
    guard depth < maxDepth else { return }
    var kids = children(e)
    // A long table (Shortcuts): the first rows are enough.
    if str(e, kAXRoleAttribute) == "AXTable" || str(e, kAXRoleAttribute) == "AXOutline" {
        let rows = kids.filter { str($0, kAXRoleAttribute) == "AXRow" }
        if rows.count > rowsCap {
            kids = kids.filter { str($0, kAXRoleAttribute) != "AXRow" } + rows.prefix(rowsCap)
            print(String(repeating: "  ", count: depth + 1) + "(\(rows.count - rowsCap) more rows)")
        }
    }
    for c in kids { tree(c, depth: depth + 1, maxDepth: maxDepth, rowsCap: rowsCap) }
}

/// Elements a VoiceOver cursor stops on: static text, and controls (anything with an action or a value
/// that is not a container), in tree order.
let containerRoles: Set<String> = ["AXWindow", "AXGroup", "AXScrollArea", "AXSplitGroup", "AXToolbar", "AXTable",
                                   "AXOutline", "AXRow", "AXColumn", "AXCell", "AXLayoutArea", "AXList", "AXUnknown",
                                   "AXTabGroup", "AXScrollBar", "AXSplitter", "AXValueIndicator"]
func stops(_ e: AXUIElement, into out: inout [AXUIElement], depth: Int = 0, rowsCap: Int = 6) {
    let role = str(e, kAXRoleAttribute) ?? ""
    if !containerRoles.contains(role) { out.append(e) }
    if role == "AXButton" || role == "AXCheckBox" || role == "AXPopUpButton" || role == "AXTextField"
        || role == "AXSearchField" || role == "AXStaticText" || role == "AXLink" { return }
    guard depth < 30 else { return }
    var kids = children(e)
    if role == "AXTable" || role == "AXOutline" {
        let rows = kids.filter { str($0, kAXRoleAttribute) == "AXRow" }
        kids = kids.filter { str($0, kAXRoleAttribute) != "AXRow" } + rows.prefix(rowsCap)
    }
    for c in kids { stops(c, into: &out, depth: depth + 1, rowsCap: rowsCap) }
}

func isSwitch(_ e: AXUIElement) -> Bool {
    str(e, kAXSubroleAttribute) == "AXSwitch"
}

func reading(_ window: AXUIElement) {
    var out: [AXUIElement] = []
    stops(window, into: &out)
    print("READING ORDER")
    for e in out {
        let role = (str(e, kAXRoleAttribute) ?? "?") + (isSwitch(e) ? "/switch" : "")
        if str(e, kAXRoleAttribute) == "AXStaticText" {
            print("  text \"\(str(e, kAXValueAttribute) ?? "")\"")
        } else {
            print("  \(role) name=\"\(name(e) ?? "")\" value=\"\(str(e, kAXValueAttribute)?.prefix(40) ?? "")\"\(str(e, kAXIdentifierAttribute).map { " id=\($0)" } ?? "")")
        }
    }
    print("SWITCHES")
    var unnamed = 0
    for e in out where isSwitch(e) {
        let n = name(e)
        if n == nil { unnamed += 1 }
        print("  \"\(n ?? "")\"\(str(e, kAXIdentifierAttribute).map { " id=\($0)" } ?? "")")
    }
    print("DUPLICATES")
    // A text, then (next to it in reading order, either side) a control named the same.
    var dupes = 0
    for (i, e) in out.enumerated() where str(e, kAXRoleAttribute) == "AXStaticText" {
        guard let text = str(e, kAXValueAttribute) else { continue }
        for j in [i - 1, i + 1] where out.indices.contains(j) {
            let c = out[j]
            if str(c, kAXRoleAttribute) != "AXStaticText", let n = name(c), n == text {
                dupes += 1; print("  \"\(n)\": a text beside a \(str(c, kAXRoleAttribute) ?? "?") of that name")
            }
        }
    }
    print("UNNAMED SWITCHES: \(unnamed)  DUPLICATES: \(dupes)")
    controlChecks(out)
}

// TASK-342: every control type, not only switches.
let controlRoles: Set<String> = ["AXButton", "AXCheckBox", "AXPopUpButton", "AXTextField", "AXSearchField",
                                 "AXComboBox", "AXRadioButton", "AXRadioGroup", "AXSlider", "AXMenuButton", "AXLink",
                                 "AXImage"]
/// A label as a sighted user reads it: "Name:" and "Name" are the same label.
func normalized(_ text: String) -> String {
    var t = text.trimmingCharacters(in: .whitespaces).lowercased()
    while t.hasSuffix(":") { t.removeLast() }
    return t
}
/// The static texts under an element, its own subtree only.
func childTexts(_ e: AXUIElement, depth: Int = 6) -> [String] {
    guard depth > 0 else { return [] }
    return children(e).flatMap { c -> [String] in
        (str(c, kAXRoleAttribute) == "AXStaticText" ? [str(c, kAXValueAttribute) ?? ""] : []) + childTexts(c, depth: depth - 1)
    }
}
func controlChecks(_ out: [AXUIElement]) {
    print("CONTROLS")
    var unnamed = 0, nearDupes = 0, twice = 0
    for (i, e) in out.enumerated() {
        let role = str(e, kAXRoleAttribute) ?? ""
        guard controlRoles.contains(role) else { continue }
        let n = name(e)
        let id = str(e, kAXIdentifierAttribute).map { " id=\($0)" } ?? ""
        print("  \(role) \"\(n ?? "")\"\(id)")
        // A text field with a placeholder is still unnamed: VoiceOver reads the placeholder only while it is empty.
        // The window's own buttons (close, minimize, zoom) and a scroll bar's parts are AppKit's.
        let sub = str(e, kAXSubroleAttribute) ?? ""
        if n == nil, ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton",
                      "AXIncrementPage", "AXDecrementPage", "AXIncrementArrow", "AXDecrementArrow"].contains(sub) {
            print("    (\(sub), AppKit's)"); continue
        }
        if n == nil { unnamed += 1; print("    UNNAMED\(sub.isEmpty ? "" : " " + sub)") }
        // A label read on its own next to the control it labels (normalized: "Name:" is "Name"): the stops
        // right before and after it, and every text in the same container (a row whose labels are read after
        // its controls, as Links' route rows were).
        if let n {
            var nearby = [i - 1, i + 1].filter { out.indices.contains($0) && str(out[$0], kAXRoleAttribute) == "AXStaticText" }
                .map { str(out[$0], kAXValueAttribute) ?? "" }
            if let parent = attr(e, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() {
                nearby += childTexts(parent as! AXUIElement, depth: 3)
            }
            for text in Set(nearby) where !text.isEmpty && normalized(text) == normalized(n) {
                nearDupes += 1; print("    LABEL READ TOO: \"\(text)\"")
            }
        }
        // Its value (or name) again as a text inside it.
        let value = str(e, kAXValueAttribute)
        for text in childTexts(e) where !text.isEmpty && (text == value || text == n) {
            twice += 1; print("    READ TWICE: \"\(text)\" (value/name and child text)")
        }
    }
    print("UNNAMED CONTROLS: \(unnamed)  LABELS READ TOO: \(nearDupes)  READ TWICE: \(twice)")
}

let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[2]) else { print("usage: axsettings tree|reading|pane|pressnamed|popover <pid> [title|name]"); exit(2) }
switch args[1] {
case "tree":
    guard let w = settingsWindow(pid) else { print("no Settings window"); exit(1) }
    tree(w)
case "reading":
    guard let w = settingsWindow(pid) else { print("no Settings window"); exit(1) }
    print("window: \(str(w, kAXTitleAttribute) ?? "")")
    reading(w)
case "popover":
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 5)
    // A popover is a child of the window it hangs from.
    var found: AXUIElement?
    func look(_ e: AXUIElement, _ d: Int) {
        if found != nil || d > 12 { return }
        if str(e, kAXRoleAttribute) == "AXPopover" { found = e; return }
        for c in children(e) { look(c, d + 1) }
    }
    for w in attr(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] { look(w, 0) }
    guard let p = found else { print("no popover"); exit(1) }
    tree(p)
    reading(p)
case "pressnamed":
    // presses the first button named args[3] in any window (the sidebar's page settings button)
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 5)
    var pressed = false
    func look(_ e: AXUIElement, _ d: Int) {
        if pressed || d > 14 { return }
        if str(e, kAXRoleAttribute) == "AXButton", name(e) == args[3] {
            pressed = AXUIElementPerformAction(e, kAXPressAction as CFString) == .success; return
        }
        if str(e, kAXRoleAttribute) == "AXWebArea" { return }
        for c in children(e) { look(c, d + 1) }
    }
    for w in attr(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] { look(w, 0) }
    print(pressed ? "pressed \(args[3])" : "no button \(args[3])")
    if !pressed { exit(1) }
case "choose":
    // TASK-342: picks item args[4] of the first pop-up named args[3] in the Settings window (opens its menu,
    // presses the item).
    guard args.count >= 5, let w = settingsWindow(pid) else { print("usage: axsettings choose <pid> <pop-up> <item>"); exit(2) }
    var popUp: AXUIElement?
    func find(_ e: AXUIElement, _ d: Int) {
        if popUp != nil || d > 30 { return }
        if str(e, kAXRoleAttribute) == "AXPopUpButton", name(e) == args[3] { popUp = e; return }
        for c in children(e) { find(c, d + 1) }
    }
    find(w, 0)
    guard let popUp else { print("no pop-up \(args[3])"); exit(1) }
    AXUIElementPerformAction(popUp, kAXPressAction as CFString)
    usleep(500_000)
    var chosen = false
    for menu in children(popUp) where str(menu, kAXRoleAttribute) == "AXMenu" {
        for item in children(menu) where str(item, kAXTitleAttribute) == args[4] {
            chosen = AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
        }
    }
    if !chosen {
        // Close the menu it opened, so the next command finds the window as it was.
        for menu in children(popUp) where str(menu, kAXRoleAttribute) == "AXMenu" {
            AXUIElementPerformAction(menu, kAXCancelAction as CFString)
        }
    }
    print(chosen ? "chose \(args[4])" : "no item \(args[4])")
    if !chosen { exit(1) }
case "search":
    // TASK-343: types args[3] into the Settings window's first search field (sets its value, then confirms,
    // so the field's action and text-change callback run) and leaves the list filtered.
    guard args.count >= 4, let w = settingsWindow(pid) else { print("usage: axsettings search <pid> <text>"); exit(2) }
    var field: AXUIElement?
    func find(_ e: AXUIElement, _ d: Int) {
        if field != nil || d > 30 { return }
        if str(e, kAXSubroleAttribute) == "AXSearchField" { field = e; return }
        for c in children(e) { find(c, d + 1) }
    }
    find(w, 0)
    guard let field else { print("no search field"); exit(1) }
    AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    let set = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, args[3] as CFString)
    AXUIElementPerformAction(field, kAXConfirmAction as CFString)
    print(set == .success ? "searched \(args[3])" : "could not set the field (\(set.rawValue))")
case "pane":
    guard args.count >= 4, let w = settingsWindow(pid) else { print("no Settings window"); exit(1) }
    let wanted = args[3]
    var pressed = false
    func look(_ e: AXUIElement, _ d: Int) {
        if pressed || d > 6 { return }
        if str(e, kAXRoleAttribute) == "AXButton", name(e) == wanted || str(e, kAXTitleAttribute) == wanted {
            pressed = AXUIElementPerformAction(e, kAXPressAction as CFString) == .success; return
        }
        for c in children(e) { look(c, d + 1) }
    }
    look(w, 0)
    print(pressed ? "pressed \(wanted)" : "no toolbar item \(wanted)")
    if !pressed { exit(1) }
default:
    print("unknown"); exit(2)
}
