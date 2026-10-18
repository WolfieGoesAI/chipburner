import Foundation

/// Working models of common logic chips, used by the Extended Logic Test to generate test vectors:
/// every input combination for combinational chips, and reset / full-cycle / random sequences for
/// flip-flops, latches, counters and shift registers. The models use three-valued logic (true, false,
/// unknown) so an output is only checked once its value is certain. The build replays minipro's own
/// test vectors through every model and requires them to agree.
final class LogicSim {
    let names: [String]
    private let index: [String: Int]
    var cur: [Bool?]
    var prev: [Bool?]
    var out: [(String, Bool?)] = []
    var ints: [String: Int] = [:]          // counters (missing = unknown)
    var flags: [String: Bool] = [:]        // flip-flops (missing = unknown)
    var regs: [String: [Bool?]] = [:]      // registers

    init(names: [String]) {
        self.names = names
        var d: [String: Int] = [:]
        for (i, n) in names.enumerated() where d[n] == nil { d[n] = i }
        index = d
        cur = [Bool?](repeating: nil, count: names.count)
        prev = cur
    }

    func idx(_ n: String) -> Int? { index[n] }
    func v(_ n: String) -> Bool? { index[n].flatMap { cur[$0] } }
    func rose(_ n: String) -> Bool { guard let i = index[n] else { return false }; return prev[i] == false && cur[i] == true }
    func fell(_ n: String) -> Bool { guard let i = index[n] else { return false }; return prev[i] == true && cur[i] == false }
    func o(_ n: String, _ value: Bool?) { out.append((n, value)) }
    func flag(_ k: String) -> Bool? { flags[k] }
    func setFlag(_ k: String, _ value: Bool?) { if let b = value { flags[k] = b } else { flags.removeValue(forKey: k) } }
    func int(_ k: String) -> Int? { ints[k] }
    func setInt(_ k: String, _ value: Int?) { if let x = value { ints[k] = x } else { ints.removeValue(forKey: k) } }
}

// MARK: Three-valued helpers

private func not3(_ a: Bool?) -> Bool? { a.map { !$0 } }
private func and3(_ xs: Bool?...) -> Bool? { and3(xs) }
private func and3(_ xs: [Bool?]) -> Bool? {
    if xs.contains(where: { $0 == false }) { return false }
    return xs.allSatisfy { $0 == true } ? true : nil
}
private func or3(_ xs: [Bool?]) -> Bool? {
    if xs.contains(where: { $0 == true }) { return true }
    return xs.allSatisfy { $0 == false } ? false : nil
}
private func xor3(_ a: Bool?, _ b: Bool?) -> Bool? {
    guard let a = a, let b = b else { return nil }
    return a != b
}
private func bits(_ xs: [Bool?]) -> Int? {
    var r = 0
    for (i, x) in xs.enumerated() {
        guard let b = x else { return nil }
        if b { r |= 1 << i }
    }
    return r
}
private func bit(_ value: Int?, _ i: Int) -> Bool? { value.map { ($0 >> i) & 1 == 1 } }

enum LogicModels {
    typealias Step = (LogicSim) -> Void

    struct Model {
        let step: Step
        var sequential = false
        var rest: [(String, Bool)] = []    // control pins and their inactive level
        var clocks: [String] = []
        var full = 0                       // clock pulses in the full-cycle part
    }

    // MARK: Combinational

    static let gateOps: [String: String] = [
        "7400": "nand", "7410": "nand", "7420": "nand", "7430": "nand", "4011": "nand", "4093": "nand",
        "7408": "and", "7411": "and", "7421": "and", "4081": "and",
        "7402": "nor", "7427": "nor", "4001": "nor", "7432": "or", "4071": "or", "7486": "xor", "4070": "xor",
        "7404": "inv", "4049": "inv", "4050": "buf",
    ]

    private static func gates(_ names: [String], _ op: String) -> Step {
        let outs = names.filter { $0.range(of: "^[0-9]?Y$", options: .regularExpression) != nil }
        let groups: [(String, [String])] = outs.map { y in
            let p = String(y.dropLast())
            return (y, names.filter { $0.count == p.count + 1 && $0.hasPrefix(p) && "ABCDEFGH".contains($0.last!) && $0.range(of: "^[0-9]?[A-H]$", options: .regularExpression) != nil })
        }
        return { s in
            for (y, ins) in groups {
                let xs = ins.map { s.v($0) }
                let r: Bool?
                switch op {
                case "nand": r = not3(and3(xs))
                case "and": r = and3(xs)
                case "nor": r = not3(or3(xs))
                case "or": r = or3(xs)
                case "xor": r = xor3(xs.first ?? nil, xs.count > 1 ? xs[1] : nil)
                case "inv": r = not3(xs.first ?? nil)
                default: r = xs.first ?? nil
                }
                s.o(y, r)
            }
        }
    }

    private static func tristateBuffers(activeLow: Bool) -> Step {
        return { s in
            for k in ["1", "2", "3", "4"] {
                let oe = s.v(activeLow ? "\(k)/OE" : "\(k)OE")
                let en = activeLow ? not3(oe) : oe
                s.o("\(k)Y", en == true ? s.v("\(k)A") : nil)
            }
        }
    }

    private static let m74138: Step = { s in
        let en = and3(s.v("G1"), not3(s.v("/G2A")), not3(s.v("/G2B")))
        let sel = bits([s.v("A"), s.v("B"), s.v("C")])
        for n in 0..<8 {
            let r: Bool?
            if en == false { r = true } else if en == nil || sel == nil { r = nil } else { r = sel! != n }
            s.o("/Y\(n)", r)
        }
    }

    private static let m74139: Step = { s in
        for k in ["1", "2"] {
            let en = not3(s.v("\(k)/G"))
            let sel = bits([s.v("\(k)A"), s.v("\(k)B")])
            for n in 0..<4 {
                let r: Bool? = en == false ? true : (en == nil || sel == nil ? nil : sel! != n)
                s.o("\(k)/Y\(n)", r)
            }
        }
    }

    private static let m74151: Step = { s in
        let g = s.v("/G"), sel = bits([s.v("A"), s.v("B"), s.v("C")])
        let y: Bool?
        if g == true { y = false } else if g == nil || sel == nil { y = nil } else { y = s.v("D\(sel!)") }
        s.o("Y", y); s.o("/W", not3(y))
    }

    private static let m74153: Step = { s in
        let sel = bits([s.v("A"), s.v("B")])
        for k in ["1", "2"] {
            let g = s.v("\(k)/G")
            let y: Bool? = g == true ? false : (g == nil || sel == nil ? nil : s.v("\(k)C\(sel!)"))
            s.o("\(k)Y", y)
        }
    }

    private static let m74157: Step = { s in
        let g = s.v("/G"), sel = s.v("S")
        for k in ["1", "2", "3", "4"] {
            let y: Bool? = g == true ? false : (g == nil || sel == nil ? nil : s.v("\(k)\(sel! ? "B" : "A")"))
            s.o("\(k)Y", y)
        }
    }

    private static let m7483: Step = { s in
        let a = bits((1...4).map { s.v("A\($0)") }), b = bits((1...4).map { s.v("B\($0)") }), c = s.v("C0")
        guard let x = a, let y = b, let ci = c else {
            for i in 1...4 { s.o("S\(i)", nil) }
            s.o("C4", nil); return
        }
        let t = x + y + (ci ? 1 : 0)
        for i in 1...4 { s.o("S\(i)", (t >> (i - 1)) & 1 == 1) }
        s.o("C4", (t >> 4) & 1 == 1)
    }

    private static let m7485: Step = { s in
        let a = bits((0..<4).map { s.v("A\($0)") }), b = bits((0..<4).map { s.v("B\($0)") })
        let gi = s.v("A>Bin"), ei = s.v("A=Bin"), li = s.v("A<Bin")
        var g: Bool?, e: Bool?, l: Bool?
        if let x = a, let y = b {
            if x > y { (g, e, l) = (true, false, false) }
            else if x < y { (g, e, l) = (false, false, true) }
            else if let gi = gi, let ei = ei, let li = li {
                if ei { (g, e, l) = (false, true, false) }
                else if gi && !li { (g, e, l) = (true, false, false) }
                else if li && !gi { (g, e, l) = (false, false, true) }
                else if gi && li { (g, e, l) = (false, false, false) }
                else { (g, e, l) = (true, false, true) }
            }
        }
        s.o("A>Bout", g); s.o("A=Bout", e); s.o("A<Bout", l)
    }

    private static func buffers(inverting: Bool, enables: [[String]], pairs: [(Int, String, String)]) -> Step {
        return { s in
            for (grp, i, o) in pairs {
                let en = and3(enables[grp].map { not3(s.v($0)) })
                let value = s.v(i)
                s.o(o, en == true ? (inverting ? not3(value) : value) : nil)
            }
        }
    }

    private static let pairs240: [(Int, String, String)] = (1...4).map { (0, "1A\($0)", "1Y\($0)") } + (1...4).map { (1, "2A\($0)", "2Y\($0)") }
    private static let pairs541: [(Int, String, String)] = (1...8).map { (0, "A\($0)", "Y\($0)") }

    private static let m74245: Step = { s in
        let oe = s.v("/OE"), d = s.v("DIR")
        for n in 1...8 {
            let a = "A\(n)", b = "B\(n)"
            if oe == false && d == true { s.o(b, s.v(a)); s.o(a, nil) }
            else if oe == false && d == false { s.o(a, s.v(b)); s.o(b, nil) }
            else { s.o(a, nil); s.o(b, nil) }
        }
    }

    // MARK: Sequential

    private static let m7474: Step = { s in
        for k in ["1", "2"] {
            let pre = s.v("\(k)/PRE"), clr = s.v("\(k)/CLR")
            var q = s.flag(k)
            if pre == false && clr == false {
                s.setFlag(k, nil); s.o("\(k)Q", true); s.o("\(k)/Q", true); continue
            }
            if pre == false { q = true }
            else if clr == false { q = false }
            else if pre == nil || clr == nil { q = nil }
            else if s.rose("\(k)CLK") { q = s.v("\(k)D") }
            s.setFlag(k, q)
            s.o("\(k)Q", q); s.o("\(k)/Q", not3(q))
        }
    }

    private static func dRegister(_ n: Int, clock: String?, clear: String?, q: @escaping (Int) -> String, d: @escaping (Int) -> String,
                                  notQ: ((Int) -> String)? = nil, oe: String? = nil, latch: String? = nil) -> Step {
        return { s in
            var r = s.regs["r"] ?? [Bool?](repeating: nil, count: n)
            let c: Bool? = clear.map { s.v($0) } ?? true
            if c == false { r = [Bool?](repeating: false, count: n) }
            else if c == nil { r = [Bool?](repeating: nil, count: n) }
            else if let le = latch {
                let l = s.v(le)
                if l == true { r = (0..<n).map { s.v(d($0)) } }
                else if l == nil { r = (0..<n).map { r[$0] != s.v(d($0)) ? nil : r[$0] } }
            } else if let ck = clock, s.rose(ck) {
                r = (0..<n).map { s.v(d($0)) }
            }
            s.regs["r"] = r
            let en: Bool? = oe.map { not3(s.v($0)) } ?? true
            for i in 0..<n {
                s.o(q(i), en == true ? r[i] : nil)
                if let nq = notQ { s.o(nq(i), not3(r[i])) }
            }
        }
    }

    private static func syncCounter(modulus: Int, asyncClear: Bool) -> Step {
        return { s in
            var c = s.int("c")
            let clr = s.v("/CLR"), load = s.v("/LOAD"), enp = s.v("ENP"), ent = s.v("ENT")
            if asyncClear && clr == false { c = 0 }
            else if asyncClear && clr == nil { c = nil }
            else if s.rose("CLK") {
                if !asyncClear && clr == false { c = 0 }
                else if clr == nil { c = nil }
                else if load == false { c = bits([s.v("A"), s.v("B"), s.v("C"), s.v("D")]) }
                else if load == nil { c = nil }
                else if enp == true && ent == true { c = c.map { ($0 + 1) % modulus } }
                else if enp == nil || ent == nil { c = nil }
            }
            if let x = c, x >= modulus { c = nil }   // decade counters loaded with 10–15 aren't modelled
            s.setInt("c", c)
            for (i, qn) in ["QA", "QB", "QC", "QD"].enumerated() { s.o(qn, bit(c, i)) }
            if ent == false { s.o("RCO", false) }
            else if ent == nil || c == nil { s.o("RCO", nil) }
            else { s.o("RCO", c! == modulus - 1) }
        }
    }

    private static let m74164: Step = { s in
        var r = s.regs["r"] ?? [Bool?](repeating: nil, count: 8)
        if s.v("/CLR") == false { r = [Bool?](repeating: false, count: 8) }
        else if s.v("/CLR") == nil { r = [Bool?](repeating: nil, count: 8) }
        else if s.rose("CLK") { r = [and3(s.v("A"), s.v("B"))] + Array(r.prefix(7)) }
        s.regs["r"] = r
        for (i, l) in ["A", "B", "C", "D", "E", "F", "G", "H"].enumerated() { s.o("Q" + l, r[i]) }
    }

    private static let m74165: Step = { s in
        var r = s.regs["r"] ?? [Bool?](repeating: nil, count: 8)
        let ld = s.v("SH/LD")
        if ld == false { r = ["A", "B", "C", "D", "E", "F", "G", "H"].map { s.v($0) } }
        else if ld == nil { r = [Bool?](repeating: nil, count: 8) }
        else {
            let edge = (s.rose("CLK") && s.v("CLKINH") == false) || (s.rose("CLKINH") && s.v("CLK") == false)
            if edge { r = [s.v("SER")] + Array(r.prefix(7)) }
        }
        s.regs["r"] = r
        s.o("QH", r[7]); s.o("/QH", not3(r[7]))
    }

    private static let m74193: Step = { s in
        var c = s.int("c")
        if s.v("CLR") == true { c = 0 }
        else if s.v("CLR") == nil { c = nil }
        else if s.v("/LOAD") == false { c = bits([s.v("A"), s.v("B"), s.v("C"), s.v("D")]) }
        else if s.v("/LOAD") == nil { c = nil }
        else if s.rose("UP") && s.v("DOWN") == true { c = c.map { ($0 + 1) % 16 } }
        else if s.rose("DOWN") && s.v("UP") == true { c = c.map { ($0 + 15) % 16 } }
        s.setInt("c", c)
        for (i, qn) in ["QA", "QB", "QC", "QD"].enumerated() { s.o(qn, bit(c, i)) }
        let up = s.v("UP"), dn = s.v("DOWN")
        s.o("/CO", up == true ? true : (up == nil || c == nil ? nil : c! != 15))
        s.o("/BO", dn == true ? true : (dn == nil || c == nil ? nil : c! != 0))
    }

    private static let m74393: Step = { s in
        for k in ["1", "2"] {
            var c = s.int(k)
            let clr = s.v("\(k)CLR")
            if clr == true { c = 0 }
            else if clr == nil { c = nil }
            else if s.fell("\(k)A") { c = c.map { ($0 + 1) % 16 } }
            s.setInt(k, c)
            for (i, l) in ["A", "B", "C", "D"].enumerated() { s.o("\(k)Q\(l)", bit(c, i)) }
        }
    }

    private static let m7490: Step = { s in
        var qa = s.flag("a"), qbd = s.int("b")
        let r0 = and3(s.v("R0(1)"), s.v("R0(2)")), r9 = and3(s.v("R9(1)"), s.v("R9(2)"))
        if r9 == true { qa = true; qbd = 4 }
        else if r0 == true && r9 == false { qa = false; qbd = 0 }
        else if r0 == nil || r9 == nil { qa = nil; qbd = nil }
        else {
            if s.fell("CKA") { qa = not3(qa) }
            if s.fell("CKB") { qbd = qbd.map { ($0 + 1) % 5 } }
        }
        s.setFlag("a", qa); s.setInt("b", qbd)
        s.o("QA", qa)
        for (i, qn) in ["QB", "QC", "QD"].enumerated() { s.o(qn, bit(qbd, i)) }
    }

    private static let m7493: Step = { s in
        var qa = s.flag("a"), qb = s.int("b")
        let r0 = and3(s.v("R0(1)"), s.v("R0(2)"))
        if r0 == true { qa = false; qb = 0 }
        else if r0 == nil { qa = nil; qb = nil }
        else {
            if s.fell("CKA") { qa = not3(qa) }
            if s.fell("CKB") { qb = qb.map { ($0 + 1) % 8 } }
        }
        s.setFlag("a", qa); s.setInt("b", qb)
        s.o("QA", qa)
        for (i, qn) in ["QB", "QC", "QD"].enumerated() { s.o(qn, bit(qb, i)) }
    }

    private static let m74595: Step = { s in
        var sh = s.regs["s"] ?? [Bool?](repeating: nil, count: 8)
        var stg = s.regs["t"] ?? [Bool?](repeating: nil, count: 8)
        if s.rose("RCLK") { stg = sh }
        if s.v("/SRCLR") == false { sh = [Bool?](repeating: false, count: 8) }
        else if s.v("/SRCLR") == nil { sh = [Bool?](repeating: nil, count: 8) }
        else if s.rose("SRCLK") { sh = [s.v("SER")] + Array(sh.prefix(7)) }
        s.regs["s"] = sh; s.regs["t"] = stg
        let en = not3(s.v("/OE"))
        for (i, l) in ["A", "B", "C", "D", "E", "F", "G", "H"].enumerated() { s.o("Q" + l, en == true ? stg[i] : nil) }
        s.o("QH'", sh[7])
    }

    private static let m4013: Step = { s in
        for k in ["1", "2"] {
            let set = s.v("\(k)S"), reset = s.v("\(k)R")
            var q = s.flag(k)
            if set == true && reset == true { s.setFlag(k, nil); s.o("\(k)Q", true); s.o("\(k)/Q", true); continue }
            if set == true { q = true }
            else if reset == true { q = false }
            else if set == nil || reset == nil { q = nil }
            else if s.rose("\(k)CLK") { q = s.v("\(k)D") }
            s.setFlag(k, q)
            s.o("\(k)Q", q); s.o("\(k)/Q", not3(q))
        }
    }

    private static let m4017: Step = { s in
        var c = s.int("c")
        if s.v("RST") == true { c = 0 }
        else if s.v("RST") == nil { c = nil }
        else if (s.rose("CLK") && s.v("/CE") == false) || (s.fell("/CE") && s.v("CLK") == true) { c = c.map { ($0 + 1) % 10 } }
        s.setInt("c", c)
        for n in 0..<10 { s.o("Q\(n)", c.map { $0 == n }) }
        s.o("CO", c.map { $0 < 5 })
    }

    private static let m4040: Step = { s in
        var c = s.int("c")
        if s.v("RST") == true { c = 0 }
        else if s.v("RST") == nil { c = nil }
        else if s.fell("CLK") { c = c.map { ($0 + 1) % 4096 } }
        s.setInt("c", c)
        for i in 0..<12 { s.o("Q\(i + 1)", bit(c, i)) }
    }

    // MARK: Registry

    static func model(for chip: String, names: [String]) -> Model? {
        if let op = gateOps[chip] { return Model(step: gates(names, op)) }
        let counterRest: [(String, Bool)] = [("/CLR", true), ("/LOAD", true), ("ENP", true), ("ENT", true)]
        switch chip {
        case "74125": return Model(step: tristateBuffers(activeLow: true))
        case "74126": return Model(step: tristateBuffers(activeLow: false))
        case "74138": return Model(step: m74138)
        case "74139": return Model(step: m74139)
        case "74151": return Model(step: m74151)
        case "74153": return Model(step: m74153)
        case "74157": return Model(step: m74157)
        case "7483": return Model(step: m7483)
        case "7485": return Model(step: m7485)
        case "74240": return Model(step: buffers(inverting: true, enables: [["1/G"], ["2/G"]], pairs: pairs240))
        case "74244": return Model(step: buffers(inverting: false, enables: [["1/G"], ["2/G"]], pairs: pairs240))
        case "74541": return Model(step: buffers(inverting: false, enables: [["/G1", "/G2"]], pairs: pairs541))
        case "74245": return Model(step: m74245)
        case "7474": return Model(step: m7474, sequential: true, rest: [("1/PRE", true), ("1/CLR", true), ("2/PRE", true), ("2/CLR", true)], clocks: ["1CLK", "2CLK"])
        case "74174": return Model(step: dRegister(6, clock: "CLK", clear: "/CLR", q: { "\($0 + 1)Q" }, d: { "\($0 + 1)D" }), sequential: true, rest: [("/CLR", true)], clocks: ["CLK"])
        case "74175": return Model(step: dRegister(4, clock: "CLK", clear: "/CLR", q: { "\($0 + 1)Q" }, d: { "\($0 + 1)D" }, notQ: { "\($0 + 1)/Q" }), sequential: true, rest: [("/CLR", true)], clocks: ["CLK"])
        case "74273": return Model(step: dRegister(8, clock: "CLK", clear: "/CLR", q: { "\($0 + 1)Q" }, d: { "\($0 + 1)D" }), sequential: true, rest: [("/CLR", true)], clocks: ["CLK"])
        case "74374": return Model(step: dRegister(8, clock: "CLK", clear: nil, q: { "\($0 + 1)Q" }, d: { "\($0 + 1)D" }, oe: "/OE"), sequential: true, rest: [("/OE", false)], clocks: ["CLK"])
        case "74574": return Model(step: dRegister(8, clock: "CLK", clear: nil, q: { "Q\($0 + 1)" }, d: { "D\($0 + 1)" }, oe: "/OE"), sequential: true, rest: [("/OE", false)], clocks: ["CLK"])
        case "74373": return Model(step: dRegister(8, clock: nil, clear: nil, q: { "\($0 + 1)Q" }, d: { "\($0 + 1)D" }, oe: "/OE", latch: "LE"), sequential: true, rest: [("/OE", false), ("LE", false)])
        case "74573": return Model(step: dRegister(8, clock: nil, clear: nil, q: { "Q\($0 + 1)" }, d: { "D\($0 + 1)" }, oe: "/OE", latch: "LE"), sequential: true, rest: [("/OE", false), ("LE", false)])
        case "74161": return Model(step: syncCounter(modulus: 16, asyncClear: true), sequential: true, rest: counterRest, clocks: ["CLK"], full: 20)
        case "74163": return Model(step: syncCounter(modulus: 16, asyncClear: false), sequential: true, rest: counterRest, clocks: ["CLK"], full: 20)
        case "74160": return Model(step: syncCounter(modulus: 10, asyncClear: true), sequential: true, rest: counterRest, clocks: ["CLK"], full: 14)
        case "74162": return Model(step: syncCounter(modulus: 10, asyncClear: false), sequential: true, rest: counterRest, clocks: ["CLK"], full: 14)
        case "74164": return Model(step: m74164, sequential: true, rest: [("/CLR", true)], clocks: ["CLK"], full: 12)
        case "74165": return Model(step: m74165, sequential: true, rest: [("SH/LD", true), ("CLKINH", false)], clocks: ["CLK"], full: 12)
        case "74193": return Model(step: m74193, sequential: true, rest: [("CLR", false), ("/LOAD", true), ("UP", true), ("DOWN", true)], clocks: ["UP", "DOWN"], full: 20)
        case "74393": return Model(step: m74393, sequential: true, rest: [("1CLR", false), ("2CLR", false)], clocks: ["1A", "2A"], full: 20)
        case "7490": return Model(step: m7490, sequential: true, rest: [("R0(1)", false), ("R0(2)", false), ("R9(1)", false), ("R9(2)", false)], clocks: ["CKA", "CKB"], full: 12)
        case "7493": return Model(step: m7493, sequential: true, rest: [("R0(1)", false), ("R0(2)", false)], clocks: ["CKA", "CKB"], full: 12)
        case "74595": return Model(step: m74595, sequential: true, rest: [("/SRCLR", true), ("/OE", false)], clocks: ["SRCLK", "RCLK"], full: 12)
        case "4013": return Model(step: m4013, sequential: true, rest: [("1S", false), ("1R", false), ("2S", false), ("2R", false)], clocks: ["1CLK", "2CLK"])
        case "4017": return Model(step: m4017, sequential: true, rest: [("RST", false), ("/CE", false)], clocks: ["CLK"], full: 24)
        case "4040": return Model(step: m4040, sequential: true, rest: [("RST", false)], clocks: ["CLK"], full: 4100)
        default: return nil
        }
    }

    // MARK: Running vectors through a model

    /// The model's output for every vector, the way minipro applies it: all pins set, then each "C" pin
    /// pulsed high and low again; clock pins start low and keep their last level.
    static func simulate(_ model: Model, names: [String], vectors: [[Character]]) -> [[Int: Bool]] {
        let s = LogicSim(names: names)
        var level = [Bool](repeating: false, count: names.count)
        var results: [[Int: Bool]] = []
        for vec in vectors {
            var stage0: [Bool?] = []
            var clockPins: [Int] = []
            for (i, c) in vec.enumerated() {
                switch c {
                case "0": stage0.append(false)
                case "1": stage0.append(true)
                case "C": stage0.append(level[i]); clockPins.append(i)
                default: stage0.append(nil)
                }
            }
            while stage0.count < names.count { stage0.append(nil) }
            var stages = [stage0]
            if !clockPins.isEmpty {
                var s1 = stage0, s2 = stage0
                for i in clockPins { s1[i] = true; s2[i] = false }
                stages += [s1, s2]
            }
            for st in stages {
                s.prev = s.cur
                s.cur = st
                s.out = []
                model.step(s)
            }
            for (i, c) in vec.enumerated() {
                if c == "0" || c == "1" { level[i] = c == "1" } else if c == "C" { level[i] = false }
            }
            var r: [Int: Bool] = [:]
            for (n, value) in s.out { if let i = s.idx(n), let b = value { r[i] = b } }
            results.append(r)
        }
        return results
    }

    // MARK: Generating the extended vectors

    struct Extended {
        let vectors: [[Character]]
        let checks: Int
        let description: String
        /// Named parts of the sequence (vector index ranges), for reporting where a failure happened.
        let phases: [(name: String, range: Range<Int>)]

        func phase(ofVector i: Int) -> String { phases.first { $0.range.contains(i) }?.name ?? "step \(i)" }
    }

    private struct LCG {
        var x: UInt64
        mutating func next() -> UInt64 { x = x &* 6364136223846793005 &+ 1442695040888963407; return x >> 33 }
        mutating func chance(_ p: Double) -> Bool { Double(next() % 1000) < p * 1000 }
    }

    /// The pins of a logic chip as the models see them: the model key (e.g. "74161"), the data-sheet pin
    /// names and roles (i, o, b, g, v, n). Group members that share minipro's vectors share the model.
    static func pins(for chip: String, xml: String) -> (key: String, names: [String], roles: [Character])? {
        guard let v = Pinouts.logicVectors(xml: xml, name: chip) else { return nil }
        let members = [chip] + v.group.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        for m in members {
            let base = Pinouts.logicBase(m)
            let key = Pinouts.logicNames[base] != nil ? base : m
            guard let entry = Pinouts.logicNames[key] else { continue }
            let items = entry.pins.split(separator: " ")
            guard items.count == v.pins else { continue }
            let names = items.map { String($0.split(separator: ":", maxSplits: 1).last ?? "") }
            let roles = items.map { $0.first ?? "i" }
            if model(for: key, names: names) != nil { return (key, names, roles) }
        }
        return nil
    }

    /// - Parameters: chip – the model key (e.g. "74161"); names / roles – the pin names and roles (i, o, b, g, v, n).
    static func extended(chip: String, names: [String], roles: [Character]) -> Extended? {
        guard let model = LogicModels.model(for: chip, names: names), names.count == roles.count else { return nil }
        let base: [Character] = roles.map { $0 == "g" ? "G" : $0 == "v" ? "V" : "X" }
        let inputs = roles.indices.filter { roles[$0] == "i" }
        var vecs: [[Character]] = []
        var phases: [(name: String, range: Range<Int>)] = []
        func phase(_ name: String, _ body: () -> Void) {
            let start = vecs.count
            body()
            if vecs.count > start { phases.append((name, start..<vecs.count)) }
        }
        var description = ""
        if chip == "74245" {
            func mk(_ dir: Character, _ side: String, _ value: Int) -> [Character] {
                var v = base
                if let i = names.firstIndex(of: "DIR") { v[i] = dir }
                if let i = names.firstIndex(of: "/OE") { v[i] = "0" }
                for k in 0..<8 { if let i = names.firstIndex(of: "\(side)\(k + 1)") { v[i] = (value >> k) & 1 == 1 ? "1" : "0" } }
                return v
            }
            phase("A→B, all 256 patterns") { for value in 0..<256 { vecs.append(mk("1", "A", value)) } }
            phase("B→A, all 256 patterns") { for value in 0..<256 { vecs.append(mk("0", "B", value)) } }
            description = "all 256 patterns A→B and all 256 B→A (neighbour-pin patterns included)"
        } else if !model.sequential {
            guard inputs.count <= 12 else { return nil }
            phase("input combinations") {
                for k in 0..<(1 << inputs.count) {
                    var v = base
                    for (j, i) in inputs.enumerated() { v[i] = (k >> j) & 1 == 1 ? "1" : "0" }
                    vecs.append(v)
                }
            }
            description = "every one of the \(1 << inputs.count) input combinations (neighbour-pin patterns included)"
        } else {
            let rest = model.rest, clocks = model.clocks
            let restDict = Dictionary(rest, uniquingKeysWith: { a, _ in a })
            var rng = LCG(x: 0x5EED ^ UInt64(chip.unicodeScalars.reduce(0) { $0 + Int($1.value) }))
            func vec(_ over: [(String, Character)] = [], clock: String? = nil, random: Bool = false) -> [Character] {
                var v = base
                for i in inputs {
                    let nm = names[i]
                    if clocks.contains(nm) { v[i] = nm == clock ? "C" : ((restDict[nm] ?? false) ? "1" : "0") }
                    else if let r = restDict[nm] { v[i] = r ? "1" : "0" }
                    else { v[i] = random ? (rng.chance(0.5) ? "1" : "0") : "0" }
                }
                for (nm, val) in over { if let i = names.firstIndex(of: nm) { v[i] = val } }
                return v
            }
            // 1. each control once away from its resting level (resets, loads, enables)
            phase("resets and controls") {
                for (nm, val) in rest {
                    vecs.append(vec([(nm, val ? "0" : "1")], random: true))
                    vecs.append(vec(random: true))
                }
                for c in clocks { vecs.append(vec(clock: c, random: true)) }
            }
            // 2. full cycle: the clock(s) pulsed with the controls at rest
            phase("full \(model.full)-pulse cycle") {
                for c in clocks { for _ in 0..<model.full { vecs.append(vec(clock: c, random: true)) } }
            }
            // 3. neighbour-pin patterns over every input: two checkerboards, walking one, walking zero
            phase("neighbour-pin patterns") {
                func pat(_ f: (Int) -> Bool) -> [Character] {
                    var v = base
                    for i in inputs { v[i] = f(i) ? "1" : "0" }
                    return v
                }
                vecs.append(pat { $0 % 2 == 0 })
                vecs.append(pat { $0 % 2 == 1 })
                for k in inputs { vecs.append(pat { $0 == k }) }
                for k in inputs { vecs.append(pat { $0 != k }) }
            }
            // 4. random steps: random data, controls now and then, at most one clock per step
            phase("random steps") {
                for _ in 0..<512 {
                    var over: [(String, Character)] = []
                    for (nm, val) in rest where rng.chance(0.08) { over.append((nm, val ? "0" : "1")) }
                    var clk: String?
                    if !clocks.isEmpty && rng.chance(0.6) { clk = clocks[Int(rng.next() % UInt64(clocks.count))] }
                    if chip == "74373" || chip == "74573", rng.chance(0.3) { over.append(("LE", "1")) }
                    vecs.append(vec(over, clock: clk, random: true))
                }
            }
            var parts = ["resets and controls"]
            if model.full > 0 { parts.append("a full \(model.full)-pulse cycle") }
            parts += ["neighbour-pin patterns", "512 random steps"]
            description = parts.joined(separator: ", ")
        }
        let res = simulate(model, names: names, vectors: vecs)
        var out: [[Character]] = []
        var checks = 0
        for (v, r) in zip(vecs, res) {
            var w = v
            for (i, value) in r where (roles[i] == "o" || roles[i] == "b") && w[i] == "X" {
                w[i] = value ? "H" : "L"
                checks += 1
            }
            out.append(w)
        }
        return Extended(vectors: out, checks: checks, description: description, phases: phases)
    }

    /// FNV-1a over the vectors, for the build's comparison with the reference generator.
    static func fingerprint(_ vectors: [[Character]]) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for v in vectors {
            for c in String(v).utf8 { h = (h ^ UInt64(c)) &* 0x100000001b3 }
            h = (h ^ 10) &* 0x100000001b3
        }
        return h
    }
}
