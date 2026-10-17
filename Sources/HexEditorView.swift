import Cocoa

/// Hex editor: address, 16 hex bytes and ASCII per row.
/// Click to place the cursor, drag (or Shift-click / Shift-arrows) to select a range, type hex digits
/// in the hex column or characters in the ASCII column (Tab switches). Copy/Cut/Paste work on bytes;
/// Paste overwrites, Paste Inserting inserts; Delete/Backspace remove bytes. Undo/Redo via the Edit menu.
final class HexEditorView: NSView {
    private(set) var buffer = EditableBuffer()
    /// Called after every change to the bytes.
    var onChange: (() -> Void)?
    /// Called when the cursor or selection moves (for the status text).
    var onSelectionChange: (() -> Void)?

    /// Bytes tinted as a search hit / go-to target.
    private(set) var highlight: Range<Int>?
    /// Where Find Next continues from.
    var cursor: Int {
        get { grid.cursor }
        set { grid.cursor = max(0, min(newValue, max(0, buffer.count - 1))); grid.anchor = grid.cursor; grid.needsDisplay = true }
    }

    fileprivate let grid = HexGridView()
    private let header = HexHeaderView()
    private let scroll = NSScrollView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        grid.owner = self
        header.grid = grid
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        for v in [header, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.heightAnchor.constraint(equalToConstant: grid.rowH + 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Data

    func setData(_ data: Data) {
        buffer = EditableBuffer(data)
        highlight = nil
        grid.cursor = 0; grid.anchor = 0; grid.selection = nil; grid.nibble = 0
        grid.relayout()
        grid.scroll(.zero)
        header.needsDisplay = true
        onSelectionChange?()
    }

    var data: Data { buffer.data }

    /// The selected bytes, if any.
    var selection: Range<Int>? { grid.selection }

    /// Applies a change through `mutate` and refreshes the view.
    func edit(_ mutate: (inout EditableBuffer) -> Range<Int>?) {
        let before = buffer.count
        let changed = mutate(&buffer)
        if buffer.count != before { grid.relayout(); header.needsDisplay = true }
        grid.clampCursor()
        grid.needsDisplay = true
        if let r = changed, !r.isEmpty { show(r) }
        onChange?()
        onSelectionChange?()
    }

    /// Scrolls to and tints a range of bytes.
    func show(_ r: Range<Int>) {
        highlight = r
        grid.scrollToByte(r.lowerBound)
        grid.needsDisplay = true
    }

    /// Selects a range and moves the cursor to its start.
    func select(_ r: Range<Int>) {
        grid.selection = r.isEmpty ? nil : r
        grid.anchor = r.lowerBound
        grid.cursor = max(0, min(r.lowerBound, max(0, buffer.count - 1)))
        grid.scrollToByte(r.lowerBound)
        grid.needsDisplay = true
        onSelectionChange?()
    }

    /// The selection start, or the cursor – the natural starting point for dialogs.
    var selectedAddress: Int { grid.selection?.lowerBound ?? grid.cursor }

    func focus() { window?.makeFirstResponder(grid) }

    /// Inserts bytes at the cursor (replacing the selection, if any).
    func insert(_ bytes: Data) {
        let r = grid.selection ?? grid.cursor..<grid.cursor
        let at = min(r.lowerBound, buffer.count)
        edit { $0.replace(at..<min(r.upperBound, $0.count), with: bytes) }
        grid.selection = bytes.isEmpty ? nil : at..<(at + bytes.count)
        grid.cursor = min(at, max(0, buffer.count - 1)); grid.anchor = grid.cursor
        grid.needsDisplay = true
        onSelectionChange?()
    }

    // MARK: Undo

    @objc func undo(_ sender: Any?) { edit { $0.undo() } }
    @objc func redo(_ sender: Any?) { edit { $0.redo() } }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(undo(_:)) { return buffer.canUndo }
        if item.action == #selector(redo(_:)) { return buffer.canRedo }
        return true
    }
}

/// Column titles above the grid.
private final class HexHeaderView: NSView {
    weak var grid: HexGridView?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        guard let g = grid else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: g.font, .foregroundColor: NSColor.secondaryLabelColor]
        ("Address" as NSString).draw(at: NSPoint(x: g.addrX + 2, y: 2), withAttributes: attrs)
        for i in 0..<16 {
            (String(format: "%02X", i) as NSString).draw(at: NSPoint(x: g.hexX(i) + 2, y: 2), withAttributes: attrs)
        }
        ("ASCII" as NSString).draw(at: NSPoint(x: g.asciiX + 2, y: 2), withAttributes: attrs)
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

/// The grid itself: drawing, mouse selection and keyboard editing.
fileprivate final class HexGridView: NSView {
    weak var owner: HexEditorView?
    let font = NSFont.userFixedPitchFont(ofSize: 12) ?? .systemFont(ofSize: 12)
    let rowH: CGFloat = 18
    lazy var charW: CGFloat = ("0" as NSString).size(withAttributes: [.font: font]).width

    var cursor = 0
    var anchor = 0
    var selection: Range<Int>?
    var nibble = 0                 // 0 = next hex digit is the high nibble
    var asciiPane = false
    private static let hexStrings: [NSString] = (0..<256).map { String(format: "%02X", $0) as NSString }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    private var count: Int { owner?.buffer.count ?? 0 }
    private var rows: Int { (count + 15) / 16 }
    private var digits: Int { BufferOps.addressDigits(for: count) }

    let addrX: CGFloat = 8
    var hexStart: CGFloat { addrX + CGFloat(max(digits + 2, 9)) * charW }   // room for the "Address" heading
    func hexX(_ i: Int) -> CGFloat { hexStart + CGFloat(i * 3) * charW + (i >= 8 ? charW : 0) }
    var asciiX: CGFloat { hexX(15) + 4 * charW }

    func relayout() {
        let width = asciiX + 16 * charW + 16
        setFrameSize(NSSize(width: max(width, superview?.bounds.width ?? width), height: max(CGFloat(max(rows, 1)) * rowH, superview?.bounds.height ?? 0)))
        needsDisplay = true
    }

    func clampCursor() {
        cursor = max(0, min(cursor, max(0, count - 1)))
        anchor = max(0, min(anchor, max(0, count - 1)))
        if let s = selection {
            let c = s.clamped(to: 0..<count)
            selection = c.isEmpty ? nil : c
        }
    }

    func scrollToByte(_ i: Int) {
        let r = NSRect(x: 0, y: CGFloat(i / 16) * rowH - rowH * 2, width: 10, height: rowH * 5)
        scrollToVisible(r)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        guard let owner = owner, count > 0 else {
            let s = "Empty buffer – open a file, read a chip or use New…" as NSString
            s.draw(at: NSPoint(x: 12, y: 8), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
            return
        }
        let buf = owner.buffer
        let first = max(0, Int(dirtyRect.minY / rowH)), last = min(rows - 1, Int(dirtyRect.maxY / rowH))
        guard first <= last else { return }
        let textAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]
        let dimAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let focused = window?.firstResponder === self
        let selColor = focused ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor
        let hiColor = NSColor.findHighlightColor.withAlphaComponent(0.6)
        let alt = NSColor.controlAlternatingRowBackgroundColors.count > 1 ? NSColor.controlAlternatingRowBackgroundColors[1] : NSColor.textBackgroundColor
        for row in first...last {
            let y = CGFloat(row) * rowH
            if row % 2 == 1 { alt.setFill(); NSRect(x: dirtyRect.minX, y: y, width: dirtyRect.width, height: rowH).fill() }
            (String(format: "%0\(digits)X", row * 16) as NSString).draw(at: NSPoint(x: addrX, y: y + 1), withAttributes: dimAttrs)
            var ascii = ""
            for i in 0..<16 {
                let idx = row * 16 + i
                guard idx < count else { break }
                let v = buf[idx]
                let hexRect = NSRect(x: hexX(i) - 2, y: y, width: charW * 2 + 4, height: rowH)
                let ascRect = NSRect(x: asciiX + CGFloat(i) * charW, y: y, width: charW, height: rowH)
                if let s = selection, s.contains(idx) {
                    selColor.setFill(); hexRect.fill(); ascRect.fill()
                } else if let h = owner.highlight, h.contains(idx) {
                    hiColor.setFill(); hexRect.fill(); ascRect.fill()
                }
                if idx == cursor {
                    let active = asciiPane ? ascRect : hexRect
                    let other = asciiPane ? hexRect : ascRect
                    (focused ? NSColor.keyboardFocusIndicatorColor : NSColor.secondaryLabelColor).withAlphaComponent(0.35).setFill()
                    active.fill()
                    NSColor.secondaryLabelColor.withAlphaComponent(0.6).setStroke()
                    NSBezierPath(rect: other.insetBy(dx: 0.5, dy: 0.5)).stroke()
                    if !asciiPane && nibble == 1 && focused {
                        NSColor.keyboardFocusIndicatorColor.setFill()
                        NSRect(x: hexX(i) + charW, y: y + rowH - 3, width: charW, height: 2).fill()
                    }
                }
                Self.hexStrings[Int(v)].draw(at: NSPoint(x: hexX(i), y: y + 1), withAttributes: textAttrs)
                ascii.append(v >= 0x20 && v < 0x7F ? Character(UnicodeScalar(v)) : "·")
            }
            (ascii as NSString).draw(at: NSPoint(x: asciiX, y: y + 1), withAttributes: dimAttrs)
        }
    }

    // MARK: Mouse

    private func hit(_ p: NSPoint) -> (index: Int, ascii: Bool, nibble: Int) {
        let row = max(0, Int(p.y / rowH))
        if p.x >= asciiX - charW / 2 {
            let i = max(0, min(15, Int((p.x - asciiX) / charW)))
            return (min(row * 16 + i, max(0, count - 1)), true, 0)
        }
        var col = 0, nib = 0
        for i in 0..<16 {
            if p.x >= hexX(i) - charW / 2 { col = i; nib = p.x >= hexX(i) + charW ? 1 : 0 }
        }
        return (min(row * 16 + col, max(0, count - 1)), false, nib)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard count > 0 else { return }
        let h = hit(convert(event.locationInWindow, from: nil))
        asciiPane = h.ascii
        if event.modifierFlags.contains(.shift) {
            extend(to: h.index)
        } else if event.clickCount == 2 {
            selection = h.index..<(h.index + 1); cursor = h.index; anchor = h.index
        } else {
            cursor = h.index; anchor = h.index; selection = nil; nibble = 0
        }
        needsDisplay = true
        owner?.onSelectionChange?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard count > 0 else { return }
        autoscroll(with: event)
        let h = hit(convert(event.locationInWindow, from: nil))
        extend(to: h.index)
        needsDisplay = true
        owner?.onSelectionChange?()
    }

    private func extend(to i: Int) {
        selection = min(anchor, i)..<(max(anchor, i) + 1)
        cursor = i
        nibble = 0
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        m.addItem(withTitle: "Cut", action: #selector(cut(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Copy as Hex Text", action: #selector(copyAsHex(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Paste (overwrite)", action: #selector(paste(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Paste Inserting", action: #selector(pasteInserting(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Delete Bytes", action: #selector(delete(_:)), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Insert Bytes…", action: #selector(MainWindowController.insertBytes(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Fill…", action: #selector(MainWindowController.fillBufferRange(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Checksum…", action: #selector(MainWindowController.checksumBufferRange(_:)), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        return m
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) { interpretKeyEvents([event]) }

    private func moveCursor(to i: Int, extending: Bool) {
        guard count > 0 else { return }
        let n = max(0, min(i, count - 1))
        if extending { extend(to: n) } else { cursor = n; anchor = n; selection = nil; nibble = 0 }
        scrollToByte(cursor)
        needsDisplay = true
        owner?.onSelectionChange?()
    }

    private var pageRows: Int { max(1, Int((enclosingScrollView?.contentView.bounds.height ?? 300) / rowH) - 1) }

    override func moveLeft(_ sender: Any?) { moveCursor(to: cursor - 1, extending: false) }
    override func moveRight(_ sender: Any?) { moveCursor(to: cursor + 1, extending: false) }
    override func moveUp(_ sender: Any?) { moveCursor(to: cursor - 16, extending: false) }
    override func moveDown(_ sender: Any?) { moveCursor(to: cursor + 16, extending: false) }
    override func moveLeftAndModifySelection(_ sender: Any?) { moveCursor(to: cursor - 1, extending: true) }
    override func moveRightAndModifySelection(_ sender: Any?) { moveCursor(to: cursor + 1, extending: true) }
    override func moveUpAndModifySelection(_ sender: Any?) { moveCursor(to: cursor - 16, extending: true) }
    override func moveDownAndModifySelection(_ sender: Any?) { moveCursor(to: cursor + 16, extending: true) }
    override func moveToBeginningOfLine(_ sender: Any?) { moveCursor(to: cursor - cursor % 16, extending: false) }
    override func moveToEndOfLine(_ sender: Any?) { moveCursor(to: cursor - cursor % 16 + 15, extending: false) }
    override func moveToBeginningOfDocument(_ sender: Any?) { moveCursor(to: 0, extending: false) }
    override func moveToEndOfDocument(_ sender: Any?) { moveCursor(to: count - 1, extending: false) }
    override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) { moveCursor(to: 0, extending: true) }
    override func moveToEndOfDocumentAndModifySelection(_ sender: Any?) { moveCursor(to: count - 1, extending: true) }
    override func pageDown(_ sender: Any?) { moveCursor(to: cursor + 16 * pageRows, extending: false) }
    override func pageUp(_ sender: Any?) { moveCursor(to: cursor - 16 * pageRows, extending: false) }
    override func scrollPageDown(_ sender: Any?) { pageDown(sender) }
    override func scrollPageUp(_ sender: Any?) { pageUp(sender) }
    override func insertTab(_ sender: Any?) { asciiPane.toggle(); nibble = 0; needsDisplay = true }
    override func insertBacktab(_ sender: Any?) { insertTab(sender) }
    override func cancelOperation(_ sender: Any?) { selection = nil; nibble = 0; needsDisplay = true; owner?.onSelectionChange?() }

    override func insertText(_ insertString: Any) {
        guard let owner = owner, count > 0 else { NSSound.beep(); return }
        let s = (insertString as? String) ?? (insertString as? NSAttributedString)?.string ?? ""
        if let sel = selection { cursor = sel.lowerBound; anchor = cursor; selection = nil; nibble = 0 }
        for ch in s {
            guard cursor < count else { NSSound.beep(); break }
            if asciiPane {
                guard let a = ch.asciiValue else { NSSound.beep(); continue }
                let at = cursor
                owner.edit { $0.replace(at..<(at + 1), with: Data([a])) }
                cursor = min(cursor + 1, count - 1)
                if at == count - 1 { break }
            } else {
                guard let d = ch.hexDigitValue else { NSSound.beep(); continue }
                let at = cursor
                let old = owner.buffer[at]
                let new = nibble == 0 ? UInt8(d << 4) | (old & 0x0F) : (old & 0xF0) | UInt8(d)
                owner.edit { $0.replace(at..<(at + 1), with: Data([new])) }
                if nibble == 0 { nibble = 1 } else { nibble = 0; if cursor < count - 1 { cursor += 1 } }
            }
        }
        anchor = cursor
        scrollToByte(cursor)
        needsDisplay = true
        owner.onSelectionChange?()
    }

    override func deleteBackward(_ sender: Any?) {
        guard let owner = owner, count > 0 else { return }
        if let s = selection { removeBytes(s); return }
        guard cursor > 0 else { NSSound.beep(); return }
        let at = cursor - 1
        owner.edit { $0.replace(at..<(at + 1), with: Data()); return nil }
        moveCursor(to: at, extending: false)
    }

    override func deleteForward(_ sender: Any?) {
        guard count > 0 else { return }
        removeBytes(selection ?? cursor..<(cursor + 1))
    }

    private func removeBytes(_ r: Range<Int>) {
        guard let owner = owner else { return }
        owner.edit { $0.replace(r, with: Data()); return nil }
        selection = nil
        moveCursor(to: r.lowerBound, extending: false)
    }

    // MARK: Pasteboard

    static let bytesType = NSPasteboard.PasteboardType("se.chipburner.bytes")

    private var copyRange: Range<Int>? { selection ?? (count > 0 ? cursor..<(cursor + 1) : nil) }

    @objc func copy(_ sender: Any?) {
        guard let owner = owner, let r = copyRange else { return }
        let bytes = owner.buffer.data.subdata(in: r)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([Self.bytesType, .string], owner: nil)
        pb.setData(bytes, forType: Self.bytesType)
        if asciiPane {
            pb.setString(String(bytes.map { $0 >= 0x20 && $0 < 0x7F ? Character(UnicodeScalar($0)) : "." }), forType: .string)
        } else {
            pb.setString(bytes.map { String(format: "%02X", $0) }.joined(separator: " "), forType: .string)
        }
    }

    @objc func copyAsHex(_ sender: Any?) {
        let was = asciiPane
        asciiPane = false
        copy(sender)
        asciiPane = was
    }

    @objc func cut(_ sender: Any?) {
        guard let r = copyRange else { return }
        copy(sender)
        removeBytes(r)
    }

    /// Bytes on the pasteboard: ChipBurner's own bytes, hex text ("AA 55 …") or plain text.
    private func pasteboardBytes() -> Data? {
        let pb = NSPasteboard.general
        if let d = pb.data(forType: Self.bytesType) { return d }
        guard let s = pb.string(forType: .string), !s.isEmpty else { return nil }
        if !asciiPane, let p = BufferOps.parsePattern(s), !p.contains(where: { $0 == nil }),
           s.trimmingCharacters(in: .whitespacesAndNewlines).range(of: "^[0-9A-Fa-fxX ,\\n\\r\\t]+$", options: .regularExpression) != nil {
            return Data(p.compactMap { $0 })
        }
        return Data(s.utf8)
    }

    /// Paste overwrites from the cursor (or selection start) and keeps the buffer size.
    @objc func paste(_ sender: Any?) {
        guard let owner = owner, let bytes = pasteboardBytes(), count > 0 else { NSSound.beep(); return }
        let at = selection?.lowerBound ?? cursor
        let n = min(bytes.count, count - at)
        guard n > 0 else { NSSound.beep(); return }
        owner.edit { $0.replace(at..<(at + n), with: bytes.prefix(n)) }
        selection = at..<(at + n)
        cursor = min(at + n, count - 1); anchor = cursor
        needsDisplay = true
        owner.onSelectionChange?()
    }

    @objc func pasteInserting(_ sender: Any?) {
        guard let owner = owner, let bytes = pasteboardBytes() else { NSSound.beep(); return }
        owner.insert(bytes)
    }

    @objc func delete(_ sender: Any?) { deleteForward(sender) }

    @objc override func selectAll(_ sender: Any?) {
        guard count > 0 else { return }
        selection = 0..<count
        anchor = 0; cursor = count - 1
        needsDisplay = true
        owner?.onSelectionChange?()
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(copyAsHex(_:)), #selector(cut(_:)), #selector(delete(_:)): return count > 0
        case #selector(paste(_:)): return count > 0 && pasteboardHasContent
        case #selector(pasteInserting(_:)): return pasteboardHasContent
        case #selector(selectAll(_:)): return count > 0
        default: return true
        }
    }

    private var pasteboardHasContent: Bool {
        NSPasteboard.general.availableType(from: [Self.bytesType, .string]) != nil
    }
}
