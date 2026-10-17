import Foundation

/// A logic test in minipro's logicic.xml format: one test vector per line, one character per pin.
///   0 / 1  drive the pin low / high          L / H  expect the pin low / high
///   C      clock pulse on the pin             Z      expect high impedance (reads high via pull-up)
///   X      don't care                         G / V  ground / supply
struct LogicTest: Equatable {
    var name: String
    var pins: Int
    var voltage: String          // "5V", "3.3V", "2.5V", "1.8V"
    var vectors: [[Character]]

    static let validChars: Set<Character> = ["0", "1", "L", "H", "C", "Z", "X", "G", "V"]
    static let pinCounts = [8, 14, 16, 18, 20, 22, 24, 28, 32, 40]
    static let voltages = ["5V", "3.3V", "2.5V", "1.8V"]

    /// minipro wants a plain name for -p.
    var safeName: String {
        let s = name.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return s.isEmpty ? "CUSTOM" : String(s)
    }

    /// Problems that would make minipro reject the test or the result meaningless.
    func problems() -> [String] {
        var out: [String] = []
        if !LogicTest.pinCounts.contains(pins) { out.append("Pin count \(pins) isn't supported.") }
        if vectors.isEmpty { out.append("There are no vectors.") }
        for (i, v) in vectors.enumerated() {
            if v.count != pins { out.append("Vector \(i + 1) has \(v.count) pins, expected \(pins).") }
            if let bad = v.first(where: { !LogicTest.validChars.contains($0) }) { out.append("Vector \(i + 1): '\(bad)' isn't a valid pin state.") }
            if !v.contains("G") || !v.contains("V") { out.append("Vector \(i + 1) needs at least one G (ground) and one V (supply) pin."); break }
        }
        if let first = vectors.first, first.count == pins {
            // Power pins must stay the same in every vector.
            for (i, v) in vectors.enumerated() where v.count == pins {
                for p in 0..<pins where (first[p] == "G" || first[p] == "V" || v[p] == "G" || v[p] == "V") && v[p] != first[p] {
                    out.append("Vector \(i + 1): pin \(p + 1) changes between power and signal."); break
                }
            }
        }
        return Array(out.prefix(12))
    }

    // MARK: Text form (what the editor shows)

    /// One vector per line; spaces optional; ';' starts a comment.
    static func parseVectors(_ text: String) -> [[Character]] {
        text.components(separatedBy: .newlines).compactMap { line in
            let code = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let chars = code.uppercased().filter { !$0.isWhitespace }
            return chars.isEmpty ? nil : Array(chars)
        }
    }

    func vectorText(withPinHeader: Bool = true) -> String {
        var s = ""
        if withPinHeader {
            s += "; pin   " + (1...pins).map { String(format: "%-2d", $0 % 100) }.joined() + "\n"
        }
        for (i, v) in vectors.enumerated() {
            s += String(format: "  %04d  ", i) + v.map { String($0) + " " }.joined() + "\n"
        }
        return s
    }

    // MARK: logicic.xml

    func xml() -> String {
        var s = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<logicic>\n  <database type=\"LOGIC\">\n    <manufacturer name=\"ChipBurner\">\n"
        s += "      <ic name=\"\(safeName)\" type=\"5\" voltage=\"\(voltage)\" pins=\"\(pins)\">\n"
        for (i, v) in vectors.enumerated() {
            s += String(format: "        <vector id=\"%02d\"> ", i) + v.map { String($0) }.joined(separator: " ") + " </vector>\n"
        }
        s += "      </ic>\n    </manufacturer>\n  </database>\n</logicic>\n"
        return s
    }

    /// Reads the first (or the named) <ic> from logicic.xml text.
    static func parseXML(_ text: String, name wanted: String? = nil) -> LogicTest? {
        var searchFrom = text.startIndex
        while let icStart = text.range(of: "<ic ", range: searchFrom..<text.endIndex) {
            guard let tagEnd = text.range(of: ">", range: icStart.upperBound..<text.endIndex),
                  let icEnd = text.range(of: "</ic>", range: tagEnd.upperBound..<text.endIndex) else { return nil }
            let tag = String(text[icStart.lowerBound..<tagEnd.upperBound])
            func attr(_ n: String) -> String? {
                guard let r = tag.range(of: n + "=\""), let e = tag.range(of: "\"", range: r.upperBound..<tag.endIndex) else { return nil }
                return String(tag[r.upperBound..<e.lowerBound])
            }
            let names = (attr("name") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if wanted == nil || names.contains(where: { $0.caseInsensitiveCompare(wanted!) == .orderedSame }) {
                let body = String(text[tagEnd.upperBound..<icEnd.lowerBound])
                var vectors: [[Character]] = []
                var from = body.startIndex
                while let vs = body.range(of: "<vector", range: from..<body.endIndex),
                      let gt = body.range(of: ">", range: vs.upperBound..<body.endIndex),
                      let ve = body.range(of: "</vector>", range: gt.upperBound..<body.endIndex) {
                    vectors.append(Array(body[gt.upperBound..<ve.lowerBound].filter { !$0.isWhitespace }))
                    from = ve.upperBound
                }
                return LogicTest(name: wanted ?? names.first ?? "CUSTOM", pins: Int(attr("pins") ?? "") ?? (vectors.first?.count ?? 0),
                                 voltage: attr("voltage") ?? "5V", vectors: vectors)
            }
            searchFrom = icEnd.upperBound
        }
        return nil
    }

    // MARK: Result of minipro -T

    struct Result {
        var errors = 0
        var failingVectors: [Int] = []
        var passed = false
        var table: [String] = []
    }

    /// minipro prints the pin header, then "0003: 0  1  L- H …" per vector (a '-' after a pin marks an error).
    static func parseResult(_ output: String) -> Result {
        var r = Result()
        for line in output.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.range(of: "^\\d{4}:", options: .regularExpression) != nil {
                r.table.append(t)
                if t.contains("-") {
                    let n = Int(t.prefix(4)) ?? -1
                    r.failingVectors.append(n)
                    r.errors += t.filter { $0 == "-" }.count
                }
            } else if t.range(of: "^\\s*1\\s+2\\s+3", options: .regularExpression) != nil {
                r.table.insert(t, at: 0)
            }
            if t.lowercased().contains("logic test successful") { r.passed = true }
        }
        if !r.failingVectors.isEmpty { r.passed = false }
        return r
    }
}

// MARK: GAL functional test

/// Simulates a decoded GAL with 0/1/unknown logic and writes test vectors for the logic tester.
enum GalTestGenerator {
    enum Tri: Equatable {
        case zero, one, x
        static func from(_ b: Bool) -> Tri { b ? .one : .zero }
        var not: Tri { self == .x ? .x : (self == .one ? .zero : .one) }
    }

    struct Output {
        var test: LogicTest
        var notes: [String]
        var checkedOutputs: [Int]
    }

    static func and(_ a: Tri, _ b: Tri) -> Tri {
        if a == .zero || b == .zero { return .zero }
        if a == .one && b == .one { return .one }
        return .x
    }

    static func or(_ a: Tri, _ b: Tri) -> Tri {
        if a == .one || b == .one { return .one }
        if a == .zero && b == .zero { return .zero }
        return .x
    }

    static func eval(_ s: GalSum, _ value: (Int) -> Tri) -> Tri {
        if s.isTrue { return .one }
        var acc = Tri.zero
        for row in s.rows {
            var r = Tri.one
            for l in row {
                let v = l.pin > 0 ? value(l.pin) : .x
                r = and(r, l.negated ? v.not : v)
                if r == .zero { break }
            }
            acc = or(acc, r)
            if acc == .one { break }
        }
        return acc
    }

    static func generate(_ d: GalDesign, maxVectors: Int = 128, seed: UInt64 = 0x5EED) -> Output {
        let pins = d.chip.pins
        let gnd = pins / 2, vcc = pins
        var notes: [String] = []
        let outputs = Dictionary(uniqueKeysWithValues: d.outputs.map { ($0.pin, $0) })
        let registered = d.outputs.filter { $0.kind == .registered }
        let is20RA10 = d.chip == .gal20ra10
        let clockPin: Int? = (!registered.isEmpty && !is20RA10) ? (d.clockPin ?? 1) : nil

        // Pins with a fixed level: /OE low (registered GALxxV8), /PL high and /OE low (GAL20RA10).
        var fixed: [Int: Character] = [:]
        if let oe = d.oePin { fixed[oe] = "0" }
        if is20RA10 { fixed[1] = "1"; fixed[13] = "0" }

        // Inputs that the equations actually use get varied; other inputs are held low.
        var used = Set<Int>()
        func collect(_ s: GalSum?) { s?.rows.forEach { $0.forEach { if $0.pin > 0 { used.insert($0.pin) } } } }
        for o in d.outputs { collect(o.term); collect(o.enable); collect(o.clock); collect(o.reset); collect(o.preset) }
        collect(d.asyncReset); collect(d.syncPreset)
        let inputPins = d.inputPins.filter { $0 != gnd && $0 != vcc && outputs[$0] == nil && fixed[$0] == nil && $0 != clockPin }
        let varied = inputPins.filter { used.contains($0) }.sorted()
        let held = inputPins.filter { !used.contains($0) }

        // Input combinations: all of them when few, otherwise walking bits plus pseudo-random ones.
        var combos: [[Bool]] = []
        let n = varied.count
        if n <= 7 {
            for k in 0..<(1 << n) { combos.append((0..<n).map { k & (1 << $0) != 0 }) }
        } else {
            combos.append([Bool](repeating: false, count: n))
            combos.append([Bool](repeating: true, count: n))
            for i in 0..<n { combos.append((0..<n).map { $0 == i }) }
            for i in 0..<n { combos.append((0..<n).map { $0 != i }) }
            var s = seed
            while combos.count < maxVectors {
                s = s &* 6364136223846793005 &+ 1442695040888963407
                combos.append((0..<n).map { (s >> UInt64(33 + $0 % 30)) & 1 == 1 })
            }
            notes.append("\(n) inputs are used, so \(maxVectors) of the \(1 << min(n, 62)) input combinations are tested (all-0, all-1, walking bits and random ones).")
        }
        if registered.count > 0 && n <= 7 && combos.count < 2 * (1 << n) {
            combos += combos   // run the sequence twice so registers get loaded before being checked
        }
        combos = Array(combos.prefix(maxVectors))

        // Register state at pin level: unknown at power-up.
        var state: [Int: Tri] = [:]
        for o in registered { state[o.pin] = .x }

        var vectors: [[Character]] = []
        var checked = Set<Int>()
        for combo in combos {
            var drive: [Int: Tri] = [:]
            for (i, p) in varied.enumerated() { drive[p] = .from(combo[i]) }
            for p in held { drive[p] = .zero }
            for (p, c) in fixed { drive[p] = c == "1" ? .one : .zero }

            // Combinatorial outputs, settled from unknown, given the current register state.
            func settle(_ regs: [Int: Tri]) -> (values: [Int: Tri], enabled: [Int: Tri]) {
                var vals: [Int: Tri] = [:], ens: [Int: Tri] = [:]
                for o in d.outputs where o.kind == .combinatorial { vals[o.pin] = .x }
                func value(_ p: Int) -> Tri {
                    if p == clockPin { return .x }
                    if let v = drive[p] { return v }
                    if let r = regs[p] { return r }
                    if let v = vals[p] { return ens[p] == .one ? v : .x }
                    return .x
                }
                for _ in 0..<8 {
                    var changed = false
                    for o in d.outputs where o.kind == .combinatorial {
                        let en = o.enable.map { eval($0, value) } ?? .one
                        let t = eval(o.term, value)
                        let v = o.activeHigh ? t : t.not
                        if vals[o.pin] != v || ens[o.pin] != en { changed = true }
                        vals[o.pin] = v; ens[o.pin] = en
                    }
                    if !changed { break }
                }
                for o in registered {
                    ens[o.pin] = (d.oePin != nil || is20RA10) ? .one : (o.enable.map { eval($0, value) } ?? .one)
                }
                return (vals, ens)
            }

            if is20RA10 {
                for o in registered { state[o.pin] = .x }
            } else if !registered.isEmpty {
                // Clock pulse: every register takes its D input (pin level); 22V10 AR/SP apply too.
                func value(_ p: Int) -> Tri {
                    if p == clockPin { return .x }
                    if let v = drive[p] { return v }
                    if let r = state[p] { return r }
                    return settle(state).values[p] ?? .x
                }
                var next: [Int: Tri] = [:]
                let sp = d.syncPreset.map { eval($0, value) } ?? .zero
                for o in registered {
                    let dv = eval(o.term, value)
                    var pinVal = o.activeHigh ? dv : dv.not
                    let presetVal: Tri = o.activeHigh ? .one : .zero
                    if sp == .one { pinVal = presetVal } else if sp == .x && pinVal != presetVal { pinVal = .x }
                    next[o.pin] = pinVal
                }
                state = next
                if let ar = d.asyncReset {
                    let a = eval(ar, value)
                    for o in registered {
                        let resetVal: Tri = o.activeHigh ? .zero : .one
                        if a == .one { state[o.pin] = resetVal } else if a == .x && state[o.pin] != resetVal { state[o.pin] = .x }
                    }
                }
            }

            let (vals, ens) = settle(state)
            var v = [Character](repeating: "X", count: pins)
            v[gnd - 1] = "G"; v[vcc - 1] = "V"
            for (p, t) in drive { v[p - 1] = t == .one ? "1" : "0" }
            if let c = clockPin { v[c - 1] = "C" }
            for o in d.outputs {
                let val = o.kind == .registered ? (state[o.pin] ?? .x) : (vals[o.pin] ?? .x)
                let en = ens[o.pin] ?? .one
                let ch: Character
                switch (en, val) {
                case (.zero, _): ch = "Z"
                case (.one, .one): ch = "H"
                case (.one, .zero): ch = "L"
                default: ch = "X"
                }
                if ch != "X" { checked.insert(o.pin) }
                v[o.pin - 1] = ch
            }
            vectors.append(v)
        }

        if !registered.isEmpty && !is20RA10 {
            notes.append("Registered outputs start in an unknown state; each vector clocks pin \(clockPin ?? 1) once, and an output is checked only once its value is known.")
        }
        if is20RA10 && !registered.isEmpty {
            notes.append("GAL20RA10 registered outputs have product-term clocks, so only the combinatorial outputs are checked.")
        }
        let unchecked = d.outputs.map { $0.pin }.filter { !checked.contains($0) }
        if !unchecked.isEmpty {
            notes.append("Output pin(s) \(unchecked.map(String.init).joined(separator: ", ")) never reach a known value in this test and aren't checked.")
        }
        let test = LogicTest(name: d.chip.rawValue + "TEST", pins: pins, voltage: "5V", vectors: vectors)
        return Output(test: test, notes: notes, checkedOutputs: checked.sorted())
    }
}
