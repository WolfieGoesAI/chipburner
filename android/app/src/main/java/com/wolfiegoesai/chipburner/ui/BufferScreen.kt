package com.wolfiegoesai.chipburner.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.wolfiegoesai.chipburner.AppState
import com.wolfiegoesai.chipburner.DataFormats
import com.wolfiegoesai.chipburner.R

private const val PER_ROW = 8

@Composable
fun BufferScreen(state: AppState, files: FileActions) {
    var dialog by remember { mutableStateOf<String?>(null) }
    var lastFind by remember { mutableStateOf("") }
    val b = state.buffer
    val listState = rememberLazyListState()
    val digits = if (b.size > 0x10000) 6 else 4

    LaunchedEffect(state.cursor) {
        val row = state.cursor / PER_ROW
        val visible = listState.layoutInfo.visibleItemsInfo
        if (visible.isEmpty() || row < visible.first().index || row > visible.last().index) listState.scrollToItem(maxOf(0, row - 3))
    }

    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 8.dp, top = 12.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(state.bufferName.ifEmpty { "Buffer" }, fontFamily = Sans, fontSize = 20.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(
                    if (b.isEmpty()) "Empty" else "%,d bytes · CRC32 0x%08X".format(b.size, DataFormats.crc32(b)),
                    fontFamily = Mono, fontSize = 12.sp, color = C.text2,
                )
            }
            IconButton(onClick = { state.undoEdit() }, enabled = state.canUndo) { Icon(painterResource(R.drawable.ic_undo), "Undo", tint = if (state.canUndo) C.text else C.text3, modifier = Modifier.size(20.dp)) }
            IconButton(onClick = files.open) { Icon(painterResource(R.drawable.ic_open), "Open file", tint = C.text, modifier = Modifier.size(20.dp)) }
            IconButton(onClick = { dialog = "save" }, enabled = b.isNotEmpty()) { Icon(painterResource(R.drawable.ic_save), "Save file", tint = if (b.isNotEmpty()) C.text else C.text3, modifier = Modifier.size(20.dp)) }
        }

        Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlineButton("New") { dialog = "new" }
            OutlineButton("Go to", enabled = b.isNotEmpty()) { dialog = "goto" }
            OutlineButton("Find", enabled = b.isNotEmpty()) { dialog = "find" }
            OutlineButton("Find next", enabled = b.isNotEmpty() && lastFind.isNotEmpty()) {
                val at = state.findHex(lastFind, state.cursor + 1)
                if (at != null) state.select(at) else state.message = "Not found" to "“$lastFind” isn't in the buffer."
            }
            OutlineButton("Fill", enabled = b.isNotEmpty()) { dialog = "fill" }
            OutlineButton("Checksum", enabled = b.isNotEmpty()) {
                state.message = "Checksum" to "Byte sum: 0x%04X\nCRC32: 0x%08X\nSize: %,d bytes".format(DataFormats.sum16(b), DataFormats.crc32(b), b.size)
            }
        }

        Box(Modifier.weight(1f).padding(horizontal = 12.dp).background(C.bar, RoundedCornerShape(16.dp))) {
            if (b.isEmpty()) {
                Text("Read a chip, open a file or tap New.", fontFamily = Sans, color = C.text3, modifier = Modifier.align(Alignment.Center))
            } else {
                Column {
                    Row(Modifier.padding(start = 14.dp, end = 14.dp, top = 10.dp, bottom = 4.dp)) {
                        Text("ADDR", fontFamily = Mono, fontSize = 12.sp, color = C.text3, modifier = Modifier.width((digits * 8 + 8).dp))
                        Row(Modifier.weight(1f)) {
                            for (i in 0 until PER_ROW) Text("%02X".format(i), fontFamily = Mono, fontSize = 13.sp, color = C.text3, modifier = Modifier.padding(horizontal = 3.dp))
                        }
                        Text("ASCII", fontFamily = Mono, fontSize = 12.sp, color = C.text3, modifier = Modifier.width(68.dp))
                    }
                    LazyColumn(state = listState, modifier = Modifier.fillMaxSize()) {
                        items((b.size + PER_ROW - 1) / PER_ROW) { row ->
                            HexRow(state, row, digits)
                        }
                    }
                }
            }
        }

        if (b.isNotEmpty() && state.cursor in b.indices) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("0x%0${digits}X = ".format(state.cursor), fontFamily = Mono, fontSize = 13.sp)
                Text("%02X".format(b[state.cursor].toInt() and 0xFF), fontFamily = Mono, fontSize = 13.sp, color = C.onAmber,
                    modifier = Modifier.background(C.amber, RoundedCornerShape(4.dp)).padding(horizontal = 5.dp, vertical = 1.dp))
                Text("  Tap keys to change the byte", fontFamily = Sans, fontSize = 12.sp, color = C.text3)
            }
            Column(Modifier.padding(start = 16.dp, end = 16.dp, bottom = 10.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                for (r in 0 until 2) Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    for (c in 0 until 8) {
                        val v = r * 8 + c
                        Button(
                            onClick = { state.typeNibble(v) }, shape = RoundedCornerShape(10.dp),
                            colors = ButtonDefaults.buttonColors(containerColor = C.raised, contentColor = C.text),
                            contentPadding = androidx.compose.foundation.layout.PaddingValues(0.dp),
                            modifier = Modifier.weight(1f).height(44.dp),
                        ) { Text("%X".format(v), fontFamily = Mono, fontSize = 16.sp) }
                    }
                }
            }
        }
    }

    when (dialog) {
        "new" -> InputDialog("New buffer", "Size in bytes (hex with 0x, or K)", "32K", onDismiss = { dialog = null }) { s ->
            val size = parseSize(s)
            if (size == null || size <= 0 || size > 64 * 1024 * 1024) state.message = "Not a size" to "Use e.g. 32768, 0x8000 or 32K."
            else state.newBuffer(size, 0xFF)
        }
        "goto" -> InputDialog("Go to address", "Hex address", "", hex = true, onDismiss = { dialog = null }) { s ->
            s.trim().removePrefix("0x").removePrefix("0X").toIntOrNull(16)?.let { state.select(it.coerceIn(0, b.size - 1)) }
        }
        "find" -> InputDialog("Find", "Hex bytes (e.g. 55 AA) or text", lastFind, onDismiss = { dialog = null }) { s ->
            lastFind = s
            val at = state.findHex(s, state.cursor)
            if (at != null) state.select(at) else state.message = "Not found" to "“$s” isn't in the buffer."
        }
        "fill" -> InputDialog("Fill", "from-to=value, hex (e.g. 0-7FFF=FF)", "0-%X=FF".format(maxOf(0, b.size - 1)), hex = true, onDismiss = { dialog = null }) { s ->
            val m = Regex("^\\s*([0-9A-Fa-f]+)\\s*-\\s*([0-9A-Fa-f]+)\\s*=\\s*([0-9A-Fa-f]{1,2})\\s*$").find(s)
            if (m == null) state.message = "Not understood" to "Write it as from-to=value in hex, e.g. 0-7FFF=FF."
            else state.fill(m.groupValues[1].toInt(16), m.groupValues[2].toInt(16), m.groupValues[3].toInt(16))
        }
        "save" -> InputDialog("Save buffer", "File name (.bin or .hex)", suggestedBufferName(state), onDismiss = { dialog = null }) { s ->
            files.save(s.ifBlank { "buffer.bin" })
        }
    }
}

fun suggestedBufferName(state: AppState): String {
    val base = state.chip.substringBefore('@').ifEmpty { "buffer" }
    val n = state.bufferName
    return if (n.contains('.') && !n.startsWith("read from") && n != "new") n else "$base.bin"
}

private fun parseSize(s: String): Int? {
    val t = s.trim().uppercase()
    return when {
        t.endsWith("K") -> t.dropLast(1).trim().toIntOrNull()?.times(1024)
        t.endsWith("M") -> t.dropLast(1).trim().toIntOrNull()?.times(1024 * 1024)
        t.startsWith("0X") -> t.drop(2).toIntOrNull(16)
        else -> t.toIntOrNull()
    }
}

@Composable
private fun HexRow(state: AppState, row: Int, digits: Int) {
    val b = state.buffer
    val start = row * PER_ROW
    val end = minOf(b.size, start + PER_ROW)
    val cursorRow = state.cursor / PER_ROW == row
    Row(
        Modifier.fillMaxWidth().background(if (cursorRow) C.amberDim.copy(alpha = 0.45f) else C.bar).padding(horizontal = 14.dp, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("%0${digits}X".format(start), fontFamily = Mono, fontSize = 13.sp, color = C.text3, modifier = Modifier.width((digits * 8 + 8).dp))
        Row(Modifier.weight(1f)) {
            for (i in start until start + PER_ROW) {
                if (i < end) {
                    val selected = i == state.cursor
                    Text(
                        "%02X".format(b[i].toInt() and 0xFF), fontFamily = Mono, fontSize = 13.sp,
                        color = if (selected) C.onAmber else C.text,
                        modifier = Modifier
                            .background(if (selected) C.amber else androidx.compose.ui.graphics.Color.Transparent, RoundedCornerShape(3.dp))
                            .clickable { state.select(i) }
                            .padding(horizontal = 3.dp, vertical = 2.dp),
                    )
                } else {
                    Text("  ", fontFamily = Mono, fontSize = 13.sp, modifier = Modifier.padding(horizontal = 3.dp))
                }
            }
        }
        Text(
            (start until end).joinToString("") { val v = b[it].toInt() and 0xFF; if (v in 32..126) v.toChar().toString() else "·" },
            fontFamily = Mono, fontSize = 13.sp, color = C.text3, modifier = Modifier.width(68.dp), maxLines = 1,
        )
    }
}
