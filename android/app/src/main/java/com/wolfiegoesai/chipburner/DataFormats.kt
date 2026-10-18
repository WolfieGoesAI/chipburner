package com.wolfiegoesai.chipburner

import java.io.ByteArrayOutputStream
import java.util.zip.CRC32

/** Binary and Intel HEX files for the buffer. */
object DataFormats {
    fun looksLikeIntelHex(name: String, data: ByteArray): Boolean {
        val ext = name.substringAfterLast('.', "").lowercase()
        if (ext in setOf("hex", "ihx", "ihex")) return true
        if (ext in setOf("bin", "rom", "img")) return false
        val head = String(data, 0, minOf(64, data.size), Charsets.ISO_8859_1).trim()
        return head.startsWith(":") && head.drop(1).take(8).all { it.isDigit() || it.uppercaseChar() in 'A'..'F' }
    }

    /** Parses Intel HEX into a flat image; gaps are filled with FF. */
    fun parseIntelHex(text: String): ByteArray {
        val bytes = HashMap<Long, Byte>()
        var base = 0L
        var maxAddr = -1L
        for ((lineNo, raw) in text.lines().withIndex()) {
            val line = raw.trim()
            if (line.isEmpty()) continue
            require(line.startsWith(":")) { "Line ${lineNo + 1} doesn't start with ':'" }
            val rec = ByteArray((line.length - 1) / 2) { i -> line.substring(1 + i * 2, 3 + i * 2).toInt(16).toByte() }
            require(rec.size >= 5) { "Line ${lineNo + 1} is too short" }
            val len = rec[0].toInt() and 0xFF
            require(rec.size >= len + 5) { "Line ${lineNo + 1} is too short" }
            val addr = ((rec[1].toInt() and 0xFF) shl 8) or (rec[2].toInt() and 0xFF)
            when (rec[3].toInt() and 0xFF) {
                0 -> for (i in 0 until len) {
                    val a = base + addr + i
                    bytes[a] = rec[4 + i]
                    if (a > maxAddr) maxAddr = a
                }
                1 -> break
                2 -> base = ((((rec[4].toInt() and 0xFF) shl 8) or (rec[5].toInt() and 0xFF)).toLong()) shl 4
                4 -> base = ((((rec[4].toInt() and 0xFF) shl 8) or (rec[5].toInt() and 0xFF)).toLong()) shl 16
                else -> {}
            }
        }
        require(maxAddr < 64L * 1024 * 1024) { "The file's addresses go beyond 64 MB" }
        val out = ByteArray((maxAddr + 1).toInt()) { 0xFF.toByte() }
        for ((a, b) in bytes) out[a.toInt()] = b
        return out
    }

    fun toIntelHex(data: ByteArray): String {
        val sb = StringBuilder()
        var upper = -1
        var i = 0
        while (i < data.size) {
            val hi = i ushr 16
            if (hi != upper) {
                upper = hi
                sb.append(record(0, 4, byteArrayOf((hi shr 8).toByte(), hi.toByte())))
            }
            val n = minOf(16, data.size - i, 0x10000 - (i and 0xFFFF))
            sb.append(record(i and 0xFFFF, 0, data.copyOfRange(i, i + n)))
            i += n
        }
        sb.append(":00000001FF\n")
        return sb.toString()
    }

    private fun record(addr: Int, type: Int, payload: ByteArray): String {
        val rec = ByteArrayOutputStream()
        rec.write(payload.size); rec.write(addr shr 8); rec.write(addr and 0xFF); rec.write(type)
        rec.write(payload)
        val b = rec.toByteArray()
        val sum = (0x100 - (b.sumOf { it.toInt() and 0xFF } and 0xFF)) and 0xFF
        return ":" + (b.joinToString("") { "%02X".format(it.toInt() and 0xFF) }) + "%02X".format(sum) + "\n"
    }

    fun crc32(data: ByteArray): Long = CRC32().apply { update(data) }.value
    fun sum16(data: ByteArray): Int = data.sumOf { it.toInt() and 0xFF } and 0xFFFF
}
