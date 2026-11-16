import AppKit

/// Icon (grid) view — the Finder default view. Backed by NSCollectionView,
/// driven by the pane's current item list. Double-click opens; selection is
/// reported back so the pane can act on it.
final class IconViewController: NSViewController, NSCollectionViewDataSource,
                                NSCollectionViewDelegate, ThemeObserving {

    private(set) var items: [FileItem] = []
    var onOpen: ((FileItem) -> Void)?
    var onSelectionChange: (([FileItem]) -> Void)?
    /// Files were dropped: (urls, the folder item dropped onto or nil for the
    /// current directory, isCopy). The pane performs the transfer.
    var onDrop: (([URL], FileItem?, Bool) -> Void)?

    private let scroll = NSScrollView()
    private let collection = IconCollectionView()
    /// Builds the right-click menu once the clicked item is selected.
    var menuProvider: (() -> NSMenu?)?
    private static let itemId = NSUserInterfaceItemIdentifier("IconGridItem")

    override func loadView() {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 100, height: 88)
        layout.sectionInset = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 14
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.allowsEmptySelection = true
        collection.backgroundColors = [.clear]
        collection.register(IconGridItem.self, forItemWithIdentifier: IconViewController.itemId)
        // Drag files out to Finder/other apps, and accept drops into the folder
        // (or onto a subfolder item) — parity with the list view.
        collection.registerForDraggedTypes([.fileURL])
        collection.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        collection.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: true)

        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.focusRingType = .none
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let host = NSView()
        host.wantsLayer = true
        host.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: host.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        self.view = host

        let dbl = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
        dbl.numberOfClicksRequired = 2
        dbl.delaysPrimaryMouseButtonEvents = false
        collection.addGestureRecognizer(dbl)

        collection.menuForEvent = { [weak self] event in self?.contextMenu(for: event) }

        applyTheme()
        subscribeToTheme(self)
    }

    /// Finder behaviour: right-clicking an item selects it (keeping a multi-
    /// selection that already includes it); right-clicking empty space clears
    /// the selection, which gives the folder menu.
    private func contextMenu(for event: NSEvent) -> NSMenu? {
        let pt = collection.convert(event.locationInWindow, from: nil)
        if let ip = collection.indexPathForItem(at: pt) {
            if !collection.selectionIndexPaths.contains(ip) {
                collection.deselectAll(nil)
                collection.selectItems(at: [ip], scrollPosition: [])
            }
        } else {
            collection.deselectAll(nil)
        }
        reportSelection()
        return menuProvider?()
    }
    /// Test hook: the menu a right-click at this item (or empty space) shows.
    func testContextMenu(atItem index: Int?) -> NSMenu? {
        let pt: NSPoint
        if let index, let attrs = collection.layoutAttributesForItem(at: IndexPath(item: index, section: 0)) {
            pt = NSPoint(x: attrs.frame.midX, y: attrs.frame.midY)
        } else {
            pt = NSPoint(x: collection.bounds.maxX - 2, y: collection.bounds.maxY - 2)
        }
        guard let ev = NSEvent.mouseEvent(with: .rightMouseDown, location: collection.convert(pt, to: nil),
                                          modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 1) else { return nil }
        return contextMenu(for: ev)
    }

    func reload(_ items: [FileItem], preserving preferredSelection: [URL]? = nil) {
        // Preserve the selection by URL across the reload. NSCollectionView's
        // reloadData() silently clears selection with NO deselect callback, so
        // without this the pane's cached selection goes stale + invisible — and a
        // destructive command could act on an item that's no longer shown selected.
        let selectedURLs = Set((preferredSelection ?? collection.selectionIndexPaths.compactMap {
            self.items.indices.contains($0.item) ? self.items[$0.item].url : nil
        }).map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
        self.items = items
        collection.reloadData()
        if !selectedURLs.isEmpty {
            let ips = items.indices
                .filter { selectedURLs.contains(items[$0].url.standardizedFileURL.resolvingSymlinksInPath().path) }
                .map { IndexPath(item: $0, section: 0) }
            collection.selectionIndexPaths = Set(ips)
        }
        reportSelection()   // rebuild the pane's selection from the real post-reload state
    }

    // MARK: Keyboard navigation (vim j/k/gg/G + open)

    /// Move the single selection by `delta` items, clamped, scrolling to it.
    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let cur = collection.selectionIndexPaths.first?.item ?? (delta >= 0 ? -1 : items.count)
        select(index: max(0, min(items.count - 1, cur + delta)))
    }
    func selectFirst() { guard !items.isEmpty else { return }; select(index: 0) }
    func selectLast() { guard !items.isEmpty else { return }; select(index: items.count - 1) }

    /// Re-select the items matching `urls` (selection preserved across a
    /// view-mode switch). No-op if none match.
    func restoreSelection(_ urls: [URL]) {
        let set = Set(urls.map { $0.standardizedFileURL.path })
        let ips = items.enumerated()
            .filter { set.contains($0.element.url.standardizedFileURL.path) }
            .map { IndexPath(item: $0.offset, section: 0) }
        guard !ips.isEmpty else { return }
        collection.selectItems(at: Set(ips), scrollPosition: .nearestHorizontalEdge)
        reportSelection()
    }

    /// Test hook: name colours of the cells on screen, as sRGB hex.
    var testLabelHexes: [String] {
        collection.visibleItems().compactMap { ($0 as? IconGridItem)?.textField?.textColor?.testHex }
    }

    /// Test hook: the currently-selected item(s).
    var testSelectedItems: [FileItem] {
        collection.selectionIndexPaths.compactMap { items.indices.contains($0.item) ? items[$0.item] : nil }
    }

    private func select(index: Int) {
        let ip = IndexPath(item: index, section: 0)
        collection.deselectAll(nil)
        collection.selectItems(at: [ip], scrollPosition: .nearestHorizontalEdge)
        reportSelection()
    }

    /// Open the focused (selected) item, if any.
    func openSelected() {
        if let ip = collection.selectionIndexPaths.first, items.indices.contains(ip.item) {
            onOpen?(items[ip.item])
        }
    }

    @objc func applyTheme() {
        let t = ThemeManager.shared.current
        let bg: NSColor = t.id == "system" ? .controlBackgroundColor : t.background
        scroll.backgroundColor = bg
        view.layer?.backgroundColor = bg.cgColor
        // Cells keep the text colour they were configured with; redo them so a
        // switch to a dark theme doesn't leave dark names on a dark background.
        if !items.isEmpty { reload(items) }
    }

    @objc private func handleDoubleClick(_ g: NSClickGestureRecognizer) {
        let pt = g.location(in: collection)
        guard let ip = collection.indexPathForItem(at: pt), items.indices.contains(ip.item) else { return }
        onOpen?(items[ip.item])
    }

    // MARK: NSCollectionViewDataSource
    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }
    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt ip: IndexPath) -> NSCollectionViewItem {
        let item = cv.makeItem(withIdentifier: IconViewController.itemId, for: ip)
        if let grid = item as? IconGridItem, items.indices.contains(ip.item) {
            grid.configure(with: items[ip.item], labelColor: labelColor)
        }
        return item
    }

    private var labelColor: NSColor {
        let t = ThemeManager.shared.current
        return t.id == "system" ? .labelColor : t.labelPrimary
    }

    // MARK: NSCollectionViewDelegate
    func collectionView(_ cv: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { reportSelection() }
    func collectionView(_ cv: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { reportSelection() }

    // MARK: Drag & drop
    func collectionView(_ cv: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>,
                        with event: NSEvent) -> Bool { !indexPaths.isEmpty }

    func collectionView(_ cv: NSCollectionView, pasteboardWriterForItemAt ip: IndexPath) -> NSPasteboardWriting? {
        items.indices.contains(ip.item) ? (items[ip.item].url as NSURL) : nil
    }

    func collectionView(_ cv: NSCollectionView, validateDrop info: NSDraggingInfo,
                        proposedIndexPath ip: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        // Drop ON a folder item → into it; otherwise into the current directory.
        if proposedDropOperation.pointee == .on, items.indices.contains(ip.pointee.item),
           items[ip.pointee.item].isDirectory {
            return FileOps.dropIsCopy(info) ? .copy : .move
        }
        proposedDropOperation.pointee = .before   // "between items" → current dir
        return FileOps.dropIsCopy(info) ? .copy : .move
    }

    func collectionView(_ cv: NSCollectionView, acceptDrop info: NSDraggingInfo,
                        indexPath ip: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else { return false }
        let folder: FileItem? = (dropOperation == .on && items.indices.contains(ip.item)
                                 && items[ip.item].isDirectory) ? items[ip.item] : nil
        onDrop?(urls, folder, FileOps.dropIsCopy(info))
        return true
    }
    private func reportSelection() {
        let sel = collection.selectionIndexPaths.compactMap { items.indices.contains($0.item) ? items[$0.item] : nil }
        onSelectionChange?(sel)
    }
}

/// Hands right-clicks to the controller, which selects the clicked item first.
private final class IconCollectionView: NSCollectionView {
    var menuForEvent: ((NSEvent) -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { menuForEvent?(event) ?? super.menu(for: event) }
}

/// One icon-grid cell: a 48pt icon above a centered, two-line name label.
final class IconGridItem: NSCollectionViewItem {
    private let img = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        img.translatesAutoresizingMaskIntoConstraints = false
        img.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 2
        nameLabel.font = NSFont.systemFont(ofSize: 11)
        nameLabel.cell?.wraps = true
        nameLabel.drawsBackground = false
        nameLabel.isBordered = false
        v.addSubview(img)
        v.addSubview(nameLabel)
        NSLayoutConstraint.activate([
            img.topAnchor.constraint(equalTo: v.topAnchor, constant: 4),
            img.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            img.widthAnchor.constraint(equalToConstant: 48),
            img.heightAnchor.constraint(equalToConstant: 48),
            nameLabel.topAnchor.constraint(equalTo: img.bottomAnchor, constant: 3),
            nameLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
            nameLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -2),
        ])
        self.view = v
        self.imageView = img
        self.textField = nameLabel
    }

    func configure(with item: FileItem, labelColor: NSColor) {
        nameLabel.stringValue = item.name
        nameLabel.textColor = item.isHidden ? ThemeChrome.tertiary : labelColor
        img.image = IconCache.shared.icon(for: item)   // cached per-extension, not a LaunchServices hit per cell
    }

    override var isSelected: Bool {
        didSet { applySelection() }
    }
    private func applySelection() {
        view.layer?.cornerRadius = 6
        let t = ThemeManager.shared.current
        let sel = t.id == "system" ? ThemeManager.shared.effectiveAccent.withAlphaComponent(0.25)
                                    : t.selectionBackground
        view.layer?.backgroundColor = isSelected ? sel.cgColor : NSColor.clear.cgColor
    }
}

extension NSColor {
    /// sRGB hex, for comparing colours in tests.
    var testHex: String {
        guard let c = usingColorSpace(.sRGB) else { return "?" }
        return String(format: "%02X%02X%02X", Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}
