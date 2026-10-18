package com.wolfiegoesai.chipburner

import java.io.File

/** What the app needs to know about a chip from minipro's infoic.xml / logicic.xml. */
data class ChipInfo(
    val name: String,
    val kind: Kind,
    val chipId: Long,
    val codeSize: Int,
    val dataSize: Int,
    val flags: Long,
    val hasFlags: Boolean,
    val database: String,
    val pins: Int = 0,
    val group: String = "",
) {
    enum class Kind(val label: String) {
        UNKNOWN("Unknown type"), MEMORY("Memory"), MCU("Microcontroller"), PLD("PLD/GAL"), SRAM("SRAM"),
        LOGIC("Logic IC"), NAND("NAND flash"), EMMC("eMMC/SD"), VIDEO("VGA/HDMI");

        companion object {
            fun of(type: Int) = values().getOrElse(type) { UNKNOWN }
        }
    }

    val canErase: Boolean? get() = if (hasFlags) (flags and 0x10L) != 0L else null
    val packageSuffix: String get() = name.substringAfter('@', "").let { if (it.isEmpty()) "" else "@$it" }

    /** "UV EPROM · 32 KB · ID 0x0110" */
    val summary: String
        get() {
            val parts = mutableListOf<String>()
            parts += when {
                kind == Kind.LOGIC -> "Logic IC" + if (pins > 0) " · $pins pins" else ""
                kind == Kind.MEMORY && Chips.isUVEPROM(name) -> "UV EPROM"
                kind == Kind.MEMORY && Chips.isEEPROM(name) -> "EEPROM"
                kind == Kind.MEMORY -> "Memory"
                else -> kind.label
            }
            if (codeSize > 0) parts += Chips.sizeText(codeSize)
            if (dataSize > 0) parts += "+ " + Chips.sizeText(dataSize) + " data"
            if (chipId != 0L) parts += "ID 0x" + chipId.toString(16).uppercase().padStart(4, '0')
            return parts.joinToString(" · ")
        }
}

object Chips {
    fun isUVEPROM(name: String): Boolean {
        val n = name.uppercase()
        if (Regex("27(SF|EE|LV0|BV)").containsMatchIn(n)) return false
        if (n.startsWith("W27")) return false
        return Regex("^[A-Z]{0,4}27C?[0-9]{2,4}").containsMatchIn(n)
    }

    fun isEEPROM(name: String) = Regex("^[A-Z]{0,4}28(C|HC|LV|F)?[0-9]{2,4}").containsMatchIn(name.uppercase())

    fun sizeText(n: Int): String = when {
        n >= 1 shl 20 && n % (1 shl 20) == 0 -> "${n shr 20} MB"
        n >= 1024 && n % 1024 == 0 -> "${n / 1024} KB"
        else -> "$n bytes"
    }

    /** The chip ID from minipro's output ("Chip ID: 0x0110  OK", or "expected 0x0110, got 0x208D"). */
    fun parseChipId(output: String): Long? {
        val hex = Regex("0x([0-9A-Fa-f]+)")
        for (line in output.lines().filter { it.contains("id", ignoreCase = true) }.reversed()) {
            val ms = hex.findAll(line).toList()
            if (ms.isEmpty()) continue
            val got = line.indexOf("got", ignoreCase = true)
            if (got >= 0) ms.firstOrNull { it.range.first > got }?.let { return it.groupValues[1].toLongOrNull(16) }
            return ms.last().groupValues[1].toLongOrNull(16)
        }
        return null
    }

    /** Vector rows minipro marked with "-" (a pin in the wrong state); empty when the test passed. */
    fun failingVectorLines(output: String): List<String> {
        val lines = output.lines()
        if (lines.any { it.contains("Logic test successful") }) return emptyList()
        val row = Regex("^[0-9]{4}:")
        return lines.filter { line ->
            val t = line.trim()
            row.containsMatchIn(t) && t.drop(5).split(' ').any { it.length == 2 && it.endsWith("-") && it[0] in "01HLZXCGV" }
        }
    }
}

/** The chip database, read once from the copied XML files (a line-by-line scan: the files are large). */
class ChipDb(private val infoic: File, private val logicic: File) {
    private val byName = HashMap<String, MutableList<ChipInfo>>()
    val all = ArrayList<ChipInfo>()
    @Volatile var loaded = false
        private set

    fun load() {
        if (infoic.exists()) scan(infoic, isLogic = false)
        if (logicic.exists()) scan(logicic, isLogic = true)
        loaded = true
    }

    private val attrRe = Regex("([A-Za-z_][A-Za-z0-9_]*)\\s*=\\s*\"([^\"]*)\"")

    private fun hex(s: String?): Long {
        val t = s?.trim() ?: return 0
        if (t.isEmpty()) return 0
        return if (t.startsWith("0x") || t.startsWith("0X")) t.substring(2).toLongOrNull(16) ?: 0 else t.toLongOrNull() ?: 0
    }

    private fun scan(file: File, isLogic: Boolean) {
        var database = if (isLogic) "LOGIC" else ""
        var inComment = false
        val tag = StringBuilder()
        var collecting = false
        file.bufferedReader().useLines { lines ->
            for (raw in lines) {
                var line = raw
                // drop comments (they can span lines and may contain anything)
                while (true) {
                    if (inComment) {
                        val end = line.indexOf("-->")
                        if (end < 0) { line = ""; break }
                        line = line.substring(end + 3); inComment = false
                    }
                    val start = line.indexOf("<!--")
                    if (start < 0) break
                    val end = line.indexOf("-->", start + 4)
                    if (end < 0) { line = line.substring(0, start); inComment = true; break }
                    line = line.substring(0, start) + line.substring(end + 3)
                }
                // tags of interest: <database …> and <ic …>; attributes may run over several lines,
                // and several tags may share a line
                while (line.isNotEmpty()) {
                    if (!collecting) {
                        val start = tagStart.find(line) ?: break
                        collecting = true
                        tag.setLength(0)
                        line = line.substring(start.range.first)
                    }
                    val close = line.indexOf('>')
                    if (close < 0) {
                        tag.append(line).append(' ')
                        break
                    }
                    tag.append(line, 0, close)
                    line = line.substring(close + 1)
                    collecting = false
                    val text = tag.toString()
                    if (text.startsWith("<database")) {
                        attrRe.findAll(text).firstOrNull { it.groupValues[1] == "type" }?.let { database = it.groupValues[2] }
                    } else {
                        addEntry(text, if (isLogic) "LOGIC" else database, isLogic)
                    }
                }
            }
        }
    }

    private val tagStart = Regex("<(database|ic)(\\s|$)")

    private fun addEntry(tag: String, database: String, isLogic: Boolean) {
        val a = HashMap<String, String>()
        for (m in attrRe.findAll(tag)) a[m.groupValues[1]] = m.groupValues[2]
        val names = a["name"] ?: return
        val kind = if (isLogic) ChipInfo.Kind.LOGIC else ChipInfo.Kind.of(a["type"]?.trim()?.toIntOrNull() ?: 0)
        for (n in names.split(',')) {
            val name = n.trim()
            if (name.isEmpty()) continue
            val info = ChipInfo(
                name = name, kind = kind, chipId = hex(a["chip_id"]),
                codeSize = hex(a["code_memory_size"]).toInt(), dataSize = hex(a["data_memory_size"]).toInt(),
                flags = hex(a["flags"]), hasFlags = a.containsKey("flags"), database = database,
                pins = a["pins"]?.toIntOrNull() ?: 0, group = if (isLogic) names else "",
            )
            all += info
            byName.getOrPut(name.uppercase()) { mutableListOf() } += info
        }
    }

    private fun dbName(programmer: String) = when (programmer) {
        "TL866II", "T48" -> "INFOIC2PLUS"
        else -> "INFOIC"
    }

    fun info(name: String, programmer: String): ChipInfo? {
        val list = byName[name.uppercase()] ?: return null
        return list.firstOrNull { it.database == dbName(programmer) } ?: list.firstOrNull { it.database == "LOGIC" } ?: list.first()
    }

    fun search(query: String, programmer: String, kind: ChipInfo.Kind?, dipOnly: Boolean, limit: Int = 300): List<ChipInfo> {
        val q = query.trim().uppercase()
        if (q.length < 2 || !loaded) return emptyList()
        val db = dbName(programmer)
        val seen = HashSet<String>()
        val out = ArrayList<ChipInfo>()
        for (c in all) {
            if (c.database != db && c.database != "LOGIC") continue
            if (kind != null && c.kind != kind) continue
            val up = c.name.uppercase()
            if (!up.contains(q)) continue
            if (dipOnly && c.kind != ChipInfo.Kind.LOGIC && !(up.contains("@DIP") || !up.contains('@'))) continue
            if (!seen.add(up)) continue
            out += c
            if (out.size >= limit) break
        }
        // names starting with the query first, then ones with a maker prefix (e.g. AM27C256 for 27C256)
        val near = Regex("^[A-Z]{0,4}" + Regex.escape(q))
        fun rank(c: ChipInfo): Int {
            val up = c.name.uppercase()
            return if (up.startsWith(q)) 0 else if (near.containsMatchIn(up)) 1 else 2
        }
        return out.sortedWith(compareBy<ChipInfo>({ rank(it) }, { it.name.length }, { it.name }))
    }

    fun withId(id: Long, programmer: String, packageSuffix: String): List<ChipInfo> {
        if (id == 0L) return emptyList()
        val db = dbName(programmer)
        return all.filter { it.chipId == id && it.database == db && (packageSuffix.isEmpty() || it.packageSuffix.equals(packageSuffix, ignoreCase = true)) }
            .distinctBy { it.name }
    }
}
