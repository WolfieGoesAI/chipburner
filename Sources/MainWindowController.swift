import Cocoa

final class MainWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSTextViewDelegate {

    // MARK: State
    private var buffer = Data()
    private var bufferName = "empty"
    /// Text buffers hold JEDEC fuse maps (.jed) or fuse/config files (.conf) instead of raw bytes.
    private var bufferIsText = false
    private var bufferExt = "bin"
    private var running: Process?
    private var scanCancelled = false
    private var logWindow: NSWindow?
    private let connectionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let voltageLabel = NSTextField(labelWithString: "chip defaults")
    private var voltages = VoltageOverrides()
    private var voltagesChip = ""
    private var caps: [String: ChipCapabilities] = [:]   // "PROGRAMMER:CHIP" -> what minipro -d reports
    private var capsPending = Set<String>()
    private(set) var isBusy = false { didSet { updateEnabledState() } }

    // MARK: Views
    private let programmerLabel = NSTextField(labelWithString: "Not checked yet")
    private let chipField = NSTextField()
    /// The chip description; no longer shown as a line, it's the chip field's tooltip.
    private let chipInfoLabel = NSTextField(labelWithString: "")
    private let bufferLabel = NSTextField(labelWithString: "Buffer: empty")
    private var programmerModel: String?
    private var compareWindow: CompareWindowController?
    /// "TL866A – Serial … – Firmware …", shown in the Hardware… dialog (the main window shows the model only).
    private var programmerDetails: String?
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let progress = NSProgressIndicator()
    private let hexEditor = HexEditorView()
    private let textEditor = MainWindowController.makeTextView()
    private var textScroll: NSScrollView!
    private var bufferEdited = false
    private var lastFindPattern = ""
    private let selectionLabel = NSTextField(labelWithString: "")
    private var labelUpdatePending = false
    private let logView = MainWindowController.makeTextView()
    private let memoryPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    private var actionButtons: [NSButton] = []
    private var stopButton: NSButton!
    private var eraseButton: NSButton!
    private lazy var configButton: NSButton = button("Fuses & Locks…", #selector(openConfigWindow(_:)))
    private lazy var chipTestButton: NSButton = button("Chip Test…", #selector(openChipTest(_:)))
    private lazy var logicTestButton: NSButton = button("Logic Test…", #selector(showLogicTestMenu(_:)))
    private let skipID = NSButton(checkboxWithTitle: "Skip chip ID check", target: nil, action: nil)
    private let allowSize = NSButton(checkboxWithTitle: "Allow file size mismatch", target: nil, action: nil)
    private let skipErase = NSButton(checkboxWithTitle: "Don't erase before programming", target: nil, action: nil)
    private let skipVerify = NSButton(checkboxWithTitle: "Don't verify after programming", target: nil, action: nil)
    private let unprotect = NSButton(checkboxWithTitle: "Unprotect before writing", target: nil, action: nil)
    private let protectAfter = NSButton(checkboxWithTitle: "Protect after writing", target: nil, action: nil)
    private let settingsLabel = NSTextField(labelWithString: "")
    /// Checkbox, UserDefaults key, short name for the summary next to Settings….
    private var settingBoxes: [(box: NSButton, key: String, short: String)] {
        [(skipID, "skipID", "skip ID check"), (allowSize, "allowSize", "allow size mismatch"),
         (skipErase, "skipErase", "no erase before write"), (skipVerify, "skipVerify", "no verify"),
         (unprotect, "unprotect", "unprotect"), (protectAfter, "protectAfter", "protect after write")]
    }

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
        self.init(window: window)
        window.delegate = self
        buildUI()
        // Start at the smallest size the layout allows (the size you get by dragging the corner
        // all the way in); that is also the minimum.
        // Text that changes (buffer name, chip description …) truncates instead of widening the window.
        for l in [bufferLabel, chipInfoLabel, voltageLabel, settingsLabel, statusLabel, programmerLabel] {
            l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        // Ask for a tiny window and let Auto Layout grow it to what the controls need.
        if let content = window.contentView {
            window.setContentSize(NSSize(width: 200, height: 200))
            content.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            let smallest = content.frame.size
            window.contentMinSize = smallest
            // Fixed width: the window only grows taller (more hex rows), never wider.
            window.contentMaxSize = NSSize(width: smallest.width, height: CGFloat.greatestFiniteMagnitude)
            window.setContentSize(smallest)
        }
        // The green button zooms (to full screen height) instead of entering full-screen mode.
        window.collectionBehavior.insert(.fullScreenNone)
        chipField.stringValue = Self.cleanChipName(UserDefaults.standard.string(forKey: "lastChip") ?? "")
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
        programmerLabel.textColor = .secondaryLabelColor     // the same grey as the text after Voltages:
        programmerLabel.isSelectable = true

        chipField.placeholderString = "e.g. AM27C256@DIP28 – use Search or Chip Ident"
        chipField.delegate = self
        chipField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        let logic = logicTestButton
        let logicID = button("Logic Ident…", #selector(identifyLogic(_:)))
        let hardware = button("H/W Test…", #selector(hwTest(_:)))
        // Two rows: Logic Ident under Chip Ident, Logic Test under Chip Test, Hardware under Chip Info.
        // A stretchable gap before the six chip buttons keeps them flush right (with Save… below).
        func gap() -> NSView {
            let v = NSView()
            v.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .horizontal)
            return v
        }
        let chipRow = NSGridView(views: [
            [bold("Chip:"), chipField, button("Search…", #selector(searchChips(_:))), gap(),
             button("Chip Ident…", #selector(identifyChip(_:))), chipTestButton, button("Chip Info", #selector(chipInfo(_:)))],
            [bold("H/W:"), programmerLabel, NSView(), gap(), logicID, logic, hardware],
        ])
        // The programmer name may use the Search column's space too.
        chipRow.row(at: 1).mergeCells(in: NSRange(location: 1, length: 2))
        chipRow.rowSpacing = 6
        chipRow.columnSpacing = 8
        chipRow.rowAlignment = .firstBaseline
        for c in [2, 4, 5, 6] { chipRow.column(at: c).xPlacement = .fill }   // equal-width buttons per column
        chipRow.column(at: 3).xPlacement = .fill
        chipRow.column(at: 1).xPlacement = .fill
        chipField.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        chipInfoLabel.textColor = .secondaryLabelColor
        chipInfoLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        chipInfoLabel.lineBreakMode = .byTruncatingTail

        let read = button("Read", #selector(readChip(_:)))
        let blank = button("Blank Check", #selector(blankCheck(_:)))
        let program = button("Program…", #selector(programChip(_:)))
        let verify = button("Verify", #selector(verifyChip(_:)))
        let erase = button("Erase", #selector(eraseChip(_:)))
        eraseButton = erase
        stopButton = button("Stop", #selector(stop(_:)))
        actionButtons = [read, blank, erase, program, verify, logic, logicID]
        let jedButton = button("PLD…", #selector(showPLDMenu(_:)))
        let openButton = button("Open…", #selector(openFile(_:)))
        let saveHex = button("Save…", #selector(saveFile(_:)))
        // Stop ends the chip operations; the file buttons sit at the right end of the same row.
        let actionRow = row([read, blank, erase, program, verify, stopButton, spacer(), jedButton, openButton, saveHex])

        memoryTypes.forEach { memoryPopup.addItem(withTitle: $0.title) }
        ["ZIF socket", "ICSP – power from programmer", "ICSP – board has its own power"].forEach { connectionPopup.addItem(withTitle: $0) }
        loadSettings()

        // Memory, connection, voltages and settings share one aligned column.
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let controlWidth: CGFloat = 240
        let voltButton = button("Voltages…", #selector(editVoltages(_:)))
        let settingsButton = button("Options…", #selector(showSettings(_:)))
        for c in [memoryPopup, connectionPopup] as [NSControl] {
            c.controlSize = .small
            c.font = small
            c.widthAnchor.constraint(equalToConstant: controlWidth).isActive = true
        }
        // Fuses & Locks…, Voltages… and Options… form one right-hand column of equal-width buttons.
        for b in [configButton, voltButton, settingsButton] {
            b.controlSize = .small
            b.font = small
        }
        for l in [voltageLabel, settingsLabel] {
            l.font = small
            l.textColor = .secondaryLabelColor
            l.lineBreakMode = .byTruncatingTail
        }
        func label(_ t: String) -> NSTextField {
            let l = NSTextField(labelWithString: t)
            l.font = small
            l.alignment = .right
            // Labels keep their natural width, so spare width never widens the label column.
            l.setContentHuggingPriority(.required, for: .horizontal)
            return l
        }
        let empty = { () -> NSView in NSView() }
        // Connection and Memory share the first row. The Voltages and Options rows show their current
        // setting right after the label, with their buttons at the end under Fuses & Locks….
        let connLabel = label("Connection:"), voltLabel = label("Voltages:"), optLabel = label("Options:"), memLabel = label("Memory:")
        let grid = NSGridView(views: [
            [connLabel, connectionPopup, memLabel, memoryPopup, configButton],
            [voltLabel, voltageLabel, empty(), empty(), voltButton],
            [optLabel, settingsLabel, empty(), empty(), settingsButton],
        ])
        grid.rowSpacing = 6
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.column(at: 2).xPlacement = .trailing
        grid.column(at: 3).xPlacement = .leading
        grid.column(at: 2).leadingPadding = 12
        grid.column(at: 4).xPlacement = .fill      // the three buttons get the same width
        // Fixed widths for every column but the Memory pop-up's: the spare width then always ends up after
        // that pop-up. Left to Auto Layout, the spare width sometimes went to the label column at launch,
        // pushing Connection / Voltages / Options to the right until an option was changed.
        grid.column(at: 0).width = ceil([connLabel, voltLabel, optLabel].map { $0.fittingSize.width }.max() ?? 70)
        grid.column(at: 1).width = 240
        grid.column(at: 2).width = ceil(memLabel.fittingSize.width)
        grid.column(at: 4).width = ceil([configButton, voltButton, settingsButton].map { $0.fittingSize.width }.max() ?? 100)
        connectionPopup.widthAnchor.constraint(equalToConstant: 240).isActive = true
        memoryPopup.widthAnchor.constraint(equalToConstant: 240).isActive = true
        for r in 1...2 {
            grid.row(at: r).mergeCells(in: NSRange(location: 1, length: 3))
            grid.cell(atColumnIndex: 1, rowIndex: r).xPlacement = .leading
        }
        updateSettingsLabel()

        bufferLabel.lineBreakMode = .byTruncatingMiddle
        bufferLabel.isSelectable = true
        // Under the hex editor, in its monospaced font, starting at the same x as its "Address" heading.
        bufferLabel.font = NSFont.userFixedPitchFont(ofSize: 12) ?? .systemFont(ofSize: 12)
        bufferLabel.textColor = .secondaryLabelColor     // the same grey as the Address heading
        // The cursor / selection text follows the buffer details on the same line, in the same style.
        selectionLabel.font = bufferLabel.font
        selectionLabel.textColor = .secondaryLabelColor
        selectionLabel.lineBreakMode = .byTruncatingTail
        // The buffer details give way (truncate) before the cursor text does.
        selectionLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(rawValue: 260), for: .horizontal)
        selectionLabel.setContentHuggingPriority(.required, for: .horizontal)
        let fileRow = row([bufferLabel, selectionLabel, spacer()])
        fileRow.spacing = 0
        fileRow.alignment = .firstBaseline
        fileRow.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 0)

        let settingsBlock = grid
        let editRow = buildEditRow()
        let bufferView = buildBufferEditor()
        bufferView.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        buildLogWindow()

        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 100
        progress.style = .bar
        progress.widthAnchor.constraint(equalToConstant: 220).isActive = true
        statusLabel.lineBreakMode = .byTruncatingTail
        let logButton = button("Log", #selector(toggleLog(_:)))
        let statusRow = row([statusLabel, spacer(), progress, logButton])

        // Thin divider lines (the same kind as in the Fuses & Locks window) set off the chip section
        // and the settings section.
        func divider() -> NSBox {
            let b = NSBox()
            b.boxType = .separator
            return b
        }
        let dividerTop = divider(), dividerBottom = divider(), dividerStatus = divider()
        // The edit buttons sit under the buffer, with a divider between them and the status line.
        let rows: [NSView] = [chipRow, dividerTop, actionRow, settingsBlock, dividerBottom, bufferView, fileRow, editRow, dividerStatus, statusRow]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        // Equal gaps above and below the chip description, so it sits midway between the chip rows and Read.
        stack.setCustomSpacing(12, after: chipRow)
        stack.setCustomSpacing(12, after: dividerTop)
        stack.setCustomSpacing(12, after: settingsBlock)
        stack.setCustomSpacing(10, after: dividerBottom)
        // The buffer line sits midway between the hex editor and the edit buttons.
        stack.setCustomSpacing(6, after: bufferView)
        stack.setCustomSpacing(6, after: fileRow)
        stack.setCustomSpacing(10, after: editRow)
        stack.setCustomSpacing(8, after: dividerStatus)
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
        bufferView.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    /// The log lives in its own window, hidden until the Log button (or Window ▸ Log) shows it.
    private func buildLogWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: true)
        w.title = "ChipBurner Log"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 360, height: 200)
        let sv = scroll(logView)
        sv.borderType = .noBorder
        w.contentView = sv
        if !w.setFrameUsingName("ChipBurnerLog") { w.center() }
        _ = w.setFrameAutosaveName("ChipBurnerLog")
        logWindow = w
    }

    @objc func toggleLog(_ sender: Any?) {
        guard let w = logWindow else { return }
        if w.isVisible {
            w.orderOut(nil)
        } else {
            if !UserDefaults.standard.bool(forKey: "logPlaced"), let main = window {
                // First time: put it beside the main window.
                let f = main.frame
                w.setFrameTopLeftPoint(NSPoint(x: f.maxX + 12, y: f.maxY))
                UserDefaults.standard.set(true, forKey: "logPlaced")
            }
            w.makeKeyAndOrderFront(nil)
            logView.scrollToEndOfDocument(nil)
        }
    }

    // MARK: Helpers

    /// minipro's chip list marks chips read with a special routine "(custom)"; the name itself has no suffix.
    private var chip: String { Self.cleanChipName(chipField.stringValue) }

    static func cleanChipName(_ s: String) -> String {
        s.replacingOccurrences(of: "(custom)", with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespaces)
    }

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
        if chip.uppercased() != voltagesChip {
            // Voltage overrides never carry over to another chip.
            if !voltages.isEmpty { log("Voltage overrides cleared because the chip changed.") }
            voltages = VoltageOverrides()
            voltagesChip = chip.uppercased()
        }
        defer {
            refreshCapabilities(); updateVoltageLabel(); updateEnabledState()
            let t = chipInfoLabel.stringValue.trimmingCharacters(in: .whitespaces)
            chipField.toolTip = t.isEmpty ? nil : t
        }
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
        if let c = currentCaps, c.icspSupported { s += " · ICSP capable" }
        chipInfoLabel.stringValue = s
    }

    // MARK: Chip capabilities, connection, pin check, voltages

    private var capsKey: String { Minipro.shared.programmerType.uppercased() + ":" + chip.uppercased() }
    private var currentCaps: ChipCapabilities? { caps[capsKey] }

    /// Asks minipro (-d) once per chip whether it supports ICSP and which voltages it uses.
    private func refreshCapabilities() {
        let key = capsKey, name = chip, type = Minipro.shared.programmerType
        guard !name.isEmpty, chipDetails != nil, caps[key] == nil, !capsPending.contains(key), !isBusy else { return }
        capsPending.insert(key)
        DispatchQueue.global(qos: .utility).async {
            let r = Minipro.shared.runSync(["-q", type, "-d", name])
            let c = ChipCapabilities.parse(r.output)
            DispatchQueue.main.async {
                self.capsPending.remove(key)
                guard r.status == 0 else { return }
                self.caps[key] = c
                if key == self.capsKey { self.updateChipInfo() }
            }
        }
    }

    private func updateVoltageLabel() {
        if !voltages.isEmpty {
            voltageLabel.stringValue = "\(voltages.summary)"
            voltageLabel.textColor = .systemOrange
            return
        }
        voltageLabel.textColor = .secondaryLabelColor
        guard let c = currentCaps else { voltageLabel.stringValue = "chip defaults"; return }
        guard c.hasVoltageOptions else { voltageLabel.stringValue = "fixed for this chip"; return }
        let parts = [c.vpp.map { "VPP \($0)" }, c.vdd.map { "VDD \($0)" }, c.vcc.map { "VCC \($0)" }, c.pulse.map { "pulse \($0)" }].compactMap { $0 }
        voltageLabel.stringValue = "defaults (\(parts.joined(separator: ", ")))"
    }

    private var usingICSP: Bool { connectionPopup.indexOfSelectedItem > 0 }

    /// -i: ICSP with the programmer powering the target; -I: ICSP, target powered on its own.
    private var connectionArgs: [String] {
        switch connectionPopup.indexOfSelectedItem {
        case 1: return ["-i"]
        case 2: return ["-I"]
        default: return []
        }
    }

    private func connectionAllowed() -> Bool {
        if usingICSP, let c = currentCaps, !c.icspSupported {
            showError("\(chip) can't be programmed over ICSP.", "Set Connection to ZIF socket, or choose a chip that supports in-circuit programming.")
            return false
        }
        return true
    }

    @objc func editVoltages(_ sender: Any?) {
        guard requireChip(), let w = window else { return }
        guard let c = currentCaps else {
            refreshCapabilities()
            showError("Still reading the chip's settings.", "Try again in a moment.")
            return
        }
        guard c.hasVoltageOptions else {
            showError("\(chip) has no adjustable voltages.", "Custom voltages are available for UV EPROMs, GALs and similar chips.")
            return
        }
        let type = Minipro.shared.programmerType
        func popup(_ title: String, _ def: String?, _ choices: [String], _ current: String?) -> (NSStackView, NSPopUpButton) {
            let p = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 170, height: 26), pullsDown: false)
            p.addItem(withTitle: "Default" + (def.map { " (\($0))" } ?? ""))
            choices.forEach { p.addItem(withTitle: "\($0) V") }
            if let cur = current, let i = choices.firstIndex(of: cur) { p.selectItem(at: i + 1) }
            p.isEnabled = def != nil
            let l = NSTextField(labelWithString: title)
            l.widthAnchor.constraint(equalToConstant: 150).isActive = true
            return (row([l, p]), p)
        }
        let (vppRow, vppPop) = popup("VPP programming", c.vpp, VoltageOverrides.vppChoices(for: type), voltages.vpp)
        let (vddRow, vddPop) = popup("VDD while writing", c.vdd, VoltageOverrides.supplyChoices, voltages.vdd)
        let (vccRow, vccPop) = popup("VCC while verifying", c.vcc, VoltageOverrides.supplyChoices, voltages.vcc)
        let pulseField = NSTextField(string: voltages.pulse ?? "")
        pulseField.placeholderString = "default" + (c.pulse.map { " (\($0))" } ?? "")
        pulseField.widthAnchor.constraint(equalToConstant: 170).isActive = true
        pulseField.isEnabled = c.pulse != nil
        let pulseLabel = NSTextField(labelWithString: "Pulse (µs, 0–65535)")
        pulseLabel.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let stack = NSStackView(views: [vppRow, vddRow, vccRow, row([pulseLabel, pulseField])])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 340, height: 140)

        let a = NSAlert()
        a.messageText = "Programming voltages for \(chip)"
        a.informativeText = "These apply only when programming. Wrong values can destroy a chip – take them from the chip's datasheet. They are cleared when you pick another chip."
        a.accessoryView = stack
        a.addButton(withTitle: "Set")
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Reset to Defaults")
        a.beginSheetModal(for: w) { [weak self] resp in
            guard let self = self else { return }
            if resp == .alertThirdButtonReturn {
                self.voltages = VoltageOverrides()
            } else if resp == .alertFirstButtonReturn {
                func pick(_ p: NSPopUpButton, _ choices: [String]) -> String? {
                    p.indexOfSelectedItem > 0 ? choices[p.indexOfSelectedItem - 1] : nil
                }
                var v = VoltageOverrides()
                v.vpp = pick(vppPop, VoltageOverrides.vppChoices(for: type))
                v.vdd = pick(vddPop, VoltageOverrides.supplyChoices)
                v.vcc = pick(vccPop, VoltageOverrides.supplyChoices)
                let pulse = pulseField.stringValue.trimmingCharacters(in: .whitespaces)
                if !pulse.isEmpty {
                    guard let n = Int(pulse), (0...65535).contains(n) else {
                        DispatchQueue.main.async { self.showError("Pulse must be a whole number from 0 to 65535 µs.", "") }
                        return
                    }
                    v.pulse = String(n)
                }
                self.voltages = v
            } else { return }
            self.log("Programming voltages: \(self.voltages.summary)")
            self.updateVoltageLabel()
        }
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
        configButton.isEnabled = !isBusy && currentConfig != nil
        let testKind = chipDetails.map { $0.kind }
        logicTestButton.isEnabled = !isBusy && testKind == .logic
        logicTestButton.toolTip = logicTestButton.isEnabled ? "Standard Test runs minipro's test vectors once; Extended Test adds an exhaustive or full-sequence test and repeated runs."
            : "Logic Test works with logic chips (74xx, 40xx …). Select one with Search or Logic Ident."
        chipTestButton.isEnabled = !isBusy && (testKind == .sram || testKind == .memory) && (chipDetails?.codeSize ?? 0) > 0
        chipTestButton.toolTip = chipTestButton.isEnabled
            ? (testKind == .sram ? "Pattern test for this SRAM." : "Health check for this EPROM/EEPROM/flash: repeated reads, content analysis and an optional write test.")
            : "Chip Test works with SRAM and with EPROM, EEPROM and flash memory chips."
        configButton.toolTip = currentConfig != nil ? "Read and write this chip's fuses, user ID and lock bits in a separate window."
                                                    : (chipDetails?.kind == .mcu
                                                       ? "minipro's database has no fuse/config layout for this chip, so its configuration bits can't be read or written here."
                                                       : "The selected chip has no fuses, user ID or lock bits in the database.")
        if let b = eraseButton {
            let m = eraseMethod
            if case .unavailable(let why) = m { b.isEnabled = false; b.toolTip = why }
            else { b.toolTip = m == .command ? "Erases the chip with its erase command." : "This chip has no erase command: it is filled with FF (its blank state) and verified." }
        }
        stopButton?.isEnabled = isBusy
        chipField.isEnabled = !isBusy
        memoryPopup.isEnabled = !isBusy
    }

    /// Shows a newly loaded or read buffer in the editor (and starts a fresh undo history).
    private func updateBufferViews() {
        defer {
            if let c = compareWindow {
                if bufferIsText { c.close() } else { c.refresh() }
            }
        }
        bufferEdited = false
        if bufferIsText {
            textEditor.string = String(decoding: buffer, as: UTF8.self)
            textEditor.undoManager?.removeAllActions()
            textScroll.isHidden = false
            hexEditor.isHidden = true
            hexEditor.setData(Data())
        } else {
            hexEditor.setData(buffer)
            textEditor.string = ""
            updateSelectionLabel()
            textScroll.isHidden = true
            hexEditor.isHidden = false
        }
        updateBufferLabel()
    }

    private func updateBufferLabel() {
        defer { bufferLabel.toolTip = bufferLabel.stringValue }   // full text when it is cut short
        let edited = bufferEdited ? " (edited)" : ""
        if buffer.isEmpty && !bufferIsText {
            bufferLabel.stringValue = "Buffer: empty – open a file, read a chip or use New Buffer…"
        } else if bufferIsText {
            bufferLabel.stringValue = "Buffer: \(bufferName)\(edited) — .\(bufferExt) text, \(buffer.count) bytes"
        } else {
            bufferLabel.stringValue = String(format: "Buffer: %@%@ — %d (0x%X) bytes — sum 0x%04X — CRC32 0x%08X",
                                             bufferName, edited, buffer.count, buffer.count, Checksums.sum16(buffer), Checksums.crc32(buffer))
        }
    }

    private func requireChip() -> Bool {
        if chip.isEmpty {
            showError("Choose a chip first.", "Type its exact minipro name, or use Search… or Chip Ident….")
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
        return a + protectionArgs(kind)
    }

    private func protectionArgs(_ kind: JobKind) -> [String] {
        guard kind == .write else { return [] }
        return (unprotect.state == .on ? ["-u"] : []) + (protectAfter.state == .on ? ["-P"] : [])
    }

    // MARK: Settings sheet

    private func loadSettings() {
        unprotect.toolTip = "Turns off write protection (such as the software data protection of parallel EEPROMs) before writing or erasing (minipro -u)."
        protectAfter.toolTip = "Turns write protection on again after writing (minipro -P)."
        skipID.toolTip = "Reads or writes even if the chip's electronic ID doesn't match (minipro -x / -y)."
        allowSize.toolTip = "Writes or verifies even if the file size differs from the chip size (minipro -s)."
        skipErase.toolTip = "Programs without erasing first (minipro -e)."
        skipVerify.toolTip = "Skips the read-back check after programming (minipro -v)."
        for s in settingBoxes {
            s.box.state = UserDefaults.standard.bool(forKey: s.key) ? .on : .off
            s.box.target = self
            s.box.action = #selector(settingChanged(_:))
        }
    }

    @objc private func settingChanged(_ sender: Any?) {
        for s in settingBoxes { UserDefaults.standard.set(s.box.state == .on, forKey: s.key) }
        updateSettingsLabel()
    }

    private func updateSettingsLabel() {
        let on = settingBoxes.filter { $0.box.state == .on }.map { $0.short }
        settingsLabel.stringValue = on.isEmpty ? "standard" : on.joined(separator: ", ")
        settingsLabel.textColor = on.isEmpty ? .secondaryLabelColor : .systemOrange
    }

    @objc func showSettings(_ sender: Any?) {
        guard let w = window, !isBusy else { return }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                             styleMask: [.titled], backing: .buffered, defer: false)
        func heading(_ t: String) -> NSTextField {
            let l = NSTextField(labelWithString: t)
            l.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            return l
        }
        let note = NSTextField(wrappingLabelWithString: "These apply to Read, Verify, Program and Erase, and are kept until you change them.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        for s in settingBoxes { s.box.controlSize = .regular; s.box.font = .systemFont(ofSize: NSFont.systemFontSize) }
        let done = NSButton(title: "Done", target: self, action: #selector(closeSettings(_:)))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let doneRow = NSStackView(views: [spacer(), done])
        doneRow.orientation = .horizontal
        let views: [NSView] = [heading("Chip checks"), skipID, allowSize,
                               heading("Programming"), skipErase, skipVerify,
                               heading("Write protection"), unprotect, protectAfter,
                               note, doneRow]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        for h in [views[3], views[6], views[9]] { stack.setCustomSpacing(14, after: stack.views[stack.views.firstIndex(of: h)! - 1]) }
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 420),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            doneRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
        sheet.contentView = content
        w.beginSheet(sheet) { [weak self] _ in self?.updateSettingsLabel() }
    }

    @objc private func closeSettings(_ sender: NSButton) {
        guard let sheet = sender.window else { return }
        settingChanged(nil)
        sheet.sheetParent?.endSheet(sheet)
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
    private func runJob(_ title: String, _ args: [String], logicic: URL? = nil, then done: ((Bool, String) -> Void)? = nil) {
        guard !isBusy else { return }
        isBusy = true
        progress.doubleValue = 0
        setStatus("\(title)…")
        log("▶︎ \(title): minipro \(args.joined(separator: " "))")
        let percent = try? NSRegularExpression(pattern: "(\\d{1,3})%")
        var collected: [String] = []
        running = Minipro.shared.run(args, logicic: logicic, onLine: { [weak self] line, isProgress in
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
            self.setStatus(ok ? "\(title): done" : "\(title): failed (exit code \(status)) – see Log")
            self.log(ok ? "✓ \(title) finished." : "✗ \(title) failed (exit code \(status)).")
            if !ok { NSSound.beep() }
            let all = collected.joined(separator: "\n")
            // Every job prints the programmer's firmware and serial number; keep the top line current.
            if let model = self.programmerModel, all.contains("Serial code:") {
                self.showProgrammer(model: model, output: all)
            }
            done?(ok, all)
        })
        if running == nil { isBusy = false }
    }

    // MARK: Actions

    @objc func checkProgrammer(_ sender: Any?) { detectProgrammer(then: nil) }

    /// Finds the programmer: model from `minipro -k`, firmware and serial number from a device search
    /// (which opens the programmer properly without touching the socket; the search term matches no chip).
    /// `done` gets true when a programmer answered.
    private func detectProgrammer(then done: ((Bool) -> Void)?) {
        guard !isBusy else { return }
        programmerLabel.stringValue = "Checking…"
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Minipro.shared.runSync(["-k"])
            let info = r.status == 0 ? Minipro.shared.runSync(["-L", "CHIPBURNER-NO-SUCH-CHIP"]).output : ""
            DispatchQueue.main.async {
                let lines = r.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.contains("overridden database") }
                var found = false
                if r.status == 0, let model = Minipro.shared.updateProgrammerType(from: r.output) {
                    found = true
                    self.programmerModel = model
                    self.showProgrammer(model: model, output: info)
                } else {
                    let first = lines.first ?? "No answer"
                    self.programmerLabel.stringValue = r.status == 0 ? first : "Not found – \(first)"
                }
                self.log("Programmer check:\n" + (r.output + "\n" + info).components(separatedBy: .newlines)
                    .filter { !$0.isEmpty && !$0.contains("overridden database") }.joined(separator: "\n"))
                self.updateChipInfo()
                done?(found)
            }
        }
    }

    /// "TL866A v03.2.86" on the main window; model, serial and firmware kept for the H/W Test report.
    private func showProgrammer(model: String, output: String) {
        programmerDetails = Minipro.programmerSummary(model: model, from: output)
        if let fw = Minipro.firmwareVersion(from: output) {
            programmerLabel.stringValue = "\(model) v\(fw)"
        } else if programmerLabel.stringValue == "Checking…" || !programmerLabel.stringValue.hasPrefix(model) {
            programmerLabel.stringValue = model
        }
    }

    private func selectChip(_ raw: String) {
        let name = Self.cleanChipName(raw)
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

    /// Shows minipro's details for the selected chip (memory, package, ICSP, default voltages) in a sheet.
    @objc func chipInfo(_ sender: Any?) {
        guard requireChip() else { return }
        let name = chip
        runJob("Chip info", ["-q", Minipro.shared.programmerType, "-d", name]) { [weak self] ok, output in
            guard let self = self else { return }
            let text = output.components(separatedBy: .newlines)
                .filter { !$0.contains("overridden database") && !$0.hasPrefix("****") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .joined(separator: "\n")
            if ok {
                var extra = ""
                if let info = self.chipDetails { extra = "\n\n" + info.summary }
                guard let w = self.window, self.currentPinout != nil else { self.showInfo(name, text + extra); return }
                let a = NSAlert()
                a.alertStyle = .informational
                a.messageText = name
                a.informativeText = text + extra
                a.addButton(withTitle: "OK")
                a.addButton(withTitle: "Pinout…")
                a.beginSheetModal(for: w) { [weak self] r in
                    if r == .alertSecondButtonReturn { DispatchQueue.main.async { self?.showPinout(nil) } }
                }
            } else {
                self.showError("No details for \(name)", text.isEmpty ? "minipro gave no answer." : text)
            }
        }
    }

    /// Reads the electronic ID with a reference algorithm, then lists every database chip with that ID.
    private enum IDMethod { case eprom(String), spi(Int) }

    @objc func identifyChip(_ sender: Any?) {
        guard let w = window, !isBusy else { return }
        guard ChipDatabase.shared.isLoaded else { showError("The chip database is still loading.", "Try again in a moment."); return }
        var choices: [(String, IDMethod)] = [
            ("SPI flash (25-series), 8 pins", .spi(8)),
            ("SPI flash (25-series), 16-pin SOIC adapter", .spi(16)),
            ("28-pin 27-series EPROM (27C64–27C512, W27C512)", .eprom("AM27C256@DIP28")),
            ("32-pin 27-series EPROM (27C010–27C080, 27SF0x0)", .eprom("AM27C010@DIP32")),
        ]
        if !chip.isEmpty, chipDetails != nil, Self.isUVEPROM(chip) || chip.uppercased().hasPrefix("W27") {
            choices.append(("Same type as \(chip)", .eprom(chip)))
        }
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 380, height: 26), pullsDown: false)
        choices.forEach { popup.addItem(withTitle: $0.0) }
        let last = UserDefaults.standard.integer(forKey: "identifyChoice")
        if last < choices.count { popup.selectItem(at: last) }
        let a = NSAlert()
        a.messageText = "Chip Ident"
        a.informativeText = """
            Put the chip in the socket (bottom-aligned, pin 1 at the lever end) and choose what kind of chip it is. \
            ChipBurner reads its electronic ID and lists the chips that match.

            SPI flash is read at 3.3 V with the standard JEDEC ID command. 1.8 V chips need a 1.8 V adapter.

            27-series EPROMs are read the EPROM way, with about 12 V on pin A9. That includes the electrically \
            erasable 27-series parts (Winbond W27C/W27E, SST 27SF), which are made for it. Never use it with \
            28-series EEPROMs, flash, microcontrollers or other chip types – they aren't made for that voltage \
            and can be damaged. Old NMOS EPROMs have no ID.
            """
        a.accessoryView = popup
        a.addButton(withTitle: "Read ID")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { [weak self] resp in
            guard let self = self, resp == .alertFirstButtonReturn else { return }
            let i = max(0, popup.indexOfSelectedItem)
            UserDefaults.standard.set(i, forKey: "identifyChoice")
            switch choices[i].1 {
            case .spi(let pins):
                self.runSPIAutodetect(pins: pins)
            case .eprom(let ref):
                if !self.chip.isEmpty, Self.isEEPROM(self.chip) {
                    self.showError("The EPROM ID read can't be used with \(self.chip).",
                                   "It puts about 12 V on pin A9. 28-series EEPROMs aren't made for that and can be damaged. Choose the chip with Search instead, and use Skip chip ID check in Options if it has no ID in the database.")
                    return
                }
                self.runIdentify(reference: ref)
            }
        }
    }

    /// minipro -a 8|16 reads the JEDEC ID of a 25-series SPI flash and lists the chips that have it.
    private func runSPIAutodetect(pins: Int) {
        guard let w = window else { return }
        runJob("Auto-detect SPI flash (\(pins) pins)", ["-a", "\(pins)"]) { [weak self] ok, output in
            guard let self = self else { return }
            let r = SPIAutodetect.parse(output)
            let programmer = Minipro.shared.programmerType
            var names = r.names
            if ChipDatabase.shared.isLoaded {
                let known = names.filter { ChipDatabase.shared.info(for: $0, programmer: programmer) != nil }
                if !known.isEmpty { names = known }
            }
            let idText = r.id.map { String(format: "0x%04X", $0) } ?? "?"
            guard ok, let id = r.id, id != 0, id != 0xFFFF, id != 0xFFFFFF, id != 0xFFFFFFFF else {
                self.showError("No SPI flash ID could be read.",
                               "Check that the chip sits correctly (pin 1 at the lever end, bottom-aligned, or in the right adapter) and that it is a 25-series SPI flash. Press Log for minipro's message.")
                return
            }
            guard !names.isEmpty else {
                self.showInfo("SPI flash ID \(idText) read", "No chip in the \(programmer) database has this ID. The maker code is 0x\(String(format: "%02X", (id >> 16) & 0xFF == 0 ? (id >> 8) & 0xFF : (id >> 16) & 0xFF)).")
                return
            }
            let picker = ChipSearchController(title: "SPI flash with ID \(idText)", results: names) { [weak self] name in
                guard let self = self, let name = name else { return }
                self.selectChip(name)
            }
            picker.present(on: w)
        }
    }

    private func runIdentify(reference ref: String) {
        let programmer = Minipro.shared.programmerType
        guard let refInfo = ChipDatabase.shared.info(for: ref, programmer: programmer) else {
            showError("\(ref) isn't in the \(programmer) database.", "Pick another reference, or use Hardware… ▸ Check Programmer first.")
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
        guard requireChip(), connectionAllowed() else { return }
        let m = mode
        let out = tempURL("read.\(m.ext)")
        try? FileManager.default.removeItem(at: out)
        runJob("Read \(chip) (\(m.label))", ["-p", chip] + connectionArgs + m.memArgs + ["-r", out.path] + optionArgs(.read)) { [weak self] ok, _ in
            guard let self = self, ok, let data = try? Data(contentsOf: out) else { return }
            self.buffer = data
            self.bufferIsText = m.text
            self.bufferExt = m.ext
            self.bufferName = "read from \(self.chip)"
            self.updateBufferViews()
        }
    }

    @objc func blankCheck(_ sender: Any?) {
        guard requireChip(), connectionAllowed() else { return }
        let m = mode
        runJob("Blank check \(chip)", ["-p", chip] + connectionArgs + m.memArgs + ["-b"] + optionArgs(.check))
    }

    @objc func verifyChip(_ sender: Any?) {
        guard requireChip(), connectionAllowed(), let file = writeBufferToTemp(for: mode) else { return }
        let m = mode
        runJob("Verify \(chip)", ["-p", chip] + connectionArgs + m.memArgs + ["-m", file.path] + optionArgs(.verify))
    }

    @objc func programChip(_ sender: Any?) {
        guard requireChip(), connectionAllowed(), let w = window else { return }
        let m = mode
        guard let file = writeBufferToTemp(for: m) else { return }
        let volts = voltages
        let where_ = usingICSP ? "over ICSP (\(connectionPopup.titleOfSelectedItem ?? "ICSP"))" : "in the ZIF socket (lever down, pin 1 at the lever end, bottom-aligned)"
        let a = NSAlert()
        a.messageText = "Program \(chip)?"
        a.informativeText = "\(buffer.count) bytes from “\(bufferName)” will be written to the \(m.label) \(where_).\n\nVoltages: \(volts.summary)."
        a.addButton(withTitle: "Program")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { [weak self] resp in
            guard let self = self, resp == .alertFirstButtonReturn else { return }
            self.runJob("Program \(self.chip)", ["-p", self.chip] + self.connectionArgs + m.memArgs + ["-w", file.path] + volts.args + self.optionArgs(.write))
        }
    }

    enum EraseMethod: Equatable { case command, fill, unavailable(String) }

    /// Erase is offered only for chips that can be erased electrically in the programmer.
    private var eraseMethod: EraseMethod {
        guard !chip.isEmpty else { return .unavailable("Choose a chip first.") }
        guard let info = chipDetails else { return .unavailable("Erase is available once the chip is found in the database.") }
        if Self.isUVEPROM(chip) && info.canErase != true {
            return .unavailable("\(chip) is a UV EPROM (or its one-time-programmable version). It can only be erased with UV light in an EPROM eraser.")
        }
        if info.canErase == true { return .command }
        switch info.kind {
        case .memory where info.codeSize > 0:
            return .fill
        case .logic:
            return .unavailable("Logic chips have no memory to erase.")
        case .sram:
            return .unavailable("SRAM loses its contents without power; there is nothing to erase.")
        default:
            return .unavailable("\(chip) has no erase command in minipro's database (it may be one-time programmable or need UV light).")
        }
    }

    @objc func eraseChip(_ sender: Any?) {
        guard requireChip(), connectionAllowed(), let w = window else { return }
        let method = eraseMethod
        if case .unavailable(let why) = method { showError("\(chip) can't be erased here.", why); return }
        let a = NSAlert()
        a.messageText = "Erase \(chip)?"
        a.informativeText = method == .command
            ? "The chip is erased with its erase command."
            : "\(chip) has no erase command. It is filled with FF (its blank state) by programming and verifying – unless a blank check shows it is already blank, which saves a write cycle."
            + (unprotect.state == .on ? "\n\nWrite protection is turned off first." : "")
        a.addButton(withTitle: "Erase")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { [weak self] resp in
            guard let self = self, resp == .alertFirstButtonReturn else { return }
            let name = self.chip
            if method == .fill {
                self.log("\(name) has no erase command in the database – filling it with FF instead.")
                self.eraseByFilling(name)
                return
            }
            let unprot = self.unprotect.state == .on ? ["-u"] : []
            self.runJob("Erase \(name)", ["-p", name] + self.connectionArgs + unprot + ["-E"]) { [weak self] ok, output in
                guard let self = self, !ok else { return }
                if Self.eraseUnsupported(output), self.chipDetails?.kind == .memory, !Self.isUVEPROM(name) {
                    self.log("\(name) has no erase command – filling it with FF instead.")
                    self.eraseByFilling(name)
                }
            }
        }
    }

    /// minipro refuses -E for chips whose database entry has no erase support.
    static func eraseUnsupported(_ output: String) -> Bool {
        let l = output.lowercased()
        guard l.contains("erase") else { return false }
        return ["can't", "can not", "cannot", "not supported", "unsupported", "doesn't support", "does not support", "not erasable"].contains { l.contains($0) }
    }

    /// Names like AM27C256, M27C512, 2764, D27128 (UV EPROMs that need 12 V and UV erase).
    static func isUVEPROM(_ name: String) -> Bool {
        let n = name.uppercased()
        if n.range(of: "27(SF|EE|LV0|BV)", options: .regularExpression) != nil { return false } // electrically erasable 27-series
        if n.hasPrefix("W27") { return false }                                                    // Winbond W27C: electrically erasable
        return n.range(of: "^[A-Z]{0,4}27C?[0-9]{2,4}", options: .regularExpression) != nil
    }

    /// Parallel EEPROMs (28-series names) – the EPROM ID read must not be used on them.
    static func isEEPROM(_ name: String) -> Bool {
        name.uppercased().range(of: "^[A-Z]{0,4}28(C|HC|LV|F)?[0-9]{2,4}", options: .regularExpression) != nil
    }

    /// Erase for chips without an erase command: skip if blank, otherwise program all FF and verify.
    /// FF is the erased state of EEPROM and flash, and what Blank Check expects. Every byte write
    /// costs one internal erase/write cycle whatever the value, so the wear-saving step is to skip
    /// the write altogether when the chip is already blank.
    private func eraseByFilling(_ name: String) {
        guard let info = ChipDatabase.shared.info(for: name, programmer: Minipro.shared.programmerType), info.codeSize > 0 else {
            showError("Can't erase \(name).", "The chip has no erase command, and its size isn't known, so it can't be filled with FF.")
            return
        }
        runJob("Blank check \(name)", ["-p", name] + connectionArgs + ["-b"]) { [weak self] blank, _ in
            guard let self = self else { return }
            if blank {
                self.showInfo("\(name) is already blank", "Every byte already reads FF, so nothing was written.")
                return
            }
            let url = self.tempURL("erase-fill.bin")
            do { try Data(repeating: 0xFF, count: info.codeSize).write(to: url) } catch {
                self.showError("Could not write a temporary file.", error.localizedDescription)
                return
            }
            var args = ["-p", name] + self.connectionArgs + ["-w", url.path, "-e"]
            if self.unprotect.state == .on { args.append("-u") }
            if self.protectAfter.state == .on { args.append("-P") }
            self.runJob("Fill \(name) with FF", args) { [weak self] ok, _ in
                guard let self = self else { return }
                if ok { self.showInfo("\(name) erased", "All \(info.codeSize) bytes were written with FF and verified.") }
                else { self.showError("Filling \(name) with FF failed.", "If the chip is write-protected, tick “Unprotect before writing” and try again. Details are in the log.") }
            }
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
            let failing = Self.failingVectorLines(output)
            if ok && failing.isEmpty {
                self.showInfo("\(name) passed", "All test vectors matched. Details are in the log.")
            } else if !failing.isEmpty {
                self.showError("\(name) failed", "\(failing.count) test vector(s) had pins in the wrong state. Press Log to see them (marked with “-”).")
            } else {
                self.showError("Logic test didn't complete", "Press Log to see minipro's message.")
            }
        }
    }

    @objc func showLogicTestMenu(_ sender: NSButton) {
        let m = NSMenu()
        m.addItem(withTitle: "Standard Test", action: #selector(logicTest(_:)), keyEquivalent: "").target = self
        m.addItem(withTitle: "Extended Test…", action: #selector(extendedLogicTest(_:)), keyEquivalent: "").target = self
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    /// Extended Logic Test: an exhaustive test (combinational chips) or a long sequence test
    /// (flip-flops, latches, counters, shift registers) generated from a working model of the chip,
    /// with neighbour-pin patterns, then the standard vectors repeated a number of times.
    @objc func extendedLogicTest(_ sender: Any?) {
        guard requireChip(), let w = window, !isBusy else { return }
        if let k = chipDetails?.kind, k != .logic {
            showError("\(chip) isn't a logic chip.", "Logic Test works with 74xx and 40xx logic ICs from the logic database, e.g. 7400 or 4011.")
            return
        }
        if logicicText == nil, let url = Minipro.shared.logicic { logicicText = try? String(contentsOf: url) }
        guard let xml = logicicText, let standard = LogicTest.parseXML(xml, name: chip) else {
            showError("\(chip) isn't in the logic database.", "Choose the chip with Search or Logic Ident.")
            return
        }
        let name = chip
        var ext: LogicModels.Extended?
        var modelKey = ""
        if let p = LogicModels.pins(for: name, xml: xml), p.names.count == standard.pins,
           let e = LogicModels.extended(chip: p.key, names: p.names, roles: p.roles) {
            ext = e
            modelKey = p.key
        }

        let box = NSButton(checkboxWithTitle: "Exhaustive / sequence test", target: nil, action: nil)
        let detail = NSTextField(wrappingLabelWithString: "")
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        if let e = ext {
            box.state = .on
            let same = Pinouts.logicBase(name) == modelKey ? "" : " (uses the \(modelKey) model – same function and pinout)"
            detail.stringValue = "\(e.vectors.count) test steps\(same): \(e.description). \(e.checks) output checks in all, worked out from a model of the chip."
        } else {
            box.state = .off
            box.isEnabled = false
            detail.stringValue = "ChipBurner has no working model of \(name) yet, so only the repeated standard test is available. Exhaustive and sequence tests cover the common gates, buffers, decoders, multiplexers, adders, comparators, flip-flops, latches, counters and shift registers."
        }
        let repeatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        let counts = [0, 10, 25, 50, 100]
        for c in counts { repeatPopup.addItem(withTitle: c == 0 ? "Don't repeat" : "\(c) times") }
        let saved = UserDefaults.standard.integer(forKey: "logicRepeats")
        repeatPopup.selectItem(at: counts.firstIndex(of: saved == 0 && UserDefaults.standard.object(forKey: "logicRepeats") == nil ? 10 : saved) ?? 1)
        let repeatRow = NSStackView(views: [NSTextField(labelWithString: "Repeat the standard test:"), repeatPopup])
        repeatRow.orientation = .horizontal
        let note = NSTextField(wrappingLabelWithString: "Repeated runs catch chips that fail now and then (marginal or overheating parts). The TL866A tests at a fixed 5 V.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [box, detail, repeatRow, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        for v in [detail, note] { v.preferredMaxLayoutWidth = 360; v.widthAnchor.constraint(equalToConstant: 360).isActive = true }
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: stack.fittingSize.height)
        let a = NSAlert()
        a.messageText = "Extended Logic Test – \(name)"
        a.informativeText = "Put the chip in the socket bottom-aligned with pin 1 at the lever end. Stop ends the test early."
        a.accessoryView = stack
        a.addButton(withTitle: "Start")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { [weak self] resp in
            guard let self = self, resp == .alertFirstButtonReturn else { return }
            let repeats = counts[max(0, repeatPopup.indexOfSelectedItem)]
            UserDefaults.standard.set(repeats, forKey: "logicRepeats")
            let useExt = box.state == .on ? ext : nil
            if useExt == nil && repeats == 0 { return }
            self.scanCancelled = false
            var report: [String] = []
            var failed = false
            let finish: (Bool) -> Void = { [weak self] stopped in
                guard let self = self else { return }
                if stopped { report.append("Stopped before the end.") }
                let text = report.joined(separator: "\n")
                self.log("Extended logic test \(name):\n" + text)
                if failed { self.showError("\(name) failed the extended test", text + "\n\nPress Log to see the vectors (failing pins are marked with “-”).") }
                else if stopped { self.showInfo("Extended test of \(name) stopped", text) }
                else { self.showInfo("\(name) passed the extended test", text) }
            }
            var runRepeats: ((Int, Int) -> Void)!
            runRepeats = { [weak self] k, fails in
                guard let self = self else { return }
                if k > repeats {
                    if repeats > 0 {
                        report.append(fails == 0 ? "✓ Standard test: passed all \(repeats) runs." : "✗ Standard test: failed \(fails) of \(repeats) runs.")
                        if fails > 0 { failed = true }
                    }
                    finish(false); return
                }
                if self.scanCancelled {
                    report.append(fails == 0 ? "✓ Standard test: passed \(k - 1) of \(repeats) runs." : "✗ Standard test: failed \(fails) of \(k - 1) runs.")
                    if fails > 0 { failed = true }
                    finish(true); return
                }
                self.runJob("Logic test \(name) – run \(k) of \(repeats)", ["-p", name, "-T"]) { ok, output in
                    let passed = ok && Self.failingVectorLines(output).isEmpty
                    if !passed && !output.contains("Logic test failed") && Self.failingVectorLines(output).isEmpty {
                        // minipro didn't get as far as testing (stopped, or the programmer went away)
                        report.append("Standard test run \(k) didn't complete.")
                        if !self.scanCancelled { failed = true }
                        finish(self.scanCancelled); return
                    }
                    runRepeats(k + 1, fails + (passed ? 0 : 1))
                }
            }
            guard let e = useExt else { runRepeats(1, 0); return }
            let test = LogicTest(name: "CBX" + standard.safeName, pins: standard.pins, voltage: standard.voltage, vectors: e.vectors)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ChipBurner", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("extended-logicic.xml")
            do { try test.xml().write(to: url, atomically: true, encoding: .utf8) } catch {
                self.showError("Could not write the test file.", error.localizedDescription); return
            }
            self.runJob("Extended logic test \(name) (\(e.vectors.count) steps)", ["-p", test.safeName, "-T"], logicic: url) { ok, output in
                let r = LogicTest.parseResult(output)
                if r.passed && ok && r.failingVectors.isEmpty {
                    report.append("✓ Exhaustive / sequence test: all \(e.vectors.count) steps (\(e.checks) output checks) passed.")
                } else if !r.failingVectors.isEmpty {
                    failed = true
                    var byPhase: [String: Int] = [:]
                    for v in r.failingVectors { byPhase[e.phase(ofVector: v), default: 0] += 1 }
                    let parts = e.phases.compactMap { p in byPhase[p.name].map { "\($0) in \(p.name)" } }
                    let first = r.failingVectors.prefix(8).map { String(format: "%04d", $0) }.joined(separator: ", ")
                    report.append("✗ Exhaustive / sequence test: \(r.errors) wrong pin state(s) in \(r.failingVectors.count) of \(e.vectors.count) steps – " + parts.joined(separator: ", ") + ". First failing steps: \(first)\(r.failingVectors.count > 8 ? " …" : "").")
                } else {
                    report.append(self.scanCancelled ? "Exhaustive / sequence test stopped." : "✗ Exhaustive / sequence test didn't run – see the log for minipro's message.")
                    if !self.scanCancelled { failed = true }
                    finish(self.scanCancelled); return
                }
                runRepeats(1, 0)
            }
        }
    }

    /// minipro marks a pin that didn't match with "-" right after the expected state. Only the vector
    /// rows ("0012: 0  L- X …") count – other output (messages, file paths) may contain hyphens too.
    /// minipro's own verdict wins when it says the test was successful.
    static func failingVectorLines(_ output: String) -> [String] {
        let lines = output.components(separatedBy: .newlines)
        if lines.contains(where: { $0.contains("Logic test successful") }) { return [] }
        return lines.filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.range(of: "^[0-9]{4}:", options: .regularExpression) != nil else { return false }
            return t.dropFirst(5).split(separator: " ").contains { $0.count == 2 && $0.hasSuffix("-") && "01HLZXCGV".contains($0.first!) }
        }
    }

    /// Logic chips have no ID, so this runs the test vectors of every candidate with the chosen pin count
    /// and lists the ones the chip passes.
    @objc func identifyLogic(_ sender: Any?) {
        guard let w = window, !isBusy else { return }
        let db = ChipDatabase.shared
        guard db.isLoaded else { showError("The chip database is still loading.", "Try again in a moment."); return }
        let counts = db.logicPinCounts.filter { !db.logicGroups(pins: $0, standardPowerOnly: true).isEmpty }
        guard !counts.isEmpty else { showError("No logic chips in the database.", ""); return }
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26), pullsDown: false)
        for c in counts {
            popup.addItem(withTitle: "\(c) pins (\(db.logicGroups(pins: c, standardPowerOnly: true).count) chip types)")
        }
        if let i = counts.firstIndex(of: UserDefaults.standard.integer(forKey: "logicPins")) { popup.selectItem(at: i) }
        else if let i = counts.firstIndex(of: 14) { popup.selectItem(at: i) }
        let a = NSAlert()
        a.messageText = "Logic Ident"
        a.informativeText = "Put the chip in the socket bottom-aligned with pin 1 at the lever end, and choose its pin count. ChipBurner runs the 5 V test of every chip type with ground on the last pin of the first row and supply on the last pin, and lists the ones it passes. This takes about a second per type; Stop ends it early."
        a.accessoryView = popup
        a.addButton(withTitle: "Start")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { [weak self] resp in
            guard let self = self, resp == .alertFirstButtonReturn else { return }
            let pins = counts[max(0, popup.indexOfSelectedItem)]
            UserDefaults.standard.set(pins, forKey: "logicPins")
            self.runLogicScan(pins: pins)
        }
    }

    private func runLogicScan(pins: Int) {
        let groups = ChipDatabase.shared.logicGroups(pins: pins, standardPowerOnly: true)
        guard !groups.isEmpty else { return }
        isBusy = true
        scanCancelled = false
        progress.doubleValue = 0
        log("▶︎ Identify logic: testing \(groups.count) \(pins)-pin chip types")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var passed: [[String]] = []
            var abortReason: String?
            var tested = 0
            for (i, g) in groups.enumerated() {
                guard let self = self else { return }
                if self.scanCancelled { abortReason = "Stopped."; break }
                let name = g[0]
                DispatchQueue.main.async {
                    self.setStatus("Testing \(g.joined(separator: " / ")) (\(i + 1) of \(groups.count))")
                    self.progress.doubleValue = Double(i) / Double(groups.count) * 100
                }
                let r = Minipro.shared.runSync(["-p", name, "-T"])
                tested += 1
                let lower = r.output.lowercased()
                if lower.contains("overcurrent") {
                    abortReason = "minipro reported overcurrent while testing \(name). Check the chip's orientation and pin count."
                    DispatchQueue.main.async { self.log(r.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    break
                }
                if lower.contains("no programmer") || lower.contains("not found") && lower.contains("programmer") {
                    abortReason = "The programmer isn't responding. Check the USB cable."
                    break
                }
                let ok = r.status == 0 && Self.failingVectorLines(r.output).isEmpty
                if ok { passed.append(g) }
                DispatchQueue.main.async { self.log("\(g.joined(separator: " / ")): \(ok ? "PASS" : "fail")") }
            }
            DispatchQueue.main.async {
                guard let self = self, let w = self.window else { return }
                self.isBusy = false
                self.progress.doubleValue = abortReason == nil ? 100 : 0
                self.setStatus("Identify logic: \(passed.count) match(es) after \(tested) of \(groups.count) types")
                self.log("✓ Identify logic finished: \(passed.count) match(es).")
                if let reason = abortReason, passed.isEmpty {
                    self.showError("Identify stopped", reason)
                    return
                }
                guard !passed.isEmpty else {
                    self.showError("No match", "The chip didn't pass any \(pins)-pin test. Check that it is seated correctly, or that it isn't one with non-standard power pins (such as the 7490) – those can be tested one by one with Logic Test.")
                    return
                }
                let names = passed.map { $0.joined(separator: " / ") }
                let picker = ChipSearchController(title: "Logic chips the chip passed", results: names) { [weak self] choice in
                    guard let self = self, let choice = choice else { return }
                    let first = choice.components(separatedBy: " / ").first ?? choice
                    self.selectChip(first)
                }
                picker.present(on: w)
            }
        }
    }

    @objc func stop(_ sender: Any?) {
        if isBusy { scanCancelled = true }
        if isBusy && running == nil { scanCancelled = true; log("Stopping after the current chip…"); return }
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
        var out = buffer
        if m.ext == "conf" {
            // minipro splits its config file at whitespace, so "hfuse = 0xd9" must become "hfuse=0xd9".
            let text = String(decoding: buffer, as: UTF8.self)
            out = Data(text.replacingOccurrences(of: "[ \\t]*=[ \\t]*", with: "=", options: .regularExpression).utf8)
        }
        do { try out.write(to: url); return url } catch {
            showError("Could not write a temporary file.", error.localizedDescription)
            return nil
        }
    }

    // MARK: Files

    /// Open…: .bin, Intel HEX or S-record (detected from the name or content), .jed/.conf as text,
    /// with the EPROM pair tools (even/odd bytes, halves, interleaving two files, byte swap, placing at an address).
    @objc func openFile(_ sender: Any?) {
        guard let w = window, !isBusy else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Load a binary, Intel HEX or Motorola S-record file (or a .jed/.conf fuse file)."
        let opts = LoadOptions(canPlace: !buffer.isEmpty && !bufferIsText)
        panel.accessoryView = opts.view
        panel.isAccessoryViewDisclosed = true
        panel.beginSheetModal(for: w) { [weak self] resp in
            guard let self = self, resp == .OK, let url = panel.url else { return }
            do {
                let raw = try Data(contentsOf: url)
                let ext = url.pathExtension.lowercased()
                if ["jed", "conf", "txt", "fuses"].contains(ext) {
                    self.buffer = raw
                    self.bufferIsText = true; self.bufferExt = ext == "jed" ? "jed" : "conf"
                    self.bufferName = url.lastPathComponent
                    self.updateBufferViews()
                    self.log("Loaded \(url.lastPathComponent) (\(raw.count) bytes).")
                    return
                }
                let fmt = FileFormat.detect(url, raw)
                let first = opts.apply(try fmt.decode(raw))
                switch opts.combine {
                case .none:
                    self.finishLoad(first, name: url.lastPathComponent, swap: opts.swap, format: fmt)
                case .placeAt:
                    guard let at = BufferOps.parseNumber(opts.address), at >= 0, at <= 256 << 20 else {
                        self.showError("Invalid address.", self.numberHelp); return
                    }
                    self.place(opts.swap ? PairTools.swap16(first) : first, at: at, name: url.lastPathComponent)
                case .thisIsEven, .thisIsOdd, .append:
                    DispatchQueue.main.async { self.loadSecond(first: first, firstName: url.lastPathComponent, opts: opts) }
                }
            } catch {
                self.showError("Could not load \(url.lastPathComponent).", error.localizedDescription)
            }
        }
    }

    private func loadSecond(first: Data, firstName: String, opts: LoadOptions) {
        guard let w = window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        switch opts.combine {
        case .thisIsEven: panel.message = "\(firstName) holds the even bytes. Now choose the ODD (high) EPROM file."
        case .thisIsOdd: panel.message = "\(firstName) holds the odd bytes. Now choose the EVEN (low) EPROM file."
        default: panel.message = "Choose the file to append after \(firstName)."
        }
        panel.beginSheetModal(for: w) { [weak self] resp in
            guard let self = self, resp == .OK, let url = panel.url else { return }
            do {
                let raw = try Data(contentsOf: url)
                let second = try FileFormat.detect(url, raw).decode(raw)
                let result: Data
                switch opts.combine {
                case .thisIsEven: result = PairTools.interleave(even: first, odd: second)
                case .thisIsOdd: result = PairTools.interleave(even: second, odd: first)
                default: result = first + second
                }
                if (opts.combine == .thisIsEven || opts.combine == .thisIsOdd) && first.count != second.count {
                    self.log("Note: the two EPROM files differ in size (\(first.count) and \(second.count) bytes); the shorter one was padded with FF.")
                }
                let name = opts.combine == .append ? "\(firstName) + \(url.lastPathComponent)" : "\(firstName) ⇄ \(url.lastPathComponent)"
                self.finishLoad(result, name: name, swap: opts.swap, format: .binary)
            } catch {
                self.showError("Could not load \(url.lastPathComponent).", error.localizedDescription)
            }
        }
    }

    private func finishLoad(_ data: Data, name: String, swap: Bool, format: FileFormat) {
        buffer = swap ? PairTools.swap16(data) : data
        bufferIsText = false
        bufferExt = "bin"
        bufferName = name
        updateBufferViews()
        log("Loaded \(name) (\(buffer.count) bytes\(format == .binary ? "" : ", " + format.title)\(swap ? ", bytes swapped" : "")).")
    }

    /// Writes data into the current buffer at an address (extending it with FF if needed); undoable.
    private func place(_ data: Data, at: Int, name: String) {
        let count = buffer.count
        hexEditor.edit { b -> Range<Int>? in
            if at > count { b.replace(count..<count, with: Data(repeating: 0xFF, count: at - count)) }
            return b.replace(at..<min(at + data.count, b.count), with: data)
        }
        log("Placed \(name) (\(data.count) bytes) at \(hexAddr(at)).")
    }

    // MARK: PLD / GAL / JED

    /// The JED… button's menu (also the PLD menu in the menu bar).
    static func makePLDMenu() -> NSMenu {
        let m = NSMenu(title: "PLD")
        let newItem = NSMenuItem(title: "New PLD Source", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "New PLD Source")
        for chip in ["GAL16V8", "GAL20V8", "GAL22V10", "GAL20RA10"] {
            let it = NSMenuItem(title: chip, action: #selector(newPLDSource(_:)), keyEquivalent: "")
            it.representedObject = chip
            sub.addItem(it)
        }
        newItem.submenu = sub
        m.addItem(newItem)
        m.addItem(withTitle: "Open PLD Source…", action: #selector(openPLDSource(_:)), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Decode JED to Equations…", action: #selector(decodeJED(_:)), keyEquivalent: "e")
        m.addItem(withTitle: "Open .jed into Buffer…", action: #selector(openJEDIntoBuffer(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Save Buffer as .jed…", action: #selector(saveBufferAsJED(_:)), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "GAL Functional Test…", action: #selector(galFunctionalTest(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Logic Test Vectors…", action: #selector(customLogicTest(_:)), keyEquivalent: "")
        m.addItem(withTitle: "PAL Readout → GAL Clone…", action: #selector(palReadout(_:)), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Supported PLDs…", action: #selector(showSupportedPLDs(_:)), keyEquivalent: "")
        return m
    }

    private func openVectorEditor(_ test: LogicTest, title: String, notes: [String]) {
        let c = LogicVectorWindowController(test: test, title: title, notes: notes) { [weak self] title, args, url, done in
            guard let self = self else { return }
            if self.isBusy { NSSound.beep(); done(false, "Another job is still running."); return }
            self.runJob(title, args, logicic: url, then: done)
        }
        c.showWindow(nil)
    }

    /// Generates logic-tester vectors from a .jed (buffer or file) and opens them in the vector editor.
    @objc func galFunctionalTest(_ sender: Any?) {
        guard let w = window else { return }
        func start(_ text: String, _ name: String) {
            do {
                let design = try GalDecoder.decode(try JEDECFile.parse(text), hint: chip.isEmpty ? nil : chip)
                let g = GalTestGenerator.generate(design)
                var notes = ["Functional test of a programmed \(design.chip.rawValue) from \(name): \(g.test.vectors.count) vectors, checking output pin(s) \(g.checkedOutputs.map(String.init).joined(separator: ", "))."]
                notes += g.notes
                notes.append("Put the programmed GAL in the socket (bottom-aligned, pin 1 at the lever end) and press Run Test. The test only reads and drives pins; it doesn't change the GAL.")
                if design.securityBit { notes.append("This .jed has the security fuse set – that doesn't matter for this test.") }
                openVectorEditor(g.test, title: "GAL Functional Test – \(name)", notes: notes)
            } catch {
                showError("Can't build a test from \(name).", "\(error)")
            }
        }
        if bufferIsText && bufferExt == "jed" && !buffer.isEmpty {
            start(String(decoding: buffer, as: UTF8.self), bufferName)
            return
        }
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["jed", "JED"]
        panel.message = "Choose the .jed the GAL was programmed with."
        panel.beginSheetModal(for: w) { resp in
            guard resp == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
            start(String(decoding: data, as: UTF8.self), url.lastPathComponent)
        }
    }

    @objc func palReadout(_ sender: Any?) {
        let c = PalReadoutWindowController { [weak self] title, args, url, done in
            guard let self = self else { return }
            if self.isBusy { NSSound.beep(); done(false, "Another job is still running."); return }
            self.runJob(title, args, logicic: url, then: done)
        }
        c.onLoadJED = { [weak self] jed, name in self?.loadJEDIntoBuffer(jed, name: name, chipType: "GAL16V8") }
        c.onOpenSource = { [weak self] src in self?.openPLDEditor(source: src, url: nil) }
        c.showWindow(nil)
    }

    @objc func customLogicTest(_ sender: Any?) {
        var start = LogicTest(name: "CUSTOM", pins: 14, voltage: "5V", vectors: [])
        if chipDetails?.kind == .logic, let url = Minipro.shared.logicic, let text = try? String(contentsOf: url),
           let t = LogicTest.parseXML(text, name: chip) {
            start = t
            start.name = chip + "_MOD"
        }
        openVectorEditor(start, title: "Logic Test Vectors", notes: [
            "Write your own test vectors, or start from a database chip with From Database…, and press Run Test.",
            "Each line is one test step; the tester drives the 0/1/C pins, then checks the L/H/Z pins.",
        ])
    }

    @objc func showPLDMenu(_ sender: NSButton) {
        let m = Self.makePLDMenu()
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc func newPLDSource(_ sender: NSMenuItem) {
        let name = (sender.representedObject as? String) ?? "GAL16V8"
        guard let chip = GalAssembler.Chip(rawValue: name) else { return }
        openPLDEditor(source: GalAssembler.template(for: chip), url: nil)
    }

    @objc func openPLDSource(_ sender: Any?) {
        guard let w = window else { return }
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["pld", "PLD", "txt"]
        panel.message = "Choose a galasm-style PLD source file."
        panel.beginSheetModal(for: w) { [weak self] resp in
            guard let self = self, resp == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
            self.openPLDEditor(source: String(decoding: data, as: UTF8.self), url: url)
        }
    }

    private func openPLDEditor(source: String, url: URL?) {
        let ed = PLDEditorWindowController(source: source, fileURL: url)
        ed.onLoadIntoBuffer = { [weak self] jed, name, chipType in
            self?.loadJEDIntoBuffer(jed, name: name, chipType: chipType)
        }
        ed.showWindow(nil)
    }

    /// Puts an assembled or opened .jed into the buffer and selects a matching chip if none is chosen.
    private func loadJEDIntoBuffer(_ jed: String, name: String, chipType: String?) {
        buffer = Data(jed.utf8)
        bufferIsText = true
        bufferExt = "jed"
        bufferName = name
        updateBufferViews()
        log("Loaded \(name) into the buffer.")
        guard let type = chipType else { return }
        let current = chip.uppercased()
        let family = type.replacingOccurrences(of: "GAL", with: "")
        if current.contains(family) { return }
        if ChipDatabase.shared.info(for: type, programmer: Minipro.shared.programmerType) != nil {
            selectChip(type)
            log("Chip set to \(type) to match the fuse map; pick the exact variant (e.g. \(type)B or ATF\(family)B) with Search if needed.")
        } else {
            log("Note: \(type) isn't in the \(Minipro.shared.programmerType) database, so this programmer can't program it.")
        }
    }

    @objc func openJEDIntoBuffer(_ sender: Any?) {
        guard let w = window else { return }
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["jed", "JED"]
        panel.beginSheetModal(for: w) { [weak self] resp in
            guard let self = self, resp == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
            let text = String(decoding: data, as: UTF8.self)
            let type = (try? JEDECFile.parse(text)).flatMap { j in GalDecoder.chipType(fuseCount: j.declaredCount ?? j.fuses.count) }?.rawValue
            self.loadJEDIntoBuffer(text, name: url.lastPathComponent, chipType: type)
        }
    }

    @objc func saveBufferAsJED(_ sender: Any?) {
        guard bufferIsText && bufferExt == "jed" && !buffer.isEmpty else {
            showError("The buffer doesn't hold a .jed fuse map.", "Read a GAL, open a .jed file, or assemble a PLD source first.")
            return
        }
        saveFile(nil)
    }

    @objc func showSupportedPLDs(_ sender: Any?) {
        let plds = ChipDatabase.shared.isLoaded ? ChipDatabase.shared.names(of: .pld, programmer: Minipro.shared.programmerType) : []
        let programmable = plds.isEmpty ? "(chip database still loading)" : plds.filter { !$0.contains("@") }.joined(separator: ", ")
        showInfo("PLDs, GALs and .jed files", """
            Assembler and decoder: GAL16V8, GAL20V8, GAL22V10 and GAL20RA10 – and the pin- and             fuse-compatible ATF16V8B, ATF20V8B and ATF22V10 – in galasm/Galette source syntax.

            The \(Minipro.shared.programmerType) programs: \(programmable).

            The GAL20RA10 can be assembled and decoded here, but the TL866A can't program it.
            """)
    }

    /// Decodes the .jed in the buffer (or a chosen .jed file) into equations and a gate diagram.
    private var currentConfig: ChipConfig? {
        guard let info = chipDetails, let c = ChipDatabase.shared.config(for: info), !c.isEmpty else { return nil }
        return c
    }

    @objc func openConfigWindow(_ sender: Any?) {
        guard requireChip(), connectionAllowed() else { return }
        guard let config = currentConfig else {
            showError("\(chip) has no fuses, user ID or lock bits in the database.", "")
            return
        }
        var base = ["-p", chip] + connectionArgs
        if skipID.state == .on { base.append("-y") }
        let info = chipDetails
        let c = ConfigWindowController(chip: chip, config: config, wordSize: info?.wordSize ?? 1,
                                       lockWriteOnly: info?.lockBitWriteOnly ?? false, baseArgs: base) { [weak self] title, args, done in
            guard let self = self else { return }
            if self.isBusy { NSSound.beep(); done(false, "Another job is still running."); return }
            self.runJob(title, args, then: done)
        }
        c.showWindow(nil)
    }

    @objc func openChipTest(_ sender: Any?) {
        guard requireChip(), connectionAllowed(), !isBusy else { return }
        guard let info = chipDetails, info.codeSize > 0, info.kind == .sram || info.kind == .memory else {
            showError("Chip Test isn't available for \(chip).", "It works with SRAM and with EPROM, EEPROM and flash memory chips.")
            return
        }
        var readArgs = ["-p", chip] + connectionArgs
        if skipID.state == .on { readArgs.append("-x") }
        var writeArgs = ["-p", chip] + connectionArgs
        if skipID.state == .on { writeArgs.append("-y") }
        if allowSize.state == .on { writeArgs.append("-s") }
        writeArgs += protectionArgs(.write)
        let method = eraseMethod
        let canWrite: Bool
        let note: String
        switch method {
        case .command, .fill: canWrite = info.kind == .memory && !Self.isUVEPROM(chip); note = ""
        case .unavailable: canWrite = false; note = Self.isUVEPROM(chip) ? "not for UV EPROMs – they can only be erased with UV light" : "not available for this chip"
        }
        let setup = ChipTestWindowController.Setup(
            chip: chip, kind: info.kind == .sram ? .sram : .memory, size: info.codeSize,
            readArgs: readArgs, writeArgs: writeArgs, canWriteTest: canWrite,
            writeTestNote: canWrite ? "" : note,
            buffer: (!bufferIsText && buffer.count == info.codeSize) ? buffer : nil,
            batteryBacked: chip.uppercased().range(of: "^(DS12|BQ40)", options: .regularExpression) != nil)
        let c = ChipTestWindowController(setup: setup) { [weak self] title, args, done in
            guard let self = self else { return }
            if self.isBusy { NSSound.beep(); done(false, "Another job is still running."); return }
            self.runJob(title, args, then: done)
        }
        c.showWindow(nil)
    }

    @objc func decodeJED(_ sender: Any?) {
        guard let w = window else { return }
        let hint = chip.isEmpty ? nil : chip
        if bufferIsText && bufferExt == "jed" && !buffer.isEmpty {
            GalDecoderWindowController.show(jedText: String(decoding: buffer, as: UTF8.self),
                                            sourceName: bufferName, chipHint: hint, on: w)
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedFileTypes = ["jed", "JED"]
        panel.message = "Choose a JEDEC fuse map (.jed) for a GAL16V8, GAL20V8 or GAL22V10."
        panel.beginSheetModal(for: w) { resp in
            guard resp == .OK, let url = panel.url else { return }
            guard let data = try? Data(contentsOf: url) else { return }
            GalDecoderWindowController.show(jedText: String(decoding: data, as: UTF8.self),
                                            sourceName: url.lastPathComponent, chipHint: hint, on: w)
        }
    }

    /// Save…: binary, Intel HEX or S-record, with the EPROM pair tools (even/odd bytes, both EPROMs as
    /// two files, halves, selection, byte swap). Text buffers (.jed/.conf) are saved as they are.
    @objc func saveFile(_ sender: Any?) {
        guard let w = window else { return }
        guard !buffer.isEmpty else { showError("The buffer is empty.", "Nothing to save yet."); return }
        let panel = NSSavePanel()
        let base = chip.isEmpty ? "dump" : chip.replacingOccurrences(of: "@", with: "_")
        if bufferIsText {
            panel.nameFieldStringValue = base + "." + bufferExt
            panel.allowedFileTypes = [bufferExt]
            panel.beginSheetModal(for: w) { [weak self] resp in
                guard let self = self, resp == .OK, let url = panel.url else { return }
                do { try self.buffer.write(to: url); self.log("Saved \(url.lastPathComponent).") }
                catch { self.showError("Could not save.", error.localizedDescription) }
            }
            return
        }
        let last = FileFormat(rawValue: UserDefaults.standard.integer(forKey: "saveFormat")) ?? .binary
        panel.nameFieldStringValue = base + "." + last.ext
        let opts = SaveOptions(panel: panel, hasSelection: hexEditor.selection != nil, initial: last)
        panel.accessoryView = opts.view
        let selection = hexEditor.selection
        panel.beginSheetModal(for: w) { [weak self] resp in
            guard let self = self, resp == .OK, let url = panel.url else { return }
            let fmt = opts.format
            guard let start = BufferOps.parseNumber(opts.startAddress.isEmpty ? "0" : opts.startAddress), start >= 0 else {
                self.showError("Invalid start address.", self.numberHelp); return
            }
            UserDefaults.standard.set(fmt.rawValue, forKey: "saveFormat")
            let dir = url.deletingLastPathComponent()
            let stem = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension.isEmpty ? fmt.ext : url.pathExtension
            do {
                var saved: [String] = []
                for out in opts.output(buffer: self.buffer, selection: selection) {
                    let target = out.suffix.isEmpty ? url : dir.appendingPathComponent(stem + out.suffix + "." + ext)
                    try fmt.encode(out.data, startAddress: fmt == .binary ? 0 : start).write(to: target)
                    saved.append("\(target.lastPathComponent) (\(out.data.count) bytes)")
                }
                self.log("Saved " + saved.joined(separator: " and ") + " as \(fmt.title).")
            } catch {
                self.showError("Could not save.", error.localizedDescription)
            }
        }
    }

    // MARK: Smoke test

    /// Fills the window with example content so a build screenshot shows a realistic state.
    func prepareScreenshot() {
        programmerLabel.stringValue = "TL866A v03.2.86"
        selectChip("AM27C256@DIP28")
        var d = Data(repeating: 0xFF, count: 0x8000)
        let text = Array("ChipBurner example buffer – (C) 2026 – AM27C256 32K x 8 UV EPROM ".utf8)
        for i in 0..<0x400 { d[i] = UInt8(truncatingIfNeeded: (i * 37) ^ (i >> 3)) }
        for (i, b) in text.enumerated() { d[0x100 + i] = b }
        buffer = d
        bufferIsText = false
        bufferExt = "bin"
        bufferName = "example.bin"
        updateBufferViews()
        setStatus("Ready")
    }

    /// Build screenshot of the Fuses & Locks window for an example AVR.
    func saveFuseScreenshot(to path: String) {
        guard ChipDatabase.shared.isLoaded, let info = ChipDatabase.shared.info(for: "ATMEGA8A", programmer: "TL866A"),
              let cfg = ChipDatabase.shared.config(for: info) else { print("SMOKE fuse screenshot skipped (database not loaded)"); return }
        let c = ConfigWindowController(chip: "ATMEGA8A", config: cfg, wordSize: info.wordSize, lockWriteOnly: info.lockBitWriteOnly,
                                       baseArgs: []) { _, _, done in done(false, "") }
        c.showWindow(nil)
        guard let content = c.window?.contentView else { return }
        content.layoutSubtreeIfNeeded()
        if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print("SMOKE fuse screenshot saved: \(path)")
        }
    }

    /// Build screenshots of the tool windows (pinout, compare).
    func saveToolScreenshots(base: String) {
        func snap(_ w: NSWindow?, _ suffix: String) {
            guard let content = w?.contentView else { return }
            content.layoutSubtreeIfNeeded()
            if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: base + suffix))
                print("SMOKE screenshot saved: \(base + suffix)")
            }
        }
        if let p = Pinouts.find(chip: "AM27C256@DIP28", size: 32768) {
            let pw = PinoutWindowController(chip: "AM27C256@DIP28", pinout: p)
            pw.showWindow(nil)
            snap(pw.window, "-pinout.png")
            pw.close()
        }
        if let p = Pinouts.find(chip: "AM29F040@PLCC32", size: 524288) {
            let pw = PinoutWindowController(chip: "AM29F040@PLCC32", pinout: p)
            pw.showWindow(nil)
            snap(pw.window, "-pinout-plcc.png")
            pw.close()
        }
        if let url = Minipro.shared.logicic, let xml = try? String(contentsOf: url) {
            for (chip, suffix) in [("74161", "-pinout-logic.png"), ("4520", "-pinout-logic2.png")] {
                if let v = Pinouts.logicVectors(xml: xml, name: chip),
                   let p = Pinouts.logic(name: chip, pins: v.pins, group: v.group, vectors: v.vectors) {
                    let pw = PinoutWindowController(chip: chip, pinout: p)
                    pw.showWindow(nil)
                    snap(pw.window, suffix)
                    pw.close()
                }
            }
        }
        var other = buffer
        if other.count > 0x120 { for i in [0x10, 0x11, 0x12, 0x105, 0x110] { other[i] ^= 0x5A } }
        openCompare(name: "patched.bin", data: other)
        snap(compareWindow?.window, "-compare.png")
        compareWindow?.close()
    }

    /// Renders the window's content to a PNG file.
    func saveScreenshot(to path: String) {
        guard let content = window?.contentView else { return }
        content.layoutSubtreeIfNeeded()
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            print("SMOKE screenshot saved: \(path)")
        }
    }


    /// Run by the build (CHIPBURNER_SMOKETEST=1): reports whether the window came up and where the
    /// main buttons ended up, so layout problems show in the build log.
    func smokeReport() -> Bool {
        guard let w = window, let content = w.contentView else { print("SMOKE FAIL: no window"); return false }
        content.layoutSubtreeIfNeeded()
        var buttons: [String: NSRect] = [:]
        func walk(_ v: NSView) {
            if let b = v as? NSButton, !b.title.isEmpty, b.superview != nil {
                buttons[b.title] = b.convert(b.bounds, to: nil)
            }
            v.subviews.forEach(walk)
        }
        walk(content)
        print("SMOKE window visible=\(w.isVisible) frame=\(NSStringFromRect(w.frame)) content=\(NSStringFromRect(content.frame)) buttons=\(buttons.count)")
        for t in ["Read", "Stop", "Compare w Chip", "Compare w File…", "Redo", "H/W Test…", "Save…", "Open…", "Fuses & Locks…", "Chip Test…", "Chip Ident…", "Logic Ident…", "Chip Info", "Logic Test…", "Voltages…", "Options…"] {
            if let r = buttons[t] { print(String(format: "SMOKE %@ x=%.0f..%.0f y=%.0f..%.0f", t, r.minX, r.maxX, r.minY, r.maxY)) }
            else { print("SMOKE missing button: \(t)") }
        }
        if let stack = content.subviews.first as? NSStackView {
            for (i, v) in stack.views.enumerated() {
                print(String(format: "SMOKE row %d %@ fitting width %.0f", i, String(describing: type(of: v)), v.fittingSize.width))
                if let st = v as? NSStackView {
                    for sv in st.views { print(String(format: "SMOKE    %@ %.0f", (sv as? NSButton)?.title ?? (sv as? NSTextField)?.stringValue ?? String(describing: type(of: sv)), sv.fittingSize.width)) }
                }
            }
        }
        let ok = w.isVisible && buttons.count > 20 && !content.subviews.isEmpty
        print(ok ? "SMOKE OK" : "SMOKE FAIL")
        return ok
    }

    // MARK: Hardware

    /// Hardware… : check which programmer is connected, or run its self-test.
    // MARK: Compare, pinout

    private var logicicText: String?

    private var currentPinout: ChipPinout? {
        guard !chip.isEmpty else { return nil }
        let info = chipDetails
        if info?.kind == .logic {
            if logicicText == nil, let url = Minipro.shared.logicic { logicicText = try? String(contentsOf: url) }
            guard let xml = logicicText, let v = Pinouts.logicVectors(xml: xml, name: chip) else { return nil }
            return Pinouts.logic(name: chip, pins: v.pins, group: v.group, vectors: v.vectors)
        }
        return Pinouts.find(chip: chip, size: info?.codeSize, isSRAM: info?.kind == .sram)
    }

    @objc func showPinout(_ sender: Any?) {
        guard requireChip() else { return }
        guard let p = currentPinout else {
            showInfo("No pinout for \(chip)", "ChipBurner has pinouts for standard (JEDEC) EPROMs, EEPROMs, flash and SRAM in DIP packages, GALs, 8-pin serial memories, the common AVR, PIC and 8051 chips, and the logic chips in the test database. For this one, please check its data sheet.")
            return
        }
        PinoutWindowController(chip: chip, pinout: p).showWindow(nil)
    }

    private func requireBinaryBuffer() -> Bool {
        if buffer.isEmpty { showError("The buffer is empty.", "Open a file or read a chip first."); return false }
        if bufferIsText { showError("The buffer holds a text file.", "Compare works on binary data – open a .bin, .hex or .s19 file, or read a chip."); return false }
        return true
    }

    private func openCompare(name: String, data: Data) {
        compareWindow?.close()
        let hooks = CompareWindowController.Hooks(
            buffer: { [weak self] in self?.hexEditor.data ?? Data() },
            select: { [weak self] r in self?.hexEditor.select(r) },
            mark: { [weak self] s in self?.hexEditor.marked = s },
            replace: { [weak self] r, d in self?.hexEditor.edit { $0.replace(r, with: d) } })
        let c = CompareWindowController(otherName: name, other: data, hooks: hooks)
        c.onClose = { [weak self] in self?.compareWindow = nil }
        compareWindow = c
        c.showWindow(nil)
        log("Comparing the buffer with \(name).")
    }

    @objc func compareWithFile(_ sender: Any?) {
        guard requireBinaryBuffer(), let w = window else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose a file to compare the buffer with (.bin, Intel HEX or S-record)."
        panel.beginSheetModal(for: w) { [weak self] r in
            guard let self = self, r == .OK, let url = panel.url, let raw = try? Data(contentsOf: url) else { return }
            do {
                let data = try FileFormat.detect(url, raw).decode(raw)
                self.openCompare(name: url.lastPathComponent, data: data)
            } catch {
                self.showError("Couldn't read \(url.lastPathComponent)", "\(error)")
            }
        }
    }

    @objc func compareWithChip(_ sender: Any?) {
        guard requireBinaryBuffer(), requireChip(), connectionAllowed() else { return }
        let m = mode
        guard !m.text else { showError("Choose a binary memory area.", "Compare works on code or data memory, not on fuse settings."); return }
        let out = tempURL("compare.\(m.ext)")
        try? FileManager.default.removeItem(at: out)
        runJob("Read \(chip) to compare", ["-p", chip] + connectionArgs + m.memArgs + ["-r", out.path] + optionArgs(.read)) { [weak self] ok, _ in
            guard let self = self, ok, let data = try? Data(contentsOf: out) else { return }
            self.openCompare(name: self.chip, data: data)
        }
    }

    /// Zoom / maximise: keep the width and position, use the screen's full usable height.
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        guard window === self.window else { return newFrame }
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? newFrame
        var x = window.frame.minX
        x = min(max(x, screen.minX), max(screen.minX, screen.maxX - window.frame.width))
        return NSRect(x: x, y: screen.minY, width: window.frame.width, height: screen.height)
    }

    /// H/W Test…: identifies the programmer (model, firmware, serial number) and then runs its own
    /// self-test of the pin drivers and voltages (minipro -t), which needs an empty socket.
    @objc func hwTest(_ sender: Any?) {
        guard let w = window, !isBusy else { return }
        let a = NSAlert()
        a.messageText = "Test the programmer?"
        a.informativeText = "ChipBurner first checks which programmer is connected (model, firmware and serial number), then runs the programmer's own self-test, which drives every socket pin and switches the programming voltages.\n\nTake any chip out of the ZIF socket and unplug the ICSP cable before you start."
        a.addButton(withTitle: "Start Test")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { [weak self] resp in
            guard let self = self, resp == .alertFirstButtonReturn else { return }
            self.setStatus("Checking the programmer…")
            self.detectProgrammer { [weak self] found in
                guard let self = self else { return }
                guard found else {
                    self.showError("No programmer found", "Check the USB cable and that the programmer's LED is on, then try again. The Log has minipro's answer.")
                    return
                }
                let who = self.programmerDetails ?? self.programmerLabel.stringValue
                self.runJob("Programmer self-test", ["-t"]) { [weak self] ok, output in
                    guard let self = self else { return }
                    let lines = output.components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty && !$0.contains("overridden database") }
                    // A line is only a problem if it doesn't say OK ("VPP overcurrent protection is OK." is fine).
                    let problems = lines.filter {
                        $0.range(of: "error|fail|short|overcurrent|bad", options: [.regularExpression, .caseInsensitive]) != nil
                            && $0.range(of: "\\bOK\\.?$", options: .regularExpression) == nil
                            && !$0.localizedCaseInsensitiveContains("completed successfully")
                    }
                    let passed = output.localizedCaseInsensitiveContains("completed successfully") || problems.isEmpty
                    let checks = lines.filter { $0.range(of: "\\bOK\\.?$", options: .regularExpression) != nil }.count
                    let summary = lines.suffix(25).joined(separator: "\n")
                    if ok && passed && problems.isEmpty {
                        self.showInfo("H/W Test passed", "\(who)\n\nAll \(checks) checks passed: VPP, VCC and GND drivers, logic levels on every pin, and VPP/VCC overcurrent protection.\n\nThe full list is in the Log.")
                    } else {
                        self.showError(ok ? "H/W Test found problems" : "The self-test didn't complete",
                                       "\(who)\n\n" + (problems.isEmpty ? summary : problems.joined(separator: "\n")) + "\n\nThe full output is in the Log.")
                    }
                }
            }
        }
    }

    // MARK: Buffer editing

    private func buildBufferEditor() -> NSView {
        let container = NSView()
        textEditor.isEditable = true
        textEditor.allowsUndo = true
        textEditor.delegate = self
        textScroll = scroll(textEditor)
        for v in [hexEditor, textScroll!] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                v.topAnchor.constraint(equalTo: container.topAnchor),
                v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        textScroll.isHidden = true
        hexEditor.onChange = { [weak self] in
            guard let self = self else { return }
            self.buffer = self.hexEditor.data
            self.bufferChanged()
        }
        return container
    }

    private func buildEditRow() -> NSView {
        let items: [(String, Selector)] = [
            ("New…", #selector(newBuffer(_:))), ("Go To…", #selector(goToAddress(_:))),
            ("Find…", #selector(findInBuffer(_:))), ("Find Next", #selector(findNextInBuffer(_:))),
            ("Fill…", #selector(fillBufferRange(_:))), ("Checksum…", #selector(checksumBufferRange(_:))),
            ("Resize…", #selector(resizeBuffer(_:))), ("Undo", #selector(undoBufferEdit(_:))), ("Redo", #selector(redoBufferEdit(_:))),
        ]
        let buttons = items.map { item -> NSButton in
            let b = button(item.0, item.1)
            b.controlSize = .small
            b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            return b
        }
        hexEditor.onSelectionChange = { [weak self] in self?.updateSelectionLabel() }
        updateSelectionLabel()
        let tools = [("Compare w Chip", #selector(compareWithChip(_:))), ("Compare w File…", #selector(compareWithFile(_:)))].map { item -> NSButton in
            let b = button(item.0, item.1)
            b.controlSize = .small
            b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            return b
        }
        // Evenly spread from the editor's left edge to its right edge.
        let r = row(buttons + tools)
        r.distribution = .equalSpacing
        r.spacing = 3
        return r
    }

    /// Called after every edit: marks the buffer edited and refreshes the label (checksums are
    /// recomputed at most a few times a second).
    private func bufferChanged() {
        bufferEdited = true
        guard !labelUpdatePending else { return }
        labelUpdatePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.labelUpdatePending = false
            self?.updateBufferLabel()
            self?.compareWindow?.refresh()
        }
    }

    func textDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextView) === textEditor else { return }
        buffer = Data(textEditor.string.utf8)
        bufferChanged()
    }

    private func updateSelectionLabel() {
        guard !bufferIsText, !buffer.isEmpty else { selectionLabel.stringValue = ""; return }
        if let s = hexEditor.selection {
            selectionLabel.stringValue = " — selected \(hexAddr(s.lowerBound))–\(hexAddr(s.upperBound - 1)) (\(s.count) bytes)"
        } else {
            let a = hexEditor.selectedAddress
            selectionLabel.stringValue = a < buffer.count ? String(format: " — cursor %@ = %02X", hexAddr(a), buffer[a]) : ""
        }
    }

    /// Start/end defaults for range dialogs: the selection, or cursor…end.
    private var defaultRange: (String, String) {
        if let s = hexEditor.selection { return (hexAddr(s.lowerBound), hexAddr(s.upperBound - 1)) }
        return (hexAddr(hexEditor.selectedAddress), hexAddr(max(0, buffer.count - 1)))
    }

    @objc func insertBytes(_ sender: Any?) {
        guard requireBinaryBuffer(allowEmpty: true) else { return }
        askFields("Insert bytes", "Inserts bytes at the cursor\(hexEditor.selection != nil ? ", replacing the selection" : ""); the rest of the buffer moves up. \(numberHelp)",
                  [("Count:", "10"), ("Fill with:", "FF")], ok: "Insert") { [weak self] v in
            guard let self = self else { return }
            guard let n = BufferOps.parseNumber(v[0]), n > 0, n <= 16 << 20 else { self.showError("Invalid count.", self.numberHelp); return }
            guard let p = BufferOps.parsePattern(v[1]), !p.contains(where: { $0 == nil }) else { self.showError("Invalid fill value.", "Use hex bytes such as FF or a pattern such as 55 AA."); return }
            self.hexEditor.insert(BufferOps.fill(count: n, pattern: p.compactMap { $0 }))
            self.log("Inserted \(n) bytes.")
        }
    }

    private func requireBinaryBuffer(allowEmpty: Bool = false) -> Bool {
        if bufferIsText {
            showError("The buffer holds a .\(bufferExt) text file.", "Edit it directly in the text view. Fill, Find and the other byte tools work on binary data.")
            return false
        }
        if !allowEmpty && buffer.isEmpty {
            showError("The buffer is empty.", "Open a file, read a chip or use New… first.")
            return false
        }
        return true
    }

    /// A sheet with labelled text fields; `done` gets the values, or isn't called on Cancel.
    private func askFields(_ title: String, _ info: String, _ fields: [(label: String, value: String)],
                           ok: String = "OK", done: @escaping ([String]) -> Void) {
        guard let w = window else { return }
        var inputs: [NSTextField] = []
        var rows: [[NSView]] = []
        for f in fields {
            let l = NSTextField(labelWithString: f.label)
            l.alignment = .right
            let t = NSTextField(string: f.value)
            t.font = NSFont.userFixedPitchFont(ofSize: 12)
            t.widthAnchor.constraint(equalToConstant: 220).isActive = true
            inputs.append(t)
            rows.append([l, t])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.frame.size = grid.fittingSize
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.accessoryView = grid
        a.addButton(withTitle: ok)
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = inputs.first
        a.beginSheetModal(for: w) { resp in
            guard resp == .alertFirstButtonReturn else { return }
            done(inputs.map { $0.stringValue })
        }
    }

    private func hexAddr(_ v: Int) -> String {
        String(format: "%0\(BufferOps.addressDigits(for: buffer.count))X", v)
    }

    private let numberHelp = "Numbers are hexadecimal (1F00, 0x1F00, $1F00). Use #8192 for decimal or 32K / 1M for sizes."

    @objc func newBuffer(_ sender: Any?) {
        guard !isBusy else { return }
        let size = chipDetails.map { $0.codeSize } ?? 0
        askFields("New buffer", "Creates an empty buffer filled with one value. \(numberHelp)",
                  [("Size:", size > 0 ? String(format: "%X", size) : "8000"), ("Fill with:", "FF")], ok: "Create") { [weak self] v in
            guard let self = self else { return }
            guard let n = BufferOps.parseNumber(v[0]), n > 0, n <= 256 << 20 else { self.showError("Invalid size.", self.numberHelp); return }
            guard let p = BufferOps.parsePattern(v[1]), !p.contains(where: { $0 == nil }) else { self.showError("Invalid fill value.", "Use hex bytes such as FF or 00, or a pattern such as 55 AA."); return }
            self.buffer = BufferOps.fill(count: n, pattern: p.compactMap { $0 })
            self.bufferIsText = false
            self.bufferExt = "bin"
            self.bufferName = "new"
            self.updateBufferViews()
            self.log("New buffer: \(n) bytes of \(v[1]).")
        }
    }

    @objc func goToAddress(_ sender: Any?) {
        guard requireBinaryBuffer() else { return }
        askFields("Go to address", numberHelp, [("Address:", hexAddr(hexEditor.selectedAddress))], ok: "Go") { [weak self] v in
            guard let self = self else { return }
            guard let a = BufferOps.parseNumber(v[0]), a >= 0, a < self.buffer.count else {
                self.showError("Address out of range.", "The buffer ends at \(self.hexAddr(max(0, self.buffer.count - 1))).")
                return
            }
            self.hexEditor.show(a..<(a + 1))
            self.hexEditor.cursor = a
        }
    }

    @objc func findInBuffer(_ sender: Any?) {
        guard requireBinaryBuffer() else { return }
        askFields("Find in buffer", "Hex bytes such as 55 AA or C3 ?? ?? (?? matches any byte), or text in quotes such as \"COPYRIGHT\". The search continues from the last hit and wraps around.",
                  [("Find:", lastFindPattern)], ok: "Find") { [weak self] v in
            guard let self = self else { return }
            self.lastFindPattern = v[0]
            self.runFind(from: self.hexEditor.cursor)
        }
    }

    @objc func findNextInBuffer(_ sender: Any?) {
        guard requireBinaryBuffer() else { return }
        if lastFindPattern.isEmpty { findInBuffer(sender); return }
        runFind(from: hexEditor.cursor)
    }

    private func runFind(from start: Int) {
        guard let p = BufferOps.parsePattern(lastFindPattern) else {
            showError("Can't read the search pattern.", "Use hex bytes (55 AA, ?? for any byte) or text in quotes.")
            return
        }
        guard let hit = BufferOps.find(p, in: buffer, from: start) else {
            setStatus("Not found: \(lastFindPattern)")
            NSSound.beep()
            return
        }
        hexEditor.show(hit..<(hit + p.count))
        hexEditor.cursor = hit + 1
        setStatus("Found \(lastFindPattern) at \(hexAddr(hit))" + (hit < start ? " (wrapped around)" : ""))
    }

    private func parseRange(_ startText: String, _ endText: String) -> Range<Int>? {
        guard let a = BufferOps.parseNumber(startText), let b = BufferOps.parseNumber(endText),
              a >= 0, b >= a, b < buffer.count else {
            showError("Invalid range.", "Start and end must lie inside the buffer (0 to \(hexAddr(max(0, buffer.count - 1)))), with end ≥ start. \(numberHelp)")
            return nil
        }
        return a..<(b + 1)
    }

    @objc func fillBufferRange(_ sender: Any?) {
        guard requireBinaryBuffer() else { return }
        askFields("Fill range", "Fills from start to end (both included) with a byte or a repeating pattern. \(numberHelp)",
                  [("Start:", defaultRange.0), ("End:", defaultRange.1), ("Fill with:", "FF")], ok: "Fill") { [weak self] v in
            guard let self = self, let r = self.parseRange(v[0], v[1]) else { return }
            guard let p = BufferOps.parsePattern(v[2]), !p.contains(where: { $0 == nil }) else {
                self.showError("Invalid fill value.", "Use hex bytes such as FF, or a pattern such as 55 AA, or text in quotes.")
                return
            }
            let bytes = BufferOps.fill(count: r.count, pattern: p.compactMap { $0 })
            self.hexEditor.edit { $0.replace(r, with: bytes) }
            self.log("Filled \(self.hexAddr(r.lowerBound))–\(self.hexAddr(r.upperBound - 1)) with \(v[2]).")
        }
    }

    @objc func checksumBufferRange(_ sender: Any?) {
        guard requireBinaryBuffer() else { return }
        askFields("Checksum of range", "Start and end are both included. \(numberHelp)",
                  [("Start:", hexEditor.selection != nil ? defaultRange.0 : hexAddr(0)), ("End:", hexEditor.selection != nil ? defaultRange.1 : hexAddr(buffer.count - 1))], ok: "Calculate") { [weak self] v in
            guard let self = self, let r = self.parseRange(v[0], v[1]) else { return }
            let c = BufferOps.checksums(self.buffer.subdata(in: r))
            let text = String(format: """
                Range %@–%@ (%d bytes)

                Sum, 8-bit:    0x%02X   (two's complement 0x%02X)
                Sum, 16-bit:   0x%04X
                Sum, 32-bit:   0x%08X
                XOR, 8-bit:    0x%02X
                CRC-32:        0x%08X
                """, self.hexAddr(r.lowerBound), self.hexAddr(r.upperBound - 1), r.count,
                c.sum8, c.twosComplement8, c.sum16, c.sum32, c.xor8, c.crc32)
            self.log(text.replacingOccurrences(of: "\n\n", with: "\n"))
            self.showInfo("Checksums", text)
        }
    }

    @objc func resizeBuffer(_ sender: Any?) {
        guard requireBinaryBuffer(allowEmpty: true) else { return }
        let target = chipDetails.map { $0.codeSize } ?? 0
        askFields("Resize buffer", "Cuts the buffer short, or extends it with the pad value. Currently \(hexAddr(buffer.count)) (\(buffer.count)) bytes. \(numberHelp)",
                  [("New size:", String(format: "%X", target > 0 ? target : buffer.count)), ("Pad with:", "FF")], ok: "Resize") { [weak self] v in
            guard let self = self else { return }
            guard let n = BufferOps.parseNumber(v[0]), n > 0, n <= 256 << 20 else { self.showError("Invalid size.", self.numberHelp); return }
            guard let p = BufferOps.parsePattern(v[1]), !p.contains(where: { $0 == nil }) else { self.showError("Invalid pad value.", "Use a hex byte such as FF."); return }
            let old = self.buffer.count
            if n > old {
                self.hexEditor.edit { $0.replace(old..<old, with: BufferOps.fill(count: n - old, pattern: p.compactMap { $0 })) }
            } else if n < old {
                self.hexEditor.edit { b in b.replace(n..<old, with: Data()); return nil }
            }
            self.log("Buffer resized from \(old) to \(n) bytes.")
        }
    }

    /// Edit ▸ Undo/Redo when neither the hex grid nor the text view has the keyboard focus.
    @objc func undo(_ sender: Any?) { undoBufferEdit(sender) }
    @objc func redo(_ sender: Any?) { redoBufferEdit(sender) }

    @objc func undoBufferEdit(_ sender: Any?) {
        if bufferIsText { textEditor.undoManager?.undo(); return }
        guard hexEditor.buffer.canUndo else { NSSound.beep(); return }
        hexEditor.undo(sender)
    }

    @objc func redoBufferEdit(_ sender: Any?) {
        if bufferIsText { textEditor.undoManager?.redo(); return }
        guard hexEditor.buffer.canRedo else { NSSound.beep(); return }
        hexEditor.redo(sender)
    }

    // MARK: Window

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isBusy { NSSound.beep(); log("Wait for the current job to finish, or press Stop."); return false }
        return true
    }
}
