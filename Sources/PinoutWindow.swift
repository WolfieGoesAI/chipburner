import Cocoa

/// Draws a DIP chip seen from above (notch at the top), pin 1 top left, with the signal names.
final class PinoutView: NSView {
    var pinout: ChipPinout? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    private let font = NSFont.userFixedPitchFont(ofSize: 12) ?? .systemFont(ofSize: 12)
    private let pitch: CGFloat = 22
    private let bodyWidth: CGFloat = 120
    private let labelWidth: CGFloat = 130

    override var isFlipped: Bool { true }

    // PLCC32 geometry
    private let plccW: CGFloat = 210, plccH: CGFloat = 250, plccLabel: CGFloat = 96

    override var intrinsicContentSize: NSSize {
        if pinout?.package == .plcc32 {
            return NSSize(width: plccW + 2 * (labelWidth + 20), height: plccH + 2 * (plccLabel + 14))
        }
        let half = (pinout?.pins.count ?? 0) / 2
        return NSSize(width: bodyWidth + 2 * (labelWidth + 24), height: CGFloat(half) * pitch + 40)
    }

    private func color(for label: String, pin: Int) -> NSColor {
        if let r = pinout?.roles, pin - 1 < r.count {
            switch r[pin - 1] {
            case "g": return .systemBlue
            case "v": return .systemRed
            case "o": return .systemGreen
            case "c": return .systemOrange
            case "b": return .systemPurple
            case "n": return .tertiaryLabelColor
            default: return .labelColor
            }
        }
        let l = label.uppercased()
        if l == "VCC" || l == "VDD" || l == "AVCC" { return .systemRed }
        if l == "GND" || l == "VSS" { return .systemBlue }
        if l.contains("VPP") { return .systemOrange }
        if l == "NC" { return .tertiaryLabelColor }
        return .labelColor
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        guard let p = pinout, p.pins.count >= 2 else { return }
        if p.package == .plcc32 && p.pins.count == 32 { drawPLCC(p); return }
        let half = p.pins.count / 2
        let bodyX = labelWidth + 24
        let top: CGFloat = 16
        let height = CGFloat(half) * pitch + 8
        let body = NSRect(x: bodyX, y: top, width: bodyWidth, height: height)

        // Body with the notch at the top.
        let path = NSBezierPath(roundedRect: body, xRadius: 4, yRadius: 4)
        NSColor.controlBackgroundColor.blended(withFraction: 0.15, of: .black)?.setFill()
        path.fill()
        NSColor.secondaryLabelColor.setStroke()
        path.lineWidth = 1.5
        path.stroke()
        let notch = NSBezierPath()
        notch.appendArc(withCenter: NSPoint(x: body.midX, y: body.minY), radius: 10, startAngle: 0, endAngle: 180, clockwise: false)
        NSColor.textBackgroundColor.setFill()
        notch.fill()
        notch.stroke()
        // Pin-1 dot
        NSColor.secondaryLabelColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: body.minX + 22, y: body.minY + 9, width: 7, height: 7)).fill()

        let numAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        for i in 0..<half {
            let y = top + 4 + CGFloat(i) * pitch + pitch / 2
            // left side: pins 1…half, top to bottom
            let leftPin = i + 1
            // right side: pins n…half+1, top to bottom
            let rightPin = p.pins.count - i
            for (pin, isLeft) in [(leftPin, true), (rightPin, false)] {
                let label = p.pins[pin - 1]
                let leg = NSRect(x: isLeft ? body.minX - 14 : body.maxX, y: y - 4, width: 14, height: 8)
                NSColor.tertiaryLabelColor.setFill()
                leg.fill()
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color(for: label, pin: pin)]
                let s = label as NSString
                let w = s.size(withAttributes: attrs).width
                let x = isLeft ? leg.minX - 6 - w : leg.maxX + 6
                s.draw(at: NSPoint(x: x, y: y - 8), withAttributes: attrs)
                let n = "\(pin)" as NSString
                let nw = n.size(withAttributes: numAttrs).width
                n.draw(at: NSPoint(x: isLeft ? body.minX + 6 : body.maxX - 6 - nw, y: y - 6), withAttributes: numAttrs)
            }
        }
    }
}

extension PinoutView {
    /// PLCC32 from above: pin 1 in the middle of the top edge, numbers running anticlockwise.
    fileprivate func drawPLCC(_ p: ChipPinout) {
        let font = NSFont.userFixedPitchFont(ofSize: 12) ?? .systemFont(ofSize: 12)
        let numAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        let W: CGFloat = 210, H: CGFloat = 250, label: CGFloat = 96
        let body = NSRect(x: bounds.midX - W / 2, y: label + 14, width: W, height: H)
        // Body with the bevelled index corner (top left).
        let path = NSBezierPath()
        path.move(to: NSPoint(x: body.minX + 18, y: body.minY))
        path.line(to: NSPoint(x: body.maxX, y: body.minY))
        path.line(to: NSPoint(x: body.maxX, y: body.maxY))
        path.line(to: NSPoint(x: body.minX, y: body.maxY))
        path.line(to: NSPoint(x: body.minX, y: body.minY + 18))
        path.close()
        NSColor.controlBackgroundColor.blended(withFraction: 0.15, of: .black)?.setFill()
        path.fill()
        NSColor.secondaryLabelColor.setStroke()
        path.lineWidth = 1.5
        path.stroke()

        let top = [4, 3, 2, 1, 32, 31, 30], bottom = [14, 15, 16, 17, 18, 19, 20]
        let left = Array(5...13), right = Array((21...29).reversed())
        let hStep = (W - 24) / 7, vStep = (H - 24) / 9

        func colorFor(_ pin: Int) -> NSColor {
            let l = p.pins[pin - 1].uppercased()
            if l == "VCC" || l == "VDD" { return .systemRed }
            if l == "GND" || l == "VSS" { return .systemBlue }
            if l.contains("VPP") { return .systemOrange }
            if l == "NC" { return .tertiaryLabelColor }
            return .labelColor
        }
        func text(_ pin: Int) -> (NSString, [NSAttributedString.Key: Any]) {
            (p.pins[pin - 1] as NSString, [.font: font, .foregroundColor: colorFor(pin)])
        }
        func vertical(_ s: NSString, _ attrs: [NSAttributedString.Key: Any], at pt: NSPoint, up: Bool) {
            guard let ctx = NSGraphicsContext.current else { return }
            ctx.saveGraphicsState()
            let t = NSAffineTransform()
            t.translateX(by: pt.x, yBy: pt.y)
            t.rotate(byDegrees: up ? -90 : 90)
            t.concat()
            let h = s.size(withAttributes: attrs).height
            s.draw(at: NSPoint(x: 0, y: -h / 2), withAttributes: attrs)
            ctx.restoreGraphicsState()
        }

        NSColor.tertiaryLabelColor.setFill()
        for (i, pin) in top.enumerated() {
            let x = body.minX + 12 + (CGFloat(i) + 0.5) * hStep
            NSRect(x: x - 4, y: body.minY - 10, width: 8, height: 10).fill()
            let (s, a) = text(pin); vertical(s, a, at: NSPoint(x: x, y: body.minY - 14), up: true)
            let n = "\(pin)" as NSString
            n.draw(at: NSPoint(x: x - n.size(withAttributes: numAttrs).width / 2, y: body.minY + 3), withAttributes: numAttrs)
            NSColor.tertiaryLabelColor.setFill()
        }
        for (i, pin) in bottom.enumerated() {
            let x = body.minX + 12 + (CGFloat(i) + 0.5) * hStep
            NSRect(x: x - 4, y: body.maxY, width: 8, height: 10).fill()
            let (s, a) = text(pin); vertical(s, a, at: NSPoint(x: x, y: body.maxY + 14), up: false)
            let n = "\(pin)" as NSString
            n.draw(at: NSPoint(x: x - n.size(withAttributes: numAttrs).width / 2, y: body.maxY - 14), withAttributes: numAttrs)
            NSColor.tertiaryLabelColor.setFill()
        }
        for (i, pin) in left.enumerated() {
            let y = body.minY + 12 + (CGFloat(i) + 0.5) * vStep
            NSRect(x: body.minX - 10, y: y - 4, width: 10, height: 8).fill()
            let (s, a) = text(pin)
            s.draw(at: NSPoint(x: body.minX - 16 - s.size(withAttributes: a).width, y: y - 8), withAttributes: a)
            ("\(pin)" as NSString).draw(at: NSPoint(x: body.minX + 4, y: y - 6), withAttributes: numAttrs)
            NSColor.tertiaryLabelColor.setFill()
        }
        for (i, pin) in right.enumerated() {
            let y = body.minY + 12 + (CGFloat(i) + 0.5) * vStep
            NSRect(x: body.maxX, y: y - 4, width: 10, height: 8).fill()
            let (s, a) = text(pin)
            s.draw(at: NSPoint(x: body.maxX + 16, y: y - 8), withAttributes: a)
            let n = "\(pin)" as NSString
            n.draw(at: NSPoint(x: body.maxX - 4 - n.size(withAttributes: numAttrs).width, y: y - 6), withAttributes: numAttrs)
            NSColor.tertiaryLabelColor.setFill()
        }
        // Pin-1 marker under pin 1.
        NSColor.secondaryLabelColor.setFill()
        let x1 = body.minX + 12 + 3.5 * hStep
        NSBezierPath(ovalIn: NSRect(x: x1 - 3.5, y: body.minY + 16, width: 7, height: 7)).fill()
        _ = label
    }
}

final class PinoutWindowController: NSWindowController {
    private var retainSelf: PinoutWindowController?

    init(chip: String, pinout: ChipPinout) {
        let view = PinoutView()
        view.pinout = pinout
        let size = view.intrinsicContentSize
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size.width + 24, height: size.height + 110),
                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Pinout – \(chip)"
        w.isReleasedWhenClosed = false
        super.init(window: w)

        let title = NSTextField(labelWithString: pinout.title)
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        var noteLines = pinout.package == .plcc32 ? [] : ["Top view, notch up. In the programmer's ZIF socket: lever down, pin 1 at the lever end, chip bottom-aligned."]
        noteLines += pinout.notes
        let notes = NSTextField(wrappingLabelWithString: noteLines.joined(separator: "\n"))
        notes.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        notes.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, view, notes])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        w.contentView?.addSubview(stack)
        if let c = w.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: c.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: c.trailingAnchor),
                stack.topAnchor.constraint(equalTo: c.topAnchor),
                stack.bottomAnchor.constraint(equalTo: c.bottomAnchor),
            ])
        }
        notes.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        view.widthAnchor.constraint(equalToConstant: size.width).isActive = true
        view.heightAnchor.constraint(equalToConstant: size.height).isActive = true
        w.center()
        retainSelf = self
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            self?.retainSelf = nil
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
