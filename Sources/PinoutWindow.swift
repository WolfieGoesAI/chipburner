import Cocoa

/// Draws a DIP chip seen from above (notch at the top), pin 1 top left, with the signal names.
final class PinoutView: NSView {
    var pinout: ChipPinout? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    private let font = NSFont.userFixedPitchFont(ofSize: 12) ?? .systemFont(ofSize: 12)
    private let pitch: CGFloat = 22
    private let bodyWidth: CGFloat = 120
    private let labelWidth: CGFloat = 130

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
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
        var noteLines = ["Top view, notch up. In the programmer's ZIF socket: lever down, pin 1 at the lever end, chip bottom-aligned."]
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
