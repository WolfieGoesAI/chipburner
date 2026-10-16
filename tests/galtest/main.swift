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
        case "R": e.kind = .registered; e.term = sum; e.activeHigh = lneg == pinNeg
        default: e.kind = .combinatorial; e.term = sum; e.activeHigh = lneg == pinNeg
        }
        eqs[pin] = e
    }
    return (chip, names, eqs, ar, sp)
}

var failed = 0, passed = 0, skipped = 0
for pld in files.filter({ $0.hasSuffix(".pld") }).sorted() {
    let base = String(pld.dropLast(4))
    guard let src = try? String(contentsOf: dir.appendingPathComponent(pld)),
          let jedText = try? String(contentsOf: dir.appendingPathComponent(base + ".jed")) else { continue }
    guard let p = parsePLD(src) else { print("FAIL \(base): can't parse .pld"); failed += 1; continue }
    if p.chip == "GAL20RA10" { skipped += 1; continue }
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
print("galtest: \(passed) passed, \(failed) failed, \(skipped) skipped (GAL20RA10)")
exit(failed == 0 && passed > 0 ? 0 : 1)
