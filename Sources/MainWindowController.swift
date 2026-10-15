import Cocoa

final class MainWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {

    // MARK: State
    private var buffer = Data()
    private var bufferName = "empty"
    private var running: Process?
    private(set) var isBusy = false { didSet { updateEnabledState() } }

    // MARK: Views
    private let programmerLabel = NSTextField(labelWithString: "Not checked yet")
    private let chipField = NSTextField()
    private let bufferLabel = NSTextField(labelWithString: "Buffer: empty")
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let progress = NSProgressIndicator()
    private let hexView = MainWindowController.makeTextView()
    private let logView = MainWindowController.makeTextView()

    private var actionButtons: [NSButton] = []
    private var stopButton: NSButton!
    private let skipID = NSButton(checkboxWithTitle: "Skip chip ID check", target: nil, action: nil)
    private let allowSize = NSButton(checkboxWithTitle: "Allow file size mismatch", target: nil, action: nil)
    private let skipErase = NSButton(checkboxWithTitle: "Don't erase before programming", target: nil, action: nil)
    private let skipVerify = NSButton(checkboxWithTitle: "Don't verify after programming", target: nil, action: nil)

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "ChipBurner"
        window.minSize = NSSize(width: 760, height: 560)
        _ = window.setFrameAutosaveName("ChipBurnerMain")
        self.init(window: window)
        window.delegate = self
        buildUI()
        chipField.stringValue = UserDefaults.standard.string(forKey: "lastChip") ?? ""
        updateBufferViews()
        updateEnabledState()
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

        chipField.placeholderString = "e.g. AM27C256@DIP28 – use Search to find the exact name"
        chipField.delegate = self
        chipField.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        let chipRow = row([bold("Chip:"), chipField,
                           button("Search…", #selector(searchChips(_:))),
                           button("Chip Info", #selector(chipInfo(_:))), spacer()])

        let read = button("Read", #selector(readChip(_:)))
        let blank = button("Blank Check", #selector(blankCheck(_:)))
        let program = button("Program…", #selector(programChip(_:)))
        let verify = button("Verify", #selector(verifyChip(_:)))
        let erase = button("Erase", #selector(eraseChip(_:)))
        stopButton = button("Stop", #selector(stop(_:)))
        actionButtons = [read, blank, program, verify, erase]
        let actionRow = row([read, blank, program, verify, erase, spacer(), stopButton])

        let optionsRow = row([skipID, allowSize, skipErase, skipVerify, spacer()])
        [skipID, allowSize, skipErase, skipVerify].forEach { $0.controlSize = .small; $0.font = .systemFont(ofSize: NSFont.smallSystemFontSize) }

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

        let stack = NSStackView(views: [progRow, chipRow, actionRow, optionsRow, fileRow, split, statusRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        for v in [progRow, chipRow, actionRow, optionsRow, fileRow, split, statusRow] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        DispatchQueue.main.async { split.setPosition(split.bounds.height * 0.6, ofDividerAt: 0) }
    }

    // MARK: Helpers

    private var chip: String { chipField.stringValue.trimmingCharacters(in: .whitespaces) }

    func controlTextDidEndEditing(_ obj: Notification) {
        UserDefaults.standard.set(chip, forKey: "lastChip")
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
    }

    private func updateBufferViews() {
        if buffer.isEmpty {
            bufferLabel.stringValue = "Buffer: empty"
            hexView.string = ""
            return
        }
        bufferLabel.stringValue = String(format: "Buffer: %@ — %d bytes — sum 0x%04X — CRC32 0x%08X",
                                         bufferName, buffer.count, Checksums.sum16(buffer), Checksums.crc32(buffer))
        hexView.string = HexDump.render(buffer)
        hexView.scrollToBeginningOfDocument(nil)
    }

    private func requireChip() -> Bool {
        if chip.isEmpty {
            showError("Choose a chip first.", "Type its exact minipro name or use Search… to find it.")
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

    /// Runs one minipro job with progress, logging and a completion callback.
    private func runJob(_ title: String, _ args: [String], then done: ((Bool) -> Void)? = nil) {
        guard !isBusy else { return }
        isBusy = true
        progress.doubleValue = 0
        setStatus("\(title)…")
        log("▶︎ \(title): minipro \(args.joined(separator: " "))")
        let percent = try? NSRegularExpression(pattern: "(\\d{1,3})%")
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
            done?(ok)
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
                self.log("Programmer check:\n" + r.output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    @objc func searchChips(_ sender: Any?) {
        guard let w = window else { return }
        let picker = ChipSearchController(initialQuery: chip) { [weak self] name in
            guard let self = self, let name = name else { return }
            self.chipField.stringValue = name
            UserDefaults.standard.set(name, forKey: "lastChip")
            self.log("Chip selected: \(name)")
        }
        picker.present(on: w)
    }

    @objc func chipInfo(_ sender: Any?) {
        guard requireChip() else { return }
        runJob("Chip info", ["-d", chip])
    }

    @objc func readChip(_ sender: Any?) {
        guard requireChip() else { return }
        let out = tempURL("read.bin")
        try? FileManager.default.removeItem(at: out)
        runJob("Read \(chip)", ["-p", chip, "-r", out.path] + optionArgs(.read)) { [weak self] ok in
            guard let self = self, ok, let data = try? Data(contentsOf: out) else { return }
            self.buffer = data
            self.bufferName = "read from \(self.chip)"
            self.updateBufferViews()
        }
    }

    @objc func blankCheck(_ sender: Any?) {
        guard requireChip() else { return }
        runJob("Blank check \(chip)", ["-p", chip, "-b"] + optionArgs(.check))
    }

    @objc func verifyChip(_ sender: Any?) {
        guard requireChip() else { return }
        guard let file = writeBufferToTemp() else { return }
        runJob("Verify \(chip)", ["-p", chip, "-m", file.path] + optionArgs(.verify))
    }

    @objc func programChip(_ sender: Any?) {
        guard requireChip(), let w = window else { return }
        guard !buffer.isEmpty else {
            showError("The buffer is empty.", "Open a .bin or .hex file, or read a chip, first.")
            return
        }
        let a = NSAlert()
        a.messageText = "Program \(chip)?"
        a.informativeText = "\(buffer.count) bytes from “\(bufferName)” will be written. Check the chip type and that it sits correctly in the socket (lever down, pin 1 at the lever end, bottom-aligned)."
        a.addButton(withTitle: "Program")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { [weak self] resp in
            guard let self = self, resp == .alertFirstButtonReturn, let file = self.writeBufferToTemp() else { return }
            self.runJob("Program \(self.chip)", ["-p", self.chip, "-w", file.path] + self.optionArgs(.write))
        }
    }

    @objc func eraseChip(_ sender: Any?) {
        guard requireChip(), let w = window else { return }
        let a = NSAlert()
        a.messageText = "Erase \(chip)?"
        a.informativeText = "This works for flash and EEPROM chips. UV EPROMs (27Cxxx) can only be erased with UV light."
        a.addButton(withTitle: "Erase")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { [weak self] resp in
            guard let self = self, resp == .alertFirstButtonReturn else { return }
            self.runJob("Erase \(self.chip)", ["-p", self.chip, "-E"])
        }
    }

    @objc func stop(_ sender: Any?) {
        guard let p = running else { return }
        log("Stopping…")
        p.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if p.isRunning { p.terminate() } }
    }

    private func writeBufferToTemp() -> URL? {
        guard !buffer.isEmpty else {
            showError("The buffer is empty.", "Open a file or read a chip first.")
            return nil
        }
        let url = tempURL("buffer.bin")
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
                } else {
                    self.buffer = raw
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
        let panel = NSSavePanel()
        let base = chip.isEmpty ? "dump" : chip.replacingOccurrences(of: "@", with: "_")
        panel.nameFieldStringValue = base + (asHex ? ".hex" : ".bin")
        panel.allowedFileTypes = [asHex ? "hex" : "bin"]
        panel.beginSheetModal(for: w) { [weak self] resp in
            guard let self = self, resp == .OK, let url = panel.url else { return }
            do {
                if asHex {
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
