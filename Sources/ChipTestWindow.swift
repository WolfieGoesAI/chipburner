import Cocoa

/// The Chip Test window: SRAM pattern test, or EPROM/EEPROM/flash health check.
final class ChipTestWindowController: NSWindowController {
    enum Kind { case sram, memory }

    struct Setup {
        let chip: String
        let kind: Kind
        let size: Int
        let readArgs: [String]        // -p chip, connection, ID options for reading
        let writeArgs: [String]       // -p chip, connection, ID/size/protection options for writing
        let canWriteTest: Bool        // EEPROM/flash: electrically erasable
        let writeTestNote: String     // why the write test isn't offered, when it isn't
        let buffer: Data?             // binary buffer of the same size, for "compare with buffer"
        let batteryBacked: Bool
    }

    typealias Runner = (_ title: String, _ args: [String], _ done: @escaping (Bool, String) -> Void) -> Void

    private let setup: Setup
    private let run: Runner
    private var retainSelf: ChipTestWindowController?
    private let report = NSTextView()
    private let stepLabel = NSTextField(labelWithString: "")
    private var startButton: NSButton!
    private var running = false
    private var stopRequested = false

    // SRAM options
    private let solidBox = NSButton(checkboxWithTitle: "All 00 and all FF (stuck bits)", target: nil, action: nil)
    private let checkerBox = NSButton(checkboxWithTitle: "55, AA and checkerboard (neighbouring bits)", target: nil, action: nil)
    private let addressBox = NSButton(checkboxWithTitle: "Address patterns (finds stuck or shorted address lines)", target: nil, action: nil)
    private let backupBox = NSButton(checkboxWithTitle: "Back up the contents first and write them back afterwards", target: nil, action: nil)
    // Memory options
    private let readsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let analyseBox = NSButton(checkboxWithTitle: "Analyse the contents (blank, stuck bits, repeated halves)", target: nil, action: nil)
    private let compareBox = NSButton(checkboxWithTitle: "Compare with the buffer", target: nil, action: nil)
    private let writeTestBox = NSButton(checkboxWithTitle: "Write test: 55, AA and address patterns – erases the chip, then writes the backup back", target: nil, action: nil)

    init(setup: Setup, run: @escaping Runner) {
        self.setup = setup
        self.run = run
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Chip Test – \(setup.chip)"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 520, height: 420)
        super.init(window: w)
        buildUI()
        w.center()
        retainSelf = self
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            self?.stopRequested = true
            self?.retainSelf = nil
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var digits: Int { BufferOps.addressDigits(for: setup.size) }
    private func addr(_ a: Int) -> String { ChipTests.hex(a, digits: digits) }

    // MARK: UI

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(labelWithString: setup.kind == .sram ? "SRAM test" : "EPROM / EEPROM / flash health check")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        let sizeText = setup.size >= 1024 ? "\(setup.size / 1024) KB" : "\(setup.size) bytes"
        let intro = NSTextField(wrappingLabelWithString: setup.kind == .sram
            ? "Writes test patterns to the \(sizeText) RAM and reads each one back, reporting every byte that differs and which data bits and address lines look faulty. This overwrites the RAM's contents."
            : "Reads the \(sizeText) chip several times to find unstable bits – a typical sign of a weak or ageing EPROM – and checks the contents for signs of bad pins or address lines. Reading doesn't change the chip.")
        intro.textColor = .secondaryLabelColor

        var options: [NSView] = []
        if setup.kind == .sram {
            [solidBox, checkerBox, addressBox].forEach { $0.state = .on }
            backupBox.state = setup.batteryBacked ? .on : .off
            if setup.batteryBacked { backupBox.title += " (recommended: battery-backed RAM keeps its data)" }
            options = [solidBox, checkerBox, addressBox, backupBox]
        } else {
            ["4", "16", "64", "256"].forEach { readsPopup.addItem(withTitle: $0) }
            readsPopup.selectItem(withTitle: "4")
            let readsRow = NSStackView(views: [NSTextField(labelWithString: "Read the chip"), readsPopup, NSTextField(labelWithString: "times and compare the reads")])
            readsRow.orientation = .horizontal
            analyseBox.state = .on
            compareBox.state = setup.buffer != nil ? .on : .off
            compareBox.isEnabled = setup.buffer != nil
            if setup.buffer == nil { compareBox.title += " (load a binary file of the same size first)" }
            writeTestBox.state = .off
            writeTestBox.isEnabled = setup.canWriteTest
            if !setup.canWriteTest { writeTestBox.title = "Write test (\(setup.writeTestNote))" }
            options = [readsRow, analyseBox, compareBox, writeTestBox]
        }

        startButton = NSButton(title: "Start Test", target: self, action: #selector(start(_:)))
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        let copy = NSButton(title: "Copy Report", target: self, action: #selector(copyReport(_:)))
        copy.bezelStyle = .rounded
        let save = NSButton(title: "Save Report…", target: self, action: #selector(saveReport(_:)))
        save.bezelStyle = .rounded
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .horizontal)
        stepLabel.textColor = .secondaryLabelColor
        stepLabel.lineBreakMode = .byTruncatingTail
        stepLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [stepLabel, spacer, copy, save, startButton])
        buttons.orientation = .horizontal

        report.isEditable = false
        report.font = NSFont.userFixedPitchFont(ofSize: 11)
        report.textContainerInset = NSSize(width: 6, height: 6)
        report.isVerticallyResizable = true
        report.autoresizingMask = [.width]
        report.textContainer?.widthTracksTextView = true
        report.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = report

        let views: [NSView] = [title, intro] + options + [buttons, scroll]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(12, after: intro)
        stack.setCustomSpacing(14, after: options.last ?? intro)
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        for v in [intro, buttons, scroll] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    private func say(_ s: String) {
        report.string += s + "\n"
        report.scrollToEndOfDocument(nil)
    }

    private func tempURL(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ChipBurner", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    @objc private func copyReport(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.string, forType: .string)
    }

    @objc private func saveReport(_ sender: Any?) {
        guard let w = window else { return }
        let p = NSSavePanel()
        p.nameFieldStringValue = setup.chip.replacingOccurrences(of: "@", with: "_") + "-test.txt"
        p.allowedFileTypes = ["txt"]
        p.beginSheetModal(for: w) { [weak self] r in
            guard let self = self, r == .OK, let url = p.url else { return }
            try? self.report.string.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Running

    /// One step of the test: a minipro call and what to do with its result.
    private struct Step {
        let title: String
        let args: [String]
        let after: (Bool, String) -> Bool    // false = stop the test
    }

    private var steps: [Step] = []
    private var stepIndex = 0
    private var failures = 0
    private var unstable = false
    /// Set once the write test has erased the chip, until the original contents are written back.
    private var pendingRestore: URL?

    @objc private func start(_ sender: Any?) {
        guard !running else { stopRequested = true; startButton.title = "Stopping…"; return }
        steps = setup.kind == .sram ? sramSteps() : memorySteps()
        guard !steps.isEmpty else { NSSound.beep(); return }
        report.string = ""
        failures = 0
        pendingRestore = nil
        stopRequested = false
        stepIndex = 0
        running = true
        startButton.title = "Stop"
        let f = DateFormatter()
        f.dateStyle = .medium; f.timeStyle = .medium
        say("ChipBurner chip test – \(setup.chip) – \(f.string(from: Date()))")
        say(String(repeating: "─", count: 60))
        next()
    }

    private func next() {
        guard !stopRequested else { finish(stopped: true); return }
        guard stepIndex < steps.count else { finish(stopped: false); return }
        let s = steps[stepIndex]
        stepLabel.stringValue = "Step \(stepIndex + 1) of \(steps.count): \(s.title)"
        run(s.title, s.args) { [weak self] ok, output in
            guard let self = self else { return }
            self.stepIndex += 1
            if s.after(ok, output) { self.next() } else { self.finish(stopped: false) }
        }
    }

    private func finish(stopped: Bool) {
        running = false
        startButton.title = "Start Test"
        stepLabel.stringValue = stopped ? "Stopped." : "Finished."
        say(String(repeating: "─", count: 60))
        if stopped {
            say("Test stopped before the end." + (setup.kind == .sram && backupBox.state == .on ? " The backup was NOT written back – it is still in the buffer file \(tempURL("test-backup.bin").path)." : ""))
        } else {
            say(failures == 0 ? "RESULT: PASSED – no faults found." : "RESULT: \(failures) problem(s) found – see above.")
        }
        if let backup = pendingRestore { reportUnrestored(backup) }
        pendingRestore = nil
    }

    /// The write test erased the chip but its original contents weren't written back: keep them safe and say where.
    private func reportUnrestored(_ backup: URL) {
        guard let data = try? Data(contentsOf: backup) else {
            say("⚠ The original contents were NOT written back, and the backup could not be found.")
            return
        }
        if data.allSatisfy({ $0 == 0xFF }) {
            say("The chip was blank before the test, so nothing was lost – it is now erased or partly written.")
            return
        }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ChipBurner", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"
        let safe = setup.chip.replacingOccurrences(of: "@", with: "_").replacingOccurrences(of: "/", with: "_")
        let keep = dir.appendingPathComponent("\(safe)-backup-\(f.string(from: Date())).bin")
        if (try? data.write(to: keep)) != nil {
            say("⚠ The original contents were NOT written back. They are saved in \(keep.path) – open that file and Program the chip to restore them.")
        } else {
            say("⚠ The original contents were NOT written back. The backup is in \(backup.path) until the next test – open it and Program the chip to restore them.")
        }
    }

    private func minipro(_ ok: Bool, _ out: String, _ what: String) -> Bool {
        if !ok {
            failures += 1
            say("✗ \(what) failed – minipro said:")
            out.components(separatedBy: .newlines).filter { !$0.isEmpty && !$0.contains("overridden database") }.suffix(6).forEach { say("    " + $0) }
            if out.contains("LIBUSB_ERROR") || out.contains("IO error") {
                say("  The programmer stopped answering over USB in the middle of the operation. Unplug it and plug it in again,")
                say("  preferably straight into the Mac rather than through a hub, then check the chip's seating and try again.")
            }
        }
        return ok
    }

    private func describe(_ r: ChipTests.CompareResult, _ label: String) {
        if r.ok { say("✓ \(label): every byte correct."); return }
        failures += 1
        if r.sizeMismatch { say("✗ \(label): the read size differs from the chip size.") }
        if r.badBytes > 0 {
            say("✗ \(label): \(r.badBytes) wrong byte(s); faulty bits: \(ChipTests.bitList(r.badBits)).")
            for m in r.samples { say(String(format: "    %@: wrote %02X, read %02X", addr(m.address), m.expected, m.got)) }
            if r.badBytes > r.samples.count { say("    … and \(r.badBytes - r.samples.count) more") }
            if !r.addressLineSuspects.isEmpty {
                say("    Address line(s) \(r.addressLineSuspects.map { "A\($0)" }.joined(separator: ", ")) look stuck or shorted: bytes read back the value written one address-bit away.")
            }
        }
    }

    // MARK: SRAM

    private func sramSteps() -> [Step] {
        var patterns: [ChipTests.Pattern] = []
        if solidBox.state == .on { patterns += [.zeros, .ones] }
        if checkerBox.state == .on { patterns += [.x55, .xAA, .checker] }
        if addressBox.state == .on { patterns += ChipTests.Pattern.addressPatterns(for: setup.size) }
        guard !patterns.isEmpty else { return [] }
        let size = setup.size
        var steps: [Step] = []
        let backup = tempURL("test-backup.bin")
        if backupBox.state == .on {
            try? FileManager.default.removeItem(at: backup)
            steps.append(Step(title: "Back up contents", args: setup.readArgs + ["-r", backup.path]) { [unowned self] ok, out in
                guard self.minipro(ok, out, "Backup read") else { self.say("  Test not started, so nothing was overwritten."); return false }
                self.say("✓ Contents backed up (\(size) bytes).")
                return true
            })
        }
        for p in patterns {
            let file = tempURL("test-\(p).bin"), back = tempURL("test-\(p)-read.bin")
            let data = p.data(count: size)
            steps.append(Step(title: "Write \(p.rawValue)", args: setup.writeArgs + ["-w", file.path, "-v", "-e"]) { [unowned self] ok, out in
                self.minipro(ok, out, "Writing \(p.rawValue)")
            })
            steps.append(Step(title: "Read back \(p.rawValue)", args: setup.readArgs + ["-r", back.path]) { [unowned self] ok, out in
                guard self.minipro(ok, out, "Reading back \(p.rawValue)"), let got = try? Data(contentsOf: back) else { return false }
                self.describe(ChipTests.compare(expected: data, got: got, pattern: p), p.rawValue)
                return true
            })
            try? data.write(to: file)
        }
        if backupBox.state == .on {
            steps.append(Step(title: "Write the backup back", args: setup.writeArgs + ["-w", backup.path, "-e"]) { [unowned self] ok, out in
                if self.minipro(ok, out, "Writing the backup back") { self.say("✓ Original contents written back and verified.") }
                return true
            })
        }
        return steps
    }

    // MARK: EPROM / EEPROM / flash

    private func memorySteps() -> [Step] {
        let size = setup.size
        let n = Int(readsPopup.titleOfSelectedItem ?? "4") ?? 4
        var steps: [Step] = []
        // Read 1 is kept (the backup for the write test); later reads are compared with it and deleted at once.
        let first = tempURL("health-read-1.bin"), next = tempURL("health-read-next.bin")
        try? FileManager.default.removeItem(at: first)
        var acc: ChipTests.StabilityAccumulator?
        for i in 1...n {
            let url = i == 1 ? first : next
            steps.append(Step(title: "Read \(i) of \(n)", args: setup.readArgs + ["-r", url.path]) { [unowned self] ok, out in
                guard self.minipro(ok, out, "Read \(i)") else { return false }
                guard let data = try? Data(contentsOf: url) else { self.failures += 1; self.say("✗ Could not load read \(i)."); return false }
                if i == 1 { acc = ChipTests.StabilityAccumulator(base: data) }
                else { acc?.add(data); try? FileManager.default.removeItem(at: url) }
                if i == n, let acc = acc {
                    self.afterReads(acc)
                    if self.unstable && self.writeTestBox.isEnabled && self.writeTestBox.state == .on {
                        self.say("Write test skipped: the reads weren't identical, so the backup of the contents can't be trusted.")
                        return false
                    }
                }
                return true
            })
        }
        if writeTestBox.isEnabled && writeTestBox.state == .on {
            let backup = first
            for p in [ChipTests.Pattern.x55, .xAA] + ChipTests.Pattern.addressPatterns(for: size) {
                let file = tempURL("health-\(p).bin"), back = tempURL("health-\(p)-read.bin")
                let data = p.data(count: size)
                try? data.write(to: file)
                steps.append(Step(title: "Write test: \(p.rawValue)", args: setup.writeArgs + ["-w", file.path, "-v"]) { [unowned self] ok, out in
                    // from here on the chip has been erased: its contents are only in the backup
                    if self.pendingRestore == nil { self.pendingRestore = backup }
                    return self.minipro(ok, out, "Writing \(p.rawValue)")
                })
                steps.append(Step(title: "Read back \(p.rawValue)", args: setup.readArgs + ["-r", back.path]) { [unowned self] ok, out in
                    guard self.minipro(ok, out, "Reading back \(p.rawValue)"), let got = try? Data(contentsOf: back) else { return false }
                    self.describe(ChipTests.compare(expected: data, got: got, pattern: p), "Write test \(p.rawValue)")
                    return true
                })
            }
            steps.append(Step(title: "Write the original contents back", args: setup.writeArgs + ["-w", backup.path]) { [unowned self] ok, out in
                if self.minipro(ok, out, "Writing the original contents back") {
                    self.say("✓ Original contents written back and verified.")
                    self.pendingRestore = nil
                }
                return true
            })
        }
        return steps
    }

    private func afterReads(_ acc: ChipTests.StabilityAccumulator) {
        let first = Data(acc.base)
        let st = acc.result()
        unstable = !st.ok
        if st.ok {
            say("✓ \(acc.reads) reads are identical – no unstable bits.")
        } else {
            failures += 1
            say("✗ \(st.unstableBytes) byte(s) read differently between the \(acc.reads) reads; unstable bits: \(ChipTests.bitList(st.unstableBits)).")
            say("  This is typical of a weak, ageing or partly erased EPROM, or of poor socket contact.")
            for s in st.counts { say("    \(addr(s.address)): " + s.counts.map { String(format: "%02X ×%d", $0.value, $0.count) }.joined(separator: "  ")) }
        }
        if analyseBox.state == .on {
            say("Contents:")
            ChipTests.hints(ChipTests.analyse(first)).forEach { say("  • " + $0) }
            say(String(format: "  • Sum 0x%04X, CRC32 0x%08X", Checksums.sum16(first), Checksums.crc32(first)))
        }
        if compareBox.state == .on, let b = setup.buffer {
            describe(ChipTests.compare(expected: b, got: first, pattern: nil), "Compared with the buffer")
        }
    }
}
