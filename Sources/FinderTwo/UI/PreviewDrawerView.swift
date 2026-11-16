import AppKit
import Quartz

/// Right-side preview panel (View ▸ Show Preview): a live Quick Look render of
/// the selected item, its name, and details (kind, size, dimensions, dates, where).
/// The content keeps a fixed width and is clipped while the panel slides, so
/// Quick Look always builds against a real, non-zero frame.
///
/// The QLPreviewView is **recreated for every item** rather than reused. Swapping
/// `previewItem` on a live QLPreviewView trips its internal KVO
/// ("…displayedDisplayBundle… without an appropriate KVO notification…") and its
/// overlay scroller (`-[NSScrollerImp setKnobProportion:]` asserts
/// `isfinite(newKnobProportion)`), which crashes the app when previewing
/// scrollable content like PDFs. A fresh view per item — added only once the host
/// has a real, non-zero size — avoids both failure modes.
final class PreviewDrawerView: NSView, ThemeObserving {

    private let content = NSView()
    private let block = NSView()
    /// Fades the whole panel out toward its top and bottom edges: solid behind
    /// the preview and its text, fully transparent at the very top and bottom.
    private let fade = CAGradientLayer()
    private lazy var blockCentre: NSLayoutConstraint = {
        let c = block.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        c.priority = .defaultHigh
        return c
    }()
    private let qlHost = NSView()
    private var ql: QLPreviewView?
    private let nameLabel = NSTextField(labelWithString: "")
    private let details = NSGridView()
    private var contentWidthConstraint: NSLayoutConstraint!

    /// Width the content lays out at, whatever the panel's current width.
    var contentWidth: CGFloat {
        get { contentWidthConstraint.constant }
        set { contentWidthConstraint.constant = newValue }
    }

    var url: URL? {
        didSet {
            nameLabel.stringValue = url?.lastPathComponent ?? "No selection"
            showDetails()
            fitPreviewShape()
            reloadPreview()
        }
    }

    /// The preview is as tall as the item needs: an image's own shape (within
    /// limits), a rough page shape for documents, a smaller box for folders.
    private var previewShape: NSLayoutConstraint?
    private func fitPreviewShape() {
        var ratio: CGFloat = 0.75   // height / width
        if let url {
            if let px = PreviewDrawerView.pixelSize(of: url), px.width > 0 {
                ratio = CGFloat(px.height) / CGFloat(px.width)
            } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                ratio = 0.6
            } else if ["pdf", "doc", "docx", "pages", "txt", "md", "rtf"].contains(url.pathExtension.lowercased()) {
                ratio = 1.3
            }
        }
        previewShape?.isActive = false
        let c = qlHost.heightAnchor.constraint(equalTo: qlHost.widthAnchor, multiplier: min(1.6, max(0.3, ratio)))
        c.priority = NSLayoutConstraint.Priority(740)   // gives way when the panel is too short
        c.isActive = true
        previewShape = c
    }

    private static let folderSizeQueue = DispatchQueue(label: "FinderTwo.previewSize", qos: .utility)

    private func showDetails() {
        // removeRow keeps the row's labels on screen: take them out first, or each
        // selection draws its details over the previous ones.
        while details.numberOfRows > 0 {
            let row = details.row(at: 0)
            for c in 0..<row.numberOfCells { row.cell(at: c).contentView?.removeFromSuperview() }
            details.removeRow(at: 0)
        }
        guard let url else { return }
        let rv = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .isPackageKey,
                                                   .localizedTypeDescriptionKey,
                                                   .creationDateKey, .contentModificationDateKey])
        let isFolder = rv?.isDirectory == true && rv?.isPackage != true
        var rows: [(String, String)] = [("Kind", isFolder ? "Folder" : (rv?.localizedTypeDescription ?? "—"))]
        rows.append(("Size", isFolder ? "…" : SizeFormatter.string(Int64(rv?.fileSize ?? 0))))
        if let px = PreviewDrawerView.pixelSize(of: url) { rows.append(("Dimensions", "\(px.width) × \(px.height)")) }
        if let d = rv?.creationDate { rows.append(("Created", DateFormatterCache.string(d))) }
        if let d = rv?.contentModificationDate { rows.append(("Modified", DateFormatterCache.string(d))) }
        rows.append(("Where", (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath))
        for (key, value) in rows {
            let k = NSTextField(labelWithString: key)
            k.font = .systemFont(ofSize: 11)
            k.textColor = secondaryColor
            k.alignment = .right
            let v = NSTextField(labelWithString: value)
            v.font = .systemFont(ofSize: 11)
            v.textColor = primaryColor
            v.lineBreakMode = .byTruncatingMiddle
            v.isSelectable = true
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            details.addRow(with: [k, v])
        }
        if isFolder {   // a folder's size means walking it: do that off the main thread
            Self.folderSizeQueue.async { [weak self] in
                let bytes = FileListController.recursiveSize(url) { self?.url != url }
                DispatchQueue.main.async {
                    guard let self, self.url == url, self.details.numberOfRows > 1,
                          let v = self.details.cell(atColumnIndex: 1, rowIndex: 1).contentView as? NSTextField
                    else { return }
                    v.stringValue = SizeFormatter.string(bytes)
                }
            }
        }
    }

    /// Pixel size of an image file, read from its header (no full decode).
    static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    private var primaryColor: NSColor {
        let t = ThemeManager.shared.current
        return t.id == "system" ? .labelColor : t.labelPrimary
    }
    private var secondaryColor: NSColor {
        let t = ThemeManager.shared.current
        return t.id == "system" ? .secondaryLabelColor : t.labelSecondary
    }

    /// Tear down the previous QLPreviewView and build a fresh one for the current
    /// URL — but only once the host actually has a non-zero frame.
    private func reloadPreview() {
        ql?.close()
        ql?.removeFromSuperview()
        ql = nil

        guard let url else { return }
        layoutSubtreeIfNeeded()
        guard qlHost.bounds.width >= 1, qlHost.bounds.height >= 1 else { return }

        guard let v = QLPreviewView(frame: qlHost.bounds, style: .normal) else { return }
        v.autostarts = true
        v.translatesAutoresizingMaskIntoConstraints = false
        qlHost.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: qlHost.topAnchor),
            v.leadingAnchor.constraint(equalTo: qlHost.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: qlHost.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: qlHost.bottomAnchor),
        ])
        layoutSubtreeIfNeeded()          // give it a real frame before QuickLook loads
        v.previewItem = url as NSURL
        ql = v
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true   // clip the fixed-width content while sliding
        let line = NSBox(frame: NSRect(x: 0, y: 0, width: 1, height: 100))
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        block.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(block)
        fade.startPoint = CGPoint(x: 0.5, y: 0)   // layer y runs bottom to top
        fade.endPoint = CGPoint(x: 0.5, y: 1)
        fade.colors = [NSColor.black.withAlphaComponent(0).cgColor, NSColor.black.cgColor,
                       NSColor.black.cgColor, NSColor.black.withAlphaComponent(0).cgColor]
        layer?.mask = fade
        qlHost.translatesAutoresizingMaskIntoConstraints = false
        block.addSubview(qlHost)

        nameLabel.font = .boldSystemFont(ofSize: 12)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        block.addSubview(nameLabel)

        details.translatesAutoresizingMaskIntoConstraints = false
        details.rowSpacing = 4
        details.columnSpacing = 8
        block.addSubview(details)

        contentWidthConstraint = content.widthAnchor.constraint(equalToConstant: LayoutMetrics.value(.previewPaneWidth))
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: topAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.widthAnchor.constraint(equalToConstant: 1),

            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentWidthConstraint,

            // The preview and its text form one block, centred top to bottom;
            // the panel fades out above and below it (see `fade`).
            block.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            block.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            block.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: 12),
            block.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -12),
            blockCentre,

            qlHost.topAnchor.constraint(equalTo: block.topAnchor),
            qlHost.leadingAnchor.constraint(equalTo: block.leadingAnchor, constant: 12),
            qlHost.trailingAnchor.constraint(equalTo: block.trailingAnchor, constant: -12),

            nameLabel.topAnchor.constraint(equalTo: qlHost.bottomAnchor, constant: 10),
            nameLabel.leadingAnchor.constraint(equalTo: block.leadingAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(equalTo: block.trailingAnchor, constant: -10),

            details.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 8),
            details.centerXAnchor.constraint(equalTo: block.centerXAnchor),
            details.leadingAnchor.constraint(greaterThanOrEqualTo: block.leadingAnchor, constant: 10),
            details.trailingAnchor.constraint(lessThanOrEqualTo: block.trailingAnchor, constant: -10),
            details.bottomAnchor.constraint(equalTo: block.bottomAnchor),
        ])
        fitPreviewShape()
        // Guarantee the QuickLook host keeps a real height even when the pane is
        // short (e.g. the bottom terminal drawer is open) — otherwise the label
        // chain can squeeze qlHost to zero and reloadPreview()'s size guard drops
        // the view. High (not required) priority so it yields if the window is
        // genuinely too small.
        let qlHostMinHeight = qlHost.heightAnchor.constraint(greaterThanOrEqualToConstant: 80)
        qlHostMinHeight.priority = .defaultHigh
        qlHostMinHeight.isActive = true
        subscribeToTheme(self)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Keep the solid part of the fade behind the block, with a little margin.
    override func layout() {
        super.layout()
        let h = bounds.height
        guard h > 0 else { return }
        let b = block.convert(block.bounds, to: self)
        let margin: CGFloat = 16
        let low = max(0, min(1, (b.minY - margin) / h))
        let high = max(low, min(1, (b.maxY + margin) / h))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fade.frame = bounds
        fade.locations = [0, NSNumber(value: Double(low)), NSNumber(value: Double(high)), 1]
        CATransaction.commit()
    }

    @objc func applyTheme() {
        let t = ThemeManager.shared.current
        layer?.backgroundColor = (t.id == "system" ? NSColor.windowBackgroundColor : t.background).cgColor
        nameLabel.textColor = primaryColor
        showDetails()   // re-colour the detail rows
    }

    // MARK: - Test hooks
    var testQLHostSize: NSSize { qlHost.bounds.size }
    var testHasLiveQLView: Bool { ql != nil }
    /// Labels left over from earlier selections (should be 0).
    var testStrayDetailViews: Int { details.subviews.count - 2 * details.numberOfRows }
    var testPreviewFrame: NSRect { qlHost.convert(qlHost.bounds, to: self) }
    var testBlockFrame: NSRect { block.convert(block.bounds, to: self) }
    /// (location, alpha) for each stop of the fade, bottom to top.
    var testFadeStops: [(CGFloat, CGFloat)] {
        let alphas = (fade.colors as? [CGColor] ?? []).map { $0.alpha }
        let locs = (fade.locations ?? []).map { CGFloat($0.doubleValue) }
        return Array(zip(locs, alphas))
    }
    /// "Key: value" for each detail row.
    var testDetails: [String] {
        (0..<details.numberOfRows).compactMap { r in
            guard let k = details.cell(atColumnIndex: 0, rowIndex: r).contentView as? NSTextField,
                  let v = details.cell(atColumnIndex: 1, rowIndex: r).contentView as? NSTextField else { return nil }
            return "\(k.stringValue): \(v.stringValue)"
        }
    }
}
