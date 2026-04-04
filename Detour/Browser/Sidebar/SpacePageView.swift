import AppKit

/// A single page in the horizontal space strip, containing a space header and a scroll view with a table view.
class SpacePageView: NSView {
    private static let headerHeight: CGFloat = 24
    private static let headerTopPad: CGFloat = 6

    private let header = SpaceHeaderView()
    let scrollView: DraggableScrollView
    let tableView: DraggableTableView
    private let topFadeShadow: NSView
    private let bottomFadeShadow: NSView

    init(tableViewDataSource: NSTableViewDataSource,
         tableViewDelegate: NSTableViewDelegate,
         menuDelegate: NSMenuDelegate,
         dragType: NSPasteboard.PasteboardType,
         onScrollWheel: @escaping (NSEvent) -> Bool) {
        tableView = DraggableTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("TabColumn"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 36
        tableView.style = .sourceList
        tableView.dataSource = tableViewDataSource
        tableView.delegate = tableViewDelegate
        tableView.registerForDraggedTypes([dragType])
        tableView.draggingDestinationFeedbackStyle = .sourceList

        let menu = NSMenu()
        menu.delegate = menuDelegate
        tableView.menu = menu

        scrollView = DraggableScrollView()
        scrollView.contentView = DraggableClipView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.drawsBackground = false
        scrollView.onScrollWheel = onScrollWheel

        topFadeShadow = FadeShadowView(flipped: true)
        topFadeShadow.translatesAutoresizingMaskIntoConstraints = false
        topFadeShadow.alphaValue = 0

        bottomFadeShadow = FadeShadowView(flipped: false)
        bottomFadeShadow.translatesAutoresizingMaskIntoConstraints = false
        bottomFadeShadow.alphaValue = 0

        super.init(frame: .zero)

        header.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        addSubview(scrollView)
        addSubview(topFadeShadow, positioned: .above, relativeTo: scrollView)
        addSubview(bottomFadeShadow, positioned: .above, relativeTo: scrollView)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: Self.headerTopPad),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            topFadeShadow.topAnchor.constraint(equalTo: scrollView.topAnchor),
            topFadeShadow.leadingAnchor.constraint(equalTo: leadingAnchor),
            topFadeShadow.trailingAnchor.constraint(equalTo: trailingAnchor),
            topFadeShadow.heightAnchor.constraint(equalToConstant: 12),

            bottomFadeShadow.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomFadeShadow.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomFadeShadow.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomFadeShadow.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(emoji: String, name: String) {
        header.update(emoji: emoji, name: name)
    }

    func updateFadeShadows() {
        let clipView = scrollView.contentView
        guard let documentView = scrollView.documentView else { return }

        let contentHeight = documentView.frame.height
        let visibleHeight = clipView.bounds.height
        let scrollY = clipView.bounds.origin.y

        let targetTopAlpha: CGFloat = scrollY > 0 ? 1 : 0
        let targetBottomAlpha: CGFloat = contentHeight - visibleHeight - scrollY > 0.5 ? 1 : 0

        guard topFadeShadow.alphaValue != targetTopAlpha || bottomFadeShadow.alphaValue != targetBottomAlpha else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            topFadeShadow.animator().alphaValue = targetTopAlpha
            bottomFadeShadow.animator().alphaValue = targetBottomAlpha
        }
    }
}
