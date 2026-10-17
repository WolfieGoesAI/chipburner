import Foundation

/// Reading out a combinatorial bipolar PAL through the logic tester and turning it into a GAL16V8.
///
/// Every input combination is applied with all outputs expected low; minipro marks each output pin
/// that isn't low with '-', so the marked pins are the ones that read high. That gives the complete
/// truth table, from which sum-of-products equations are worked out, written as galasm source,
/// assembled with GalAssembler and checked against the truth table again.
enum PalReadout {

    struct PalType: Equatable {
        let name: String
        let inputs: [Int]
        let outputs: [Int]
        let note: String
    }

    // Standard 20-pin small PALs (MMI/TI/NS). H = active-high outputs, L = active-low, C = both polarities.
    static let types: [PalType] = [
        PalType(name: "PAL10H8 / PAL10L8", inputs: [1, 2, 3, 4, 5, 6, 7, 8, 9, 11], outputs: Array(12...19), note: "10 inputs, 8 outputs"),
        PalType(name: "PAL12H6 / PAL12L6", inputs: [1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 19], outputs: Array(13...18), note: "12 inputs, 6 outputs"),
        PalType(name: "PAL14H4 / PAL14L4", inputs: [1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 18, 19], outputs: Array(14...17), note: "14 inputs, 4 outputs"),
        PalType(name: "PAL16H2 / PAL16L2 / PAL16C1", inputs: [1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 17, 18, 19], outputs: [15, 16], note: "16 inputs, 2 outputs"),
    ]

    static let pins = 20
    static let chunk = 1024

    /// Test vectors for input combinations start..<end: inputs driven, outputs expected low.
    static func vectors(_ t: PalType, range: Range<Int>) -> [[Character]] {
        range.map { k in
            var v = [Character](repeating: "X", count: pins)
            v[9] = "G"; v[19] = "V"
            for (j, p) in t.inputs.enumerated() { v[p - 1] = (k >> j) & 1 == 1 ? "1" : "0" }
            for p in t.outputs { v[p - 1] = "L" }
            return v
        }
    }

    /// Output bits (bit i = t.outputs[i]) for each vector line minipro printed, in order.
    /// Returns nil if the table is missing or incomplete.
    static func parseTable(_ output: String, type t: PalType, expected: Int) -> [UInt16]? {
        var rows: [UInt16] = []
        for line in output.components(separatedBy: .newlines) {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.range(of: "^\\d{4}:", options: .regularExpression) != nil else { continue }
            let tokens = s.dropFirst(5).split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard tokens.count == pins else { return nil }
            var bits: UInt16 = 0
            for (i, p) in t.outputs.enumerated() where tokens[p - 1].contains("-") { bits |= 1 << UInt16(i) }
            rows.append(bits)
        }
        return rows.count == expected ? rows : nil
    }

    /// Output bits from the file minipro writes with --logicic_out: every vector again, with the
    /// level each output pin actually had (H, L, or Z when it floated). Returns nil if the file is
    /// missing vectors or has a pin state that isn't a level.
    static func parseResultFile(_ xml: String, type t: PalType, expected: Int) -> [UInt16]? {
        guard let test = LogicTest.parseXML(xml), test.vectors.count == expected else { return nil }
        var rows: [UInt16] = []
        rows.reserveCapacity(expected)
        for v in test.vectors {
            guard v.count == pins else { return nil }
            var bits: UInt16 = 0
            for (i, p) in t.outputs.enumerated() {
                switch v[p - 1] {
                case "H", "Z": bits |= 1 << UInt16(i)     // a bipolar PAL output never floats; Z means pulled high
                case "L": break
                default: return nil
                }
            }
            rows.append(bits)
        }
        return rows
    }

    // MARK: Minimisation

    /// A product term: `mask` says which inputs appear, `value` their required levels.
    struct Cube: Equatable { var mask: Int; var value: Int }

    /// Sum of products covering exactly the on-set (greedy expansion, then redundant terms removed).
    static func cover(n: Int, isOn: (Int) -> Bool, limit: Int = 64) -> [Cube]? {
        let size = 1 << n
        let all = size - 1
        var covered = [Bool](repeating: false, count: size)
        var cubes: [Cube] = []
        func cubeOK(_ c: Cube) -> Bool {
            let free = all & ~c.mask
            var sub = free
            while true {
                if !isOn((c.value & c.mask) | sub) { return false }
                if sub == 0 { break }
                sub = (sub - 1) & free
            }
            return true
        }
        func mark(_ c: Cube) {
            let free = all & ~c.mask
            var sub = free
            while true {
                covered[(c.value & c.mask) | sub] = true
                if sub == 0 { break }
                sub = (sub - 1) & free
            }
        }
        for m in 0..<size where isOn(m) && !covered[m] {
            var c = Cube(mask: all, value: m)
            var improved = true
            while improved {
                improved = false
                for j in 0..<n where c.mask & (1 << j) != 0 {
                    let t = Cube(mask: c.mask & ~(1 << j), value: c.value)
                    if cubeOK(t) { c = t; improved = true }
                }
            }
            cubes.append(c)
            if cubes.count > limit { return nil }
            mark(c)
        }
        // Drop terms that the others already cover.
        var i = 0
        while i < cubes.count {
            let others = cubes.enumerated().filter { $0.offset != i }.map { $0.element }
            let c = cubes[i]
            let free = all & ~c.mask
            var sub = free, redundant = true
            while true {
                let m = (c.value & c.mask) | sub
                if !others.contains(where: { m & $0.mask == $0.value & $0.mask }) { redundant = false; break }
                if sub == 0 { break }
                sub = (sub - 1) & free
            }
            if redundant { cubes.remove(at: i) } else { i += 1 }
        }
        return cubes
    }

    struct Clone {
        var source: String
        var jedec: String
        var equations: [String]
        var notes: [String]
    }

    enum CloneError: Error, CustomStringConvertible {
        case tooManyTerms(pin: Int, terms: Int)
        case assembler(String)
        case mismatch(Int)
        var description: String {
            switch self {
            case .tooManyTerms(let p, let t): return "Output pin \(p) needs \(t) product terms, more than the GAL16V8's 8 – the readout may be unreliable, or this isn't a simple combinatorial PAL."
            case .assembler(let s): return "Assembling the GAL16V8 failed: \(s)"
            case .mismatch(let k): return "The GAL16V8 fuse map doesn't reproduce the readout (first difference at input combination \(k))."
            }
        }
    }

    /// Truth table → galasm source for a pin-compatible GAL16V8 → assembled and verified fuse map.
    static func makeClone(_ t: PalType, table: [UInt16], palName: String) throws -> Clone {
        let n = t.inputs.count
        precondition(table.count == 1 << n)
        func name(_ p: Int) -> String { t.inputs.contains(p) ? "I\(p)" : t.outputs.contains(p) ? "O\(p)" : (p == 10 ? "GND" : p == 20 ? "VCC" : "NC") }
        func term(_ c: Cube) -> String {
            let lits = (0..<n).filter { c.mask & (1 << $0) != 0 }.map { j -> String in
                (c.value & (1 << j) != 0 ? "" : "/") + "I\(t.inputs[j])"
            }
            return lits.isEmpty ? "VCC" : lits.joined(separator: " * ")
        }
        var eqLines: [String] = []
        var notes: [String] = []
        for (i, p) in t.outputs.enumerated() {
            let on = { (k: Int) -> Bool in table[k] & (1 << UInt16(i)) != 0 }
            let ones = (0..<table.count).filter(on).count
            if ones == 0 { eqLines.append("O\(p) = GND"); notes.append("Pin \(p) is always low."); continue }
            if ones == table.count { eqLines.append("O\(p) = VCC"); notes.append("Pin \(p) is always high – possibly an unused output."); continue }
            let high = cover(n: n, isOn: on)
            let low = cover(n: n, isOn: { !on($0) })
            // Pick the shorter form; active-low when the inverse needs fewer terms (typical for PALxxL parts).
            let useLow: Bool
            switch (high, low) {
            case let (h?, l?): useLow = l.count < h.count
            case (nil, .some): useLow = true
            default: useLow = false
            }
            guard let cubes = useLow ? low : high else { throw CloneError.tooManyTerms(pin: p, terms: 65) }
            if cubes.count > 8 { throw CloneError.tooManyTerms(pin: p, terms: cubes.count) }
            eqLines.append((useLow ? "/" : "") + "O\(p) = " + cubes.map(term).joined(separator: "\n      + "))
        }
        let row1 = (1...10).map(name).joined(separator: " ")
        let row2 = (11...20).map(name).joined(separator: " ")
        let sig = String(palName.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(8))
        let source = """
            GAL16V8
            \(sig.isEmpty ? "PALCLONE" : sig)

            \(row1)
            \(row2)

            \(eqLines.joined(separator: "\n"))

            DESCRIPTION

            GAL16V8 replacement for a \(palName), read out with ChipBurner's logic tester
            (\(table.count) input combinations). Pin-compatible: inputs \(t.inputs.map(String.init).joined(separator: ",")), outputs \(t.outputs.map(String.init).joined(separator: ",")).

            """
        let jed: String
        do { jed = try GalAssembler.assemble(source).jedec } catch { throw CloneError.assembler("\(error)") }
        // Check the result against every row of the readout.
        let design = try GalDecoder.decode(try JEDECFile.parse(jed))
        for k in 0..<table.count {
            func value(_ pin: Int) -> GalTestGenerator.Tri {
                if let j = t.inputs.firstIndex(of: pin) { return .from((k >> j) & 1 == 1) }
                return .x
            }
            var got: UInt16 = 0
            for (i, p) in t.outputs.enumerated() {
                guard let o = design.outputs.first(where: { $0.pin == p }) else {
                    // An output that is always low with no logic is left unprogrammed.
                    if table[k] & (1 << UInt16(i)) != 0 { throw CloneError.mismatch(k) }
                    continue
                }
                let v = GalTestGenerator.eval(o.term, value)
                let pinV: GalTestGenerator.Tri = o.activeHigh ? v : v.not
                if pinV == .one { got |= 1 << UInt16(i) } else if pinV == .x { throw CloneError.mismatch(k) }
            }
            if got != table[k] { throw CloneError.mismatch(k) }
        }
        return Clone(source: source, jedec: jed, equations: eqLines, notes: notes)
    }
}
