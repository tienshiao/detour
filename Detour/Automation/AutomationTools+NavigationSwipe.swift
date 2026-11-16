import AppKit

/// TASK-325: Debug builds' way into Detour's own back swipe. Synthetic events
/// cannot drive `NSEvent.trackSwipeEvent`, so a run can check the mode of a
/// tab's web view and run a swipe's completion through the same code as a
/// trackpad's, with a scripted tracker in place of the real one.
extension AutomationTools {

    var navigationSwipeTools: [MCPTool] {
        #if DEBUG
        [navigationSwipe]
        #else
        []
        #endif
    }

    #if DEBUG
    private var navigationSwipe: MCPTool {
        MCPTool(
            name: "navigation_swipe",
            title: "Inspect or drive the back swipe",
            description: "Debug builds and test runs only. action state (the default) reports, for each pane window_id "
                + "hosts, whether its web view is in Detour's own back-swipe mode (a tab opened from another, with no "
                + "back item), WebKit's gesture flag, the rubber-band edges, its history, its opener and whether a forward "
                + "swipe would show a picture of the forward page. action begin "
                + "starts a swipe on context's pane (default the selected tab) in direction (back or forward) and holds "
                + "it at progress (0 to 1) with the veneer showing; action finish completes it (complete true, the "
                + "default) or springs it back (complete false), through the completion a trackpad swipe runs.",
            inputSchema: MCPSchema.input([
                ("window_id", .integer("The browser window")),
                ("action", .enumeration(["state", "begin", "finish"], "What to do; state by default")),
                ("context", .string("begin: the pane's tab_id; the selected tab by default")),
                ("direction", .enumeration(["back", "forward"], "begin: which way; back by default")),
                ("progress", .number("begin: how far, 0 to 1; 0.5 by default")),
                ("complete", .boolean("finish: true completes the swipe, false cancels it; true by default")),
            ], required: ["window_id"]),
            outputSchema: MCPSchema.output([
                "panes": MCPSchema.arrayOfObjects("One entry per pane the window hosts"),
                "selected_tab_id": ["type": ["string", "null"]],
                "swipe_active": MCPSchema.booleanType,
                "began": ["type": ["boolean", "null"]],
                "forward_picture": ["type": ["boolean", "null"]],
            ]),
            annotations: ["readOnlyHint": false, "destructiveHint": true],
            handler: { [self] arguments in
                try requireStagingTestRun("navigation_swipe")
                let controller = try window(id: try arguments.requiredInt("window_id"))
                var began: Bool?
                switch try arguments.string("action") ?? "state" {
                case "state":
                    break
                case "begin":
                    // A held swipe that was cancelled meanwhile (a navigation, a
                    // close) holds nothing: a new one may replace it.
                    guard controller.navigationSwipe.scriptedTracker == nil
                            || controller.navigationSwipe.session == nil else {
                        throw AutomationToolError(.invalidArguments, "A swipe is already held; finish it first")
                    }
                    let tab: BrowserTab
                    if let context = try arguments.string("context") {
                        tab = try resolveTab(context: context)
                    } else if let selected = controller.selectedTab {
                        tab = selected
                    } else {
                        throw AutomationToolError(.invalidArguments, "Window has no selected tab")
                    }
                    guard let webView = tab.webView as? BrowserWebView else {
                        throw AutomationToolError(.tabAsleep, "Tab \(tab.id.uuidString) has no web view")
                    }
                    let direction: NavigationSwipeDirection
                    switch try arguments.string("direction") ?? "back" {
                    case "back": direction = .back
                    case "forward": direction = .forward
                    default: throw AutomationToolError(.invalidArguments, "direction is back or forward")
                    }
                    let progress = try arguments.number("progress") ?? 0.5
                    guard (0...1).contains(progress) else {
                        throw AutomationToolError(.invalidArguments, "progress is 0 to 1")
                    }
                    let tracker = ScriptedNavigationSwipeTracker()
                    began = controller.beginNavigationSwipe(on: webView, direction: direction, tracker: tracker)
                    if began == true {
                        controller.navigationSwipe.scriptedTracker = tracker
                        let sign: CGFloat = direction == .back ? 1 : -1
                        tracker.step(sign * CGFloat(progress), phase: .began)
                    }
                case "finish":
                    guard let tracker = controller.navigationSwipe.scriptedTracker else {
                        throw AutomationToolError(.invalidArguments, "No swipe is held; begin one first")
                    }
                    controller.navigationSwipe.scriptedTracker = nil
                    let direction = controller.navigationSwipe.session?.direction ?? .back
                    if try arguments.bool("complete") ?? true {
                        tracker.complete(direction: direction)
                    } else {
                        tracker.cancel()
                    }
                default:
                    throw AutomationToolError(.invalidArguments, "action is state, begin or finish")
                }
                return [
                    "panes": .array(controller.navigationSwipePaneStates().map(Self.json)),
                    "selected_tab_id": .nullable(controller.selectedTabID?.uuidString),
                    "swipe_active": .bool(controller.navigationSwipe.session != nil),
                    "began": began.map(JSONValue.bool) ?? .null,
                    // A held forward swipe's card carries a picture (TASK-355).
                    "forward_picture": controller.navigationSwipe.session.map {
                        .bool($0.overlay.forwardPage != nil)
                    } ?? .null,
                ]
            })
    }

    private static func json(_ pane: NavigationSwipePaneState) -> JSONValue {
        let ownSwipe: Bool
        let forwardInMode: Bool
        switch pane.mode {
        case .webKit:
            ownSwipe = false
            forwardInMode = false
        case .ownSwipe(let canGoForward):
            ownSwipe = true
            forwardInMode = canGoForward
        }
        return [
            "tab_id": .string(pane.tabID.uuidString),
            "own_swipe": .bool(ownSwipe),
            "own_swipe_forward": .bool(forwardInMode),
            "gestures_enabled": .bool(pane.gesturesEnabled),
            "rubber_band_edges": pane.rubberBandEdges.map { .int(Int($0)) } ?? .null,
            "can_go_back": .bool(pane.facts.canGoBack),
            "can_go_forward": .bool(pane.facts.canGoForward),
            "is_normal_tab": .bool(pane.facts.isNormalTab),
            "opener_id": .nullable(pane.openerID?.uuidString),
            "opener_picture": .bool(pane.hasOpenerPicture),
            "forward_picture": .bool(pane.hasForwardPicture),
        ]
    }
    #endif
}
