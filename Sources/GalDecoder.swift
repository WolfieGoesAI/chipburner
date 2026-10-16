import Foundation

// Decodes a JEDEC fuse map for GAL16V8, GAL20V8 and GAL22V10 (and the pin-compatible
// ATF16V8/ATF20V8/ATF22V10) back into sum-of-products equations.
//
// Fuse layouts, input column tables and OLMC row ranges follow Galette
// (https://github.com/simon-frankau/galette, MIT licence, © 2019 Simon Frankau),
// which writes galasm-compatible JEDEC files. The build checks this decoder against
// Galette's own test cases (tests/gal).

// MARK: JEDEC file

struct JEDECFile {
    var fuses: [Bool]            // true = "1" in the file (fuse intact = input not connected)
    var declaredCount: Int?      // *QF
    var securityBit: Bool        // *G1
    var checksum: UInt16?        // *C
    var device: String?          // "Device: GAL16V8" header line, if present
    var computedChecksum: UInt16 {
        var sum: UInt16 = 0, byte: UInt8 = 0, bit = 0
        for f in fuses {
            if f { byte |= UInt8(1 << bit) }
            bit += 1
            if bit == 8 { sum = sum &+ UInt16(byte); byte = 0; bit = 0 }
        }
        return sum &+ UInt16(byte)
    }

    enum ParseError: Error, CustomStringConvertible {
        case noFuses, badField(String)
        var description: String {
            switch self {
            case .noFuses: return "The file has no fuse data (*L fields)."
            case .badField(let f): return "Unreadable JEDEC field “\(f.prefix(40))”."
            }
        }
    }

    static func parse(_ text: String) throws -> JEDECFile {
        // Text between STX and ETX; fields are separated by '*'.
        var body = Substring(text)
        if let stx = body.firstIndex(of: "\u{02}") { body = body[body.index(after: stx)...] }
        if let etx = body.firstIndex(of: "\u{03}") { body = body[..<etx] }
        let parts = body.components(separatedBy: "*")
        var device: String?
        for line in (parts.first ?? "").components(separatedBy: .newlines) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.lowercased().hasPrefix("device") {
                device = l.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) }
            }
        }
        var count: Int?, defaultBit = false, security = false, checksum: UInt16?
        var spans: [(Int, [Bool])] = []
        for raw in parts.dropFirst() {
            let f = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let code = f.first else { continue }
            let rest = f.dropFirst()
            switch code {
            case "Q":
                if rest.hasPrefix("F") { count = Int(rest.dropFirst().trimmingCharacters(in: .whitespaces)) }
            case "F":
                defaultBit = rest.trimmingCharacters(in: .whitespaces) == "1"
            case "G":
                security = rest.trimmingCharacters(in: .whitespaces) == "1"
            case "C":
                checksum = UInt16(rest.trimmingCharacters(in: .whitespaces), radix: 16)
            case "L":
                let digits = rest.prefix { $0.isNumber }
                guard let addr = Int(digits) else { throw ParseError.badField(f) }
                var bits: [Bool] = []
                for ch in rest.dropFirst(digits.count) {
                    if ch == "0" { bits.append(false) } else if ch == "1" { bits.append(true) }
                    else if !ch.isWhitespace { throw ParseError.badField(f) }
                }
                spans.append((addr, bits))
            default:
                continue   // N (note), V (test vectors), P, D, X, J … are not needed here
            }
        }
        guard !spans.isEmpty else { throw ParseError.noFuses }
        let end = spans.map { $0.0 + $0.1.count }.max() ?? 0
        var fuses = [Bool](repeating: defaultBit, count: max(count ?? 0, end))
        for (addr, bits) in spans { for (i, b) in bits.enumerated() { fuses[addr + i] = b } }
        return JEDECFile(fuses: fuses, declaredCount: count, securityBit: security, checksum: checksum, device: device)
    }
}

// MARK: Decoded design

struct GalLiteral: Hashable {
    var pin: Int        // > 0: package pin; < 0: unmapped fuse column (-column - 1)
    var negated: Bool
}

/// OR of AND rows. No rows = always false (GND); an empty row = always true (VCC).
struct GalSum: Equatable {
    var rows: [[GalLiteral]]
    var isTrue: Bool { rows.contains { $0.isEmpty } }
    var isFalse: Bool { rows.isEmpty }
    /// Order-free form for comparisons.
    var normalized: Set<Set<GalLiteral>> { isTrue ? [[]] : Set(rows.map { Set($0) }) }
}

struct GalOutput {
    enum Kind { case combinatorial, registered }
    var pin: Int
    var kind: Kind
    var activeHigh: Bool
    var term: GalSum
    /// Product-term output enable; nil = always enabled (or pin-controlled, see GalDesign.oePin).
    var enable: GalSum?
    var productTermsUsed: Int { term.isTrue ? 1 : term.rows.count }
    var productTermsAvailable: Int
}

enum GalChipType: String {
    case gal16v8 = "GAL16V8", gal20v8 = "GAL20V8", gal22v10 = "GAL22V10"
    var pins: Int { self == .gal16v8 ? 20 : 24 }
    var fuseCount: Int { [.gal16v8: 2194, .gal20v8: 2706, .gal22v10: 5892][self]! }
}

struct GalDesign {
    var chip: GalChipType
    var mode: String                 // "simple", "complex", "registered" (V8) or "" (22V10)
    var outputs: [GalOutput]         // highest pin first, as in data sheets
    var inputPins: [Int]             // pins used as inputs (including OLMC pins used as inputs)
    var clockPin: Int?
    var oePin: Int?                  // pin-controlled output enable for registered outputs (active low)
    var asyncReset: GalSum?          // 22V10 AR
    var syncPreset: GalSum?          // 22V10 SP
    var signature: [UInt8]
    var securityBit: Bool
    var notes: [String]

    var signatureText: String {
        let printable = signature.allSatisfy { $0 == 0 || (0x20...0x7E).contains($0) }
        if printable, let s = String(bytes: signature.filter { $0 != 0 }, encoding: .ascii), !s.isEmpty { return s }
        return signature.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

// MARK: Decoder

enum GalDecoder {
    enum DecodeError: Error, CustomStringConvertible {
        case unknownSize(Int), invalidMode, unsupported(String)
        var description: String {
            switch self {
            case .unknownSize(let n):
                return "A fuse map with \(n) fuses isn't a GAL16V8 (2194), GAL20V8 (2706) or GAL22V10 (5892)."
            case .invalidMode:
                return "The mode fuses (SYN = 0, AC0 = 0) don't describe a valid GALxxV8 mode."
            case .unsupported(let s): return s
            }
        }
    }

    // Input pin -> first fuse column (the inverted input is the next column); nil = no column.
    private static let col16Simple: [Int?] = [2, 0, 4, 8, 12, 16, 20, 24, 28, nil, 30, 26, 22, 18, nil, nil, 14, 10, 6, nil]
    private static let col16Complex: [Int?] = [2, 0, 4, 8, 12, 16, 20, 24, 28, nil, 30, nil, 26, 22, 18, 14, 10, 6, nil, nil]
    private static let col16Registered: [Int?] = [nil, 0, 4, 8, 12, 16, 20, 24, 28, nil, nil, 30, 26, 22, 18, 14, 10, 6, 2, nil]
    private static let col20Simple: [Int?] = [2, 0, 4, 8, 12, 16, 20, 24, 28, 32, 36, nil, 38, 34, 30, 26, 22, nil, nil, 18, 14, 10, 6, nil]
    private static let col20Complex: [Int?] = [2, 0, 4, 8, 12, 16, 20, 24, 28, 32, 36, nil, 38, 34, nil, 30, 26, 22, 18, 14, 10, nil, 6, nil]
    private static let col20Registered: [Int?] = [nil, 0, 4, 8, 12, 16, 20, 24, 28, 32, 36, nil, nil, 38, 34, 30, 26, 22, 18, 14, 10, 6, 2, nil]
    private static let col22V10: [Int?] = [0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, nil, 42, 38, 34, 30, 26, 22, 18, 14, 10, 6, 2, nil]

    // OLMC n (n = 0 is the lowest output pin) -> first row, and rows per OLMC.
    private static let rowsV8 = [56, 48, 40, 32, 24, 16, 8, 0]
    private static let rows22V10 = [122, 111, 98, 83, 66, 49, 34, 21, 10, 1]
    private static let size22V10 = [9, 11, 13, 15, 17, 17, 15, 13, 11, 9]

    /// Picks the chip from the fuse count; `hint` (the selected chip name) settles ATF/GAL variants.
    static func chipType(fuseCount n: Int, hint: String? = nil) -> GalChipType? {
        switch n {
        case 2194: return .gal16v8
        case 2706: return .gal20v8
        case 5892, 5893: return .gal22v10   // some ATF22V10 files carry one extra power-down fuse
        default:
            guard let h = hint?.uppercased() else { return nil }
            if h.contains("16V8") { return .gal16v8 }
            if h.contains("20V8") { return .gal20v8 }
            if h.contains("22V10") { return .gal22v10 }
            return nil
        }
    }

    static func decode(_ jed: JEDECFile, hint: String? = nil) throws -> GalDesign {
        let n = jed.declaredCount ?? jed.fuses.count
        if n == 3274 { throw DecodeError.unsupported("This is a GAL20RA10 fuse map, which the decoder doesn't handle yet.") }
        guard let chip = chipType(fuseCount: n, hint: hint) else { throw DecodeError.unknownSize(n) }
        var f = jed.fuses
        if f.count < chip.fuseCount { f += [Bool](repeating: false, count: chip.fuseCount - f.count) }
        var notes: [String] = []
        if let c = jed.checksum, c != jed.computedChecksum {
            notes.append(String(format: "Fuse checksum in the file is %04X but the fuses add up to %04X – the file may be damaged.", c, jed.computedChecksum))
        }
        if n != chip.fuseCount && (chip != .gal22v10 || n != 5893) {
            notes.append("The file declares \(n) fuses; decoded as \(chip.rawValue) (\(chip.fuseCount)).")
        }
        var design = chip == .gal22v10 ? decode22V10(f, notes: &notes) : try decodeV8(f, chip: chip, notes: &notes)
        design.securityBit = jed.securityBit
        if jed.securityBit { design.notes.append("The security fuse is set: a chip programmed from this file can't be read back.") }
        return design
    }

    private static func bytes(_ bits: ArraySlice<Bool>) -> [UInt8] {
        var out: [UInt8] = []
        var i = bits.startIndex
        while i + 8 <= bits.endIndex {
            var b: UInt8 = 0
            for j in 0..<8 where bits[i + j] { b |= UInt8(0x80 >> j) }
            out.append(b); i += 8
        }
        return out
    }

    /// One row of the AND array, or nil if the row can never be true.
    private static func row(_ f: [Bool], _ r: Int, cols: Int, colToPin: [Int: Int], flip: Set<Int>) -> [GalLiteral]? {
        var lits: [GalLiteral] = []
        let base = r * cols
        for c in stride(from: 0, to: cols, by: 2) {
            let pos = !f[base + c], neg = !f[base + c + 1]   // "0" = connected
            if pos && neg { return nil }                     // x AND /x
            if !pos && !neg { continue }
            let pin = colToPin[c] ?? -(c + 1)
            lits.append(GalLiteral(pin: pin, negated: neg != flip.contains(pin)))
        }
        return lits
    }

    private static func sum(_ f: [Bool], rows: Range<Int>, cols: Int, colToPin: [Int: Int], flip: Set<Int> = [], enabled: (Int) -> Bool = { _ in true }) -> GalSum {
        var out: [[GalLiteral]] = []
        for r in rows where enabled(r) {
            if let l = row(f, r, cols: cols, colToPin: colToPin, flip: flip) { out.append(l) }
        }
        if out.contains(where: { $0.isEmpty }) { return GalSum(rows: [[]]) }
        return GalSum(rows: out)
    }

    private static func inverse(_ table: [Int?]) -> [Int: Int] {
        var m: [Int: Int] = [:]
        for (i, c) in table.enumerated() { if let c = c { m[c] = i + 1 } }
        return m
    }

    private static func decodeV8(_ f: [Bool], chip: GalChipType, notes: inout [String]) throws -> GalDesign {
        let is16 = chip == .gal16v8
        let cols = is16 ? 32 : 40
        var p = cols * 64
        let xor = Array(f[p..<p + 8]); p += 8
        let sig = bytes(f[p..<p + 64]); p += 64
        let ac1 = Array(f[p..<p + 8]); p += 8
        let pt = Array(f[p..<p + 64]); p += 64
        let syn = f[p], ac0 = f[p + 1]

        let mode: String, table: [Int?]
        switch (syn, ac0) {
        case (true, false): mode = "simple"; table = is16 ? col16Simple : col20Simple
        case (true, true): mode = "complex"; table = is16 ? col16Complex : col20Complex
        case (false, true): mode = "registered"; table = is16 ? col16Registered : col20Registered
        default: throw DecodeError.invalidMode
        }
        let colToPin = inverse(table)
        let firstOLMC = is16 ? 12 : 15
        let enabled: (Int) -> Bool = { pt[$0] }
        if pt.contains(false) { notes.append("Some product terms are switched off with PTD fuses; they are left out.") }

        var outputs: [GalOutput] = []
        var olmcInputs: [Int] = []
        for olmc in (0..<8).reversed() {
            let pin = firstOLMC + olmc
            let bit = 7 - olmc
            let start = rowsV8[olmc]
            let active = xor[bit]
            var out: GalOutput?
            switch mode {
            case "simple":
                if !ac1[bit] {
                    out = GalOutput(pin: pin, kind: .combinatorial, activeHigh: active,
                                    term: sum(f, rows: start..<start + 8, cols: cols, colToPin: colToPin, enabled: enabled),
                                    enable: nil, productTermsAvailable: 8)
                }
            case "registered" where !ac1[bit]:
                out = GalOutput(pin: pin, kind: .registered, activeHigh: active,
                                term: sum(f, rows: start..<start + 8, cols: cols, colToPin: colToPin, enabled: enabled),
                                enable: nil, productTermsAvailable: 8)
            default:   // complex mode, or a combinatorial OLMC in registered mode: row 0 is the output enable
                if mode == "complex" && !ac1[bit] {
                    notes.append("Pin \(pin): AC1 = 0 isn't defined in complex mode; decoded as a tristate output.")
                }
                let oe = sum(f, rows: start..<start + 1, cols: cols, colToPin: colToPin, enabled: enabled)
                if !oe.isFalse {
                    out = GalOutput(pin: pin, kind: .combinatorial, activeHigh: active,
                                    term: sum(f, rows: start + 1..<start + 8, cols: cols, colToPin: colToPin, enabled: enabled),
                                    enable: oe.isTrue ? nil : oe, productTermsAvailable: 7)
                }
            }
            if let o = out, o.term.isFalse && !o.activeHigh {
                out = nil   // nothing programmed: Galette/galasm leave unused OLMCs like this
            }
            if let o = out { outputs.append(o) } else if table[pin - 1] != nil { olmcInputs.append(pin) }
        }
        let reg = mode == "registered"
        let dedicated = (1...chip.pins).filter { pin in
            table[pin - 1] != nil && !(firstOLMC...(firstOLMC + 7)).contains(pin)
        }
        return GalDesign(chip: chip, mode: mode, outputs: outputs,
                         inputPins: dedicated + olmcInputs.sorted(),
                         clockPin: reg ? 1 : nil, oePin: reg ? (is16 ? 11 : 13) : nil,
                         asyncReset: nil, syncPreset: nil, signature: sig, securityBit: false, notes: notes)
    }

    private static func decode22V10(_ f: [Bool], notes: inout [String]) -> GalDesign {
        let cols = 44
        var p = cols * 132
        var s0: [Bool] = [], s1: [Bool] = []
        for _ in 0..<10 { s0.append(f[p]); s1.append(f[p + 1]); p += 2 }
        let sig = bytes(f[p..<p + 64])
        let colToPin = inverse(col22V10)
        // Registered outputs feed back /Q; in active-high mode that is the inverse of the pin,
        // so those literals are flipped to read in terms of the pin's own level.
        var flip = Set<Int>()
        for olmc in 0..<10 where !s1[9 - olmc] && s0[9 - olmc] { flip.insert(14 + olmc) }

        var outputs: [GalOutput] = []
        var olmcInputs: [Int] = []
        for olmc in (0..<10).reversed() {
            let pin = 14 + olmc, bit = 9 - olmc
            let start = rows22V10[olmc], size = size22V10[olmc]
            let oe = sum(f, rows: start..<start + 1, cols: cols, colToPin: colToPin, flip: flip)
            let term = sum(f, rows: start + 1..<start + size, cols: cols, colToPin: colToPin, flip: flip)
            if oe.isFalse || (term.isFalse && !s0[bit]) {
                olmcInputs.append(pin)
                continue
            }
            outputs.append(GalOutput(pin: pin, kind: s1[bit] ? .combinatorial : .registered, activeHigh: s0[bit],
                                     term: term, enable: oe.isTrue ? nil : oe, productTermsAvailable: size - 1))
        }
        let ar = sum(f, rows: 0..<1, cols: cols, colToPin: colToPin, flip: flip)
        let sp = sum(f, rows: 131..<132, cols: cols, colToPin: colToPin, flip: flip)
        let anyReg = outputs.contains { $0.kind == .registered }
        return GalDesign(chip: .gal22v10, mode: "", outputs: outputs,
                         inputPins: Array(1...11) + [13] + olmcInputs.sorted(),
                         clockPin: anyReg ? 1 : nil, oePin: nil,
                         asyncReset: ar.isFalse ? nil : ar, syncPreset: sp.isFalse ? nil : sp,
                         signature: sig, securityBit: false, notes: notes)
    }
}

// MARK: Text output (galasm-style equations)

extension GalDesign {
    func name(_ pin: Int, _ names: [Int: String]) -> String {
        if pin < 0 { return "col\(-pin - 1)" }
        return names[pin] ?? "P\(pin)"
    }

    func literal(_ l: GalLiteral, _ names: [Int: String]) -> String {
        (l.negated ? "/" : "") + name(l.pin, names)
    }

    func expression(_ s: GalSum, _ names: [Int: String], indent: Int) -> String {
        if s.isTrue { return "VCC" }
        if s.isFalse { return "GND" }
        let pad = "\n" + String(repeating: " ", count: max(0, indent - 2)) + "+ "
        return s.rows.map { $0.map { literal($0, names) }.joined(separator: " * ") }.joined(separator: pad)
    }

    func modeDescription() -> String {
        switch mode {
        case "simple": return "simple mode (combinatorial outputs, always enabled)"
        case "complex": return "complex mode (combinatorial outputs with product-term output enable)"
        case "registered": return "registered mode (pin \(clockPin ?? 1) = clock, pin \(oePin ?? 11) = /OE for registered outputs)"
        default: return clockPin != nil ? "pin 1 = clock for registered outputs" : "all outputs combinatorial"
        }
    }

    func equations(names: [Int: String] = [:]) -> String {
        var s = "; \(chip.rawValue) – \(modeDescription())\n"
        s += "; Decoded by ChipBurner. Signature: \(signatureText.isEmpty ? "(none)" : signatureText)\n"
        for n in notes { s += "; Note: \(n)\n" }
        s += "\n"
        if outputs.isEmpty { s += "; No outputs are programmed.\n" }
        for o in outputs {
            var lhs = (o.activeHigh ? "" : "/") + name(o.pin, names)
            if o.kind == .registered { lhs += ".R" } else if o.enable != nil { lhs += ".T" }
            let head = lhs + " = "
            s += head + expression(o.term, names, indent: head.count) + "\n"
            if let e = o.enable {
                let eh = name(o.pin, names) + ".E = "
                s += eh + expression(e, names, indent: eh.count) + "\n"
            }
            s += "\n"
        }
        if let ar = asyncReset { s += "AR = " + expression(ar, names, indent: 5) + "\n" }
        if let sp = syncPreset { s += "SP = " + expression(sp, names, indent: 5) + "\n" }
        if asyncReset != nil || syncPreset != nil { s += "\n" }

        s += "; Pins\n"
        for pin in 1...chip.pins {
            s += String(format: "; %2d  ", pin) + role(of: pin) + "\n"
        }
        return s
    }

    func role(of pin: Int) -> String {
        if pin == chip.pins { return "VCC" }
        if pin == chip.pins / 2 { return "GND" }
        if pin == clockPin { return chip == .gal22v10 ? "clock / input" : "clock" }
        if pin == oePin { return "/OE (output enable for registered outputs)" }
        if let o = outputs.first(where: { $0.pin == pin }) {
            var r = o.kind == .registered ? "registered output" : (o.enable != nil ? "tristate output" : "combinatorial output")
            r += o.activeHigh ? ", active high" : ", active low"
            r += " (\(o.productTermsUsed) of \(o.productTermsAvailable) product terms)"
            return r
        }
        return inputPins.contains(pin) ? "input" : "not used"
    }
}
