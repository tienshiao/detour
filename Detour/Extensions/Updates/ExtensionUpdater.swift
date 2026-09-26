import Foundation
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "extension-updater")

/// Fetches an update check response or a CRX. Injected so the updater is tested
/// against canned responses rather than the network.
protocol ExtensionUpdateFetching: Sendable {
    func fetch(_ url: URL) async throws -> Data
}

/// The production fetcher: a plain GET with the Chrome user agent, which the Web
/// Store's update endpoint expects, failing on any non-2xx status.
struct URLSessionExtensionUpdateFetcher: ExtensionUpdateFetching {
    struct HTTPError: LocalizedError {
        let status: Int
        let url: URL
        var errorDescription: String? { "HTTP \(status) from \(url.host ?? url.absoluteString)" }
    }

    func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(UserAgentMode.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPError(status: http.statusCode, url: url)
        }
        return data
    }
}

/// What one extension's check came to.
enum ExtensionUpdateOutcome: Equatable {
    /// Nothing to poll: an unpacked extension, or a CRX whose manifest names no update URL.
    case notUpdatable(String)
    case upToDate
    case updated(version: String)
    /// Installed disabled; the user has to accept the added permissions in Settings.
    case updatedPendingPermissions(version: String, delta: ExtensionUpdatePolicy.PermissionDelta)
    /// `runtime.requestUpdateCheck` asked again too soon.
    case throttled
    case failed(String)
}

/// Polls each CRX-installed extension's update URL and installs a newer version in
/// place (TASK-113). Runs on launch when the last check is older than
/// `checkInterval`, then on that interval while the app runs, and on demand from
/// Extension settings and `runtime.requestUpdateCheck`.
///
/// Every candidate goes through the same gate: its CRX3 signatures must verify and
/// the declared key must derive the installed id (`CRX3Verifier`), its version must
/// be newer (`ExtensionVersion`), and `ExtensionManager.applyUpdate` re-checks both
/// and decides whether added permissions hold it disabled.
@MainActor
final class ExtensionUpdater {

    static let shared = ExtensionUpdater(fetcher: URLSessionExtensionUpdateFetcher())

    /// Posted on the main thread after `checkAllForUpdates` or a single check
    /// finishes; `userInfo["outcomes"]` is `[String: ExtensionUpdateOutcome]`.
    static let didFinishCheckNotification = Notification.Name("ExtensionUpdaterDidFinishCheck")

    /// How often the background check runs — Chrome's cadence.
    var checkInterval: TimeInterval = 5 * 60 * 60
    /// How soon `runtime.requestUpdateCheck` may ask again for the same extension.
    var requestUpdateCheckThrottle: TimeInterval = 5 * 60
    /// `prodversion` for the store: the Chrome release Detour presents as.
    var prodVersion: String = chromeProductVersion(fromUserAgent: UserAgentMode.chromeUserAgent)

    private(set) var isChecking = false

    private let fetcher: any ExtensionUpdateFetching
    private let now: () -> Date
    private let database: AppDatabase
    private unowned let manager: ExtensionManager
    private var inFlight: [String: Task<ExtensionUpdateOutcome, Never>] = [:]
    private var lastRequestUpdateCheck: [String: Date] = [:]
    private var timer: Timer?

    init(fetcher: any ExtensionUpdateFetching, now: @escaping () -> Date = Date.init,
         database: AppDatabase = .shared, manager: ExtensionManager = .shared) {
        self.fetcher = fetcher
        self.now = now
        self.database = database
        self.manager = manager
    }

    /// When the last full check finished, across launches.
    var lastCheckAt: Date? { database.extensionUpdateLastCheckAt() }

    var isCheckDue: Bool {
        guard let last = lastCheckAt else { return true }
        return now().timeIntervalSince(last) >= checkInterval
    }

    /// "131.0.0.0" from a Chrome user agent string; a fixed fallback otherwise.
    nonisolated static func chromeProductVersion(fromUserAgent userAgent: String) -> String {
        guard let range = userAgent.range(of: #"Chrome/([0-9.]+)"#, options: .regularExpression) else {
            return "131.0.0.0"
        }
        return String(userAgent[range].dropFirst("Chrome/".count))
    }

    // MARK: - Scheduling

    /// Start the background cadence: a first check `initialDelay` after the call
    /// (the extensions are still loading at launch) if one is due, then a poll
    /// every `pollInterval` that runs a check once `checkInterval` has passed
    /// since the last one. Never called in the unit-test host.
    func startPeriodicChecks(initialDelay: TimeInterval = 30, pollInterval: TimeInterval = 15 * 60) {
        stopPeriodicChecks()
        DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay) { [weak self] in
            self?.runScheduledCheckIfDue()
        }
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runScheduledCheckIfDue() }
        }
        timer.tolerance = pollInterval / 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopPeriodicChecks() {
        timer?.invalidate()
        timer = nil
    }

    private func runScheduledCheckIfDue() {
        guard isCheckDue, !isChecking else { return }
        Task { @MainActor in _ = await checkAllForUpdates() }
    }

    // MARK: - Checking

    /// Check every installed extension that can update, in parallel, and record
    /// the time. Extensions that cannot update report `notUpdatable`.
    func checkAllForUpdates() async -> [String: ExtensionUpdateOutcome] {
        isChecking = true
        defer { isChecking = false }
        let extensions = manager.extensions
        var outcomes: [String: ExtensionUpdateOutcome] = [:]
        await withTaskGroup(of: (String, ExtensionUpdateOutcome).self) { group in
            for ext in extensions {
                group.addTask { @MainActor in (ext.id, await self.checkForUpdate(extensionID: ext.id)) }
            }
            for await (id, outcome) in group {
                outcomes[id] = outcome
            }
        }
        database.setExtensionUpdateLastCheckAt(now())
        log.notice("Update check finished: \(outcomes.count) extensions, \(outcomes.values.filter { if case .updated = $0 { return true }; if case .updatedPendingPermissions = $0 { return true }; return false }.count) updated")
        NotificationCenter.default.post(name: Self.didFinishCheckNotification, object: self,
                                        userInfo: ["outcomes": outcomes])
        return outcomes
    }

    /// Check one extension now. A second call while the first is still running
    /// joins it rather than starting another download.
    func checkForUpdate(extensionID: String) async -> ExtensionUpdateOutcome {
        if let running = inFlight[extensionID] {
            return await running.value
        }
        let task = Task<ExtensionUpdateOutcome, Never> { @MainActor in
            await self.performCheck(extensionID: extensionID)
        }
        inFlight[extensionID] = task
        let outcome = await task.value
        inFlight[extensionID] = nil
        return outcome
    }

    /// `runtime.requestUpdateCheck`: a real check, but at most one per
    /// `requestUpdateCheckThrottle` per extension so a worker in a loop cannot
    /// hammer the update server.
    func requestUpdateCheck(extensionID: String) async -> ExtensionUpdateOutcome {
        let current = now()
        if let last = lastRequestUpdateCheck[extensionID],
           current.timeIntervalSince(last) < requestUpdateCheckThrottle {
            return .throttled
        }
        lastRequestUpdateCheck[extensionID] = current
        let outcome = await checkForUpdate(extensionID: extensionID)
        NotificationCenter.default.post(name: Self.didFinishCheckNotification, object: self,
                                        userInfo: ["outcomes": [extensionID: outcome]])
        return outcome
    }

    private func performCheck(extensionID: String) async -> ExtensionUpdateOutcome {
        guard let ext = manager.extension(withID: extensionID) else {
            return .failed("extension \(extensionID) is not installed")
        }
        guard ext.source != .unpacked else {
            return .notUpdatable("an unpacked extension is reloaded from its folder, not updated")
        }
        guard let updateURL = ext.updateURL else {
            return .notUpdatable("the extension declares no update URL")
        }
        let installedVersion = ext.manifest.version
        guard let requestURL = UpdateManifest.requestURL(updateURL: updateURL, extensionID: ext.id,
                                                         version: installedVersion, prodVersion: prodVersion) else {
            return .failed("the update URL \(updateURL.absoluteString) cannot be used")
        }

        do {
            let response = try await fetcher.fetch(requestURL)
            let entries = try UpdateManifest.parse(response)
            guard let entry = entries.first(where: { $0.appID.lowercased() == ext.id.lowercased() }) else {
                return .failed("the update server did not answer for \(ext.id)")
            }
            if let appStatus = entry.appStatus, appStatus != "ok" {
                return .failed("update server: \(appStatus)")
            }
            if entry.updateStatus == "noupdate" { return .upToDate }
            // Any other non-"ok" status is a server-side error (`error-…`), not
            // a current install; self-hosted manifests may omit the attribute.
            if let updateStatus = entry.updateStatus, updateStatus != "ok" {
                return .failed("update server: \(updateStatus)")
            }
            guard let version = entry.version, let codebase = entry.codebase else {
                return .failed("the update server announced an update without a version or download URL")
            }
            guard ExtensionVersion.isNewer(version, than: installedVersion) else { return .upToDate }

            log.notice("Update available for \(ext.id, privacy: .public): \(installedVersion, privacy: .public) -> \(version, privacy: .public)")
            let crx = try await fetcher.fetch(codebase)
            try ExtensionUpdatePolicy.validateSHA256(expected: entry.sha256, of: crx)
            let publicKey: Data
            switch CRX3Verifier.verify(crxData: crx) {
            case .verified(let key): publicKey = key
            case .failed(let failure): return .failed(failure.description)
            }
            let candidateID = ExtensionInstaller.deriveExtensionID(from: publicKey)
            try ExtensionUpdatePolicy.validateCandidate(installedID: ext.id, installedVersion: installedVersion,
                                                        candidateID: candidateID, candidateVersion: version)

            let unpacked = try CRXUnpacker.unpack(data: crx)
            defer { try? FileManager.default.removeItem(at: unpacked.directory) }
            // The installed extension may have changed while the download ran
            // (another check, an uninstall): applyUpdate re-reads and re-validates.
            switch try manager.applyUpdate(from: unpacked.directory, publicKey: publicKey, to: ext.id) {
            case .installed(let installedNow):
                return .updated(version: installedNow)
            case .installedPendingPermissions(let installedNow, let delta):
                return .updatedPendingPermissions(version: installedNow, delta: delta)
            }
        } catch {
            log.error("Update check failed for \(ext.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }
}
