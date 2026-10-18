package com.wolfiegoesai.chipburner.ui

import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.wolfiegoesai.chipburner.AppState
import com.wolfiegoesai.chipburner.R

enum class Tab(val label: String, val icon: Int) {
    CHIP("Chip", R.drawable.ic_chip), BUFFER("Buffer", R.drawable.ic_buffer), TEST("Test", R.drawable.ic_test), LOG("Log", R.drawable.ic_log)
}

@Composable
fun ChipBurnerApp(state: AppState) {
    var tab by rememberSaveable { mutableStateOf(Tab.CHIP) }
    var searching by rememberSaveable { mutableStateOf(false) }
    var searchKind by rememberSaveable { mutableStateOf<String?>(null) }
    val context = LocalContext.current

    val openLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        if (uri != null) {
            val name = displayName(context, uri)
            runCatching { context.contentResolver.openInputStream(uri)?.use { it.readBytes() } }
                .onSuccess { data -> if (data != null) { state.loadFile(name, data); tab = Tab.BUFFER } }
                .onFailure { state.message = "Can't open the file" to (it.message ?: "") }
        }
    }
    var saveName by remember { mutableStateOf("") }
    val saveLauncher = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { uri: Uri? ->
        if (uri != null) {
            runCatching { context.contentResolver.openOutputStream(uri, "wt")?.use { it.write(state.bufferBytesFor(saveName)) } }
                .onSuccess { state.addLog("Saved $saveName") }
                .onFailure { state.message = "Can't save the file" to (it.message ?: "") }
        }
    }
    val files = FileActions(
        open = { openLauncher.launch(arrayOf("*/*")) },
        save = { suggested -> saveName = suggested; saveLauncher.launch(suggested) },
    )

    if (searching) {
        BackHandler { searching = false }
        SearchScreen(state, initialKind = searchKind, onClose = { searching = false }, onPick = { state.selectChip(it); searching = false })
    } else {
        Scaffold(
            containerColor = C.ground,
            bottomBar = {
                Column {
                    JobBar(state)
                    NavigationBar(containerColor = C.bar) {
                        for (t in Tab.values()) {
                            NavigationBarItem(
                                selected = tab == t, onClick = { tab = t },
                                icon = { Icon(painterResource(t.icon), contentDescription = null, modifier = Modifier.size(22.dp)) },
                                label = { Text(t.label, fontFamily = Sans, fontSize = 12.sp) },
                                colors = NavigationBarItemDefaults.colors(
                                    selectedIconColor = C.amber, selectedTextColor = C.text, indicatorColor = C.amberDim,
                                    unselectedIconColor = C.text2, unselectedTextColor = C.text2,
                                ),
                            )
                        }
                    }
                }
            },
        ) { pad ->
            Box(Modifier.fillMaxSize().padding(pad).statusBarsPadding()) {
                when (tab) {
                    Tab.CHIP -> ChipScreen(state, files, onSearch = { searchKind = null; searching = true }, onShowBuffer = { tab = Tab.BUFFER })
                    Tab.BUFFER -> BufferScreen(state, files)
                    Tab.TEST -> TestScreen(state, onSearch = { searchKind = "LOGIC"; searching = true })
                    Tab.LOG -> LogScreen(state)
                }
            }
        }
    }

    state.message?.let { (title, text) ->
        AlertDialog(
            onDismissRequest = { state.message = null },
            confirmButton = { TextButton(onClick = { state.message = null }) { Text("OK", color = C.amber) } },
            title = { Text(title, fontFamily = Sans, fontWeight = FontWeight.SemiBold) },
            text = { Text(text, fontFamily = Sans) },
            containerColor = C.card,
        )
    }
}

class FileActions(val open: () -> Unit, val save: (String) -> Unit)

/** Progress and Stop for the running job, above the tab bar. */
@Composable
fun JobBar(state: AppState) {
    if (!state.busy) return
    Surface(color = C.card, shape = RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp)) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(state.jobTitle, fontFamily = Sans, fontWeight = FontWeight.Medium, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(state.status, fontFamily = Mono, fontSize = 12.sp, color = C.text3, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                OutlineButton("Stop") { state.stop() }
            }
            val p = state.progress
            if (p != null && p > 0f) {
                LinearProgressIndicator(progress = { p }, modifier = Modifier.fillMaxWidth(), color = C.amber, trackColor = C.raised)
            } else {
                LinearProgressIndicator(modifier = Modifier.fillMaxWidth(), color = C.amber, trackColor = C.raised)
            }
        }
    }
}

fun displayName(context: android.content.Context, uri: Uri): String {
    runCatching {
        context.contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) return c.getString(0) ?: "file"
        }
    }
    return uri.lastPathSegment?.substringAfterLast('/') ?: "file"
}

fun shareText(context: android.content.Context, subject: String, text: String) {
    val i = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_SUBJECT, subject).putExtra(Intent.EXTRA_TEXT, text)
    context.startActivity(Intent.createChooser(i, subject))
}

@Suppress("unused")
private fun Modifier.groundBg() = this.background(C.ground)
