import Cocoa

/// A window for a microcontroller's fuses, user ID and lock bits: one section each, read and
/// written separately with minipro's --fuses, --uid and --lock.
final class ConfigWindowController: NSWindowController {
    final class Field {
        let name: String
        let mask: UInt16
        let defaultValue: UInt16
        let wide: Bool
        let input = NSTextField()
        var checks: [NSButton] = []      // index = bit number
        init(name: String, mask: UInt16, defaultValue: UInt16, wide: Bool) {
            self.name = name; self.mask = mask; self.defaultValue = defaultValue; self.wide = wide
        }
    }

    enum Section: String, CaseIterable {
        case fuses = "Fuses", uid = "User ID", lock = "Lock bits"
        var flag: String { self == .fuses ? "--fuses" : self == .uid ? "--uid" : "--lock" }
    }

    typealias Runner = (_ title: String, _ args: [String], _ done: @escaping (Bool, String) -> Void) -> Void

    private let chip: String
    private let baseArgs: [String]
    private let run: Runner
    private var fields: [Section: [Field]] = [:]
    private var retainSelf: ConfigWindowController?
    private let status = NSTextField(labelWithString: "Values shown are the database defaults until you read the chip.")

    private let lockWriteOnly: Bool

    init(chip: String, config: ChipConfig, wordSize: Int, lockWriteOnly: Bool, baseArgs: [String], run: @escaping Runner) {
        self.lockWriteOnly = lockWriteOnly
        self.chip = chip
        self.baseArgs = baseArgs
        self.run = run
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "\(chip) – Fuses, User ID & Lock Bits"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 480, height: 300)
        super.init(window: w)
        let wide = wordSize == 2 || (config.fuses + config.locks).contains { $0.mask > 0xFF || $0.defaultValue > 0xFF }
        fields[.fuses] = config.fuses.map { Field(name: $0.name, mask: $0.mask, defaultValue: $0.defaultValue, wide: wide) }
        fields[.uid] = (0..<config.userIDs).map { Field(name: "user_id\($0)", mask: wide ? 0xFFFF : 0xFF, defaultValue: wide ? 0xFFFF : 0xFF, wide: wide) }
        fields[.lock] = config.locks.map { Field(name: $0.name, mask: $0.mask, defaultValue: $0.defaultValue, wide: wide) }
        buildUI()
        w.center()
        retainSelf = self
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            self?.retainSelf = nil
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: UI

    private var activeSections: [Section] { Section.allCases.filter { !(fields[$0] ?? []).isEmpty } }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        var views: [NSView] = []
        let intro = NSTextField(wrappingLabelWithString: "Tick or untick single bits, or type the value in hex. A ticked box is a 1. Greyed-out bits aren't used by the chip. On AVRs a fuse bit of 0 means \u{201C}programmed\u{201D}. Each section is read and written on its own.")
        intro.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        intro.textColor = .secondaryLabelColor
        views.append(intro)

        for section in activeSections {
            let grid = NSGridView()
            grid.rowSpacing = 6
            grid.columnSpacing = 10
            for f in fields[section] ?? [] {
                let name = NSTextField(labelWithString: f.name)
                name.alignment = .right
                f.input.font = NSFont.userFixedPitchFont(ofSize: 12)
                f.input.placeholderString = f.wide ? "0x0000" : "0x00"
                f.input.widthAnchor.constraint(equalToConstant: 80).isActive = true
                f.input.target = self
                f.input.action = #selector(valueEdited(_:))
                let n = f.wide ? 16 : 8
                f.checks = (0..<n).map { bit -> NSButton in
                    let c = NSButton(checkboxWithTitle: "\(bit)", target: self, action: #selector(bitToggled(_:)))
                    c.controlSize = .small
                    c.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                    c.tag = bit
                    c.imagePosition = .imageAbove
                    c.isEnabled = (f.mask >> bit) & 1 == 1
                    c.toolTip = c.isEnabled ? "Bit \(bit)" : "Bit \(bit) isn't used by this chip"
                    return c
                }
                var boxes: [NSView] = []
                for bit in stride(from: n - 1, through: 0, by: -1) {
                    boxes.append(f.checks[bit])
                    if bit % 4 == 0 && bit > 0 {
                        let gap = NSView()
                        gap.widthAnchor.constraint(equalToConstant: 6).isActive = true
                        boxes.append(gap)
                    }
                }
                let bitRow = NSStackView(views: boxes)
                bitRow.orientation = .horizontal
                bitRow.spacing = 2
                let def = NSTextField(labelWithString: "default " + hex(f.defaultValue, f.wide))
                def.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                def.textColor = .secondaryLabelColor
                grid.addRow(with: [name, f.input, bitRow, def])
                set(f, f.defaultValue)
            }
            grid.column(at: 0).xPlacement = .trailing
            grid.setContentHuggingPriority(.required, for: .horizontal)   // keep rows left-aligned
            grid.rowAlignment = .none
            for r in 0..<grid.numberOfRows { grid.row(at: r).yPlacement = .center }
            let read = NSButton(title: "Read", target: self, action: #selector(readSection(_:)))
            let write = NSButton(title: "Write", target: self, action: #selector(writeSection(_:)))
            let defaults = NSButton(title: "Defaults", target: self, action: #selector(defaultsSection(_:)))
            for (i, b) in [read, write, defaults].enumerated() {
                b.bezelStyle = .rounded
                b.tag = Section.allCases.firstIndex(of: section)! * 10 + i
            }
            if section == .lock && lockWriteOnly {
                read.isEnabled = false
                read.toolTip = "This chip's lock bits can be written but not read back."
            }
            let spacer = NSView()
            spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .horizontal)
            let buttons = NSStackView(views: [spacer, defaults, read, write])
            buttons.orientation = .horizontal
            // A heading and a separator line instead of an NSBox, which doesn't size itself to its
            // contents under Auto Layout (the sections collapsed on top of each other).
            let heading = NSTextField(labelWithString: section.rawValue)
            heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            let separator = NSBox()
            separator.boxType = .separator
            let inner = NSStackView(views: [heading, grid, buttons])
            inner.orientation = .vertical
            inner.alignment = .leading
            inner.spacing = 8
            buttons.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
            views.append(separator)
            views.append(inner)
        }

        let readAll = NSButton(title: "Read All", target: self, action: #selector(readAll(_:)))
        let open = NSButton(title: "Open…", target: self, action: #selector(openFile(_:)))
        let save = NSButton(title: "Save…", target: self, action: #selector(saveFile(_:)))
        [readAll, open, save].forEach { $0.bezelStyle = .rounded }
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .horizontal)
        let bottom = NSStackView(views: [open, save, spacer, readAll])
        bottom.orientation = .horizontal
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.lineBreakMode = .byTruncatingTail
        views += [bottom, status]

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 12, right: 14)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        for v in views { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true }
    }

    private final class FlippedView: NSView { override var isFlipped: Bool { true } }

    // MARK: Values

    private func hex(_ v: UInt16, _ wide: Bool) -> String { String(format: wide ? "0x%04X" : "0x%02X", v) }

    private func set(_ f: Field, _ v: UInt16) {
        f.input.stringValue = hex(v, f.wide)
        for c in f.checks { c.state = (v >> c.tag) & 1 == 1 ? .on : .off }
    }

    @objc private func bitToggled(_ sender: NSButton) {
        for list in fields.values { for f in list where f.checks.contains(where: { $0 === sender }) {
            var v = value(f) ?? f.defaultValue
            let bit = UInt16(1) << UInt16(sender.tag)
            if sender.state == .on { v |= bit } else { v &= ~bit }
            set(f, v)
            status.stringValue = "\(f.name) = \(hex(v, f.wide)) (not written yet)"
            status.textColor = .labelColor
        } }
    }

    private func value(_ f: Field) -> UInt16? {
        var t = f.input.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("0x") { t.removeFirst(2) }
        guard !t.isEmpty, let v = UInt16(t, radix: 16), f.wide || v <= 0xFF else { return nil }
        return v
    }

    @objc private func valueEdited(_ sender: NSTextField) {
        for list in fields.values { for f in list where f.input === sender {
            if let v = value(f) { set(f, v) } else { NSSound.beep(); status.stringValue = "\(f.name): not a hex value"; status.textColor = .systemRed }
        } }
    }

    private func section(of sender: NSButton) -> Section { Section.allCases[sender.tag / 10] }

    private func apply(_ values: [String: UInt16], to sections: [Section]) -> Int {
        var n = 0
        for s in sections { for f in fields[s] ?? [] {
            if let v = values[f.name.lowercased()] { set(f, v); n += 1 }
        } }
        return n
    }

    private func tempURL(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ChipBurner", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    // MARK: Actions

    private func read(_ sections: [Section], filter: [String], then next: (() -> Void)? = nil) {
        let url = tempURL("config-read.conf")
        try? FileManager.default.removeItem(at: url)
        let what = sections.map { $0.rawValue.lowercased() }.joined(separator: ", ")
        run("Read \(what) of \(chip)", baseArgs + ["-c", "config", "-r", url.path] + filter) { [weak self] ok, output in
            guard let self = self else { return }
            guard ok, let text = try? String(contentsOf: url) else {
                self.status.stringValue = "Reading \(what) failed – press Log in the main window for details."
                self.status.textColor = .systemRed
                return
            }
            let n = self.apply(ConfigText.parse(text), to: sections)
            self.status.stringValue = "Read \(n) value(s) from the chip."
            self.status.textColor = .labelColor
            next?()
        }
    }

    @objc private func readSection(_ sender: NSButton) {
        let s = section(of: sender)
        read([s], filter: [s.flag])
    }

    @objc private func readAll(_ sender: Any?) {
        if lockWriteOnly && fields[.lock]?.isEmpty == false {
            // minipro refuses a lock read on these chips, so read the other sections one by one.
            let readable = activeSections.filter { $0 != .lock }
            guard let first = readable.first else { return }
            read([first], filter: [first.flag]) { [weak self] in
                guard let self = self, readable.count > 1 else { return }
                self.read([readable[1]], filter: [readable[1].flag])
            }
            return
        }
        read(activeSections, filter: [])
    }

    @objc private func defaultsSection(_ sender: NSButton) {
        for f in fields[section(of: sender)] ?? [] { set(f, f.defaultValue) }
        status.stringValue = "\(section(of: sender).rawValue): database defaults filled in (not written yet)."
        status.textColor = .labelColor
    }

    @objc private func writeSection(_ sender: NSButton) {
        guard let w = window else { return }
        let s = section(of: sender)
        var lines: [String] = []
        for f in fields[s] ?? [] {
            guard let v = value(f) else {
                status.stringValue = "\(f.name) isn't a valid hex value."
                status.textColor = .systemRed
                NSSound.beep()
                return
            }
            lines.append(ConfigText.line(f.name, v, wide: f.wide))
        }
        let a = NSAlert()
        a.messageText = "Write \(s.rawValue.lowercased()) to \(chip)?"
        var info = lines.joined(separator: "\n")
        switch s {
        case .fuses:
            info += "\n\nWrong fuse settings can stop the chip from running or from being programmed again (for example the clock source, reset pin or programming-interface fuses). Check the values against the data sheet."
        case .lock:
            info += "\n\nLocking stops the program memory from being read back or changed. Usually only a full chip erase unlocks it again."
        case .uid:
            break
        }
        a.informativeText = info
        a.alertStyle = s == .uid ? .informational : .warning
        a.addButton(withTitle: "Write")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { [weak self] resp in
            guard let self = self, resp == .alertFirstButtonReturn else { return }
            let url = self.tempURL("config-write.conf")
            do { try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .ascii) } catch {
                self.status.stringValue = "Could not write a temporary file."
                return
            }
            self.run("Write \(s.rawValue.lowercased()) of \(self.chip)", self.baseArgs + ["-c", "config", "-w", url.path, s.flag]) { [weak self] ok, output in
                guard let self = self else { return }
                let verifyError = output.lowercased().contains("verify error")
                self.status.stringValue = ok && !verifyError ? "\(s.rawValue) written and read back." :
                    verifyError ? "\(s.rawValue) written, but reading back gave different values – see the Log." :
                    "Writing \(s.rawValue.lowercased()) failed – see the Log."
                self.status.textColor = ok && !verifyError ? .labelColor : .systemRed
            }
        }
    }

    @objc private func openFile(_ sender: Any?) {
        guard let w = window else { return }
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["conf", "fuses", "txt", "cfg"]
        panel.beginSheetModal(for: w) { [weak self] resp in
            guard let self = self, resp == .OK, let url = panel.url, let text = try? String(contentsOf: url) else { return }
            let n = self.apply(ConfigText.parse(text), to: self.activeSections)
            self.status.stringValue = "Loaded \(n) value(s) from \(url.lastPathComponent) (not written yet)."
            self.status.textColor = .labelColor
        }
    }

    @objc private func saveFile(_ sender: Any?) {
        guard let w = window else { return }
        var lines: [String] = []
        for s in activeSections { for f in fields[s] ?? [] {
            if let v = value(f) { lines.append(ConfigText.line(f.name, v, wide: f.wide)) }
        } }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = chip.replacingOccurrences(of: "@", with: "_") + ".conf"
        panel.allowedFileTypes = ["conf"]
        panel.beginSheetModal(for: w) { [weak self] resp in
            guard let self = self, resp == .OK, let url = panel.url else { return }
            do {
                try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .ascii)
                self.status.stringValue = "Saved \(url.lastPathComponent)."
            } catch { self.status.stringValue = "Could not save: \(error.localizedDescription)" }
        }
    }
}
