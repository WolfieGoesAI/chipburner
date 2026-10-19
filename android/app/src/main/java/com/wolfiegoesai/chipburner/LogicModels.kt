package com.wolfiegoesai.chipburner

/**
 * Working models of common logic chips for the Extended Logic Test (ported from the Mac app's
 * LogicModels.swift): every input combination for combinational chips, and reset / full-cycle /
 * neighbour-pin / random sequences for flip-flops, latches, counters and shift registers.
 * Three-valued logic (true, false, null = unknown) so an output is only checked once its value is certain.
 */
class LogicSim(val names: List<String>) {
    private val index = HashMap<String, Int>().apply { names.forEachIndexed { i, n -> if (n !in this) this[n] = i } }
    var cur: Array<Boolean?> = arrayOfNulls(names.size)
    var prev: Array<Boolean?> = arrayOfNulls(names.size)
    val out = ArrayList<Pair<String, Boolean?>>()
    private val ints = HashMap<String, Int>()
    private val flags = HashMap<String, Boolean>()
    val regs = HashMap<String, List<Boolean?>>()

    fun idx(n: String): Int? = index[n]
    fun v(n: String): Boolean? = index[n]?.let { cur[it] }
    fun rose(n: String): Boolean { val i = index[n] ?: return false; return prev[i] == false && cur[i] == true }
    fun fell(n: String): Boolean { val i = index[n] ?: return false; return prev[i] == true && cur[i] == false }
    fun o(n: String, value: Boolean?) { out += n to value }
    fun flag(k: String): Boolean? = flags[k]
    fun setFlag(k: String, value: Boolean?) { if (value != null) flags[k] = value else flags.remove(k) }
    fun int(k: String): Int? = ints[k]
    fun setInt(k: String, value: Int?) { if (value != null) ints[k] = value else ints.remove(k) }
}

private fun not3(a: Boolean?): Boolean? = a?.let { !it }
private fun and3(vararg xs: Boolean?): Boolean? = and3(xs.toList())
private fun and3(xs: List<Boolean?>): Boolean? = if (xs.any { it == false }) false else if (xs.all { it == true }) true else null
private fun or3(xs: List<Boolean?>): Boolean? = if (xs.any { it == true }) true else if (xs.all { it == false }) false else null
private fun xor3(a: Boolean?, b: Boolean?): Boolean? = if (a == null || b == null) null else a != b
private fun bits(xs: List<Boolean?>): Int? {
    var r = 0
    for ((i, x) in xs.withIndex()) { val b = x ?: return null; if (b) r = r or (1 shl i) }
    return r
}
private fun bit(value: Int?, i: Int): Boolean? = value?.let { (it shr i) and 1 == 1 }

object LogicModels {
    class Model(
        val step: (LogicSim) -> Unit,
        val sequential: Boolean = false,
        val rest: List<Pair<String, Boolean>> = emptyList(),
        val clocks: List<String> = emptyList(),
        val full: Int = 0,
        /** More inputs that change one at a time in the sequence test (see LogicDsl). */
        val controls: List<String> = emptyList(),
        /** A bus transceiver: control levels for A→B and for B→A. */
        val transceiver: Pair<List<Pair<String, Char>>, List<Pair<String, Char>>>? = null,
    )

    val gateOps = mapOf(
        "7400" to "nand", "7410" to "nand", "7420" to "nand", "7430" to "nand", "4011" to "nand", "4093" to "nand",
        "7408" to "and", "7411" to "and", "7421" to "and", "4081" to "and",
        "7402" to "nor", "7427" to "nor", "4001" to "nor", "7432" to "or", "4071" to "or", "7486" to "xor", "4070" to "xor",
        "7404" to "inv", "4049" to "inv", "4050" to "buf",
    )

    private fun gates(names: List<String>, op: String): (LogicSim) -> Unit {
        val outRe = Regex("^[0-9]?Y$")
        val inRe = Regex("^[0-9]?[A-H]$")
        val groups = names.filter { outRe.matches(it) }.map { y ->
            val p = y.dropLast(1)
            y to names.filter { it.length == p.length + 1 && it.startsWith(p) && inRe.matches(it) }
        }
        return { s ->
            for ((y, ins) in groups) {
                val xs = ins.map { s.v(it) }
                val r = when (op) {
                    "nand" -> not3(and3(xs))
                    "and" -> and3(xs)
                    "nor" -> not3(or3(xs))
                    "or" -> or3(xs)
                    "xor" -> xor3(xs.getOrNull(0), xs.getOrNull(1))
                    "inv" -> not3(xs.getOrNull(0))
                    else -> xs.getOrNull(0)
                }
                s.o(y, r)
            }
        }
    }

    private fun tristateBuffers(activeLow: Boolean): (LogicSim) -> Unit = { s ->
        for (k in listOf("1", "2", "3", "4")) {
            val oe = s.v(if (activeLow) "$k/OE" else "${k}OE")
            val en = if (activeLow) not3(oe) else oe
            s.o("${k}Y", if (en == true) s.v("${k}A") else null)
        }
    }

    private val m74138: (LogicSim) -> Unit = { s ->
        val en = and3(s.v("G1"), not3(s.v("/G2A")), not3(s.v("/G2B")))
        val sel = bits(listOf(s.v("A"), s.v("B"), s.v("C")))
        for (n in 0 until 8) s.o("/Y$n", if (en == false) true else if (en == null || sel == null) null else sel != n)
    }

    private val m74139: (LogicSim) -> Unit = { s ->
        for (k in listOf("1", "2")) {
            val en = not3(s.v("$k/G"))
            val sel = bits(listOf(s.v("${k}A"), s.v("${k}B")))
            for (n in 0 until 4) s.o("$k/Y$n", if (en == false) true else if (en == null || sel == null) null else sel != n)
        }
    }

    private val m74151: (LogicSim) -> Unit = { s ->
        val g = s.v("/G"); val sel = bits(listOf(s.v("A"), s.v("B"), s.v("C")))
        val y = if (g == true) false else if (g == null || sel == null) null else s.v("D$sel")
        s.o("Y", y); s.o("/W", not3(y))
    }

    private val m74153: (LogicSim) -> Unit = { s ->
        val sel = bits(listOf(s.v("A"), s.v("B")))
        for (k in listOf("1", "2")) {
            val g = s.v("$k/G")
            s.o("${k}Y", if (g == true) false else if (g == null || sel == null) null else s.v("${k}C$sel"))
        }
    }

    private val m74157: (LogicSim) -> Unit = { s ->
        val g = s.v("/G"); val sel = s.v("S")
        for (k in listOf("1", "2", "3", "4")) {
            s.o("${k}Y", if (g == true) false else if (g == null || sel == null) null else s.v(k + if (sel) "B" else "A"))
        }
    }

    private val m7483: (LogicSim) -> Unit = fn@{ s ->
        val a = bits((1..4).map { s.v("A$it") }); val b = bits((1..4).map { s.v("B$it") }); val c = s.v("C0")
        if (a == null || b == null || c == null) {
            for (i in 1..4) s.o("S$i", null)
            s.o("C4", null); return@fn
        }
        val t = a + b + (if (c) 1 else 0)
        for (i in 1..4) s.o("S$i", (t shr (i - 1)) and 1 == 1)
        s.o("C4", (t shr 4) and 1 == 1)
    }

    private val m7485: (LogicSim) -> Unit = { s ->
        val a = bits((0 until 4).map { s.v("A$it") }); val b = bits((0 until 4).map { s.v("B$it") })
        val gi = s.v("A>Bin"); val ei = s.v("A=Bin"); val li = s.v("A<Bin")
        var g: Boolean? = null; var e: Boolean? = null; var l: Boolean? = null
        if (a != null && b != null) {
            if (a > b) { g = true; e = false; l = false }
            else if (a < b) { g = false; e = false; l = true }
            else if (gi != null && ei != null && li != null) {
                if (ei) { g = false; e = true; l = false }
                else if (gi && !li) { g = true; e = false; l = false }
                else if (li && !gi) { g = false; e = false; l = true }
                else if (gi && li) { g = false; e = false; l = false }
                else { g = true; e = false; l = true }
            }
        }
        s.o("A>Bout", g); s.o("A=Bout", e); s.o("A<Bout", l)
    }

    private fun buffers(inverting: Boolean, enables: List<List<String>>, pairs: List<Triple<Int, String, String>>): (LogicSim) -> Unit = { s ->
        for ((grp, i, o) in pairs) {
            val en = and3(enables[grp].map { not3(s.v(it)) })
            val value = s.v(i)
            s.o(o, if (en == true) (if (inverting) not3(value) else value) else null)
        }
    }

    private val pairs240 = (1..4).map { Triple(0, "1A$it", "1Y$it") } + (1..4).map { Triple(1, "2A$it", "2Y$it") }
    private val pairs541 = (1..8).map { Triple(0, "A$it", "Y$it") }

    private val m74245: (LogicSim) -> Unit = { s ->
        val oe = s.v("/OE"); val d = s.v("DIR")
        for (n in 1..8) {
            val a = "A$n"; val b = "B$n"
            if (oe == false && d == true) { s.o(b, s.v(a)); s.o(a, null) }
            else if (oe == false && d == false) { s.o(a, s.v(b)); s.o(b, null) }
            else { s.o(a, null); s.o(b, null) }
        }
    }

    private val m7474: (LogicSim) -> Unit = { s ->
        for (k in listOf("1", "2")) {
            val pre = s.v("$k/PRE"); val clr = s.v("$k/CLR")
            var q = s.flag(k)
            if (pre == false && clr == false) {
                s.setFlag(k, null); s.o("${k}Q", true); s.o("$k/Q", true); continue
            }
            if (pre == false) q = true
            else if (clr == false) q = false
            else if (pre == null || clr == null) q = null
            else if (s.rose("${k}CLK")) q = s.v("${k}D")
            s.setFlag(k, q)
            s.o("${k}Q", q); s.o("$k/Q", not3(q))
        }
    }

    private fun dRegister(
        n: Int, clock: String?, clear: String?, q: (Int) -> String, d: (Int) -> String,
        notQ: ((Int) -> String)? = null, oe: String? = null, latch: String? = null,
    ): (LogicSim) -> Unit = { s ->
        var r: List<Boolean?> = s.regs["r"] ?: List(n) { null }
        val c: Boolean? = if (clear != null) s.v(clear) else true
        if (c == false) r = List(n) { false }
        else if (c == null) r = List(n) { null }
        else if (latch != null) {
            val l = s.v(latch)
            if (l == true) r = List(n) { s.v(d(it)) }
            else if (l == null) { val old = r; r = List(n) { if (old[it] != s.v(d(it))) null else old[it] } }
        } else if (clock != null && s.rose(clock)) {
            r = List(n) { s.v(d(it)) }
        }
        s.regs["r"] = r
        val en: Boolean? = if (oe != null) not3(s.v(oe)) else true
        for (i in 0 until n) {
            s.o(q(i), if (en == true) r[i] else null)
            if (notQ != null) s.o(notQ(i), not3(r[i]))
        }
    }

    private fun syncCounter(modulus: Int, asyncClear: Boolean): (LogicSim) -> Unit = { s ->
        var c = s.int("c")
        val clr = s.v("/CLR"); val load = s.v("/LOAD"); val enp = s.v("ENP"); val ent = s.v("ENT")
        if (asyncClear && clr == false) c = 0
        else if (asyncClear && clr == null) c = null
        else if (s.rose("CLK")) {
            if (!asyncClear && clr == false) c = 0
            else if (clr == null) c = null
            else if (load == false) c = bits(listOf(s.v("A"), s.v("B"), s.v("C"), s.v("D")))
            else if (load == null) c = null
            else if (enp == true && ent == true) c = c?.let { (it + 1) % modulus }
            else if (enp == null || ent == null) c = null
        }
        if (c != null && c >= modulus) c = null
        s.setInt("c", c)
        listOf("QA", "QB", "QC", "QD").forEachIndexed { i, qn -> s.o(qn, bit(c, i)) }
        if (ent == false) s.o("RCO", false)
        else if (ent == null || c == null) s.o("RCO", null)
        else s.o("RCO", c == modulus - 1)
    }

    private val letters8 = listOf("A", "B", "C", "D", "E", "F", "G", "H")

    private val m74164: (LogicSim) -> Unit = { s ->
        var r: List<Boolean?> = s.regs["r"] ?: List(8) { null }
        if (s.v("/CLR") == false) r = List(8) { false }
        else if (s.v("/CLR") == null) r = List(8) { null }
        else if (s.rose("CLK")) r = listOf(and3(s.v("A"), s.v("B"))) + r.take(7)
        s.regs["r"] = r
        letters8.forEachIndexed { i, l -> s.o("Q$l", r[i]) }
    }

    private val m74165: (LogicSim) -> Unit = { s ->
        var r: List<Boolean?> = s.regs["r"] ?: List(8) { null }
        val ld = s.v("SH/LD")
        if (ld == false) r = letters8.map { s.v(it) }
        else if (ld == null) r = List(8) { null }
        else {
            val edge = (s.rose("CLK") && s.v("CLKINH") == false) || (s.rose("CLKINH") && s.v("CLK") == false)
            if (edge) r = listOf(s.v("SER")) + r.take(7)
        }
        s.regs["r"] = r
        s.o("QH", r[7]); s.o("/QH", not3(r[7]))
    }

    private val m74193: (LogicSim) -> Unit = { s ->
        var c = s.int("c")
        if (s.v("CLR") == true) c = 0
        else if (s.v("CLR") == null) c = null
        else if (s.v("/LOAD") == false) c = bits(listOf(s.v("A"), s.v("B"), s.v("C"), s.v("D")))
        else if (s.v("/LOAD") == null) c = null
        else if (s.rose("UP") && s.v("DOWN") == true) c = c?.let { (it + 1) % 16 }
        else if (s.rose("DOWN") && s.v("UP") == true) c = c?.let { (it + 15) % 16 }
        s.setInt("c", c)
        listOf("QA", "QB", "QC", "QD").forEachIndexed { i, qn -> s.o(qn, bit(c, i)) }
        val up = s.v("UP"); val dn = s.v("DOWN")
        s.o("/CO", if (up == true) true else if (up == null || c == null) null else c != 15)
        s.o("/BO", if (dn == true) true else if (dn == null || c == null) null else c != 0)
    }

    private val m74393: (LogicSim) -> Unit = { s ->
        for (k in listOf("1", "2")) {
            var c = s.int(k)
            val clr = s.v("${k}CLR")
            if (clr == true) c = 0
            else if (clr == null) c = null
            else if (s.fell("${k}A")) c = c?.let { (it + 1) % 16 }
            s.setInt(k, c)
            listOf("A", "B", "C", "D").forEachIndexed { i, l -> s.o("${k}Q$l", bit(c, i)) }
        }
    }

    private val m7490: (LogicSim) -> Unit = { s ->
        var qa = s.flag("a"); var qbd = s.int("b")
        val r0 = and3(s.v("R0(1)"), s.v("R0(2)")); val r9 = and3(s.v("R9(1)"), s.v("R9(2)"))
        if (r9 == true) { qa = true; qbd = 4 }
        else if (r0 == true && r9 == false) { qa = false; qbd = 0 }
        else if (r0 == null || r9 == null) { qa = null; qbd = null }
        else {
            if (s.fell("CKA")) qa = not3(qa)
            if (s.fell("CKB")) qbd = qbd?.let { (it + 1) % 5 }
        }
        s.setFlag("a", qa); s.setInt("b", qbd)
        s.o("QA", qa)
        listOf("QB", "QC", "QD").forEachIndexed { i, qn -> s.o(qn, bit(qbd, i)) }
    }

    private val m7493: (LogicSim) -> Unit = { s ->
        var qa = s.flag("a"); var qb = s.int("b")
        val r0 = and3(s.v("R0(1)"), s.v("R0(2)"))
        if (r0 == true) { qa = false; qb = 0 }
        else if (r0 == null) { qa = null; qb = null }
        else {
            if (s.fell("CKA")) qa = not3(qa)
            if (s.fell("CKB")) qb = qb?.let { (it + 1) % 8 }
        }
        s.setFlag("a", qa); s.setInt("b", qb)
        s.o("QA", qa)
        listOf("QB", "QC", "QD").forEachIndexed { i, qn -> s.o(qn, bit(qb, i)) }
    }

    private val m74595: (LogicSim) -> Unit = { s ->
        var sh: List<Boolean?> = s.regs["s"] ?: List(8) { null }
        var stg: List<Boolean?> = s.regs["t"] ?: List(8) { null }
        if (s.rose("RCLK")) stg = sh
        if (s.v("/SRCLR") == false) sh = List(8) { false }
        else if (s.v("/SRCLR") == null) sh = List(8) { null }
        else if (s.rose("SRCLK")) sh = listOf(s.v("SER")) + sh.take(7)
        s.regs["s"] = sh; s.regs["t"] = stg
        val en = not3(s.v("/OE"))
        letters8.forEachIndexed { i, l -> s.o("Q$l", if (en == true) stg[i] else null) }
        s.o("QH'", sh[7])
    }

    private val m4013: (LogicSim) -> Unit = { s ->
        for (k in listOf("1", "2")) {
            val set = s.v("${k}S"); val reset = s.v("${k}R")
            var q = s.flag(k)
            if (set == true && reset == true) { s.setFlag(k, null); s.o("${k}Q", true); s.o("$k/Q", true); continue }
            if (set == true) q = true
            else if (reset == true) q = false
            else if (set == null || reset == null) q = null
            else if (s.rose("${k}CLK")) q = s.v("${k}D")
            s.setFlag(k, q)
            s.o("${k}Q", q); s.o("$k/Q", not3(q))
        }
    }

    private val m4017: (LogicSim) -> Unit = { s ->
        var c = s.int("c")
        if (s.v("RST") == true) c = 0
        else if (s.v("RST") == null) c = null
        else if ((s.rose("CLK") && s.v("/CE") == false) || (s.fell("/CE") && s.v("CLK") == true)) c = c?.let { (it + 1) % 10 }
        s.setInt("c", c)
        for (n in 0 until 10) s.o("Q$n", c?.let { it == n })
        s.o("CO", c?.let { it < 5 })
    }

    private val m4040: (LogicSim) -> Unit = { s ->
        var c = s.int("c")
        if (s.v("RST") == true) c = 0
        else if (s.v("RST") == null) c = null
        else if (s.fell("CLK")) c = c?.let { (it + 1) % 4096 }
        s.setInt("c", c)
        for (i in 0 until 12) s.o("Q${i + 1}", bit(c, i))
    }

    fun model(chip: String, names: List<String>): Model? {
        gateOps[chip]?.let { return Model(gates(names, it)) }
        val counterRest = listOf("/CLR" to true, "/LOAD" to true, "ENP" to true, "ENT" to true)
        val nq: (Int) -> String = { "${it + 1}Q" }
        val nd: (Int) -> String = { "${it + 1}D" }
        val qn: (Int) -> String = { "Q${it + 1}" }
        val dn: (Int) -> String = { "D${it + 1}" }
        return when (chip) {
            "74125" -> Model(tristateBuffers(true))
            "74126" -> Model(tristateBuffers(false))
            "74138" -> Model(m74138)
            "74139" -> Model(m74139)
            "74151" -> Model(m74151)
            "74153" -> Model(m74153)
            "74157" -> Model(m74157)
            "7483" -> Model(m7483)
            "7485" -> Model(m7485)
            "74240" -> Model(buffers(true, listOf(listOf("1/G"), listOf("2/G")), pairs240))
            "74244" -> Model(buffers(false, listOf(listOf("1/G"), listOf("2/G")), pairs240))
            "74541" -> Model(buffers(false, listOf(listOf("/G1", "/G2")), pairs541))
            "74245" -> Model(m74245)
            "7474" -> Model(m7474, true, listOf("1/PRE" to true, "1/CLR" to true, "2/PRE" to true, "2/CLR" to true), listOf("1CLK", "2CLK"))
            "74174" -> Model(dRegister(6, "CLK", "/CLR", nq, nd), true, listOf("/CLR" to true), listOf("CLK"))
            "74175" -> Model(dRegister(4, "CLK", "/CLR", nq, nd, notQ = { "${it + 1}/Q" }), true, listOf("/CLR" to true), listOf("CLK"))
            "74273" -> Model(dRegister(8, "CLK", "/CLR", nq, nd), true, listOf("/CLR" to true), listOf("CLK"))
            "74374" -> Model(dRegister(8, "CLK", null, nq, nd, oe = "/OE"), true, listOf("/OE" to false), listOf("CLK"))
            "74574" -> Model(dRegister(8, "CLK", null, qn, dn, oe = "/OE"), true, listOf("/OE" to false), listOf("CLK"))
            "74373" -> Model(dRegister(8, null, null, nq, nd, oe = "/OE", latch = "LE"), true, listOf("/OE" to false, "LE" to false))
            "74573" -> Model(dRegister(8, null, null, qn, dn, oe = "/OE", latch = "LE"), true, listOf("/OE" to false, "LE" to false))
            "74161" -> Model(syncCounter(16, true), true, counterRest, listOf("CLK"), 20)
            "74163" -> Model(syncCounter(16, false), true, counterRest, listOf("CLK"), 20)
            "74160" -> Model(syncCounter(10, true), true, counterRest, listOf("CLK"), 14)
            "74162" -> Model(syncCounter(10, false), true, counterRest, listOf("CLK"), 14)
            "74164" -> Model(m74164, true, listOf("/CLR" to true), listOf("CLK"), 12)
            "74165" -> Model(m74165, true, listOf("SH/LD" to true, "CLKINH" to false), listOf("CLK"), 12)
            "74193" -> Model(m74193, true, listOf("CLR" to false, "/LOAD" to true, "UP" to true, "DOWN" to true), listOf("UP", "DOWN"), 20)
            "74393" -> Model(m74393, true, listOf("1CLR" to false, "2CLR" to false), listOf("1A", "2A"), 20)
            "7490" -> Model(m7490, true, listOf("R0(1)" to false, "R0(2)" to false, "R9(1)" to false, "R9(2)" to false), listOf("CKA", "CKB"), 12)
            "7493" -> Model(m7493, true, listOf("R0(1)" to false, "R0(2)" to false), listOf("CKA", "CKB"), 12)
            "74595" -> Model(m74595, true, listOf("/SRCLR" to true, "/OE" to false), listOf("SRCLK", "RCLK"), 12)
            "4013" -> Model(m4013, true, listOf("1S" to false, "1R" to false, "2S" to false, "2R" to false), listOf("1CLK", "2CLK"))
            "4017" -> Model(m4017, true, listOf("RST" to false, "/CE" to false), listOf("CLK"), 24)
            "4040" -> Model(m4040, true, listOf("RST" to false), listOf("CLK"), 4100)
            else -> LogicDsl.defs[chip]?.takeIf { it.pins == names }?.let { d ->
                Model({ LogicDsl.step(d, it) }, d.sequential, d.rest, d.clocks, d.full, d.controls, d.transceiver)
            }
        }
    }

    /** The model's outputs per vector, the way minipro applies it: pins set, then each C pin pulsed high and low. */
    fun simulate(model: Model, names: List<String>, vectors: List<String>): List<Map<Int, Boolean>> {
        val s = LogicSim(names)
        val level = BooleanArray(names.size)
        val results = ArrayList<Map<Int, Boolean>>()
        for (vec in vectors) {
            val stage0 = arrayOfNulls<Boolean>(names.size)
            val clockPins = ArrayList<Int>()
            for ((i, c) in vec.withIndex()) {
                if (i >= names.size) break
                when (c) {
                    '0' -> stage0[i] = false
                    '1' -> stage0[i] = true
                    'C' -> { stage0[i] = level[i]; clockPins += i }
                    else -> stage0[i] = null
                }
            }
            val stages = ArrayList<Array<Boolean?>>()
            stages += stage0
            if (clockPins.isNotEmpty()) {
                val s1 = stage0.copyOf(); val s2 = stage0.copyOf()
                for (i in clockPins) { s1[i] = true; s2[i] = false }
                stages += s1; stages += s2
            }
            for (st in stages) {
                s.prev = s.cur
                s.cur = st
                s.out.clear()
                model.step(s)
            }
            for ((i, c) in vec.withIndex()) {
                if (i >= names.size) break
                if (c == '0' || c == '1') level[i] = c == '1' else if (c == 'C') level[i] = false
            }
            val r = HashMap<Int, Boolean>()
            for ((n, value) in s.out) { val i = s.idx(n); if (i != null && value != null) r[i] = value }
            results += r
        }
        return results
    }

    class Extended(val vectors: List<String>, val checks: Int, val description: String, val phases: List<Pair<String, IntRange>>) {
        fun phaseOf(i: Int): String = phases.firstOrNull { i in it.second }?.first ?: "step $i"
    }

    private class LCG(var x: ULong) {
        fun next(): ULong { x = x * 6364136223846793005uL + 1442695040888963407uL; return x shr 33 }
        fun chance(p: Double): Boolean = (next() % 1000uL).toDouble() < p * 1000
    }

    /** Model key, data-sheet pin names and roles for a logic chip, if a model covers it (group members share it). */
    fun pins(chip: String, group: ChipDb.LogicGroup): Triple<String, List<String>, List<Char>>? {
        for (m in listOf(chip) + group.names) {
            val base = Pinouts.logicBase(m)
            val key = if (Pinouts.logicNames.containsKey(base)) base else m
            val entry = Pinouts.logicNames[key] ?: continue
            val items = entry.second.split(' ')
            if (items.size != group.pins) continue
            val names = items.map { it.substringAfter(':') }
            val roles = items.map { it.first() }
            if (model(key, names) != null) return Triple(key, names, roles)
        }
        // models from logic-models.txt
        for (m in listOf(chip) + group.names) {
            val base = Pinouts.logicBase(m)
            val d = LogicDsl.defs[m] ?: LogicDsl.defs[base] ?: continue
            if (d.pins.size != group.pins) continue
            if (model(d.key, d.pins) != null) return Triple(d.key, d.pins, d.roles)
        }
        return null
    }

    fun extended(chip: String, names: List<String>, roles: List<Char>): Extended? {
        val model = model(chip, names) ?: return null
        if (names.size != roles.size) return null
        val base = roles.map { if (it == 'g') 'G' else if (it == 'v') 'V' else 'X' }
        val inputs = roles.indices.filter { roles[it] == 'i' }
        val vecs = ArrayList<CharArray>()
        val phases = ArrayList<Pair<String, IntRange>>()
        fun phase(name: String, body: () -> Unit) {
            val start = vecs.size
            body()
            if (vecs.size > start) phases += name to (start until vecs.size)
        }
        val description: String
        val xcvr = model.transceiver ?: if (chip == "74245") (listOf("DIR" to '1', "/OE" to '0') to listOf("DIR" to '0', "/OE" to '0')) else null
        if (xcvr != null) {
            val width = (1..32).takeWhile { "A$it" in names && "B$it" in names }.size
            val count = 1 shl width
            fun mk(set: List<Pair<String, Char>>, side: String, value: Int): CharArray {
                val v = base.toCharArray()
                for ((n, c) in set) names.indexOf(n).takeIf { it >= 0 }?.let { v[it] = c }
                for (k in 0 until width) names.indexOf("$side${k + 1}").takeIf { it >= 0 }?.let { v[it] = if ((value shr k) and 1 == 1) '1' else '0' }
                return v
            }
            phase("A→B, all $count patterns") { for (value in 0 until count) vecs += mk(xcvr.first, "A", value) }
            phase("B→A, all $count patterns") { for (value in 0 until count) vecs += mk(xcvr.second, "B", value) }
            description = "all $count patterns A→B and all $count B→A (neighbour-pin patterns included)"
        } else if (!model.sequential && inputs.size > 12) {
            // too many inputs for every combination: neighbour-pin patterns and 2048 random combinations
            val rng = LCG(0x5EEDuL xor chip.sumOf { it.code }.toULong())
            fun pat(f: (Int) -> Boolean): CharArray { val v = base.toCharArray(); for (i in inputs) v[i] = if (f(i)) '1' else '0'; return v }
            phase("neighbour-pin patterns") {
                vecs += pat { false }; vecs += pat { true }
                vecs += pat { it % 2 == 0 }; vecs += pat { it % 2 == 1 }
                for (k in inputs) vecs += pat { it == k }
                for (k in inputs) vecs += pat { it != k }
            }
            phase("random combinations") { repeat(2048) { vecs += pat { rng.chance(0.5) } } }
            description = "neighbour-pin patterns and 2048 random combinations of the ${inputs.size} inputs"
        } else if (!model.sequential) {
            phase("input combinations") {
                for (k in 0 until (1 shl inputs.size)) {
                    val v = base.toCharArray()
                    inputs.forEachIndexed { j, i -> v[i] = if ((k shr j) and 1 == 1) '1' else '0' }
                    vecs += v
                }
            }
            description = "every one of the ${1 shl inputs.size} input combinations (neighbour-pin patterns included)"
        } else {
            val rest = model.rest; val clocks = model.clocks
            val restMap = HashMap<String, Boolean>().apply { for ((k, v) in rest) if (k !in this) this[k] = v }
            val rng = LCG(0x5EEDuL xor chip.sumOf { it.code }.toULong())
            fun vec(over: List<Pair<String, Char>> = emptyList(), clock: String? = null, random: Boolean = false): CharArray {
                val v = base.toCharArray()
                for (i in inputs) {
                    val nm = names[i]
                    if (nm in clocks) v[i] = if (nm == clock) 'C' else if (restMap[nm] == true) '1' else '0'
                    else if (restMap.containsKey(nm)) v[i] = if (restMap[nm] == true) '1' else '0'
                    else v[i] = if (random) (if (rng.chance(0.5)) '1' else '0') else '0'
                }
                for ((nm, value) in over) names.indexOf(nm).takeIf { it >= 0 }?.let { v[it] = value }
                return v
            }
            phase("resets and controls") {
                for ((nm, value) in rest) {
                    vecs += vec(listOf(nm to if (value) '0' else '1'), random = true)
                    vecs += vec(random = true)
                }
                for (c in clocks) vecs += vec(clock = c, random = true)
            }
            phase("full ${model.full}-pulse cycle") {
                for (c in clocks) repeat(model.full) { vecs += vec(clock = c, random = true) }
            }
            phase("neighbour-pin patterns") {
                fun pat(f: (Int) -> Boolean): CharArray {
                    val v = base.toCharArray()
                    for (i in inputs) v[i] = if (f(i)) '1' else '0'
                    return v
                }
                vecs += pat { it % 2 == 0 }
                vecs += pat { it % 2 == 1 }
                for (k in inputs) vecs += pat { it == k }
                for (k in inputs) vecs += pat { it != k }
            }
            phase("random steps") {
                repeat(512) {
                    val over = ArrayList<Pair<String, Char>>()
                    for ((nm, value) in rest) if (rng.chance(0.08)) over += nm to if (value) '0' else '1'
                    var clk: String? = null
                    if (clocks.isNotEmpty() && rng.chance(0.6)) clk = clocks[(rng.next() % clocks.size.toULong()).toInt()]
                    if ((chip == "74373" || chip == "74573") && rng.chance(0.3)) over += "LE" to '1'
                    vecs += vec(over, clk, true)
                }
            }
            val parts = mutableListOf("resets and controls")
            if (model.full > 0) parts += "a full ${model.full}-pulse cycle"
            parts += listOf("neighbour-pin patterns", "512 random steps")
            description = parts.joinToString(", ")
            // The TL866A sets a step's pins one after another (pin 1 first), so a step that changes data and a
            // control, clock level or latch enable together races: data on pins below the control arrives before
            // it, data above after it. Split such steps: data first, then each control on its own, then the step.
            // A step with a clock pulse changes nothing else, so every level is set up before the edge.
            val ctrl = inputs.filter { names[it] in restMap || names[it] in clocks || names[it] in model.controls }.toSet()
            val split = ArrayList<CharArray>()
            val newStart = IntArray(vecs.size + 1)
            for ((n, v) in vecs.withIndex()) {
                newStart[n] = split.size
                if (n > 0) {
                    val cur = vecs[n - 1].map { if (it == 'C') '0' else it }.toCharArray()
                    val data = inputs.filter { it !in ctrl && cur[it] != v[it] }
                    val controls = inputs.filter { it in ctrl && v[it] != 'C' && cur[it] != v[it] }
                    // a clock pulse gets a step of its own, after every other change (setup time)
                    val pulse = inputs.any { v[it] == 'C' } && (data.isNotEmpty() || controls.isNotEmpty())
                    if (pulse || (data.isNotEmpty() && controls.isNotEmpty()) || controls.size > 1) {
                        if (data.isNotEmpty()) { for (i in data) cur[i] = v[i]; split += cur.copyOf() }
                        for (i in if (pulse) controls else controls.dropLast(1)) { cur[i] = v[i]; split += cur.copyOf() }
                    }
                }
                split += v
            }
            newStart[vecs.size] = split.size
            val remapped = phases.map { (nm, r) -> nm to (newStart[r.first] until newStart[r.last + 1]) }
            vecs.clear(); vecs += split
            phases.clear(); phases += remapped
        }
        val strs = vecs.map { String(it) }
        val res = simulate(model, names, strs)
        var checks = 0
        val out = strs.zip(res).map { (v, r) ->
            val w = v.toCharArray()
            for ((i, value) in r) if ((roles[i] == 'o' || roles[i] == 'b' || roles[i] == 'z' || roles[i] == 'y') && w[i] == 'X') {
                w[i] = if (roles[i] == 'z' || roles[i] == 'y') (if (value) 'Z' else 'L') else if (value) 'H' else 'L'; checks++
            }
            String(w)
        }
        return Extended(out, checks, description, phases)
    }

    /** FNV-1a over the vectors (matches the Mac build's reference fingerprints). */
    fun fingerprint(vectors: List<String>): ULong {
        var h = 0xcbf29ce484222325uL
        for (v in vectors) {
            for (c in v.toByteArray(Charsets.UTF_8)) h = (h xor (c.toInt() and 0xFF).toULong()) * 0x100000001b3uL
            h = (h xor 10uL) * 0x100000001b3uL
        }
        return h
    }
}
