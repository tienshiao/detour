import AppKit
import Combine

class DownloadCellView: NSTableCellView {
    private let filenameLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let actionButton = NSButton()

    private var subscriptions = Set<AnyCancellable>()
    private weak var currentItem: DownloadItem?

    var onCancel: (() -> Void)?
    var onReveal: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        filenameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        filenameLabel.lineBreakMode = .byTruncatingMiddle
        filenameLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        actionButton.bezelStyle = .inline
        actionButton.isBordered = false
        actionButton.imagePosition = .imageOnly
        actionButton.target = self
        actionButton.action = #selector(actionClicked)
        actionButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(filenameLabel)
        addSubview(statusLabel)
        addSubview(progressBar)
        addSubview(actionButton)

        NSLayoutConstraint.activate([
            filenameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            filenameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            filenameLabel.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -4),

            statusLabel.topAnchor.constraint(equalTo: filenameLabel.bottomAnchor, constant: 2),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -4),

            progressBar.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            progressBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            progressBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            progressBar.heightAnchor.constraint(equalToConstant: 4),

            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            actionButton.widthAnchor.constraint(equalToConstant: 24),
            actionButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    func configure(with item: DownloadItem) {
        subscriptions.removeAll()
        currentItem = item

        item.$filename
            .receive(on: RunLoop.main)
            .sink { [weak self] name in
                self?.filenameLabel.stringValue = name.isEmpty ? "Downloading…" : name
            }
            .store(in: &subscriptions)

        Publishers.CombineLatest3(item.$state, item.$bytesWritten, item.$totalBytes)
            .receive(on: RunLoop.main)
            .sink { [weak self] state, written, total in
                self?.updateStatus(state: state, bytesWritten: written, totalBytes: total)
            }
            .store(in: &subscriptions)

        item.$fractionCompleted
            .receive(on: RunLoop.main)
            .sink { [weak self] fraction in
                self?.progressBar.doubleValue = fraction
            }
            .store(in: &subscriptions)

        item.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.updateActionButton(state: state)
                self?.progressBar.isHidden = state != .downloading
            }
            .store(in: &subscriptions)
    }

    private func updateStatus(state: DownloadItem.State, bytesWritten: Int64, totalBytes: Int64) {
        switch state {
        case .downloading:
            if totalBytes > 0 {
                let written = ByteCountFormatter.string(fromByteCount: bytesWritten, countStyle: .file)
                let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
                statusLabel.stringValue = "\(written) / \(total)"
            } else {
                let written = ByteCountFormatter.string(fromByteCount: bytesWritten, countStyle: .file)
                statusLabel.stringValue = "\(written)"
                progressBar.isIndeterminate = true
                progressBar.startAnimation(nil)
            }
        case .completed:
            let size = totalBytes > 0 ? ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file) : ""
            statusLabel.stringValue = size.isEmpty ? "Completed" : "Completed — \(size)"
        case .failed(let message):
            statusLabel.stringValue = "Failed — \(message)"
        case .cancelled:
            statusLabel.stringValue = "Cancelled"
        }
    }

    private func updateActionButton(state: DownloadItem.State) {
        switch state {
        case .downloading:
            actionButton.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Cancel")
        case .completed:
            actionButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Reveal in Finder")
        case .failed, .cancelled:
            actionButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Remove")
        }
    }

    @objc private func actionClicked() {
        guard let item = currentItem else { return }
        switch item.state {
        case .downloading:
            onCancel?()
        case .completed:
            onReveal?()
        case .failed, .cancelled:
            onCancel?() // reuse for remove
        }
    }
}
