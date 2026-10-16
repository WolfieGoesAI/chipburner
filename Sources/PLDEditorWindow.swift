import Cocoa

/// Editor for galasm-style PLD source: assemble it into a .jed (into the main buffer or a file),
/// and check the result by decoding it straight back into equations.
final class PLDEditorWindowController: NSWindowController, NSTextViewDelegate {
    /// Called with (jedec text, file name, chip type) when the user loads the result into the buffer.
    var onLoadIntoBuffer: ((String, String, String) -> Void)?

    private let textView = NSTextView()
    private let status = NSTextField(labelWithString: "")
    private var fileURL: URL?
    private var edited = false { didSet { updateTitle() } }
    private var retainSelf: PLDEditorWindowController?

    init(source: String, fileURL: URL?) {
        self.fileURL = fileURL
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.minSize = NSSize(width: 520, height: 320)
        w.isReleasedWhenClosed = false
        super.init(window: w)
        buildUI()
        textView.string = source
        textView.undoManager?.removeAllActions()
        updateTitle()
        w.center()
        retainSelf = self
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            self?.retainSelf = nil
        }
        setStatus("Assemble checks the source and makes a .jed fuse map.", error: false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func updateTitle() {
        window?.title = (fileURL?.lastPathComponent ?? "Untitled.pld") + (edited ? " – edited" : "") + " – PLD Source"
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = NSFont.userFixedPitchFont(ofSize: 12)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = self
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = textView

        func b(_ t: String, _ s: Selector) -> NSButton {
            let x = NSButton(title: t, target: self, action: s)
            x.bezelStyle = .rounded
            return x
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .horizontal)
        let assemble = b("Assemble → Buffer", #selector(assembleToBuffer(_:)))
        assemble.keyEquivalent = "\r"
        assemble.keyEquivalentModifierMask = [.command]
        let buttons = NSStackView(views: [b("Open…", #selector(openSource(_:))), b("Save", #selector(saveSource(_:))),
                                          b("Save As…", #selector(saveSourceAs(_:))), spacer,
                                          b("Check", #selector(check(_:))), b("Show Equations", #selector(showEquations(_:))),
                                          b("Save .jed…", #selector(saveJED(_:))), assemble])
        buttons.orientation = .horizontal
        status.lineBreakMode = .byTruncatingTail
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [buttons, scroll, status])
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
        for v in [buttons, scroll, status] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    func textDidChange(_ notification: Notification) { edited = true }

    private func setStatus(_ s: String, error: Bool) {
        status.stringValue = s
        status.textColor = error ? .systemRed : .secondaryLabelColor
    }

    /// Assembles the source; on error shows the message and selects the offending line.
    private func assemble() -> (chip: GalAssembler.Chip, jedec: String)? {
        do {
            let r = try GalAssembler.assemble(textView.string)
            setStatus("Assembled for \(r.chip.rawValue) – no errors.", error: false)
            return r
        } catch let e as GalAssembler.AsmError {
            setStatus(e.description, error: true)
            selectLine(e.line)
            NSSound.beep()
            return nil
        } catch {
            setStatus("\(error)", error: true)
            return nil
        }
    }

    private func selectLine(_ n: Int) {
        guard n > 0 else { return }
        let ns = textView.string as NSString
        var start = 0, line = 1
        while line < n && start < ns.length {
            let r = ns.lineRange(for: NSRange(location: start, length: 0))
            start = NSMaxRange(r); line += 1
        }
        guard start <= ns.length else { return }
        let r = ns.lineRange(for: NSRange(location: min(start, ns.length), length: 0))
        textView.setSelectedRange(r)
        textView.scrollRangeToVisible(r)
        window?.makeFirstResponder(textView)
    }

    private var jedName: String {
        ((fileURL?.deletingPathExtension().lastPathComponent) ?? "untitled") + ".jed"
    }

    @objc private func check(_ sender: Any?) { _ = assemble() }

    @objc private func assembleToBuffer(_ sender: Any?) {
        guard let r = assemble() else { return }
        onLoadIntoBuffer?(r.jedec, jedName, r.chip.rawValue)
        setStatus("Assembled for \(r.chip.rawValue) and loaded into the buffer as \(jedName) – ready to program.", error: false)
    }

    @objc private func showEquations(_ sender: Any?) {
        guard let r = assemble() else { return }
        GalDecoderWindowController.show(jedText: r.jedec, sourceName: jedName, chipHint: r.chip.rawValue,
                                        on: window, pinNames: GalAssembler.pinNames(textView.string))
    }

    @objc private func saveJED(_ sender: Any?) {
        guard let w = window, let r = assemble() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = jedName
        panel.allowedFileTypes = ["jed"]
        panel.beginSheetModal(for: w) { [weak self] resp in
            guard let self = self, resp == .OK, let url = panel.url else { return }
            do {
                try r.jedec.write(to: url, atomically: true, encoding: .ascii)
                self.setStatus("Saved \(url.lastPathComponent).", error: false)
            } catch { self.setStatus("Could not save: \(error.localizedDescription)", error: true) }
        }
    }

    @objc private func openSource(_ sender: Any?) {
        guard let w = window else { return }
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["pld", "PLD", "txt"]
        panel.beginSheetModal(for: w) { [weak self] resp in
            guard let self = self, resp == .OK, let url = panel.url,
                  let data = try? Data(contentsOf: url) else { return }
            self.textView.string = String(decoding: data, as: UTF8.self)
            self.textView.undoManager?.removeAllActions()
            self.fileURL = url
            self.edited = false
            self.setStatus("Opened \(url.lastPathComponent).", error: false)
        }
    }

    @objc private func saveSource(_ sender: Any?) {
        guard let url = fileURL else { saveSourceAs(sender); return }
        write(to: url)
    }

    @objc private func saveSourceAs(_ sender: Any?) {
        guard let w = window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "untitled.pld"
        panel.allowedFileTypes = ["pld"]
        panel.beginSheetModal(for: w) { [weak self] resp in
            guard let self = self, resp == .OK, let url = panel.url else { return }
            self.write(to: url)
        }
    }

    private func write(to url: URL) {
        do {
            try textView.string.write(to: url, atomically: true, encoding: .utf8)
            fileURL = url
            edited = false
            setStatus("Saved \(url.lastPathComponent).", error: false)
        } catch { setStatus("Could not save: \(error.localizedDescription)", error: true) }
    }
}
