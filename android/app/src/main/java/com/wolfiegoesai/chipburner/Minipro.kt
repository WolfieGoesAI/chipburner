package com.wolfiegoesai.chipburner

import android.content.Context
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.os.ParcelFileDescriptor
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.util.UUID
import kotlin.concurrent.thread

/**
 * Runs the minipro program packed in the app (lib/<abi>/libminipro.so) with the chip database copied
 * from the app's assets. The programmer's USB connection is handed to minipro over a Unix socket:
 * the app opens the device through UsbManager and sends minipro the file descriptor.
 */
class Minipro(private val context: Context) {
    val executable: File get() = File(context.applicationInfo.nativeLibraryDir, "libminipro.so")
    private val dbDir = File(context.filesDir, "minipro")
    val infoic: File get() = File(dbDir, "infoic.xml")
    val logicic: File get() = File(dbDir, "logicic.xml")
    val workDir: File get() = File(context.cacheDir, "work").apply { mkdirs() }

    @Volatile private var current: Process? = null
    @Volatile var stopRequested = false
        private set

    /** Copies the database out of the APK when the app is new or updated. */
    fun prepareDatabase() {
        val version = runCatching { context.assets.open("minipro/VERSION.txt").bufferedReader().use { it.readText() } }.getOrDefault("")
        val stamp = File(dbDir, "VERSION.txt")
        if (stamp.exists() && stamp.readText() == version && infoic.exists()) return
        dbDir.mkdirs()
        for (name in listOf("infoic.xml", "logicic.xml", "SOURCE.txt")) {
            runCatching {
                context.assets.open("minipro/$name").use { input ->
                    File(dbDir, name).outputStream().use { input.copyTo(it, 1 shl 16) }
                }
            }
        }
        stamp.writeText(version)
    }

    val sourceInfo: String
        get() = runCatching { File(dbDir, "SOURCE.txt").readText() }.getOrDefault("")

    /**
     * Runs minipro and blocks until it exits; call it off the main thread.
     * [onLine] gets each output line and whether it is a progress line (rewritten in place with \r).
     */
    fun run(
        args: List<String>,
        usbFd: Int?,
        logicOverride: File? = null,
        onLine: (String, Boolean) -> Unit,
    ): Int {
        stopRequested = false
        val db = mutableListOf<String>()
        if (infoic.exists()) db += listOf("--infoic", infoic.path)
        val logic = logicOverride ?: logicic
        if (logic.exists()) db += listOf("--logicic", logic.path)

        val socketName = "chipburner-usb-" + UUID.randomUUID().toString()
        var server: LocalServerSocket? = null
        if (usbFd != null) {
            val s = LocalServerSocket(socketName)
            server = s
            thread(isDaemon = true, name = "usb-fd-sender") {
                try {
                    val client = s.accept()
                    try {
                        val dup = ParcelFileDescriptor.fromFd(usbFd)
                        client.setFileDescriptorsForSend(arrayOf(dup.fileDescriptor))
                        client.outputStream.write(1)
                        client.outputStream.flush()
                        dup.close()
                    } finally {
                        client.close()
                    }
                } catch (_: IOException) {
                }
            }
        }

        val pb = ProcessBuilder(listOf(executable.path) + db + args)
            .directory(workDir)
        pb.environment()["LC_ALL"] = "C"
        pb.environment()["TMPDIR"] = context.cacheDir.path
        if (usbFd != null) pb.environment()["CHIPBURNER_USB_SOCKET"] = socketName

        val process = try {
            pb.start()
        } catch (e: IOException) {
            onLine("Could not start minipro: ${e.message}", false)
            server?.let { closeServer(it, socketName) }
            return -1
        }
        current = process
        runCatching { process.outputStream.close() }
        // stdout and stderr read separately: through one stream a stderr message could land in the middle of a
        // stdout table row ("Logic test successful." was cut into a vector line and lost).
        val lock = Any()
        val emit: (String, Boolean) -> Unit = { line, progress -> synchronized(lock) { onLine(line, progress) } }
        fun pump(input: java.io.InputStream) {
            val splitter = LineSplitter(emit)
            val buf = ByteArray(8192)
            try {
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    splitter.feed(buf, n)
                }
            } catch (_: IOException) {
            }
            splitter.finish()
        }
        val errThread = thread(isDaemon = true, name = "minipro-stderr") { pump(process.errorStream) }
        pump(process.inputStream)
        errThread.join()
        val code = process.waitFor()
        current = null
        server?.let { closeServer(it, socketName) }
        return code
    }

    /** Runs minipro and returns the exit code and the whole output. */
    fun runCollect(args: List<String>, usbFd: Int?, logicOverride: File? = null): Pair<Int, String> {
        val sb = StringBuilder()
        val code = run(args, usbFd, logicOverride) { line, progress -> if (!progress) sb.append(line).append('\n') }
        return code to sb.toString()
    }

    fun stop() {
        stopRequested = true
        current?.destroy()
    }

    private fun closeServer(server: LocalServerSocket, name: String) {
        // accept() may still be waiting (minipro didn't need the programmer): connect once to release it.
        runCatching { LocalSocket().use { it.connect(LocalSocketAddress(name)) } }
        runCatching { server.close() }
    }
}

/** Splits minipro's output into lines; text ended by a lone \r is a progress line. */
class LineSplitter(private val onLine: (String, Boolean) -> Unit) {
    private val line = ByteArrayOutputStream()
    private var pendingCR = false

    fun feed(bytes: ByteArray, count: Int) {
        for (i in 0 until count) {
            val b = bytes[i]
            if (pendingCR) {
                pendingCR = false
                if (b == '\n'.code.toByte()) {
                    emit(false); continue
                }
                emit(true)
            }
            when (b) {
                '\n'.code.toByte() -> emit(false)
                '\r'.code.toByte() -> pendingCR = true
                else -> line.write(b.toInt())
            }
        }
    }

    fun finish() {
        if (pendingCR) {
            pendingCR = false
            emit(true)
        }
        if (line.size() > 0) emit(false)
    }

    private fun emit(progress: Boolean) {
        val text = stripAnsi(line.toString(Charsets.UTF_8.name()))
        line.reset()
        if (text.isNotBlank() || !progress) onLine(text, progress)
    }

    companion object {
        private val ansi = Regex("\u001B\\[[0-9;?]*[A-Za-z]")
        fun stripAnsi(s: String) = ansi.replace(s, "")
    }
}
