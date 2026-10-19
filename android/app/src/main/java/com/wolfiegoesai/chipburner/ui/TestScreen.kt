package com.wolfiegoesai.chipburner.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.wolfiegoesai.chipburner.AppState
import com.wolfiegoesai.chipburner.ChipInfo

@Composable
fun TestScreen(state: AppState, onSearch: () -> Unit) {
    var repeats by rememberSaveable { mutableIntStateOf(16) }
    if (repeats !in listOf(16, 64, 256)) repeats = 16
    var extendedMode by rememberSaveable { mutableStateOf(false) }
    var exhaustive by rememberSaveable { mutableStateOf(true) }
    var showIdent by remember { mutableStateOf(false) }
    var showPinout by remember { mutableStateOf(false) }
    var infoText by remember { mutableStateOf<String?>(null) }
    val info = state.chipInfo
    val isLogic = info?.kind == ChipInfo.Kind.LOGIC

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(bottom = 16.dp)) {
        Column(Modifier.padding(start = 20.dp, end = 20.dp, top = 16.dp, bottom = 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Eyebrow("Logic test")
            Text(state.chip.ifEmpty { "No chip chosen" }, fontFamily = Mono, fontSize = 22.sp, fontWeight = FontWeight.SemiBold)
            Text(
                when {
                    state.chip.isEmpty() -> "Choose a 74xx or 4000-series chip with Search"
                    info == null -> "Not in the database"
                    !isLogic -> "${info.summary} – not a logic chip"
                    else -> info.summary + if (info.group.contains(',')) " · same test as " + info.group.split(',').map { it.trim() }.filter { !it.equals(state.chip, true) }.take(4).joinToString(", ") else ""
                }, fontSize = 13.sp, color = C.text2, fontFamily = Sans,
            )
        }

        Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlineButton("Search logic chip", Modifier.weight(1f), onClick = onSearch)
                OutlineButton("Identify logic chip", Modifier.weight(1f), enabled = !state.busy) { showIdent = true }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlineButton("Info", Modifier.weight(1f), enabled = !state.busy && state.chip.isNotEmpty()) { state.chipInfoText { infoText = it } }
                OutlineButton("Pinout", Modifier.weight(1f), enabled = state.chip.isNotEmpty() && info != null) { showPinout = true }
            }
            val plan = remember(state.chip, state.dbReady) { if (isLogic) state.extendedPlan() else null }
            val hasModel = plan?.ext != null
            Card {
                Eyebrow("Test")
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChipButton("Standard test", !extendedMode) { extendedMode = false }
                    FilterChipButton("Extended test", extendedMode) { extendedMode = true }
                }
                if (!extendedMode) {
                    Text("Runs minipro's test vectors for the chip once.", fontSize = 13.sp, color = C.text2, fontFamily = Sans)
                } else {
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                        Checkbox(
                            checked = hasModel && exhaustive, enabled = hasModel, onCheckedChange = { exhaustive = it },
                            colors = CheckboxDefaults.colors(checkedColor = C.amber, checkmarkColor = C.onAmber, uncheckedColor = C.text2),
                        )
                        Text("Exhaustive / sequence test", fontFamily = Sans, fontSize = 15.sp, color = if (hasModel) C.text else C.text3)
                    }
                    if (plan != null) Text(plan.detail, fontSize = 13.sp, color = C.text2, fontFamily = Sans)
                    Text("Repeat the standard test", fontFamily = Sans, fontSize = 14.sp, color = C.text, modifier = Modifier.padding(top = 4.dp))
                    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        for (n in listOf(16, 64, 256)) FilterChipButton("$n times", repeats == n) { repeats = n }
                    }
                    Text("Repeated runs catch chips that fail now and then (marginal or overheating parts). Stop ends the test early.",
                        fontSize = 13.sp, color = C.text2, fontFamily = Sans)
                }
            }
            val extendedRunnable = !extendedMode || (exhaustive && hasModel) || repeats > 0
            PrimaryButton(if (extendedMode) "Start extended test" else "Test chip", enabled = !state.busy && isLogic && extendedRunnable) {
                if (extendedMode) state.extendedLogicTest(exhaustive && hasModel, repeats) else state.logicTest(1)
            }

            state.testResult?.let { r ->
                val good = r.passed
                Row(
                    Modifier.fillMaxWidth().background(if (good) C.greenBg else C.redBg, RoundedCornerShape(20.dp)).padding(18.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    Box(Modifier.size(48.dp).background(if (good) Color(0xFF2E5A3A) else Color(0xFF6A2E28), CircleShape), contentAlignment = Alignment.Center) {
                        Icon(if (good) Icons.Default.Check else Icons.Default.Close, contentDescription = null, tint = if (good) Color(0xFFB7F0C0) else Color(0xFFFFC9C0))
                    }
                    Column {
                        Text((if (r.title.isNotEmpty()) r.title + ": " else "") + if (good) "Passed" else if (r.report.isNotEmpty() && r.report.lastOrNull() == "Stopped before the end." && r.report.none { it.startsWith("✗") }) "Stopped" else "Failed", fontFamily = Sans, fontSize = 18.sp, fontWeight = FontWeight.SemiBold, color = if (good) Color(0xFFDFF7E3) else Color(0xFFFFE1DB))
                        Text(
                            buildString {
                                append(r.chip)
                                if (r.report.isEmpty()) {
                                    append(" · ").append(if (r.runs <= 1) "${r.runs} run" else "${r.runs} runs")
                                    if (r.failedRuns > 0) append(" · ${r.failedRuns} failed")
                                }
                                if (r.note.isNotEmpty()) append("\n").append(r.note)
                            },
                            fontFamily = Sans, fontSize = 13.sp, color = if (good) Color(0xFFA8CFAF) else Color(0xFFE9B3A9),
                        )
                    }
                }
                if (r.report.isNotEmpty()) {
                    Card {
                        Eyebrow("Report")
                        for (l in r.report) Text(l, fontFamily = Sans, fontSize = 13.sp,
                            color = when { l.startsWith("✓") -> C.green; l.startsWith("✗") -> C.red; else -> C.text })
                    }
                }
                if (r.failingLines.isNotEmpty()) {
                    Card {
                        Eyebrow("Failing vectors (pins marked “-”)")
                        for (l in r.failingLines) Text(l, fontFamily = Mono, fontSize = 12.sp, color = C.text)
                    }
                }
            }
            if (showIdent) LogicIdentDialog(state) { showIdent = false }
            if (showPinout) PinoutDialog(state.chip, state.currentPinout()) { showPinout = false }
            infoText?.let { InfoDialog(state.chip, it) { infoText = null } }
            LogicMatchesDialog(state)
            Text("The TL866A tests at a fixed 5 V and reads pins as high or low; it can't measure output levels or current, so a weak chip can still pass.",
                fontSize = 12.sp, color = C.text3, fontFamily = Sans, modifier = Modifier.padding(horizontal = 4.dp))
        }
    }
}

@Composable
fun LogScreen(state: AppState) {
    val context = LocalContext.current
    val list = rememberLazyListState()
    LaunchedEffect(state.log.size) { if (state.log.isNotEmpty()) list.scrollToItem(state.log.size - 1) }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 8.dp, top = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("Log", fontFamily = Sans, fontSize = 20.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            TextButton(onClick = { shareText(context, "ChipBurner log", state.log.joinToString("\n")) }) { Text("Share", color = C.amber, fontFamily = Sans) }
            TextButton(onClick = { state.log.clear() }) { Text("Clear", color = C.amber, fontFamily = Sans) }
        }
        LazyColumn(state = list, modifier = Modifier.fillMaxSize().padding(horizontal = 12.dp).background(C.bar, RoundedCornerShape(16.dp)).padding(12.dp)) {
            itemsIndexed(state.log) { _, line ->
                Text(
                    line, fontFamily = Mono, fontSize = 12.sp,
                    color = when {
                        line.startsWith("✗") -> C.red
                        line.startsWith("✓") -> C.green
                        line.startsWith("▶") -> C.amberLight
                        else -> C.text
                    },
                )
            }
        }
    }
}
