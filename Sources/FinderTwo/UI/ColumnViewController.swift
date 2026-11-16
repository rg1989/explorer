import AppKit

/// NSBrowser reports a content-driven intrinsic size (≈ visible columns × column
/// width), so pushing/popping columns changed the view's fitting size — a second
/// path (besides the split controller's preferredContentSize) that could nudge
/// the window. Returning noIntrinsicMetric decouples column count from layout
/// size; the browser fills its host via edge constraints and scrolls instead.
private final class FixedWidthBrowser: NSBrowser {
    /// Right-clicks go to the controller, which selects the clicked row first.
    var menuForEvent: ((NSEvent) -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { menuForEvent?(event) ?? super.menu(for: event) }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
    /// NSBrowser.tile() grows the browser's OWN frame to fit every column, which —
    /// through the window's constraint-based layout — widened the whole window as
    /// columns were pushed (confirmed in the trace as
    /// -[NSWindow _changeWindowFrameFromConstraintsIfNecessary]). Clamp the width to
    /// the host so NSBrowser keeps its frame fixed and uses its horizontal scroller
    /// instead of widening itself (and the window).
    override func setFrameSize(_ newSize: NSSize) {
        var size = newSize
        if let cap = superview?.bounds.width, cap > 0 {
            size.width = min(size.width, cap)
        }
        super.setFrameSize(size)
    }
}

/// NSBrowser-based Miller column view. The browser owns the per-column data
/// (each column is the contents of one path component); we drive its delegate
/// from the active tab's DirectoryModel for the root and use direct filesystem
/// calls for deeper columns.
final class ColumnViewController: NSViewController, NSBrowserDelegate, ThemeObserving {

    weak var pane: PaneController?
    private let browser = FixedWidthBrowser()

    init(pane: PaneController) {
        self.pane = pane
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        browser.translatesAutoresizingMaskIntoConstraints = true   // autoresizing, not constraints (see host setup)
        browser.delegate = self
        browser.cellPrototype = NSBrowserCell()
        browser.hasHorizontalScroller = true
        browser.minColumnWidth = 180
        // Fixed-width columns, no user/auto column resizing. .userColumnResizing
        // makes NSBrowser manage column widths dynamically, which imposes a
        // content-driven width demand that pushed the window/panes around as you
        // drilled. .noColumnResizing pins every column to defaultColumnWidth so the
        // browser's width is constant; overflow scrolls horizontally.
        browser.columnResizingType = .noColumnResizing
        browser.setDefaultColumnWidth(220)
        browser.allowsMultipleSelection = true
        browser.allowsEmptySelection = true
        browser.target = self
        browser.action = #selector(handleSelection)
        browser.doubleAction = #selector(handleDoubleClick)
        browser.takesTitleFromPreviousColumn = true
        // No maxVisibleColumns target — NSBrowser uses the available width and the
        // horizontal scroller, never asking to grow to show a fixed column count.
        // Host the browser with autoresizing springs, NOT AutoLayout constraints.
        // NSBrowser's columns impose a *required* minimum width; pinned to the host
        // with required edge constraints, that demand propagated up and made AppKit
        // grow the whole window to fit as columns were pushed — confirmed in the
        // trace as -[NSWindow _changeWindowFrameFromConstraintsIfNecessary]. Springs
        // keep the demand contained: the browser just fills the host (kept in sync in
        // viewDidLayout) and scrolls columns horizontally instead of widening the
        // window.
        let host = NSView()
        browser.autoresizingMask = [.width, .height]
        host.addSubview(browser)
        self.view = host

        browser.menuForEvent = { [weak self] event in self?.contextMenu(for: event) }
        // Copy, move, rename, trash and new folder all log here; re-read the open
        // columns so they show the change.
        NotificationCenter.default.addObserver(self, selector: #selector(fileActionDidHappen),
                                               name: FileActionLog.didChange, object: nil)

        applyTheme()
        subscribeToTheme(self)
        reload()
    }
    deinit { NotificationCenter.default.removeObserver(self) }

    /// FileActionLog posts on the main thread.
    @objc private func fileActionDidHappen() { refresh() }

    /// Re-read every open column, keeping the path of single selections open.
    func refresh() {
        guard pane != nil, browser.lastColumn >= 0 else { return }
        var path: [URL] = []
        for c in 0...browser.lastColumn {
            guard let dir = folder(forColumn: c) else { break }
            let rows = browser.selectedRowIndexes(inColumn: c) ?? IndexSet()
            let kids = entries(in: dir)
            guard rows.count == 1, let r = rows.first, kids.indices.contains(r) else { break }
            path.append(kids[r].url)
        }
        entryCache.removeAll()
        browser.loadColumnZero()
        for (c, url) in path.enumerated() {
            guard let dir = folder(forColumn: c) else { break }
            let kids = entries(in: dir)
            guard let r = kids.firstIndex(where: { $0.url == url }) else { break }
            browser.selectRow(r, inColumn: c)
            if kids[r].isDir, browser.lastColumn == c { browser.addColumn() }
        }
        onSelectionChange?(selectedURLs())
    }

    /// Builds the right-click menu once the clicked row is selected.
    var menuProvider: (() -> NSMenu?)?

    /// Finder behaviour: right-clicking a row selects it unless it is already
    /// part of the selection, then shows the item menu.
    private func contextMenu(for event: NSEvent) -> NSMenu? {
        var row = -1, col = -1
        let pt = browser.convert(event.locationInWindow, from: nil)
        if browser.getRow(&row, column: &col, for: pt), row >= 0, col >= 0 {
            let selected = browser.selectedRowIndexes(inColumn: col) ?? IndexSet()
            if browser.selectedColumn != col || !selected.contains(row) {
                browser.selectRow(row, inColumn: col)
                handleSelection()
            }
        }
        return menuProvider?()
    }
    /// Test hook: the menu a right-click on this row shows.
    func testContextMenu(row: Int, column: Int) -> NSMenu? {
        let r = browser.frame(ofRow: row, inColumn: column)
        guard let ev = NSEvent.mouseEvent(with: .rightMouseDown,
                                          location: browser.convert(NSPoint(x: r.midX, y: r.midY), to: nil),
                                          modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 1) else { return nil }
        return contextMenu(for: ev)
    }

    /// The folder of the column holding the selection: where New Folder and
    /// Paste land. The pane's folder when nothing is selected.
    var activeFolder: URL? {
        let col = browser.selectedColumn
        return col >= 0 ? folder(forColumn: col) : pane?.currentURL
    }

    func openSelected() { handleDoubleClick() }

    override func viewDidLayout() {
        super.viewDidLayout()
        browser.frame = view.bounds   // fill the host without participating in its constraints
    }

    @objc func applyTheme() {
        let t = ThemeManager.shared.current
        if t.id == "system" {
            browser.backgroundColor = .controlBackgroundColor
        } else {
            browser.backgroundColor = t.background
        }
    }

    func reload() {
        guard pane != nil else { return }
        entryCache.removeAll()
        browser.loadColumnZero()
    }

    private struct ColEntry { let url: URL; let isDir: Bool }
    /// Per-directory listing cache. NSBrowser calls `entries(in:)` once per
    /// visible cell *and* per row count, so without this the whole directory is
    /// re-read and re-stat-ed on every redraw — and resolving `isDir` once per
    /// entry (not twice per sort comparison) removes an O(n log n) stat storm.
    private var entryCache: [URL: [ColEntry]] = [:]

    private func entries(in url: URL) -> [ColEntry] {
        if let cached = entryCache[url] { return cached }
        // FastDirScan returns name + isDirectory from one lstat per entry —
        // far cheaper than contentsOfDirectory + a resourceValues call per URL.
        let showHidden = pane?.testModel.showHidden ?? false
        let resolved: [ColEntry] = FastDirScan.list(url).compactMap { e in
            if !showHidden && e.isHidden { return nil }
            return ColEntry(url: e.url, isDir: e.isDirectory)
        }
        let sorted = resolved.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
        }
        entryCache[url] = sorted
        return sorted
    }

    /// The folder a column shows: the pane's folder for column 0, else the folder
    /// selected in the column to its left. Read from the browser itself, because
    /// NSBrowser opens the next column on its own when a folder is clicked, before
    /// our action runs; a separate list of column folders went stale there and
    /// showed blank rows and an extra empty column.
    private func folder(forColumn column: Int) -> URL? {
        guard var url = pane?.currentURL else { return nil }
        for c in 0..<column {
            let kids = entries(in: url)
            let row = browser.selectedRow(inColumn: c)
            guard kids.indices.contains(row), kids[row].isDir else { return nil }
            url = kids[row].url
        }
        return url
    }

    // MARK: NSBrowserDelegate

    func browser(_ sender: NSBrowser, numberOfRowsInColumn column: Int) -> Int {
        folder(forColumn: column).map { entries(in: $0).count } ?? 0
    }

    func browser(_ sender: NSBrowser, willDisplayCell cell: Any, atRow row: Int, column: Int) {
        guard let cell = cell as? NSBrowserCell, let url = folder(forColumn: column) else { return }
        let kids = entries(in: url)
        guard kids.indices.contains(row) else { return }
        let kid = kids[row]
        cell.title = kid.url.lastPathComponent
        cell.isLeaf = !kid.isDir
        // A bare NSBrowserCell is just text — give it the file icon + a clean font so
        // the column view reads like a real file browser instead of a plain list.
        cell.font = .systemFont(ofSize: 13)
        cell.image = IconCache.shared.icon(forURL: kid.url, isDirectory: kid.isDir)
    }

    /// Verify hook: drill into the first subfolder of the deepest column (push a column).
    @discardableResult
    func testDrillIntoFirstFolder() -> Bool {
        let col = max(0, browser.lastColumn)
        guard let dir = folder(forColumn: col) else { return false }
        let kids = entries(in: dir)
        guard let row = kids.firstIndex(where: { $0.isDir }) else { return false }
        browser.selectRow(row, inColumn: col)
        handleSelection()
        return true
    }

    /// Test hook: a real mouse click on a row, so NSBrowser runs its own click
    /// handling (which adds the next column by itself) before our action.
    func testClickRow(_ row: Int, inColumn col: Int) {
        guard let win = browser.window, col <= browser.lastColumn else { return }
        browser.scrollColumnToVisible(col)
        let r = browser.frame(ofRow: row, inColumn: col)
        let p = browser.convert(NSPoint(x: r.midX, y: r.midY), to: nil)
        func ev(_ t: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: t, location: p, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: win.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)
        }
        // Straight to the view under the point: an inactive (off-screen test) window
        // would treat a window-level click as "activate" and drop it.
        guard let cv = win.contentView, let hit = cv.hitTest(cv.convert(p, from: nil)),
              let down = ev(.leftMouseDown), let up = ev(.leftMouseUp) else { return }
        NSApp.postEvent(up, atStart: true)   // ends the cell tracking loop
        hit.mouseDown(with: down)
    }

    /// Test hook: what the browser shows, one array of titles per loaded column.
    /// An empty title is a blank row.
    func testVisibleTitles() -> [[String]] {
        guard browser.lastColumn >= 0 else { return [] }
        return (0...browser.lastColumn).map { c in
            var titles: [String] = []
            var row = 0
            while let cell = browser.loadedCell(atRow: row, column: c) as? NSBrowserCell {
                titles.append(cell.title); row += 1
            }
            return titles
        }
    }

    /// Reports the URLs selected in the active (deepest selected) column so the
    /// pane can run file commands (cut/copy/Get Info/…) on the real selection.
    var onSelectionChange: (([URL]) -> Void)?

    /// URLs currently highlighted in the active column (supports multi-select).
    func selectedURLs() -> [URL] {
        let col = browser.selectedColumn
        guard col >= 0, let dir = folder(forColumn: col) else { return [] }
        let kids = entries(in: dir)
        return (browser.selectedRowIndexes(inColumn: col) ?? IndexSet()).compactMap {
            kids.indices.contains($0) ? kids[$0].url : nil
        }
    }

    @objc private func handleSelection() {
        let col = browser.selectedColumn
        guard col >= 0, let dir = folder(forColumn: col) else { onSelectionChange?([]); return }
        let kids = entries(in: dir)
        let selUrls = (browser.selectedRowIndexes(inColumn: col) ?? IndexSet()).compactMap {
            kids.indices.contains($0) ? kids[$0].url : nil
        }
        // A click on a folder already opened its column; a programmatic selectRow
        // (test hooks) does not, so open it only when it is missing.
        let row = browser.selectedRow(inColumn: col)
        if selUrls.count == 1, kids.indices.contains(row), kids[row].isDir, browser.lastColumn == col {
            browser.addColumn()
            browser.scrollColumnToVisible(col + 1)
        }
        onSelectionChange?(selUrls)
    }

    /// Test hook: select row 0 of column 0 and return the resulting selection.
    @discardableResult
    func testSelectFirstRow() -> [URL] {
        guard browser(browser, numberOfRowsInColumn: 0) > 0 else { return [] }
        browser.selectRow(0, inColumn: 0)
        handleSelection()
        return selectedURLs()
    }

    @objc private func handleDoubleClick() {
        let col = browser.selectedColumn
        guard col >= 0, let dir = folder(forColumn: col) else { return }
        let row = browser.selectedRow(inColumn: col)
        guard row >= 0 else { return }
        let kids = entries(in: dir)
        guard kids.indices.contains(row) else { return }
        let sel = kids[row]
        if sel.isDir {
            pane?.navigate(to: sel.url)
        } else {
            NSWorkspace.shared.open(sel.url)
        }
    }
}
