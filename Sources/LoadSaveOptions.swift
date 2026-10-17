import Cocoa

/// File formats ChipBurner reads and writes for binary buffers.
enum FileFormat: Int, CaseIterable {
    case binary, intelHex, sRecord

    var title: String {
        switch self {
        case .binary: return "Binary (.bin)"
        case .intelHex: return "Intel HEX (.hex)"
        case .sRecord: return "Motorola S-record (.s19 / .srec)"
        }
    }
    var ext: String { [.binary: "bin", .intelHex: "hex", .sRecord: "s19"][self]! }
    var allExtensions: [String] {
        switch self {
        case .binary: return ["bin", "rom", "img"]
        case .intelHex: return ["hex", "ihx", "ihex"]
        case .sRecord: return ["s19", "srec", "s28", "s37", "mot", "s"]
        }
    }

    static func detect(_ url: URL, _ data: Data) -> FileFormat {
        let e = url.pathExtension.lowercased()
        if FileFormat.intelHex.allExtensions.contains(e) { return .intelHex }
        if FileFormat.sRecord.allExtensions.contains(e) { return .sRecord }
        // Unknown extension: look at the content.
        let head = String(decoding: data.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix(":") && head.dropFirst().prefix(8).allSatisfy({ $0.isHexDigit }) { return .intelHex }
        if head.count > 3, head.first == "S", "0123456789".contains(head[head.index(after: head.startIndex)]),
           head.dropFirst(2).prefix(8).allSatisfy({ $0.isHexDigit }) { return .sRecord }
        return .binary
    }

    func decode(_ data: Data) throws -> Data {
        switch self {
        case .binary: return data
        case .intelHex: return try IntelHex.parse(String(decoding: data, as: UTF8.self))
        case .sRecord: return try SRecord.parse(String(decoding: data, as: UTF8.self))
        }
    }

    func encode(_ data: Data, startAddress: Int) -> Data {
        switch self {
        case .binary: return data
        case .intelHex: return Data(IntelHex.write(data, startAddress: startAddress).utf8)
        case .sRecord: return Data(SRecord.write(data, startAddress: startAddress).utf8)
        }
    }
}

/// Accessory view of the Load panel: which part of the file to use and the EPROM pair tools.
final class LoadOptions: NSObject {
    enum Part: Int { case whole, even, odd, lower, upper }
    enum Combine: Int { case none, thisIsEven, thisIsOdd, append, placeAt }

    let view: NSView
    private let partPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let combinePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let addressField = NSTextField(string: "0")
    private let swapBox = NSButton(checkboxWithTitle: "Swap byte order of 16-bit words", target: nil, action: nil)

    var part: Part { Part(rawValue: partPopup.indexOfSelectedItem) ?? .whole }
    var combine: Combine { Combine(rawValue: combinePopup.indexOfSelectedItem) ?? .none }
    var swap: Bool { swapBox.state == .on }
    var address: String { addressField.stringValue }

    init(canPlace: Bool) {
        ["Whole file", "Even bytes only (0, 2, 4 … – low byte of each word)", "Odd bytes only (1, 3, 5 … – high byte of each word)",
         "Lower half of the file", "Upper half of the file"].forEach { partPopup.addItem(withTitle: $0) }
        ["Nothing – load just this file",
         "This is the EVEN (low) EPROM – choose the ODD one next and interleave",
         "This is the ODD (high) EPROM – choose the EVEN one next and interleave",
         "Choose a second file to append after this one",
         "Place into the current buffer at address:"].forEach { combinePopup.addItem(withTitle: $0) }
        if !canPlace { combinePopup.item(at: 4)?.isEnabled = false; combinePopup.autoenablesItems = false }
        addressField.placeholderString = "hex address"
        addressField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        func label(_ s: String) -> NSTextField { let l = NSTextField(labelWithString: s); l.alignment = .right; return l }
        let grid = NSGridView(views: [
            [label("Use:"), partPopup],
            [label("Combine:"), NSStackView(views: [combinePopup, addressField])],
            [NSView(), swapBox],
        ])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        let note = NSTextField(labelWithString: "EPROM pair tools: 16-bit systems keep even and odd bytes in two 8-bit EPROMs.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [grid, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        stack.frame.size = stack.fittingSize
        view = stack
        super.init()
        combinePopup.target = self
        combinePopup.action = #selector(changed(_:))
        changed(nil)
    }

    @objc private func changed(_ sender: Any?) { addressField.isEnabled = combine == .placeAt }

    func apply(_ d: Data) -> Data {
        switch part {
        case .whole: return d
        case .even: return PairTools.even(d)
        case .odd: return PairTools.odd(d)
        case .lower: return PairTools.lowerHalf(d)
        case .upper: return PairTools.upperHalf(d)
        }
    }
}

/// Accessory view of the Save panel: format, which part to save and the EPROM pair tools.
final class SaveOptions: NSObject {
    enum Part: Int { case whole, selection, even, odd, bothHalves, lower, upper }

    let view: NSView
    private weak var panel: NSSavePanel?
    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let partPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let startField = NSTextField(string: "0")
    private let swapBox = NSButton(checkboxWithTitle: "Swap byte order of 16-bit words", target: nil, action: nil)

    var format: FileFormat { FileFormat(rawValue: formatPopup.indexOfSelectedItem) ?? .binary }
    var part: Part { Part(rawValue: partPopup.indexOfSelectedItem) ?? .whole }
    var swap: Bool { swapBox.state == .on }
    var startAddress: String { startField.stringValue }

    init(panel: NSSavePanel, hasSelection: Bool, initial: FileFormat) {
        self.panel = panel
        FileFormat.allCases.forEach { formatPopup.addItem(withTitle: $0.title) }
        formatPopup.selectItem(at: initial.rawValue)
        ["Whole buffer", "Selection only", "Even bytes only (low EPROM of a pair)", "Odd bytes only (high EPROM of a pair)",
         "Both EPROMs of a pair – two files, _even and _odd", "Lower half", "Upper half"].forEach { partPopup.addItem(withTitle: $0) }
        partPopup.autoenablesItems = false
        partPopup.item(at: 1)?.isEnabled = hasSelection
        startField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        startField.placeholderString = "hex"
        func label(_ s: String) -> NSTextField { let l = NSTextField(labelWithString: s); l.alignment = .right; return l }
        let grid = NSGridView(views: [
            [label("Format:"), formatPopup],
            [label("Save:"), partPopup],
            [label("Start address:"), NSStackView(views: [startField, NSTextField(labelWithString: "(Intel HEX and S-record only)")])],
            [NSView(), swapBox],
        ])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        let stack = NSStackView(views: [grid])
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        stack.frame.size = stack.fittingSize
        view = stack
        super.init()
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged(_:))
        formatChanged(nil)
    }

    @objc private func formatChanged(_ sender: Any?) {
        startField.isEnabled = format != .binary
        guard let p = panel else { return }
        p.allowedFileTypes = format.allExtensions
        let base = (p.nameFieldStringValue as NSString).deletingPathExtension
        p.nameFieldStringValue = base + "." + format.ext
    }

    /// The data to write: [(file suffix, bytes)] – two entries for a pair.
    func output(buffer: Data, selection: Range<Int>?) -> [(suffix: String, data: Data)] {
        var d: Data
        switch part {
        case .selection: d = selection.map { Data(buffer.subdata(in: $0)) } ?? buffer
        case .lower: d = PairTools.lowerHalf(buffer)
        case .upper: d = PairTools.upperHalf(buffer)
        default: d = buffer
        }
        if swap { d = PairTools.swap16(d) }
        switch part {
        case .even: return [("", PairTools.even(d))]
        case .odd: return [("", PairTools.odd(d))]
        case .bothHalves: return [("_even", PairTools.even(d)), ("_odd", PairTools.odd(d))]
        default: return [("", d)]
        }
    }
}
