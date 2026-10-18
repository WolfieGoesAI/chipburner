package com.wolfiegoesai.chipburner

/** Test patterns and result analysis for the SRAM test and the EPROM/EEPROM/flash health check (ported from the Mac app). */
object ChipTests {
    enum class Pattern(val label: String, val addressBits: IntRange? = null) {
        ZEROS("all 00"), ONES("all FF"), X55("55 (01010101)"), XAA("AA (10101010)"), CHECKER("checkerboard 55/AA"),
        ADDRESS_LOW("address A0–A7 pattern", 0..7), ADDRESS_HIGH("address A8–A15 pattern", 8..15), ADDRESS_TOP("address A16–A23 pattern", 16..23);

        fun byte(a: Int): Byte = when (this) {
            ZEROS -> 0x00
            ONES -> 0xFF.toByte()
            X55 -> 0x55
            XAA -> 0xAA.toByte()
            CHECKER -> if (a and 1 == 0) 0x55 else 0xAA.toByte()
            ADDRESS_LOW -> a.toByte()
            ADDRESS_HIGH -> (a shr 8).toByte()
            ADDRESS_TOP -> (a shr 16).toByte()
        }

        fun data(count: Int) = ByteArray(count) { byte(it) }

        companion object {
            fun addressPatterns(size: Int): List<Pattern> {
                val p = mutableListOf(ADDRESS_LOW)
                if (size > 0x100) p += ADDRESS_HIGH
                if (size > 0x10000) p += ADDRESS_TOP
                return p
            }
        }
    }

    data class Mismatch(val address: Int, val expected: Int, val got: Int)

    class CompareResult {
        var badBytes = 0
        var badBits = 0
        val samples = ArrayList<Mismatch>()
        val addressLineSuspects = ArrayList<Int>()
        var sizeMismatch = false
        val ok: Boolean get() = badBytes == 0 && !sizeMismatch
    }

    fun compare(expected: ByteArray, got: ByteArray, pattern: Pattern?, maxSamples: Int = 12): CompareResult {
        val r = CompareResult()
        if (expected.size != got.size) r.sizeMismatch = true
        val n = minOf(expected.size, got.size)
        if (n == 0) return r
        val failing = ArrayList<Int>()
        for (i in 0 until n) {
            val e = expected[i].toInt() and 0xFF
            val g = got[i].toInt() and 0xFF
            if (e != g) {
                r.badBytes++
                r.badBits = r.badBits or (e xor g)
                if (r.samples.size < maxSamples) r.samples += Mismatch(i, e, g)
                if (failing.size < 200_000) failing += i
            }
        }
        // Address-line check: a failing byte holding the value of the address one bit away.
        val range = pattern?.addressBits
        if (pattern != null && range != null && failing.isNotEmpty()) {
            var bits = 0
            while ((1 shl bits) < n) bits++
            for (k in range) {
                if (k >= bits) continue
                var hits = 0
                for (a in failing) {
                    val b = a xor (1 shl k)
                    if (b < n && got[a] == pattern.byte(b)) hits++
                }
                if (hits >= maxOf(4, n / 8)) r.addressLineSuspects += k
            }
        }
        return r
    }

    class StabilityResult {
        var unstableBytes = 0
        var unstableBits = 0
        val samples = ArrayList<Pair<Int, List<Int>>>()
        val ok: Boolean get() = unstableBytes == 0
    }

    fun stability(reads: List<ByteArray>, maxSamples: Int = 12): StabilityResult {
        val r = StabilityResult()
        if (reads.isEmpty()) return r
        val n = reads.minOf { it.size }
        for (i in 0 until n) {
            val v0 = reads[0][i].toInt() and 0xFF
            var diff = 0
            for (k in 1 until reads.size) diff = diff or ((reads[k][i].toInt() and 0xFF) xor v0)
            if (diff != 0) {
                r.unstableBytes++
                r.unstableBits = r.unstableBits or diff
                if (r.samples.size < maxSamples) r.samples += i to reads.map { it[i].toInt() and 0xFF }
            }
        }
        return r
    }

    class ContentReport {
        var size = 0
        var blank = false
        var ffBytes = 0
        var zeroBytes = 0
        var alwaysOne = 0
        var alwaysZero = 0
        var repeatsEvery: Int? = null
    }

    fun analyse(b: ByteArray): ContentReport {
        val r = ContentReport()
        r.size = b.size
        if (b.isEmpty()) return r
        var andAll = 0xFF
        var orAll = 0
        for (x in b) {
            val v = x.toInt() and 0xFF
            andAll = andAll and v; orAll = orAll or v
            if (v == 0xFF) r.ffBytes++ else if (v == 0) r.zeroBytes++
        }
        r.blank = r.ffBytes == b.size
        r.alwaysOne = andAll
        r.alwaysZero = orAll.inv() and 0xFF
        if (!r.blank && r.zeroBytes != b.size) {
            var period = 256
            while (period < b.size) {
                var same = true
                var i = 0
                while (i + period < b.size) { if (b[i] != b[i + period]) { same = false; break }; i++ }
                if (same) { r.repeatsEvery = period; break }
                period = period shl 1
            }
        }
        return r
    }

    fun bitList(mask: Int) = (0 until 8).filter { mask and (1 shl it) != 0 }.joinToString(", ") { "D$it" }

    fun hints(r: ContentReport): List<String> {
        if (r.size == 0) return listOf("Nothing was read.")
        if (r.blank) return listOf("The chip is blank (every byte is FF) – erased or never programmed.")
        if (r.zeroBytes == r.size) return listOf("Every byte reads 00. That usually means the chip isn't seated properly, is in the wrong way round, or the wrong chip type is selected.")
        val out = ArrayList<String>()
        out += "%.1f%% of the bytes are FF (unprogrammed).".format(r.ffBytes * 100.0 / r.size)
        if (r.alwaysOne != 0) out += "Bit ${bitList(r.alwaysOne)} is 1 in every byte. Possible with some data, but it can also mean a broken data line or a bad pin contact."
        if (r.alwaysZero != 0) {
            val only7 = r.alwaysZero == 0x80
            out += "Bit ${bitList(r.alwaysZero)} is 0 in every byte." + if (only7) " Normal for 7-bit data such as character ROMs; otherwise check D7's pin." else " This can mean a broken data line or a bad pin contact."
        }
        r.repeatsEvery?.let { p ->
            var k = 0
            while ((1 shl k) < p) k++
            val sz = if (p / 1024 > 0) "${p / 1024} KB" else "$p bytes"
            out += "The contents repeat every $sz: address line A$k and above make no difference. Either the image is a smaller one repeated (common), or A$k isn't working."
        }
        return out
    }
}
