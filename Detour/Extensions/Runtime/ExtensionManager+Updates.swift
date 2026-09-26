import Foundation
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "extension-updater")

/// Replacing an installed extension's files with a newer or edited copy
/// (TASK-113). Both paths go through `install(from:publicKey:options:)`, which
/// already unloads the old contexts, keeps per-profile enablement and saved
/// permission decisions, rehomes open extension pages and owes
/// `runtime.onInstalled` its `update`; what is added here is the gate in front.
extension ExtensionManager {

    enum UpdateApplication: Equatable {
        case installed(version: String)
        /// Installed but left disabled until the user accepts the added permissions.
        case installedPendingPermissions(version: String, delta: ExtensionUpdatePolicy.PermissionDelta)
    }

    enum UpdateError: LocalizedError {
        case notInstalled(String)
        case notUnpacked(String)
        case sourceFolderMissing(URL?)

        var errorDescription: String? {
            switch self {
            case .notInstalled(let id): return "extension \(id) is not installed"
            case .notUnpacked(let id): return "extension \(id) was not loaded from a folder"
            case .sourceFolderMissing(let url):
                if let url { return "the folder \(url.path) no longer holds a manifest.json" }
                return "the folder this extension was loaded from is not recorded"
            }
        }
    }

    /// Install the unpacked contents of a verified update CRX over the installed
    /// extension. `publicKey` is the CRX's verified signing key; the id it derives
    /// must be `extensionID`, and the manifest's version must be newer.
    @MainActor
    @discardableResult
    func applyUpdate(from unpackedDir: URL, publicKey: Data?, to extensionID: String) throws -> UpdateApplication {
        guard let installed = self.extension(withID: extensionID) else {
            throw UpdateError.notInstalled(extensionID)
        }
        let manifest = try ExtensionManifest.parse(at: unpackedDir.appendingPathComponent("manifest.json"))
        let candidateID = publicKey.map(ExtensionInstaller.deriveExtensionID) ?? extensionID
        try ExtensionUpdatePolicy.validateCandidate(installedID: extensionID, installedVersion: installed.manifest.version,
                                                    candidateID: candidateID, candidateVersion: manifest.version)
        log.notice("Updating \(extensionID, privacy: .public) from \(installed.manifest.version, privacy: .public) to \(manifest.version, privacy: .public)")
        return try replace(installed, from: unpackedDir, publicKey: publicKey, manifest: manifest,
                           forcedID: nil, source: installed.source,
                           updateURL: ExtensionSource.pollableUpdateURL(manifest.updateURL) ?? installed.updateURL,
                           sourcePath: installed.sourcePath)
    }

    /// Reinstall an unpacked extension from the folder it was loaded from, keeping
    /// its id (Chrome's developer-mode Reload). Any version is accepted; permissions
    /// the edited manifest adds are held for approval like an update's.
    @MainActor
    @discardableResult
    func reloadUnpacked(id extensionID: String) throws -> UpdateApplication {
        guard let installed = self.extension(withID: extensionID) else {
            throw UpdateError.notInstalled(extensionID)
        }
        guard installed.source == .unpacked else { throw UpdateError.notUnpacked(extensionID) }
        guard let sourcePath = installed.sourcePath,
              FileManager.default.fileExists(atPath: sourcePath.appendingPathComponent("manifest.json").path) else {
            throw UpdateError.sourceFolderMissing(installed.sourcePath)
        }
        let manifest = try ExtensionManifest.parse(at: sourcePath.appendingPathComponent("manifest.json"))
        log.notice("Reloading unpacked \(extensionID, privacy: .public) from \(sourcePath.path, privacy: .public)")
        return try replace(installed, from: sourcePath, publicKey: nil, manifest: manifest,
                           forcedID: extensionID, source: .unpacked, updateURL: nil, sourcePath: sourcePath)
    }

    /// The installer options that replace `installed` with `manifest`'s files:
    /// the source bookkeeping carried over, and the added-permissions policy —
    /// permissions the user has not accepted yet are what this manifest adds
    /// over the installed one, plus anything an earlier update is still waiting
    /// on (an approval the user never gave does not lapse because another
    /// version arrived); with any, the replacement installs disabled.
    static func replacementOptions(for installed: WebExtension, manifest: ExtensionManifest, forcedID: String?,
                                   source: ExtensionSource, updateURL: URL?, sourcePath: URL?) -> ExtensionInstaller.Options {
        let added = ExtensionUpdatePolicy.addedPermissions(from: installed.manifest, to: manifest)
        let pendingDelta = (installed.pendingPermissionApproval?.delta ?? .none).merged(with: added)

        var options = ExtensionInstaller.Options()
        options.source = source
        options.updateURL = updateURL
        options.sourcePath = sourcePath
        options.forcedID = forcedID
        if pendingDelta.isEmpty {
            options.enabled = installed.isEnabled
        } else {
            options.enabled = false
            options.pendingPermissionApproval = .init(version: manifest.version, delta: pendingDelta)
            log.notice("\(installed.id, privacy: .public) \(manifest.version, privacy: .public) adds permissions; installed disabled pending approval: \(pendingDelta.permissions.joined(separator: ","), privacy: .public) / \(pendingDelta.hostPermissions.joined(separator: ","), privacy: .public)")
        }
        return options
    }

    @MainActor
    private func replace(_ installed: WebExtension, from sourceDir: URL, publicKey: Data?,
                         manifest: ExtensionManifest, forcedID: String?, source: ExtensionSource,
                         updateURL: URL?, sourcePath: URL?) throws -> UpdateApplication {
        let options = Self.replacementOptions(for: installed, manifest: manifest, forcedID: forcedID,
                                              source: source, updateURL: updateURL, sourcePath: sourcePath)
        let ext = try install(from: sourceDir, publicKey: publicKey, options: options)
        if let pending = ext.pendingPermissionApproval {
            return .installedPendingPermissions(version: ext.manifest.version, delta: pending.delta)
        }
        return .installed(version: ext.manifest.version)
    }

    // MARK: - Deferred updates (TASK-123)

    /// What `ExtensionUpdateDeferral` needs to know about the extension right now.
    @MainActor
    func activity(for extensionID: String) -> ExtensionUpdateDeferral.Activity {
        var activity = ExtensionUpdateDeferral.Activity()
        for profile in TabStore.shared.profiles {
            guard let host = profile.extensionContext(for: extensionID)?.baseURL.host, !host.isEmpty else { continue }
            activity.openPages += profile.extensionPageLocations(forOriginHost: host).count
        }
        activity.popupOpen = isPopupOpen(extensionID: extensionID)
        activity.liveNativeHosts = liveNativeHostCount(extensionID: extensionID)
        activity.lastBackgroundRequestAt = backgroundActivity[extensionID]
        return activity
    }

    /// The verified update waiting for `extensionID` to go idle, if any.
    func stagedUpdate(for extensionID: String) -> StagedExtensionUpdate? {
        StagedExtensionUpdate.load(for: extensionID)
    }

    /// Put a verified, unpacked update aside for `extensionID` and tell its
    /// background contexts (`runtime.onUpdateAvailable`). A staged copy that is
    /// not newer than the installed version is pointless and is discarded.
    @MainActor
    @discardableResult
    func stageUpdate(from unpackedDir: URL, publicKey: Data, version: String,
                     for extensionID: String) throws -> StagedExtensionUpdate {
        let staged = try StagedExtensionUpdate.stage(unpackedDirectory: unpackedDir, publicKey: publicKey,
                                                     version: version, for: extensionID)
        notifyUpdateAvailable(extensionID: extensionID, version: version)
        NotificationCenter.default.post(name: Self.extensionsDidChangeNotification, object: nil)
        return staged
    }

    /// Install the staged update for `extensionID` now, whatever it is doing.
    /// Returns nil when nothing is staged. A staged copy that no longer passes
    /// the update gate (the extension moved on) is discarded.
    @MainActor
    @discardableResult
    func applyStagedUpdate(for extensionID: String) throws -> UpdateApplication? {
        guard let staged = stagedUpdate(for: extensionID) else { return nil }
        defer { staged.discard() }
        do {
            let application = try applyUpdate(from: staged.directory, publicKey: staged.publicKey, to: extensionID)
            if let basePath = self.extension(withID: extensionID)?.basePath {
                StagedExtensionUpdate.removeMarker(installedAt: basePath)
            }
            log.notice("Applied staged update \(staged.version, privacy: .public) for \(extensionID, privacy: .public)")
            return application
        } catch let rejection as ExtensionUpdatePolicy.CandidateRejection {
            log.notice("Discarding staged update for \(extensionID, privacy: .public): \(rejection.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// At launch, before the extension records are read: every staged update is
    /// installed through the installer directly — no context is loaded yet, so
    /// there is nothing to unload, rehome or wake, and `loadInstalledExtensions`
    /// then reads the replaced record like any other. The added-permissions
    /// policy applies exactly as it would for a live update.
    func applyStagedUpdatesBeforeLoad() {
        let records = Dictionary(uniqueKeysWithValues: AppDatabase.shared.loadExtensions().map { ($0.id, $0) })
        for staged in StagedExtensionUpdate.all() {
            defer { staged.discard() }
            guard let record = records[staged.extensionID],
                  let installedManifest = try? JSONDecoder().decode(ExtensionManifest.self, from: record.manifestJSON) else {
                log.notice("Discarding staged update for \(staged.extensionID, privacy: .public): no longer installed")
                continue
            }
            do {
                let manifest = try ExtensionManifest.parse(at: staged.directory.appendingPathComponent("manifest.json"))
                let candidateID = ExtensionInstaller.deriveExtensionID(from: staged.publicKey)
                try ExtensionUpdatePolicy.validateCandidate(installedID: record.id, installedVersion: record.version,
                                                            candidateID: candidateID, candidateVersion: manifest.version)
                let installed = WebExtension(id: record.id, manifest: installedManifest,
                                             basePath: URL(fileURLWithPath: record.basePath), isEnabled: record.isEnabled)
                installed.source = ExtensionSource(rawValue: record.source) ?? .unpacked
                installed.updateURL = record.updateURL.flatMap(URL.init(string:))
                installed.sourcePath = record.sourcePath.map { URL(fileURLWithPath: $0) }
                installed.pendingPermissionApproval = record.pendingPermissionApprovalJSON.flatMap {
                    try? JSONDecoder().decode(ExtensionUpdatePolicy.PendingApproval.self, from: $0)
                }
                let options = Self.replacementOptions(
                    for: installed, manifest: manifest, forcedID: nil, source: installed.source,
                    updateURL: manifest.updateURL.flatMap(ExtensionSource.pollableUpdateURL) ?? installed.updateURL,
                    sourcePath: installed.sourcePath)
                let replaced = try ExtensionInstaller.install(from: staged.directory, publicKey: staged.publicKey, options: options)
                StagedExtensionUpdate.removeMarker(installedAt: replaced.basePath)
                log.notice("Applied staged update \(manifest.version, privacy: .public) for \(record.id, privacy: .public) at launch")
            } catch {
                log.error("Staged update for \(staged.extensionID, privacy: .public) not applied at launch: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: runtime.onUpdateAvailable and runtime.reload()

    /// A background context's parked `runtime.awaitUpdateAvailable` request,
    /// answered when an update is staged, with the incarnation token the polyfill
    /// stamped on it (`__detourContextInstance`; nil from a caller without one).
    /// One per (profile, extension): a newer request from the same context
    /// supersedes the old one. Static because an extension cannot add stored
    /// properties; the manager is a singleton.
    private struct UpdateAvailableWaiter {
        let reply: (Any?, String?) -> Void
        let instance: String?
    }
    private static var updateAvailableWaiters: [String: UpdateAvailableWaiter] = [:]

    /// When `runtime.onUpdateAvailable` was last delivered per (profile,
    /// extension), for which staged version, and to which incarnation of the
    /// background context. See `backgroundContextDidStart`.
    private struct UpdateAvailableDelivery {
        let version: String
        let at: Date
        let instance: String?
    }
    private static var updateAvailableDeliveries: [String: UpdateAvailableDelivery] = [:]

    /// How soon after an `onUpdateAvailable` delivery a background start counts
    /// as the extension's own `runtime.reload()`.
    static let reloadAfterUpdateAvailableWindow: TimeInterval = 15

    private static func waiterKey(extensionID: String, profileID: UUID) -> String {
        "\(profileID.uuidString)|\(extensionID)"
    }

    /// Park `reply` until an update is staged for `extensionID`; answered at once
    /// when one already is — unless that version was just delivered to this
    /// context, which is what a listener re-armed by the worker that reloaded in
    /// response looks like (answering again would reload it in a loop).
    /// `instance` is the polyfill's incarnation token, recorded with a delivery.
    func awaitUpdateAvailable(extensionID: String, profileID: UUID, instance: String? = nil,
                              reply: @escaping (Any?, String?) -> Void, now: Date = Date()) {
        let key = Self.waiterKey(extensionID: extensionID, profileID: profileID)
        if let staged = stagedUpdate(for: extensionID) {
            let delivered = Self.updateAvailableDeliveries[key]
            let justDelivered = delivered.map {
                $0.version == staged.version && now.timeIntervalSince($0.at) < Self.reloadAfterUpdateAvailableWindow
            } ?? false
            if !justDelivered {
                Self.updateAvailableDeliveries[key] = UpdateAvailableDelivery(version: staged.version, at: now, instance: instance)
                reply(["version": staged.version], nil)
                return
            }
        }
        if let previous = Self.updateAvailableWaiters[key] {
            previous.reply(nil, "superseded by a newer wait")
        }
        Self.updateAvailableWaiters[key] = UpdateAvailableWaiter(reply: reply, instance: instance)
    }

    /// Deliver `runtime.onUpdateAvailable` to every background context waiting for `extensionID`.
    func notifyUpdateAvailable(extensionID: String, version: String, now: Date = Date()) {
        let suffix = "|" + extensionID
        for (key, waiter) in Self.updateAvailableWaiters where key.hasSuffix(suffix) {
            Self.updateAvailableWaiters[key] = nil
            Self.updateAvailableDeliveries[key] = UpdateAvailableDelivery(version: version, at: now, instance: waiter.instance)
            waiter.reply(["version": version], nil)
        }
    }

    /// A background context of `extensionID` just started in `profileID` (its
    /// polyfill claimed `runtime.onInstalled`, stamping its incarnation token as
    /// `instance`). WebKit's `runtime.reload()` cannot be intercepted — `reload`
    /// is a read-only static of the runtime wrapper, unlike the functions the
    /// polyfill shadows — and a reload keeps the context's base URL, so the only
    /// trace it leaves is this restart. A restart within
    /// `reloadAfterUpdateAvailableWindow` of an `onUpdateAvailable` delivery *to
    /// an earlier incarnation* is the extension reloading to take the update,
    /// Chrome's documented pattern (an idle unload cannot happen that soon after
    /// the worker spoke), so the staged copy installs now, whatever else the
    /// extension has open. A delivery to this same incarnation is one this start
    /// asked for itself — the listener is added at script evaluation, before the
    /// claim runs on a later task — and says nothing about why it started. A
    /// reload for any other reason is not distinguishable from an event waking
    /// the worker and leaves the staged copy for the idle poll.
    @MainActor
    @discardableResult
    func backgroundContextDidStart(extensionID: String, profileID: UUID, instance: String? = nil,
                                   now: Date = Date()) -> Bool {
        let key = Self.waiterKey(extensionID: extensionID, profileID: profileID)
        guard let staged = stagedUpdate(for: extensionID),
              let delivered = Self.updateAvailableDeliveries[key],
              delivered.version == staged.version,
              now.timeIntervalSince(delivered.at) < Self.reloadAfterUpdateAvailableWindow else { return false }
        if let instance, let deliveredTo = delivered.instance, deliveredTo == instance {
            return false
        }
        Self.updateAvailableDeliveries[key] = nil
        log.notice("\(extensionID, privacy: .public) restarted after runtime.onUpdateAvailable; applying staged \(staged.version, privacy: .public)")
        do {
            let application = try applyStagedUpdate(for: extensionID)
            if let application {
                var outcomes: [String: ExtensionUpdateOutcome] = [:]
                switch application {
                case .installed(let version): outcomes[extensionID] = .updated(version: version)
                case .installedPendingPermissions(let version, let delta):
                    outcomes[extensionID] = .updatedPendingPermissions(version: version, delta: delta)
                }
                NotificationCenter.default.post(name: ExtensionUpdater.didFinishCheckNotification, object: nil,
                                                userInfo: ["outcomes": outcomes])
            }
            return application != nil
        } catch {
            log.error("Staged update for \(extensionID, privacy: .public) failed after reload: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Forget the parked waits and deliveries for `extensionID` — on uninstall,
    /// and between tests.
    func forgetUpdateAvailableState(extensionID: String) {
        let suffix = "|" + extensionID
        for key in Self.updateAvailableWaiters.keys where key.hasSuffix(suffix) { Self.updateAvailableWaiters[key] = nil }
        for key in Self.updateAvailableDeliveries.keys where key.hasSuffix(suffix) { Self.updateAvailableDeliveries[key] = nil }
    }

    /// How many background contexts are waiting for `extensionID` (tests).
    func updateAvailableWaiterCountForTesting(extensionID: String) -> Int {
        Self.updateAvailableWaiters.keys.filter { $0.hasSuffix("|" + extensionID) }.count
    }

    /// The user accepted the permissions an update added: clear the wait and turn
    /// the extension back on (globally; per-profile choices were never touched).
    @MainActor
    func approvePendingPermissions(id extensionID: String) {
        guard let ext = self.extension(withID: extensionID) else { return }
        ext.pendingPermissionApproval = nil
        AppDatabase.shared.setExtensionPendingPermissionApproval(id: extensionID, json: nil)
        log.notice("Pending permissions approved for \(extensionID, privacy: .public); enabling")
        setEnabled(id: extensionID, enabled: true)
    }
}
