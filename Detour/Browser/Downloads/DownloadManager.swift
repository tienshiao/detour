import Foundation
import WebKit
import Combine

// MARK: - DownloadScope

/// Which windows list a download, and whether it is saved (TASK-148).
enum DownloadScope: Equatable {
    /// Started in a normal window: listed in every normal window and saved to
    /// the `download` table once it has ended.
    case normal
    /// Started in the Private window whose incognito space has this id: listed
    /// and badged in that window only, never saved, and dropped from the list
    /// when the space is removed (the window closed). One still in flight
    /// then is cancelled (`PrivateDownloadClosePolicy`).
    case incognito(spaceID: UUID)

    /// Only a normal window's downloads are written to the `download` table.
    var isPersisted: Bool {
        self == .normal
    }

    /// A window lists, and counts in its badge, the downloads of its own scope
    /// only: normal windows share one list, each Private window has its own.
    func isListed(inWindowWith windowScope: DownloadScope) -> Bool {
        self == windowScope
    }

    /// True for a Private download whose incognito space is no longer among
    /// the live ones: its window closed, so nothing may list it any more.
    func isOrphaned(liveIncognitoSpaceIDs: Set<UUID>) -> Bool {
        switch self {
        case .normal: false
        case .incognito(let spaceID): !liveIncognitoSpaceIDs.contains(spaceID)
        }
    }
}

// MARK: - DownloadItem

class DownloadItem: NSObject {
    enum State: Equatable {
        case downloading
        case completed
        case failed(String)
        case cancelled

        var persistenceString: String {
            switch self {
            case .downloading: "downloading"
            case .completed: "completed"
            case .failed: "failed"
            case .cancelled: "cancelled"
            }
        }

        init(persistenceString: String) {
            switch persistenceString {
            case "completed": self = .completed
            case "cancelled": self = .cancelled
            default: self = .failed("Interrupted")
            }
        }
    }

    let id: UUID
    let createdAt: Date
    /// Fixed at creation: the window the download started in (TASK-148).
    let scope: DownloadScope
    /// When the download finished. Set once, by `markCompleted(at:)`, and
    /// carried through every later save and a relaunch (TASK-143). Nil for a
    /// download that is in flight, failed or was cancelled.
    private(set) var completedAt: Date?
    var download: WKDownload?
    var urlSessionTask: URLSessionTask?

    @Published var state: State = .downloading
    @Published var filename: String = ""
    @Published var sourceURL: URL?
    @Published var destinationURL: URL?
    @Published var bytesWritten: Int64 = 0
    @Published var totalBytes: Int64 = -1
    @Published var fractionCompleted: Double = 0

    private var progressObservation: AnyCancellable?

    init(download: WKDownload, sourceURL: URL?, scope: DownloadScope = .normal, createdAt: Date = Date()) {
        self.id = UUID()
        self.createdAt = createdAt
        self.scope = scope
        self.download = download
        self.sourceURL = sourceURL
        super.init()

        progressObservation = download.progress.publisher(for: \.fractionCompleted)
            .receive(on: RunLoop.main)
            .sink { [weak self] fraction in
                guard let self else { return }
                self.fractionCompleted = fraction
                self.bytesWritten = download.progress.completedUnitCount
                self.totalBytes = download.progress.totalUnitCount
            }
    }

    init(filename: String, sourceURL: URL?, scope: DownloadScope = .normal, createdAt: Date = Date()) {
        self.id = UUID()
        self.createdAt = createdAt
        self.scope = scope
        super.init()
        self.filename = filename
        self.sourceURL = sourceURL
    }

    func observeURLSessionTask(_ task: URLSessionTask) {
        self.urlSessionTask = task
        progressObservation = task.publisher(for: \.countOfBytesReceived)
            .throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)
            .sink { [weak self, weak task] received in
                guard let self, let task else { return }
                self.bytesWritten = received
                let expected = task.countOfBytesExpectedToReceive
                let newTotal: Int64 = expected > 0 ? expected : -1
                if self.totalBytes != newTotal { self.totalBytes = newTotal }
                self.fractionCompleted = newTotal > 0 ? Double(received) / Double(newTotal) : 0
            }
    }

    /// Restore from a persisted record (terminal state only). Only normal
    /// downloads are ever saved, so a restored item is always `.normal`.
    init(record: DownloadRecord) {
        self.id = UUID(uuidString: record.id) ?? UUID()
        self.createdAt = record.createdAt
        self.scope = .normal
        self.filename = record.filename
        self.sourceURL = record.sourceURL.flatMap { URL(string: $0) }
        self.destinationURL = URL(fileURLWithPath: record.destinationURL)
        self.bytesWritten = record.bytesWritten
        self.totalBytes = record.totalBytes
        self.fractionCompleted = record.totalBytes > 0 ? Double(record.bytesWritten) / Double(record.totalBytes) : 0
        super.init()

        self.state = State(persistenceString: record.state)
        // Only a completed download has a completion time; a row in any other
        // state loads without one whatever its column holds.
        self.completedAt = state == .completed ? record.completedAt : nil
    }

    /// Moves the item to `.completed`. The completion time is recorded the
    /// first time only; a repeated call cannot move it.
    func markCompleted(at date: Date) {
        if completedAt == nil { completedAt = date }
        state = .completed
    }

    /// Whether a save writes this item: it has ended, and its scope is saved.
    var isPersisted: Bool {
        scope.isPersisted && state != .downloading
    }
}

// MARK: - Observer Protocol

protocol DownloadManagerObserver: AnyObject {
    func downloadManagerDidAddItem(_ item: DownloadItem)
    func downloadManagerDidUpdateItem(_ item: DownloadItem)
    func downloadManagerDidRemoveItem(_ item: DownloadItem)
}

extension DownloadManagerObserver {
    func downloadManagerDidAddItem(_ item: DownloadItem) {}
    func downloadManagerDidUpdateItem(_ item: DownloadItem) {}
    func downloadManagerDidRemoveItem(_ item: DownloadItem) {}
}

// MARK: - DownloadManager

class DownloadManager: NSObject {
    static let shared: DownloadManager = {
        let manager = DownloadManager(database: .shared)
        manager.observeIncognitoSpaces(of: .shared)
        return manager
    }()

    /// Runs `work` after `delay` unless the returned closure (cancel) is called
    /// first. Injected so tests drive the save debounce without waiting.
    typealias SaveScheduler = (_ delay: TimeInterval, _ work: @escaping () -> Void) -> () -> Void

    static let saveDebounce: TimeInterval = 1.0

    static let mainQueueScheduler: SaveScheduler = { delay, work in
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }

    /// Every listed download, newest first, whatever window it belongs to. A
    /// window reads its own list through `items(in:)`.
    private(set) var items: [DownloadItem] = []
    private var observers: [WeakDownloadObserver] = []
    private weak var observedStore: TabStore?
    private let database: AppDatabase
    private let now: () -> Date
    private let scheduleAfter: SaveScheduler
    /// Cancels the debounced save. Non-nil exactly while a save is pending.
    private var cancelPendingSave: (() -> Void)?
    /// Where a `WKDownload` is saved: the user's Downloads folder. A variable
    /// so a test with a real download writes to a temporary directory instead.
    var downloadsDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!

    /// The downloads a window with `scope` lists, newest first.
    func items(in scope: DownloadScope) -> [DownloadItem] {
        items.filter { $0.scope.isListed(inWindowWith: scope) }
    }

    /// Whether a window with `scope` shows the in-flight badge.
    func hasActiveDownloads(in scope: DownloadScope) -> Bool {
        items.contains { $0.state == .downloading && $0.scope.isListed(inWindowWith: scope) }
    }

    init(database: AppDatabase,
         now: @escaping () -> Date = Date.init,
         scheduler: @escaping SaveScheduler = DownloadManager.mainQueueScheduler) {
        self.database = database
        self.now = now
        self.scheduleAfter = scheduler
        super.init()
        loadPersistedDownloads()
    }

    // MARK: - Observer Management

    func addObserver(_ observer: DownloadManagerObserver) {
        pruneObservers()
        observers.append(WeakDownloadObserver(value: observer))
    }

    func removeObserver(_ observer: DownloadManagerObserver) {
        observers.removeAll { $0.value === observer || $0.value == nil }
    }

    private func pruneObservers() {
        observers.removeAll { $0.value == nil }
    }

    private func notifyObservers(_ action: (DownloadManagerObserver) -> Void) {
        pruneObservers()
        for wrapper in observers {
            if let observer = wrapper.value {
                action(observer)
            }
        }
    }

    // MARK: - Download Management

    /// `scope` is the window the download started in
    /// (`BrowserWindowController.downloadScope`).
    @discardableResult
    func handleNewDownload(_ download: WKDownload, sourceURL: URL?, scope: DownloadScope) -> DownloadItem {
        insertAndNotify(DownloadItem(download: download, sourceURL: sourceURL, scope: scope, createdAt: now()))
    }

    @discardableResult
    func addManualItem(filename: String, sourceURL: URL?, scope: DownloadScope) -> DownloadItem {
        insertAndNotify(DownloadItem(filename: filename, sourceURL: sourceURL, scope: scope, createdAt: now()))
    }

    private func insertAndNotify(_ item: DownloadItem) -> DownloadItem {
        items.insert(item, at: 0)
        notifyObservers { $0.downloadManagerDidAddItem(item) }
        return item
    }

    func cancelDownload(_ item: DownloadItem) {
        stop(item, removingPartialFile: false)
        itemDidEnd(item)
    }

    /// Stops the transfer behind `item` and marks it cancelled, telling nobody.
    ///
    /// WebKit leaves what a cancelled `WKDownload` wrote where it wrote it.
    /// With `removingPartialFile` that file is removed: at once, because at
    /// quit WebKit's reply to the cancel never arrives, and again on the reply,
    /// for a file the network process created in between. Only a `WKDownload`
    /// that is still in flight has such a file; a manual item's bytes are held
    /// by whoever fetches them.
    private func stop(_ item: DownloadItem, removingPartialFile: Bool) {
        let partialFile = removingPartialFile && item.state == .downloading && item.download != nil
            ? item.destinationURL : nil
        item.download?.cancel { _ in
            if let partialFile { try? FileManager.default.removeItem(at: partialFile) }
        }
        if let partialFile { try? FileManager.default.removeItem(at: partialFile) }
        item.urlSessionTask?.cancel()
        item.state = .cancelled
        item.download = nil
        item.urlSessionTask = nil
    }

    /// The download behind `item` ended on its own: it finished or failed. The
    /// `WKDownloadDelegate` callbacks land here; a cancel goes through
    /// `cancelDownload`.
    func downloadDidEnd(_ item: DownloadItem, failure: String? = nil) {
        if let failure {
            item.state = .failed(failure)
        } else {
            item.markCompleted(at: now())
            item.fractionCompleted = 1.0
        }
        item.download = nil
        itemDidEnd(item)
    }

    /// `item` just reached a terminal state.
    private func itemDidEnd(_ item: DownloadItem) {
        notifyObservers { $0.downloadManagerDidUpdateItem(item) }
        if item.isPersisted { scheduleSave() }
    }

    func removeDownload(_ item: DownloadItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items.remove(at: index)
        if item.scope.isPersisted { database.deleteDownload(id: item.id.uuidString) }
        notifyObservers { $0.downloadManagerDidRemoveItem(item) }
    }

    /// Removes the ended downloads a window with `scope` lists; the lists of
    /// other scopes are left alone.
    func clearCompleted(in scope: DownloadScope) {
        let cleared = items.filter { $0.state != .downloading && $0.scope.isListed(inWindowWith: scope) }
        guard !cleared.isEmpty else { return }
        items.removeAll { item in cleared.contains { $0 === item } }
        for item in cleared {
            if item.scope.isPersisted { database.deleteDownload(id: item.id.uuidString) }
            notifyObservers { $0.downloadManagerDidRemoveItem(item) }
        }
    }

    // MARK: - Private windows (TASK-148)

    /// Follows `store` so that removing an incognito space (its Private window
    /// closed) drops that window's downloads.
    func observeIncognitoSpaces(of store: TabStore) {
        observedStore?.removeObserver(self)
        observedStore = store
        store.addObserver(self)
    }

    /// Drops every Private download whose incognito space is not in
    /// `liveSpaceIDs`. One still in flight is cancelled and its partial file
    /// removed (TASK-156): its window went away without the question, or the
    /// user answered it, and nothing may keep running where no window lists
    /// it. This is the backstop for every path that removes an incognito
    /// space, so no caller has to remember it.
    func discardIncognitoDownloads(keeping liveSpaceIDs: Set<UUID>) {
        let orphaned = items.filter { $0.scope.isOrphaned(liveIncognitoSpaceIDs: liveSpaceIDs) }
        guard !orphaned.isEmpty else { return }
        items.removeAll { item in orphaned.contains { $0 === item } }
        for item in orphaned {
            if item.state == .downloading { stop(item, removingPartialFile: true) }
            notifyObservers { $0.downloadManagerDidRemoveItem(item) }
        }
    }

    /// The in-flight downloads `closing` would cancel: what a window asks
    /// about before it closes, and the quit confirmation names.
    func privateDownloadsInFlight(closing: PrivateDownloadClosePolicy.Closing) -> [DownloadItem] {
        items.filter {
            PrivateDownloadClosePolicy.cancels(downloadIn: $0.scope, isInFlight: $0.state == .downloading,
                                               closing: closing)
        }
    }

    /// Cancels the downloads `closing` cancels and removes their partial
    /// files. They stay listed, as cancelled, until their window's space goes.
    func cancelPrivateDownloads(closing: PrivateDownloadClosePolicy.Closing) {
        for item in privateDownloadsInFlight(closing: closing) {
            stop(item, removingPartialFile: true)
            itemDidEnd(item)
        }
    }

    /// The listed item behind a `WKDownload` callback. Nil once the item was
    /// cancelled or dropped: `stop` lets go of the download.
    private func trackedItem(for download: WKDownload) -> DownloadItem? {
        items.first { $0.download === download }
    }

    // MARK: - Persistence

    private func loadPersistedDownloads() {
        let records = database.loadDownloads()
        for record in records {
            let item = DownloadItem(record: record)
            // Mark stale "downloading" items as failed
            if record.state == "downloading" {
                item.state = .failed("Interrupted")
            }
            items.append(item)
        }
    }

    func scheduleSave() {
        cancelPendingSave?()
        cancelPendingSave = scheduleAfter(Self.saveDebounce) { [weak self] in
            self?.saveNow()
        }
    }

    /// Writes a save that is still waiting out the debounce. Called before the
    /// app terminates, so a download that ended in the last second is not lost
    /// (TASK-143). Does nothing when no save is pending.
    func flushPendingSave() {
        guard cancelPendingSave != nil else { return }
        saveNow()
    }

    private func saveNow() {
        cancelPendingSave?()
        cancelPendingSave = nil

        for item in items where item.isPersisted {
            let record = DownloadRecord(
                id: item.id.uuidString,
                filename: item.filename,
                sourceURL: item.sourceURL?.absoluteString,
                destinationURL: item.destinationURL?.path ?? "",
                totalBytes: item.totalBytes,
                bytesWritten: item.bytesWritten,
                state: item.state.persistenceString,
                createdAt: item.createdAt,
                completedAt: item.completedAt
            )
            database.saveDownload(record)
        }
    }
}

// MARK: - WKDownloadDelegate

extension DownloadManager: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        // Cancelled, or dropped with its Private window, before WebKit asked
        // where to write: refusing a destination cancels it, so a download
        // nothing tracks never writes a file.
        guard let item = await MainActor.run(body: { trackedItem(for: download) }) else { return nil }

        let downloadsDir = downloadsDirectory
        var destURL = downloadsDir.appendingPathComponent(suggestedFilename)

        // Resolve name conflicts
        let fm = FileManager.default
        if fm.fileExists(atPath: destURL.path) {
            let name = destURL.deletingPathExtension().lastPathComponent
            let ext = destURL.pathExtension
            var counter = 1
            repeat {
                let newName = ext.isEmpty ? "\(name) (\(counter))" : "\(name) (\(counter)).\(ext)"
                destURL = downloadsDir.appendingPathComponent(newName)
                counter += 1
            } while fm.fileExists(atPath: destURL.path)
        }

        let chosen = destURL
        return await MainActor.run { () -> URL? in
            // Cancelled while the name was being chosen.
            guard item.download === download else { return nil }
            item.filename = chosen.lastPathComponent
            item.destinationURL = chosen
            if let contentLength = (response as? HTTPURLResponse)?.expectedContentLength, contentLength > 0 {
                item.totalBytes = contentLength
            }
            notifyObservers { $0.downloadManagerDidUpdateItem(item) }
            return chosen
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = trackedItem(for: download) else { return }
        downloadDidEnd(item)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = trackedItem(for: download) else { return }
        downloadDidEnd(item, failure: error.localizedDescription)
    }
}

// MARK: - TabStoreObserver

extension DownloadManager: TabStoreObserver {
    /// The only signal `removeIncognitoSpace` sends. Reconciling against the
    /// spaces that still exist covers every path that removes one.
    func tabStoreDidUpdateSpaces() {
        guard let store = observedStore else { return }
        discardIncognitoDownloads(keeping: store.liveIncognitoDownloadScopeIDs)
    }

    /// A Private Quick Detour's downloads are scoped to its tab (TASK-193.1)
    /// and go when its window closes, as a Private window's do.
    func tabStoreDidCloseQuickDetour(_ tab: BrowserTab) {
        tabStoreDidUpdateSpaces()
    }
}

private struct WeakDownloadObserver {
    weak var value: (any DownloadManagerObserver)?
}
