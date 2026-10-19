package com.wolfiegoesai.chipburner

/**
 * Logic chip models written in a small text format (assets/logic-models.txt, shared with the Mac app),
 * for the Extended Logic Test. Each model lists the pins in order and the chip's logic:
 *
 *   model 74257,74LS257         names (the first is the model key)
 *   pins S 1A 1B 1Y … GND … VCC  pin 1 first; GND/VSS = ground, VCC/VDD = supply, NC = unused
 *   rest /CLR=1 LE=0            resting levels of the controls (sequence tests)
 *   clocks CLK                  clock inputs, pulsed with C in the vectors
 *   full 16                     length of the full clock cycle in the sequence test
 *   transceiver DIR=1 /OE=0 | DIR=0 /OE=0
 *                               a bus transceiver: the control levels for A→B and for B→A; the test then sends
 *                               every pattern across A1…An → B1…Bn and back (pins used both ways are bidirectional)
 *   controls S0 S1 /G           more pins that must change one at a time in the sequence test (levels that
 *                               select or store, e.g. the address of an addressable latch)
 *   state Q C                   state kept between steps (starts unknown)
 *   let T = expr                a temporary for this step
 *   Q = expr                    a state assignment
 *   when cond do Q = e; C = e   conditional assignments, followed by elif cond do … / else do …
 *   out 1Y = expr               an output (Z or an unknown value = not checked)
 *   oc 1Y = expr                an open-collector / open-drain output (checked as Z when high)
 *
 * Values are integers or unknown; conditions are true when non-zero. Operators: ?: | ^ & == != < > <= >=
 * + - * % ! and unary -; functions rise(pin) fall(pin) bus(lsb, …) bit(v, k). Pins read 1/0.
 * Statements run in order at every step (and around each clock edge), the way the built-in models do.
 */
object LogicDsl {
    sealed class Expr {
        class Num(val v: Int) : Expr()
        object Unknown : Expr()
        class Ref(val name: String) : Expr()
        class Un(val op: String, val a: Expr) : Expr()
        class Bin(val op: String, val a: Expr, val b: Expr) : Expr()
        class Cond(val c: Expr, val t: Expr, val f: Expr) : Expr()
        class Call(val fn: String, val args: List<Expr>) : Expr()
    }

    sealed class Stmt {
        class Assign(val target: String, val expr: Expr, val isLet: Boolean) : Stmt()
        class Out(val name: String, val expr: Expr, val oc: Boolean = false) : Stmt()
        class Chain(val branches: MutableList<Pair<Expr?, List<Assign>>>) : Stmt()
    }

    class Def(
        val names: List<String>,
        val pins: List<String>,
        val roles: List<Char>,
        val rest: List<Pair<String, Boolean>>,
        val clocks: List<String>,
        val full: Int,
        val controls: List<String>,
        val state: List<String>,
        val stmts: List<Stmt>,
        val transceiver: Pair<List<Pair<String, Char>>, List<Pair<String, Char>>>? = null,
    ) {
        val key: String get() = names[0]
        val sequential: Boolean get() = state.isNotEmpty() || clocks.isNotEmpty()
    }

    class ParseError(msg: String) : Exception(msg)

    /** Loaded definitions by name (every name of a model maps to it). */
    val defs = LinkedHashMap<String, Def>()

    fun load(text: String): List<String> {
        val errors = ArrayList<String>()
        defs.clear()
        for (d in parse(text, errors)) for (n in d.names) if (n !in defs) defs[n] = d
        return errors
    }

    // MARK: Parsing

    private fun tokenize(s: String): List<String> {
        val out = ArrayList<String>()
        var i = 0
        while (i < s.length) {
            val c = s[i]
            when {
                c.isWhitespace() -> i++
                c.isLetterOrDigit() || c == '/' || c == '_' || c == '\'' || c == '.' -> {
                    val st = i
                    while (i < s.length && (s[i].isLetterOrDigit() || s[i] == '/' || s[i] == '_' || s[i] == '\'' || s[i] == '.')) i++
                    out += s.substring(st, i)
                }
                i + 1 < s.length && s.substring(i, i + 2) in setOf("==", "!=", "<=", ">=") -> { out += s.substring(i, i + 2); i += 2 }
                else -> { out += c.toString(); i++ }
            }
        }
        return out
    }

    private class P(val t: List<String>) {
        var i = 0
        fun peek() = t.getOrNull(i)
        fun next(): String = t.getOrNull(i++) ?: throw ParseError("unexpected end")
        fun expect(s: String) { val n = next(); if (n != s) throw ParseError("expected $s, found $n") }
        fun expr(): Expr = ternary()
        fun ternary(): Expr {
            val c = or()
            if (peek() == "?") { next(); val a = ternary(); expect(":"); val b = ternary(); return Expr.Cond(c, a, b) }
            return c
        }
        fun or(): Expr { var a = xor(); while (peek() == "|") { next(); a = Expr.Bin("|", a, xor()) }; return a }
        fun xor(): Expr { var a = and(); while (peek() == "^") { next(); a = Expr.Bin("^", a, and()) }; return a }
        fun and(): Expr { var a = cmp(); while (peek() == "&") { next(); a = Expr.Bin("&", a, cmp()) }; return a }
        fun cmp(): Expr {
            var a = add()
            while (peek() in setOf("==", "!=", "<", ">", "<=", ">=")) { val op = next(); a = Expr.Bin(op, a, add()) }
            return a
        }
        fun add(): Expr { var a = mul(); while (peek() == "+" || peek() == "-") { val op = next(); a = Expr.Bin(op, a, mul()) }; return a }
        fun mul(): Expr { var a = unary(); while (peek() == "*" || peek() == "%") { val op = next(); a = Expr.Bin(op, a, unary()) }; return a }
        fun unary(): Expr {
            if (peek() == "!") { next(); return Expr.Un("!", unary()) }
            if (peek() == "-") { next(); return Expr.Un("-", unary()) }
            return primary()
        }
        fun primary(): Expr {
            val tk = next()
            if (tk == "(") { val e = expr(); expect(")"); return e }
            if (tk.all { it.isDigit() }) return Expr.Num(tk.toInt())
            if (tk == "Z" || tk == "X") return Expr.Unknown
            if (peek() == "(" && tk in setOf("rise", "fall", "bus", "bit")) {
                next()
                val args = ArrayList<Expr>()
                if (peek() != ")") { args += expr(); while (peek() == ",") { next(); args += expr() } }
                expect(")")
                return Expr.Call(tk, args)
            }
            if (tk.first().isLetterOrDigit() || tk.first() == '/' || tk.first() == '_') return Expr.Ref(tk)
            throw ParseError("unexpected $tk")
        }
    }

    private fun assignments(text: String, isLet: Boolean = false): List<Stmt.Assign> =
        text.split(';').map { it.trim() }.filter { it.isNotEmpty() }.map { a ->
            val eq = a.indexOf('=')
            if (eq <= 0 || a.getOrNull(eq + 1) == '=') throw ParseError("expected assignment in \"$a\"")
            val p = P(tokenize(a.substring(eq + 1)))
            val e = p.expr()
            if (p.peek() != null) throw ParseError("unexpected ${p.peek()} in \"$a\"")
            Stmt.Assign(a.substring(0, eq).trim(), e, isLet)
        }

    private fun expr(text: String): Expr {
        val p = P(tokenize(text))
        val e = p.expr()
        if (p.peek() != null) throw ParseError("unexpected ${p.peek()} in \"$text\"")
        return e
    }

    fun parse(text: String, errors: MutableList<String>): List<Def> {
        val out = ArrayList<Def>()
        var names: List<String>? = null
        var pins = listOf<String>(); var rest = listOf<Pair<String, Boolean>>(); var clocks = listOf<String>()
        var full = 0; var controls = listOf<String>(); var state = listOf<String>(); var stmts = ArrayList<Stmt>(); var bad = false
        var xcvr: Pair<List<Pair<String, Char>>, List<Pair<String, Char>>>? = null
        fun finish() {
            val n = names ?: return
            if (!bad) {
                try { out += build(n, pins, rest, clocks, full, controls, state, stmts, xcvr) } catch (e: ParseError) { errors += "${n[0]}: ${e.message}" }
            }
            names = null
        }
        for ((ln, raw) in text.lines().withIndex()) {
            val line = raw.substringBefore('#').trim()
            if (line.isEmpty()) continue
            val kw = line.substringBefore(' ')
            val rest0 = line.substringAfter(' ', "").trim()
            if (kw == "model") {
                finish()
                names = rest0.split(',').map { it.trim() }.filter { it.isNotEmpty() }
                pins = emptyList(); rest = emptyList(); clocks = emptyList(); full = 0; controls = emptyList(); state = emptyList(); stmts = ArrayList(); bad = false; xcvr = null
                continue
            }
            if (names == null) { errors += "line ${ln + 1}: outside a model"; continue }
            try {
                when (kw) {
                    "pins" -> pins = rest0.split(Regex("\\s+"))
                    "rest" -> rest = rest0.split(Regex("\\s+")).map { val (a, b) = it.split('='); a to (b == "1") }
                    "clocks" -> clocks = rest0.split(Regex("\\s+"))
                    "full" -> full = rest0.toInt()
                    "controls" -> controls = rest0.split(Regex("\\s+"))
                    "transceiver" -> {
                        val sides = rest0.split('|').map { side -> side.trim().split(Regex("\\s+")).map { val (a, b) = it.split('='); a to b[0] } }
                        if (sides.size != 2) throw ParseError("transceiver needs two settings")
                        xcvr = sides[0] to sides[1]
                    }
                    "state" -> state = state + rest0.split(Regex("\\s+"))
                    "let" -> stmts.addAll(assignments(rest0, isLet = true))
                    "out", "oc" -> { val eq = rest0.indexOf('='); stmts += Stmt.Out(rest0.substring(0, eq).trim(), expr(rest0.substring(eq + 1)), kw == "oc") }
                    "when" -> {
                        val d = rest0.indexOf(" do ")
                        if (d < 0) throw ParseError("when without do")
                        stmts += Stmt.Chain(mutableListOf(expr(rest0.substring(0, d)) to assignments(rest0.substring(d + 4))))
                    }
                    "elif", "else" -> {
                        val ch = stmts.lastOrNull() as? Stmt.Chain ?: throw ParseError("$kw without when")
                        if (kw == "else") {
                            if (!rest0.startsWith("do ")) throw ParseError("else without do")
                            ch.branches += null to assignments(rest0.substring(3))
                        } else {
                            val d = rest0.indexOf(" do ")
                            if (d < 0) throw ParseError("elif without do")
                            ch.branches += expr(rest0.substring(0, d)) to assignments(rest0.substring(d + 4))
                        }
                    }
                    else -> stmts.addAll(assignments(line))
                }
            } catch (e: ParseError) { errors += "${names!![0]} line ${ln + 1}: ${e.message}"; bad = true }
            catch (e: Exception) { errors += "${names!![0]} line ${ln + 1}: ${e.message}"; bad = true }
        }
        finish()
        return out
    }

    private fun build(
        names: List<String>, pins: List<String>, rest: List<Pair<String, Boolean>>, clocks: List<String>, full: Int,
        controls: List<String>, state: List<String>, stmts: List<Stmt>,
        xcvr: Pair<List<Pair<String, Char>>, List<Pair<String, Char>>>? = null,
    ): Def {
        if (pins.isEmpty()) throw ParseError("no pins")
        val outs = stmts.filterIsInstance<Stmt.Out>().map { it.name }.toSet()
        val ocs = stmts.filterIsInstance<Stmt.Out>().filter { it.oc }.map { it.name }.toSet()
        // pins read by the logic as well as driven by it are bidirectional
        val read = HashSet<String>()
        fun refs(e: Expr) { when (e) { is Expr.Ref -> read += e.name; is Expr.Un -> refs(e.a); is Expr.Bin -> { refs(e.a); refs(e.b) }; is Expr.Cond -> { refs(e.c); refs(e.t); refs(e.f) }; is Expr.Call -> e.args.forEach { refs(it) }; else -> {} } }
        for (s in stmts) when (s) { is Stmt.Assign -> refs(s.expr); is Stmt.Out -> refs(s.expr); is Stmt.Chain -> for ((c, a) in s.branches) { c?.let { refs(it) }; a.forEach { refs(it.expr) } } }
        val roles = pins.map { p ->
            when (p.uppercase()) {
                "GND", "VSS" -> 'g'
                "VCC", "VDD" -> 'v'
                "NC" -> 'n'
                else -> if (p in outs && p in read) (if (p in ocs) 'y' else 'b') else if (p in ocs) 'z' else if (p in outs) 'o' else 'i'
            }
        }
        val pinSet = pins.toSet()
        val known = HashSet<String>(pins); known += state
        for (o in outs) if (o !in pinSet) throw ParseError("output $o is not a pin")
        for (r in rest) if (r.first !in pinSet) throw ParseError("rest $r.first is not a pin")
        for (c in clocks) if (c !in pinSet) throw ParseError("clock $c is not a pin")
        for (c in controls) if (c !in pinSet) throw ParseError("control $c is not a pin")
        fun check(e: Expr) {
            when (e) {
                is Expr.Ref -> if (e.name !in known) throw ParseError("unknown name ${e.name}")
                is Expr.Un -> check(e.a)
                is Expr.Bin -> { check(e.a); check(e.b) }
                is Expr.Cond -> { check(e.c); check(e.t); check(e.f) }
                is Expr.Call -> {
                    if ((e.fn == "rise" || e.fn == "fall") && (e.args.size != 1 || (e.args[0] as? Expr.Ref)?.name !in pinSet)) throw ParseError("${e.fn} needs a pin")
                    e.args.forEach { check(it) }
                }
                else -> {}
            }
        }
        for (s in stmts) when (s) {
            is Stmt.Assign -> { check(s.expr); if (s.isLet) known += s.target else if (s.target !in state) throw ParseError("${s.target} is not declared as state") }
            is Stmt.Out -> check(s.expr)
            is Stmt.Chain -> for ((c, a) in s.branches) { c?.let { check(it) }; for (x in a) { check(x.expr); if (x.target !in state) throw ParseError("${x.target} is not declared as state") } }
        }
        xcvr?.let { (ab, ba) -> for ((n, _) in ab + ba) if (n !in pinSet) throw ParseError("transceiver control $n is not a pin") }
        return Def(names, pins, roles, rest, clocks, full, controls, state, stmts, xcvr)
    }

    // MARK: Evaluation

    private fun truth(v: Int?): Boolean? = v?.let { it != 0 }
    private fun b(v: Boolean): Int = if (v) 1 else 0

    private fun eval(e: Expr, s: LogicSim, lets: Map<String, Int?>): Int? = when (e) {
        is Expr.Num -> e.v
        Expr.Unknown -> null
        is Expr.Ref -> if (lets.containsKey(e.name)) lets[e.name] else if (s.idx(e.name) != null) s.v(e.name)?.let { b(it) } else s.int("$" + e.name)
        is Expr.Un -> {
            val a = eval(e.a, s, lets)
            if (a == null) null else if (e.op == "!") b(a == 0) else -a
        }
        is Expr.Bin -> {
            val a = eval(e.a, s, lets)
            if (e.op == "&") {
                if (a == 0) 0 else { val c = eval(e.b, s, lets); if (c == 0) 0 else if (a == null || c == null) null else 1 }
            } else if (e.op == "|") {
                if (a != null && a != 0) 1 else { val c = eval(e.b, s, lets); if (c != null && c != 0) 1 else if (a == null || c == null) null else 0 }
            } else {
                val c = eval(e.b, s, lets)
                if (a == null || c == null) null else when (e.op) {
                    "^" -> b((a != 0) != (c != 0))
                    "==" -> b(a == c); "!=" -> b(a != c)
                    "<" -> b(a < c); ">" -> b(a > c); "<=" -> b(a <= c); ">=" -> b(a >= c)
                    "+" -> a + c; "-" -> a - c; "*" -> a * c
                    "%" -> if (c == 0) null else Math.floorMod(a, c)
                    else -> null
                }
            }
        }
        is Expr.Cond -> {
            val c = eval(e.c, s, lets)
            if (c == null) { val t = eval(e.t, s, lets); val f = eval(e.f, s, lets); if (t == f) t else null }
            else if (c != 0) eval(e.t, s, lets) else eval(e.f, s, lets)
        }
        is Expr.Call -> when (e.fn) {
            "rise" -> b(s.rose((e.args[0] as Expr.Ref).name))
            "fall" -> b(s.fell((e.args[0] as Expr.Ref).name))
            "bus" -> {
                var r = 0; var ok = true
                for ((i, a) in e.args.withIndex()) { val v = eval(a, s, lets); if (v == null) { ok = false; break }; if (v != 0) r = r or (1 shl i) }
                if (ok) r else null
            }
            "bit" -> { val v = eval(e.args[0], s, lets); val k = eval(e.args[1], s, lets); if (v == null || k == null) null else (v shr k) and 1 }
            else -> null
        }
    }

    /** One step of the model: state updates and outputs, in the order written. */
    fun step(d: Def, s: LogicSim) {
        val lets = HashMap<String, Int?>()
        for (st in d.stmts) when (st) {
            is Stmt.Assign -> {
                val v = eval(st.expr, s, lets)
                if (st.isLet) lets[st.target] = v else s.setInt("$" + st.target, v)
            }
            is Stmt.Out -> s.o(st.name, truth(eval(st.expr, s, lets)))
            is Stmt.Chain -> {
                var unknown = false
                for ((c, assigns) in st.branches) {
                    if (unknown) { for (a in assigns) s.setInt("$" + a.target, null); continue }
                    val cv = if (c == null) 1 else eval(c, s, lets)
                    if (cv == null) {
                        // condition unknown: whatever these branches would set becomes unknown, unless unchanged
                        for (a in assigns) { val nv = eval(a.expr, s, lets); if (nv == null || nv != s.int("$" + a.target)) s.setInt("$" + a.target, null) }
                        unknown = true
                    } else if (cv != 0) {
                        val vals = assigns.map { eval(it.expr, s, lets) }
                        assigns.forEachIndexed { i, a -> s.setInt("$" + a.target, vals[i]) }
                        break
                    }
                }
            }
        }
    }
}
