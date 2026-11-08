import AppKit
import WebKit

// TASK-132.12: the native half of `chrome.tabGroups`, `tabs.group`,
// `tabs.ungroup` and a tab's `groupId` (`ExtensionAPIPolyfill.tabGroupsJS`).
// The model and its rules are TabStore's (TASK-132.10); this resolves what the
// extension named, checks it belongs to this profile, and calls the store.
//
// Tabs arrive as handles from the tab-id bridge (`__detourResolveTab`); a
// window, which has no bridge, arrives as the handle of its active tab
// (`windowTabHandle`), as for `chrome.sidePanel`. Groups arrive as the
// session ids of `ExtensionTabGroupIDs`.

extension ExtensionPolyfillHandler {

    static let tabGroupsPermissionRefusal = "tabGroups: the extension does not declare the tabGroups permission"
    static let tabGroupNotGroupableError = "Pinned tabs, favourites and Peeks cannot be grouped."
    static let tabGroupOtherWindowError = "The tabs must be in the group's window."
    static let tabGroupTabsInSeveralWindowsError = "The tabs must all be in one window."
    static let tabGroupMoveOtherWindowError = "Cannot move the group to another window."
    static let tabGroupMoveInsidePinnedError = "Cannot move the group to an index that is in the middle of pinned tabs."
    static let tabGroupMoveInsideGroupError = "Cannot move the group to an index that is in the middle of another group."

    /// Chrome's text for a group id it does not know; an id of another
    /// profile's group gets it too.
    static func noTabGroupError(_ value: Any?) -> String {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return "No group with id: \(number.intValue)."
        }
        return "No group with id: \(value.map { "\($0)" } ?? "undefined")."
    }

    /// Requests that need no `tabGroups` permission: `tabs.group`,
    /// `tabs.ungroup` and a Tab's `groupId` are part of `chrome.tabs` in Chrome.
    static let ungatedTabGroupRequests: Set<String> = [
        "tabGroups.group", "tabGroups.ungroup", "tabGroups.membership", "tabGroups.membershipSnapshot",
        "tabGroups.awaitEvent",
    ]

    /// Every `tabGroups.*` bridge message.
    func handleTabGroupsRequest(_ type: String, params: [String: Any], extensionID: String,
                                sender: PolyfillSender, senderWebView: WKWebView?,
                                replyHandler: @escaping (Any?, String?) -> Void) {
        // WebKit vends no tabGroups and does not know the permission, so the
        // manifest — and a denial in this profile's context — is the gate.
        if !Self.ungatedTabGroupRequests.contains(type),
           let refusal = permissionRefusal("tabGroups", extensionID: extensionID) {
            replyHandler(nil, refusal == Self.permissionNotDeclared("tabGroups") ? Self.tabGroupsPermissionRefusal : refusal)
            return
        }
        guard let profile else {
            replyHandler(nil, "\(type): profile unavailable")
            return
        }
        let store = TabStore.shared

        switch type {
        case "tabGroups.group":
            let tabs: [ExtensionTabHandleRegistry.ResolvedTab]
            switch resolveTabHandles(params["tabHandles"], type: type) {
            case .failure(let failure): replyHandler(nil, failure.message); return
            case .success(let resolved): tabs = resolved
            }
            guard tabs.allSatisfy({ $0.placement.kind == .normal }) else {
                replyHandler(nil, Self.tabGroupNotGroupableError)
                return
            }
            let spaceIDs = Set(tabs.compactMap(\.placement.spaceID))
            guard spaceIDs.count == 1, let space = store.space(withID: spaceIDs.first!) else {
                replyHandler(nil, Self.tabGroupTabsInSeveralWindowsError)
                return
            }
            if let anchor = params["windowTabHandle"], !(anchor is NSNull) {
                switch resolveTabHandle(anchor) {
                case .failure(let error): replyHandler(nil, Self.tabHandleRefusal(error, type: type)); return
                case .success(let resolved):
                    // Chrome moves the tabs into the window; there is no
                    // window bridge yet, so Detour groups only where they are.
                    guard tabGroupsSpace(ofWindowShowing: resolved)?.id == space.id else {
                        replyHandler(nil, Self.tabGroupOtherWindowError)
                        return
                    }
                }
            }
            let tabIDs = tabs.map(\.tab.id)
            do {
                if let requested = params["groupId"], !(requested is NSNull) {
                    guard let (group, groupSpace) = tabGroup(forID: requested, in: profile) else {
                        replyHandler(nil, Self.noTabGroupError(requested))
                        return
                    }
                    guard groupSpace.id == space.id else {
                        replyHandler(nil, Self.tabGroupOtherWindowError)
                        return
                    }
                    try store.addTabs(tabIDs, toTabGroup: group.id, in: space)
                    replyHandler(ExtensionTabGroupIDs.shared.id(for: group.id), nil)
                } else {
                    let group = try store.createTabGroup(tabIDs: tabIDs, in: space)
                    replyHandler(ExtensionTabGroupIDs.shared.id(for: group.id), nil)
                }
            } catch {
                replyHandler(nil, Self.message(for: error))
            }

        case "tabGroups.ungroup":
            let tabs: [ExtensionTabHandleRegistry.ResolvedTab]
            switch resolveTabHandles(params["tabHandles"], type: type) {
            case .failure(let failure): replyHandler(nil, failure.message); return
            case .success(let resolved): tabs = resolved
            }
            // A pinned tab, a favourite or a Peek is in no group: nothing to do
            // for it, as Chrome does nothing for an ungrouped tab.
            var bySpace: [UUID: [UUID]] = [:]
            for resolved in tabs where resolved.placement.kind == .normal {
                guard let spaceID = resolved.placement.spaceID else { continue }
                bySpace[spaceID, default: []].append(resolved.tab.id)
            }
            do {
                for (spaceID, tabIDs) in bySpace {
                    guard let space = store.space(withID: spaceID) else { continue }
                    try store.ungroupTabs(tabIDs, in: space)
                }
                replyHandler(true, nil)
            } catch {
                replyHandler(nil, Self.message(for: error))
            }

        case "tabGroups.membership":
            // The groupId of each tab, -1 when it is in none or the handle no
            // longer names a tab of this profile: a decoration, never a refusal.
            guard let handles = params["tabHandles"] as? [Any] else {
                replyHandler(nil, "\(type): tabHandles must be an array")
                return
            }
            let ids: [Int] = handles.map { handle in
                guard case .success(let resolved) = resolveTabHandle(handle), resolved.placement.kind == .normal,
                      let groupID = resolved.tab.tabGroupID else { return -1 }
                return ExtensionTabGroupIDs.shared.id(for: groupID)
            }
            replyHandler(["groupIds": ids], nil)

        case "tabGroups.membershipSnapshot":
            // Every grouped tab of this profile, for a context that starts
            // listening: its cache starts from this and follows the events.
            var entries: [[String: Any]] = []
            for space in store.spaces where space.profileID == profile.id {
                for tab in space.tabs {
                    guard let groupID = tab.tabGroupID else { continue }
                    entries.append(["tabHandle": ExtensionTabHandleRegistry.shared.handle(for: tab),
                                    "groupId": ExtensionTabGroupIDs.shared.id(for: groupID)])
                }
            }
            replyHandler(["tabs": entries], nil)

        case "tabGroups.get":
            guard let (group, space) = tabGroup(forID: params["groupId"], in: profile) else {
                replyHandler(nil, Self.noTabGroupError(params["groupId"]))
                return
            }
            replyHandler(group.extensionWireForm(in: space), nil)

        case "tabGroups.query":
            var spaces = store.spaces.filter { $0.profileID == profile.id }
            if let anchor = params["windowTabHandle"], !(anchor is NSNull) {
                switch resolveTabHandle(anchor) {
                case .failure(let error): replyHandler(nil, Self.tabHandleRefusal(error, type: type)); return
                case .success(let resolved):
                    let windowSpace = tabGroupsSpace(ofWindowShowing: resolved)
                    spaces = spaces.filter { $0.id == windowSpace?.id }
                }
            } else if Self.boolean(params["hasWindow"]) == true {
                // A window with no tab to name it by has no group either (the
                // polyfill answers that itself; this is for a raw request).
                spaces = []
            }
            let title = params["title"] as? String
            let color = (params["color"] as? String).flatMap(TabGroupColor.init(rawValue:))
            if params["color"] is String, color == nil {
                replyHandler([], nil)
                return
            }
            let collapsed = Self.boolean(params["collapsed"])
            var groups: [[String: Any]] = []
            for space in spaces {
                // In list order: the order of their first members.
                var seen = Set<UUID>()
                for tab in space.tabs {
                    guard let groupID = tab.tabGroupID, seen.insert(groupID).inserted,
                          let group = space.tabGroup(id: groupID) else { continue }
                    if let title, !Self.tabGroupTitle(group.title, matches: title) { continue }
                    if let color, group.color != color { continue }
                    if let collapsed, group.isCollapsed != collapsed { continue }
                    groups.append(group.extensionWireForm(in: space))
                }
            }
            replyHandler(groups, nil)

        case "tabGroups.update":
            guard let (group, space) = tabGroup(forID: params["groupId"], in: profile) else {
                replyHandler(nil, Self.noTabGroupError(params["groupId"]))
                return
            }
            var color: TabGroupColor?
            if let name = params["color"], !(name is NSNull) {
                guard let parsed = (name as? String).flatMap(TabGroupColor.init(rawValue:)) else {
                    replyHandler(nil, "Invalid color: \(name).")
                    return
                }
                color = parsed
            }
            do {
                try store.updateTabGroup(group.id, title: params["title"] as? String, color: color,
                                         isCollapsed: Self.boolean(params["collapsed"]), in: space)
                replyHandler(group.extensionWireForm(in: space), nil)
            } catch {
                replyHandler(nil, Self.message(for: error))
            }

        case "tabGroups.move":
            guard let (group, space) = tabGroup(forID: params["groupId"], in: profile) else {
                replyHandler(nil, Self.noTabGroupError(params["groupId"]))
                return
            }
            guard let indexNumber = params["index"] as? NSNumber, CFGetTypeID(indexNumber) != CFBooleanGetTypeID(),
                  let index = Int(exactly: indexNumber.doubleValue) else {
                replyHandler(nil, "\(type): index must be an integer")
                return
            }
            if let anchor = params["windowTabHandle"], !(anchor is NSNull) {
                switch resolveTabHandle(anchor) {
                case .failure(let error): replyHandler(nil, Self.tabHandleRefusal(error, type: type)); return
                case .success(let resolved):
                    guard tabGroupsSpace(ofWindowShowing: resolved)?.id == space.id else {
                        replyHandler(nil, Self.tabGroupMoveOtherWindowError)
                        return
                    }
                }
            }
            let pinned = space.pinnedTabs
            let leadingCount = pinned.count + pinned.filter { $0.peekTab?.webView != nil }.count
            let rest = space.tabs.filter { $0.tabGroupID != group.id }.map {
                TabGroupMoveSlot(slot: TabSlot(splitGroupID: $0.splitGroupID, tabGroupID: $0.tabGroupID),
                                 hasListedPeek: $0.peekTab?.webView != nil)
            }
            switch tabGroupMoveTarget(windowIndex: index, leadingCount: leadingCount, rest: rest) {
            case .insidePinnedTabs:
                replyHandler(nil, Self.tabGroupMoveInsidePinnedError)
            case .insideAnotherGroup:
                replyHandler(nil, Self.tabGroupMoveInsideGroupError)
            case .gap(let gap):
                do {
                    try store.moveTabGroup(group.id, to: gap, in: space)
                    replyHandler(group.extensionWireForm(in: space), nil)
                } catch {
                    replyHandler(nil, Self.message(for: error))
                }
            }

        case "tabGroups.awaitEvent":
            let events = tabGroupEventHub(for: profile)
            let registered = ExtensionManager.shared.extension(withID: extensionID)
            let isBackground = Self.senderIsBackgroundContext(sender, background: registered?.manifest.background)
            events.awaitEvent(extensionID: extensionID, isBackground: isBackground,
                              instance: params["instance"] as? String,
                              webView: isBackground ? nil : senderWebView,
                              ack: (params["ack"] as? NSNumber)?.intValue, reply: replyHandler)

        default:
            replyHandler(nil, "Unknown polyfill message type: \(type)")
        }
    }

    // MARK: Helpers

    /// The hub, made on first use: only a profile whose extensions listen pays
    /// for observing the store.
    private func tabGroupEventHub(for profile: Profile) -> ExtensionTabGroupEvents {
        if let existing = tabGroupEvents { return existing }
        let hub = ExtensionTabGroupEvents(
            profileID: profile.id,
            permits: { [weak self] extensionID in
                self?.permissionRefusal("tabGroups", extensionID: extensionID) == nil
            },
            wakeBackground: { [weak profile] extensionID in
                guard let context = profile?.extensionContext(for: extensionID),
                      context.webExtension.hasBackgroundContent else { return }
                context.loadBackgroundContent { _ in }
            })
        tabGroupEvents = hub
        return hub
    }

    /// The tabs `value` names by handle, every one resolved, or the refusal.
    private func resolveTabHandles(_ value: Any?, type: String)
        -> Result<[ExtensionTabHandleRegistry.ResolvedTab], TabGroupRequestFailure> {
        guard let handles = value as? [Any], !handles.isEmpty else {
            return .failure(TabGroupRequestFailure("\(type): tabHandles must be a non-empty array"))
        }
        var resolved: [ExtensionTabHandleRegistry.ResolvedTab] = []
        for handle in handles {
            switch resolveTabHandle(handle) {
            case .failure(let error): return .failure(TabGroupRequestFailure(Self.tabHandleRefusal(error, type: type)))
            case .success(let tab): resolved.append(tab)
            }
        }
        return .success(resolved)
    }

    /// The group a session id names, among this profile's spaces only.
    private func tabGroup(forID value: Any?, in profile: Profile) -> (TabGroup, Space)? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let id = Int(exactly: number.doubleValue),
              let uuid = ExtensionTabGroupIDs.shared.group(for: id) else { return nil }
        for space in TabStore.shared.spaces where space.profileID == profile.id {
            if let group = space.tabGroup(id: uuid) { return (group, space) }
        }
        return nil
    }

    /// The space of the window a resolved tab names: the window showing the
    /// tab's web view, else the tab's own space.
    private func tabGroupsSpace(ofWindowShowing resolved: ExtensionTabHandleRegistry.ResolvedTab) -> Space? {
        if let space = ExtensionSidePanelController.window(showing: resolved.tab)?.activeSpace { return space }
        return resolved.placement.spaceID.flatMap { TabStore.shared.space(withID: $0) }
    }

    /// What the extension is told for a refused store call.
    static func message(for error: Error) -> String {
        switch error as? TabGroupError {
        case .tabNotGroupable: return tabGroupNotGroupableError
        case .tabNotFound: return "No tab with this id in the window."
        case .groupNotFound(let id): return "No group with id: \(ExtensionTabGroupIDs.shared.id(for: id))."
        case .noTabs: return "At least one tab must be given."
        case nil: return error.localizedDescription
        }
    }

    /// Chrome matches `tabGroups.query`'s `title` as a pattern: `*` any run of
    /// characters, `?` one, everything else literally (`base::MatchPattern`).
    static func tabGroupTitle(_ title: String, matches pattern: String) -> Bool {
        let text = Array(title), glob = Array(pattern)
        var t = 0, p = 0, star = -1, mark = 0
        while t < text.count {
            if p < glob.count, glob[p] == "?" || glob[p] == text[t] {
                t += 1; p += 1
            } else if p < glob.count, glob[p] == "*" {
                star = p; mark = t; p += 1
            } else if star != -1 {
                p = star + 1; mark += 1; t = mark
            } else {
                return false
            }
        }
        while p < glob.count, glob[p] == "*" { p += 1 }
        return p == glob.count
    }
}

/// A refusal text, as a `Result` failure.
struct TabGroupRequestFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
