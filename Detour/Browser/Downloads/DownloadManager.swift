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
    }

    let id: UUID
    let createdAt: Date
    var download: WKDownload?

    @Published var state: State = .downloading
    @Published var filename: String = ""
    @Published var sourceURL: URL?
    @Published var destinationURL: URL?
    @Published var bytesWritten: Int64 = 0
    @Published var totalBytes: Int64 = -1
    @Published var fractionCompleted: Double = 0

    private var progressObservation: AnyCancellable?

    init(download: WKDownload, sourceURL: URL?) {
        self.id = UUID()
        self.createdAt = Date()
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

        switch record.state {
        case "completed": self.state = .completed
        case "cancelled": self.state = .cancelled
        default: self.state = .failed("Interrupted")
        }
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
    static let shared = DownloadManager()

    private(set) var items: [DownloadItem] = []
    private var observers: [WeakDownloadObserver] = []
    private var saveWorkItem: DispatchWorkItem?

    var hasActiveDownloads: Bool {
        items.contains { $0.state == .downloading }
    }

    private override init() {
        super.init()
        loadPersistedDownloads()
    }

    // MARK: - Observer Management

    func addObserver(_ observer: DownloadManagerObserver) {
        observers.removeAll { $0.value == nil }
        observers.append(WeakDownloadObserver(value: observer))
    }

    func removeObserver(_ observer: DownloadManagerObserver) {
        observers.removeAll { $0.value === observer || $0.value == nil }
    }

    private func notifyObservers(_ action: (DownloadManagerObserver) -> Void) {
        observers.removeAll { $0.value == nil }
        for wrapper in observers {
            if let observer = wrapper.value {
                action(observer)
            }
        }
    }

    // MARK: - Download Management

    func handleNewDownload(_ download: WKDownload, sourceURL: URL?) -> DownloadItem {
        let item = DownloadItem(download: download, sourceURL: sourceURL)
        items.insert(item, at: 0)
        notifyObservers { $0.downloadManagerDidAddItem(item) }
        return item
    }

    func cancelDownload(_ item: DownloadItem) {
        item.download?.cancel { _ in }
        item.state = .cancelled
        item.download = nil
        notifyObservers { $0.downloadManagerDidUpdateItem(item) }
        scheduleSave()
    }

    func removeDownload(_ item: DownloadItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items.remove(at: index)
        AppDatabase.shared.deleteDownload(id: item.id.uuidString)
        notifyObservers { $0.downloadManagerDidRemoveItem(item) }
    }

    func clearCompleted() {
        let inactive = items.filter { $0.state != .downloading }
        items.removeAll { $0.state != .downloading }
        for item in inactive {
            AppDatabase.shared.deleteDownload(id: item.id.uuidString)
            notifyObservers { $0.downloadManagerDidRemoveItem(item) }
        }
    }

    // MARK: - Persistence

    private func loadPersistedDownloads() {
        let records = AppDatabase.shared.loadDownloads()
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
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveNow()
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func saveNow() {
        saveWorkItem?.cancel()
        saveWorkItem = nil

        for item in items where item.state != .downloading {
            let stateString: String
            switch item.state {
            case .completed: stateString = "completed"
            case .failed: stateString = "failed"
            case .cancelled: stateString = "cancelled"
            case .downloading: continue
            }

            let record = DownloadRecord(
                id: item.id.uuidString,
                filename: item.filename,
                sourceURL: item.sourceURL?.absoluteString,
                destinationURL: item.destinationURL?.path ?? "",
                totalBytes: item.totalBytes,
                bytesWritten: item.bytesWritten,
                state: stateString,
                createdAt: item.createdAt,
                completedAt: item.state == .completed ? Date() : nil
            )
            AppDatabase.shared.saveDownload(record)
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
        item.state = .completed
        item.fractionCompleted = 1.0
        item.download = nil
        notifyObservers { $0.downloadManagerDidUpdateItem(item) }
        scheduleSave()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = items.first(where: { $0.download === download }) else { return }
        item.state = .failed(error.localizedDescription)
        item.download = nil
        notifyObservers { $0.downloadManagerDidUpdateItem(item) }
        scheduleSave()
    }
}

private struct WeakDownloadObserver {
    weak var value: (any DownloadManagerObserver)?
}
