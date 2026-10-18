package com.wolfiegoesai.chipburner

import android.app.Application
import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

class AppState(app: Application) : AndroidViewModel(app) {
    private val ctx: Context get() = getApplication()
    val minipro = Minipro(app)
    val db = ChipDb(minipro.infoic, minipro.logicic)
    val usb = UsbProgrammer(app) { onUsbChange() }
    private val prefs = app.getSharedPreferences("chipburner", Context.MODE_PRIVATE)

    // Programmer
    var usbStatus by mutableStateOf(UsbProgrammer.Status.NONE); private set
    var programmerText by mutableStateOf("No programmer connected"); private set
    var programmerType by mutableStateOf(prefs.getString("programmerType", "TL866A") ?: "TL866A"); private set
    private var detectedFor: String? = null

    // Chip
    var dbReady by mutableStateOf(false); private set
    var chip by mutableStateOf(prefs.getString("chip", "") ?: ""); private set
    val chipInfo: ChipInfo? get() = if (dbReady && chip.isNotEmpty()) db.info(chip, programmerType) else null

    // Buffer
    var buffer by mutableStateOf(ByteArray(0)); private set
    var bufferName by mutableStateOf(""); private set
    var bufferVersion by mutableIntStateOf(0); private set
    var cursor by mutableIntStateOf(0)
    private var pendingNibble: Int? = null
    private val undo = ArrayList<Pair<Int, Byte>>()

    // Jobs
    var busy by mutableStateOf(false); private set
    var jobTitle by mutableStateOf(""); private set
    var progress by mutableStateOf<Float?>(null); private set
    var status by mutableStateOf("Ready"); private set
    val log = mutableStateListOf<String>()
    var message by mutableStateOf<Pair<String, String>?>(null)
    var testResult by mutableStateOf<TestResult?>(null); private set

    // Options
    var skipId by mutableStateOf(prefs.getBoolean("skipId", false)); private set
    var allowSize by mutableStateOf(prefs.getBoolean("allowSize", false)); private set
    var noErase by mutableStateOf(prefs.getBoolean("noErase", false)); private set
    var noVerify by mutableStateOf(prefs.getBoolean("noVerify", false)); private set

    // Connection: 0 ZIF socket, 1 ICSP powered by the programmer (-i), 2 ICSP, board powers itself (-I)
    var connection by mutableIntStateOf(prefs.getInt("connection", 0)); private set
    val connectionNames = listOf("ZIF socket", "ICSP – power from programmer", "ICSP – board has its own power")
    private val connectionArgs: List<String> get() = when (connection) { 1 -> listOf("-i"); 2 -> listOf("-I"); else -> emptyList() }

    fun chooseConnection(c: Int) {
        connection = c
        prefs.edit().putInt("connection", c).apply()
        addLog("Connection: ${connectionNames[c]}")
    }

    var logicMatches by mutableStateOf<List<String>?>(null)
    @Volatile private var scanCancelled = false

    data class TestResult(val chip: String, val passed: Boolean, val runs: Int, val failedRuns: Int, val failingLines: List<String>, val note: String)

    init {
        viewModelScope.launch(Dispatchers.IO) {
            minipro.prepareDatabase()
            db.load()
            withContext(Dispatchers.Main) {
                dbReady = true
                addLog("Chip database: ${db.all.size} entries. ${minipro.sourceInfo.lines().firstOrNull() ?: ""}")
            }
        }
        usb.start()
    }

    override fun onCleared() {
        usb.stop()
        super.onCleared()
    }

    fun addLog(line: String) {
        log += line
        if (log.size > 5000) log.removeRange(0, log.size - 5000)
    }

    // MARK: Programmer

    private fun onUsbChange() {
        usbStatus = usb.status
        when (usbStatus) {
            UsbProgrammer.Status.NONE -> { programmerText = "No programmer connected"; detectedFor = null }
            UsbProgrammer.Status.NO_PERMISSION -> programmerText = "Programmer found – tap to allow access"
            UsbProgrammer.Status.NOT_OPEN -> programmerText = "Programmer found – couldn't open it"
            UsbProgrammer.Status.READY -> {
                val name = usb.device?.deviceName
                if (detectedFor != name) {
                    detectedFor = name
                    detectProgrammer()
                }
            }
        }
    }

    fun requestUsbPermission() = usb.requestPermission()
    fun refreshUsb() = usb.refresh()

    fun detectProgrammer() {
        if (busy) return
        programmerText = "Checking programmer…"
        viewModelScope.launch(Dispatchers.IO) {
            val (code, out) = minipro.runCollect(listOf("-k"), usb.fd)
            val info = if (code == 0) minipro.runCollect(listOf("-L", "CHIPBURNER-NO-SUCH-CHIP"), usb.fd).second else ""
            withContext(Dispatchers.Main) {
                addLog("Programmer check:\n" + (out + info).lines().filter { it.isNotBlank() && !it.contains("overridden database") }.joinToString("\n"))
                val up = out.uppercase()
                val model = listOf("TL866II" to "TL866II+", "T48" to "T48", "TL866CS" to "TL866CS", "TL866A" to "TL866A")
                    .firstOrNull { up.contains(it.first) }
                if (code == 0 && model != null) {
                    programmerType = if (model.first == "TL866II" || model.first == "T48") model.first else "TL866A"
                    prefs.edit().putString("programmerType", programmerType).apply()
                    val fw = Regex("Found\\s+\\S+\\s+(\\d+\\.\\d+\\.\\d+)").find(info)?.groupValues?.get(1)
                    programmerText = model.second + (fw?.let { " v$it" } ?: "") + " · USB connected"
                } else {
                    programmerText = "Programmer didn't answer – " + (out.lines().firstOrNull { it.isNotBlank() } ?: "no reply")
                }
            }
        }
    }

    // MARK: Chip

    fun selectChip(name: String) {
        chip = name.replace("(custom)", "", ignoreCase = true).trim()
        prefs.edit().putString("chip", chip).apply()
        addLog("Chip selected: $chip")
    }

    fun setOption(key: String, value: Boolean) {
        when (key) {
            "skipId" -> skipId = value
            "allowSize" -> allowSize = value
            "noErase" -> noErase = value
            "noVerify" -> noVerify = value
        }
        prefs.edit().putBoolean(key, value).apply()
    }

    val optionsSummary: String
        get() = listOfNotNull(
            "skip ID".takeIf { skipId }, "any size".takeIf { allowSize },
            "no erase".takeIf { noErase }, "no verify".takeIf { noVerify },
        ).joinToString(", ").ifEmpty { "standard" }

    sealed class EraseMethod {
        object Command : EraseMethod()
        object Fill : EraseMethod()
        data class Unavailable(val why: String) : EraseMethod()
    }

    val eraseMethod: EraseMethod
        get() {
            val info = chipInfo ?: return EraseMethod.Unavailable("Choose a chip first.")
            if (Chips.isUVEPROM(chip) && info.canErase != true) return EraseMethod.Unavailable("UV EPROMs are erased with UV light.")
            if (info.canErase == true) return EraseMethod.Command
            return when (info.kind) {
                ChipInfo.Kind.MEMORY -> if (info.codeSize > 0) EraseMethod.Fill else EraseMethod.Unavailable("Its size isn't known.")
                ChipInfo.Kind.LOGIC -> EraseMethod.Unavailable("Logic chips have no memory to erase.")
                ChipInfo.Kind.SRAM -> EraseMethod.Unavailable("SRAM has nothing to erase.")
                else -> EraseMethod.Unavailable("This chip has no erase command.")
            }
        }

    private fun needsChip(): Boolean {
        if (chip.isEmpty()) { message = "Choose a chip" to "Use Search to pick the chip in the socket first."; return false }
        return true
    }

    private fun needsProgrammer(): Boolean {
        when (usb.status) {
            UsbProgrammer.Status.READY -> return true
            UsbProgrammer.Status.NO_PERMISSION -> { usb.requestPermission(); return false }
            else -> {
                message = "No programmer" to "Connect the TL866A with a USB-OTG cable. If the phone can't power it, use a powered USB hub."
                return false
            }
        }
    }

    private fun optionArgs(kind: String): List<String> {
        val a = ArrayList<String>()
        if (skipId) a += if (kind == "read") "-x" else "-y"
        if (allowSize && (kind == "verify" || kind == "write")) a += "-s"
        if (kind == "write") {
            if (noErase) a += "-e"
            if (noVerify) a += "-v"
        }
        return a
    }

    // MARK: Jobs

    private val percent = Regex("(\\d{1,3})%")

    /** Runs one minipro job; [done] runs on the main thread with success and the full output. */
    private fun runJob(title: String, args: List<String>, needsUsb: Boolean = true, logicOverride: File? = null, done: ((Boolean, String) -> Unit)? = null) {
        if (busy) return
        if (needsUsb && !needsProgrammer()) return
        busy = true
        jobTitle = title
        progress = 0f
        status = "$title…"
        // ICSP: the connection flag goes right after the chip name (not for the ID read or logic tests)
        val args = if (connection != 0 && args.size >= 2 && args[0] == "-p" && "-T" !in args && "-D" !in args)
            args.take(2) + connectionArgs + args.drop(2) else args
        addLog("▶ $title: minipro ${args.joinToString(" ")}")
        val fd = if (needsUsb) usb.fd else null
        viewModelScope.launch(Dispatchers.IO) {
            val out = StringBuilder()
            val code = minipro.run(args, fd, logicOverride) { line, isProgress ->
                if (!isProgress) out.append(line).append('\n')
                viewModelScope.launch(Dispatchers.Main) {
                    if (isProgress) {
                        status = line.trim()
                        percent.find(line)?.groupValues?.get(1)?.toFloatOrNull()?.let { progress = it / 100f }
                    } else if (line.isNotBlank() && !line.contains("overridden database")) {
                        addLog(line)
                    }
                }
            }
            withContext(Dispatchers.Main) {
                busy = false
                val ok = code == 0
                progress = if (ok) 1f else null
                status = when {
                    minipro.stopRequested -> "$title: stopped"
                    ok -> "$title: done"
                    else -> "$title: failed – see Log"
                }
                addLog(if (ok) "✓ $title finished." else "✗ $title failed (exit code $code).")
                done?.invoke(ok, out.toString())
            }
        }
    }

    fun stop() {
        if (busy) { addLog("Stopping…"); scanCancelled = true; minipro.stop() }
    }

    /** Logic chips have no ID: run the test of every 5 V chip type with this pin count and list the ones that pass. */
    fun identifyLogic(pins: Int) {
        if (busy || !needsProgrammer()) return
        val groups = db.identGroups(pins)
        if (groups.isEmpty()) { message = "No $pins-pin logic chips" to "The database has no 5 V logic chips with $pins pins."; return }
        busy = true
        jobTitle = "Logic Ident ($pins pins)"
        progress = 0f
        scanCancelled = false
        addLog("▶ Logic Ident: testing ${groups.size} $pins-pin chip types")
        val fd = usb.fd
        viewModelScope.launch(Dispatchers.IO) {
            val passed = ArrayList<ChipDb.LogicGroup>()
            var abort: String? = null
            var tested = 0
            for ((i, g) in groups.withIndex()) {
                if (scanCancelled) { abort = "Stopped after $tested of ${groups.size} types."; break }
                val label = g.names.joinToString(" / ")
                withContext(Dispatchers.Main) { status = "Testing $label (${i + 1} of ${groups.size})"; progress = i.toFloat() / groups.size }
                val (code, out) = minipro.runCollect(listOf("-p", g.names[0], "-T"), fd)
                tested++
                val low = out.lowercase()
                if ("overcurrent" in low) { abort = "minipro reported overcurrent while testing ${g.names[0]}. Check the chip's orientation and pin count."; break }
                if ("no programmer" in low || ("not found" in low && "programmer" in low)) { abort = "The programmer isn't responding. Check the USB cable."; break }
                val ok = code == 0 && Chips.failingVectorLines(out).isEmpty()
                if (ok) passed += g
                withContext(Dispatchers.Main) { addLog("$label: ${if (ok) "PASS" else "fail"}") }
            }
            withContext(Dispatchers.Main) {
                busy = false
                progress = if (abort == null) 1f else null
                status = "Logic Ident: ${passed.size} match(es) after $tested of ${groups.size} types"
                addLog("✓ Logic Ident finished: ${passed.size} match(es).")
                when {
                    passed.isNotEmpty() -> logicMatches = passed.map { it.names.joinToString(" / ") }
                    abort != null -> message = "Logic Ident stopped" to abort
                    else -> message = "No match" to "The chip didn't pass any $pins-pin test. Check that it is seated correctly (bottom-aligned, pin 1 at the lever), or that it isn't one with non-standard power pins such as the 7490 – those can be tested one at a time."
                }
            }
        }
    }

    /** The selected chip's pinout drawing, if there is one. */
    fun currentPinout(): ChipPinout? {
        val info = chipInfo ?: return null
        if (info.kind == ChipInfo.Kind.LOGIC) {
            val g = db.logicGroup(chip) ?: return null
            return Pinouts.logic(chip, g.pins, g.group, g.vectors)
        }
        return Pinouts.find(chip, info.codeSize, info.kind == ChipInfo.Kind.SRAM)
    }

    private fun tempFile(name: String) = File(minipro.workDir, name)

    fun readChip() {
        if (!needsChip()) return
        val out = tempFile("read." + if (chipInfo?.kind == ChipInfo.Kind.PLD) "jed" else "bin")
        out.delete()
        runJob("Read $chip", listOf("-p", chip, "-r", out.path) + optionArgs("read")) { ok, _ ->
            if (ok && out.exists()) {
                setBuffer(out.readBytes(), "read from $chip" + if (out.name.endsWith(".jed")) ".jed" else "")
                message = "$chip read" to "${buffer.size} bytes are in the buffer. CRC32 0x%08X.".format(DataFormats.crc32(buffer))
            } else if (!minipro.stopRequested) {
                message = "Reading $chip failed" to lastLines()
            }
        }
    }

    fun blankCheck() {
        if (!needsChip()) return
        runJob("Blank check $chip", listOf("-p", chip, "-b") + optionArgs("check")) { ok, _ ->
            if (!minipro.stopRequested) message = if (ok) "$chip is blank" to "Every byte reads as erased." else "$chip isn't blank" to lastLines()
        }
    }

    private fun writeBufferFile(): File? {
        if (buffer.isEmpty()) { message = "The buffer is empty" to "Open a file or read a chip first."; return null }
        val ext = if (bufferName.lowercase().endsWith(".jed") || chipInfo?.kind == ChipInfo.Kind.PLD) "jed" else "bin"
        val f = tempFile("buffer.$ext")
        f.writeBytes(buffer)
        return f
    }

    fun program() {
        if (!needsChip()) return
        val f = writeBufferFile() ?: return
        runJob("Program $chip", listOf("-p", chip, "-w", f.path) + optionArgs("write")) { ok, _ ->
            if (!minipro.stopRequested) message = if (ok) "$chip programmed" to "${buffer.size} bytes written" + (if (noVerify) "." else " and verified.")
            else "Programming failed" to lastLines()
        }
    }

    fun verify() {
        if (!needsChip()) return
        val f = writeBufferFile() ?: return
        runJob("Verify $chip", listOf("-p", chip, "-m", f.path) + optionArgs("verify")) { ok, _ ->
            if (!minipro.stopRequested) message = if (ok) "$chip matches the buffer" to "Verify OK." else "$chip differs from the buffer" to lastLines()
        }
    }

    fun erase() {
        if (!needsChip()) return
        when (val m = eraseMethod) {
            is EraseMethod.Unavailable -> message = "$chip can't be erased here" to m.why
            EraseMethod.Command -> runJob("Erase $chip", listOf("-p", chip, "-E") + optionArgs("erase")) { ok, _ ->
                if (!minipro.stopRequested) message = if (ok) "$chip erased" to "The chip was erased." else "Erase failed" to lastLines()
            }
            EraseMethod.Fill -> {
                val size = chipInfo?.codeSize ?: 0
                runJob("Blank check $chip", listOf("-p", chip, "-b")) { blank, _ ->
                    if (blank) { message = "$chip is already blank" to "Nothing was written."; return@runJob }
                    if (minipro.stopRequested) return@runJob
                    val f = tempFile("erase-fill.bin")
                    f.writeBytes(ByteArray(size) { 0xFF.toByte() })
                    runJob("Fill $chip with FF", listOf("-p", chip, "-w", f.path, "-e")) { ok, _ ->
                        if (!minipro.stopRequested) message = if (ok) "$chip erased" to "All $size bytes were written with FF and verified." else "Filling with FF failed" to lastLines()
                    }
                }
            }
        }
    }

    /** Blank check (when the chip can't be erased first), then program and verify. */
    fun autoProgram() {
        if (!needsChip()) return
        if (buffer.isEmpty()) { message = "The buffer is empty" to "Open a file or read a chip first."; return }
        val m = eraseMethod
        val then: () -> Unit = { program() }
        if (m is EraseMethod.Command) { then(); return }
        runJob("Auto: blank check $chip", listOf("-p", chip, "-b")) { ok, _ ->
            if (ok) then() else if (!minipro.stopRequested) message = "$chip isn't blank" to "Erase it first" + (if (Chips.isUVEPROM(chip)) " with UV light." else ".")
        }
    }

    fun chipInfoText(onDone: (String) -> Unit) {
        if (!needsChip()) return
        runJob("Chip info", listOf("-q", programmerType, "-d", chip), needsUsb = false) { _, out ->
            onDone(out.lines().filter { it.isNotBlank() && !it.contains("overridden database") && !it.startsWith("****") }.joinToString("\n"))
        }
    }

    enum class IdentKind(val label: String, val reference: String?) {
        EPROM28("28-pin 27-series EPROM (27C64–27C512, W27C512)", "AM27C256@DIP28"),
        EPROM32("32-pin 27-series EPROM (27C010–27C080, 27SF0x0)", "AM27C010@DIP32"),
        SPI8("SPI flash (25-series), 8 pins", null),
    }

    var identMatches by mutableStateOf<List<String>?>(null)

    fun identify(kind: IdentKind) {
        if (kind.reference != null && chip.isNotEmpty() && Chips.isEEPROM(chip)) {
            message = "Not with $chip" to "The EPROM ID read puts about 12 V on pin A9. 28-series EEPROMs aren't made for that and can be damaged."
            return
        }
        if (kind.reference == null) {
            runJob("Auto-detect SPI flash", listOf("-a", "8")) { _, out ->
                val names = out.lines().map { it.trim() }.filter { it.isNotEmpty() && !it.contains(' ') && it.contains('@') }
                    .filter { db.info(it, programmerType) != null }
                if (names.isEmpty()) message = "No SPI flash found" to lastLines() else identMatches = names
            }
            return
        }
        val ref = kind.reference
        val refInfo = db.info(ref, programmerType)
        runJob("Read ID", listOf("-p", ref, "-D", "-y")) { _, out ->
            val id = Chips.parseChipId(out)
            if (id == null || id == 0L || id == 0xFFFFL || id == 0xFFFFFFFFL) {
                message = "No chip ID could be read" to "Check that the chip sits correctly. Old NMOS EPROMs have no ID – choose them with Search."
                return@runJob
            }
            val matches = db.withId(id, programmerType, refInfo?.packageSuffix ?: "").map { it.name }
            if (matches.isEmpty()) message = "ID 0x%04X".format(id) to "No chip in the database has this ID."
            else {
                addLog("Chip ID 0x%04X: %s".format(id, matches.joinToString(", ")))
                identMatches = matches
            }
        }
    }

    fun logicTest(repeats: Int) {
        if (!needsChip()) return
        val name = chip
        testResult = null
        var failed = 0
        val failing = ArrayList<String>()
        fun next(k: Int) {
            if (k > repeats || (minipro.stopRequested && k > 1)) {
                val done = k - 1
                testResult = TestResult(name, failed == 0 && done == repeats, done, failed, failing.take(20),
                    if (done < repeats) "Stopped after $done of $repeats runs." else "")
                return
            }
            runJob(if (repeats > 1) "Logic test $name – run $k of $repeats" else "Logic test $name", listOf("-p", name, "-T")) { ok, out ->
                val f = Chips.failingVectorLines(out)
                val passed = ok && f.isEmpty()
                if (!passed && f.isEmpty() && !out.contains("Logic test failed")) {
                    testResult = TestResult(name, false, k - 1, failed, emptyList(),
                        if (minipro.stopRequested) "Stopped." else "The test didn't run: " + lastLines())
                    return@runJob
                }
                if (!passed) { failed++; if (failing.isEmpty()) failing += f }
                next(k + 1)
            }
        }
        next(1)
    }

    fun hardwareTest() {
        runJob("Programmer self-test", listOf("-t")) { ok, out ->
            val problems = out.lines().filter { l ->
                val t = l.trim()
                Regex("error|fail|short|overcurrent|bad", RegexOption.IGNORE_CASE).containsMatchIn(t) && !t.endsWith("OK")
            }
            message = if (ok && problems.isEmpty()) "Self-test passed" to "All checks passed." else "Self-test found problems" to problems.joinToString("\n").ifEmpty { lastLines() }
        }
    }

    private fun lastLines(n: Int = 4) = log.takeLast(n + 1).dropLast(1).filter { !it.startsWith("▶") }.joinToString("\n")

    // MARK: Buffer

    fun setBuffer(data: ByteArray, name: String) {
        buffer = data
        bufferName = name
        cursor = 0
        pendingNibble = null
        undo.clear()
        bufferVersion++
    }

    fun newBuffer(size: Int, fill: Int) = setBuffer(ByteArray(size) { fill.toByte() }, "new")

    fun loadFile(name: String, data: ByteArray) {
        try {
            val bytes = if (DataFormats.looksLikeIntelHex(name, data)) DataFormats.parseIntelHex(String(data, Charsets.ISO_8859_1)) else data
            setBuffer(bytes, name)
            addLog("Opened $name: ${bytes.size} bytes")
        } catch (e: Exception) {
            message = "Can't open $name" to (e.message ?: "Unknown error")
        }
    }

    fun bufferBytesFor(name: String): ByteArray =
        if (name.lowercase().endsWith(".hex")) DataFormats.toIntelHex(buffer).toByteArray(Charsets.US_ASCII) else buffer

    fun select(index: Int) {
        if (index in buffer.indices) { cursor = index; pendingNibble = null }
    }

    /** Types one hex digit at the cursor: high nibble first, then low, then moves on. */
    fun typeNibble(v: Int) {
        if (cursor !in buffer.indices) return
        val old = buffer[cursor]
        val p = pendingNibble
        val nb = buffer.copyOf()
        if (p == null) {
            nb[cursor] = ((v shl 4) or (old.toInt() and 0x0F)).toByte()
            undo += cursor to old
            pendingNibble = v
        } else {
            nb[cursor] = ((p shl 4) or v).toByte()
            pendingNibble = null
            if (cursor < buffer.size - 1) cursor++
        }
        buffer = nb
        bufferVersion++
    }

    fun undoEdit() {
        val (i, b) = undo.removeLastOrNull() ?: return
        val nb = buffer.copyOf(); nb[i] = b
        buffer = nb; cursor = i; pendingNibble = null; bufferVersion++
    }

    val canUndo: Boolean get() = undo.isNotEmpty()

    fun findHex(query: String, from: Int): Int? {
        val q = query.replace(" ", "")
        val pattern = if (q.length % 2 == 0 && q.all { it.isDigit() || it.uppercaseChar() in 'A'..'F' })
            ByteArray(q.length / 2) { q.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
        else query.toByteArray(Charsets.ISO_8859_1)
        if (pattern.isEmpty()) return null
        for (start in listOf(from, 0)) {
            var i = start
            while (i <= buffer.size - pattern.size) {
                var ok = true
                for (j in pattern.indices) if (buffer[i + j] != pattern[j]) { ok = false; break }
                if (ok) return i
                i++
            }
        }
        return null
    }

    fun fill(from: Int, to: Int, value: Int) {
        if (buffer.isEmpty()) return
        val a = from.coerceIn(0, buffer.size - 1); val b = to.coerceIn(a, buffer.size - 1)
        val nb = buffer.copyOf()
        for (i in a..b) nb[i] = value.toByte()
        buffer = nb; undo.clear(); bufferVersion++
    }
}
