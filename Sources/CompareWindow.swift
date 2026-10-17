import Cocoa

/// Lists the differences between the buffer and another image (a file or a chip that was read).
/// Differing bytes are tinted orange in the hex editor; selecting a row (or Previous/Next) jumps
/// there. "Use Other's Bytes" copies the other image's bytes for the selected places into the buffer.
final class CompareWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    /// Supplied by the main window.
    struct Hooks {
        var buffer: () -> Data
        var select: (Range<Int>) -> Void
        var mark: (IndexSet) -> Void
        var replace: (Range<Int>, Data) -> Void
    }

    let otherName: String
    private let other: Data
    private let hooks: Hooks
    private var result = BufferDiff.Result()
    private var retainSelf: CompareWindowController?

    private let summary = NSTextField(wrappingLabelWithString: "")
    private let table = NSTableView()
    private let mergeBox = NSButton(checkboxWithTitle: "Join differences less than 16 bytes apart", target: nil, action: nil)
    private var prevButton: NSButton!
    private var nextButton: NSButton!
    private var useButton: NSButton!
    var onClose: (() -> Void)?

    init(otherName: String, other: Data, hooks: Hooks) {
        self.otherName = otherName
        self.other = other
        self.hooks = hooks
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 460),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Compare with \(otherName)"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 480, height: 300)
        super.init(window: w)
        buildUI()
        refresh()
        retainSelf = self
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            self?.hooks.mark(IndexSet())
            self?.onClose?()
            self?.retainSelf = nil
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        summary.font = .systemFont(ofSize: NSFont.systemFontSize)
        mergeBox.target = self
        mergeBox.action = #selector(mergeChanged(_:))
        mergeBox.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let mono = NSFont.userFixedPitchFont(ofSize: 11) ?? .systemFont(ofSize: 11)
        for (id, title, width) in [("addr", "Address", 90.0), ("len", "Bytes", 60.0), ("buf", "Buffer", 190.0), ("oth", "Other", 190.0)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = CGFloat(width)
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 17
        table.font = mono
        table.target = self
        table.action = #selector(rowClicked(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        func b(_ t: String, _ s: Selector) -> NSButton {
            let x = NSButton(title: t, target: self, action: s)
            x.bezelStyle = .rounded
            return x
        }
        prevButton = b("◀ Previous", #selector(previous(_:)))
        nextButton = b("Next ▶", #selector(next(_:)))
        useButton = b("Use Other's Bytes", #selector(useOther(_:)))
        useButton.toolTip = "Copy the other image's bytes for the selected places into the buffer (can be undone)."
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .horizontal)
        let buttons = NSStackView(views: [prevButton, nextButton, spacer, b("Copy Report", #selector(copyReport(_:))), useButton])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [summary, mergeBox, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        for v in [summary, scroll, buttons] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
    }

    // MARK: Data

    /// Recomputes the differences (called after every buffer edit, too).
    func refresh() {
        let buf = hooks.buffer()
        result = BufferDiff.compare(buf, other, mergeGap: mergeBox.state == .on ? 16 : 0)
        hooks.mark(result.indexSet)
        let digits = BufferOps.addressDigits(for: max(buf.count, other.count))
        func size(_ n: Int) -> String { String(format: "%d (0x%X) bytes", n, n) }
        var text: String
        if result.identical {
            text = "✓ Identical – the buffer and \(otherName) have the same \(size(buf.count))."
        } else if result.runs.isEmpty {
            text = "The common part is identical, but the sizes differ."
        } else {
            text = "\(result.differingBytes) byte\(result.differingBytes == 1 ? "" : "s") differ in \(result.runs.count) place\(result.runs.count == 1 ? "" : "s") (tinted orange in the hex editor)."
        }
        if result.sizeA != result.sizeB {
            text += String(format: "\nSizes differ: buffer %@, %@ %@ – the bytes after 0x%0\(digits)X are only in the %@.",
                           size(result.sizeA), otherName, size(result.sizeB), min(result.sizeA, result.sizeB),
                           result.sizeA > result.sizeB ? "buffer" : "other image")
        }
        summary.stringValue = text
        summary.textColor = result.identical ? .systemGreen : .labelColor
        table.reloadData()
        updateButtons()
    }

    private func updateButtons() {
        let has = !result.runs.isEmpty
        prevButton.isEnabled = has
        nextButton.isEnabled = has
        useButton.isEnabled = !table.selectedRowIndexes.isEmpty
    }

    func numberOfRows(in tableView: NSTableView) -> Int { result.runs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, row < result.runs.count else { return nil }
        let id = col.identifier
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let t = NSTextField(labelWithString: "")
            t.identifier = id
            t.font = NSFont.userFixedPitchFont(ofSize: 11)
            t.lineBreakMode = .byTruncatingTail
            return t
        }()
        let r = result.runs[row]
        let buf = hooks.buffer()
        let digits = BufferOps.addressDigits(for: max(buf.count, other.count))
        func bytes(_ d: Data) -> String {
            let n = min(r.count, 8)
            var s = (0..<n).map { i -> String in
                let k = r.start + i
                return k < d.count ? String(format: "%02X", d[d.startIndex + k]) : "--"
            }.joined(separator: " ")
            if r.count > n { s += " …" }
            return s
        }
        switch id.rawValue {
        case "addr": cell.stringValue = String(format: "%0\(digits)X", r.start)
        case "len": cell.stringValue = "\(r.count)"
        case "buf": cell.stringValue = bytes(buf)
        default: cell.stringValue = bytes(other)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    // MARK: Actions

    @objc private func rowClicked(_ sender: Any?) {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < result.runs.count else { return }
        hooks.select(result.runs[row].range)
    }

    private func go(_ delta: Int) {
        guard !result.runs.isEmpty else { return }
        var row = table.selectedRow
        row = row < 0 ? (delta > 0 ? 0 : result.runs.count - 1) : (row + delta + result.runs.count) % result.runs.count
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        hooks.select(result.runs[row].range)
    }

    @objc private func previous(_ sender: Any?) { go(-1) }
    @objc private func next(_ sender: Any?) { go(1) }

    @objc private func mergeChanged(_ sender: Any?) { refresh() }

    @objc private func useOther(_ sender: Any?) {
        let rows = table.selectedRowIndexes.filter { $0 < result.runs.count }
        guard !rows.isEmpty else { return }
        // Last to first, so earlier ranges keep their positions.
        for row in rows.sorted(by: >) {
            let r = result.runs[row].range
            let end = min(r.upperBound, other.count)
            guard end > r.lowerBound else { continue }
            hooks.replace(r.lowerBound..<end, other.subdata(in: (other.startIndex + r.lowerBound)..<(other.startIndex + end)))
        }
        refresh()
    }

    @objc private func copyReport(_ sender: Any?) {
        let buf = hooks.buffer()
        let digits = BufferOps.addressDigits(for: max(buf.count, other.count))
        var lines = ["Compare: buffer (\(buf.count) bytes) vs \(otherName) (\(other.count) bytes)",
                     "\(result.differingBytes) bytes differ in \(result.runs.count) places", ""]
        for r in result.runs {
            for k in r.range {
                let a = k < buf.count ? buf[buf.startIndex + k] : 0, b = k < other.count ? other[other.startIndex + k] : 0
                if a != b { lines.append(String(format: "%0\(digits)X: %02X -> %02X", k, a, b)) }
            }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n") + "\n", forType: .string)
    }
}
