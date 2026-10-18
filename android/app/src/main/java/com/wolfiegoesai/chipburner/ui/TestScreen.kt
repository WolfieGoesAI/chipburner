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
    var repeats by rememberSaveable { mutableIntStateOf(1) }
    var showIdent by remember { mutableStateOf(false) }
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
                OutlineButton("Search logic chips", Modifier.weight(1f), onClick = onSearch)
                OutlineButton("Logic Ident…", Modifier.weight(1f), enabled = !state.busy) { showIdent = true }
            }
            Card {
                Eyebrow("Runs")
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    for (n in listOf(1, 10, 25, 50, 100)) FilterChipButton(if (n == 1) "Once" else "$n times", repeats == n) { repeats = n }
                }
                Text(
                    if (repeats == 1) "Runs minipro's test vectors once at 5 V." else "Repeats the test $repeats times – catches chips that fail now and then.",
                    fontSize = 13.sp, color = C.text2, fontFamily = Sans,
                )
            }
            PrimaryButton("Test chip", enabled = !state.busy && isLogic) { state.logicTest(repeats) }

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
                        Text(if (good) "Passed" else "Failed", fontFamily = Sans, fontSize = 18.sp, fontWeight = FontWeight.SemiBold, color = if (good) Color(0xFFDFF7E3) else Color(0xFFFFE1DB))
                        Text(
                            buildString {
                                append(r.chip).append(" · ")
                                append(if (r.runs <= 1) "${r.runs} run" else "${r.runs} runs")
                                if (r.failedRuns > 0) append(" · ${r.failedRuns} failed")
                                if (r.note.isNotEmpty()) append("\n").append(r.note)
                            },
                            fontFamily = Sans, fontSize = 13.sp, color = if (good) Color(0xFFA8CFAF) else Color(0xFFE9B3A9),
                        )
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
