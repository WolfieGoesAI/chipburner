import Foundation

/// Logic chip models written in a small text format (logic-models.txt, shared with the Android app), for the
/// Extended Logic Test. The format and the semantics are described in LogicDsl.kt; this file mirrors it line
/// for line so that both apps generate exactly the same test vectors (the build compares fingerprints).
enum LogicDsl {
    indirect enum Expr {
        case num(Int)
        case unknown
        case ref(String)
        case un(String, Expr)
        case bin(String, Expr, Expr)
        case cond(Expr, Expr, Expr)
        case call(String, [Expr])
    }

    struct Assign { let target: String; let expr: Expr; let isLet: Bool }

    enum Stmt {
        case assign(Assign)
        case out(String, Expr, Bool)                 // name, expression, open collector
        case chain([(Expr?, [Assign])])
    }

    final class Def {
        let names: [String]
        let pins: [String]
        let roles: [Character]
        let rest: [(String, Bool)]
        let clocks: [String]
        let full: Int
        let controls: [String]
        let state: [String]
        let stmts: [Stmt]
        let transceiver: (ab: [(String, Character)], ba: [(String, Character)])?
        var key: String { names[0] }
        var sequential: Bool { !state.isEmpty || !clocks.isEmpty }

        init(names: [String], pins: [String], roles: [Character], rest: [(String, Bool)], clocks: [String], full: Int,
             controls: [String], state: [String], stmts: [Stmt], transceiver: (ab: [(String, Character)], ba: [(String, Character)])?) {
            self.names = names; self.pins = pins; self.roles = roles; self.rest = rest; self.clocks = clocks
            self.full = full; self.controls = controls; self.state = state; self.stmts = stmts; self.transceiver = transceiver
        }
    }

    struct ParseError: Error { let message: String }

    /// Loaded definitions by name (every name of a model maps to it).
    private(set) static var defs: [String: Def] = [:]
    private static var loadedBundle = false

    @discardableResult
    static func load(_ text: String) -> [String] {
        var errors: [String] = []
        var d: [String: Def] = [:]
        for def in parse(text, errors: &errors) { for n in def.names where d[n] == nil { d[n] = def } }
        defs = d
        loadedBundle = true
        return errors
    }

    /// Loads logic-models.txt from the app bundle once (the dbtest loads its own copy with `load`).
    static func ensureLoaded() {
        guard !loadedBundle else { return }
        loadedBundle = true
        if let url = Bundle.main.url(forResource: "logic-models", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            load(text)
        }
    }

    // MARK: Parsing

    private static func isNameChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "/" || c == "_" || c == "'" || c == "."
    }

    private static func tokenize(_ s: String) -> [String] {
        let ch = Array(s)
        var out: [String] = []
        var i = 0
        while i < ch.count {
            let c = ch[i]
            if c.isWhitespace { i += 1; continue }
            if isNameChar(c) {
                let st = i
                while i < ch.count && isNameChar(ch[i]) { i += 1 }
                out.append(String(ch[st..<i]))
                continue
            }
            if i + 1 < ch.count, ["==", "!=", "<=", ">="].contains(String(ch[i...i + 1])) {
                out.append(String(ch[i...i + 1])); i += 2; continue
            }
            out.append(String(c)); i += 1
        }
        return out
    }

    private final class P {
        let t: [String]
        var i = 0
        init(_ t: [String]) { self.t = t }
        func peek() -> String? { i < t.count ? t[i] : nil }
        func next() throws -> String { guard i < t.count else { throw ParseError(message: "unexpected end") }; i += 1; return t[i - 1] }
        func expect(_ s: String) throws { let n = try next(); if n != s { throw ParseError(message: "expected \(s), found \(n)") } }
        func expr() throws -> Expr { try ternary() }
        func ternary() throws -> Expr {
            let c = try or()
            if peek() == "?" { _ = try next(); let a = try ternary(); try expect(":"); let b = try ternary(); return .cond(c, a, b) }
            return c
        }
        func or() throws -> Expr { var a = try xor(); while peek() == "|" { _ = try next(); a = .bin("|", a, try xor()) }; return a }
        func xor() throws -> Expr { var a = try and(); while peek() == "^" { _ = try next(); a = .bin("^", a, try and()) }; return a }
        func and() throws -> Expr { var a = try cmp(); while peek() == "&" { _ = try next(); a = .bin("&", a, try cmp()) }; return a }
        func cmp() throws -> Expr {
            var a = try add()
            while let p = peek(), ["==", "!=", "<", ">", "<=", ">="].contains(p) { let op = try next(); a = .bin(op, a, try add()) }
            return a
        }
        func add() throws -> Expr { var a = try mul(); while peek() == "+" || peek() == "-" { let op = try next(); a = .bin(op, a, try mul()) }; return a }
        func mul() throws -> Expr { var a = try unary(); while peek() == "*" || peek() == "%" { let op = try next(); a = .bin(op, a, try unary()) }; return a }
        func unary() throws -> Expr {
            if peek() == "!" { _ = try next(); return .un("!", try unary()) }
            if peek() == "-" { _ = try next(); return .un("-", try unary()) }
            return try primary()
        }
        func primary() throws -> Expr {
            let tk = try next()
            if tk == "(" { let e = try expr(); try expect(")"); return e }
            if tk.allSatisfy({ $0.isASCII && $0.isNumber }), let v = Int(tk) { return .num(v) }
            if tk == "Z" || tk == "X" { return .unknown }
            if peek() == "(" && ["rise", "fall", "bus", "bit"].contains(tk) {
                _ = try next()
                var args: [Expr] = []
                if peek() != ")" { args.append(try expr()); while peek() == "," { _ = try next(); args.append(try expr()) } }
                try expect(")")
                return .call(tk, args)
            }
            if let f = tk.first, f.isLetter || f.isNumber || f == "/" || f == "_" { return .ref(tk) }
            throw ParseError(message: "unexpected \(tk)")
        }
    }

    private static func assignments(_ text: String, isLet: Bool = false) throws -> [Assign] {
        try text.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { (a: String) throws -> Assign in
            guard let eq = a.firstIndex(of: "="), eq != a.startIndex,
                  a.index(after: eq) == a.endIndex || a[a.index(after: eq)] != "=" else {
                throw ParseError(message: "expected assignment in \"\(a)\"")
            }
            let p = P(tokenize(String(a[a.index(after: eq)...])))
            let e = try p.expr()
            if let x = p.peek() { throw ParseError(message: "unexpected \(x) in \"\(a)\"") }
            return Assign(target: a[..<eq].trimmingCharacters(in: .whitespaces), expr: e, isLet: isLet)
        }
    }

    private static func expr(_ text: String) throws -> Expr {
        let p = P(tokenize(text))
        let e = try p.expr()
        if let x = p.peek() { throw ParseError(message: "unexpected \(x) in \"\(text)\"") }
        return e
    }

    private static func words(_ s: String) -> [String] { s.split(whereSeparator: { $0.isWhitespace }).map(String.init) }

    static func parse(_ text: String, errors: inout [String]) -> [Def] {
        var out: [Def] = []
        var names: [String]?
        var pins: [String] = [], rest: [(String, Bool)] = [], clocks: [String] = [], full = 0
        var controls: [String] = [], state: [String] = [], stmts: [Stmt] = [], bad = false
        var xcvr: (ab: [(String, Character)], ba: [(String, Character)])?
        func finish(_ errors: inout [String]) {
            guard let n = names else { return }
            if !bad {
                do { out.append(try build(n, pins, rest, clocks, full, controls, state, stmts, xcvr)) }
                catch let e as ParseError { errors.append("\(n[0]): \(e.message)") }
                catch { errors.append("\(n[0]): \(error)") }
            }
            names = nil
        }
        let lines = text.components(separatedBy: "\n")
        for (ln, raw) in lines.enumerated() {
            let line = String(raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let kw = line.split(separator: " ", maxSplits: 1).first.map(String.init) ?? line
            let rest0 = line.count > kw.count ? String(line.dropFirst(kw.count)).trimmingCharacters(in: .whitespaces) : ""
            if kw == "model" {
                finish(&errors)
                names = rest0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                pins = []; rest = []; clocks = []; full = 0; controls = []; state = []; stmts = []; bad = false; xcvr = nil
                continue
            }
            guard let current = names else { errors.append("line \(ln + 1): outside a model"); continue }
            do {
                switch kw {
                case "pins": pins = words(rest0)
                case "rest":
                    rest = try words(rest0).map { (w: String) throws -> (String, Bool) in
                        let p = w.split(separator: "=", omittingEmptySubsequences: false)
                        guard p.count == 2 else { throw ParseError(message: "bad rest \(w)") }
                        return (String(p[0]), p[1] == "1")
                    }
                case "clocks": clocks = words(rest0)
                case "full": guard let f = Int(rest0) else { throw ParseError(message: "bad full") }; full = f
                case "controls": controls = words(rest0)
                case "transceiver":
                    let sides = try rest0.split(separator: "|").map { (side: Substring) throws -> [(String, Character)] in
                        try words(String(side)).map { (w: String) throws -> (String, Character) in
                            let p = w.split(separator: "=", omittingEmptySubsequences: false)
                            guard p.count == 2, let c = p[1].first else { throw ParseError(message: "bad transceiver \(w)") }
                            return (String(p[0]), c)
                        }
                    }
                    guard sides.count == 2 else { throw ParseError(message: "transceiver needs two settings") }
                    xcvr = (sides[0], sides[1])
                case "state": state += words(rest0)
                case "let": stmts += try assignments(rest0, isLet: true).map { .assign($0) }
                case "out", "oc":
                    guard let eq = rest0.firstIndex(of: "=") else { throw ParseError(message: "expected =") }
                    stmts.append(.out(rest0[..<eq].trimmingCharacters(in: .whitespaces), try expr(String(rest0[rest0.index(after: eq)...])), kw == "oc"))
                case "when":
                    guard let d = rest0.range(of: " do ") else { throw ParseError(message: "when without do") }
                    stmts.append(.chain([(try expr(String(rest0[..<d.lowerBound])), try assignments(String(rest0[d.upperBound...])))]))
                case "elif", "else":
                    guard case .chain(var branches)? = stmts.last else { throw ParseError(message: "\(kw) without when") }
                    if kw == "else" {
                        guard rest0.hasPrefix("do ") else { throw ParseError(message: "else without do") }
                        branches.append((nil, try assignments(String(rest0.dropFirst(3)))))
                    } else {
                        guard let d = rest0.range(of: " do ") else { throw ParseError(message: "elif without do") }
                        branches.append((try expr(String(rest0[..<d.lowerBound])), try assignments(String(rest0[d.upperBound...]))))
                    }
                    stmts[stmts.count - 1] = .chain(branches)
                default: stmts += try assignments(line).map { .assign($0) }
                }
            } catch let e as ParseError {
                errors.append("\(current[0]) line \(ln + 1): \(e.message)"); bad = true
            } catch {
                errors.append("\(current[0]) line \(ln + 1): \(error)"); bad = true
            }
        }
        finish(&errors)
        return out
    }

    private static func build(_ names: [String], _ pins: [String], _ rest: [(String, Bool)], _ clocks: [String], _ full: Int,
                              _ controls: [String], _ state: [String], _ stmts: [Stmt],
                              _ xcvr: (ab: [(String, Character)], ba: [(String, Character)])?) throws -> Def {
        if pins.isEmpty { throw ParseError(message: "no pins") }
        var outs = Set<String>(), ocs = Set<String>()
        for s in stmts { if case let .out(n, _, oc) = s { outs.insert(n); if oc { ocs.insert(n) } } }
        // pins read by the logic as well as driven by it are bidirectional
        var read = Set<String>()
        func refs(_ e: Expr) {
            switch e {
            case .ref(let n): read.insert(n)
            case .un(_, let a): refs(a)
            case .bin(_, let a, let b): refs(a); refs(b)
            case .cond(let c, let t, let f): refs(c); refs(t); refs(f)
            case .call(_, let args): args.forEach(refs)
            default: break
            }
        }
        for s in stmts {
            switch s {
            case .assign(let a): refs(a.expr)
            case .out(_, let e, _): refs(e)
            case .chain(let br): for (c, a) in br { if let c = c { refs(c) }; a.forEach { refs($0.expr) } }
            }
        }
        let roles: [Character] = pins.map { p in
            switch p.uppercased() {
            case "GND", "VSS": return "g"
            case "VCC", "VDD": return "v"
            case "NC": return "n"
            default:
                if outs.contains(p) && read.contains(p) { return ocs.contains(p) ? "y" : "b" }
                return ocs.contains(p) ? "z" : outs.contains(p) ? "o" : "i"
            }
        }
        let pinSet = Set(pins)
        var known = pinSet.union(state)
        for o in outs where !pinSet.contains(o) { throw ParseError(message: "output \(o) is not a pin") }
        for r in rest where !pinSet.contains(r.0) { throw ParseError(message: "rest \(r.0) is not a pin") }
        for c in clocks where !pinSet.contains(c) { throw ParseError(message: "clock \(c) is not a pin") }
        for c in controls where !pinSet.contains(c) { throw ParseError(message: "control \(c) is not a pin") }
        func check(_ e: Expr) throws {
            switch e {
            case .ref(let n): if !known.contains(n) { throw ParseError(message: "unknown name \(n)") }
            case .un(_, let a): try check(a)
            case .bin(_, let a, let b): try check(a); try check(b)
            case .cond(let c, let t, let f): try check(c); try check(t); try check(f)
            case .call(let fn, let args):
                if fn == "rise" || fn == "fall" {
                    guard args.count == 1, case .ref(let n) = args[0], pinSet.contains(n) else { throw ParseError(message: "\(fn) needs a pin") }
                }
                for a in args { try check(a) }
            default: break
            }
        }
        for s in stmts {
            switch s {
            case .assign(let a):
                try check(a.expr)
                if a.isLet { known.insert(a.target) } else if !state.contains(a.target) { throw ParseError(message: "\(a.target) is not declared as state") }
            case .out(_, let e, _): try check(e)
            case .chain(let br):
                for (c, a) in br {
                    if let c = c { try check(c) }
                    for x in a { try check(x.expr); if !state.contains(x.target) { throw ParseError(message: "\(x.target) is not declared as state") } }
                }
            }
        }
        if let x = xcvr { for (n, _) in x.ab + x.ba where !pinSet.contains(n) { throw ParseError(message: "transceiver control \(n) is not a pin") } }
        return Def(names: names, pins: pins, roles: roles, rest: rest, clocks: clocks, full: full, controls: controls,
                   state: state, stmts: stmts, transceiver: xcvr)
    }

    // MARK: Evaluation

    private static func b(_ v: Bool) -> Int { v ? 1 : 0 }

    private static func eval(_ e: Expr, _ s: LogicSim, _ lets: [String: Int?]) -> Int? {
        switch e {
        case .num(let v): return v
        case .unknown: return nil
        case .ref(let n):
            if let l = lets[n] { return l }
            if s.idx(n) != nil { return s.v(n).map { b($0) } }
            return s.int("$" + n)
        case .un(let op, let x):
            guard let a = eval(x, s, lets) else { return nil }
            return op == "!" ? b(a == 0) : -a
        case .bin(let op, let x, let y):
            let a = eval(x, s, lets)
            if op == "&" {
                if a == 0 { return 0 }
                let c = eval(y, s, lets)
                if c == 0 { return 0 }
                return a == nil || c == nil ? nil : 1
            }
            if op == "|" {
                if let a = a, a != 0 { return 1 }
                let c = eval(y, s, lets)
                if let c = c, c != 0 { return 1 }
                return a == nil || c == nil ? nil : 0
            }
            guard let av = a, let c = eval(y, s, lets) else { return nil }
            switch op {
            case "^": return b((av != 0) != (c != 0))
            case "==": return b(av == c)
            case "!=": return b(av != c)
            case "<": return b(av < c)
            case ">": return b(av > c)
            case "<=": return b(av <= c)
            case ">=": return b(av >= c)
            case "+": return av + c
            case "-": return av - c
            case "*": return av * c
            case "%": return c == 0 ? nil : ((av % c) + c) % c
            default: return nil
            }
        case .cond(let c, let t, let f):
            guard let cv = eval(c, s, lets) else {
                let tv = eval(t, s, lets), fv = eval(f, s, lets)
                return tv == fv ? tv : nil
            }
            return cv != 0 ? eval(t, s, lets) : eval(f, s, lets)
        case .call(let fn, let args):
            switch fn {
            case "rise": if case .ref(let n) = args[0] { return b(s.rose(n)) }; return nil
            case "fall": if case .ref(let n) = args[0] { return b(s.fell(n)) }; return nil
            case "bus":
                var r = 0
                for (i, a) in args.enumerated() { guard let v = eval(a, s, lets) else { return nil }; if v != 0 { r |= 1 << i } }
                return r
            case "bit":
                guard let v = eval(args[0], s, lets), let k = eval(args[1], s, lets) else { return nil }
                return (v >> (k & 31)) & 1
            default: return nil
            }
        }
    }

    /// One step of the model: state updates and outputs, in the order written.
    static func step(_ d: Def, _ s: LogicSim) {
        var lets: [String: Int?] = [:]
        for st in d.stmts {
            switch st {
            case .assign(let a):
                let v = eval(a.expr, s, lets)
                if a.isLet { lets[a.target] = .some(v) } else { s.setInt("$" + a.target, v) }
            case .out(let n, let e, _):
                s.o(n, eval(e, s, lets).map { $0 != 0 })
            case .chain(let branches):
                var unknown = false
                for (c, assigns) in branches {
                    if unknown { for a in assigns { s.setInt("$" + a.target, nil) }; continue }
                    let cv: Int? = c == nil ? 1 : eval(c!, s, lets)
                    if cv == nil {
                        // condition unknown: whatever these branches would set becomes unknown, unless unchanged
                        for a in assigns { let nv = eval(a.expr, s, lets); if nv == nil || nv != s.int("$" + a.target) { s.setInt("$" + a.target, nil) } }
                        unknown = true
                    } else if cv! != 0 {
                        let vals = assigns.map { eval($0.expr, s, lets) }
                        for (i, a) in assigns.enumerated() { s.setInt("$" + a.target, vals[i]) }
                        break
                    }
                }
            }
        }
    }
}
