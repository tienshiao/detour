import AppKit
import Combine

protocol FavoritesBarDelegate: AnyObject {
    func favoritesBar(_ bar: FavoritesBarView, didReceiveDropOfTab payload: SidebarDragPayload, at index: Int)
    func favoritesBar(_ bar: FavoritesBarView, didClickFavoriteAt index: Int)
    func favoritesBar(_ bar: FavoritesBarView, didDoubleClickFavoriteAt index: Int)
    func favoritesBar(_ bar: FavoritesBarView, didReorderFavoriteFrom sourceIndex: Int, to destinationIndex: Int)
    func favoritesBar(_ bar: FavoritesBarView, didRemoveFavoriteAt index: Int)
}

class FavoritesBarView: NSView, NSDraggingSource {
    override var mouseDownCanMoveWindow: Bool { false }
    weak var delegate: FavoritesBarDelegate?

    /// Identity of the owning sidebar, stamped into drag payloads so drops from
    /// another window's bars are rejected. Set by TabSidebarViewController.
    var sidebarID: UUID?

    private static let tileSize: CGFloat = 40
    private static let iconSize: CGFloat = 16
    private static let maxPerRow = 4
    private static let hPad: CGFloat = 10
    private static let tileSpacing: CGFloat = 8
    private static let vPad: CGFloat = 4

    private var favorites: [Favorite] = []
    private(set) var tileViews: [FavoriteTileView] = []
    private var dropZoneLabel: NSTextField?
    private var dropZoneBorder: CAShapeLayer?
    private var isDragHighlighted = false
    private var dragInsertionIndex: Int? { didSet { updateInsertionIndicator() } }
    private var isAnimatingTileUpdate = false

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

        let newHeight = computeHeight()
        let targetFrames = computeTileFrames(for: favorites.count)

        // If bounds aren't ready (e.g. first update before layout), animation can't
        // compute frames. Fall back to a non-animated rebuild so a later layout pass
        // positions the tiles instead of leaving them invisible.
        if !favorites.isEmpty && targetFrames.isEmpty {
            rebuildTiles(selectedTabID: selectedTabID)
            return
        }

        let animOrigin = pendingAnimationOrigin
        pendingAnimationOrigin = nil

        // Reuse existing tiles without resetting their frames so the animator below
        // captures each tile's current position as the animation's starting point.
        var newTiles: [FavoriteTileView] = []
        for (index, fav) in favorites.enumerated() {
            if let existing = oldTilesByID[fav.id] {
                existing.updateIndex(index)
                existing.isSelected = fav.tab?.id == selectedTabID
                existing.refreshFavicon()
                existing.refreshPeekBadge()
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

        // Suppress layoutTiles() during the animation so the implicit Auto Layout pass
        // driven by the height-constraint animation can't overwrite the explicit tile
        // frame animations below.
        isAnimatingTileUpdate = true

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.allowsImplicitAnimation = true

            if heightConstraintRef?.constant != newHeight {
                heightConstraintRef?.animator().constant = newHeight
            }

            for id in removedIDs {
                oldTilesByID[id]?.animator().alphaValue = 0
            }

            for (i, tile) in newTiles.enumerated() where i < targetFrames.count {
                tile.animator().frame = targetFrames[i]
                if addedIDs.contains(favorites[i].id) {
                    tile.animator().alphaValue = 1
                }
            }

            superview?.layoutSubtreeIfNeeded()
        } completionHandler: { [weak self] in
            self?.isAnimatingTileUpdate = false
            for id in removedIDs {
                oldTilesByID[id]?.removeFromSuperview()
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

    /// Refreshes the favicon and peek badge on the tile backed by `tabID`, if
    /// any. Called when a Peek opens, navigates, or closes on a favourite host.
    func refreshTile(forTabID tabID: UUID) {
        for tile in tileViews where tile.favorite.tab?.id == tabID {
            tile.refreshFavicon()
            tile.refreshPeekBadge()
        }
    }

    /// Returns the frame of the tile at `index` in this view's coordinate space.
    func tileFrame(at index: Int) -> NSRect? {
        guard index < tileViews.count else { return nil }
        return tileViews[index].frame
    }

    /// Returns the current index of the favorite with the given ID, if present.
    func index(ofFavoriteID id: UUID) -> Int? {
        favorites.firstIndex(where: { $0.id == id })
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
        if !isAnimatingTileUpdate {
            layoutTiles()
        }
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
        let count = favorites.count
        let numRows = (count + Self.maxPerRow - 1) / Self.maxPerRow
        let distanceFromTop = bounds.height - Self.vPad - point.y
        let rawRow = Int(floor(distanceFromTop / (Self.tileSize + Self.tileSpacing)))
        let targetRow = max(0, min(numRows - 1, rawRow))
        let rowStart = targetRow * Self.maxPerRow
        let rowEnd = min(rowStart + Self.maxPerRow, count)
        for index in rowStart..<rowEnd {
            if point.x < tileViews[index].frame.midX {
                return index
            }
        }
        return rowEnd
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
        let y: CGFloat
        if index < tileViews.count {
            let frame = tileViews[index].frame
            x = frame.minX - Self.tileSpacing / 2
            y = frame.minY + 4
        } else if let last = tileViews.last {
            x = last.frame.maxX + Self.tileSpacing / 2
            y = last.frame.minY + 4
        } else {
            x = Self.hPad
            y = bounds.height - Self.vPad - Self.tileSize + 4
        }

        let indicatorWidth: CGFloat = 2
        let indicatorHeight: CGFloat = Self.tileSize - 8
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
        guard index < tileViews.count, index < favorites.count, let sidebarID else { return }
        let tile = tileViews[index]
        dragSourceIndex = index

        let payload = FavoriteDragPayload(favoriteID: favorites[index].id, sidebarID: sidebarID)
        guard let payloadString = payload.pasteboardString else { return }
        let pbItem = NSPasteboardItem()
        pbItem.setString(payloadString, forType: favoritePasteboardType)
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

        // Internal favorite reorder — resolve the source index by ID at drop time
        if let data = pasteboard.string(forType: favoritePasteboardType),
           let payload = FavoriteDragPayload(pasteboardString: data) {
            guard payload.sidebarID == sidebarID,
                  let srcIdx = favorites.firstIndex(where: { $0.id == payload.favoriteID }) else { return false }
            let rawDest = dragInsertionIndex ?? favorites.count
            // dragInsertionIndex is in pre-removal coordinates, but the reorder
            // API removes the source first then inserts; shift down for forward moves.
            let destIdx = srcIdx < rawDest ? rawDest - 1 : rawDest
            guard srcIdx != destIdx else { return false }
            delegate?.favoritesBar(self, didReorderFavoriteFrom: srcIdx, to: destIdx)
            return true
        }

        // Tab drop → add favorite
        if let data = pasteboard.string(forType: tabReorderPasteboardType),
           let payload = SidebarDragPayload(pasteboardString: data) {
            // Only lone tabs and lone pinned entries can become favorites —
            // folders and split rows/members (normal or pinned) can't (a split
            // row is two tabs; favoriting only one would silently scatter the
            // group). Allow-list, so new payload kinds default to rejected.
            guard payload.sidebarID == sidebarID,
                  payload.kind == .normalTab || payload.kind == .pinnedEntry else { return false }
            let destIdx = dragInsertionIndex ?? favorites.count
            delegate?.favoritesBar(self, didReceiveDropOfTab: payload, at: destIdx)
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
    let imageView = NSImageView()
    /// Rounded chip in the tile's top-right corner backing the peek favicon, so
    /// the secondary icon reads over any main favicon. Hidden when the backing
    /// tab has no live or parked Peek.
    let peekBadgeView = NSView()
    let peekFaviconImageView = NSImageView()
    private var peekSubscription: AnyCancellable?
    private var faviconSubscriptions = Set<AnyCancellable>()
    private var trackingArea: NSTrackingArea?
    private var isHovering = false

    private static let restingColor = NSColor.labelColor.withAlphaComponent(0.04)
    private static let hoverColor = UIConstants.hoverBackgroundColor
    private static let peekBadgeSize: CGFloat = 14
    private static let peekBadgeIconSize: CGFloat = 10
    private static let peekBadgeInset: CGFloat = 2

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
        addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        refreshFavicon()
        setupPeekBadge()
        refreshPeekBadge()
    }

    /// Syncs the main favicon with the favourite and rebinds the two sources
    /// that can still change it: the favourite's own download and the backing
    /// tab's. Both matter — a restored favourite downloads its icon while its
    /// sleeping tab downloads the same URL — and publishing reaches every
    /// window's tile, unlike the single callback this replaced (TASK-53).
    /// Cheap and idempotent: call it whenever the tile is reused, since a
    /// favourite's `tab` swaps as it activates or goes dormant.
    func refreshFavicon() {
        bindFavicon()
        applyFavicon()
    }

    private func applyFavicon() {
        imageView.image = favorite.displayFavicon
            ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
    }

    /// The main-thread hop is load-bearing for the same reason as the peek
    /// badge's: `@Published` emits before the property is stored, and
    /// `displayFavicon` re-reads it.
    private func bindFavicon() {
        faviconSubscriptions.removeAll()
        favorite.$favicon
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyFavicon() }
            .store(in: &faviconSubscriptions)
        favorite.tab?.$favicon
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyFavicon() }
            .store(in: &faviconSubscriptions)
    }

    private func setupPeekBadge() {
        peekBadgeView.wantsLayer = true
        peekBadgeView.translatesAutoresizingMaskIntoConstraints = false
        peekBadgeView.layer?.cornerRadius = 4
        peekBadgeView.layer?.borderWidth = 0.5
        peekBadgeView.isHidden = true
        updatePeekBadgeColors()

        peekFaviconImageView.imageScaling = .scaleProportionallyUpOrDown
        peekFaviconImageView.translatesAutoresizingMaskIntoConstraints = false
        peekBadgeView.addSubview(peekFaviconImageView)

        // Added after imageView so the chip draws on top of the main favicon.
        addSubview(peekBadgeView)

        NSLayoutConstraint.activate([
            peekBadgeView.widthAnchor.constraint(equalToConstant: Self.peekBadgeSize),
            peekBadgeView.heightAnchor.constraint(equalToConstant: Self.peekBadgeSize),
            peekBadgeView.topAnchor.constraint(equalTo: topAnchor, constant: Self.peekBadgeInset),
            peekBadgeView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.peekBadgeInset),

            peekFaviconImageView.widthAnchor.constraint(equalToConstant: Self.peekBadgeIconSize),
            peekFaviconImageView.heightAnchor.constraint(equalToConstant: Self.peekBadgeIconSize),
            peekFaviconImageView.centerXAnchor.constraint(equalTo: peekBadgeView.centerXAnchor),
            peekFaviconImageView.centerYAnchor.constraint(equalTo: peekBadgeView.centerYAnchor),
        ])
    }

    /// Syncs the peek badge with the backing tab's live-or-parked peek favicon.
    /// Cheap and idempotent: call it whenever the tile is reused or the peek
    /// state may have changed. Rebinds unconditionally — tiles are reused
    /// across `update(favorites:)` calls and a favourite's `tab` swaps as it
    /// activates / goes dormant.
    func refreshPeekBadge() {
        bindPeekFavicon()
        applyPeekBadge()
    }

    private func applyPeekBadge() {
        let image = favorite.tab?.displayPeekFavicon
        peekFaviconImageView.image = image
        peekBadgeView.isHidden = image == nil
    }

    /// Subscribes to the backing tab's `$peekFavicon`, which carries both the
    /// download that follows a relaunch (`BrowserTab.downloadPeekFavicon`) and
    /// the live peek's favicon mirrored by `BrowserWindowController` — so the
    /// badge tracks the tab in every window and space page, not only the one
    /// hosting the peek. The main-thread hop is load-bearing: `@Published`
    /// emits before the property is stored, and `displayPeekFavicon` re-reads it.
    private func bindPeekFavicon() {
        guard let tab = favorite.tab else {
            peekSubscription = nil
            return
        }
        peekSubscription = tab.$peekFavicon
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyPeekBadge()
            }
    }

    /// CGColor doesn't track appearance changes — re-resolve on theme switches.
    private func updatePeekBadgeColors() {
        peekBadgeView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        peekBadgeView.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.15).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            updatePeekBadgeColors()
            updateBackground()
        }
    }

    /// The favicon and peek chip are decorative: the tile owns every click, drag
    /// and context menu. A plain `NSView` chip would otherwise become the hit
    /// view and, being non-opaque, report `mouseDownCanMoveWindow == true` —
    /// turning a click on the badge corner into a window drag.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
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
