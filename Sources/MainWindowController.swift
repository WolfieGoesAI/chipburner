import Cocoa

final class MainWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {

    // MARK: State
    private var buffer = Data()
    private var bufferName = "empty"
    /// Text buffers hold JEDEC fuse maps (.jed) or fuse/config files (.conf) instead of raw bytes.
    private var bufferIsText = false
    private var bufferExt = "bin"
    private var running: Process?
    private(set) var isBusy = false { didSet { updateEnabledState() } }

    // MARK: Views
    private let programmerLabel = NSTextField(labelWithString: "Not checked yet")
    private let chipField = NSTextField()
    private let chipInfoLabel = NSTextField(labelWithString: "")
    private let bufferLabel = NSTextField(labelWithString: "Buffer: empty")
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let progress = NSProgressIndicator()
    private let hexView = MainWindowController.makeTextView()
    private let logView = MainWindowController.makeTextView()
    private let memoryPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    private var actionButtons: [NSButton] = []
    private var stopButton: NSButton!
    private let skipID = NSButton(checkboxWithTitle: "Skip chip ID check", target: nil, action: nil)
    private let allowSize = NSButton(checkboxWithTitle: "Allow file size mismatch", target: nil, action: nil)
    private let skipErase = NSButton(checkboxWithTitle: "Don't erase before programming", target: nil, action: nil)
    private let skipVerify = NSButton(checkboxWithTitle: "Don't verify after programming", target: nil, action: nil)

    /// Memory types minipro selects with -c. Titles shown in the popup, argument passed to minipro.
    private let memoryTypes: [(title: String, arg: String?)] = [
        ("Code (main memory)", nil),
        ("Data (EEPROM)", "data"),
        ("Config (fuses)", "config"),
        ("User row", "user"),
        ("Calibration (read only)", "calibration"),
    ]

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "ChipBurner"
        window.minSize = NSSize(width: 820, height: 600)
        _ = window.setFrameAutosaveName("ChipBurnerMain")
        self.init(window: window)
        window.delegate = self
        buildUI()
        chipField.stringValue = UserDefaults.standard.string(forKey: "lastChip") ?? ""
        updateBufferViews()
        updateEnabledState()
        updateChipInfo()
        if !Minipro.shared.isAvailable {
            log("minipro is missing from the app bundle – this build is incomplete.")
        }
    }

    // MARK: UI construction

    private static func makeTextView() -> NSTextView {
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.font = NSFont.userFixedPitchFont(ofSize: 11) ?? NSFont.systemFont(ofSize: 11)
        tv.textColor = .textColor
        tv.backgroundColor = .textBackgroundColor
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        return tv
    }

    private func scroll(_ tv: NSTextView) -> NSScrollView {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.borderType = .bezelBorder
        sv.documentView = tv
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        return sv
    }

    private func bold(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        l.setContentHuggingPriority(.required, for: .horizontal)
        return l
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = .centerY
        s.spacing = 8
        return s
    }

    private func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .horizontal)
        return v
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        programmerLabel.lineBreakMode = .byTruncatingTail
        programmerLabel.isSelectable = true
        let progRow = row([bold("Programmer:"), programmerLabel, spacer(),
                           button("Check Programmer", #selector(checkProgrammer(_:)))])

        chipField.placeholderString = "e.g. AM27C256@DIP28 – use Search or Identify"
        chipField.delegate = self
        chipField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        let chipRow = row([bold("Chip:"), chipField,
                           button("Search…", #selector(searchChips(_:))),
                           button("Identify…", #selector(identifyChip(_:))),
                           button("Chip Info", #selector(chipInfo(_:))), spacer()])

        chipInfoLabel.textColor = .secondaryLabelColor
        chipInfoLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        chipInfoLabel.lineBreakMode = .byTruncatingTail

        let read = button("Read", #selector(readChip(_:)))
        let blank = button("Blank Check", #selector(blankCheck(_:)))
        let program = button("Program…", #selector(programChip(_:)))
        let verify = button("Verify", #selector(verifyChip(_:)))
        let erase = button("Erase", #selector(eraseChip(_:)))
        let logic = button("Logic Test", #selector(logicTest(_:)))
        stopButton = button("Stop", #selector(stop(_:)))
        actionButtons = [read, blank, program, verify, erase, logic]
        let actionRow = row([read, blank, program, verify, erase, logic, spacer(), stopButton])

        memoryTypes.forEach { memoryPopup.addItem(withTitle: $0.title) }
        memoryPopup.controlSize = .small
        memoryPopup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let memLabel = NSTextField(labelWithString: "Memory:")
        memLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        [skipID, allowSize, skipErase, skipVerify].forEach { $0.controlSize = .small; $0.font = .systemFont(ofSize: NSFont.smallSystemFontSize) }
        let optionsRow = row([memLabel, memoryPopup, skipID, allowSize, skipErase, skipVerify, spacer()])

        bufferLabel.lineBreakMode = .byTruncatingMiddle
        bufferLabel.isSelectable = true
        let fileRow = row([bufferLabel, spacer(),
                           button("Open…", #selector(openFile(_:))),
                           button("Save .bin…", #selector(saveBinary(_:))),
                           button("Save .hex…", #selector(saveIntelHex(_:)))])

        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(scroll(hexView))
        split.addArrangedSubview(scroll(logView))
        split.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true

        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 100
        progress.style = .bar
        progress.widthAnchor.constraint(equalToConstant: 220).isActive = true
        statusLabel.lineBreakMode = .byTruncatingTail
        let statusRow = row([statusLabel, spacer(), progress])

        let rows: [NSView] = [progRow, chipRow, chipInfoLabel, actionRow, optionsRow, fileRow, split, statusRow]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(4, after: chipRow)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        for v in rows {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        DispatchQueue.main.async { split.setPosition(split.bounds.height * 0.6, ofDividerAt: 0) }
    }

    // MARK: Helpers

    private var chip: String { chipField.stringValue.trimmingCharacters(in: .whitespaces) }

    private var chipDetails: ChipInfo? {
        ChipDatabase.shared.isLoaded ? ChipDatabase.shared.info(for: chip, programmer: Minipro.shared.programmerType) : nil
    }

    func controlTextDidChange(_ obj: Notification) { updateChipInfo() }

    func controlTextDidEndEditing(_ obj: Notification) {
        UserDefaults.standard.set(chip, forKey: "lastChip")
        updateChipInfo()
    }

    /// Shows the chip type, size and ID under the chip field, and adapts the controls to it.
    func updateChipInfo() {
        guard ChipDatabase.shared.isLoaded else {
            chipInfoLabel.stringValue = "Loading chip database…"
            return
        }
        if let err = ChipDatabase.shared.loadError { chipInfoLabel.stringValue = "Chip database problem: \(err)"; return }
        guard !chip.isEmpty else { chipInfoLabel.stringValue = " "; return }
        guard let info = chipDetails else {
            chipInfoLabel.stringValue = "Not in the \(Minipro.shared.programmerType) database – use Search to find the exact name"
            return
        }
        var s = info.summary
        switch info.kind {
        case .pld: s += " · programs from and reads to .jed fuse files"
        case .logic: s += " · use Logic Test"
        case .mcu where info.dataSize > 0: s += " · pick the memory area under Memory"
        default: break
        }
        chipInfoLabel.stringValue = s
    }

    private func log(_ s: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = NSAttributedString(string: "[\(stamp)] \(s)\n", attributes: [
            .font: logView.font ?? NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.textColor,
        ])
        logView.textStorage?.append(line)
        logView.scrollToEndOfDocument(nil)
    }

    private func setStatus(_ s: String) { statusLabel.stringValue = s }

    private func updateEnabledState() {
        actionButtons.forEach { $0.isEnabled = !isBusy }
        stopButton?.isEnabled = isBusy
        chipField.isEnabled = !isBusy
        memoryPopup.isEnabled = !isBusy
    }

    private func updateBufferViews() {
        if buffer.isEmpty {
            bufferLabel.stringValue = "Buffer: empty"
            hexView.string = ""
            return
        }
        if bufferIsText {
            bufferLabel.stringValue = "Buffer: \(bufferName) — .\(bufferExt) text, \(buffer.count) bytes"
            hexView.string = String(decoding: buffer, as: UTF8.self)
        } else {
            bufferLabel.stringValue = String(format: "Buffer: %@ — %d bytes — sum 0x%04X — CRC32 0x%08X",
                                             bufferName, buffer.count, Checksums.sum16(buffer), Checksums.crc32(buffer))
            hexView.string = HexDump.render(buffer)
        }
        hexView.scrollToBeginningOfDocument(nil)
    }

    private func requireChip() -> Bool {
        if chip.isEmpty {
            showError("Choose a chip first.", "Type its exact minipro name, or use Search… or Identify….")
            return false
        }
        return true
    }

    private func showError(_ title: String, _ detail: String) {
        guard let w = window else { return }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title
        a.informativeText = detail
        a.beginSheetModal(for: w, completionHandler: nil)
    }

    private func showInfo(_ title: String, _ detail: String) {
        guard let w = window else { return }
        let a = NSAlert()
        a.alertStyle = .informational
        a.messageText = title
        a.informativeText = detail
        a.beginSheetModal(for: w, completionHandler: nil)
    }

    private func tempURL(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ChipBurner", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    private enum JobKind { case read, check, verify, write }

    /// minipro: -x = don't read the chip ID (read mode), -y = don't fail on ID mismatch,
    /// -s = size mismatch is only a warning, -e = don't erase, -v = don't verify after writing.
    private func optionArgs(_ kind: JobKind) -> [String] {
        var a: [String] = []
        if skipID.state == .on { a.append(kind == .read ? "-x" : "-y") }
        if allowSize.state == .on, kind == .verify || kind == .write { a.append("-s") }
        if kind == .write {
            if skipErase.state == .on { a.append("-e") }
            if skipVerify.state == .on { a.append("-v") }
        }
        return a
    }

    /// What the selected chip and memory area exchange: minipro's -c argument, text or binary, file extension.
    private struct Mode { let memArgs: [String]; let text: Bool; let ext: String; let label: String }

    private var mode: Mode {
        if chipDetails?.kind == .pld { return Mode(memArgs: [], text: true, ext: "jed", label: "JEDEC fuse map") }
        let sel = memoryTypes[max(0, memoryPopup.indexOfSelectedItem)]
        guard let arg = sel.arg else { return Mode(memArgs: [], text: false, ext: "bin", label: "code memory") }
        if arg == "config" { return Mode(memArgs: ["-c", arg], text: true, ext: "conf", label: "fuse/config settings") }
        return Mode(memArgs: ["-c", arg], text: false, ext: "bin", label: "\(arg) memory")
    }

    /// Runs one minipro job with progress and logging; `done` gets success and the full output.
    private func runJob(_ title: String, _ args: [String], then done: ((Bool, String) -> Void)? = nil) {
        guard !isBusy else { return }
        isBusy = true
        progress.doubleValue = 0
        setStatus("\(title)…")
        log("▶︎ \(title): minipro \(args.joined(separator: " "))")
        let percent = try? NSRegularExpression(pattern: "(\\d{1,3})%")
        var collected: [String] = []
        running = Minipro.shared.run(args, onLine: { [weak self] line, isProgress in
            guard let self = self else { return }
            if isProgress {
                self.setStatus(line)
                let ns = line as NSString
                if let m = percent?.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                   let v = Double(ns.substring(with: m.range(at: 1))) {
                    self.progress.doubleValue = v
                }
            } else {
                collected.append(line)
                self.log(line)
            }
        }, completion: { [weak self] status in
            guard let self = self else { return }
            self.running = nil
            self.isBusy = false
            let ok = status == 0
            self.progress.doubleValue = ok ? 100 : 0
            self.setStatus(ok ? "\(title): done" : "\(title): failed (exit code \(status))")
            self.log(ok ? "✓ \(title) finished." : "✗ \(title) failed (exit code \(status)).")
            if !ok { NSSound.beep() }
            done?(ok, collected.joined(separator: "\n"))
        })
        if running == nil { isBusy = false }
    }

    // MARK: Actions

    @objc func checkProgrammer(_ sender: Any?) {
        guard !isBusy else { return }
        programmerLabel.stringValue = "Checking…"
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Minipro.shared.runSync(["-k"])
            DispatchQueue.main.async {
                let lines = r.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                let found = lines.first { $0.lowercased().contains("found") } ?? lines.first ?? "No answer"
                self.programmerLabel.stringValue = r.status == 0 ? found : "Not found – \(found)"
                if r.status == 0 { Minipro.shared.updateProgrammerType(from: r.output) }
                self.log("Programmer check:\n" + r.output.trimmingCharacters(in: .whitespacesAndNewlines))
                self.updateChipInfo()
            }
        }
    }

    private func selectChip(_ name: String) {
        chipField.stringValue = name
        UserDefaults.standard.set(name, forKey: "lastChip")
        log("Chip selected: \(name)")
        updateChipInfo()
    }

    @objc func searchChips(_ sender: Any?) {
        guard let w = window else { return }
        let picker = ChipSearchController(initialQuery: chip) { [weak self] name in
            guard let self = self, let name = name else { return }
            self.selectChip(name)
        }
        picker.present(on: w)
    }

    @objc func chipInfo(_ sender: Any?) {
        guard requireChip() else { return }
        runJob("Chip info", ["-q", Minipro.shared.programmerType, "-d", chip])
    }

    /// Reads the electronic ID with a reference algorithm, then lists every database chip with that ID.
    @objc func identifyChip(_ sender: Any?) {
        guard let w = window, !isBusy else { return }
        guard ChipDatabase.shared.isLoaded else { showError("The chip database is still loading.", "Try again in a moment."); return }
        var refs: [(String, String)] = [
            ("28-pin UV EPROM (27C64 to 27C512)", "AM27C256@DIP28"),
            ("32-pin UV EPROM (27C010 to 27C080)", "AM27C010@DIP32"),
        ]
        if !chip.isEmpty, chipDetails != nil { refs.append(("Same type as \(chip)", chip)) }
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
        refs.forEach { popup.addItem(withTitle: $0.0) }
        let a = NSAlert()
        a.messageText = "Identify chip"
        a.informativeText = "Put the chip in the socket (bottom-aligned, pin 1 at the lever end) and choose what kind of chip it is. ChipBurner reads its electronic ID and lists the chips that match. Old NMOS parts such as 2716 and 2732 have no ID."
        a.accessoryView = popup
        a.addButton(withTitle: "Read ID")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { [weak self] resp in
            guard let self = self, resp == .alertFirstButtonReturn else { return }
            let ref = refs[max(0, popup.indexOfSelectedItem)].1
            self.runIdentify(reference: ref)
        }
    }

    private func runIdentify(reference ref: String) {
        let programmer = Minipro.shared.programmerType
        guard let refInfo = ChipDatabase.shared.info(for: ref, programmer: programmer) else {
            showError("\(ref) isn't in the \(programmer) database.", "Pick another reference or press Check Programmer first.")
            return
        }
        runJob("Read ID", ["-p", ref, "-D", "-y"]) { [weak self] _, output in
            guard let self = self, let w = self.window else { return }
            guard let id = ChipIDParser.parse(output), id != 0, id != 0xFFFF, id != 0xFFFFFFFF else {
                self.showError("No chip ID could be read.",
                               "Check that the chip sits correctly. Some chips, including old NMOS EPROMs, have no electronic ID – choose them with Search instead.")
                return
            }
            let idText = String(format: "0x%04X", id)
            var matches = ChipDatabase.shared.chips(withID: id, programmer: programmer, packageSuffix: refInfo.packageSuffix)
            if matches.isEmpty { matches = ChipDatabase.shared.chips(withID: id, programmer: programmer, packageSuffix: nil) }
            self.log("Chip ID \(idText): \(Set(matches.map { $0.name.uppercased() }).count) matching chip(s) in the database.")
            guard !matches.isEmpty else {
                self.showInfo("Chip ID \(idText) read", "No chip in the \(programmer) database has this ID. The maker code is 0x\(String(format: "%02X", (id >> 8) & 0xFF)).")
                return
            }
            var seen = Set<String>()
            let names = matches.map { $0.name }.filter { seen.insert($0.uppercased()).inserted }
            let picker = ChipSearchController(title: "Chips with ID \(idText)", results: names) { [weak self] name in
                guard let self = self, let name = name else { return }
                self.selectChip(name)
            }
            picker.present(on: w)
        }
    }

    @objc func readChip(_ sender: Any?) {
        guard requireChip() else { return }
        let m = mode
        let out = tempURL("read.\(m.ext)")
        try? FileManager.default.removeItem(at: out)
        runJob("Read \(chip) (\(m.label))", ["-p", chip] + m.memArgs + ["-r", out.path] + optionArgs(.read)) { [weak self] ok, _ in
            guard let self = self, ok, let data = try? Data(contentsOf: out) else { return }
            self.buffer = data
            self.bufferIsText = m.text
            self.bufferExt = m.ext
            self.bufferName = "read from \(self.chip)"
            self.updateBufferViews()
        }
    }

    @objc func blankCheck(_ sender: Any?) {
        guard requireChip() else { return }
        let m = mode
        runJob("Blank check \(chip)", ["-p", chip] + m.memArgs + ["-b"] + optionArgs(.check))
    }

    @objc func verifyChip(_ sender: Any?) {
        guard requireChip(), let file = writeBufferToTemp(for: mode) else { return }
        let m = mode
        runJob("Verify \(chip)", ["-p", chip] + m.memArgs + ["-m", file.path] + optionArgs(.verify))
    }

    @objc func programChip(_ sender: Any?) {
        guard requireChip(), let w = window else { return }
        let m = mode
        guard let file = writeBufferToTemp(for: m) else { return }
        let a = NSAlert()
        a.messageText = "Program \(chip)?"
        a.informativeText = "\(buffer.count) bytes from “\(bufferName)” will be written to the \(m.label). Check the chip type and that it sits correctly in the socket (lever down, pin 1 at the lever end, bottom-aligned)."
        a.addButton(withTitle: "Program")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { [weak self] resp in
            guard let self = self, resp == .alertFirstButtonReturn else { return }
            self.runJob("Program \(self.chip)", ["-p", self.chip] + m.memArgs + ["-w", file.path] + self.optionArgs(.write))
        }
    }

    @objc func eraseChip(_ sender: Any?) {
        guard requireChip(), let w = window else { return }
        let a = NSAlert()
        a.messageText = "Erase \(chip)?"
        a.informativeText = "This works for flash, EEPROM, GAL and microcontroller chips. UV EPROMs (27Cxxx) can only be erased with UV light."
        a.addButton(withTitle: "Erase")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { [weak self] resp in
            guard let self = self, resp == .alertFirstButtonReturn else { return }
            self.runJob("Erase \(self.chip)", ["-p", self.chip, "-E"])
        }
    }

    /// Runs minipro's logic IC test; failing pins are marked with "-" after the expected state.
    @objc func logicTest(_ sender: Any?) {
        guard requireChip() else { return }
        if let k = chipDetails?.kind, k != .logic {
            showError("\(chip) isn't a logic chip.", "Logic Test works with 74xx and 40xx logic ICs from the logic database, e.g. 7400 or 4011.")
            return
        }
        let name = chip
        runJob("Logic test \(name)", ["-p", name, "-T"]) { [weak self] ok, output in
            guard let self = self else { return }
            let lines = output.components(separatedBy: .newlines)
            let failing = lines.filter { $0.range(of: "[01HLZXCGV]-", options: .regularExpression) != nil }
            if ok && failing.isEmpty {
                self.showInfo("\(name) passed", "All test vectors matched. Details are in the log.")
            } else if !failing.isEmpty {
                self.showError("\(name) failed", "\(failing.count) test vector(s) had pins in the wrong state (marked with “-” in the log).")
            } else {
                self.showError("Logic test didn't complete", "See the log for minipro's message.")
            }
        }
    }

    @objc func stop(_ sender: Any?) {
        guard let p = running else { return }
        log("Stopping…")
        p.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if p.isRunning { p.terminate() } }
    }

    private func writeBufferToTemp(for m: Mode) -> URL? {
        guard !buffer.isEmpty else {
            showError("The buffer is empty.", "Open a file or read a chip first.")
            return nil
        }
        if m.text != bufferIsText {
            showError(m.text ? "This needs a .\(m.ext) text file." : "This needs binary data.",
                      m.text ? "The \(m.label) is exchanged as a .\(m.ext) text file. Open one, or read it from a chip first."
                             : "The buffer holds a .\(bufferExt) text file. Open a .bin or .hex file for this memory area.")
            return nil
        }
        let url = tempURL("buffer.\(m.ext)")
        do { try buffer.write(to: url); return url } catch {
            showError("Could not write a temporary file.", error.localizedDescription)
            return nil
        }
    }

    // MARK: Files

    @objc func openFile(_ sender: Any?) {
        guard let w = window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: w) { [weak self] resp in
            guard let self = self, resp == .OK, let url = panel.url else { return }
            do {
                let raw = try Data(contentsOf: url)
                let ext = url.pathExtension.lowercased()
                if ["hex", "ihx", "ihex"].contains(ext) {
                    self.buffer = try IntelHex.parse(String(decoding: raw, as: UTF8.self))
                    self.bufferIsText = false; self.bufferExt = "bin"
                } else if ["jed", "conf", "txt", "fuses"].contains(ext) {
                    self.buffer = raw
                    self.bufferIsText = true; self.bufferExt = ext == "jed" ? "jed" : "conf"
                } else {
                    self.buffer = raw
                    self.bufferIsText = false; self.bufferExt = "bin"
                }
                self.bufferName = url.lastPathComponent
                self.updateBufferViews()
                self.log("Loaded \(url.lastPathComponent) (\(self.buffer.count) bytes).")
            } catch {
                self.showError("Could not open \(url.lastPathComponent).", error.localizedDescription)
            }
        }
    }

    @objc func saveBinary(_ sender: Any?) { save(asHex: false) }
    @objc func saveIntelHex(_ sender: Any?) { save(asHex: true) }

    private func save(asHex: Bool) {
        guard let w = window else { return }
        guard !buffer.isEmpty else { showError("The buffer is empty.", "Nothing to save yet."); return }
        let ext = bufferIsText ? bufferExt : (asHex ? "hex" : "bin")
        let panel = NSSavePanel()
        let base = chip.isEmpty ? "dump" : chip.replacingOccurrences(of: "@", with: "_")
        panel.nameFieldStringValue = base + "." + ext
        panel.allowedFileTypes = [ext]
        panel.beginSheetModal(for: w) { [weak self] resp in
            guard let self = self, resp == .OK, let url = panel.url else { return }
            do {
                if asHex && !self.bufferIsText {
                    try IntelHex.write(self.buffer).write(to: url, atomically: true, encoding: .ascii)
                } else {
                    try self.buffer.write(to: url)
                }
                self.log("Saved \(url.lastPathComponent).")
            } catch {
                self.showError("Could not save.", error.localizedDescription)
            }
        }
    }

    // MARK: Window

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isBusy { NSSound.beep(); log("Wait for the current job to finish, or press Stop."); return false }
        return true
    }
}
