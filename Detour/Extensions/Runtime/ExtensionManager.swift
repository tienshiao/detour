import Foundation
import WebKit
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "extension-manager")

/// Singleton lifecycle manager for web extensions.
/// Each `Profile` owns its own `WKWebExtensionController`; this class coordinates
/// install/uninstall/enable/disable across profiles and serves as the delegate for all controllers.
class ExtensionManager: NSObject, WKWebExtensionControllerDelegate {
    static let shared = ExtensionManager()

    /// Model array for UI (settings, toolbar, menus). Single source of truth.
    /// Each element's `.wkExtension` is populated asynchronously after init.
    var extensions: [WebExtension] = []

    /// The most recently focused space ID, used for `currentWindow` queries.
    var lastActiveSpaceID: UUID?

    let tabObserver = ExtensionTabObserver()

    /// Whether a profile created mid-session has its enabled extensions loaded
    /// right away (`profileWasAdded`). Always on in the app. The unit tests run
    /// inside the app, so `ExtensionManager.initialize` has registered the
    /// observer there too; `TestEnvironmentSetup` turns this off so the many
    /// tests that create profiles through `TabStore.shared.addProfile` and wire
    /// contexts by hand do not load every registered extension as a side effect.
    /// Tests of the new-profile path turn it back on for their duration.
    var loadsExtensionsIntoAddedProfiles = true

    /// Set once `loadInstalledExtensions` reaches its per-profile load. A profile
    /// added before then is loaded by that loop, so `profileWasAdded` leaves it
    /// alone (and never loads a half-populated `extensions` list).
    private(set) var hasLoadedInstalledExtensions = false

    /// Stored popup completionHandlers for extension-initiated popups (browser.action.openPopup).
    private var popupCompletionHandlers: [String: ((any Error)?) -> Void] = [:]

    /// Retained popover controllers for extension-initiated popups.
    private var activePopovers: [String: ExtensionPopoverController] = [:]

    /// A one-shot `sendNativeMessage` in flight: the host plus the reply WebKit is
    /// waiting for, answered at most once — by the host's response, by its exit,
    /// or by a nativeMessaging denial that tears it down (TASK-25).
    private final class OneShotNativeRequest {
        let host: NativeMessagingHost
        private var replyHandler: ((Any?, (any Error)?) -> Void)?

        init(host: NativeMessagingHost, replyHandler: @escaping (Any?, (any Error)?) -> Void) {
            self.host = host
            self.replyHandler = replyHandler
        }

        func finish(_ response: Any?, _ error: (any Error)?) {
            guard let handler = replyHandler else { return }
            replyHandler = nil
            handler(response, error)
        }
    }

    /// Retained native messaging hosts for one-shot sendMessage calls.
    private var activeMessagingHosts: [ObjectIdentifier: OneShotNativeRequest] = [:]

    /// Open keep-alive ports from background workers, at most one per extension per
    /// controller (see the `connectUsing` delegate method and
    /// ExtensionAPIPolyfill.nativePortKeepAliveJS). Held so the port objects stay
    /// alive until the worker disconnects them or the context is unloaded
    /// (`closeExtensionPorts(for:in:)`).
    private struct KeepAlivePortKey: Hashable {
        let controller: ObjectIdentifier
        let extensionID: String
    }
    private var keepAlivePorts: [KeepAlivePortKey: WKWebExtension.MessagePort] = [:]

    /// Live relayed WebSockets per extension per controller (TASK-8). A worker may
    /// hold several at once, so each session is keyed by its own identity; entries
    /// are dropped when the port goes away or the context unloads
    /// (`closeExtensionPorts(for:in:)`).
    private var webSocketRelays: [KeepAlivePortKey: [ObjectIdentifier: WebSocketRelaySession]] = [:]

    /// Whether each extension's worker should currently be pinging its keep-alive
    /// port, driven by real native-host connects/disconnects (TASK-16). Entries are
    /// created on demand and dropped as soon as they go idle.
    private var keepAliveStates: [KeepAlivePortKey: NativeHostKeepAliveState] = [:]

    /// `{type:"keepalive"}` replies received on each keep-alive port, for
    /// diagnostics and tests. Dropped with the state entry.
    private var keepAlivePingCounts: [KeepAlivePortKey: Int] = [:]

    /// Detour's own pinging of one armed keep-alive port (TASK-68): the timer and
    /// what the round trips have done so far. Exists only while the key is armed.
    private final class KeepAlivePinger {
        let timer: DispatchSourceTimer
        /// The sequence number of the last ping sent — also how many have been
        /// sent, since a pinger is created fresh on every arm.
        var seq = 0
        var lastPingSentAt: Date?
        /// The ping that has not been answered yet, if any. A ping still pending
        /// at the next tick is the symptom TASK-68 exists to make visible.
        var awaitingSeq: Int?

        init(timer: DispatchSourceTimer) { self.timer = timer }
    }
    private var keepAlivePingers: [KeepAlivePortKey: KeepAlivePinger] = [:]

    /// How often Detour pings an armed keep-alive port (TASK-68). Comfortably
    /// inside WebKit's 2-minute inactive-ports window, so two lost round trips in
    /// a row are still not enough to let the background be unloaded. A property
    /// rather than a constant so a test can shorten it; production never changes
    /// it.
    var keepAlivePingInterval: TimeInterval = 30

    /// Keep-alive ports accepted for each extension, for diagnostics and tests: a
    /// count that keeps climbing means contexts are taking the port from each
    /// other. Unlike the ping count it outlives an idle state (a replaced port
    /// passes through one) and is dropped only when the context unloads.
    private var keepAlivePortOpenCounts: [KeepAlivePortKey: Int] = [:]

    /// The real native messaging hosts currently connected for each extension, keyed
    /// by host identity (TASK-16). The keep-alive count is derived from this registry
    /// rather than from a flag captured in each connection's closures: those closures
    /// outlive an extension reload, and a late release from a host whose context is
    /// long gone must not disarm a keep-alive that a *new* host on the same
    /// (controller, extensionID) key is holding up. Removal is also what makes a
    /// double release (process exit and port disconnect both fire) a no-op.
    ///
    /// The port is kept next to its host so a nativeMessaging denial can end the
    /// extension's side of the connection too (TASK-25): `host.disconnect()`
    /// deliberately does not fire the host's own `onDisconnect`, which is what
    /// would otherwise close the port.
    private struct LiveNativeHost {
        let host: NativeMessagingHost
        let port: WKWebExtension.MessagePort
    }
    private var liveNativeHosts: [KeepAlivePortKey: [ObjectIdentifier: LiveNativeHost]] = [:]

    /// Whether a native-host connection from an extension may proceed.
    enum NativeHostAccess: Equatable {
        /// Detour's own polyfill host: accepted without the manifest permission.
        case polyfillHost
        /// Detour's WebSocket relay host (TASK-8): also accepted without the
        /// manifest permission — a worker may open a WebSocket whether or not it
        /// declares `nativeMessaging`, and this host is the only way it can.
        case webSocketRelayHost
        /// A real native host the extension declared `nativeMessaging` for, and
        /// the user has not denied it.
        case allowed
        /// A real native host without the manifest permission.
        case denied
        /// A real native host the manifest declares `nativeMessaging` for, but
        /// the user's saved nativeMessaging decision is a denial (TASK-25).
        case deniedByUser
    }

    /// The gate shared by `sendNativeMessage` and `connectNative`. `nativeMessaging`
    /// is auto-granted at the context level so the polyfill bridge works, so this
    /// is the real gate for anything but Detour's own hosts: the manifest must
    /// declare the permission, and the user's saved decision (Settings) must not
    /// be a denial. No saved decision means allowed — install saves every declared
    /// permission as granted, and Chrome grants a declared permission outright.
    ///
    /// Detour's own hosts are decided first and never consult the saved decision:
    /// they are the polyfill bridge and the WebSocket relay, not the user-facing
    /// "communicate with native applications" capability, and denying them would
    /// break `runtime` messaging and every worker WebSocket. `savedDecision` is an
    /// autoclosure so it is only read (a DB lookup) for a real host.
    static func nativeHostAccess(hostName: String, manifestPermissions: [String],
                                 savedDecision: @autoclosure () -> ExtensionPermissionStatus?) -> NativeHostAccess {
        if hostName == ExtensionPolyfillHandler.handlerName { return .polyfillHost }
        if hostName == WebSocketRelaySession.hostName { return .webSocketRelayHost }
        guard manifestPermissions.contains(ExtensionPermissionRecord.nativeMessagingKey) else { return .denied }
        return savedDecision() == .denied ? .deniedByUser : .allowed
    }

    /// `nativeHostAccess` for a delegate callback: the manifest and the saved
    /// decision of the profile-verified extension id (none for a stale context,
    /// which therefore reads as `.denied` for any real host).
    private func nativeHostAccess(hostName: String, extensionID: String?) -> NativeHostAccess {
        let manifestPermissions = extensionID
            .flatMap { self.extension(withID: $0)?.manifest.permissions } ?? []
        return Self.nativeHostAccess(
            hostName: hostName, manifestPermissions: manifestPermissions,
            savedDecision: extensionID.flatMap {
                AppDatabase.shared.permissionStatus(
                    extensionID: $0, key: ExtensionPermissionRecord.nativeMessagingKey, type: .apiPermission)
            })
    }

    /// What an extension sees when the user denied nativeMessaging: Chrome's own
    /// wording for a host the extension may not use, delivered the same way as
    /// every other native-host failure — a rejected `sendNativeMessage` promise /
    /// `runtime.lastError`, or a port disconnected with that error.
    static let nativeHostForbiddenMessage = "Access to the specified native messaging host is forbidden."

    /// The disconnect reason on a keep-alive port evicted by a newer one from the
    /// same extension (see the `.polyfillHost` case of the `connectUsing` delegate
    /// method). `ExtensionAPIPolyfill.nativePortKeepAliveJS` embeds the same string
    /// and stops, instead of reconnecting, when its port ends with it.
    static let keepAliveSupersededMessage = "Detour keep-alive port superseded by a newer one"

    /// The message type Detour sends on an evicted keep-alive port just before
    /// disconnecting it: WebKit does not deliver a native disconnect's error to
    /// an established port's `onDisconnect` (neither `port.error` nor
    /// `runtime.lastError`; measured 2026-09-13), so this is how the polyfill
    /// learns the reason.
    static let keepAliveSupersededType = "keepalive-superseded"

    static func nativeHostForbiddenError() -> NSError {
        NSError(domain: "DetourExtension", code: -1,
                userInfo: [NSLocalizedDescriptionKey: nativeHostForbiddenMessage])
    }

    /// The disconnect reason on a native host port whose background context was
    /// replaced by a new one (TASK-67, the supersede path of `connectUsing`).
    /// The context that opened it is already gone, so nothing is likely to read
    /// this; it exists so the port ends with a reason rather than in silence.
    static let replacedBackgroundContextMessage =
        "The extension's background context was replaced; Detour closed its native host connection."

    static func replacedBackgroundContextError() -> NSError {
        NSError(domain: "DetourExtension", code: -1,
                userInfo: [NSLocalizedDescriptionKey: replacedBackgroundContextMessage])
    }

    // MARK: - Notifications

    static let extensionsDidChangeNotification = Notification.Name("ExtensionManagerExtensionsDidChange")
    static let tabShouldSelectNotification = Notification.Name("extensionTabShouldSelect")
    static let popupOpenURLNotification = Notification.Name("extensionPopupOpenURL")
    static let openOptionsPageNotification = Notification.Name("extensionOpenOptionsPage")
    static let extensionActionDidChangeNotification = Notification.Name("extensionActionDidChange")
    static let extensionPinStateDidChangeNotification = Notification.Name("extensionPinStateDidChange")

    // MARK: - Init

    override init() {
        super.init()
    }

    // MARK: - Initialize

    func initialize() {
        Task { @MainActor in
            await loadInstalledExtensions()
        }

        TabStore.shared.addObserver(tabObserver)

        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification, object: nil
        )
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let wc = window.windowController as? BrowserWindowController else { return }
        for profile in TabStore.shared.profiles {
            profile.extensionController.didFocusWindow(wc)
        }
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        // Defer check: NSApp.keyWindow hasn't updated yet in the same run loop pass
        DispatchQueue.main.async {
            if NSApp.keyWindow?.windowController is BrowserWindowController { return }
            for profile in TabStore.shared.profiles {
                profile.extensionController.didFocusWindow(nil)
            }
        }
    }

    @MainActor
    private func loadInstalledExtensions() async {
        let records = AppDatabase.shared.loadExtensions()

        // Parse manifests and create models (fast, synchronous)
        var pendingExtensions: [WebExtension] = []
        for record in records {
            let basePath = URL(fileURLWithPath: record.basePath)
            let diskManifestURL = basePath.appendingPathComponent("manifest.json")
            let manifest: ExtensionManifest
            if let diskManifest = try? ExtensionManifest.parse(at: diskManifestURL) {
                manifest = diskManifest
            } else if let dbManifest = try? JSONDecoder().decode(ExtensionManifest.self, from: record.manifestJSON) {
                manifest = dbManifest
            } else {
                log.error("Failed to decode manifest for extension \(record.id, privacy: .public)")
                continue
            }

            let ext = WebExtension(id: record.id, manifest: manifest, basePath: basePath, isEnabled: record.isEnabled)
            pendingExtensions.append(ext)
        }

        // Inject polyfills into each extension before loading
        for ext in pendingExtensions {
            injectServiceWorkerPolyfill(into: ext)
            writeContentPolyfill(into: ext)
        }

        // Load WKWebExtension resources in parallel (async I/O)
        await withTaskGroup(of: (WebExtension, WKWebExtension?).self) { group in
            for ext in pendingExtensions {
                group.addTask { @MainActor in
                    do {
                        let wkExt = try await WKWebExtension(resourceBaseURL: ext.basePath)
                        return (ext, wkExt)
                    } catch {
                        log.error("Failed to load WKWebExtension for \(ext.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        return (ext, nil)
                    }
                }
            }
            for await (ext, wkExt) in group {
                ext.wkExtension = wkExt
                extensions.append(ext)
                log.info("Loaded extension \(ext.manifest.name, privacy: .public) (\(ext.id, privacy: .public)), enabled: \(ext.isEnabled)")
            }
        }

        // Load enabled extensions into each profile's controller
        // (notifyExistingTabs is called inside loadExtensionsIntoProfile after contexts are registered).
        // From here on a newly added profile is loaded as it is added (profileWasAdded).
        // Drop anything cached before the extensions existed *first*, so each
        // profile's set is read fresh by the load below and then stays cached for
        // the UI reads that follow the notification (the pinned toolbar icons
        // read it on extensionsDidChangeNotification).
        hasLoadedInstalledExtensions = true
        invalidateEnabledExtensionsCache()
        for profile in TabStore.shared.profiles {
            loadExtensionsIntoProfile(profile)
        }

        NotificationCenter.default.post(name: Self.extensionsDidChangeNotification, object: nil)
    }

    /// Load every extension that is enabled in `profile` (`isEnabled(extensionID:inProfile:)`)
    /// into its controller.
    @MainActor
    func loadExtensionsIntoProfile(_ profile: Profile) {
        log.info("Loading extensions for profile \(profile.name, privacy: .public)")

        // The whole enabled set in one query rather than one read per installed
        // extension (TASK-46), and shared with the UI's reads through
        // `enabledIDsCache`. `enabledExtensionIDs(for:)` encodes the same rule as
        // `isEnabled(extensionID:inProfile:)` and every writer of either flag
        // invalidates the cache, so the decision below is the one
        // `reconcileExtensionContext` would have read for itself.
        let enabledIDs = enabledExtensionIDs(for: profile.id)

        // Load all contexts. Background content loads on demand when needed.
        for ext in extensions {
            reconcileExtensionContext(ext, in: profile, shouldLoad: enabledIDs.contains(ext.id))
            wakeForPendingInstalledEvent(extensionID: ext.id, in: profile)
        }

        // Pages restored from the previous launch are on origins that died with
        // it; move them onto the contexts just loaded (TASK-24). Before the
        // announce below, as for a context reload: each moved tab is left asleep
        // and announces itself once, on wake.
        profile.resolvePendingExtensionPages()
        notifyExistingTabs(for: profile)
    }

    /// A profile was created mid-session (`TabStore.addProfile`, or the Private
    /// profile created when the first private window opens). Nothing else loads
    /// extensions into it before a relaunch, so load them now through the same
    /// path launch uses: `loadExtensionsIntoProfile` applies the per-profile rule
    /// (TASK-26), wakes a worker owed `runtime.onInstalled` — a new profile has no
    /// ledger row, so that is `install` (TASK-22) — and resolves pending pages
    /// (TASK-24). Once loaded, the per-profile Settings toggles reconcile it like
    /// any other profile.
    func profileWasAdded(_ profile: Profile) {
        guard loadsExtensionsIntoAddedProfiles, hasLoadedInstalledExtensions else { return }
        MainActor.assumeIsolated {
            loadExtensionsIntoProfile(profile)
        }
    }

    /// Start the extension's background context in `profile` when it is still
    /// owed a `runtime.onInstalled` event, so the event arrives now — right after
    /// the install or update, or at launch for one a crash or a disabled profile
    /// left undelivered — rather than whenever something else next wakes it.
    /// Delivery itself is that context's claim (`RuntimeInstalledEvent`); an
    /// extension with no background content at all — no service worker, no
    /// `background.scripts`/`page` (TASK-43) — never claims, so it is not woken,
    /// and neither is the Private profile's, which is never owed the event
    /// (TASK-29).
    func wakeForPendingInstalledEvent(extensionID: String, in profile: Profile) {
        guard let pending = installedEventOwingWake(extensionID: extensionID, in: profile),
              let context = profile.extensionContext(for: extensionID) else { return }
        log.info("runtime.onInstalled: \(pending.reason.rawValue, privacy: .public) pending for \(extensionID, privacy: .public) in profile \(profile.name, privacy: .public); waking its background context")
        context.loadBackgroundContent { error in
            if let error {
                let nsError = error as NSError
                log.error("runtime.onInstalled: waking \(extensionID, privacy: .public) failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code)")
            }
        }
    }

    /// The event `wakeForPendingInstalledEvent` would wake the background context
    /// for, or nil when it would not wake it. Separate so tests can check the
    /// decision without starting anything.
    ///
    /// Both `hasBackgroundContent` checks are the same question asked of the two
    /// sources — WebKit's parse of the extension and Detour's own — and both have
    /// to agree before a context is woken: Detour's decides only from a manifest
    /// it could decode, WebKit's from the extension it will actually run.
    func installedEventOwingWake(extensionID: String, in profile: Profile) -> RuntimeInstalledEvent.Details? {
        guard !profile.isIncognito,
              let context = profile.extensionContext(for: extensionID),
              context.webExtension.hasBackgroundContent,
              self.extension(withID: extensionID)?.manifest.background?.hasBackgroundContent == true,
              let version = context.webExtension.version else { return nil }
        return AppDatabase.shared.pendingRuntimeInstalledEvent(
            extensionID: extensionID, profileID: profile.id.uuidString,
            isPrivateProfile: profile.isIncognito, currentVersion: version)
    }

    /// Re-associate the profile's open windows and tabs with a freshly reloaded
    /// extension context (Profile.recoverFromBackgroundLoadFailure). Only the
    /// reloaded context is told: the profile's other contexts already know these
    /// windows and tabs, and re-announcing them surfaces duplicate lifecycle events.
    func didReloadExtensionContext(_ context: WKWebExtensionContext, in profile: Profile) {
        notifyExistingTabs(for: profile, contexts: [context])
    }

    /// Close every tab in `profile` showing a page from the unloaded context's
    /// origin (`oldBase`, as returned by `Profile.unloadExtension`).
    ///
    /// Used when an extension goes away for good — disabled or uninstalled. There
    /// is no replacement origin to move these pages to (that is
    /// `Profile.retargetExtensionPages`, for a reload), and a page whose context
    /// is unloaded is inert: its `chrome.*` bindings are gone and the polyfill
    /// bridge no longer recognises its origin. So the tab is closed rather than
    /// navigated somewhere arbitrary — and closed through `TabStore`, so
    /// selection, split groups and the sidebar all stay consistent. The close is
    /// deliberately *not* undoable and not recorded on the closed-tab stack: the
    /// page's origin died with its context (a re-enable mints a fresh one), so a
    /// restored tab could never load.
    ///
    /// A pinned entry and a favourite keep their tile (dormant), matching what
    /// closing one by hand does. A peek overlay has no `TabStore` close API and
    /// cannot show an extension page today (it is built from the space
    /// configuration), so it is left alone.
    private func closeExtensionPages(in profile: Profile, from oldBase: URL?) {
        guard let host = oldBase?.host else { return }
        let store = TabStore.shared
        // Resolved up front: every mutation below re-resolves its target by id,
        // so a close that shifts a list cannot make a later one act on the wrong tab.
        let locations = profile.extensionPageLocations(forOriginHost: host)
        guard !locations.isEmpty else { return }

        var closed = 0
        for location in locations {
            switch location {
            case .tab(let space, let tab):
                store.closeTab(id: tab.id, in: space, undoable: false)
                closed += 1
            case .pinned(let space, let entry, _):
                store.closePinnedTab(id: entry.id, in: space, undoable: false)
                closed += 1
            case .favorite(let favorite, let tab):
                // `deactivateFavorite` only tears the tab down and refreshes the
                // favourites strip; a window displaying it would keep a selection
                // that no longer resolves and an empty pane. Same remedy as the
                // profile swap in `TabStore.updateSpace`: move each space's
                // selection off the tab first, then have windows on those spaces
                // re-select (the favourite is displayable from any of them).
                let affectedSpaces = store.spaces.filter { $0.profileID == profile.id }
                for space in affectedSpaces where space.selectedTabID == tab.id {
                    space.selectedTabID = space.tabs.first?.id
                        ?? space.pinnedEntries.first(where: { $0.tab != nil })?.tab?.id
                }
                store.deactivateFavorite(id: favorite.id, profileID: profile.id)
                for space in affectedSpaces {
                    NotificationCenter.default.post(
                        name: .spaceTabsNeedRehost, object: nil,
                        userInfo: ["spaceID": space.id, "tabIDs": Set([tab.id])]
                    )
                }
                closed += 1
            case .peek:
                break
            }
        }

        if closed > 0 {
            log.info("Closed \(closed) extension page tab(s) in profile \(profile.name, privacy: .public) after its context was unloaded")
        }
    }

    /// Close every page of `extensionID` in `profile` once it is disabled or
    /// uninstalled there: those on the unloaded context's origin (`unloadedBase`,
    /// from `Profile.unloadExtension`; nil when no context was loaded) and those
    /// still on a pending origin — restored from the previous launch before a
    /// context loaded (TASK-24), which `closeExtensionPages(in:from:)` on the
    /// unloaded base alone would miss.
    ///
    /// A disable keeps the pending origins and registers the unloaded one, so the
    /// dormant pinned and favourite tiles left on them keep their identity (it is
    /// saved with them) and are moved onto the new origin if the extension is
    /// re-enabled. An uninstall forgets them: nothing will serve them again, and
    /// the next restore drops those tiles.
    private func closePagesOfUnloadedExtension(
        _ extensionID: String, in profile: Profile, unloadedBase: URL?, uninstalling: Bool
    ) {
        closeExtensionPages(in: profile, from: unloadedBase)
        for pendingBase in profile.pendingExtensionOriginBaseURLs(for: extensionID, forget: uninstalling) {
            closeExtensionPages(in: profile, from: pendingBase)
        }
        if !uninstalling, let host = unloadedBase?.host {
            profile.registerPendingExtensionOrigin(host: host, extensionID: extensionID)
        }
    }

    /// Drop every port Detour holds for the extension in `controller`'s profile:
    /// the background's keep-alive port and any relayed WebSockets. Called from
    /// `Profile.unloadExtension` so a reload, disable or uninstall does not strand
    /// a retained port or leave a socket running for a context that is gone.
    func closeExtensionPorts(for extensionID: String, in controller: WKWebExtensionController) {
        let key = KeepAlivePortKey(controller: ObjectIdentifier(controller), extensionID: extensionID)

        // WebKit closes an unloaded context's ports itself, so the extension side
        // of each conversation is already ending: pass no error and only end the
        // host processes, which would otherwise be left talking to a dead context.
        let torn = tearDownNativeConnections(for: key, disconnectingPortsWith: nil)
        if torn.relays > 0 {
            log.info("Tore down \(torn.relays) relayed WebSocket(s) for \(extensionID, privacy: .public) (context unloaded)")
        }
        keepAlivePortOpenCounts.removeValue(forKey: key)
        if let port = keepAlivePorts.removeValue(forKey: key) {
            port.disconnect(throwing: nil)
            log.info("Keep-alive port closed for \(extensionID, privacy: .public) (context unloaded)")
        }
    }

    /// End every long-lived native connection Detour holds for one (controller,
    /// extension) key — real `connectNative` hosts (process killed, and their
    /// WebKit port disconnected when `hostError` says with what) and relayed
    /// WebSockets (TASK-8) — and reset the keep-alive bookkeeping with them: the
    /// whole context they belonged to is gone, so `contextUnloaded` is the event,
    /// and nothing is sent anywhere. One-shot `sendNativeMessage` hosts are *not*
    /// swept: `activeMessagingHosts` is keyed by host alone and records no
    /// controller, so they end the way they always have, with the host's reply
    /// or exit (`disconnectRealNativeHosts` sweeps them, by extension id only).
    ///
    /// Every registry entry is taken away *as a whole* before anything is
    /// disconnected, so each teardown this sets off finds nothing left to release:
    /// a relay's `onDisconnect`, a host's process exit and its port's disconnect
    /// all release through a removal that has already happened, which is what
    /// makes the release exactly once.
    ///
    /// Shared by the two paths that know a background context has gone away — the
    /// context unload (`closeExtensionPorts`) and the arrival of a replacement
    /// context's keep-alive port (TASK-67) — so the two cannot drift apart.
    @discardableResult
    private func tearDownNativeConnections(
        for key: KeepAlivePortKey, disconnectingPortsWith hostError: NSError?
    ) -> (hosts: Int, relays: Int) {
        let relays = webSocketRelays.removeValue(forKey: key) ?? [:]
        for relay in relays.values {
            relay.tearDown()
        }
        let hosts = liveNativeHosts.removeValue(forKey: key) ?? [:]
        applyKeepAlive(.contextUnloaded, for: key)
        for live in hosts.values {
            live.host.disconnect()
            if let hostError {
                live.port.disconnect(throwing: hostError)
            }
        }
        return (hosts.count, relays.count)
    }

    /// Tear down every real native host the extension has running, in every
    /// profile: its long-lived `connectNative` hosts (process killed, port
    /// disconnected with the forbidden error, keep-alive released) and any
    /// one-shot `sendNativeMessage` still waiting for its reply (process killed,
    /// reply rejected). Detour's built-in hosts are untouched — the keep-alive
    /// port and relayed WebSockets are not in these registries. Called when the
    /// user denies nativeMessaging (TASK-25). Returns how many hosts were torn
    /// down.
    @discardableResult
    func disconnectRealNativeHosts(for extensionID: String) -> Int {
        let error = Self.nativeHostForbiddenError()
        var torn = 0

        for key in liveNativeHosts.keys where key.extensionID == extensionID {
            // Take the whole entry first: each port's disconnect handler and each
            // host's release then find nothing left to release, so the keep-alive
            // is released exactly once per host, here.
            let hosts = liveNativeHosts.removeValue(forKey: key) ?? [:]
            for live in hosts.values {
                live.host.disconnect()
                live.port.disconnect(throwing: error)
                applyKeepAlive(.hostDisconnected, for: key)
                torn += 1
            }
        }

        for (hostKey, request) in activeMessagingHosts where request.host.extensionID == extensionID {
            activeMessagingHosts.removeValue(forKey: hostKey)
            request.host.disconnect()
            request.finish(nil, error)
            torn += 1
        }

        if torn > 0 {
            log.info("Disconnected \(torn) native host(s) for \(extensionID, privacy: .public): nativeMessaging denied")
        }
        return torn
    }

    /// Start a relayed WebSocket for a worker that connected to the relay host
    /// (TASK-8, `WebSocketRelaySession`). The session owns the socket; this owns
    /// the session until its port goes away — for either reason, which is what the
    /// adapter's single `onDisconnect` signal is for.
    private func openWebSocketRelay(port: WKWebExtension.MessagePort,
                                    controller: WKWebExtensionController,
                                    extensionID: String) {
        let key = KeepAlivePortKey(controller: ObjectIdentifier(controller), extensionID: extensionID)
        let relayPort = MessagePortRelayPort(port)
        // The handshake carries the owning profile's cookies (see
        // `WebSocketRelaySession`). No profile owns this controller only in tests
        // that build one by hand; those sockets simply send no cookies.
        let cookieProvider: WebSocketRelaySession.CookieProvider? = profile(for: controller).map { profile in
            { [weak profile] _, completion in
                guard let profile else {
                    completion([])
                    return
                }
                profile.dataStore.httpCookieStore.getAllCookies(completion)
            }
        }
        let session = WebSocketRelaySession(port: relayPort, extensionID: extensionID,
                                            cookieProvider: cookieProvider)
        let sessionKey = ObjectIdentifier(session)
        webSocketRelays[key, default: [:]][sessionKey] = session

        // An open relayed socket keeps the worker alive exactly as a native host
        // does (TASK-16): a quiet long-lived socket — 1Password's notifier — would
        // otherwise die with the worker WebKit unloads after ~2.5 minutes idle,
        // and the extension would see an error and a 1006 every few minutes.
        applyKeepAlive(.hostConnected, for: key)

        // The session installed its own teardown on the adapter; keep it and drop
        // the registry entry after it. The removal is the token that makes the
        // release happen exactly once — a context unload takes the whole entry
        // away first, so the teardown it triggers finds nothing left to release
        // (and `contextUnloaded` has already reset the keep-alive anyway).
        let sessionDisconnect = relayPort.onDisconnect
        relayPort.onDisconnect = { [weak self] in
            sessionDisconnect?()
            guard let self,
                  self.webSocketRelays[key]?.removeValue(forKey: sessionKey) != nil else { return }
            if self.webSocketRelays[key]?.isEmpty == true {
                self.webSocketRelays.removeValue(forKey: key)
            }
            self.applyKeepAlive(.hostDisconnected, for: key)
            log.info("Relayed WebSocket port closed for \(extensionID, privacy: .public)")
        }
        log.info("Relayed WebSocket port opened for \(extensionID, privacy: .public)")
    }

    /// Feed an event to the extension's keep-alive state machine and carry out what
    /// it asks for on the background's keep-alive port (TASK-16). Main-thread only:
    /// every caller is a delegate callback or a native-host callback dispatched to
    /// the main queue.
    private func applyKeepAlive(_ event: NativeHostKeepAliveState.Event, for key: KeepAlivePortKey) {
        var state = keepAliveStates[key] ?? NativeHostKeepAliveState()
        let action = state.apply(event)
        if state.isIdle {
            keepAliveStates.removeValue(forKey: key)
            keepAlivePingCounts.removeValue(forKey: key)
        } else {
            keepAliveStates[key] = state
        }

        // Detour drives the pings, so they stop the moment the worker is not armed
        // any more — a stop, a port that closed or was replaced, a context unload,
        // or a control send that never arrived (`reconcile` starts them again).
        if !state.armed {
            stopKeepAlivePinging(for: key)
        }

        let extID = key.extensionID
        switch action {
        case .none:
            return
        case .sendStart:
            log.info("Keep-alive armed for \(extID, privacy: .public): \(state.connectedHosts) native host(s) connected")
            sendKeepAliveControl("keepalive-start", for: key)
            startKeepAlivePinging(for: key)
        case .sendStop:
            log.info("Keep-alive disarmed for \(extID, privacy: .public): no native host connected")
            sendKeepAliveControl("keepalive-stop", for: key)
        }
    }

    /// Begin pinging the extension's keep-alive port: one ping immediately (the
    /// worker's reply is what resets WebKit's inactive-ports timer, so the arm
    /// itself must produce one) and then one every `keepAlivePingInterval`.
    ///
    /// **Why Detour pings and the background only answers** (TASK-68): WebKit
    /// defers the background's unload until 2 minutes after the last message the
    /// *background* posted on one of its open ports — a message Detour sends does
    /// not count, the reply does. The worker used to run that clock itself on a
    /// `setInterval`, and in production (2026-09-13) workers were unloaded ~170 s
    /// after starting with the keep-alive armed the whole time: 120 s past what
    /// would have been the second ping, i.e. its timers stopped firing and nothing
    /// could tell. A timer on Detour's side cannot be suspended with the worker,
    /// and every round trip is observable here, so a stalled background now shows
    /// up in the log instead of as a silent unload.
    private func startKeepAlivePinging(for key: KeepAlivePortKey) {
        stopKeepAlivePinging(for: key)
        // Strict: an ordinary dispatch timer may be deferred well past its leeway
        // by App Nap and timer coalescing once every window is occluded, and a
        // deferred tick is a missed ping *and* a missed "no reply" check — the
        // silent gap this timer exists to close.
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(deadline: .now() + keepAlivePingInterval,
                       repeating: keepAlivePingInterval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.sendKeepAlivePing(for: key)
        }
        keepAlivePingers[key] = KeepAlivePinger(timer: timer)
        timer.resume()
        sendKeepAlivePing(for: key)
    }

    /// Stop pinging the extension's keep-alive port and forget the round trips.
    private func stopKeepAlivePinging(for key: KeepAlivePortKey) {
        guard let pinger = keepAlivePingers.removeValue(forKey: key) else { return }
        pinger.timer.cancel()
    }

    /// One `{type:"keepalive-ping", seq}` on the extension's keep-alive port. The
    /// polyfill answers `{type:"keepalive", seq}` at once (`messageHandler` on the
    /// port counts it), and a ping still unanswered when the next one goes out is
    /// logged as an error: at that point the background is stalled, its timers are
    /// suspended, or the port is dead, and WebKit's unload is roughly 90 s away.
    ///
    /// A ping that fails to *send* is only logged: unlike a control message it
    /// changes nothing in the worker, the next tick retries it anyway, and going
    /// through `handleKeepAliveControlFailure` would disarm and re-arm the state —
    /// discarding this pinger's ledger (`awaitingSeq`, the sequence numbers in the
    /// log) exactly when a failure is what the ledger is for, and doubling the
    /// 1 Hz retry loop on a port that stays registered but cannot be sent on.
    private func sendKeepAlivePing(for key: KeepAlivePortKey) {
        guard let pinger = keepAlivePingers[key], let port = keepAlivePorts[key] else { return }
        let extID = key.extensionID
        let now = Date()

        if let pending = pinger.awaitingSeq {
            let waited = pinger.lastPingSentAt.map { now.timeIntervalSince($0) } ?? 0
            log.error("Keep-alive for \(extID, privacy: .public): ping #\(pending) sent \(waited, format: .fixed(precision: 0), privacy: .public) s ago has no reply (worker stalled, its timers suspended, or the port is dead); sending #\(pending + 1)")
        }

        pinger.seq += 1
        let seq = pinger.seq
        pinger.lastPingSentAt = now
        pinger.awaitingSeq = seq
        port.sendMessage(["type": "keepalive-ping", "seq": seq], completionHandler: { error in
            guard let error else { return }
            log.error("Keep-alive ping #\(seq) to \(extID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        })
        log.info("Keep-alive ping #\(seq) sent to \(extID, privacy: .public)")
    }

    /// A `{type:"keepalive", seq}` reply came back on the extension's keep-alive
    /// port: this is the post WebKit counts as background activity, so it is the
    /// one line that says the keep-alive is actually working.
    private func recordKeepAliveReply(seq: Int?, for key: KeepAlivePortKey) {
        keepAlivePingCounts[key, default: 0] += 1
        let extID = key.extensionID
        guard let pinger = keepAlivePingers[key] else {
            // A reply after the disarm (or on a port whose pinger is gone): still
            // counted, but there is no round trip to measure.
            log.info("Keep-alive reply #\(seq ?? -1) from \(extID, privacy: .public) (not pinging)")
            return
        }
        let milliseconds = pinger.lastPingSentAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
        if seq == nil || seq == pinger.awaitingSeq {
            pinger.awaitingSeq = nil
        }
        log.info("Keep-alive reply #\(seq ?? -1) from \(extID, privacy: .public) (\(milliseconds) ms)")
    }

    /// Send one `keepalive-start` / `keepalive-stop` on the extension's keep-alive
    /// port. A failed send leaves the worker doing the *opposite* of what the state
    /// machine believes, so it is not just logged: `controlSendFailed` clears `armed`
    /// and a `reconcile` a second later re-sends the control message if it is still
    /// wanted (and stops re-sending as soon as it is not).
    private func sendKeepAliveControl(_ type: String, for key: KeepAlivePortKey) {
        guard let port = keepAlivePorts[key] else { return }
        let extID = key.extensionID
        port.sendMessage(["type": type], completionHandler: { [weak self, weak port] error in
            guard let error else {
                log.info("Keep-alive '\(type, privacy: .public)' delivered to \(extID, privacy: .public)")
                return
            }
            log.error("Keep-alive '\(type, privacy: .public)' failed for \(extID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            guard let self, let port else { return }
            // The keep-alive bookkeeping is main-thread only (see `applyKeepAlive`);
            // WebKit calls this back on the main queue, but do not rely on it.
            let recover = { self.handleKeepAliveControlFailure(for: key, on: port) }
            if Thread.isMainThread { recover() } else { DispatchQueue.main.async(execute: recover) }
        })
    }

    /// A control message never reached the worker: forget that it was sent and
    /// re-evaluate a second later, which re-sends it while it is still wanted.
    private func handleKeepAliveControlFailure(for key: KeepAlivePortKey, on port: WKWebExtension.MessagePort) {
        applyKeepAlive(.controlSendFailed, for: key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak port] in
            // Only retry on the port that failed: a port replaced or closed since
            // then got its own portOpened/portClosed event, which already left the
            // state (and the new worker port) consistent.
            guard let self, let port, self.keepAlivePorts[key] === port else { return }
            self.applyKeepAlive(.reconcile, for: key)
        }
    }

    /// The keep-alive state for an extension in a controller, or nil when nothing
    /// is tracked. Tests only (`ExtensionPolyfillProfileWiringTests`).
    func keepAliveStateForTesting(controller: WKWebExtensionController, extensionID: String) -> NativeHostKeepAliveState? {
        keepAliveStates[KeepAlivePortKey(controller: ObjectIdentifier(controller), extensionID: extensionID)]
    }

    /// Ping replies received on the extension's keep-alive port so far. Tests only.
    func keepAlivePingCountForTesting(controller: WKWebExtensionController, extensionID: String) -> Int {
        keepAlivePingCounts[KeepAlivePortKey(controller: ObjectIdentifier(controller), extensionID: extensionID)] ?? 0
    }

    /// Pings Detour has sent on the extension's keep-alive port since it was
    /// armed, and whether one is still unanswered (TASK-68). Tests only.
    func keepAlivePingsSentForTesting(controller: WKWebExtensionController,
                                      extensionID: String) -> (sent: Int, awaiting: Int?)? {
        let key = KeepAlivePortKey(controller: ObjectIdentifier(controller), extensionID: extensionID)
        guard let pinger = keepAlivePingers[key] else { return nil }
        return (pinger.seq, pinger.awaitingSeq)
    }

    /// Keep-alive ports accepted for the extension since its context loaded. Tests only.
    func keepAlivePortOpenCountForTesting(controller: WKWebExtensionController, extensionID: String) -> Int {
        keepAlivePortOpenCounts[KeepAlivePortKey(controller: ObjectIdentifier(controller), extensionID: extensionID)] ?? 0
    }

    /// Real native messaging hosts currently registered as live for the extension.
    /// Tests only.
    func liveNativeHostCountForTesting(controller: WKWebExtensionController, extensionID: String) -> Int {
        liveNativeHosts[KeepAlivePortKey(controller: ObjectIdentifier(controller), extensionID: extensionID)]?.count ?? 0
    }

    /// One-shot native messages still waiting for their host's reply. Tests only.
    func pendingOneShotNativeMessageCountForTesting(extensionID: String) -> Int {
        activeMessagingHosts.values.filter { $0.host.extensionID == extensionID }.count
    }

    /// Relayed WebSockets currently open for the extension (TASK-8). Tests only.
    func webSocketRelayCountForTesting(controller: WKWebExtensionController, extensionID: String) -> Int {
        webSocketRelays[KeepAlivePortKey(controller: ObjectIdentifier(controller), extensionID: extensionID)]?.count ?? 0
    }

    /// Drive a real native host's connect/disconnect without spawning one, so the
    /// worker-facing half of the keep-alive can be tested end to end. Tests only.
    func simulateNativeHostForTesting(connected: Bool, controller: WKWebExtensionController, extensionID: String) {
        let key = KeepAlivePortKey(controller: ObjectIdentifier(controller), extensionID: extensionID)
        applyKeepAlive(connected ? .hostConnected : .hostDisconnected, for: key)
    }

    /// Tell `contexts` (default: every context loaded in the profile) about the
    /// profile's open windows and tabs.
    private func notifyExistingTabs(for profile: Profile, contexts: [WKWebExtensionContext]? = nil) {
        let contexts = contexts ?? Array(profile.extensionContexts.values)
        let windowControllers = NSApp.windows.compactMap { $0.windowController as? BrowserWindowController }
            .filter { $0.activeSpace?.profileID == profile.id }

        for wc in windowControllers {
            for context in contexts {
                context.didOpenWindow(wc)
            }
        }

        // Report ALL tabs across ALL spaces for this profile, not just the active space.
        // WKWebExtension uses didOpenTab to associate web views with WKWebExtensionTab objects;
        // without this, sender.tab is null for content script messages from non-active spaces.
        // Report non-sleeping tabs across all spaces for this profile.
        // Sleeping tabs have no webView and can't run content scripts.
        //
        // The enumeration is the same one `tabs(for:)` uses (`extensionWindowTabs`),
        // so a loading context and a window never disagree about which tabs exist
        // (TASK-50).
        let profileSpaces = TabStore.shared.spaces.filter { $0.profileID == profile.id }
        let tabs = extensionWindowTabs(pinned: profileSpaces.flatMap(\.pinnedTabs),
                                       normal: profileSpaces.flatMap(\.tabs),
                                       favorites: profile.favoriteTabs)
        for tab in tabs where !tab.isSleeping {
            ExtensionTabLifecycle.didOpen(tab, in: profile, contexts: contexts)
        }

        if let focusedWC = NSApp.keyWindow?.windowController as? BrowserWindowController,
           focusedWC.activeSpace?.profileID == profile.id {
            for context in contexts {
                context.didFocusWindow(focusedWC)
            }
            // What the window reports as active, so a context loading over a
            // presented peek is told about the peek, not the host (TASK-51).
            if let activeTab = focusedWC.extensionActiveTab {
                ExtensionTabLifecycle.didActivate(activeTab, in: profile, contexts: contexts)
            }
        }
    }

    // MARK: - Enabled Extensions

    var enabledExtensions: [WebExtension] {
        extensions.filter { $0.isEnabled }
    }

    private var enabledIDsCache: [UUID: Set<String>] = [:]

    /// Extensions enabled in the profile, by `isEnabled(extensionID:inProfile:)`.
    func enabledExtensions(for profileID: UUID) -> [WebExtension] {
        let ids = enabledExtensionIDs(for: profileID)
        return extensions.filter { ids.contains($0.id) }
    }

    /// The profile's enabled extension ids, cached until either flag is written.
    ///
    /// The whole set in one query: `enabledExtensionIDs(for:)` and
    /// `isEnabled(extensionID:inProfile:)` must keep encoding the same rule. The
    /// cached set is still what `isEnabled(extensionID:inProfile:)` would answer
    /// now, because every writer of either flag invalidates it
    /// (`setEnabled(id:enabled:)`, `setEnabled(id:profileID:enabled:)`, install,
    /// uninstall). Nonisolated like its callers' reads, which are all on the main
    /// thread today.
    private func enabledExtensionIDs(for profileID: UUID) -> Set<String> {
        if let cached = enabledIDsCache[profileID] { return cached }
        let ids = AppDatabase.shared.enabledExtensionIDs(for: profileID.uuidString)
        enabledIDsCache[profileID] = ids
        return ids
    }

    func invalidateEnabledExtensionsCache() {
        enabledIDsCache.removeAll()
    }

    // MARK: - Pinned Extensions

    func toggleExtensionPinned(_ extensionID: String, profileID: UUID) {
        AppDatabase.shared.toggleExtensionPinned(extensionID: extensionID, profileID: profileID.uuidString)
        NotificationCenter.default.post(name: Self.extensionPinStateDidChangeNotification, object: nil)
    }

    func pinnedExtensions(for profileID: UUID) -> [WebExtension] {
        let pinnedIDs = AppDatabase.shared.pinnedExtensionIDs(for: profileID.uuidString)
        let enabledIDs = Set(enabledExtensions(for: profileID).map(\.id))
        return pinnedIDs.compactMap { id in extensions.first { $0.id == id } }
            .filter { enabledIDs.contains($0.id) }
    }

    /// Build an icon image for an extension, compositing badge text from WKWebExtension.Action.
    static func iconImage(for extID: String, ext: WebExtension) -> NSImage {
        let context = shared.context(for: extID)
        let action = context?.action(for: nil)
        let badgeText = action?.badgeText ?? ""

        let baseIcon: NSImage
        if let actionIcon = action?.icon(for: NSSize(width: 20, height: 20)) {
            baseIcon = actionIcon
        } else if let icon = ext.icon {
            baseIcon = icon
        } else {
            return NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: ext.manifest.name)
                ?? NSImage(named: NSImage.actionTemplateName)!
        }

        let size = NSSize(width: 20, height: 20)

        if badgeText.isEmpty {
            return NSImage(size: size, flipped: false) { rect in
                baseIcon.draw(in: rect)
                return true
            }
        }

        return NSImage(size: size, flipped: false) { rect in
            baseIcon.draw(in: rect)

            let badgeFont = NSFont.systemFont(ofSize: 7, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: badgeFont,
                .foregroundColor: NSColor.white
            ]
            let textSize = (badgeText as NSString).size(withAttributes: attrs)
            let badgeWidth = max(textSize.width + 4, 10)
            let badgeHeight: CGFloat = 9
            let badgeRect = NSRect(
                x: rect.maxX - badgeWidth,
                y: rect.minY,
                width: badgeWidth,
                height: badgeHeight
            )

            let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: 3, yRadius: 3)
            NSColor.systemRed.setFill()
            badgePath.fill()

            let textRect = NSRect(
                x: badgeRect.midX - textSize.width / 2,
                y: badgeRect.midY - textSize.height / 2,
                width: textSize.width,
                height: textSize.height
            )
            (badgeText as NSString).draw(in: textRect, withAttributes: attrs)

            return true
        }
    }

    func `extension`(withID id: String) -> WebExtension? {
        extensions.first { $0.id == id }
    }

    /// Find a context for an extension ID from the currently active profile.
    func context(for extensionID: String) -> WKWebExtensionContext? {
        if let spaceID = lastActiveSpaceID,
           let space = TabStore.shared.space(withID: spaceID),
           let profile = space.profile {
            return profile.extensionContext(for: extensionID)
        }
        // Fallback: search all profiles
        for profile in TabStore.shared.profiles {
            if let ctx = profile.extensionContext(for: extensionID) {
                return ctx
            }
        }
        return nil
    }

    /// Localized display name for an extension.
    func displayName(for extensionID: String) -> String {
        if let ext = self.extension(withID: extensionID) {
            if let nativeName = ext.wkExtension?.displayName, !nativeName.isEmpty {
                return nativeName
            }
            return ext.resolveI18n(ext.manifest.name)
        }
        return extensionID
    }

    /// Localized display description for an extension.
    func displayDescription(for extensionID: String) -> String? {
        if let ext = self.extension(withID: extensionID) {
            if let nativeDesc = ext.wkExtension?.displayDescription, !nativeDesc.isEmpty {
                return nativeDesc
            }
            if let desc = ext.manifest.description {
                return ext.resolveI18n(desc)
            }
        }
        return nil
    }

    // MARK: - Install

    @discardableResult
    func install(from sourceURL: URL, publicKey: Data? = nil) throws -> WebExtension {
        let ext = try ExtensionInstaller.install(from: sourceURL, publicKey: publicKey)

        // Clean up existing extension with same ID. An update replaces the
        // context, so the origins its pages are open on are noted here and those
        // pages are moved onto the replacement's origin below, once it is loaded.
        var oldBasesByProfile: [UUID: URL] = [:]
        if let existingIdx = extensions.firstIndex(where: { $0.id == ext.id }) {
            for profile in TabStore.shared.profiles {
                if let oldBase = profile.unloadExtension(id: ext.id) {
                    oldBasesByProfile[profile.id] = oldBase
                    // The origin is pending for as long as the replacement takes
                    // to load: the dormant tiles (pinned entries, favourites)
                    // left on it keep their identity meanwhile, so a save in that
                    // window still writes their extension id rather than dropping
                    // them at the next restore. `retargetExtensionPages` below —
                    // or `resolvePendingExtensionPages`, whichever runs first —
                    // moves them once the replacement is loaded.
                    if let host = oldBase.host, !host.isEmpty {
                        profile.registerPendingExtensionOrigin(host: host, extensionID: ext.id)
                    }
                }
            }
            extensions.remove(at: existingIdx)
            // An explicit reinstall, even of the same version, owes each profile
            // that already had the event one `update` (TASK-29). Marked before the
            // replacement loads, so the wake below and the new worker's claim see
            // it. The recovery reload and enable paths never come through here.
            AppDatabase.shared.markRuntimeInstalledEventReinstalled(extensionID: ext.id)
        }

        extensions.append(ext)

        // Record every declared permission in the DB so it is restored on
        // subsequent launches without re-prompting. Declared permissions are
        // granted only where no decision is saved yet: an existing decision — a
        // denial made in Settings (TASK-25, TASK-44) above all — survives a
        // reinstall and an update (TASK-63), while a permission an update newly
        // declares has no row and so is still recorded as granted.
        var permRecords: [ExtensionPermissionRecord] = []
        for perm in ext.manifest.permissions ?? [] {
            permRecords.append(ExtensionPermissionRecord(
                extensionID: ext.id, key: perm, type: .apiPermission, status: .granted
            ))
        }
        for pattern in ext.manifest.hostPermissions ?? [] {
            permRecords.append(ExtensionPermissionRecord(
                extensionID: ext.id, key: pattern, type: .matchPattern, status: .granted
            ))
        }
        if !permRecords.isEmpty {
            AppDatabase.shared.recordDeclaredPermissions(permRecords)
        }

        // Inject polyfills before WKWebExtension reads the files
        injectServiceWorkerPolyfill(into: ext)
        writeContentPolyfill(into: ext)

        // Load via WKWebExtension asynchronously, then into all profiles
        Task { @MainActor in
            do {
                ext.wkExtension = try await WKWebExtension(resourceBaseURL: ext.basePath)

                for profile in TabStore.shared.profiles {
                    self.reconcileExtensionContext(ext, in: profile)
                    self.wakeForPendingInstalledEvent(extensionID: ext.id, in: profile)
                }

                // Pages the replaced version had open are on a dead origin; move
                // them to the new context's before its tabs are announced, so each
                // rehosted tab is announced once (on wake) rather than twice. A
                // profile that got no replacement context (the extension is
                // disabled there) has no origin to move them to: close them, as
                // a disable would.
                for profile in TabStore.shared.profiles {
                    guard let oldBase = oldBasesByProfile[profile.id] else { continue }
                    if let context = profile.extensionContext(for: ext.id) {
                        profile.retargetExtensionPages(from: oldBase, to: context.baseURL)
                    } else {
                        closePagesOfUnloadedExtension(ext.id, in: profile, unloadedBase: oldBase,
                                                      uninstalling: false)
                    }
                }

                // Notify existing tabs in relevant profiles
                for profile in TabStore.shared.profiles {
                    if profile.extensionContext(for: ext.id) != nil {
                        profile.resolvePendingExtensionPages()
                        notifyExistingTabs(for: profile)
                    }
                }
            } catch {
                log.error("Failed to load WKWebExtension after install: \(error.localizedDescription, privacy: .public)")
                // The old contexts are already unloaded; nothing will replace
                // them, so the pages they served can only be dead. The extension
                // is still installed, though, so the origin stays pending and the
                // tiles stay dormant on it — they keep their identity for the next
                // successful load, exactly as a disable leaves them.
                for profile in TabStore.shared.profiles {
                    closePagesOfUnloadedExtension(ext.id, in: profile,
                                                  unloadedBase: oldBasesByProfile[profile.id],
                                                  uninstalling: false)
                }
            }
        }

        invalidateEnabledExtensionsCache()
        NotificationCenter.default.post(name: Self.extensionsDidChangeNotification, object: nil)
        return ext
    }

    // MARK: - Uninstall

    func uninstall(id: String) {
        log.info("Uninstalling extension \(id, privacy: .public)")

        // Unload from all profiles and remove WebKit extension data, then close
        // the pages each unloaded context was serving — the extension is gone, so
        // they can only be dead.
        for profile in TabStore.shared.profiles {
            let oldBase = profile.unloadExtension(id: id, removeData: true)
            closePagesOfUnloadedExtension(id, in: profile, unloadedBase: oldBase, uninstalling: true)
        }

        extensions.removeAll { $0.id == id }
        AppDatabase.shared.deleteExtension(id: id)

        let extDir = detourDataDirectory().appendingPathComponent("Extensions/\(id)")
        try? FileManager.default.removeItem(at: extDir)

        invalidateEnabledExtensionsCache()
        NotificationCenter.default.post(name: Self.extensionsDidChangeNotification, object: nil)
    }

    // MARK: - Enable / Disable

    /// Whether the extension is enabled in the profile — the one rule every path
    /// that loads a context (launch, install, both toggles) and every per-profile
    /// list (menus, pinned toolbar icons) goes through: the global flag is on AND
    /// the profile has not turned it off (no per-profile row means on).
    ///
    /// The two flags are stored independently and each toggle writes only its
    /// own: a global disable leaves the per-profile rows alone, so re-enabling
    /// restores every profile's earlier choice, and a per-profile enable while
    /// the extension is globally off records the choice without loading it.
    func isEnabled(extensionID: String, inProfile profileID: UUID) -> Bool {
        AppDatabase.shared.isExtensionEnabled(extensionID: extensionID, profileID: profileID.uuidString)
    }

    /// What `reconcileExtensionContext` did to the profile's context.
    private enum ContextReconciliation {
        case unchanged
        case loaded(WKWebExtensionContext)
        /// The unloaded context's base URL — the origin its open pages are stranded on.
        case unloaded(oldBase: URL)
    }

    /// Load or unload `ext`'s context in `profile` so it matches
    /// `isEnabled(extensionID:inProfile:)`. Idempotent, and it reads the saved
    /// flags at call time rather than applying a delta, so no sequence of toggles
    /// can leave a profile out of step with what Settings shows.
    @MainActor
    @discardableResult
    private func reconcileExtensionContext(_ ext: WebExtension, in profile: Profile) -> ContextReconciliation {
        reconcileExtensionContext(ext, in: profile,
                                  shouldLoad: isEnabled(extensionID: ext.id, inProfile: profile.id))
    }

    /// `reconcileExtensionContext(_:in:)` with the rule already evaluated, for a
    /// caller that resolved a whole profile's enabled set in one query
    /// (`loadExtensionsIntoProfile`, TASK-46). `shouldLoad` must be what
    /// `isEnabled(extensionID:inProfile:)` would answer *now*: pass only a
    /// decision read after the last write to either flag, never one carried
    /// across a toggle. A set taken from `enabledIDsCache` qualifies — every
    /// writer of either flag invalidates that cache
    /// (`setEnabled(id:enabled:)`, `setEnabled(id:profileID:enabled:)`, install,
    /// uninstall) — but a set held across a toggle in a local does not.
    @MainActor
    @discardableResult
    private func reconcileExtensionContext(_ ext: WebExtension, in profile: Profile,
                                           shouldLoad: Bool) -> ContextReconciliation {
        switch (shouldLoad, profile.extensionContext(for: ext.id)) {
        case (true, nil):
            _ = profile.loadExtensionContext(ext)
            return profile.extensionContext(for: ext.id).map { .loaded($0) } ?? .unchanged
        case (false, .some):
            return profile.unloadExtension(id: ext.id).map { .unloaded(oldBase: $0) } ?? .unchanged
        default:
            return .unchanged
        }
    }

    /// Bring every profile in `profiles` in line after a toggle. A newly loaded
    /// context is told about the profile's windows and tabs (only that context:
    /// the others already know them, and re-announcing surfaces duplicate
    /// lifecycle events). An unloaded context's pages are closed in *that*
    /// profile only — the same extension's pages in a profile where it stays
    /// enabled are served by a different, still-live context.
    @MainActor
    private func applyEnabledState(of ext: WebExtension, to profiles: [Profile]) {
        for profile in profiles {
            switch reconcileExtensionContext(ext, in: profile) {
            case .loaded(let context):
                // Pages left on this extension's pending origins (restored while
                // it was disabled, or left dormant by an earlier disable) move onto
                // the new context before it is told about the tabs (TASK-24).
                profile.resolvePendingExtensionPages()
                wakeForPendingInstalledEvent(extensionID: ext.id, in: profile)
                notifyExistingTabs(for: profile, contexts: [context])
            case .unloaded(let oldBase):
                closePagesOfUnloadedExtension(ext.id, in: profile, unloadedBase: oldBase, uninstalling: false)
            case .unchanged:
                // No context to unload — e.g. one that failed to load, leaving the
                // pages restored for it waiting on pending origins (TASK-24) — but
                // a disabled extension's pages must still not stay open.
                if !isEnabled(extensionID: ext.id, inProfile: profile.id) {
                    closePagesOfUnloadedExtension(ext.id, in: profile, unloadedBase: nil, uninstalling: false)
                }
            }
        }
    }

    /// Turn the extension on or off for every profile. Only the global flag is
    /// written; per-profile choices survive, so enabling loads it just where
    /// the profile has not turned it off.
    @MainActor
    func setEnabled(id: String, enabled: Bool) {
        guard let ext = self.extension(withID: id) else { return }
        log.info("Extension \(id, privacy: .public) \(enabled ? "enabled" : "disabled")")
        ext.isEnabled = enabled
        AppDatabase.shared.setEnabled(id: id, enabled: enabled)

        applyEnabledState(of: ext, to: TabStore.shared.profiles)

        invalidateEnabledExtensionsCache()
        NotificationCenter.default.post(name: Self.extensionsDidChangeNotification, object: nil)
    }

    /// Turn the extension on or off for one profile. The choice is saved even
    /// while the extension is globally off, but it only takes effect (loads)
    /// once the global flag is on again.
    @MainActor
    func setEnabled(id: String, profileID: UUID, enabled: Bool) {
        log.info("Extension \(id, privacy: .public) \(enabled ? "enabled" : "disabled") for profile \(profileID.uuidString, privacy: .public)")
        AppDatabase.shared.setProfileExtensionEnabled(extensionID: id, profileID: profileID.uuidString, enabled: enabled)

        if let profile = TabStore.shared.profile(withID: profileID),
           let ext = self.extension(withID: id) {
            applyEnabledState(of: ext, to: [profile])
        }

        invalidateEnabledExtensionsCache()
        NotificationCenter.default.post(name: Self.extensionsDidChangeNotification, object: nil)
    }


    // MARK: - Service Worker Polyfill Injection

    /// When true, module service workers are bundled into a single classic script
    /// via ModuleBundler. When false, the polyfill is injected as an ES module import.
    /// Bundling provides better scope isolation for polyfill patches but is more
    /// invasive. The module-import approach is simpler and less likely to break.
    private static let useModuleBundler = false

    /// A service worker gets no user scripts, so the polyfill is written next to
    /// it and imported from its top. A *background page* (MV2, or MV3
    /// `background.scripts` / `background.page`) needs nothing here: it is a
    /// web view built from the extension controller's configuration, so the
    /// polyfill user script `Profile.extensionController` installs runs in it at
    /// document start like in any other extension page (verified for TASK-43).
    private func injectServiceWorkerPolyfill(into ext: WebExtension) {
        guard let swFile = ext.manifest.background?.serviceWorker else { return }
        let polyfillFilename = "_detour_polyfill.js"
        let swURL = ext.basePath.appendingPathComponent(swFile)

        if ext.manifest.background?.isModule == true {
            if Self.useModuleBundler {
                do {
                    try ModuleBundler.bundle(extension: ext)
                    return
                } catch {
                    log.error("Bundler failed for \(ext.id, privacy: .public): \(error.localizedDescription, privacy: .public), falling back to module import")
                }
            }
            injectModuleSWPolyfill(ext: ext, swURL: swURL)
            return
        }

        // Classic service workers: write polyfill file + importScripts
        injectClassicSWPolyfill(ext: ext, swURL: swURL, polyfillFilename: polyfillFilename)
    }

    private func injectClassicSWPolyfill(ext: WebExtension, swURL: URL, polyfillFilename: String) {
        // Write the polyfill file next to the service worker, since importScripts
        // resolves paths relative to the SW file's directory, not the extension root.
        let swDir = swURL.deletingLastPathComponent()
        let polyfillURL = swDir.appendingPathComponent(polyfillFilename)
        do {
            try writeIfChanged(ExtensionAPIPolyfill.polyfillJS, to: polyfillURL)
        } catch {
            log.error("Failed to write polyfill for \(ext.id, privacy: .public): \(error.localizedDescription)")
            return
        }

        let importLine = "importScripts('\(polyfillFilename)');"
        do {
            let swSource = try String(contentsOf: swURL, encoding: .utf8)
            if !swSource.contains(importLine) {
                let patched = importLine + "\n" + swSource
                try patched.write(to: swURL, atomically: true, encoding: .utf8)
                log.info("Injected polyfill into classic SW for \(ext.id, privacy: .public)")
            }
        } catch {
            log.error("Failed to patch classic SW for \(ext.id, privacy: .public): \(error.localizedDescription)")
        }
    }

    private func injectModuleSWPolyfill(ext: WebExtension, swURL: URL) {
        let polyfillFilename = "_detour_polyfill_module.js"
        // Write the polyfill file next to the service worker, matching the classic strategy.
        let swDir = swURL.deletingLastPathComponent()
        let polyfillURL = swDir.appendingPathComponent(polyfillFilename)
        do {
            try writeIfChanged(ExtensionAPIPolyfill.polyfillJS, to: polyfillURL)
        } catch {
            log.error("Failed to write module SW polyfill for \(ext.id, privacy: .public): \(error.localizedDescription)")
            return
        }

        let importLine = "import './\(polyfillFilename)';"
        do {
            let swSource = try String(contentsOf: swURL, encoding: .utf8)
            if !swSource.contains(importLine) {
                let patched = importLine + "\n" + swSource
                try patched.write(to: swURL, atomically: true, encoding: .utf8)
                log.info("Injected polyfill module into module SW for \(ext.id, privacy: .public)")
            }
        } catch {
            log.error("Failed to patch module SW for \(ext.id, privacy: .public): \(error.localizedDescription)")
        }
    }

    /// Writes the content polyfill file and inserts it as the first script in each
    /// content_scripts entry in the manifest, so it runs before the extension's own scripts.
    private func writeContentPolyfill(into ext: WebExtension) {
        let filename = "_detour_content_polyfill.js"
        let fileURL = ext.basePath.appendingPathComponent(filename)

        // Write the polyfill file (update if changed)
        do {
            try writeIfChanged(ExtensionAPIPolyfill.contentPolyfillJS, to: fileURL)
        } catch {
            log.error("Failed to write content polyfill for \(ext.id, privacy: .public): \(error.localizedDescription)")
            return
        }

        // Insert polyfill as first script in each content_scripts entry in manifest.json
        let manifestURL = ext.basePath.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL),
              var manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              var contentScripts = manifest["content_scripts"] as? [[String: Any]] else { return }

        var modified = false
        for i in contentScripts.indices {
            guard var jsFiles = contentScripts[i]["js"] as? [String] else { continue }
            if !jsFiles.contains(filename) {
                jsFiles.insert(filename, at: 0)
                contentScripts[i]["js"] = jsFiles
                modified = true
            }
        }

        if modified {
            manifest["content_scripts"] = contentScripts
            if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: manifestURL, options: .atomic)
                log.info("Injected content polyfill into manifest for \(ext.id, privacy: .public)")
            }
        }
    }

    // MARK: - Helpers

    /// Write content to a file only if it differs from the existing content.
    private func writeIfChanged(_ content: String, to url: URL) throws {
        let existing = try? String(contentsOf: url, encoding: .utf8)
        guard existing != content else { return }
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The profile that owns a controller — the registry `Profile` fills when it
    /// builds one, not a scan of the store: a scan force-builds every profile's
    /// lazy `extensionController` (and so its persistent storage, data store and
    /// polyfill handler) just to compare, and misses a controller whose profile
    /// has left `TabStore.shared`.
    private func profile(for controller: WKWebExtensionController) -> Profile? {
        Profile.profile(owning: controller)
    }

    /// Find a space belonging to the profile that owns a controller.
    /// Returns nil if the profile has no open spaces — callers should not create
    /// tabs in a different profile's space.
    private func space(for controller: WKWebExtensionController) -> Space? {
        let targetProfile = profile(for: controller)
        return TabStore.shared.spaces.first { $0.profileID == targetProfile?.id }
    }

    /// Select a tab and notify window controllers.
    private func selectTab(_ tab: BrowserTab, in space: Space) {
        space.selectedTabID = tab.id
        NotificationCenter.default.post(
            name: Self.tabShouldSelectNotification,
            object: nil,
            userInfo: ["tabID": tab.id, "spaceID": space.id]
        )
    }

    // MARK: - Permission decisions (Settings)

    /// Save the user's decision for one permission row and apply it right away
    /// to every loaded context of the extension, in every profile — the Settings
    /// toggles' single entry point (TASK-25), so no change waits for a relaunch.
    ///
    /// - `nativeMessaging` is never applied to a context (the context keeps it so
    ///   Detour's built-in hosts work, see `Profile.loadExtensionContext`). The
    ///   saved row is what `nativeHostAccess` enforces on the next connect, and a
    ///   denial also tears down the real hosts the extension already has running.
    /// - Host rows (`.matchPattern` and `.url`) re-run the whole saved host-access
    ///   restore on each context rather than setting only the toggled key.
    ///   Overlapping patterns interact in WebKit — a later write erases what the
    ///   opposite set held under it — so setting one key alone could, say, let a
    ///   broad grant wipe a narrower saved denial for the rest of the session,
    ///   while the next launch (which restores in grant-then-deny order) would
    ///   bring the denial back. Clearing the toggled key and re-running the
    ///   restore makes the live state the state the next launch produces. The
    ///   same manifest gate applies, so a row
    ///   the manifest cannot ask for is saved but stays inert, as on load.
    /// - Other API permissions are set on the context directly.
    @MainActor
    func setPermissionDecision(extensionID: String, key: String,
                               type: ExtensionPermissionType, granted: Bool) {
        let status: ExtensionPermissionStatus = granted ? .granted : .denied
        AppDatabase.shared.savePermission(ExtensionPermissionRecord(
            extensionID: extensionID, key: key, type: type, status: status))

        if type == .apiPermission, key == ExtensionPermissionRecord.nativeMessagingKey {
            if !granted {
                disconnectRealNativeHosts(for: extensionID)
            }
            return
        }

        let contexts = TabStore.shared.profiles.compactMap { $0.extensionContext(for: extensionID) }
        guard !contexts.isEmpty else { return }

        switch type {
        case .apiPermission:
            let permission = WKWebExtension.Permission(rawValue: key)
            for context in contexts {
                context.setPermissionStatus(status.contextStatus, for: permission)
            }
        case .matchPattern, .url:
            guard let ext = self.extension(withID: extensionID) else { return }
            let saved = AppDatabase.shared.loadPermissions(extensionID: extensionID)
            for context in contexts {
                // Forget the context's previous status for the toggled key first:
                // the restore only ever *adds* entries, and not every WebKit write
                // replaces its opposite. For the all-hosts pattern neither a grant
                // nor `.unknown` removes an earlier `<all_urls>` denial, which
                // then keeps winning (pinned by
                // ExtensionPermissionRestoreTests.testWebKitAllHostsGrantDoesNotEraseAllHostsDenial),
                // so a pattern key is dropped from both dictionaries directly.
                // A `.url` key widens to a non-all-hosts origin pattern, which
                // `.unknown` does clear.
                switch type {
                case .matchPattern:
                    context.grantedPermissionMatchPatterns = context.grantedPermissionMatchPatterns
                        .filter { $0.key.string != key }
                    context.deniedPermissionMatchPatterns = context.deniedPermissionMatchPatterns
                        .filter { $0.key.string != key }
                case .url:
                    if let url = URL(string: key) {
                        context.setPermissionStatus(.unknown, for: url)
                    }
                case .apiPermission:
                    break
                }
                Profile.applySavedHostAccessDecisions(saved, for: ext, to: context)
            }
        }
    }

    /// Find the extension ID for a context by searching the owning profile.
    private func extensionIDFromContext(_ context: WKWebExtensionContext) -> String? {
        guard let controller = context.webExtensionController,
              let profile = profile(for: controller) else { return nil }
        return profile.extensionContexts.first { $0.value === context }?.key
    }

    // MARK: - WKWebExtensionControllerDelegate

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        // Return windows whose profile matches this controller
        let profile = profile(for: controller)
        return NSApp.windows.compactMap { $0.windowController as? BrowserWindowController }
            .filter { $0.activeSpace?.profileID == profile?.id }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        guard let wc = NSApp.keyWindow?.windowController as? BrowserWindowController,
              let profile = profile(for: controller),
              wc.activeSpace?.profileID == profile.id else { return nil }
        return wc
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openOptionsPageFor extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let optionsURL = extensionContext.optionsPageURL,
              let extConfig = extensionContext.webViewConfiguration,
              let space = space(for: controller) else {
            completionHandler(nil)
            return
        }

        let tab = TabStore.shared.addExtensionTab(in: space, url: optionsURL, configuration: extConfig)
        selectTab(tab, in: space)
        completionHandler(nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        guard let space = space(for: controller) else {
            completionHandler(nil, nil)
            return
        }

        let url = configuration.url ?? URL(string: "about:blank")!
        let tab: BrowserTab
        if url.scheme == "webkit-extension", let extConfig = extensionContext.webViewConfiguration {
            tab = TabStore.shared.addExtensionTab(in: space, url: url, configuration: extConfig)
        } else {
            tab = TabStore.shared.addTab(in: space, url: url)
        }

        if configuration.shouldBeActive {
            selectTab(tab, in: space)
        }
        completionHandler(tab, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void
    ) {
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            completionHandler(nil, nil)
            return
        }

        let wc = BrowserWindowController(incognito: configuration.shouldBePrivate)
        appDelegate.assignDefaultSpace(to: wc)

        // TODO: Handle configuration.tabs (moving existing tabs to new window)

        // Open new tabs for specified URLs
        var lastTab: BrowserTab?
        if let space = wc.activeSpace {
            for url in configuration.tabURLs {
                if url.scheme == "webkit-extension", let extConfig = extensionContext.webViewConfiguration {
                    lastTab = TabStore.shared.addExtensionTab(in: space, url: url, configuration: extConfig)
                } else {
                    lastTab = TabStore.shared.addTab(in: space, url: url)
                }
            }
        }

        wc.showWindow(nil)
        if let lastTab {
            wc.selectTab(id: lastTab.id)
        } else if configuration.tabURLs.isEmpty && configuration.tabs.isEmpty {
            wc.newTab(nil)
        }

        appDelegate.registerWindowController(wc)

        if configuration.shouldBeFocused {
            wc.window?.makeKeyAndOrderFront(nil)
        }

        // Apply window frame if specified (NaN means not specified)
        let frame = configuration.frame
        if let window = wc.window {
            var currentFrame = window.frame
            if !frame.origin.x.isNaN { currentFrame.origin.x = frame.origin.x }
            if !frame.origin.y.isNaN { currentFrame.origin.y = frame.origin.y }
            if !frame.size.width.isNaN { currentFrame.size.width = frame.size.width }
            if !frame.size.height.isNaN { currentFrame.size.height = frame.size.height }
            if currentFrame != window.frame {
                window.setFrame(currentFrame, display: true)
            }
        }

        completionHandler(wc, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        // This delegate is for extension-initiated opens (browser.action.openPopup()).
        // User toolbar clicks use userGesturePerformed + manual popup presentation.
        // Explicit present path: the extension called browser.action.openPopup(),
        // so creating and loading the popup web view here is intended (TASK-55).
        guard let popupWebView = action.popupWebView,
              let extID = extensionIDFromContext(extensionContext) else {
            completionHandler(nil)
            return
        }

        let popoverController = ExtensionPopoverController(extensionID: extID)

        // Anchor to pinned extension button in faux address bar, or settings button, or top-right of window
        if let wc = NSApp.keyWindow?.windowController as? BrowserWindowController {
            let fauxBar = wc.tabSidebar.fauxAddressBar
            if let pinnedButton = fauxBar.pinnedExtensionStack.arrangedSubviews
                .first(where: { $0.identifier?.rawValue == extID }) {
                popoverController.setPositioning(relativeTo: pinnedButton.bounds, of: pinnedButton, preferredEdge: .maxY)
            } else {
                popoverController.setPositioning(relativeTo: fauxBar.settingsButton.bounds, of: fauxBar.settingsButton, preferredEdge: .maxY)
            }
        } else if let contentView = NSApp.keyWindow?.contentView {
            let rect = NSRect(x: contentView.bounds.maxX - 50, y: contentView.bounds.maxY - 10, width: 1, height: 1)
            popoverController.setPositioning(relativeTo: rect, of: contentView, preferredEdge: .minY)
        }

        popoverController.onClose = { [weak self] in
            self?.activePopovers.removeValue(forKey: extID)
            self?.popupCompletionHandlers.removeValue(forKey: extID)?(nil)
        }
        popoverController.presentPopupWebView(popupWebView)

        activePopovers[extID] = popoverController
        popupCompletionHandlers[extID] = completionHandler
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        // API permissions are never auto-granted by activeTab (activeTab grants
        // site access, not API permissions).
        handlePermissionPrompt(
            items: permissions,
            context: extensionContext,
            tab: tab,
            autoGrantsForActiveTab: false,
            autoGrantLogLabel: "",
            recordType: .apiPermission,
            describe: { ExtensionPermissionDescriptions.describe($0.rawValue) },
            recordKey: { $0.rawValue },
            completionHandler: completionHandler
        )
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        handlePermissionPrompt(
            items: urls,
            context: extensionContext,
            tab: tab,
            autoGrantsForActiveTab: true,
            autoGrantLogLabel: "URLs",
            category: "site access",
            recordType: .url,
            describe: { $0.absoluteString },
            recordKey: { $0.absoluteString },
            completionHandler: completionHandler
        )
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        handlePermissionPrompt(
            items: matchPatterns,
            context: extensionContext,
            tab: tab,
            autoGrantsForActiveTab: true,
            autoGrantLogLabel: "match patterns",
            category: "site access",
            recordType: .matchPattern,
            describe: { $0.string == "<all_urls>" ? "All websites" : $0.string },
            recordKey: { $0.string },
            completionHandler: completionHandler
        )
    }

    /// Shared implementation for the three permission-prompt delegate callbacks.
    /// Handles the optional activeTab auto-grant short-circuit, building the
    /// prompt, persisting the granted/denied records, and invoking the
    /// completion handler with the granted set (or empty on denial).
    private func handlePermissionPrompt<Item: Hashable>(
        items: Set<Item>,
        context extensionContext: WKWebExtensionContext,
        tab: (any WKWebExtensionTab)?,
        autoGrantsForActiveTab: Bool,
        autoGrantLogLabel: String,
        category: String = "permissions",
        recordType: ExtensionPermissionType,
        describe: (Item) -> String,
        recordKey: (Item) -> String,
        completionHandler: (Set<Item>, Date?) -> Void
    ) {
        let extID = extensionIDFromContext(extensionContext)

        if autoGrantsForActiveTab,
           shouldAutoGrantForActiveTab(context: extensionContext, tab: tab) {
            log.info("activeTab auto-grant \(autoGrantLogLabel, privacy: .public) for \(extID ?? "?", privacy: .public)")
            completionHandler(items, nil)
            return
        }

        let name = extID.map { displayName(for: $0) } ?? "This extension"
        let descriptions = items.map(describe)

        let granted = promptUserForPermission(
            extensionName: name,
            itemDescriptions: descriptions,
            category: category
        )

        if let extID {
            let status: ExtensionPermissionStatus = granted ? .granted : .denied
            let records = items.map {
                ExtensionPermissionRecord(extensionID: extID, key: recordKey($0), type: recordType, status: status)
            }
            AppDatabase.shared.savePermissions(records)
        }
        completionHandler(granted ? items : Set(), nil)
    }

    /// Returns true if the extension has activeTab and the request should be
    /// auto-granted (either tab-scoped with a gesture, or from the service worker).
    private func shouldAutoGrantForActiveTab(
        context: WKWebExtensionContext, tab: (any WKWebExtensionTab)?
    ) -> Bool {
        guard context.hasPermission(.activeTab) else { return false }
        if let tab { return context.hasActiveUserGesture(in: tab) }
        // nil tab = service worker request on behalf of a user action
        return true
    }

    /// Shows an NSAlert prompting the user to allow or deny permissions.
    /// Returns true if the user clicked Allow.
    private func promptUserForPermission(
        extensionName: String,
        itemDescriptions: [String],
        category: String = "permissions"
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = "\"\(extensionName)\" is requesting additional \(category)"
        alert.informativeText = itemDescriptions.map { "\u{2022} \($0)" }.joined(separator: "\n")
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        didUpdate action: WKWebExtension.Action,
        forExtensionContext extensionContext: WKWebExtensionContext
    ) {
        if let extID = extensionIDFromContext(extensionContext) {
            NotificationCenter.default.post(
                name: Self.extensionActionDidChangeNotification,
                object: nil,
                userInfo: ["extensionID": extID]
            )
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        sendMessage message: Any,
        toApplicationWithIdentifier appID: String?,
        for extensionContext: WKWebExtensionContext,
        replyHandler: @escaping (Any?, (any Error)?) -> Void
    ) {
        // Route polyfill messages from service workers (where webkit.messageHandlers
        // is unavailable and the polyfill falls back to sendNativeMessage). The
        // polyfill host never reaches the real native-host path below: a payload
        // that is not the polyfill envelope is rejected here rather than falling
        // through to `nativeHostAccess`, which exempts this host name from the
        // manifest permission and would otherwise spawn a host named after it.
        if appID == ExtensionPolyfillHandler.handlerName {
            guard let body = message as? [String: Any] else {
                log.error("Rejecting polyfill native message with a non-object payload")
                replyHandler(nil, NSError(domain: "DetourPolyfill", code: -1,
                                          userInfo: [NSLocalizedDescriptionKey: "Invalid polyfill message format"]))
                return
            }
            log.debug("Routing polyfill native message: \(body["type"] as? String ?? "(no type)", privacy: .public)")
            let profile = profile(for: controller)
            guard let handler = profile?.polyfillHandler else {
                log.error("No polyfill handler for profile")
                replyHandler(nil, NSError(domain: "DetourPolyfill", code: -1,
                                          userInfo: [NSLocalizedDescriptionKey: "No polyfill handler for profile"]))
                return
            }
            // The sender's identity comes from the context, never from the body:
            // a context the profile no longer lists (unloaded, or a message in
            // flight across a reload) is rejected rather than trusted.
            guard let verifiedExtensionID = extensionIDFromContext(extensionContext) else {
                log.error("Rejecting polyfill native message \(body["type"] as? String ?? "(unknown)", privacy: .public) from a context not loaded in profile \(profile?.name ?? "?", privacy: .public)")
                replyHandler(nil, NSError(domain: "DetourPolyfill", code: -1,
                                          userInfo: [NSLocalizedDescriptionKey: "Unrecognized extension context"]))
                return
            }
            handler.handleNativeMessage(body, verifiedExtensionID: verifiedExtensionID, replyHandler: replyHandler)
            return
        }

        log.info("sendNativeMessage to appID: \(appID ?? "(nil)", privacy: .public)")

        guard let hostName = appID else {
            replyHandler(nil, nil)
            return
        }

        // nativeMessaging is auto-granted so the polyfill bridge works, but real
        // native messaging hosts should only be reachable by extensions that
        // explicitly declared the permission in their manifest and whose
        // nativeMessaging the user has not denied. Decided by host name first, so
        // Detour's own host names can never fall through to the real-host path
        // below — where a process named after one would be searched for and
        // spawned.
        let resolvedExtensionID = extensionIDFromContext(extensionContext)
        switch nativeHostAccess(hostName: hostName, extensionID: resolvedExtensionID) {
        case .polyfillHost:
            // Unreachable: the polyfill envelope path above answers this host name
            // and always returns. Kept so the exhaustive switch is the only place
            // that decides what a host name means.
            replyHandler(nil, nil)
            return
        case .webSocketRelayHost:
            // The relay is a conversation, not a one-shot exchange: it only exists
            // on a port (TASK-8).
            log.warning("Rejecting a one-shot native message to the WebSocket relay host")
            replyHandler(nil, NSError(domain: "DetourExtension", code: -1,
                                      userInfo: [NSLocalizedDescriptionKey: "\(WebSocketRelaySession.hostName) is a port-only host"]))
            return
        case .denied:
            // A context the profile no longer lists (unloaded, or a message in
            // flight across a reload) has no manifest to consult; say so rather
            // than blaming a permission it may well have declared.
            guard let deniedID = resolvedExtensionID else {
                log.error("Rejecting native message to '\(hostName, privacy: .public)' from a context not loaded in any profile")
                replyHandler(nil, NSError(domain: "DetourExtension", code: -1,
                                          userInfo: [NSLocalizedDescriptionKey: "Unrecognized extension context"]))
                return
            }
            log.warning("Extension \(deniedID, privacy: .public) tried native messaging to '\(hostName, privacy: .public)' without declaring nativeMessaging permission")
            replyHandler(nil, NSError(domain: "DetourExtension", code: -1,
                                      userInfo: [NSLocalizedDescriptionKey: "nativeMessaging permission not declared"]))
            return
        case .deniedByUser:
            // Refused before any host object exists: nothing is looked up or spawned.
            log.warning("Refusing native message to '\(hostName, privacy: .public)' from \(resolvedExtensionID ?? "?", privacy: .public): nativeMessaging denied by the user")
            replyHandler(nil, Self.nativeHostForbiddenError())
            return
        case .allowed:
            break
        }

        // Spawning a real host needs the profile-verified id.
        guard let extID = resolvedExtensionID else {
            replyHandler(nil, nil)
            return
        }

        let host = NativeMessagingHost(hostName: hostName, extensionID: extID)
        let hostKey = ObjectIdentifier(host)
        let request = OneShotNativeRequest(host: host, replyHandler: replyHandler)
        activeMessagingHosts[hostKey] = request

        // The request is captured weakly: the registry owns it (and through it the
        // host), so the host's own callbacks cannot keep it alive in a cycle. The
        // reply is delivered at most once, whichever of these ends it first.
        // (Each callback takes a strong local before dropping the registry entry,
        // which would otherwise release the request it is about to answer.)
        host.onMessage = { [weak self, weak request] response in
            guard let request else { return }
            self?.activeMessagingHosts.removeValue(forKey: hostKey)
            request.finish(response, nil)
        }
        host.onDisconnect = { [weak self, weak request] _ in
            guard let request else { return }
            self?.activeMessagingHosts.removeValue(forKey: hostKey)
            // A host that exits without answering must still settle the
            // extension's promise, with Chrome's wording for it.
            request.finish(nil, NSError(domain: "DetourExtension", code: -1,
                                        userInfo: [NSLocalizedDescriptionKey: "Native host has exited."]))
        }
        do {
            try host.connect()
            if let msgDict = message as? [String: Any] {
                try host.sendMessage(msgDict)
            }
        } catch {
            activeMessagingHosts.removeValue(forKey: hostKey)
            request.finish(nil, error)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        connectUsing port: WKWebExtension.MessagePort,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let hostName = port.applicationIdentifier else {
            completionHandler(nil)
            return
        }

        // Decided by host name first: Detour's own hosts need no manifest
        // permission and ignore the user's nativeMessaging decision, and the relay
        // needs no extension record at all.
        let resolvedExtensionID = extensionIDFromContext(extensionContext)

        // Every path but the relay's needs the profile-verified id.
        func verifiedExtensionID() -> String? {
            if let resolvedExtensionID { return resolvedExtensionID }
            completionHandler(nil)
            return nil
        }

        switch nativeHostAccess(hostName: hostName, extensionID: resolvedExtensionID) {
        case .webSocketRelayHost:
            // The relay only labels its session with the extension id, so it needs
            // no extension record — but when a Profile owns this controller the id
            // must still come from it: a context the profile no longer lists is
            // stale (unloaded, or a connect in flight across a reload). Only a
            // controller no Profile owns — one built by hand in the tests — falls
            // back to the context's own identifier.
            let relayID: String
            if profile(for: controller) != nil {
                guard let verified = resolvedExtensionID else {
                    log.error("Rejecting a WebSocket relay port from a context not loaded in its profile")
                    completionHandler(NSError(domain: "DetourExtension", code: -1,
                                              userInfo: [NSLocalizedDescriptionKey: "Unrecognized extension context"]))
                    return
                }
                relayID = verified
            } else {
                relayID = extensionContext.uniqueIdentifier
            }
            openWebSocketRelay(port: port, controller: controller, extensionID: relayID)
            completionHandler(nil)
            return
        case .polyfillHost:
            guard let extID = verifiedExtensionID() else { return }
            // The polyfill's keep-alive port (see ExtensionAPIPolyfill.nativePortKeepAliveJS):
            // accept it without spawning anything and hold it until the background
            // context (a worker or a non-persistent background page, TASK-62) closes
            // it or unloads. The background opens it idle at startup and never decides
            // anything itself — Detour arms it (`keepalive-start`) while a real native
            // messaging host is connected for this extension and disarms it when the
            // last one exits (TASK-16), and WebKit counts the background's pings on it
            // as the activity that defers the unload. One port per extension per
            // controller: the background only ever holds one, so a second replaces
            // (and closes) the first rather than accumulating.
            //
            // The newest port wins, and the context that held the old one stops: it
            // is told `keepAliveSupersededType` just before the disconnect (WebKit
            // does not hand the disconnect error to an established port, so the
            // error alone never reaches it) and does not reconnect until its next
            // start. Reconnecting would evict the newer port, whose context would
            // reconnect and evict it back, about once a second forever.
            //
            // Residual limit: nothing here can tell which web view opened the port.
            // A top-level extension page navigated to the background document's path
            // also passes the polyfill's gate, and its port takes the keep-alive from
            // the real background, which then stays stopped until it restarts.
            // TASK-66 closed the same hole for runtime.onInstalled with
            // `ExtensionPageHostRegistry`, but that needs the sending web view, which
            // a native-message port never carries.
            let key = KeepAlivePortKey(controller: ObjectIdentifier(controller), extensionID: extID)
            if let previous = keepAlivePorts.removeValue(forKey: key) {
                // Sent before the disconnect on the same port, so the polyfill has
                // it by the time its onDisconnect runs.
                previous.sendMessage(["type": Self.keepAliveSupersededType], completionHandler: { _ in })
                previous.disconnect(throwing: NSError(
                    domain: "DetourExtension", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: Self.keepAliveSupersededMessage]))
                log.info("Keep-alive port for \(extID, privacy: .public) superseded by a newer one")

                // A second keep-alive port while the first is still open means the
                // background context was replaced, and everything Detour holds for
                // this extension belongs to the context that went away: the
                // polyfill opens this port before any extension code runs, so the
                // replacement cannot have connected anything yet.
                //
                // Nothing else tells Detour that context ended.
                // `WebExtensionContext::unload()` — what `chrome.runtime.reload()`
                // runs (reload = unload + load), and what a WebKit-internal
                // background restart runs — clears its native port map *without*
                // calling `reportDisconnection`, so no host port ever disconnects:
                // the host processes stay alive as Detour's children and keep
                // counting towards the keep-alive, which then stays armed for a
                // worker with no live host of its own (production 2026-09-13,
                // TASK-67: 1Password's workers replaced at 18:38:49, armed counts
                // climbing to 2 and 3, ten BrowserSupport processes for three
                // workers). So tear them down here, which also resets the count to
                // zero: the new port's `portOpened` below arms nothing until the
                // new context connects a host of its own.
                //
                // Known over-reach: the registries are keyed per extension, not
                // per context, so a `connectNative` port a still-open popup or
                // options page of this extension holds is torn down with the
                // background's (nothing on a native port says which context
                // opened it). A `runtime.reload()` closes those pages too, so it
                // only costs anything on a WebKit-internal background restart,
                // where the page sees an ordinary `onDisconnect` and can reconnect.
                let torn = tearDownNativeConnections(
                    for: key, disconnectingPortsWith: Self.replacedBackgroundContextError())
                if torn.hosts > 0 || torn.relays > 0 {
                    log.info("Replaced background context of \(extID, privacy: .public): tore down \(torn.hosts) stale native host(s) and \(torn.relays) relayed WebSocket(s)")
                }
            }
            keepAlivePorts[key] = port
            keepAlivePortOpenCounts[key, default: 0] += 1
            port.messageHandler = { [weak self] message, _ in
                guard let self,
                      let body = message as? [String: Any],
                      body["type"] as? String == "keepalive" else { return }
                self.recordKeepAliveReply(seq: body["seq"] as? Int, for: key)
            }
            port.disconnectHandler = { [weak self, weak port] _ in
                guard let self, let port, self.keepAlivePorts[key] === port else { return }
                self.keepAlivePorts.removeValue(forKey: key)
                self.applyKeepAlive(.portClosed, for: key)
                log.info("Keep-alive port closed for \(extID, privacy: .public)")
            }
            log.info("Keep-alive port opened for \(extID, privacy: .public)")
            // Accept the port before arming it: the completion handler is what marks
            // the connection ready to use, and `portOpened` may immediately send a
            // `keepalive-start` on it (a native host connected before the worker's
            // port arrived, or reconnected after a drop).
            completionHandler(nil)
            applyKeepAlive(.portOpened, for: key)
            return
        case .denied:
            guard let extID = verifiedExtensionID() else { return }
            log.warning("Extension \(extID, privacy: .public) tried connectNative to '\(hostName, privacy: .public)' without declaring nativeMessaging permission")
            completionHandler(NSError(domain: "DetourExtension", code: -1,
                                      userInfo: [NSLocalizedDescriptionKey: "nativeMessaging permission not declared"]))
            return
        case .deniedByUser:
            guard let extID = verifiedExtensionID() else { return }
            // Refused before any host object exists: nothing is looked up or spawned.
            log.warning("Refusing connectNative to '\(hostName, privacy: .public)' from \(extID, privacy: .public): nativeMessaging denied by the user")
            completionHandler(Self.nativeHostForbiddenError())
            return
        case .allowed:
            break
        }

        guard let extID = verifiedExtensionID() else { return }
        let host = NativeMessagingHost(hostName: hostName, extensionID: extID)
        let keepAliveKey = KeepAlivePortKey(controller: ObjectIdentifier(controller), extensionID: extID)
        let hostKey = ObjectIdentifier(host)

        // This host counts towards the worker's keep-alive exactly once (TASK-16).
        // The host's process exit and the port's disconnect both end the connection
        // and either can come first, so both release through here; the registry
        // removal is the token — it only succeeds for a host that was registered as
        // live (i.e. `connect()` succeeded) and only once, and it cannot match a host
        // the context unload already took away. Main thread only: `onDisconnect` is
        // dispatched to the main queue and `disconnectHandler` is a WebKit delegate
        // callback.
        let releaseHost = { [weak self] in
            guard let self,
                  self.liveNativeHosts[keepAliveKey]?.removeValue(forKey: hostKey) != nil else { return }
            if self.liveNativeHosts[keepAliveKey]?.isEmpty == true {
                self.liveNativeHosts.removeValue(forKey: keepAliveKey)
            }
            self.applyKeepAlive(.hostDisconnected, for: keepAliveKey)
        }

        host.onMessage = { response in
            port.sendMessage(response, completionHandler: nil)
        }
        host.onDisconnect = { _ in
            releaseHost()
            port.disconnect(throwing: nil)
        }
        port.messageHandler = { message, _ in
            if let msgDict = message as? [String: Any] {
                try? host.sendMessage(msgDict)
            }
        }
        port.disconnectHandler = { _ in
            releaseHost()
            host.disconnect()
        }
        do {
            try host.connect()
        } catch {
            completionHandler(error)
            return
        }
        liveNativeHosts[keepAliveKey, default: [:]][hostKey] = LiveNativeHost(host: host, port: port)
        applyKeepAlive(.hostConnected, for: keepAliveKey)
        completionHandler(nil)
    }
}
