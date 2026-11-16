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
            reloadPreview()
        }
    }

    private static let folderSizeQueue = DispatchQueue(label: "FinderTwo.previewSize", qos: .utility)

    private func showDetails() {
        while details.numberOfRows > 0 { details.removeRow(at: 0) }
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
        qlHost.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(qlHost)

        nameLabel.font = .boldSystemFont(ofSize: 12)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(nameLabel)

        details.translatesAutoresizingMaskIntoConstraints = false
        details.rowSpacing = 4
        details.columnSpacing = 8
        content.addSubview(details)

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

            qlHost.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            qlHost.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            qlHost.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),

            nameLabel.topAnchor.constraint(equalTo: qlHost.bottomAnchor, constant: 8),
            nameLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),

            details.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 8),
            details.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            details.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -10),
            details.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
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

    @objc func applyTheme() {
        let t = ThemeManager.shared.current
        layer?.backgroundColor = (t.id == "system" ? NSColor.windowBackgroundColor : t.background).cgColor
        nameLabel.textColor = primaryColor
        showDetails()   // re-colour the detail rows
    }

    // MARK: - Test hooks
    var testQLHostSize: NSSize { qlHost.bounds.size }
    var testHasLiveQLView: Bool { ql != nil }
    /// "Key: value" for each detail row.
    var testDetails: [String] {
        (0..<details.numberOfRows).compactMap { r in
            guard let k = details.cell(atColumnIndex: 0, rowIndex: r).contentView as? NSTextField,
                  let v = details.cell(atColumnIndex: 1, rowIndex: r).contentView as? NSTextField else { return nil }
            return "\(k.stringValue): \(v.stringValue)"
        }
    }
}
