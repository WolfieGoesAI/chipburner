import Cocoa

/// Editor for custom logic test vectors (and for GAL functional tests generated from a .jed).
/// Runs them with minipro's logic tester through a temporary logicic.xml.
final class LogicVectorWindowController: NSWindowController, NSTextViewDelegate {
    typealias Runner = (_ title: String, _ args: [String], _ logicic: URL, _ done: @escaping (Bool, String) -> Void) -> Void

    private let run: Runner
    private var retainSelf: LogicVectorWindowController?
    private let nameField = NSTextField()
    private let pinsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let voltPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let editor = NSTextView()
    private let resultView = NSTextView()
    private let status = NSTextField(labelWithString: "")
    private var fileURL: URL?

    init(test: LogicTest, title: String, notes: [String], run: @escaping Runner) {
        self.run = run
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 660),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 600, height: 460)
        super.init(window: w)
        buildUI()
        load(test)
        if !notes.isEmpty { resultView.string = notes.map { "• " + $0 }.joined(separator: "\n") + "\n" }
        w.center()
        retainSelf = self
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            self?.retainSelf = nil
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    static let help = """
        ; One test vector per line, one character per pin (pin 1 first). Spaces are optional, ';' starts a comment.
        ;   0 1  drive the pin low/high      L H  expect low/high      Z  expect high impedance
        ;   C    one clock pulse on the pin  X    don't care           G V  ground / supply
        """

    // MARK: UI

    private func buildUI() {
        guard let content = window?.contentView else { return }
        func label(_ s: String) -> NSTextField { NSTextField(labelWithString: s) }
        nameField.widthAnchor.constraint(equalToConstant: 160).isActive = true
        LogicTest.pinCounts.forEach { pinsPopup.addItem(withTitle: "\($0)") }
        LogicTest.voltages.forEach { voltPopup.addItem(withTitle: $0) }
        let top = NSStackView(views: [label("Name:"), nameField, label("Pins:"), pinsPopup, label("Supply:"), voltPopup])
        top.orientation = .horizontal

        for tv in [editor, resultView] {
            tv.isRichText = false
            tv.font = NSFont.userFixedPitchFont(ofSize: 12)
            tv.textContainerInset = NSSize(width: 6, height: 6)
            tv.isVerticallyResizable = true
            tv.isHorizontallyResizable = true
            tv.autoresizingMask = [.width]
            tv.textContainer?.widthTracksTextView = false
            tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            tv.isAutomaticQuoteSubstitutionEnabled = false
            tv.isAutomaticTextReplacementEnabled = false
        }
        editor.allowsUndo = true
        editor.delegate = self
        resultView.isEditable = false
        func scroller(_ tv: NSTextView) -> NSScrollView {
            let s = NSScrollView()
            s.hasVerticalScroller = true
            s.hasHorizontalScroller = true
            s.borderType = .bezelBorder
            s.documentView = tv
            return s
        }
        let edScroll = scroller(editor), resScroll = scroller(resultView)

        func b(_ t: String, _ s: Selector) -> NSButton {
            let x = NSButton(title: t, target: self, action: s)
            x.bezelStyle = .rounded
            return x
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .horizontal)
        let runB = b("Run Test", #selector(runTest(_:)))
        runB.keyEquivalent = "\r"
        runB.keyEquivalentModifierMask = [.command]
        let buttons = NSStackView(views: [b("From Database…", #selector(loadFromDatabase(_:))), b("Open…", #selector(open(_:))),
                                          b("Save…", #selector(save(_:))), spacer, b("Check", #selector(check(_:))), runB])
        buttons.orientation = .horizontal
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(edScroll)
        split.addArrangedSubview(resScroll)

        let stack = NSStackView(views: [top, buttons, split, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        for v in [buttons, split, status] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        split.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        split.setContentHuggingPriority(.defaultLow, for: .vertical)
        resScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        edScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
    }

    private func setStatus(_ s: String, error: Bool) {
        status.stringValue = s
        status.textColor = error ? .systemRed : .secondaryLabelColor
    }

    private func load(_ t: LogicTest) {
        nameField.stringValue = t.name
        pinsPopup.selectItem(withTitle: "\(t.pins)")
        if pinsPopup.indexOfSelectedItem < 0 { pinsPopup.selectItem(withTitle: "16") }
        voltPopup.selectItem(withTitle: t.voltage)
        if voltPopup.indexOfSelectedItem < 0 { voltPopup.selectItem(withTitle: "5V") }
        editor.string = Self.help + "\n" + (t.vectors.isEmpty ? "" : t.vectorText())
        editor.undoManager?.removeAllActions()
        setStatus("\(t.vectors.count) vector(s), \(t.pins) pins.", error: false)
    }

    private var current: LogicTest {
        LogicTest(name: nameField.stringValue.isEmpty ? "CUSTOM" : nameField.stringValue,
                  pins: Int(pinsPopup.titleOfSelectedItem ?? "16") ?? 16,
                  voltage: voltPopup.titleOfSelectedItem ?? "5V",
                  vectors: LogicTest.parseVectors(editor.string.components(separatedBy: .newlines)
                      .map { l -> String in
                          // Strip the "0003" vector numbers the editor shows in front of each vector.
                          let t = l.trimmingCharacters(in: .whitespaces)
                          if let r = t.range(of: "^\\d{4}\\s+", options: .regularExpression) { return String(t[r.upperBound...]) }
                          return l
                      }.joined(separator: "\n")))
    }

    // MARK: Actions

    @discardableResult
    @objc private func check(_ sender: Any?) -> Bool {
        let p = current.problems()
        if p.isEmpty { setStatus("\(current.vectors.count) vector(s) – no problems found.", error: false); return true }
        setStatus(p.first!, error: true)
        resultView.string = "Problems:\n" + p.map { "  • " + $0 }.joined(separator: "\n") + "\n"
        NSSound.beep()
        return false
    }

    @objc private func runTest(_ sender: Any?) {
        guard check(nil) else { return }
        let t = current
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ChipBurner", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("custom-logicic.xml")
        do { try t.xml().write(to: url, atomically: true, encoding: .utf8) } catch {
            setStatus("Could not write the test file.", error: true); return
        }
        resultView.string = "Running \(t.vectors.count) vector(s) on \(t.safeName)…\n"
        setStatus("Testing – put the chip in the socket bottom-aligned, pin 1 at the lever end.", error: false)
        run("Logic test \(t.safeName)", ["-p", t.safeName, "-T"], url) { [weak self] ok, output in
            guard let self = self else { return }
            let r = LogicTest.parseResult(output)
            var s = r.table.joined(separator: "\n") + "\n\n"
            if r.passed && ok {
                s += "RESULT: PASSED – all \(t.vectors.count) vectors matched."
                self.setStatus("Passed.", error: false)
            } else if !r.failingVectors.isEmpty {
                s += "RESULT: FAILED – \(r.errors) wrong pin state(s) in vector(s) " + r.failingVectors.prefix(20).map { String(format: "%04d", $0) }.joined(separator: ", ") + (r.failingVectors.count > 20 ? " …" : "") + ".\nPins marked with '-' didn't have the expected level."
                self.setStatus("Failed – see the marked pins.", error: true)
            } else {
                s += "The test didn't run. minipro said:\n" + output.components(separatedBy: .newlines).filter { !$0.contains("overridden database") }.suffix(8).joined(separator: "\n")
                self.setStatus("The test didn't run.", error: true)
            }
            self.resultView.string = s
        }
    }

    @objc private func loadFromDatabase(_ sender: Any?) {
        guard let w = window else { return }
        let names = ChipDatabase.shared.names(of: .logic, programmer: "")
        let picker = ChipSearchController(title: "Start from a logic chip's test vectors", results: names) { [weak self] name in
            guard let self = self, let name = name, let url = Minipro.shared.logicic,
                  let text = try? String(contentsOf: url), var t = LogicTest.parseXML(text, name: name) else { return }
            t.name = name + "_MOD"
            self.load(t)
        }
        picker.present(on: w)
    }

    @objc private func open(_ sender: Any?) {
        guard let w = window else { return }
        let p = NSOpenPanel()
        p.allowedFileTypes = ["xml", "txt", "vec"]
        p.beginSheetModal(for: w) { [weak self] r in
            guard let self = self, r == .OK, let url = p.url, let text = try? String(contentsOf: url) else { return }
            if let t = LogicTest.parseXML(text) { self.load(t) } else { self.editor.string = text }
            self.fileURL = url
        }
    }

    @objc private func save(_ sender: Any?) {
        guard let w = window else { return }
        let t = current
        let p = NSSavePanel()
        p.nameFieldStringValue = fileURL?.lastPathComponent ?? (t.safeName.lowercased() + "-logicic.xml")
        p.allowedFileTypes = ["xml"]
        p.message = "Saved in minipro's logicic.xml format, usable with minipro --logicic too."
        p.beginSheetModal(for: w) { [weak self] r in
            guard let self = self, r == .OK, let url = p.url else { return }
            do { try t.xml().write(to: url, atomically: true, encoding: .utf8); self.fileURL = url; self.setStatus("Saved \(url.lastPathComponent).", error: false) }
            catch { self.setStatus("Could not save: \(error.localizedDescription)", error: true) }
        }
    }
}
