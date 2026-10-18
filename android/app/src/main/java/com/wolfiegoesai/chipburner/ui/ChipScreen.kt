package com.wolfiegoesai.chipburner.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.wolfiegoesai.chipburner.AppState
import com.wolfiegoesai.chipburner.BuildConfig
import com.wolfiegoesai.chipburner.ChipInfo
import com.wolfiegoesai.chipburner.DataFormats
import com.wolfiegoesai.chipburner.UsbProgrammer

@Composable
fun ChipScreen(state: AppState, files: FileActions, onSearch: () -> Unit, onShowBuffer: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    var showIdent by remember { mutableStateOf(false) }
    var info by remember { mutableStateOf<String?>(null) }
    var confirmProgram by remember { mutableStateOf(false) }
    var showOptions by remember { mutableStateOf(false) }
    var showAbout by remember { mutableStateOf(false) }
    var connMenu by remember { mutableStateOf(false) }
    var showPinout by remember { mutableStateOf(false) }
    var showLogicIdent by remember { mutableStateOf(false) }
    var showChipTest by remember { mutableStateOf(false) }
    var saveAsk by remember { mutableStateOf(false) }
    val chipInfo = state.chipInfo
    val erase = state.eraseMethod
    val canWork = !state.busy

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(bottom = 16.dp)) {
        Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 8.dp, top = 12.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            ChipLogo()
            Spacer(Modifier.size(10.dp))
            Text("ChipBurner", fontFamily = Sans, fontSize = 22.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            Box {
                IconButton(onClick = { menu = true }) { Icon(Icons.Default.MoreVert, contentDescription = "More", tint = C.text) }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text("Check programmer") }, onClick = { menu = false; state.refreshUsb(); state.detectProgrammer() })
                    DropdownMenuItem(text = { Text("Programmer self-test…") }, onClick = { menu = false; state.hardwareTest() })
                    DropdownMenuItem(text = { Text("Connection: ${state.connectionNames[state.connection]}  ▸") }, onClick = { menu = false; connMenu = true })
                    DropdownMenuItem(text = { Text("Options…") }, onClick = { menu = false; showOptions = true })
                    DropdownMenuItem(text = { Text("About ChipBurner") }, onClick = { menu = false; showAbout = true })
                }
                DropdownMenu(expanded = connMenu, onDismissRequest = { connMenu = false }) {
                    for ((i, name) in state.connectionNames.withIndex()) {
                        DropdownMenuItem(
                            text = { Text((if (state.connection == i) "✓  " else "     ") + name) },
                            onClick = { connMenu = false; state.chooseConnection(i) },
                        )
                    }
                }
            }
        }

        Box(Modifier.padding(horizontal = 20.dp).padding(bottom = 12.dp)) {
            StatusPill(state.programmerText, good = state.usbStatus == UsbProgrammer.Status.READY && state.programmerText.contains("connected")) {
                if (state.usbStatus == UsbProgrammer.Status.NO_PERMISSION) state.requestUsbPermission() else { state.refreshUsb(); state.detectProgrammer() }
            }
        }

        Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Card {
                Row(verticalAlignment = Alignment.Top) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Eyebrow("Chip")
                        Text(state.chip.ifEmpty { "None chosen" }, fontFamily = Mono, fontSize = 20.sp, fontWeight = FontWeight.SemiBold,
                            color = if (state.chip.isEmpty()) C.text3 else C.text)
                        Text(
                            when {
                                state.chip.isEmpty() -> "Search for the part printed on the chip"
                                !state.dbReady -> "Loading the chip database…"
                                chipInfo == null -> "Not in the ${state.programmerType} database"
                                else -> chipInfo.summary
                            }, fontSize = 13.sp, color = C.text2, fontFamily = Sans,
                        )
                    }
                }
                Spacer(Modifier.height(4.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlineButton("Search", Modifier.weight(1f), enabled = state.dbReady, onClick = onSearch)
                    OutlineButton("Identify", Modifier.weight(1f), enabled = canWork) { showIdent = true }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlineButton("Info", Modifier.weight(1f), enabled = canWork && state.chip.isNotEmpty()) { state.chipInfoText { info = it } }
                    OutlineButton("Pinout", Modifier.weight(1f), enabled = state.chip.isNotEmpty() && chipInfo != null) { showPinout = true }
                }
                if (state.connection != 0) {
                    Text("Connection: ${state.connectionNames[state.connection]}", fontSize = 12.sp, color = C.amberLight, fontFamily = Sans)
                }
            }

            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    TileButton("Read", Modifier.weight(1f), enabled = canWork) { state.readChip() }
                    TileButton("Test", Modifier.weight(1f), enabled = canWork) {
                        if (state.chipTestKind == null) state.message = "Chip Test isn't available" to (if (state.chip.isEmpty()) "Choose a chip first." else "It works with SRAM and with EPROM, EEPROM and flash memory chips. Logic chips are tested on the Test tab.")
                        else showChipTest = true
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    TileButton("Program", Modifier.weight(1f), enabled = canWork) {
                        if (state.buffer.isEmpty()) state.message = "The buffer is empty" to "Open a file or read a chip first." else confirmProgram = true
                    }
                    TileButton("Verify", Modifier.weight(1f), enabled = canWork) { state.verify() }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    TileButton("Blank check", Modifier.weight(1f), enabled = canWork) { state.blankCheck() }
                    TileButton("Erase", Modifier.weight(1f), enabled = canWork && erase !is AppState.EraseMethod.Unavailable) { state.erase() }
                }
                if (erase is AppState.EraseMethod.Unavailable && state.chip.isNotEmpty() && chipInfo != null) {
                    Text("Erase isn't available: ${erase.why}", fontSize = 12.sp, color = C.text3, fontFamily = Sans, modifier = Modifier.padding(horizontal = 4.dp))
                } else if (erase is AppState.EraseMethod.Fill) {
                    Text("This chip has no erase command: Erase fills it with FF and verifies.", fontSize = 12.sp, color = C.text3, fontFamily = Sans, modifier = Modifier.padding(horizontal = 4.dp))
                }
            }

            Card(padding = androidx.compose.foundation.layout.PaddingValues(start = 18.dp, end = 8.dp, top = 12.dp, bottom = 16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.weight(1f)) { Eyebrow("Buffer") }
                    TextButton(onClick = files.open) { Text("Open file", color = C.amber, fontFamily = Sans) }
                    TextButton(onClick = { saveAsk = true }, enabled = state.buffer.isNotEmpty()) {
                        Text("Save file", color = if (state.buffer.isNotEmpty()) C.amber else C.text3, fontFamily = Sans)
                    }
                }
                if (state.buffer.isEmpty()) {
                    Text("Empty – read a chip or open a file", fontFamily = Mono, fontSize = 14.sp, color = C.text3)
                } else {
                    val b = state.buffer
                    Text("${state.bufferName} · ${"%,d".format(b.size)} bytes", fontFamily = Mono, fontSize = 14.sp)
                    Text("sum 0x%04X · CRC32 0x%08X".format(DataFormats.sum16(b), DataFormats.crc32(b)), fontFamily = Mono, fontSize = 12.sp, color = C.text2)
                }
            }

        }
    }

    if (showIdent) IdentDialog(state, onLogic = { showLogicIdent = true }) { showIdent = false }
    if (showLogicIdent) LogicIdentDialog(state) { showLogicIdent = false }
    LogicMatchesDialog(state)
    if (saveAsk) SaveFormatDialog(state, files) { saveAsk = false }
    if (showChipTest) ChipTestDialog(state) { showChipTest = false }
    if (showPinout) PinoutDialog(state.chip, state.currentPinout()) { showPinout = false }
    state.identMatches?.let { matches ->
        PickDialog("Chips with this ID", "Pick the exact part printed on the chip.", matches, onDismiss = { state.identMatches = null }) {
            state.selectChip(it); state.identMatches = null
        }
    }
    info?.let { text -> InfoDialog(state.chip, text) { info = null } }
    if (confirmProgram) ProgramSheet(state, onDismiss = { confirmProgram = false })
    if (showOptions) OptionsDialog(state) { showOptions = false }
    if (showAbout) AboutDialog(state) { showAbout = false }
}

@Composable
fun ChipLogo() {
    Box(Modifier.size(width = 20.dp, height = 26.dp).border(2.dp, C.amber, RoundedCornerShape(3.dp)), contentAlignment = Alignment.Center) {
        Box(Modifier.size(width = 9.dp, height = 7.dp).background(C.uv, RoundedCornerShape(1.dp)))
    }
}

@Composable
private fun ChipThumb(info: ChipInfo?) {
    Box(Modifier.size(width = 56.dp, height = 72.dp).background(C.raised, RoundedCornerShape(6.dp)), contentAlignment = Alignment.Center) {
        if (info != null && info.kind == ChipInfo.Kind.MEMORY && com.wolfiegoesai.chipburner.Chips.isUVEPROM(info.name)) {
            Box(Modifier.size(width = 22.dp, height = 16.dp).background(Color4A4370, RoundedCornerShape(3.dp)).border(1.dp, C.uv, RoundedCornerShape(3.dp)))
        } else {
            Text(info?.kind?.label?.take(5)?.uppercase() ?: "", fontSize = 10.sp, color = C.text3, fontFamily = Mono)
        }
    }
}

private val Color4A4370 = androidx.compose.ui.graphics.Color(0xFF4A4370)

@Composable
private fun IdentDialog(state: AppState, onLogic: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss, containerColor = C.card,
        title = { Text("Chip Ident", fontFamily = Sans, fontWeight = FontWeight.SemiBold) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("Put the chip in the socket (bottom-aligned, pin 1 at the lever) and choose what kind it is.", fontFamily = Sans, fontSize = 14.sp)
                for (k in AppState.IdentKind.values()) {
                    if (k == AppState.IdentKind.SAME && !state.canIdentifySameType) continue
                    val label = if (k == AppState.IdentKind.SAME) "Same type as ${state.chip}" else k.label
                    OutlineButton(label, Modifier.fillMaxWidth()) { onDismiss(); state.identify(k) }
                }
                Text("SPI flash is read at 3.3 V with the standard JEDEC ID command; 1.8 V chips need a 1.8 V adapter. The EPROM read puts about 12 V on pin A9. Only use it for 27-series EPROMs (UV or electrically erasable), never for 28-series EEPROMs, flash or microcontrollers.",
                    fontFamily = Sans, fontSize = 12.sp, color = C.text2)
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Cancel", color = C.amber) } },
    )
}

@Composable
fun PickDialog(title: String, note: String, items: List<String>, onDismiss: () -> Unit, onPick: (String) -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss, containerColor = C.card,
        title = { Text(title, fontFamily = Sans, fontWeight = FontWeight.SemiBold) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(note, fontFamily = Sans, fontSize = 13.sp, color = C.text2)
                for (it in items) TextButton(onClick = { onPick(it) }, modifier = Modifier.fillMaxWidth()) {
                    Text(it, fontFamily = Mono, fontSize = 15.sp, color = C.text, modifier = Modifier.fillMaxWidth())
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Cancel", color = C.amber) } },
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ProgramSheet(state: AppState, onDismiss: () -> Unit) {
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheet, containerColor = C.card) {
        Column(Modifier.padding(start = 20.dp, end = 20.dp, bottom = 28.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text("Program ${state.chip}?", fontFamily = Sans, fontSize = 22.sp, fontWeight = FontWeight.SemiBold)
            Text("${"%,d".format(state.buffer.size)} bytes from ${state.bufferName} will be written to the chip in the ZIF socket.",
                fontFamily = Sans, fontSize = 14.sp, color = C.text2)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Fact("Before", if (state.noErase) "No erase" else when (state.eraseMethod) {
                    AppState.EraseMethod.Command -> "Erase"
                    else -> "Writes over"
                }, Modifier.weight(1f))
                Fact("After", if (state.noVerify) "No verify" else "Verify", Modifier.weight(1f))
            }
            state.chipInfo?.let { ci ->
                if (ci.codeSize > 0 && ci.codeSize != state.buffer.size && !state.allowSize) {
                    Text("The buffer is ${state.buffer.size} bytes but the chip holds ${ci.codeSize}. minipro will stop unless “Allow file size mismatch” is on in Options.",
                        fontFamily = Sans, fontSize = 13.sp, color = C.red)
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlineButton("Cancel", Modifier.weight(1f).height(56.dp)) { onDismiss() }
                PrimaryButton("Program", modifier = Modifier.weight(1f)) { onDismiss(); state.program() }
            }
            Text("Keep the cable connected until it finishes.", fontFamily = Sans, fontSize = 12.sp, color = C.text3)
        }
    }
}

@Composable
private fun Fact(label: String, value: String, modifier: Modifier) {
    Column(modifier.background(C.raised, RoundedCornerShape(14.dp)).padding(12.dp)) {
        Text(label, fontSize = 12.sp, color = C.text2, fontFamily = Sans)
        Text(value, fontSize = 15.sp, fontFamily = Sans)
    }
}

@Composable
private fun OptionsDialog(state: AppState, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss, containerColor = C.card,
        title = { Text("Options", fontFamily = Sans, fontWeight = FontWeight.SemiBold) },
        text = {
            Column {
                for ((key, label, value) in listOf(
                    Triple("skipId", "Skip chip ID check", state.skipId),
                    Triple("allowSize", "Allow file size mismatch", state.allowSize),
                    Triple("noErase", "Don't erase before programming", state.noErase),
                    Triple("noVerify", "Don't verify after programming", state.noVerify),
                )) {
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                        Checkbox(checked = value, onCheckedChange = { state.setOption(key, it) },
                            colors = CheckboxDefaults.colors(checkedColor = C.amber, checkmarkColor = C.onAmber))
                        Text(label, fontFamily = Sans, fontSize = 15.sp)
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done", color = C.amber) } },
    )
}

@Composable
private fun AboutDialog(state: AppState, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss, containerColor = C.card,
        title = { Text("ChipBurner for Android", fontFamily = Sans, fontWeight = FontWeight.SemiBold) },
        text = {
            Text(
                "Version ${BuildConfig.VERSION_NAME} (build ${BuildConfig.VERSION_CODE}, ${BuildConfig.COMMIT})\n" +
                    "Made by WolfieGoesAI\n\n" + state.minipro.sourceInfo,
                fontFamily = Sans, fontSize = 13.sp,
            )
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("OK", color = C.amber) } },
    )
}

/** A small dialog asking for one text value. */
@Composable
fun InputDialog(title: String, label: String, initial: String = "", hex: Boolean = false, onDismiss: () -> Unit, onOk: (String) -> Unit) {
    var text by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss, containerColor = C.card,
        title = { Text(title, fontFamily = Sans, fontWeight = FontWeight.SemiBold) },
        text = {
            OutlinedTextField(value = text, onValueChange = { text = it }, label = { Text(label) }, singleLine = true,
                textStyle = androidx.compose.ui.text.TextStyle(fontFamily = Mono, fontSize = 16.sp, color = C.text),
                keyboardOptions = KeyboardOptions(keyboardType = if (hex) KeyboardType.Ascii else KeyboardType.Text))
        },
        confirmButton = { TextButton(onClick = { onDismiss(); onOk(text) }) { Text("OK", color = C.amber) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel", color = C.text2) } },
    )
}


/** Logic Ident: pick the pin count, then every 5 V chip type with it is tested. */
@Composable
fun LogicIdentDialog(state: AppState, onDismiss: () -> Unit) {
    val counts = state.db.identPinCounts
    AlertDialog(
        onDismissRequest = onDismiss, containerColor = C.card,
        title = { Text("Logic Ident", fontFamily = Sans, fontWeight = FontWeight.SemiBold) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Logic chips have no ID. Put the chip in the socket bottom-aligned with pin 1 at the lever, and choose its pin count. ChipBurner runs the 5 V test of every chip type with ground on the last pin of the first row and supply on the last pin, and lists the ones it passes. About a second per type; Stop ends it early.",
                    fontFamily = Sans, fontSize = 13.sp, color = C.text2)
                for (n in counts) {
                    val k = state.db.identGroups(n).size
                    OutlineButton("$n pins  ($k chip types)", Modifier.fillMaxWidth()) { onDismiss(); state.identifyLogic(n) }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Cancel", color = C.amber) } },
    )
}

@Composable
fun LogicMatchesDialog(state: AppState) {
    state.logicMatches?.let { matches ->
        PickDialog("Logic chips the chip passed", "Chips on one line share the same test. Pick the one printed on the chip.", matches,
            onDismiss = { state.logicMatches = null }) {
            state.selectChip(it.substringBefore(" / ")); state.logicMatches = null
        }
    }
}


@Composable
fun InfoDialog(chip: String, text: String, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss, containerColor = C.card,
        confirmButton = { TextButton(onClick = onDismiss) { Text("Close", color = C.amber) } },
        title = { Text(chip, fontFamily = Mono) },
        text = { Text(text, fontFamily = Mono, fontSize = 12.sp, modifier = Modifier.verticalScroll(rememberScrollState())) },
    )
}

/** Save the buffer as a binary (.bin) or Intel HEX (.hex) file. */
@Composable
fun SaveFormatDialog(state: AppState, files: FileActions, onDismiss: () -> Unit) {
    val base = suggestedBufferName(state).substringBeforeLast('.')
    AlertDialog(
        onDismissRequest = onDismiss, containerColor = C.card,
        title = { Text("Save buffer", fontFamily = Sans, fontWeight = FontWeight.SemiBold) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("${"%,d".format(state.buffer.size)} bytes. Choose the file format; you can change the name in the next step.", fontFamily = Sans, fontSize = 13.sp, color = C.text2)
                OutlineButton("Binary (.bin)", Modifier.fillMaxWidth()) { onDismiss(); files.save("$base.bin") }
                OutlineButton("Intel HEX (.hex)", Modifier.fillMaxWidth()) { onDismiss(); files.save("$base.hex") }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Cancel", color = C.amber) } },
    )
}
