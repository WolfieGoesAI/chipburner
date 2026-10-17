import Cocoa

/// Shows the buffer as CPU code. The ROM's base address says where the buffer's first byte sits in the
/// CPU's memory (an EPROM at the top of a 6809's memory starts at E000 for an 8 KB chip, for example).
final class DisassemblyWindowController: NSWindowController, NSTextFieldDelegate {
    private let bytes: [UInt8]
    private let sourceName: String
    private var retainSelf: DisassemblyWindowController?
    var onSelectInBuffer: ((Range<Int>) -> Void)?

    private let cpuPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let baseField = NSTextField()
    private let startField = NSTextField()
    private let note = NSTextField(labelWithString: "")
    private let textView = NSTextView()
    private let status = NSTextField(labelWithString: "")
    private var lines: [DisasmLine] = []

    static let maxLines = 100_000

    init(bytes: Data, name: String, startOffset: Int?) {
        self.bytes = [UInt8](bytes)
        self.sourceName = name
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Disassembly – \(name)"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 520, height: 320)
        super.init(window: w)
        buildUI()
        let saved = UserDefaults.standard.string(forKey: "disasmCPU").flatMap { DisasmCPU(rawValue: $0) } ?? .z80
        cpuPopup.selectItem(withTitle: saved.rawValue)
        applyDefaultBase()
        if let s = startOffset { startField.stringValue = String(format: "%04X", base + s) }
        render()
        w.center()
        retainSelf = self
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            self?.retainSelf = nil
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var cpu: DisasmCPU { DisasmCPU(rawValue: cpuPopup.titleOfSelectedItem ?? "") ?? .z80 }

    private func parseHex(_ s: String) -> Int? {
        var t = s.trimmingCharacters(in: .whitespaces).uppercased()
        if t.hasPrefix("$") { t.removeFirst() }
        if t.hasPrefix("0X") { t.removeFirst(2) }
        if t.hasSuffix("H") { t.removeLast() }
        return t.isEmpty ? nil : Int(t, radix: 16)
    }

    private var base: Int { parseHex(baseField.stringValue) ?? 0 }

    /// 6502 and 6809 have their reset vector at the top, so their ROM usually ends at FFFF.
    private func applyDefaultBase() {
        let size = bytes.count
        let b: Int
        switch cpu {
        case .m6502, .m6809: b = size > 0 && size <= 0x10000 ? 0x10000 - size : 0
        default: b = 0
        }
        baseField.stringValue = String(format: "%04X", b)
        startField.stringValue = String(format: "%04X", b)
        note.stringValue = cpu.examples
    }

    // MARK: UI

    private func buildUI() {
        guard let content = window?.contentView else { return }
        func label(_ s: String) -> NSTextField { NSTextField(labelWithString: s) }
        DisasmCPU.allCases.forEach { cpuPopup.addItem(withTitle: $0.rawValue) }
        cpuPopup.target = self
        cpuPopup.action = #selector(cpuChanged(_:))
        for f in [baseField, startField] {
            f.font = NSFont.userFixedPitchFont(ofSize: 12)
            f.widthAnchor.constraint(equalToConstant: 70).isActive = true
            f.delegate = self
        }
        baseField.toolTip = "The CPU address of the buffer's first byte."
        startField.toolTip = "Where to start disassembling (a CPU address)."
        let resetButton = NSButton(title: "Reset Vector", target: self, action: #selector(useResetVector(_:)))
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        resetButton.toolTip = "Start where the CPU starts after reset (6502: FFFC, 6809: FFFE; Z80, µPD7810 and 8051 start at 0000)."
        let top = NSStackView(views: [label("CPU:"), cpuPopup, label("ROM starts at:"), baseField, label("Start at:"), startField, resetButton])
        top.orientation = .horizontal
        top.spacing = 6
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor

        textView.isEditable = false
        textView.isRichText = false
        textView.font = NSFont.userFixedPitchFont(ofSize: 12)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder

        func b(_ t: String, _ s: Selector) -> NSButton {
            let x = NSButton(title: t, target: self, action: s)
            x.bezelStyle = .rounded
            return x
        }
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .horizontal)
        let bottom = NSStackView(views: [status, spacer, b("Select in Buffer", #selector(selectInBuffer(_:))), b("Copy", #selector(copyAll(_:))), b("Save…", #selector(save(_:)))])
        bottom.orientation = .horizontal

        let stack = NSStackView(views: [top, note, scroll, bottom])
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
        for v in [scroll, bottom] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
    }

    // MARK: Rendering

    private func render() {
        let b = base
        let start = max(b, min(parseHex(startField.stringValue) ?? b, b + max(0, bytes.count - 1)))
        lines = Disassembler(cpu).run(bytes, base: b, start: start, end: b + bytes.count, maxLines: Self.maxLines)
        let digits = b + bytes.count > 0x10000 ? 5 : 4
        var out = "; \(sourceName) – \(cpu.rawValue), ROM at \(String(format: "%0\(digits)X", b))–\(String(format: "%0\(digits)X", b + max(0, bytes.count - 1)))\n"
        out.reserveCapacity(lines.count * 40)
        for l in lines {
            var hex = ""
            for k in 0..<min(l.length, 5) {
                let i = l.address - b + k
                hex += String(format: "%02X ", i < bytes.count ? Int(bytes[i]) : 0)
            }
            if l.length > 5 { hex += "…" }
            out += String(format: "%0\(digits)X  ", l.address) + hex.padding(toLength: 16, withPad: " ", startingAt: 0) + l.text + "\n"
        }
        textView.string = out
        textView.scrollToBeginningOfDocument(nil)
        status.stringValue = "\(lines.count) instructions" + (lines.count >= Self.maxLines ? " (stopped at \(Self.maxLines))" : "") + ". Data areas show up as nonsense code – that's normal."
    }

    @objc private func cpuChanged(_ sender: Any?) {
        UserDefaults.standard.set(cpu.rawValue, forKey: "disasmCPU")
        applyDefaultBase()
        render()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if (obj.object as? NSTextField) === baseField { startField.stringValue = baseField.stringValue }
        render()
    }

    @objc private func useResetVector(_ sender: Any?) {
        let b = base
        func byte(_ a: Int) -> Int? { a >= b && a - b < bytes.count ? Int(bytes[a - b]) : nil }
        var target = b
        switch cpu {
        case .m6502: if let lo = byte(0xFFFC), let hi = byte(0xFFFD) { target = lo | (hi << 8) }
        case .m6809: if let hi = byte(0xFFFE), let lo = byte(0xFFFF) { target = (hi << 8) | lo }
        default: target = 0
        }
        if target < b || target >= b + bytes.count {
            status.stringValue = String(format: "The reset vector points to %04X, which isn't in this ROM (check “ROM starts at”).", target)
            NSSound.beep()
            return
        }
        startField.stringValue = String(format: "%04X", target)
        render()
    }

    /// Selects the bytes of the instructions selected in the text.
    @objc private func selectInBuffer(_ sender: Any?) {
        let ns = textView.string as NSString
        let sel = textView.selectedRange()
        let first = ns.substring(to: sel.location).components(separatedBy: "\n").count - 2
        let last = ns.substring(to: NSMaxRange(sel)).components(separatedBy: "\n").count - 2
        guard first >= 0, first < lines.count else { NSSound.beep(); return }
        let l1 = lines[first], l2 = lines[max(first, min(last, lines.count - 1))]
        onSelectInBuffer?((l1.address - base)..<(l2.address - base + max(1, l2.length)))
    }

    @objc private func copyAll(_ sender: Any?) {
        let sel = textView.selectedRange()
        let s = sel.length > 0 ? (textView.string as NSString).substring(with: sel) : textView.string
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    @objc private func save(_ sender: Any?) {
        guard let w = window else { return }
        let p = NSSavePanel()
        p.nameFieldStringValue = ((sourceName as NSString).deletingPathExtension) + ".asm"
        p.allowedFileTypes = ["asm", "txt"]
        p.beginSheetModal(for: w) { [weak self] r in
            guard let self = self, r == .OK, let url = p.url else { return }
            try? self.textView.string.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
