import Foundation
import WebKit
import Combine

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

    init(download: WKDownload, sourceURL: URL?, createdAt: Date = Date()) {
        self.id = UUID()
        self.createdAt = createdAt
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

    init(filename: String, sourceURL: URL?, createdAt: Date = Date()) {
        self.id = UUID()
        self.createdAt = createdAt
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

    /// Restore from a persisted record (terminal state only)
    init(record: DownloadRecord) {
        self.id = UUID(uuidString: record.id) ?? UUID()
        self.createdAt = record.createdAt
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
    static let shared = DownloadManager(database: .shared)

    /// Runs `work` after `delay` unless the returned closure (cancel) is called
    /// first. Injected so tests drive the save debounce without waiting.
    typealias SaveScheduler = (_ delay: TimeInterval, _ work: @escaping () -> Void) -> () -> Void

    static let saveDebounce: TimeInterval = 1.0

    static let mainQueueScheduler: SaveScheduler = { delay, work in
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }

    private(set) var items: [DownloadItem] = []
    private var observers: [WeakDownloadObserver] = []
    private let database: AppDatabase
    private let now: () -> Date
    private let scheduleAfter: SaveScheduler
    /// Cancels the debounced save. Non-nil exactly while a save is pending.
    private var cancelPendingSave: (() -> Void)?

    var hasActiveDownloads: Bool {
        items.contains { $0.state == .downloading }
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

    @discardableResult
    func handleNewDownload(_ download: WKDownload, sourceURL: URL?) -> DownloadItem {
        insertAndNotify(DownloadItem(download: download, sourceURL: sourceURL, createdAt: now()))
    }

    @discardableResult
    func addManualItem(filename: String, sourceURL: URL?) -> DownloadItem {
        insertAndNotify(DownloadItem(filename: filename, sourceURL: sourceURL, createdAt: now()))
    }

    private func insertAndNotify(_ item: DownloadItem) -> DownloadItem {
        items.insert(item, at: 0)
        notifyObservers { $0.downloadManagerDidAddItem(item) }
        return item
    }

    func cancelDownload(_ item: DownloadItem) {
        item.download?.cancel { _ in }
        item.urlSessionTask?.cancel()
        item.state = .cancelled
        item.download = nil
        item.urlSessionTask = nil
        notifyObservers { $0.downloadManagerDidUpdateItem(item) }
        scheduleSave()
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
        notifyObservers { $0.downloadManagerDidUpdateItem(item) }
        scheduleSave()
    }

    func removeDownload(_ item: DownloadItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items.remove(at: index)
        database.deleteDownload(id: item.id.uuidString)
        notifyObservers { $0.downloadManagerDidRemoveItem(item) }
    }

    func clearCompleted() {
        let inactive = items.filter { $0.state != .downloading }
        items.removeAll { $0.state != .downloading }
        for item in inactive {
            database.deleteDownload(id: item.id.uuidString)
            notifyObservers { $0.downloadManagerDidRemoveItem(item) }
        }
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

        for item in items where item.state != .downloading {
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
        let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
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

        // Update the corresponding DownloadItem
        if let item = items.first(where: { $0.download === download }) {
            await MainActor.run {
                item.filename = destURL.lastPathComponent
                item.destinationURL = destURL
                if let contentLength = (response as? HTTPURLResponse)?.expectedContentLength, contentLength > 0 {
                    item.totalBytes = contentLength
                }
                notifyObservers { $0.downloadManagerDidUpdateItem(item) }
            }
        }

        return destURL
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = items.first(where: { $0.download === download }) else { return }
        downloadDidEnd(item)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = items.first(where: { $0.download === download }) else { return }
        downloadDidEnd(item, failure: error.localizedDescription)
    }
}

private struct WeakDownloadObserver {
    weak var value: (any DownloadManagerObserver)?
}
