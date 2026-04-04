import AppKit

private let tabReorderPasteboardType = NSPasteboard.PasteboardType("com.mybrowser.tab-reorder")

/// Shared pasteboard type for favorite drag-and-drop. Also registered in SpacePageView and TabSidebarViewController.
let favoritePasteboardType = NSPasteboard.PasteboardType("com.mybrowser.favorite-reorder")

protocol FavoritesBarDelegate: AnyObject {
    func favoritesBar(_ bar: FavoritesBarView, didReceiveDropOfTabRow row: Int, at index: Int)
    func favoritesBar(_ bar: FavoritesBarView, didClickFavoriteAt index: Int)
    func favoritesBar(_ bar: FavoritesBarView, didDoubleClickFavoriteAt index: Int)
    func favoritesBar(_ bar: FavoritesBarView, didReorderFavoriteFrom sourceIndex: Int, to destinationIndex: Int)
    func favoritesBar(_ bar: FavoritesBarView, didRemoveFavoriteAt index: Int)
}

class FavoritesBarView: NSView, NSDraggingSource {
    override var mouseDownCanMoveWindow: Bool { false }
    weak var delegate: FavoritesBarDelegate?

    private static let tileSize: CGFloat = 40
    private static let iconSize: CGFloat = 16
    private static let maxPerRow = 4
    private static let hPad: CGFloat = 10
    private static let tileSpacing: CGFloat = 8
    private static let vPad: CGFloat = 4

    private var favorites: [Favorite] = []
    private var tileViews: [FavoriteTileView] = []
    private var dropZoneLabel: NSTextField?
    private var dropZoneBorder: CAShapeLayer?
    private var isDragHighlighted = false
    private var dragInsertionIndex: Int? { didSet { updateInsertionIndicator() } }

    // Internal drag tracking
    private var dragSourceIndex: Int?
    private var insertionIndicator: CALayer?

    /// Local-coordinate origin for animating a newly added tile from its source position.
    private var pendingAnimationOrigin: NSPoint?

    private(set) var heightConstraintRef: NSLayoutConstraint?

    func setHeightConstraint(_ constraint: NSLayoutConstraint) {
        heightConstraintRef = constraint
    }
    private var selectedFavoriteID: UUID?

    var selectionColor: NSColor? {
        didSet {
            for tile in tileViews {
                tile.selectionColor = selectionColor
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([tabReorderPasteboardType, favoritePasteboardType])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public

    var isEmpty: Bool { favorites.isEmpty }

    func update(favorites: [Favorite], selectedTabID: UUID? = nil, animated: Bool = true) {
        let oldFavorites = self.favorites
        self.favorites = favorites
        self.selectedFavoriteID = selectedTabID

        let oldIDs = oldFavorites.map(\.id)
        let newIDs = favorites.map(\.id)

        // Non-animated: full rebuild (used on space switch / initial load)
        guard animated, !oldIDs.isEmpty || !newIDs.isEmpty else {
            rebuildTiles(selectedTabID: selectedTabID)
            return
        }

        let oldTilesByID = Dictionary(zip(oldIDs, tileViews), uniquingKeysWith: { a, _ in a })
        let removedIDs = Set(oldIDs).subtracting(newIDs)
        let addedIDs = Set(newIDs).subtracting(oldIDs)

        // Fade out removed tiles
        for id in removedIDs {
            if let tile = oldTilesByID[id] {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    tile.animator().alphaValue = 0
                } completionHandler: {
                    tile.removeFromSuperview()
                }
            }
        }

        // Animate height change first so target frames use correct bounds
        let newHeight = computeHeight()
        let heightChanged = heightConstraintRef?.constant != newHeight
        if heightChanged {
            heightConstraintRef?.constant = newHeight
            superview?.layoutSubtreeIfNeeded()
        }

        // Compute target frames after height is set
        let targetFrames = computeTileFrames(for: favorites.count)

        let animOrigin = pendingAnimationOrigin
        pendingAnimationOrigin = nil

        // Build new tile array, reusing existing tiles where possible
        var newTiles: [FavoriteTileView] = []
        for (index, fav) in favorites.enumerated() {
            if let existing = oldTilesByID[fav.id] {
                existing.updateIndex(index)
                existing.isSelected = fav.tab?.id == selectedTabID
                newTiles.append(existing)
            } else {
                let tile = FavoriteTileView(favorite: fav, index: index)
                tile.selectionColor = selectionColor
                tile.isSelected = fav.tab?.id == selectedTabID
                if index < targetFrames.count {
                    if let origin = animOrigin {
                        // Start at the source position (e.g. where the tab was)
                        let target = targetFrames[index]
                        tile.frame = NSRect(x: origin.x - target.width / 2,
                                            y: origin.y - target.height / 2,
                                            width: target.width, height: target.height)
                    } else {
                        tile.frame = targetFrames[index]
                    }
                }
                tile.alphaValue = animOrigin != nil ? 1 : 0
                addSubview(tile)
                newTiles.append(tile)
            }
        }
        tileViews = newTiles

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.allowsImplicitAnimation = true

            for (i, tile) in tileViews.enumerated() where i < targetFrames.count {
                if addedIDs.contains(favorites[i].id) {
                    tile.animator().frame = targetFrames[i]
                    tile.animator().alphaValue = 1
                } else {
                    tile.animator().frame = targetFrames[i]
                }
            }
        }
    }

    private func rebuildTiles(selectedTabID: UUID?) {
        tileViews.forEach { $0.removeFromSuperview() }
        tileViews.removeAll()

        for (index, fav) in favorites.enumerated() {
            let tile = FavoriteTileView(favorite: fav, index: index)
            tile.selectionColor = selectionColor
            tile.isSelected = fav.tab?.id == selectedTabID
            addSubview(tile)
            tileViews.append(tile)
        }

        let newHeight = computeHeight()
        if heightConstraintRef?.constant != newHeight {
            heightConstraintRef?.constant = newHeight
        }
        needsLayout = true
    }

    /// Returns the frame of the tile at `index` in this view's coordinate space.
    func tileFrame(at index: Int) -> NSRect? {
        guard index < tileViews.count else { return nil }
        return tileViews[index].frame
    }

    /// Sets the origin point (in this view's coordinates) for the next tile addition animation.
    func setAnimationOrigin(_ point: NSPoint) {
        pendingAnimationOrigin = point
    }

    func updateSelection(selectedTabID: UUID?) {
        self.selectedFavoriteID = selectedTabID
        for tile in tileViews {
            tile.isSelected = tile.favorite.tab?.id == selectedTabID
        }
    }

    func showDropZone(_ show: Bool) {
        if show && favorites.isEmpty {
            isDragHighlighted = true
            animateHeightTo(44)
            setupDropZoneAppearance()
        } else if !show {
            isDragHighlighted = false
            teardownDropZoneAppearance()
            // If favorites were added during the drag, the bar already has the right height
            // from update(favorites:). Only collapse if still empty.
            if favorites.isEmpty {
                animateHeightTo(0)
            }
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        layoutTiles()
        updateDropZoneBorderPath()
    }

    private func computeHeight() -> CGFloat {
        guard !favorites.isEmpty else { return 0 }
        let rows = (favorites.count + Self.maxPerRow - 1) / Self.maxPerRow
        return CGFloat(rows) * Self.tileSize + CGFloat(rows - 1) * Self.tileSpacing + Self.vPad * 2
    }

    private func layoutTiles() {
        guard !favorites.isEmpty, bounds.width > 0, bounds.height > 0 else { return }
        let availableWidth = bounds.width - Self.hPad * 2
        guard availableWidth > 0 else { return }
        let count = favorites.count

        for (index, tile) in tileViews.enumerated() {
            let row = index / Self.maxPerRow
            let col = index % Self.maxPerRow
            let itemsInRow = min(Self.maxPerRow, count - row * Self.maxPerRow)
            guard itemsInRow > 0 else { continue }

            let tileWidth = (availableWidth - CGFloat(itemsInRow - 1) * Self.tileSpacing) / CGFloat(itemsInRow)
            let x = Self.hPad + CGFloat(col) * (tileWidth + Self.tileSpacing)
            let y = bounds.height - Self.vPad - CGFloat(row + 1) * Self.tileSize - CGFloat(row) * Self.tileSpacing
            tile.frame = NSRect(x: x, y: y, width: tileWidth, height: Self.tileSize)
        }
    }

    private func computeTileFrames(for count: Int) -> [NSRect] {
        guard count > 0 else { return [] }
        let availableWidth = bounds.width - Self.hPad * 2
        guard availableWidth > 0 else { return [] }
        // Use the target height based on count, not current bounds (which may not have updated yet)
        let rows = (count + Self.maxPerRow - 1) / Self.maxPerRow
        let totalHeight = CGFloat(rows) * Self.tileSize + CGFloat(rows - 1) * Self.tileSpacing + Self.vPad * 2

        var frames: [NSRect] = []
        for index in 0..<count {
            let row = index / Self.maxPerRow
            let col = index % Self.maxPerRow
            let itemsInRow = min(Self.maxPerRow, count - row * Self.maxPerRow)
            let tileWidth = (availableWidth - CGFloat(itemsInRow - 1) * Self.tileSpacing) / CGFloat(itemsInRow)
            let x = Self.hPad + CGFloat(col) * (tileWidth + Self.tileSpacing)
            let y = totalHeight - Self.vPad - CGFloat(row + 1) * Self.tileSize - CGFloat(row) * Self.tileSpacing
            frames.append(NSRect(x: x, y: y, width: tileWidth, height: Self.tileSize))
        }
        return frames
    }

    private func insertionIndex(for point: NSPoint) -> Int {
        guard !favorites.isEmpty else { return 0 }
        // Find the closest tile boundary
        for (index, tile) in tileViews.enumerated() {
            if point.x < tile.frame.midX {
                return index
            }
        }
        return favorites.count
    }

    // MARK: - Drop Zone Appearance

    private func setupDropZoneAppearance() {
        if dropZoneLabel == nil {
            let label = NSTextField(labelWithString: "Drop to add favorite")
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            dropZoneLabel = label
        }

        if dropZoneBorder == nil {
            wantsLayer = true
            let border = CAShapeLayer()
            border.strokeColor = NSColor.secondaryLabelColor.withAlphaComponent(0.3).cgColor
            border.fillColor = nil
            border.lineDashPattern = [6, 4]
            border.lineWidth = 1.5
            layer?.addSublayer(border)
            dropZoneBorder = border
        }

        updateDropZoneBorderPath()
    }

    private func teardownDropZoneAppearance() {
        dropZoneLabel?.removeFromSuperview()
        dropZoneLabel = nil
        dropZoneBorder?.removeFromSuperlayer()
        dropZoneBorder = nil
    }

    override func updateLayer() {
        super.updateLayer()
        updateDropZoneBorderPath()
    }

    private func updateDropZoneBorderPath() {
        guard let border = dropZoneBorder else { return }
        let inset = bounds.insetBy(dx: 16, dy: 4)
        border.path = NSBezierPath(roundedRect: inset, xRadius: 8, yRadius: 8).cgPath
    }

    // MARK: - Insertion Indicator

    private func updateInsertionIndicator() {
        guard let index = dragInsertionIndex, !favorites.isEmpty else {
            insertionIndicator?.removeFromSuperlayer()
            insertionIndicator = nil
            return
        }

        wantsLayer = true
        if insertionIndicator == nil {
            let indicator = CALayer()
            indicator.backgroundColor = NSColor.controlAccentColor.cgColor
            indicator.cornerRadius = 1
            layer?.addSublayer(indicator)
            insertionIndicator = indicator
        }

        // Position: vertical bar at the insertion boundary
        let x: CGFloat
        if index < tileViews.count {
            x = tileViews[index].frame.minX - Self.tileSpacing / 2
        } else if let last = tileViews.last {
            x = last.frame.maxX + Self.tileSpacing / 2
        } else {
            x = Self.hPad
        }

        let indicatorWidth: CGFloat = 2
        let indicatorHeight: CGFloat = Self.tileSize - 8
        let y = bounds.height - Self.vPad - Self.tileSize + 4
        insertionIndicator?.frame = NSRect(x: x - indicatorWidth / 2, y: y, width: indicatorWidth, height: indicatorHeight)
    }

    private func removeInsertionIndicator() {
        insertionIndicator?.removeFromSuperlayer()
        insertionIndicator = nil
    }

    private func animateHeightTo(_ height: CGFloat) {
        guard let constraint = heightConstraintRef, constraint.constant != height else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            constraint.animator().constant = height
            superview?.layoutSubtreeIfNeeded()
        }
    }

    // MARK: - Dragging Source (for favorite tiles)

    func beginDraggingFavorite(at index: Int, event: NSEvent) {
        guard index < tileViews.count else { return }
        let tile = tileViews[index]
        dragSourceIndex = index

        let pbItem = NSPasteboardItem()
        pbItem.setString("\(index)", forType: favoritePasteboardType)
        let item = NSDraggingItem(pasteboardWriter: pbItem)
        let image = tile.snapshotImage()
        item.setDraggingFrame(tile.frame, contents: image)

        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragSourceIndex = nil
    }

    // MARK: - Dragging Destination

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if favorites.isEmpty {
            isDragHighlighted = true
            setupDropZoneAppearance()
        }
        return .move
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        dragInsertionIndex = insertionIndex(for: point)
        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dragInsertionIndex = nil
        removeInsertionIndicator()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer {
            dragInsertionIndex = nil
            removeInsertionIndicator()
            isDragHighlighted = false
            teardownDropZoneAppearance()
        }

        let pasteboard = sender.draggingPasteboard

        // Internal favorite reorder
        if let data = pasteboard.string(forType: favoritePasteboardType),
           let srcIdx = Int(data) {
            let destIdx = dragInsertionIndex ?? favorites.count
            guard srcIdx != destIdx else { return false }
            delegate?.favoritesBar(self, didReorderFavoriteFrom: srcIdx, to: destIdx)
            return true
        }

        // Tab drop → add favorite
        if let data = pasteboard.string(forType: tabReorderPasteboardType),
           let tabRow = Int(data) {
            let destIdx = dragInsertionIndex ?? favorites.count
            delegate?.favoritesBar(self, didReceiveDropOfTabRow: tabRow, at: destIdx)
            return true
        }

        return false
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        return true
    }
}

// MARK: - FavoriteTileView

class FavoriteTileView: NSView {
    private(set) var index: Int
    let favorite: Favorite
    private let imageView = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var isHovering = false

    private static let restingColor = NSColor.labelColor.withAlphaComponent(0.04)
    private static let hoverColor = UIConstants.hoverBackgroundColor

    var isSelected = false { didSet { updateBackground() } }
    var selectionColor: NSColor? { didSet { updateBackground() } }

    // Prevent window drag when clicking/dragging on tiles
    override var mouseDownCanMoveWindow: Bool { false }

    init(favorite: Favorite, index: Int) {
        self.favorite = favorite
        self.index = index
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = UIConstants.defaultCornerRadius
        updateBackground()

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.image = favorite.displayFavicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        favorite.onFaviconDownloaded = { [weak self, weak favorite] in
            guard let favorite else { return }
            self?.imageView.image = favorite.favicon
        }
    }

    private func updateBackground() {
        if isSelected, let color = selectionColor {
            layer?.backgroundColor = color.withAlphaComponent(0.15).cgColor
        } else if isHovering {
            layer?.backgroundColor = Self.hoverColor.cgColor
        } else {
            layer?.backgroundColor = Self.restingColor.cgColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateBackground()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            if let bar = superview as? FavoritesBarView {
                bar.delegate?.favoritesBar(bar, didDoubleClickFavoriteAt: index)
            }
            return
        }

        let mask: NSEvent.EventTypeMask = [.leftMouseUp, .leftMouseDragged]
        guard let nextEvent = window?.nextEvent(matching: mask, until: .distantFuture, inMode: .eventTracking, dequeue: true) else { return }

        if nextEvent.type == .leftMouseDragged {
            if let bar = superview as? FavoritesBarView {
                bar.beginDraggingFavorite(at: index, event: event)
            }
        } else if bounds.contains(convert(nextEvent.locationInWindow, from: nil)) {
            if let bar = superview as? FavoritesBarView {
                bar.delegate?.favoritesBar(bar, didClickFavoriteAt: index)
            }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let removeItem = NSMenuItem(title: "Remove from Favorites", action: #selector(removeFavorite), keyEquivalent: "")
        removeItem.target = self
        menu.addItem(removeItem)
        return menu
    }

    @objc private func removeFavorite() {
        if let bar = superview as? FavoritesBarView {
            bar.delegate?.favoritesBar(bar, didRemoveFavoriteAt: index)
        }
    }

    func updateIndex(_ newIndex: Int) {
        index = newIndex
    }

    func snapshotImage() -> NSImage {
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        Self.hoverColor.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: bounds.size), xRadius: 6, yRadius: 6).fill()
        if let bitmapRep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: bitmapRep)
            bitmapRep.draw(in: NSRect(origin: .zero, size: bounds.size))
        }
        image.unlockFocus()
        return image
    }
}
