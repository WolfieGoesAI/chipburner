package com.wolfiegoesai.chipburner.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.wolfiegoesai.chipburner.AppState
import com.wolfiegoesai.chipburner.Chips

/** Chip Test: SRAM pattern test, or EPROM/EEPROM/flash health check – the same tests as the Mac app. */
@Composable
fun ChipTestDialog(state: AppState, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val kind = state.chipTestKind
    val info = state.chipInfo
    var o by remember { mutableStateOf(AppState.ChipTestOptions(compareBuffer = state.bufferMatchesChip)) }
    val (canWrite, writeNote) = state.writeTestAvailability
    val scroll = rememberScrollState()
    LaunchedEffect(state.testReport.size) { scroll.animateScrollTo(scroll.maxValue) }

    Dialog(onDismissRequest = { if (!state.chipTestRunning) onDismiss() }, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(color = C.ground, modifier = Modifier.fillMaxSize()) {
            Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Eyebrow(if (kind == "sram") "SRAM test" else "EPROM / EEPROM / flash health check")
                        Text(state.chip, fontFamily = Mono, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
                    }
                    TextButton(onClick = onDismiss, enabled = !state.chipTestRunning) { Text("Close", color = if (state.chipTestRunning) C.text3 else C.amber, fontFamily = Sans) }
                }
                Column(Modifier.weight(1f).verticalScroll(scroll), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    val size = info?.codeSize ?: 0
                    Text(
                        if (kind == "sram") "Writes test patterns to the ${com.wolfiegoesai.chipburner.Chips.sizeText(size)} RAM and reads each one back, reporting every byte that differs and which data bits and address lines look faulty. This overwrites the RAM's contents."
                        else "Reads the ${Chips.sizeText(size)} chip several times to find unstable bits – a typical sign of a weak or ageing EPROM – and checks the contents for signs of bad pins or address lines. Reading doesn't change the chip.",
                        fontFamily = Sans, fontSize = 13.sp, color = C.text2,
                    )
                    Card(padding = androidx.compose.foundation.layout.PaddingValues(horizontal = 8.dp, vertical = 8.dp)) {
                        val enabled = !state.chipTestRunning
                        if (kind == "sram") {
                            Check("All 00 and all FF (stuck bits)", o.solid, enabled) { o = o.copy(solid = it) }
                            Check("55, AA and checkerboard (neighbouring bits)", o.checker, enabled) { o = o.copy(checker = it) }
                            Check("Address patterns (stuck or shorted address lines)", o.address, enabled) { o = o.copy(address = it) }
                            Check("Back up the contents first and write them back afterwards", o.backup, enabled) { o = o.copy(backup = it) }
                        } else {
                            Text("Reads", fontFamily = Sans, fontSize = 13.sp, color = C.text2, modifier = Modifier.padding(start = 8.dp, top = 4.dp))
                            Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                for (n in listOf(4, 16, 64, 256)) FilterChipButton("$n", o.reads == n) { if (enabled) o = o.copy(reads = n) }
                            }
                            Check("Analyse the contents (blank, stuck bits, repeated halves)", o.analyse, enabled) { o = o.copy(analyse = it) }
                            Check(if (state.bufferMatchesChip) "Compare with the buffer" else "Compare with the buffer (needs a buffer of the chip's size)",
                                o.compareBuffer && state.bufferMatchesChip, enabled && state.bufferMatchesChip) { o = o.copy(compareBuffer = it) }
                            Check(if (canWrite) "Write test: 55, AA and address patterns – erases the chip, then writes the contents back" else "Write test ($writeNote)",
                                o.writeTest && canWrite, enabled && canWrite) { o = o.copy(writeTest = it) }
                        }
                    }
                    if (state.testReport.isNotEmpty()) {
                        Column(Modifier.fillMaxWidth().background(C.bar, RoundedCornerShape(14.dp)).padding(12.dp)) {
                            for (line in state.testReport) Text(
                                line, fontFamily = Mono, fontSize = 12.sp,
                                color = when {
                                    line.startsWith("✗") -> C.red
                                    line.startsWith("✓") || line.startsWith("RESULT: PASSED") -> C.green
                                    line.startsWith("RESULT") -> C.red
                                    else -> C.text
                                },
                            )
                        }
                    }
                }
                Text(state.chipTestStep, fontFamily = Sans, fontSize = 13.sp, color = C.text2)
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    OutlineButton("Share report", Modifier.weight(1f), enabled = state.testReport.isNotEmpty() && !state.chipTestRunning) {
                        shareText(context, "ChipBurner test – ${state.chip}", state.testReport.joinToString("\n"))
                    }
                    if (state.chipTestRunning) {
                        TileButton("Stop", Modifier.weight(1f)) { state.stop() }
                    } else {
                        TileButton("Start test", Modifier.weight(1f), enabled = !state.busy, accent = true) { state.startChipTest(o) }
                    }
                }
            }
        }
    }
}

@Composable
private fun Check(label: String, checked: Boolean, enabled: Boolean, onChange: (Boolean) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        Checkbox(checked = checked, onCheckedChange = onChange, enabled = enabled,
            colors = CheckboxDefaults.colors(checkedColor = C.amber, checkmarkColor = C.onAmber))
        Text(label, fontFamily = Sans, fontSize = 14.sp, color = if (enabled) C.text else C.text3)
    }
}
