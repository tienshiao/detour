import AppKit

/// Page thumbnails for the sidebar hover card (TASK-190), one JPEG per key in
/// the data directory, so a tab not shown since launch still has a picture.
///
/// Written from the same capture as the Control+Tab switcher's
/// `BrowserTab.switcherPreview` (no extra snapshots), at its pixel width. The
/// key is `TabStore.thumbnailKey(for:)`; nothing is written for Private tabs.
/// Files whose key has gone are removed by `sweep`, which the store runs after
/// each session save. All file work happens on one serial background queue.
final class TabThumbnailCache {
    static let shared = TabThumbnailCache(
        directory: detourDataDirectory().appendingPathComponent("TabThumbnails", isDirectory: true))

    private let directory: URL
    private let queue = DispatchQueue(label: "com.detourbrowser.mac.tab-thumbnails", qos: .utility)
    private static let fileExtension = "jpg"

    init(directory: URL) {
        self.directory = directory
    }

    private func fileURL(for key: UUID) -> URL {
        directory.appendingPathComponent(key.uuidString).appendingPathExtension(Self.fileExtension)
    }

    func store(_ image: NSImage, for key: UUID) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let url = fileURL(for: key)
        let directory = directory
        queue.async {
            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Reads the thumbnail for `key` off the main thread; `completion` runs on
    /// the main thread, with nil when there is none.
    func image(for key: UUID, completion: @escaping (NSImage?) -> Void) {
        let url = fileURL(for: key)
        queue.async {
            let image = (try? Data(contentsOf: url)).flatMap(NSImage.init(data:))
            DispatchQueue.main.async { completion(image) }
        }
    }

    /// Removes every thumbnail whose key is not in `liveKeys`, except files
    /// modified at or after `cutoff`: one written after the caller took its
    /// live set may belong to a tab that set does not have yet.
    func sweep(keeping liveKeys: Set<UUID>, olderThan cutoff: Date) {
        let directory = directory
        queue.async {
            let fileManager = FileManager.default
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
            var files: [String: Date] = [:]
            for name in names {
                let attributes = try? fileManager.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
                files[name] = attributes?[.modificationDate] as? Date ?? .distantFuture
            }
            for name in Self.orphans(in: files, keeping: liveKeys, olderThan: cutoff) {
                try? fileManager.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    /// Waits for the queued file work. For tests.
    func flush() {
        queue.sync {}
    }

    /// The thumbnail files in `files` (name → modification date) to delete:
    /// `<uuid>.jpg` files whose key is not live and that predate `cutoff`.
    /// Anything else in the folder is left alone.
    static func orphans(in files: [String: Date], keeping liveKeys: Set<UUID>, olderThan cutoff: Date) -> [String] {
        files.compactMap { name, modified in
            let url = URL(fileURLWithPath: name)
            guard url.pathExtension == fileExtension,
                  let key = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  !liveKeys.contains(key), modified < cutoff else { return nil }
            return name
        }
    }
}
