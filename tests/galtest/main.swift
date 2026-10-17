import Foundation

// Checks GalDecoder against Galette's test cases: each .jed was assembled by Galette from the
// .pld next to it, so decoding the .jed must give back the .pld's equations.
// Usage: galtest <directory with .pld/.jed pairs>

guard CommandLine.arguments.count >= 2 else { print("usage: galtest dir"); exit(2) }
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []

struct Expected {
    var kind: GalOutput.Kind = .combinatorial
    var activeHigh = true
    var term: GalSum?
    var enable: GalSum?
    var clock: GalSum?
    var reset: GalSum?
    var preset: GalSum?
}

/// Minimal galasm/Galette .pld reader: chip, signature, pin names, equations up to DESCRIPTION.
func parsePLD(_ text: String) -> (chip: String, names: [String], eqs: [Int: Expected], ar: GalSum?, sp: GalSum?)? {
    let lines = text.components(separatedBy: .newlines).map { l -> String in
        if let i = l.firstIndex(of: ";") { return String(l[..<i]) }
        return l
    }
    var meaningful = lines.map { $0.trimmingCharacters(in: .whitespaces) }
    if let d = meaningful.firstIndex(where: { $0.hasPrefix("DESCRIPTION") }) { meaningful = Array(meaningful[..<d]) }
    meaningful = meaningful.filter { !$0.isEmpty }
    guard meaningful.count > 2 else { return nil }
    let chip = meaningful[0].components(separatedBy: .whitespaces)[0]
    let pins = chip == "GAL16V8" ? 20 : 24
    var tokens: [String] = []
    for l in meaningful.dropFirst(2) {
        var cur = ""
        for ch in l {
            if ch == "=" || ch == "+" || ch == "*" || ch == "#" || ch == "&" {
                if !cur.isEmpty { tokens.append(cur); cur = "" }
                tokens.append(ch == "#" ? "+" : ch == "&" ? "*" : String(ch))
            } else if ch.isWhitespace {
                if !cur.isEmpty { tokens.append(cur); cur = "" }
            } else { cur.append(ch) }
        }
        if !cur.isEmpty { tokens.append(cur) }
    }
    guard tokens.count >= pins else { return nil }
    let names = Array(tokens[0..<pins])
    var pinOf: [String: (Int, Bool)] = [:]
    for (i, n) in names.enumerated() {
        let neg = n.hasPrefix("/")
        pinOf[neg ? String(n.dropFirst()) : n] = (i + 1, neg)
    }
    var eqs: [Int: Expected] = [:]
    var ar: GalSum?, sp: GalSum?
    var i = pins
    while i + 1 < tokens.count {
        let lhs = tokens[i]
        guard tokens[i + 1] == "=" else { print("  parse error near \(lhs)"); return nil }
        i += 2
        var rows: [[GalLiteral]] = [[]]
        var constant: Bool?
        while i < tokens.count {
            let t = tokens[i]
            if t == "VCC" { constant = true } else if t == "GND" { constant = false } else {
                let neg = t.hasPrefix("/")
                let name = neg ? String(t.dropFirst()) : t
                guard let (pin, pinNeg) = pinOf[name] else { print("  unknown name \(name)"); return nil }
                rows[rows.count - 1].append(GalLiteral(pin: pin, negated: neg != pinNeg))
            }
            i += 1
            if i < tokens.count && tokens[i] == "*" { i += 1; continue }
            if i < tokens.count && tokens[i] == "+" { rows.append([]); i += 1; continue }
            break
        }
        let sum: GalSum = constant == true ? GalSum(rows: [[]]) : constant == false ? GalSum(rows: []) : GalSum(rows: rows)
        if lhs == "AR" { ar = sum; continue }
        if lhs == "SP" { sp = sum; continue }
        let lneg = lhs.hasPrefix("/")
        let parts = (lneg ? String(lhs.dropFirst()) : lhs).components(separatedBy: ".")
        guard let (pin, pinNeg) = pinOf[parts[0]] else { print("  unknown output \(lhs)"); return nil }
        var e = eqs[pin] ?? Expected()
        let ext = parts.count > 1 ? parts[1] : ""
        switch ext {
        case "E": e.enable = sum.isTrue ? nil : sum
        case "CLK": e.clock = sum
        case "ARST": e.reset = sum.isFalse ? nil : sum
        case "APRST": e.preset = sum.isFalse ? nil : sum
        case "R": e.kind = .registered; e.term = sum; e.activeHigh = lneg == pinNeg
        default: e.kind = .combinatorial; e.term = sum; e.activeHigh = lneg == pinNeg
        }
        eqs[pin] = e
    }
    return (chip, names, eqs, ar, sp)
}

var failed = 0, passed = 0
for pld in files.filter({ $0.hasSuffix(".pld") }).sorted() {
    let base = String(pld.dropLast(4))
    guard let src = try? String(contentsOf: dir.appendingPathComponent(pld)),
          let jedText = try? String(contentsOf: dir.appendingPathComponent(base + ".jed")) else { continue }
    guard let p = parsePLD(src) else { print("FAIL \(base): can't parse .pld"); failed += 1; continue }
    var problems: [String] = []
    do {
        let jed = try JEDECFile.parse(jedText)
        if jed.checksum != jed.computedChecksum { problems.append("fuse checksum mismatch") }
        let d = try GalDecoder.decode(jed)
        if d.chip.rawValue != p.chip { problems.append("chip \(d.chip.rawValue) != \(p.chip)") }
        var names: [Int: String] = [:]
        for (i, n) in p.names.enumerated() { names[i + 1] = n.hasPrefix("/") ? String(n.dropFirst()) : n }
        let decodedPins = Set(d.outputs.map { $0.pin })
        if decodedPins != Set(p.eqs.keys) { problems.append("outputs \(decodedPins.sorted()) != \(p.eqs.keys.sorted())") }
        for o in d.outputs {
            guard let e = p.eqs[o.pin] else { continue }
            let n = names[o.pin] ?? "\(o.pin)"
            if o.kind != e.kind { problems.append("\(n): kind \(o.kind) != \(e.kind)") }
            if o.activeHigh != e.activeHigh { problems.append("\(n): polarity") }
            if let t = e.term, o.term.normalized != t.normalized {
                problems.append("\(n): term \(d.expression(o.term, names, indent: 0)) != \(d.expression(t, names, indent: 0))")
            }
            if o.enable?.normalized != e.enable?.normalized { problems.append("\(n): enable differs") }
            if o.kind == .registered && p.chip == "GAL20RA10" {
                if o.clock?.normalized != (e.clock ?? GalSum(rows: [])).normalized { problems.append("\(n): clock differs") }
                if o.reset?.normalized != e.reset?.normalized { problems.append("\(n): reset differs") }
                if o.preset?.normalized != e.preset?.normalized { problems.append("\(n): preset differs") }
            }
        }
        if d.asyncReset?.normalized != p.ar?.normalized { problems.append("AR differs") }
        if d.syncPreset?.normalized != p.sp?.normalized { problems.append("SP differs") }
        if !problems.isEmpty { print(d.equations(names: names)) }
    } catch {
        problems.append("\(error)")
    }
    if problems.isEmpty { passed += 1; print("ok   \(base)") }
    else { failed += 1; print("FAIL \(base): " + problems.joined(separator: "; ")) }
}
print("galtest decode: \(passed) passed, \(failed) failed")

// Assembler: every .pld must give Galette's .jed byte for byte (with Galette's header line).
var asmPassed = 0, asmFailed = 0
func compareJED(_ name: String, _ src: String, _ golden: String, security: Bool) {
    do {
        let r = try GalAssembler.assemble(src, securityBit: security, assembler: "Galette 0.3.0")
        if r.jedec == golden { asmPassed += 1; print("ok   assemble \(name)") }
        else {
            asmFailed += 1
            print("FAIL assemble \(name): output differs")
            let a = r.jedec.components(separatedBy: "\n"), b = golden.components(separatedBy: "\n")
            for i in 0..<max(a.count, b.count) where (i < a.count ? a[i] : "<none>") != (i < b.count ? b[i] : "<none>") {
                print("  line \(i + 1): got  \(i < a.count ? a[i] : "<none>")")
                print("  line \(i + 1): want \(i < b.count ? b[i] : "<none>")")
            }
        }
    } catch {
        asmFailed += 1
        print("FAIL assemble \(name): \(error)")
    }
}
for pld in files.filter({ $0.hasSuffix(".pld") }).sorted() {
    let base = String(pld.dropLast(4))
    guard let src = try? String(contentsOf: dir.appendingPathComponent(pld)),
          let golden = try? String(contentsOf: dir.appendingPathComponent(base + ".jed")) else { continue }
    compareJED(base, src, golden, security: false)
}
let root = dir.deletingLastPathComponent()
if let src = try? String(contentsOf: root.appendingPathComponent("security/security_bit.pld")),
   let golden = try? String(contentsOf: root.appendingPathComponent("security/security_bit.jed")) {
    compareJED("security_bit (security fuse set)", src, golden, security: true)
} else { asmFailed += 1; print("FAIL security test files missing") }

// Assembler errors: Galette's failing sources must give the same messages.
var errPassed = 0, errFailed = 0
let failDir = root.appendingPathComponent("failure")
if let table = try? String(contentsOf: failDir.appendingPathComponent("expected.tsv")) {
    for line in table.components(separatedBy: "\n") where line.contains("\t") {
        let parts = line.components(separatedBy: "\t")
        let name = parts[0], want = parts[1]
        guard let src = try? String(contentsOf: failDir.appendingPathComponent(name)) else { errFailed += 1; print("FAIL missing \(name)"); continue }
        do {
            _ = try GalAssembler.assemble(src)
            errFailed += 1; print("FAIL error \(name): assembled, expected \"\(want)\"")
        } catch {
            let got = "\(error)"
            if got == want { errPassed += 1 } else { errFailed += 1; print("FAIL error \(name):\n  got  \(got)\n  want \(want)") }
        }
    }
} else { errFailed += 1; print("FAIL expected.tsv missing") }
for chip in [GalAssembler.Chip.gal16v8, .gal20v8, .gal22v10, .gal20ra10] {
    do {
        let r = try GalAssembler.assemble(GalAssembler.template(for: chip))
        let d = try GalDecoder.decode(try JEDECFile.parse(r.jedec))
        if d.chip.rawValue == chip.rawValue && !d.outputs.isEmpty { asmPassed += 1; print("ok   template \(chip.rawValue) assembles and decodes (\(d.outputs.count) outputs)") }
        else { asmFailed += 1; print("FAIL template \(chip.rawValue): decoded as \(d.chip.rawValue) with \(d.outputs.count) outputs") }
    } catch { asmFailed += 1; print("FAIL template \(chip.rawValue): \(error)") }
}
// GAL functional test vectors: every H/L/Z the generator expects must agree with the PLD source's
// own equations (evaluated independently of the decoder) for the combinatorial test cases.
var vecPassed = 0, vecFailed = 0
for pld in files.filter({ $0.hasSuffix(".pld") }).sorted() {
    let base = String(pld.dropLast(4))
    guard let src = try? String(contentsOf: dir.appendingPathComponent(pld)),
          let jedText = try? String(contentsOf: dir.appendingPathComponent(base + ".jed")),
          let p = parsePLD(src), let d = try? GalDecoder.decode(try JEDECFile.parse(jedText)) else { continue }
    let g = GalTestGenerator.generate(d)
    var problems = g.test.problems()
    let registered = p.eqs.values.contains { $0.kind == .registered }
    if registered && p.chip != "GAL20RA10" {
        if !g.test.vectors.allSatisfy({ $0[0] == "C" }) { problems.append("registered design without clock pulses on pin 1") }
        if g.checkedOutputs.isEmpty { problems.append("no registered output ever becomes known") }
    }
    var checks = 0
    for v in g.test.vectors where !registered {
        func pinValue(_ pin: Int) -> Bool? {
            switch v[pin - 1] { case "0", "L": return false; case "1", "H": return true; default: return nil }
        }
        func evalSum(_ s: GalSum) -> Bool? {
            if s.isTrue { return true }
            var any = false
            for row in s.rows {
                var r = true
                for l in row { guard let x = pinValue(l.pin) else { return nil }; r = r && (l.negated ? !x : x) }
                any = any || r
            }
            return any
        }
        for (pin, e) in p.eqs {
            guard let t = e.term else { continue }
            let ch = v[pin - 1]
            if let en = e.enable, let env = evalSum(en), !env {
                if ch != "Z" && ch != "X" { problems.append("pin \(pin) expected Z, vector has \(ch)") }
                checks += 1; continue
            }
            guard ch == "H" || ch == "L", let tv = evalSum(t) else { continue }
            let want: Character = (e.activeHigh ? tv : !tv) ? "H" : "L"
            if ch != want { problems.append("pin \(pin): vector has \(ch), the source gives \(want)"); break }
            checks += 1
        }
    }
    // Registers whose next value depends only on input pins: after the clock pulse in a vector,
    // the output must equal the source equation applied to that vector's inputs.
    if registered && p.chip != "GAL20RA10" && p.ar == nil && p.sp == nil {
        let outPins = Set(p.eqs.keys)
        for v in g.test.vectors {
            for (pin, e) in p.eqs where e.kind == .registered {
                guard let t = e.term, !t.rows.joined().contains(where: { outPins.contains($0.pin) }) else { continue }
                var known = true
                func pv(_ q: Int) -> Bool { switch v[q - 1] { case "1": return true; case "0": return false; default: known = false; return false } }
                let tv = t.isTrue || t.rows.contains { row in row.allSatisfy { l in pv(l.pin) != l.negated } }
                guard known else { continue }
                let want: Character = (e.activeHigh ? tv : !tv) ? "H" : "L"
                if v[pin - 1] != want { problems.append("registered pin \(pin): vector has \(v[pin - 1]), the source gives \(want)"); break }
                checks += 1
            }
        }
    }
    if checks == 0 && !(registered && (p.chip == "GAL20RA10" || p.ar != nil || p.sp != nil || p.eqs.values.allSatisfy { $0.kind != .registered || ($0.term?.rows.joined().contains { Set(p.eqs.keys).contains($0.pin) } ?? true) })) {
        problems.append("no output was checked")
    }
    if problems.isEmpty { vecPassed += 1; print("ok   GAL test vectors \(base): \(g.test.vectors.count) vectors, \(checks) output checks against the source") }
    else { vecFailed += 1; print("FAIL GAL test vectors \(base): " + problems.prefix(4).joined(separator: "; ")) }
}
// Vector file round trip and minipro result parsing.
let lt = LogicTest(name: "My 7400", pins: 14, voltage: "5V", vectors: [Array("00H00HGH00H00V"), Array("11L11LGL11L11V")])
let back = LogicTest.parseXML(lt.xml())
if back?.vectors == lt.vectors && back?.pins == 14 && back?.name == "MY_7400" && lt.problems().isEmpty { vecPassed += 1; print("ok   logicic.xml round trip") }
else { vecFailed += 1; print("FAIL logicic.xml round trip") }
let sample = "      1  2  3  \n0000: 0  0  H  \n0001: 1  1  L- \nLogic test failed: 1 errors encountered."
let pr = LogicTest.parseResult(sample)
if pr.failingVectors == [1] && pr.errors == 1 && !pr.passed { vecPassed += 1; print("ok   logic test result parsing") }
else { vecFailed += 1; print("FAIL logic test result parsing: \(pr.failingVectors) \(pr.errors)") }
if !LogicTest(name: "x", pins: 14, voltage: "5V", vectors: [Array("00H00H0H00H00V")]).problems().isEmpty { vecPassed += 1; print("ok   a vector without ground is rejected") }
else { vecFailed += 1; print("FAIL a vector without ground was accepted") }
// PAL readout → GAL clone, with simulated PALs.
func simulatedTable(_ t: PalReadout.PalType, terms: [[PalReadout.Cube]], activeLow: Bool) -> [UInt16] {
    (0..<(1 << t.inputs.count)).map { k in
        var bits: UInt16 = 0
        for (i, cubes) in terms.enumerated() {
            var v = cubes.contains { k & $0.mask == $0.value & $0.mask }
            if activeLow { v = !v }
            if v { bits |= 1 << UInt16(i) }
        }
        return bits
    }
}
var rng: UInt64 = 0xC0FFEE
func rand(_ n: Int) -> Int { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Int((rng >> 33) % UInt64(n)) }
func randomTerms(_ t: PalReadout.PalType, perOutput: Int) -> [[PalReadout.Cube]] {
    t.outputs.map { _ in (0..<perOutput).map { _ in
        var mask = 0
        for _ in 0..<(2 + rand(3)) { mask |= 1 << rand(t.inputs.count) }
        return PalReadout.Cube(mask: mask, value: rand(1 << t.inputs.count))
    } }
}
for (t, low, per) in [(PalReadout.types[0], false, 2), (PalReadout.types[0], true, 2), (PalReadout.types[1], false, 4), (PalReadout.types[3], false, 7)] {
    let table = simulatedTable(t, terms: randomTerms(t, perOutput: per), activeLow: low)
    let label = "\(t.name.components(separatedBy: " ").first!)\(low ? " (active-low)" : "")"
    do {
        let c = try PalReadout.makeClone(t, table: table, palName: label)
        vecPassed += 1; print("ok   PAL clone \(label): GAL16V8 reproduces all \(table.count) rows (\(c.equations.count) outputs)")
    } catch { vecFailed += 1; print("FAIL PAL clone \(label): \(error)") }
}
let palOut = "      1  2  3  4  5  6  7  8  9  10 11 12 13 14 15 16 17 18 19 20\n" +
    "0000: 0  0  0  0  0  0  0  0  0  G  0  L  L- L  L  L  L  L  L- V  \n" +
    "0001: 1  0  0  0  0  0  0  0  0  G  0  L- L  L  L  L  L  L  L  V  \n" +
    "Logic test failed: 3 errors encountered."
let parsed = PalReadout.parseTable(palOut, type: PalReadout.types[0], expected: 2)
if parsed == [0b1000_0010, 0b0000_0001] { vecPassed += 1; print("ok   PAL readout table parsing") }
else { vecFailed += 1; print("FAIL PAL readout table parsing: \(String(describing: parsed))") }
let pv = PalReadout.vectors(PalReadout.types[0], range: 5..<6)[0]
if String(pv) == "101000000G0LLLLLLLLV" { vecPassed += 1; print("ok   PAL readout vectors") }
else { vecFailed += 1; print("FAIL PAL readout vectors: \(String(pv))") }
print("galtest vectors: \(vecPassed) passed, \(vecFailed) failed")
print("galtest assemble: \(asmPassed) passed, \(asmFailed) failed; errors: \(errPassed) passed, \(errFailed) failed")
let allOK = failed == 0 && passed > 0 && asmFailed == 0 && asmPassed > 0 && errFailed == 0 && errPassed > 0 && vecFailed == 0 && vecPassed > 0
print(allOK ? "GALTEST OK" : "GALTEST FAILED")
exit(allOK ? 0 : 1)
