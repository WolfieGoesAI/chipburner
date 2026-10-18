package com.wolfiegoesai.chipburner.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.wolfiegoesai.chipburner.AppState
import com.wolfiegoesai.chipburner.ChipInfo
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun SearchScreen(state: AppState, initialKind: String? = null, onClose: () -> Unit, onPick: (String) -> Unit) {
    val startLogic = initialKind == "LOGIC" && state.chipInfo?.kind != ChipInfo.Kind.LOGIC
    var query by rememberSaveable { mutableStateOf(if (startLogic) "74" else state.chip.substringBefore('@')) }
    var kind by rememberSaveable { mutableStateOf(initialKind) }
    var dipOnly by rememberSaveable { mutableStateOf(false) }
    var results by remember { mutableStateOf<List<ChipInfo>>(emptyList()) }
    val focus = remember { FocusRequester() }

    LaunchedEffect(query, kind, dipOnly, state.dbReady) {
        val k = kind?.let { ChipInfo.Kind.valueOf(it) }
        results = withContext(Dispatchers.Default) { state.db.search(query, state.programmerType, k, dipOnly) }
    }
    LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }

    Column(Modifier.fillMaxSize().statusBarsPadding()) {
        Row(Modifier.padding(start = 4.dp, end = 12.dp, top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onClose) { Icon(Icons.Default.ArrowBack, contentDescription = "Back", tint = C.text) }
            Text("Choose a chip", fontFamily = Sans, fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
        }
        Surface(
            shape = RoundedCornerShape(26.dp), color = C.field, border = BorderStroke(1.dp, C.amber),
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp).fillMaxWidth().heightIn(min = 52.dp),
        ) {
            Row(Modifier.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.Search, contentDescription = null, tint = C.text2, modifier = Modifier.size(20.dp))
                Spacer(Modifier.size(10.dp))
                BasicTextField(
                    value = query, onValueChange = { query = it }, singleLine = true,
                    textStyle = TextStyle(fontFamily = Mono, fontSize = 16.sp, color = C.text),
                    cursorBrush = SolidColor(C.amber),
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters, imeAction = ImeAction.Search),
                    keyboardActions = KeyboardActions(onSearch = { results.firstOrNull()?.let { onPick(it.name) } }),
                    modifier = Modifier.weight(1f).padding(vertical = 14.dp).focusRequester(focus),
                    decorationBox = { inner ->
                        if (query.isEmpty()) Text("Part number, e.g. 27C256 or 328P", color = C.text3, fontFamily = Sans, fontSize = 15.sp)
                        inner()
                    },
                )
            }
        }
        FlowRow(Modifier.padding(horizontal = 16.dp, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            for ((label, k) in listOf("Memory" to ChipInfo.Kind.MEMORY, "MCU" to ChipInfo.Kind.MCU, "PLD" to ChipInfo.Kind.PLD, "SRAM" to ChipInfo.Kind.SRAM, "Logic" to ChipInfo.Kind.LOGIC)) {
                FilterChipButton(label, kind == k.name) { kind = if (kind == k.name) null else k.name }
            }
            FilterChipButton("DIP only", dipOnly) { dipOnly = !dipOnly }
        }
        Text(
            when {
                !state.dbReady -> "Loading the chip database…"
                query.trim().length < 2 -> "Type at least 2 characters"
                results.isEmpty() -> "No matches"
                results.size >= 300 -> "First 300 matches – type more to narrow it down"
                else -> "${results.size} matches"
            },
            fontSize = 13.sp, color = C.text3, fontFamily = Sans, modifier = Modifier.padding(horizontal = 20.dp, vertical = 6.dp),
        )
        LazyColumn(Modifier.fillMaxSize().padding(horizontal = 8.dp)) {
            items(results, key = { it.name + "|" + it.database }) { c ->
                Row(
                    Modifier.fillMaxWidth().clickable { onPick(c.name) }.padding(horizontal = 12.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(c.name.substringBefore('@'), fontFamily = Mono, fontSize = 16.sp)
                        Text(c.summary, fontFamily = Sans, fontSize = 13.sp, color = C.text2)
                    }
                    val pkg = c.name.substringAfter('@', "")
                    if (pkg.isNotEmpty()) Surface(color = C.field, shape = RoundedCornerShape(8.dp)) {
                        Text(pkg, Modifier.padding(horizontal = 8.dp, vertical = 4.dp), fontSize = 12.sp, color = C.text2, fontFamily = Sans)
                    }
                }
            }
        }
    }
}
