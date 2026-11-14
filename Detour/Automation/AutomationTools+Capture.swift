import AppKit
import WebKit

/// Screenshots, appearance and Debug overrides (TASK-228.1 phase 3, AC #4,
/// #8, #16).
extension AutomationTools {

    var captureTools: [MCPTool] {
        var tools = [screenshot, setAppearance]
        #if DEBUG
        // Testing-only tools: absent from Release builds (AC #8).
        tools.append(setDebugOverride)
        #endif
        return tools
    }

    // MARK: screenshot

    private var screenshot: MCPTool {
        MCPTool(
            name: "screenshot",
            title: "Take a screenshot",
            description: "A PNG of a window's content (window_id), its sidebar (window_id with part sidebar) or a "
                + "tab's page (context), drawn inside Detour: no Screen Recording grant, no window shadow, works "
                + "with Detour in the background. Returned as image content unless include_image is false, and "
                + "written to save_to (an absolute .png path; an existing file is replaced only with overwrite) if "
                + "given. scale 1 (default) or 2 pixels per point; 2 is never more than the display has (the "
                + "result's scale says which was used). "
                + "source app (default) draws inside Detour: no grant needed, but glass the window server "
                + "composites is missing (the command palette, find bar and toasts come out blank; the sidebar "
                + "light in dark mode). source screen is the window server's own picture of a window "
                + "(window_id, part window): exact, but needs Screen Recording for Detour or the app that "
                + "launched it, else permission_denied.",
            inputSchema: MCPSchema.input([
                ("window_id", .integer("A window from list_windows")),
                ("part", .enumeration(["window", "sidebar"], "With window_id: the whole content (default) or the sidebar")),
                ("context", .string("A tab_id or tab:<id>: its page only")),
                ("save_to", .string("An absolute path ending in .png to write the image to")),
                ("include_image", .boolean("Return the image as image content (default true)")),
                ("scale", .integer("Pixels per point: 1 (default) or 2, at most the display's")),
                ("overwrite", .boolean("Replace a file already at save_to (default false)")),
                ("source", .enumeration(["app", "screen"], "app (default): drawn by Detour; screen: the window server's picture")),
            ]),
            outputSchema: MCPSchema.output([
                "width": MCPSchema.integerType,
                "height": MCPSchema.integerType,
                "pixel_width": MCPSchema.integerType,
                "pixel_height": MCPSchema.integerType,
                "saved_to": MCPSchema.nullableString,
                "bytes": MCPSchema.integerType,
                "scale": MCPSchema.integerType,
            ]),
            // Not read-only: save_to writes a file. Not destructive: it never
            // replaces one unless overwrite says so.
            annotations: ["readOnlyHint": false, "destructiveHint": false],
            output: { [self] arguments in
                let scale = try arguments.int("scale") ?? 1
                guard scale == 1 || scale == 2 else { throw AutomationToolError(.invalidArguments, "scale is 1 or 2") }
                let saveTo = try arguments.string("save_to")
                let destination = try saveTo.map(Self.pngDestination)
                if let destination, FileManager.default.fileExists(atPath: destination.path),
                   try arguments.bool("overwrite") != true {
                    throw AutomationToolError(.invalidArguments,
                                              "\(destination.path) exists; pass overwrite true to replace it")
                }
                let includeImage = try arguments.bool("include_image") ?? true
                let source = try arguments.string("source") ?? "app"
                guard source == "app" || source == "screen" else {
                    throw AutomationToolError(.invalidArguments, "source is app or screen")
                }
                let part = try arguments.string("part") ?? "window"
                guard part == "window" || part == "sidebar" else {
                    throw AutomationToolError(.invalidArguments, "part is window or sidebar")
                }

                let rep: NSBitmapImageRep
                if let context = try arguments.string("context") {
                    guard !arguments.has("window_id"), !arguments.has("part"), source == "app" else {
                        throw AutomationToolError(.invalidArguments, "Give context, or window_id with part, not both")
                    }
                    let target = try resolve(context: context)
                    guard let webView = target.webView else { throw AutomationToolError(.notDisplayed, "No web view") }
                    rep = try await AutomationCapture.page(webView)
                } else if let windowID = try arguments.int("window_id") {
                    let controller = try self.window(id: windowID)
                    if source == "screen" {
                        guard part == "window", let window = controller.window else {
                            throw AutomationToolError(.invalidArguments, "source screen takes a whole window")
                        }
                        rep = try await AutomationCapture.screen(window)
                    } else {
                        rep = part == "sidebar" ? try AutomationCapture.sidebar(controller)
                                                : try AutomationCapture.window(controller)
                    }
                } else {
                    throw AutomationToolError(.invalidArguments, "Give window_id or context")
                }

                // Never upsample: a 1x display's capture stays 1x when 2 is asked for.
                let native = max(1, Int((CGFloat(rep.pixelsWide) / max(1, rep.size.width)).rounded()))
                let used = min(scale, native)
                let image = AutomationCapture.scaled(rep, to: CGFloat(used))
                let png = try AutomationCapture.png(image)
                if let destination {
                    do {
                        try png.write(to: destination, options: .atomic)
                    } catch {
                        throw AutomationToolError(.invalidArguments,
                                                  "Cannot write \(destination.path): \(error.localizedDescription)")
                    }
                }
                let structured: JSONValue = [
                    "width": .int(Int(image.size.width.rounded())),
                    "height": .int(Int(image.size.height.rounded())),
                    "pixel_width": .int(image.pixelsWide),
                    "pixel_height": .int(image.pixelsHigh),
                    "saved_to": .nullable(destination?.path),
                    "bytes": .int(png.count),
                    "scale": .int(used),
                ]
                return MCPToolOutput(structured: structured, images: includeImage ? [png] : [])
            })
    }

    /// `path` as a file URL to write a PNG to: absolute, ending in .png, in a
    /// directory that exists.
    static func pngDestination(_ path: String) throws -> URL {
        guard path.hasPrefix("/") else {
            throw AutomationToolError(.invalidArguments, "save_to must be an absolute path")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.pathExtension.lowercased() == "png" else {
            throw AutomationToolError(.invalidArguments, "save_to must end in .png")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AutomationToolError(.invalidArguments, "The folder for \(path) does not exist")
        }
        return url
    }

    // MARK: set_appearance

    private var setAppearance: MCPTool {
        MCPTool(
            name: "set_appearance",
            title: "Set light or dark appearance",
            description: "Sets Detour's appearance (all its windows) to light or dark, or back to following the "
                + "system. Lasts until Detour quits or the next call.",
            inputSchema: MCPSchema.input([
                ("appearance", .enumeration(["light", "dark", "system"], "The appearance")),
            ], required: ["appearance"]),
            outputSchema: MCPSchema.output([
                "appearance": MCPSchema.stringType,
                "effective": MCPSchema.stringType,
            ]),
            annotations: ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true],
            handler: { arguments in
                let wanted = try arguments.requiredString("appearance")
                switch wanted {
                case "light": NSApp.appearance = NSAppearance(named: .aqua)
                case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
                case "system": NSApp.appearance = nil
                default: throw AutomationToolError(.invalidArguments, "appearance is light, dark or system")
                }
                let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return ["appearance": .string(wanted), "effective": .string(isDark ? "dark" : "light")]
            })
    }

    // MARK: set_debug_override (Debug builds only)

    #if DEBUG
    /// The data directory's defaults keys `SpaceCelebration` reads in Debug.
    static let spaceTossHopKey = SpaceCelebration.tossHopDefaultsKey
    static let spaceTossGravityKey = SpaceCelebration.tossGravityDefaultsKey

    static var debugOverrides: JSONValue {
        let defaults = UserDefaultsScope.defaults
        return [
            "reduce_motion": MotionPreference.reduceMotionOverride.map(JSONValue.bool) ?? .null,
            "space_toss_hop": (defaults.object(forKey: spaceTossHopKey) as? Double).map(JSONValue.double) ?? .null,
            "space_toss_gravity": (defaults.object(forKey: spaceTossGravityKey) as? Double).map(JSONValue.double) ?? .null,
        ]
    }

    private var setDebugOverride: MCPTool {
        MCPTool(
            name: "set_debug_override",
            title: "Set a Debug override",
            description: "Debug builds only. Overrides a setting for testing Detour itself: reduce_motion (on or "
                + "off, for this process, without touching the protected system setting), space_toss_hop and "
                + "space_toss_gravity (points and points/s², the space editor's toss, kept in the data "
                + "directory's defaults). value default clears the override. Returns every override.",
            inputSchema: MCPSchema.input([
                ("name", .enumeration(["reduce_motion", "space_toss_hop", "space_toss_gravity"], "The override")),
                ("value", .string("on, off or a number; default clears it")),
            ], required: ["name", "value"]),
            outputSchema: MCPSchema.output(["overrides": MCPSchema.objectType]),
            annotations: ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true],
            handler: { arguments in
                let name = try arguments.requiredString("name")
                // A client may send a number for a numeric override.
                guard let raw = arguments.values["value"] else {
                    throw AutomationToolError(.invalidArguments, "Missing required argument value")
                }
                guard let given = raw.stringValue ?? raw.doubleValue.map({ String($0) }) ?? raw.boolValue.map({ $0 ? "on" : "off" }) else {
                    throw AutomationToolError(.invalidArguments, "value is on, off, a number or default")
                }
                let value = given.lowercased()
                let clear = value == "default"
                switch name {
                case "reduce_motion":
                    switch value {
                    case "on", "true": MotionPreference.reduceMotionOverride = true
                    case "off", "false": MotionPreference.reduceMotionOverride = false
                    case "default": MotionPreference.reduceMotionOverride = nil
                    default: throw AutomationToolError(.invalidArguments, "reduce_motion is on, off or default")
                    }
                case "space_toss_hop", "space_toss_gravity":
                    let key = name == "space_toss_hop" ? Self.spaceTossHopKey : Self.spaceTossGravityKey
                    if clear {
                        UserDefaultsScope.defaults.removeObject(forKey: key)
                    } else {
                        guard let number = Double(value), number.isFinite,
                              name == "space_toss_hop" ? number >= 0 : number > 0 else {
                            throw AutomationToolError(.invalidArguments, "\(name) needs a number (gravity above 0)")
                        }
                        UserDefaultsScope.defaults.set(number, forKey: key)
                    }
                default:
                    throw AutomationToolError(.invalidArguments, "Unknown override \(name)")
                }
                return ["overrides": Self.debugOverrides]
            })
    }
    #endif
}
