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
print("galtest assemble: \(asmPassed) passed, \(asmFailed) failed; errors: \(errPassed) passed, \(errFailed) failed")
let allOK = failed == 0 && passed > 0 && asmFailed == 0 && asmPassed > 0 && errFailed == 0 && errPassed > 0
print(allOK ? "GALTEST OK" : "GALTEST FAILED")
exit(allOK ? 0 : 1)
