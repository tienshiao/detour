import AppKit

class DownloadPopoverViewController: NSViewController {
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "No downloads")
    private let manager: DownloadManager
    /// The window this popover belongs to: it lists that window's downloads
    /// only (TASK-148).
    private let scope: DownloadScope
    private var items: [DownloadItem] { manager.items(in: scope) }

    init(scope: DownloadScope, manager: DownloadManager = .shared) {
        self.scope = scope
        self.manager = manager
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 300))

        // Header
        let headerLabel = NSTextField(labelWithString: "Downloads")
        headerLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        let clearButton = NSButton(title: "Clear", target: self, action: #selector(clearCompleted))
        clearButton.bezelStyle = .inline
        clearButton.controlSize = .small
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        // Table
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("DownloadColumn"))
        column.width = 300
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 60
        tableView.dataSource = self
        tableView.delegate = self
        tableView.style = .plain

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Empty state
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = !items.isEmpty

        container.addSubview(headerLabel)
        container.addSubview(clearButton)
        container.addSubview(scrollView)
        container.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            headerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),

            clearButton.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: 16),
        ])

        self.view = container
        manager.addObserver(self)
    }

    deinit {
        manager.removeObserver(self)
    }

    @objc private func clearCompleted() {
        manager.clearCompleted(in: scope)
        tableView.reloadData()
        emptyLabel.isHidden = !items.isEmpty
    }
}

// MARK: - NSTableViewDataSource

extension DownloadPopoverViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }
}

// MARK: - NSTableViewDelegate

extension DownloadPopoverViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cellID = NSUserInterfaceItemIdentifier("DownloadCell")
        let cell: DownloadCellView
        if let existing = tableView.makeView(withIdentifier: cellID, owner: nil) as? DownloadCellView {
            cell = existing
        } else {
            cell = DownloadCellView()
            cell.identifier = cellID
        }

        let items = self.items
        guard row < items.count else { return cell }
        let item = items[row]
        cell.configure(with: item)

        cell.onCancel = { [weak self] in
            guard let self else { return }
            if item.state == .downloading {
                self.manager.cancelDownload(item)
            } else {
                self.manager.removeDownload(item)
            }
        }
        cell.onReveal = {
            if let url = item.destinationURL {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }

        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        // Double-click to open completed downloads
        let items = self.items
        guard row < items.count else { return false }
        let item = items[row]
        if item.state == .completed, let url = item.destinationURL {
            NSWorkspace.shared.open(url)
        }
        return false
    }
}

// MARK: - DownloadManagerObserver

extension DownloadPopoverViewController: DownloadManagerObserver {
    // The manager reports every window's downloads; one this window does not
    // list changes nothing here.
    func downloadManagerDidAddItem(_ item: DownloadItem) {
        tableView.reloadData()
        emptyLabel.isHidden = !items.isEmpty
    }

    func downloadManagerDidUpdateItem(_ item: DownloadItem) {
        if let row = items.firstIndex(where: { $0.id == item.id }) {
            tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        }
    }

    func downloadManagerDidRemoveItem(_ item: DownloadItem) {
        tableView.reloadData()
        emptyLabel.isHidden = !items.isEmpty
    }
}
