import Cocoa

/// Shows a decoded GAL fuse map as galasm-style equations and as an AND-OR gate diagram.
final class GalDecoderWindowController: NSWindowController {
    private let design: GalDesign
    private let names: [Int: String]
    private let sourceName: String
    private var retainSelf: GalDecoderWindowController?

    static func show(jedText: String, sourceName: String, chipHint: String?, on parent: NSWindow?) {
        do {
            let jed = try JEDECFile.parse(jedText)
            let design = try GalDecoder.decode(jed, hint: chipHint)
            let c = GalDecoderWindowController(design: design, sourceName: sourceName)
            c.retainSelf = c
            c.showWindow(nil)
            c.window?.makeKeyAndOrderFront(nil)
        } catch {
            let a = NSAlert()
            a.messageText = "Can't decode \(sourceName)"
            a.informativeText = "\(error)\n\nThe decoder reads JEDEC fuse maps for GAL16V8, GAL20V8 and GAL22V10 (and the ATF versions of them)."
            if let p = parent { a.beginSheetModal(for: p) } else { a.runModal() }
        }
    }

    private init(design: GalDesign, sourceName: String) {
        self.design = design
        self.sourceName = sourceName
        var n: [Int: String] = [:]
        for pin in 1...design.chip.pins { n[pin] = "P\(pin)" }
        self.names = n
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "\(sourceName) – \(design.chip.rawValue) equations"
        w.minSize = NSSize(width: 480, height: 320)
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.center()
        buildUI()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            self?.retainSelf = nil
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var equationsText: String { design.equations(names: names) }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let summary = NSTextField(wrappingLabelWithString:
            "\(design.chip.rawValue), \(design.modeDescription()). \(design.outputs.count) output(s). " +
            "Pins are named P1, P2 … because a .jed file doesn't store signal names.")
        summary.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summary.textColor = .secondaryLabelColor

        let tabs = NSTabView()
        let eqItem = NSTabViewItem(identifier: "eq")
        eqItem.label = "Equations"
        let tv = NSTextView()
        tv.isEditable = false
        tv.isRichText = false
        tv.font = NSFont.userFixedPitchFont(ofSize: 12) ?? .systemFont(ofSize: 12)
        tv.string = equationsText
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let eqScroll = NSScrollView()
        eqScroll.hasVerticalScroller = true
        eqScroll.documentView = tv
        eqItem.view = eqScroll
        tabs.addTabViewItem(eqItem)

        let dItem = NSTabViewItem(identifier: "diagram")
        dItem.label = "Diagram"
        let diagram = GalDiagramView(design: design, names: names)
        let dScroll = NSScrollView()
        dScroll.hasVerticalScroller = true
        dScroll.hasHorizontalScroller = true
        dScroll.documentView = diagram
        dScroll.backgroundColor = .textBackgroundColor
        dScroll.drawsBackground = true
        dItem.view = dScroll
        tabs.addTabViewItem(dItem)

        let save = NSButton(title: "Save Equations…", target: self, action: #selector(saveEquations(_:)))
        save.bezelStyle = .rounded
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyEquations(_:)))
        copy.bezelStyle = .rounded
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .horizontal)
        let buttons = NSStackView(views: [spacer, copy, save])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [summary, tabs, buttons])
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
        for v in [summary, tabs, buttons] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        tabs.setContentHuggingPriority(.defaultLow, for: .vertical)
        tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
    }

    @objc private func copyEquations(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(equationsText, forType: .string)
    }

    @objc private func saveEquations(_ sender: Any?) {
        guard let w = window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (sourceName as NSString).deletingPathExtension + "_equations.txt"
        panel.allowedFileTypes = ["txt"]
        panel.beginSheetModal(for: w) { [weak self] resp in
            guard let self = self, resp == .OK, let url = panel.url else { return }
            do { try self.equationsText.write(to: url, atomically: true, encoding: .utf8) } catch {
                NSAlert(error: error).beginSheetModal(for: w)
            }
        }
    }
}

/// Draws each output as AND gates (one per product term) feeding an OR gate, then the
/// polarity inverter, the register and the output-enable buffer.
final class GalDiagramView: NSView {
    private let design: GalDesign
    private let names: [Int: String]
    private let font = NSFont.userFixedPitchFont(ofSize: 11) ?? .systemFont(ofSize: 11)
    private let titleFont = NSFont.boldSystemFont(ofSize: 12)
    private let rowH: CGFloat = 26, gateH: CGFloat = 20
    private var labelWidth: CGFloat = 120
    private var blocks: [(y: CGFloat, height: CGFloat, output: GalOutput)] = []

    override var isFlipped: Bool { true }

    init(design: GalDesign, names: [Int: String]) {
        self.design = design
        self.names = names
        super.init(frame: .zero)
        layoutBlocks()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func text(_ s: String, _ f: NSFont? = nil, _ c: NSColor = .textColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: f ?? font, .foregroundColor: c])
    }

    private func rowLabel(_ row: [GalLiteral]) -> String {
        row.map { design.literal($0, names) }.joined(separator: " · ")
    }

    private func layoutBlocks() {
        var widest: CGFloat = 60
        for o in design.outputs {
            for r in o.term.rows { widest = max(widest, text(rowLabel(r)).size().width) }
        }
        labelWidth = min(widest, 700) + 16
        var y: CGFloat = 16
        blocks = []
        for o in design.outputs {
            let n = max(1, o.term.isTrue ? 1 : o.term.rows.count)
            let h = 28 + CGFloat(n) * rowH + (o.enable != nil || o.kind == .registered ? 34 : 8)
            blocks.append((y, h, o))
            y += h + 14
        }
        var extra: [String] = []
        if let ar = design.asyncReset { extra.append("AR (asynchronous reset of all registers) = " + design.expression(ar, names, indent: 0).replacingOccurrences(of: "\n", with: " ")) }
        if let sp = design.syncPreset { extra.append("SP (synchronous preset of all registers) = " + design.expression(sp, names, indent: 0).replacingOccurrences(of: "\n", with: " ")) }
        y += CGFloat(extra.count) * 20 + (design.outputs.isEmpty ? 30 : 0)
        let width = labelWidth + 470
        setFrameSize(NSSize(width: width, height: y + 16))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        let ink = NSColor.textColor
        ink.setStroke()
        if design.outputs.isEmpty {
            text("No outputs are programmed in this fuse map.", titleFont).draw(at: NSPoint(x: 16, y: 16))
        }
        for b in blocks where NSRect(x: 0, y: b.y, width: bounds.width, height: b.height).intersects(dirtyRect) {
            drawBlock(b.output, top: b.y)
        }
        var y = (blocks.last.map { $0.y + $0.height + 14 }) ?? 46
        for (label, s) in [("AR", design.asyncReset), ("SP", design.syncPreset)] {
            guard let s = s else { continue }
            let what = label == "AR" ? "asynchronous reset" : "synchronous preset"
            text("\(label) (\(what) of all registers) = " + design.expression(s, names, indent: 0).replacingOccurrences(of: "\n", with: " "))
                .draw(at: NSPoint(x: 16, y: y))
            y += 20
        }
    }

    private func line(_ a: NSPoint, _ b: NSPoint) {
        let p = NSBezierPath()
        p.move(to: a); p.line(to: b)
        p.lineWidth = 1.2
        p.stroke()
    }

    private func drawBlock(_ o: GalOutput, top: CGFloat) {
        let ink = NSColor.textColor
        let dim = NSColor.secondaryLabelColor
        let kind = o.kind == .registered ? "registered" : (o.enable != nil ? "tristate" : "combinatorial")
        let title = "Pin \(o.pin) (\(names[o.pin] ?? "P\(o.pin)")) – \(kind), active \(o.activeHigh ? "high" : "low")"
        text(title, titleFont).draw(at: NSPoint(x: 16, y: top))

        let gateX = 16 + labelWidth
        let orX = gateX + 70
        let firstY = top + 28
        let n = max(1, o.term.isTrue ? 1 : o.term.rows.count)
        let midY = firstY + CGFloat(n) * rowH / 2 - (rowH - gateH) / 2

        // Product terms
        var orInput: NSPoint
        if o.term.isTrue || o.term.isFalse {
            let label = o.term.isTrue ? "VCC (always 1)" : "GND (always 0)"
            let s = text(label, nil, dim)
            s.draw(at: NSPoint(x: gateX + 40 - s.size().width, y: midY - 7))
            orInput = NSPoint(x: gateX + 44, y: midY)
            line(orInput, NSPoint(x: orX + 50, y: midY))
        } else {
            for (i, r) in o.term.rows.enumerated() {
                let y = firstY + CGFloat(i) * rowH
                let gate = NSRect(x: gateX, y: y, width: 36, height: gateH)
                let label = text(rowLabel(r))
                label.draw(at: NSPoint(x: gateX - 8 - label.size().width, y: y + (gateH - label.size().height) / 2))
                andGate(gate)
                let out = NSPoint(x: gate.maxX, y: gate.midY)
                if n == 1 {
                    line(out, NSPoint(x: orX + 50, y: out.y))
                } else {
                    line(out, NSPoint(x: orX + 6, y: out.y))
                }
            }
            if n > 1 {
                // Gather the AND outputs into the OR gate.
                let h = max(gateH + 6, CGFloat(n) * rowH - (rowH - gateH))
                let orRect = NSRect(x: orX, y: midY - h / 2, width: 44, height: h)
                orGate(orRect)
                line(NSPoint(x: orRect.maxX, y: midY), NSPoint(x: orX + 50, y: midY))
            }
            orInput = NSPoint(x: orX + 50, y: midY)
        }

        // Polarity
        var x = orX + 50
        if !o.activeHigh {
            let tri = NSBezierPath()
            tri.move(to: NSPoint(x: x, y: midY - 8)); tri.line(to: NSPoint(x: x, y: midY + 8))
            tri.line(to: NSPoint(x: x + 16, y: midY)); tri.close()
            tri.lineWidth = 1.2; tri.stroke()
            NSBezierPath(ovalIn: NSRect(x: x + 16, y: midY - 3, width: 6, height: 6)).stroke()
            x += 22
            line(NSPoint(x: x, y: midY), NSPoint(x: x + 14, y: midY))
            x += 14
        } else {
            line(NSPoint(x: x, y: midY), NSPoint(x: x + 36, y: midY))
            x += 36
        }

        // Register
        if o.kind == .registered {
            let box = NSRect(x: x, y: midY - 18, width: 46, height: 36)
            let p = NSBezierPath(rect: box); p.lineWidth = 1.2; p.stroke()
            text("D", nil).draw(at: NSPoint(x: box.minX + 4, y: midY - 14))
            text("Q", nil).draw(at: NSPoint(x: box.maxX - 13, y: midY - 14))
            let clk = NSBezierPath()
            clk.move(to: NSPoint(x: box.minX, y: box.maxY - 12)); clk.line(to: NSPoint(x: box.minX + 7, y: box.maxY - 7))
            clk.line(to: NSPoint(x: box.minX, y: box.maxY - 2)); clk.stroke()
            line(NSPoint(x: box.minX - 10, y: box.maxY - 7), NSPoint(x: box.minX, y: box.maxY - 7))
            text("CLK pin \(design.clockPin ?? 1)", nil, dim).draw(at: NSPoint(x: box.minX - 10, y: box.maxY + 2))
            x = box.maxX
            line(NSPoint(x: x, y: midY), NSPoint(x: x + 18, y: midY))
            x += 18
        }

        // Output buffer with enable
        let buf = NSBezierPath()
        buf.move(to: NSPoint(x: x, y: midY - 10)); buf.line(to: NSPoint(x: x, y: midY + 10))
        buf.line(to: NSPoint(x: x + 20, y: midY)); buf.close()
        buf.lineWidth = 1.2; buf.stroke()
        var enableText: String?
        if let e = o.enable {
            enableText = "OE = " + design.expression(e, names, indent: 0).replacingOccurrences(of: "\n", with: " ")
        } else if o.kind == .registered, let oe = design.oePin {
            enableText = "OE = /P\(oe) (pin \(oe) low)"
        }
        if let et = enableText {
            line(NSPoint(x: x + 10, y: midY + 5), NSPoint(x: x + 10, y: midY + 18))
            text(et, nil, dim).draw(at: NSPoint(x: x + 14, y: midY + 12))
        }
        x += 20
        line(NSPoint(x: x, y: midY), NSPoint(x: x + 24, y: midY))
        let pinLabel = text("\(names[o.pin] ?? "P\(o.pin)")  (pin \(o.pin))", titleFont, ink)
        pinLabel.draw(at: NSPoint(x: x + 30, y: midY - pinLabel.size().height / 2))
        _ = orInput
    }

    private func andGate(_ r: NSRect) {
        let p = NSBezierPath()
        let rad = r.height / 2
        p.move(to: NSPoint(x: r.minX, y: r.minY))
        p.line(to: NSPoint(x: r.maxX - rad, y: r.minY))
        p.appendArc(withCenter: NSPoint(x: r.maxX - rad, y: r.midY), radius: rad, startAngle: 270, endAngle: 90, clockwise: false)
        p.line(to: NSPoint(x: r.minX, y: r.maxY))
        p.close()
        p.lineWidth = 1.2
        p.stroke()
    }

    private func orGate(_ r: NSRect) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: r.minX, y: r.minY))
        p.curve(to: NSPoint(x: r.maxX, y: r.midY),
                controlPoint1: NSPoint(x: r.minX + r.width * 0.6, y: r.minY),
                controlPoint2: NSPoint(x: r.maxX - 4, y: r.midY - r.height * 0.25))
        p.curve(to: NSPoint(x: r.minX, y: r.maxY),
                controlPoint1: NSPoint(x: r.maxX - 4, y: r.midY + r.height * 0.25),
                controlPoint2: NSPoint(x: r.minX + r.width * 0.6, y: r.maxY))
        p.curve(to: NSPoint(x: r.minX, y: r.minY),
                controlPoint1: NSPoint(x: r.minX + 10, y: r.maxY - r.height * 0.3),
                controlPoint2: NSPoint(x: r.minX + 10, y: r.minY + r.height * 0.3))
        p.lineWidth = 1.2
        p.stroke()
    }
}
