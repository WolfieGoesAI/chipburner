import Foundation

// Assembles galasm-style PLD source into a JEDEC fuse map for GAL16V8, GAL20V8, GAL22V10 and GAL20RA10.
//
// A Swift port of Galette (https://github.com/simon-frankau/galette, MIT licence, © 2019 Simon Frankau),
// itself a rewrite of galasm. The build checks that it produces Galette's .jed files byte for byte
// and the same error messages for Galette's failing test sources (tests/gal).

enum GalAssembler {

    // MARK: Errors

    struct AsmError: Error, CustomStringConvertible {
        var line: Int
        var message: String
        var description: String { "Error in line \(line): \(message)" }
    }

    private static let eofLine = 0   // replaced with the file's line count

    private static func fail<T>(_ line: Int, _ msg: String) throws -> T { throw AsmError(line: line, message: msg) }

    // MARK: Chips

    enum Chip: String {
        case gal16v8 = "GAL16V8", gal20v8 = "GAL20V8", gal22v10 = "GAL22V10", gal20ra10 = "GAL20RA10"

        var numPins: Int { self == .gal16v8 ? 20 : 24 }
        var numRows: Int { [.gal16v8: 64, .gal20v8: 64, .gal22v10: 132, .gal20ra10: 80][self]! }
        var numCols: Int { [.gal16v8: 32, .gal20v8: 40, .gal22v10: 44, .gal20ra10: 40][self]! }
        var totalSize: Int { [.gal16v8: 2194, .gal20v8: 2706, .gal22v10: 5892, .gal20ra10: 3274][self]! }
        var minOLMCPin: Int { [.gal16v8: 12, .gal20v8: 15, .gal22v10: 14, .gal20ra10: 14][self]! }
        var maxOLMCPin: Int { [.gal16v8: 19, .gal20v8: 22, .gal22v10: 23, .gal20ra10: 23][self]! }
        var numOLMCs: Int { maxOLMCPin - minOLMCPin + 1 }
        var logicSize: Int { numRows * numCols }

        func pinToOLMC(_ pin: Int) -> Int? { (minOLMCPin...maxOLMCPin).contains(pin) ? pin - minOLMCPin : nil }

        func rowsForOLMC(_ n: Int) -> Int { self == .gal22v10 ? [9, 11, 13, 15, 17, 17, 15, 13, 11, 9][n] : 8 }

        func startRow(_ n: Int) -> Int {
            switch self {
            case .gal16v8, .gal20v8: return [56, 48, 40, 32, 24, 16, 8, 0][n]
            case .gal22v10: return [122, 111, 98, 83, 66, 49, 34, 21, 10, 1][n]
            case .gal20ra10: return [72, 64, 56, 48, 40, 32, 24, 16, 8, 0][n]
            }
        }
    }

    enum Mode { case simple, complex, registered }

    // MARK: Pin → fuse column (Err cases carry the error message)

    private enum Col { case ok(Int), bad(String) }
    private static let BAD = Col.bad("internal error: analyse_mode should never let you use this pin as an input")
    private static let PWR = Col.bad("use of VCC and GND is not allowed in equations")
    private static func regRes(_ pin: Int, _ name: String) -> Col { .bad("pin \(pin) is reserved for '\(name)' in registered mode") }
    private static func cplx(_ pin: Int) -> Col { .bad("pin \(pin) can't be used as input in complex mode") }
    private static func ra10(_ pin: Int, _ name: String) -> Col { .bad("pin \(pin) is reserved for '\(name)' on GAL20RA10 devices and can't be used in equations") }
    private static func c(_ v: Int) -> Col { .ok(v) }

    private static let col16Simple: [Col] = [c(2), c(0), c(4), c(8), c(12), c(16), c(20), c(24), c(28), PWR,
                                             c(30), c(26), c(22), c(18), BAD, BAD, c(14), c(10), c(6), PWR]
    private static let col16Complex: [Col] = [c(2), c(0), c(4), c(8), c(12), c(16), c(20), c(24), c(28), PWR,
                                              c(30), cplx(12), c(26), c(22), c(18), c(14), c(10), c(6), cplx(19), PWR]
    private static let col16Registered: [Col] = [regRes(1, "Clock"), c(0), c(4), c(8), c(12), c(16), c(20), c(24), c(28), PWR,
                                                 regRes(11, "/OE"), c(30), c(26), c(22), c(18), c(14), c(10), c(6), c(2), PWR]
    private static let col20Simple: [Col] = [c(2), c(0), c(4), c(8), c(12), c(16), c(20), c(24), c(28), c(32), c(36), PWR,
                                             c(38), c(34), c(30), c(26), c(22), BAD, BAD, c(18), c(14), c(10), c(6), PWR]
    private static let col20Complex: [Col] = [c(2), c(0), c(4), c(8), c(12), c(16), c(20), c(24), c(28), c(32), c(36), PWR,
                                              c(38), c(34), cplx(15), c(30), c(26), c(22), c(18), c(14), c(10), cplx(22), c(6), PWR]
    private static let col20Registered: [Col] = [regRes(1, "Clock"), c(0), c(4), c(8), c(12), c(16), c(20), c(24), c(28), c(32), c(36), PWR,
                                                 regRes(13, "/OE"), c(38), c(34), c(30), c(26), c(22), c(18), c(14), c(10), c(6), c(2), PWR]
    private static let col22V10: [Col] = [c(0), c(4), c(8), c(12), c(16), c(20), c(24), c(28), c(32), c(36), c(40), PWR,
                                          c(42), c(38), c(34), c(30), c(26), c(22), c(18), c(14), c(10), c(6), c(2), PWR]
    private static let col20RA10: [Col] = [ra10(1, "/PL"), c(0), c(4), c(8), c(12), c(16), c(20), c(24), c(28), c(32), c(36), PWR,
                                           ra10(13, "/OE"), c(38), c(34), c(30), c(26), c(22), c(18), c(14), c(10), c(6), c(2), PWR]

    // MARK: Terms and fuse state

    struct Pin: Equatable { var pin: Int; var neg: Bool }
    struct Term { var line: Int; var rows: [[Pin]] }
    private static func trueTerm(_ line: Int) -> Term { Term(line: line, rows: [[]]) }
    private static func falseTerm(_ line: Int) -> Term { Term(line: line, rows: []) }

    struct Bounds { var startRow: Int; var maxRow: Int; var rowOffset: Int }

    final class GAL {
        let chip: Chip
        var fuses: [Bool]
        var xor: [Bool]
        var sig = [Bool](repeating: false, count: 64)
        var ac1: [Bool]
        var pt = [Bool](repeating: false, count: 64)
        var syn = false
        var ac0 = false

        init(_ chip: Chip) {
            self.chip = chip
            fuses = [Bool](repeating: true, count: chip.logicSize)
            xor = [Bool](repeating: false, count: chip.numOLMCs)
            ac1 = [Bool](repeating: false, count: chip.numOLMCs)
        }

        func setMode(_ m: Mode) {
            switch m {
            case .simple: syn = true; ac0 = false
            case .complex: syn = true; ac0 = true
            case .registered: syn = false; ac0 = true
            }
        }

        var mode: Mode {
            switch (syn, ac0) {
            case (true, false): return .simple
            case (true, true): return .complex
            default: return .registered
            }
        }
    }

    private static func needsFlip(_ gal: GAL, _ pin: Int) -> Bool {
        guard gal.chip == .gal22v10, let i = gal.chip.pinToOLMC(pin) else { return false }
        let idx = gal.chip.numOLMCs - 1 - i
        return !gal.ac1[idx] && gal.xor[idx]
    }

    private static func pinToColumn(_ gal: GAL, _ pin: Int) throws -> Int {
        let table: [Col]
        switch gal.chip {
        case .gal16v8: table = gal.mode == .simple ? col16Simple : gal.mode == .complex ? col16Complex : col16Registered
        case .gal20v8: table = gal.mode == .simple ? col20Simple : gal.mode == .complex ? col20Complex : col20Registered
        case .gal22v10: table = col22V10
        case .gal20ra10: table = col20RA10
        }
        switch table[pin - 1] {
        case .ok(let v): return v
        case .bad(let msg): throw AsmError(line: 0, message: msg)
        }
    }

    private static func addTerm(_ gal: GAL, _ term: Term, _ b: Bounds) throws {
        var bounds = b
        let singleRow = bounds.maxRow == bounds.rowOffset + 1
        for row in term.rows {
            if bounds.rowOffset == bounds.maxRow {
                try fail(term.line, singleRow ? "only one product term allowed (no OR)"
                                              : "too many product terms in sum for pin (max: \(bounds.maxRow - 1), saw: \(term.rows.count))") as Void
            }
            for input in row {
                let flip = needsFlip(gal, input.pin)
                do {
                    let col = try pinToColumn(gal, input.pin)
                    let r = bounds.startRow + bounds.rowOffset
                    gal.fuses[r * gal.chip.numCols + col + ((input.neg != flip) ? 1 : 0)] = false
                } catch let e as AsmError {
                    throw AsmError(line: term.line, message: e.message)
                }
            }
            bounds.rowOffset += 1
        }
        // Clear the unused rows so they don't contribute.
        let cols = gal.chip.numCols
        for i in ((bounds.startRow + bounds.rowOffset) * cols)..<((bounds.startRow + bounds.maxRow) * cols) { gal.fuses[i] = false }
    }

    private static func addTermOpt(_ gal: GAL, _ term: Term?, _ b: Bounds) throws {
        try addTerm(gal, term ?? falseTerm(0), b)
    }

    // MARK: Parser

    enum Suffix: String { case none = "", t = "T", r = "R", e = "E", clk = "CLK", aprst = "APRST", arst = "ARST" }

    private enum Token: Equatable {
        case item(name: String, neg: Bool, suffix: Suffix)
        case equals, and, or
    }

    fileprivate struct Equation {
        var line: Int
        var lhs: LHS
        var rhs: [Pin]
        var isOr: [Bool]
    }

    fileprivate enum LHS { case pin(Pin, Suffix), ar, sp }

    private static func isAlpha(_ c: Character) -> Bool { c.isASCII && c.isLetter }
    private static func isAlnum(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }

    private static func tokenise(_ line: Int, _ s: String) throws -> [(Int, Token)] {
        var res: [(Int, Token)] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            switch ch {
            case "=": res.append((line, .equals)); i += 1
            case "+", "#": res.append((line, .or)); i += 1
            case "*", "&": res.append((line, .and)); i += 1
            case _ where ch == "/" || isAlpha(ch):
                var neg = false
                if chars[i] == "/" { neg = true; i += 1 }
                guard i < chars.count else { return try fail(line, "pin name expected after '/', found end-of-line") }
                guard isAlpha(chars[i]) else { return try fail(line, "pin name expected after '/', found non-alphabetic character '\(chars[i])'") }
                var name = String(chars[i]); i += 1
                while i < chars.count, isAlnum(chars[i]) { name.append(chars[i]); i += 1 }
                var suffix = Suffix.none
                if i < chars.count, chars[i] == "." {
                    i += 1
                    var ext = ""
                    while i < chars.count, isAlnum(chars[i]) { ext.append(chars[i]); i += 1 }
                    guard let s = Suffix(rawValue: ext), s != .none else { return try fail(line, "unknown suffix found: '\(ext)'") }
                    suffix = s
                }
                res.append((line, .item(name: name, neg: neg, suffix: suffix)))
            case _ where ch.isWhitespace: i += 1
            default: return try fail(line, "unexpected character in input: '\(ch)'")
            }
        }
        return res
    }

    struct Content {
        var chip: Chip
        var sig: [UInt8]
        var pins: [String]       // names, "/" prefixed when declared active low
        fileprivate var eqns: [Equation]
    }

    private static func lookupPin(_ chip: Chip, _ map: [String: Pin], _ name: String, _ neg: Bool) throws -> Pin {
        guard let p = map[name] else {
            if name == "NC" { return try fail(0, "NC (Not Connected) is not allowed in logic equations") }
            if chip == .gal22v10 && (name == "AR" || name == "SP") { return try fail(0, "use of \(name) is not allowed in equations") }
            return try fail(0, "unknown pinname '\(name)'")
        }
        return Pin(pin: p.pin, neg: p.neg != neg)
    }

    private static func atLine<T>(_ line: Int, _ body: () throws -> T) throws -> T {
        do { return try body() } catch let e as AsmError { throw AsmError(line: line, message: e.message) }
    }

    private static func extendPinMap(_ map: inout [String: Pin], _ chip: Chip, _ rowNum: Int, _ pins: [(String, Bool)]) throws {
        let n = chip.numPins
        let first = 1 + rowNum * n / 2
        for (k, (name, neg)) in pins.enumerated() {
            let pinNum = first + k
            if pinNum == n && (name != "VCC" || neg) { try fail(0, "pin \(pinNum) must be named VCC") as Void }
            if pinNum == n / 2 && (name != "GND" || neg) { try fail(0, "pin \(pinNum) must be named GND") as Void }
            if name == "VCC" && pinNum != n { try fail(0, "pin \(pinNum) cannot be named VCC, because the name is reserved for pin \(n)") as Void }
            if name == "GND" && pinNum != n / 2 { try fail(0, "pin \(pinNum) cannot be named GND, because the name is reserved for pin \(n / 2)") as Void }
            if name != "NC" {
                if map[name] != nil { try fail(0, "pinname \(name) is defined twice") as Void }
                if chip == .gal22v10 && (name == "AR" || name == "SP") { try fail(0, "GAL22V10: \(name) is not allowed as pinname") as Void }
                map[name] = Pin(pin: pinNum, neg: neg)
            }
        }
    }

    static func parse(_ text: String) throws -> Content {
        var rawLines = text.components(separatedBy: "\n")
        if rawLines.last == "" { rawLines.removeLast() }          // like Rust's str::lines()
        let lineCount = rawLines.count
        do {
            return try parseCore(rawLines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 })
        } catch let e as AsmError where e.line == eofLine {
            throw AsmError(line: lineCount, message: e.message)
        }
    }

    private static func parseCore(_ raw: [String]) throws -> Content {
        let lines: [(Int, String)] = raw.enumerated().map { (i, s) in
            let noComment = s.firstIndex(of: ";").map { String(s[..<$0]) } ?? s
            return (i + 1, noComment.trimmingCharacters(in: .whitespaces))
        }
        var it = lines.makeIterator()
        guard let (chipLine, chipName) = it.next() else { return try fail(eofLine, "unexpected GAL type found: '<eof>'") }
        guard let chip = Chip(rawValue: chipName.trimmingCharacters(in: .whitespaces)) else {
            return try fail(chipLine, "unexpected GAL type found: '\(chipName.trimmingCharacters(in: .whitespaces))'")
        }
        guard let (_, sigText) = it.next() else { return try fail(eofLine, "expected signature, found end of file") }
        let sig = Array(sigText.utf8.prefix(8))

        var rest: [(Int, String)] = []
        while let l = it.next() {
            if l.1.isEmpty { continue }
            if l.1 == "DESCRIPTION" { break }
            rest.append(l)
        }
        var restIt = rest.makeIterator()

        var map: [String: Pin] = [:]
        var pins: [(String, Bool)] = []
        for row in 0..<2 {
            guard let (ln, text) = restIt.next() else { return try fail(eofLine, "expected pin definitions, found end of file") }
            let tokens = try tokenise(ln, text)
            var rowPins: [(String, Bool)] = []
            for (tl, t) in tokens {
                switch t {
                case .item(let name, let neg, let suffix):
                    if suffix != .none { try fail(tl, "expected plain pin name, found pin with suffix") as Void }
                    rowPins.append((name, neg))
                default: try fail(tl, "expected pin, found other token") as Void
                }
            }
            if tokens.count != chip.numPins / 2 {
                try fail(ln, "wrong number of pins on pin definition line - expected \(chip.numPins / 2), found \(tokens.count)") as Void
            }
            try atLine(ln) { try extendPinMap(&map, chip, row, rowPins) }
            pins += rowPins
        }

        // Tokenise the remaining lines and join continuation lines.
        var tokLines: [Result<[(Int, Token)], AsmError>] = []
        while let (ln, text) = restIt.next() {
            do { tokLines.append(.success(try tokenise(ln, text))) } catch let e as AsmError { tokLines.append(.failure(e)) }
        }
        var joined: [Result<[(Int, Token)], AsmError>] = []
        var i = 0
        func endsWithOp(_ v: [(Int, Token)]) -> Bool { if let t = v.last?.1 { return t == .and || t == .or }; return false }
        func startsWithOp(_ k: Int) -> Bool {
            guard k < tokLines.count, case .success(let v) = tokLines[k], let t = v.first?.1 else { return false }
            return t == .and || t == .or
        }
        outer: while i < tokLines.count {
            switch tokLines[i] {
            case .failure: joined.append(tokLines[i]); i += 1
            case .success(var line):
                i += 1
                while endsWithOp(line) || startsWithOp(i) {
                    guard i < tokLines.count else { break }
                    switch tokLines[i] {
                    case .success(let next): line += next; i += 1
                    case .failure: joined.append(tokLines[i]); i += 1; continue outer
                    }
                }
                joined.append(.success(line))
            }
        }

        var eqns: [Equation] = []
        for item in joined {
            switch item {
            case .failure(let e): throw e
            case .success(let tokens): eqns.append(try parseEquation(chip, map, tokens))
            }
        }

        let names = pins.map { ($0.1 ? "/" : "") + $0.0 }
        return Content(chip: chip, sig: sig, pins: names, eqns: eqns)
    }

    private static func parseEquation(_ chip: Chip, _ map: [String: Pin], _ tokens: [(Int, Token)]) throws -> Equation {
        var k = 0
        func next() -> (Int, Token)? { defer { k += 1 }; return k < tokens.count ? tokens[k] : nil }

        let lhs: LHS
        switch next() {
        case .some((let ln, .item(let name, let neg, let suffix))):
            if chip == .gal22v10 && (name == "AR" || name == "SP") {
                if suffix != .none { return try fail(ln, "no suffix is allowed for \(name)") }
                if neg { return try fail(ln, "negation of \(name) is not allowed") }
                lhs = name == "AR" ? .ar : .sp
            } else {
                let p = try atLine(ln) { try lookupPin(chip, map, name, neg) }
                lhs = .pin(p, suffix)
            }
        default:
            return try fail(eofLine, "expected pin, found other token")
        }

        guard let (eqLine, eq) = next() else { return try fail(eofLine, "expected right-hand side of equation, found end of file") }
        guard eq == .equals else { return try fail(eqLine, "'=' expected") }

        func parsePin() throws -> Pin {
            guard let (ln, t) = next() else { return try fail(eofLine, "expected pin name, found end of line") }
            guard case .item(let name, let neg, let suffix) = t else { return try fail(ln, "expected pin, found other token") }
            if suffix != .none { return try fail(ln, "expected plain pin name, found pin with suffix") }
            return try atLine(ln) { try lookupPin(chip, map, name, neg) }
        }

        var rhs = [try parsePin()]
        var isOr = [false]
        while let (ln, t) = next() {
            switch t {
            case .and: isOr.append(false); rhs.append(try parsePin())
            case .or: isOr.append(true); rhs.append(try parsePin())
            default: return try fail(ln, "expected +, #, * or &, found other token")
            }
        }
        return Equation(line: eqLine, lhs: lhs, rhs: rhs, isOr: isOr)
    }

    // MARK: Blueprint

    enum PinMode { case combinatorial, tristate, registered }

    struct OLMC {
        var activeHigh = false
        var output: (mode: PinMode, term: Term)?
        var triCon: Term?
        var clock: Term?
        var arst: Term?
        var aprst: Term?
        var feedback = false
    }

    struct Blueprint {
        var chip: Chip
        var sig: [UInt8]
        var pins: [String]
        var olmcs: [OLMC]
        var ar: Term?
        var sp: Term?
    }

    private static func eqnToTerm(_ chip: Chip, _ e: Equation) throws -> Term {
        if e.rhs.count == 1 {
            let p = e.rhs[0]
            if p.pin == chip.numPins {
                if p.neg { return try fail(0, "VCC cannot be negated, use GND instead of /VCC") }
                return trueTerm(e.line)
            } else if p.pin == chip.numPins / 2 {
                if p.neg { return try fail(0, "GND cannot be negated, use VCC instead of /GND") }
                return falseTerm(e.line)
            }
        }
        var ors: [[Pin]] = []
        var ands: [Pin] = []
        for (p, isOr) in zip(e.rhs, e.isOr) {
            if isOr { ors.append(ands); ands = [] }
            ands.append(p)
        }
        ors.append(ands)
        return Term(line: e.line, rows: ors)
    }

    static func blueprint(_ content: Content) throws -> Blueprint {
        var bp = Blueprint(chip: content.chip, sig: content.sig, pins: content.pins,
                           olmcs: [OLMC](repeating: OLMC(), count: content.chip.numOLMCs), ar: nil, sp: nil)
        for e in content.eqns {
            try atLine(e.line) {
                for input in e.rhs { if let i = bp.chip.pinToOLMC(input.pin) { bp.olmcs[i].feedback = true } }
                let term = try eqnToTerm(bp.chip, e)
                switch e.lhs {
                case .ar:
                    if bp.ar != nil { try fail(0, "AR is defined twice") as Void }
                    bp.ar = term
                case .sp:
                    if bp.sp != nil { try fail(0, "SP is defined twice") as Void }
                    bp.sp = term
                case .pin(let pin, let suffix):
                    guard let n = bp.chip.pinToOLMC(pin.pin) else { try fail(0, "this pin can't be used as output") as Void; return }
                    func control(_ name: String, _ field: WritableKeyPath<OLMC, Term?>) throws {
                        if pin.neg { try fail(0, "negation of .\(name) is not allowed") as Void }
                        if bp.olmcs[n][keyPath: field] != nil { try fail(0, "multiple .\(name) definitions for the same output") as Void }
                        bp.olmcs[n][keyPath: field] = term
                    }
                    switch suffix {
                    case .none, .t, .r:
                        if bp.olmcs[n].output != nil { try fail(0, "output \(bp.pins[pin.pin - 1]) is defined multiple times") as Void }
                        bp.olmcs[n].output = (suffix == .r ? .registered : suffix == .t ? .tristate : .combinatorial, term)
                        bp.olmcs[n].activeHigh = !pin.neg
                    case .e: try control("E", \.triCon)
                    case .clk: try control("CLK", \.clock)
                    case .arst: try control("ARST", \.arst)
                    case .aprst: try control("APRST", \.aprst)
                    }
                }
            }
        }
        return bp
    }

    // MARK: Builder

    private static func analyseMode(_ olmcs: [OLMC]) -> Mode {
        if olmcs.contains(where: { $0.output?.mode == .registered }) { return .registered }
        if olmcs.contains(where: { $0.output?.mode == .tristate }) { return .complex }
        for (n, o) in olmcs.enumerated() where o.feedback {
            if o.output == nil { if n == 3 || n == 4 { return .complex } } else { return .complex }
        }
        return .simple
    }

    static func build(_ bp: Blueprint) throws -> GAL {
        let gal = GAL(bp.chip)
        let n = bp.chip.numOLMCs

        func checkNot20RA10() throws {
            for o in bp.olmcs {
                if let t = o.clock { try fail(t.line, ".CLK is not allowed when this type of GAL is used") as Void }
                if let t = o.arst { try fail(t.line, ".ARST is not allowed when this type of GAL is used") as Void }
                if let t = o.aprst { try fail(t.line, ".APRST is not allowed when this type of GAL is used") as Void }
            }
        }
        func setSig() {
            for i in 0..<min(bp.sig.count, 8) {
                let ch = bp.sig[i]
                for j in 0..<8 { gal.sig[i * 8 + j] = (ch << j) & 0x80 != 0 }
            }
        }
        func setTristate(_ comIsTri: Bool) {
            for (i, o) in bp.olmcs.enumerated() {
                let tri: Bool
                switch o.output?.mode {
                case nil: tri = o.feedback
                case .tristate?: tri = true
                case .combinatorial?: tri = comIsTri
                case .registered?: tri = false
                }
                if tri { gal.ac1[n - 1 - i] = true }
            }
        }
        func setXors() {
            for (i, o) in bp.olmcs.enumerated() where o.output != nil && o.activeHigh { gal.xor[n - 1 - i] = true }
        }
        func mainBounds(_ o: OLMC, _ b: Bounds) -> Bounds {
            var b = b
            switch bp.chip {
            case .gal16v8, .gal20v8:
                if !(gal.mode == .simple || o.output?.mode == .registered) { b.rowOffset = 1 }
            case .gal22v10: b.rowOffset = 1
            case .gal20ra10: b.rowOffset = 4
            }
            return b
        }
        func setCore() throws {
            for (i, o) in bp.olmcs.enumerated() {
                let bounds = Bounds(startRow: bp.chip.startRow(i), maxRow: bp.chip.rowsForOLMC(i), rowOffset: 0)
                if let out = o.output {
                    try addTerm(gal, out.term, mainBounds(o, bounds))
                } else {
                    try addTerm(gal, falseTerm(0), bounds)
                }
                if let t = o.triCon {
                    switch o.output?.mode {
                    case nil: try fail(t.line, "the output must be defined to use .E") as Void
                    case .registered? where bp.chip == .gal16v8 || bp.chip == .gal20v8:
                        try fail(t.line, "GAL16V8/20V8: tri. control for reg. output is not allowed") as Void
                    case .combinatorial?: try fail(t.line, "tristate control without previous '.T'") as Void
                    default: break
                    }
                    try addTerm(gal, t, Bounds(startRow: bounds.startRow, maxRow: 1, rowOffset: 0))
                }
            }
        }
        func checkAux(_ field: Term?, _ o: OLMC, _ suffix: String) throws {
            guard let t = field else { return }
            switch o.output?.mode {
            case nil: try fail(t.line, "the output must be defined to use .\(suffix)") as Void
            case .registered?: break
            default: try fail(t.line, "use of .\(suffix) is only allowed for registered outputs") as Void
            }
        }

        switch bp.chip {
        case .gal16v8, .gal20v8:
            try checkNot20RA10()
            setSig()
            gal.setMode(analyseMode(bp.olmcs))
            setTristate(gal.mode != .simple)
            setXors()
            try setCore()
            for k in 0..<64 { gal.pt[k] = true }
        case .gal22v10:
            try checkNot20RA10()
            setSig()
            setTristate(true)
            setXors()
            try setCore()
            try addTermOpt(gal, bp.ar, Bounds(startRow: 0, maxRow: 1, rowOffset: 0))
            try addTermOpt(gal, bp.sp, Bounds(startRow: 131, maxRow: 1, rowOffset: 0))
        case .gal20ra10:
            setSig()
            setXors()
            try setCore()
            for (i, o) in bp.olmcs.enumerated() {
                let b = Bounds(startRow: bp.chip.startRow(i), maxRow: bp.chip.rowsForOLMC(i), rowOffset: 0)
                try checkAux(o.clock, o, "CLK")
                try checkAux(o.arst, o, "ARST")
                try checkAux(o.aprst, o, "APRST")
                if let out = o.output, out.mode == .registered {
                    try addTermOpt(gal, o.arst, Bounds(startRow: b.startRow, maxRow: 3, rowOffset: 2))
                    try addTermOpt(gal, o.aprst, Bounds(startRow: b.startRow, maxRow: 4, rowOffset: 3))
                    if o.clock == nil { try fail(out.term.line, "missing clock definition (.CLK) of registered output") as Void }
                }
                if o.output != nil {
                    try addTermOpt(gal, o.clock, Bounds(startRow: b.startRow, maxRow: 2, rowOffset: 1))
                }
            }
        }
        return gal
    }

    // MARK: JEDEC output (galasm-compatible)

    static func jedec(_ gal: GAL, securityBit: Bool = false, assembler: String = "ChipBurner (Galette port)") -> String {
        let chip = gal.chip
        var buf = "\u{02}\n"
        buf += "GAL-Assembler:  \(assembler)\n"
        buf += "Device:         \(chip.rawValue)\n\n"
        buf += "*F0\n"
        buf += securityBit ? "*G1\n" : "*G0\n"
        buf += "*QF\(chip.totalSize)\n"

        var idx = 0, bitNum = 0
        var byte: UInt8 = 0
        var sum: UInt16 = 0
        func check(_ b: Bool) {
            if b { byte |= UInt8(1 << bitNum) }
            bitNum += 1
            if bitNum == 8 { sum = sum &+ UInt16(byte); byte = 0; bitNum = 0 }
        }
        func add(_ bits: [Bool]) {
            buf += String(format: "*L%04d ", idx)
            for b in bits { buf += b ? "1" : "0"; check(b); idx += 1 }
            buf += "\n"
        }
        let cols = chip.numCols
        for r in 0..<chip.numRows {
            let row = Array(gal.fuses[(r * cols)..<((r + 1) * cols)])
            if row.contains(true) { add(row) } else { for b in row { check(b); idx += 1 } }
        }
        if chip == .gal22v10 {
            var bits: [Bool] = []
            for k in 0..<gal.xor.count { bits.append(gal.xor[k]); bits.append(gal.ac1[k]) }
            add(bits)
        } else {
            add(gal.xor)
        }
        add(gal.sig)
        if chip == .gal16v8 || chip == .gal20v8 {
            add(gal.ac1)
            add(gal.pt)
            add([gal.syn])
            add([gal.ac0])
        }
        buf += String(format: "*C%04x\n", sum &+ UInt16(byte))
        buf += "*\n"
        buf += "\u{03}"
        var fileSum: UInt16 = 0
        for b in buf.utf8 { fileSum = fileSum &+ UInt16(b) }
        buf += String(format: "%04x\n", fileSum)
        return buf
    }

    /// Source text → JEDEC text.
    static func assemble(_ source: String, securityBit: Bool = false, assembler: String = "ChipBurner (Galette port)") throws -> (chip: Chip, jedec: String) {
        let content = try parse(source)
        let bp = try blueprint(content)
        let gal = try build(bp)
        return (content.chip, jedec(gal, securityBit: securityBit, assembler: assembler))
    }

    /// A small working example for each chip, used by New PLD Source.
    static func template(for chip: Chip) -> String {
        let help = """
            DESCRIPTION

            Line 1 is the chip type, line 2 a signature (up to 8 characters stored in the chip).
            Then the pin names, two rows from pin 1 upwards (NC = not connected, GND and VCC fixed),
            followed by equations:  * = AND, + = OR, / = NOT, ; starts a comment.
              Out = A * B + /C       combinatorial output          /Out = …   active-low output
              Out.T = …  Out.E = …   tristate output and its enable term
              Out.R = …              registered output (D flip-flop)
            """
        switch chip {
        case .gal16v8:
            return """
                GAL16V8
                EXAMPLE

                Clock A     B     C     D     E     F     G     H     GND
                /OE   Q0    Q1    Q2    Y3    Y2    Y1    Y0    NC    VCC

                Y0 = A * B                 ; AND
                Y1 = A + B                 ; OR
                /Y2 = A * B                ; NAND (active-low output)
                Y3 = A * /B + /A * B       ; XOR
                Q0.R = C                   ; register: Q0 follows C on the clock edge
                Q1.R = Q0
                Q2.R = D * Q1 + E

                \(help)
                  Registered mode: pin 1 is the clock and pin 11 /OE for the registered outputs.
                """
        case .gal20v8:
            return """
                GAL20V8
                EXAMPLE

                Clock A     B     C     D     E     F     G     H     I     J     GND
                /OE   NC    Q0    Q1    Y3    Y2    Y1    Y0    NC    NC    NC    VCC

                Y0 = A * B
                Y1 = A + B
                /Y2 = A * B
                Y3 = A * /B + /A * B
                Q0.R = C
                Q1.R = Q0 * D

                \(help)
                  Registered mode: pin 1 is the clock and pin 13 /OE for the registered outputs.
                """
        case .gal22v10:
            return """
                GAL22V10
                EXAMPLE

                Clock A     B     C     D     E     F     G     H     I     J     GND
                K     NC    Q0    Q1    Y3    Y2    Y1    Y0    NC    NC    NC    VCC

                Y0 = A * B
                Y1 = A + B
                /Y2 = A * B
                Y3.T = A * /B + /A * B
                Y3.E = K                   ; Y3 only drives the pin while K is high
                Q0.R = C
                Q1.R = Q0 * D
                AR = J                     ; asynchronous reset of all registers
                SP = GND                   ; synchronous preset (unused)

                \(help)
                  GAL22V10: pin 1 is the clock for registered outputs; AR and SP control all registers.
                """
        case .gal20ra10:
            return """
                GAL20RA10
                EXAMPLE

                /PL   A     B     C     D     E     F     G     H     I     Clock GND
                /OE   NC    Q0    Q1    Y1    Y0    NC    NC    NC    NC    NC    VCC

                Y0 = A * B
                Y1 = A + B
                Q0.R = C
                Q0.CLK = Clock
                Q1.R = Q0
                Q1.CLK = Clock
                Q1.ARST = D                ; asynchronous reset of Q1

                \(help)
                  GAL20RA10: every registered output needs its own .CLK term; .ARST and .APRST are
                  optional reset and preset terms. Pin 1 is /PL (preload) and pin 13 /OE.
                """
        }
    }

    /// Pin names from a source (index 0 = pin 1), for labelling decoded equations.
    static func pinNames(_ source: String) -> [Int: String]? {
        guard let c = try? parse(source) else { return nil }
        var out: [Int: String] = [:]
        for (i, n) in c.pins.enumerated() where n != "NC" { out[i + 1] = n.hasPrefix("/") ? String(n.dropFirst()) : n }
        return out
    }
}
