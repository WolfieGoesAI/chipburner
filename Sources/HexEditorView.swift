import Cocoa

/// Editable hex grid: 16 bytes per row, click a byte (or press Return on a selected row) and type
/// one or two hex digits. Return or Tab moves on to the next byte. Undo/Redo work from the Edit menu.
final class HexEditorView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private(set) var buffer = EditableBuffer()
    /// Called after every change to the bytes (edit, fill, undo …).
    var onChange: (() -> Void)?
    /// Bytes to tint, e.g. the last search hit or the go-to address.
    private(set) var highlight: Range<Int>?
    /// Where Find Next continues from.
    var cursor = 0

    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let font = NSFont.userFixedPitchFont(ofSize: 12) ?? .systemFont(ofSize: 12)
    private let perRow = 16
    private var addrDigits = 4

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 18
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.usesAlternatingRowBackgroundColors = true
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.gridStyleMask = []
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        rebuildColumns()

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func rebuildColumns() {
        for c in table.tableColumns { table.removeTableColumn(c) }
        let charW = ("0" as NSString).size(withAttributes: [.font: font]).width
        func add(_ id: String, _ title: String, _ width: CGFloat) {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            c.minWidth = width
            c.headerCell.font = font
            c.headerCell.alignment = id == "ascii" || id == "addr" ? .left : .center
            table.addTableColumn(c)
        }
        add("addr", "Address", charW * CGFloat(addrDigits) + 22)
        for i in 0..<perRow { add("b\(i)", String(format: "%02X", i), charW * 2 + (i % 8 == 7 ? 16 : 10)) }
        add("ascii", "ASCII", charW * CGFloat(perRow) + 16)
    }

    // MARK: Data

    func setData(_ data: Data) {
        buffer = EditableBuffer(data)
        highlight = nil
        cursor = 0
        let digits = BufferOps.addressDigits(for: data.count)
        if digits != addrDigits { addrDigits = digits; rebuildColumns() }
        table.reloadData()
        table.scrollRowToVisible(0)
    }

    var data: Data { buffer.data }

    /// Applies a change made through `mutate` and refreshes the view.
    func edit(_ mutate: (inout EditableBuffer) -> Range<Int>?) {
        let before = buffer.count
        let changed = mutate(&buffer)
        if buffer.count != before {
            let digits = BufferOps.addressDigits(for: buffer.count)
            if digits != addrDigits { addrDigits = digits; rebuildColumns() }
            table.reloadData()
        } else if let r = changed, !r.isEmpty {
            let rows = IndexSet(integersIn: (r.lowerBound / perRow)...((r.upperBound - 1) / perRow))
            table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        }
        if let r = changed, !r.isEmpty { show(r) }
        onChange?()
    }

    /// Scrolls to and tints a range of bytes.
    func show(_ r: Range<Int>) {
        let old = highlight
        highlight = r
        var rows = IndexSet()
        for x in [old, r].compactMap({ $0 }) where !x.isEmpty && x.lowerBound < max(buffer.count, 1) {
            rows.insert(integersIn: (x.lowerBound / perRow)...(max(x.lowerBound, x.upperBound - 1) / perRow))
        }
        let maxRow = table.numberOfRows - 1
        rows = rows.filteredIndexSet { $0 <= maxRow }
        table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        let row = r.lowerBound / perRow
        if row <= maxRow {
            table.scrollRowToVisible(min(maxRow, row + 3))
            table.scrollRowToVisible(row)
        }
    }

    // MARK: Undo

    @objc func undo(_ sender: Any?) { edit { $0.undo() } }
    @objc func redo(_ sender: Any?) { edit { $0.redo() } }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(undo(_:)) { return buffer.canUndo }
        if item.action == #selector(redo(_:)) { return buffer.canRedo }
        return true
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { (buffer.count + perRow - 1) / perRow }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        let field: NSTextField
        if let reused = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier(id), owner: self) as? NSTextField {
            field = reused
        } else {
            field = NSTextField()
            field.identifier = NSUserInterfaceItemIdentifier(id)
            field.isBordered = false
            field.font = font
            field.lineBreakMode = .byClipping
            field.cell?.usesSingleLineMode = true
            field.alignment = id.hasPrefix("b") ? .center : .left
            field.delegate = self
        }
        let base = row * perRow
        field.drawsBackground = false
        field.textColor = .textColor
        switch id {
        case "addr":
            field.isEditable = false
            field.stringValue = String(format: "%0\(addrDigits)X", base)
            field.textColor = .secondaryLabelColor
        case "ascii":
            field.isEditable = false
            var s = ""
            for i in base..<min(base + perRow, buffer.count) {
                let b = buffer[i]
                s.append(b >= 0x20 && b < 0x7F ? Character(UnicodeScalar(b)) : "·")
            }
            field.stringValue = s
            field.textColor = .secondaryLabelColor
        default:
            let i = base + (Int(id.dropFirst()) ?? 0)
            field.tag = i
            if i < buffer.count {
                field.isEditable = true
                field.stringValue = String(format: "%02X", buffer[i])
                if let h = highlight, h.contains(i) {
                    field.drawsBackground = true
                    field.backgroundColor = NSColor.selectedTextBackgroundColor
                }
            } else {
                field.isEditable = false
                field.stringValue = ""
            }
        }
        return field
    }

    @objc private func doubleClicked(_ sender: Any?) {
        let row = table.clickedRow, col = table.clickedColumn
        guard row >= 0, col >= 1, col <= perRow else { return }
        table.editColumn(col, row: row, with: nil, select: true)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let id = field.identifier?.rawValue, id.hasPrefix("b") else { return }
        let i = field.tag
        guard i < buffer.count else { return }
        var t = field.stringValue.trimmingCharacters(in: .whitespaces)
        if t.lowercased().hasPrefix("0x") { t.removeFirst(2) }
        if let v = UInt8(t, radix: 16), t.count <= 2 {
            if v != buffer[i] { edit { $0.replace(i..<(i + 1), with: Data([v])) } }
            cursor = i + 1
        } else {
            NSSound.beep()
        }
        field.stringValue = String(format: "%02X", buffer[i])
        // Return/Tab moves on to the next byte, Shift-Tab back.
        let movement = (obj.userInfo?["NSTextMovement"] as? Int) ?? 0
        let next: Int?
        switch movement {
        case NSTextMovement.return.rawValue, NSTextMovement.tab.rawValue: next = i + 1 < buffer.count ? i + 1 : nil
        case NSTextMovement.backtab.rawValue: next = i > 0 ? i - 1 : nil
        default: next = nil
        }
        if let n = next {
            DispatchQueue.main.async {
                let row = n / self.perRow
                self.table.scrollRowToVisible(row)
                self.table.editColumn(1 + n % self.perRow, row: row, with: nil, select: true)
            }
        }
    }

    /// The first byte of the selected row (or the cursor), as a starting point for dialogs.
    var selectedAddress: Int {
        if let h = highlight { return h.lowerBound }
        return table.selectedRow >= 0 ? table.selectedRow * perRow : 0
    }
}
