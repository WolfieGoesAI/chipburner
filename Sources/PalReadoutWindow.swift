import Cocoa

/// PAL readout → GAL clone: reads a combinatorial PAL's complete truth table with the logic tester
/// and builds a pin-compatible GAL16V8 fuse map from it.
final class PalReadoutWindowController: NSWindowController {
    typealias Runner = (_ title: String, _ args: [String], _ logicic: URL, _ done: @escaping (Bool, String) -> Void) -> Void

    var onLoadJED: ((String, String) -> Void)?
    var onOpenSource: ((String) -> Void)?

    private let run: Runner
    private var retainSelf: PalReadoutWindowController?
    private let typePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let pinLabel = NSTextField(wrappingLabelWithString: "")
    private let twiceBox = NSButton(checkboxWithTitle: "Read twice and compare (finds bad contacts)", target: nil, action: nil)
    private let report = NSTextView()
    private let progress = NSProgressIndicator()
    private var startButton: NSButton!
    private var resultButtons: [NSButton] = []
    private var clone: PalReadout.Clone?
    private var table: [UInt16] = []
    private var running = false
    private var stopRequested = false

    init(run: @escaping Runner) {
        self.run = run
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 600),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "PAL Readout → GAL Clone"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 560, height: 460)
        super.init(window: w)
        buildUI()
        typeChanged(nil)
        w.center()
        retainSelf = self
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            self?.stopRequested = true
            self?.retainSelf = nil
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var type: PalReadout.PalType { PalReadout.types[max(0, typePopup.indexOfSelectedItem)] }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let intro = NSTextField(wrappingLabelWithString: "Small bipolar PALs can't be read or programmed by the TL866A, but the combinatorial ones can be read out through the logic tester: every input combination is applied and the outputs recorded. ChipBurner then works out the logic and builds a fuse map for a pin-compatible GAL16V8 that does the same.")
        intro.textColor = .secondaryLabelColor
        PalReadout.types.forEach { typePopup.addItem(withTitle: $0.name) }
        typePopup.target = self
        typePopup.action = #selector(typeChanged(_:))
        let typeRow = NSStackView(views: [NSTextField(labelWithString: "PAL type:"), typePopup])
        typeRow.orientation = .horizontal
        pinLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let warn = NSTextField(wrappingLabelWithString: "Pick the type printed on the chip (PAL10H8 and PAL10L8 share a pinout, and so on). With the wrong type the tester would drive pins that are PAL outputs. Registered PALs (PAL16R4/R6/R8) can't be read this way.")
        warn.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        warn.textColor = .systemOrange
        twiceBox.state = .on

        startButton = NSButton(title: "Start Readout", target: self, action: #selector(start(_:)))
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        progress.isIndeterminate = false
        progress.minValue = 0; progress.maxValue = 100
        progress.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .horizontal)
        let runRow = NSStackView(views: [twiceBox, spacer, progress, startButton])
        runRow.orientation = .horizontal

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

        func b(_ t: String, _ s: Selector) -> NSButton {
            let x = NSButton(title: t, target: self, action: s)
            x.bezelStyle = .rounded
            x.isEnabled = false
            return x
        }
        resultButtons = [b("Load GAL .jed into Buffer", #selector(loadJED(_:))), b("Open Source in PLD Editor", #selector(openSource(_:))),
                         b("Show Equations", #selector(showEquations(_:))), b("Save Truth Table…", #selector(saveTable(_:)))]
        let results = NSStackView(views: resultButtons)
        results.orientation = .horizontal

        let views: [NSView] = [intro, typeRow, pinLabel, warn, runRow, scroll, results]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        for v in [intro, pinLabel, warn, runRow, scroll] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    @objc private func typeChanged(_ sender: Any?) {
        let t = type
        let combos = 1 << t.inputs.count
        pinLabel.stringValue = "\(t.note): inputs on pins \(t.inputs.map(String.init).joined(separator: ", ")); outputs on pins \(t.outputs.map(String.init).joined(separator: ", ")); GND 10, VCC 20. \(combos) input combinations, read in \(max(1, combos / PalReadout.chunk)) step(s)."
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

    // MARK: Readout

    @objc private func start(_ sender: Any?) {
        if running { stopRequested = true; startButton.title = "Stopping…"; return }
        let t = type
        report.string = ""
        clone = nil
        resultButtons.forEach { $0.isEnabled = false }
        running = true
        stopRequested = false
        startButton.title = "Stop"
        typePopup.isEnabled = false
        say("Reading \(t.name): \(1 << t.inputs.count) input combinations\(twiceBox.state == .on ? ", twice" : "").")
        readPass(t, pass: 1) { [weak self] first in
            guard let self = self, let first = first else { self?.finish(); return }
            guard self.twiceBox.state == .on else { self.analyse(t, first); return }
            self.readPass(t, pass: 2) { second in
                guard let second = second else { self.finish(); return }
                let diff = zip(first, second).enumerated().filter { $0.element.0 != $0.element.1 }.map { $0.offset }
                if !diff.isEmpty {
                    self.say("✗ The two readouts differ in \(diff.count) combination(s) (first at \(diff[0])). Check that the chip is seated well and is the selected type, then try again.")
                    self.finish(); return
                }
                self.say("✓ Both readouts are identical.")
                self.analyse(t, first)
            }
        }
    }

    private func readPass(_ t: PalReadout.PalType, pass: Int, done: @escaping ([UInt16]?) -> Void) {
        let total = 1 << t.inputs.count
        var rows: [UInt16] = []
        func step(_ start: Int) {
            if stopRequested { say("Stopped."); done(nil); return }
            if start >= total { done(rows); return }
            let end = min(total, start + PalReadout.chunk)
            let test = LogicTest(name: "PALREAD", pins: PalReadout.pins, voltage: "5V", vectors: PalReadout.vectors(t, range: start..<end))
            let url = tempURL("pal-readout.xml")
            do { try test.xml().write(to: url, atomically: true, encoding: .utf8) } catch { say("✗ Could not write a temporary file."); done(nil); return }
            progress.doubleValue = (Double(pass - 1) * Double(total) + Double(start)) / Double(total * (twiceBox.state == .on ? 2 : 1)) * 100
            let resultURL = tempURL("pal-readout-result.xml")
            try? FileManager.default.removeItem(at: resultURL)
            run("PAL readout pass \(pass): \(start)–\(end - 1)", ["-p", test.safeName, "-T", "--logicic_out", resultURL.path], url) { [weak self] _, output in
                guard let self = self else { return }
                // minipro writes the measured pin levels of every vector to the result file; the
                // printed table (only produced without --logicic_out) is the fallback.
                let fromFile = (try? String(contentsOf: resultURL)).flatMap { PalReadout.parseResultFile($0, type: t, expected: end - start) }
                guard let part = fromFile ?? PalReadout.parseTable(output, type: t, expected: end - start) else {
                    self.say("✗ The logic tester didn't return a complete table. minipro said:")
                    output.components(separatedBy: .newlines).filter { !$0.isEmpty && !$0.contains("overridden database") && $0.range(of: "^\\s*\\d{4}:", options: .regularExpression) == nil }.suffix(6).forEach { self.say("    " + $0) }
                    if let xml = try? String(contentsOf: resultURL) {
                        self.say("    (result file: \(LogicTest.parseXML(xml)?.vectors.count ?? 0) of \(end - start) vectors)")
                    }
                    done(nil); return
                }
                rows += part
                step(end)
            }
        }
        step(0)
    }

    private func analyse(_ t: PalReadout.PalType, _ rows: [UInt16]) {
        table = rows
        progress.doubleValue = 100
        let allSame = Set(rows).count == 1
        if allSame {
            say("⚠ Every input combination gives the same outputs (\(String(rows[0], radix: 2))). The chip may be missing, in the wrong way round, unpowered, or not this type.")
        }
        do {
            let c = try PalReadout.makeClone(t, table: rows, palName: t.name.components(separatedBy: " ").first ?? "PAL")
            clone = c
            say("✓ Logic worked out and a GAL16V8 fuse map built; it reproduces all \(rows.count) readout rows.")
            say("")
            say("Equations (I = input pin, O = output pin, / = NOT, * = AND, + = OR):")
            c.equations.forEach { say("  " + $0) }
            c.notes.forEach { say("  • " + $0) }
            say("")
            say("Program a GAL16V8 (or ATF16V8B) with it: Load GAL .jed into Buffer, select the GAL, then Program.")
            resultButtons.forEach { $0.isEnabled = true }
        } catch {
            say("✗ \(error)")
            resultButtons.last?.isEnabled = true
        }
        finish()
    }

    private func finish() {
        running = false
        startButton.title = "Start Readout"
        typePopup.isEnabled = true
    }

    // MARK: Results

    private var baseName: String { (type.name.components(separatedBy: " ").first ?? "pal").lowercased() + "-clone" }

    @objc private func loadJED(_ sender: Any?) { if let c = clone { onLoadJED?(c.jedec, baseName + ".jed") } }
    @objc private func openSource(_ sender: Any?) { if let c = clone { onOpenSource?(c.source) } }

    @objc private func showEquations(_ sender: Any?) {
        guard let c = clone else { return }
        GalDecoderWindowController.show(jedText: c.jedec, sourceName: baseName + ".jed", chipHint: "GAL16V8",
                                        on: window, pinNames: GalAssembler.pinNames(c.source))
    }

    @objc private func saveTable(_ sender: Any?) {
        guard let w = window, !table.isEmpty else { return }
        let t = type
        var csv = (t.inputs.map { "I\($0)" } + t.outputs.map { "O\($0)" }).joined(separator: ",") + "\n"
        for (k, row) in table.enumerated() {
            let ins = (0..<t.inputs.count).map { (k >> $0) & 1 == 1 ? "1" : "0" }
            let outs = (0..<t.outputs.count).map { row & (1 << UInt16($0)) != 0 ? "1" : "0" }
            csv += (ins + outs).joined(separator: ",") + "\n"
        }
        let p = NSSavePanel()
        p.nameFieldStringValue = baseName.replacingOccurrences(of: "-clone", with: "") + "-truth-table.csv"
        p.allowedFileTypes = ["csv"]
        p.beginSheetModal(for: w) { r in
            guard r == .OK, let url = p.url else { return }
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
