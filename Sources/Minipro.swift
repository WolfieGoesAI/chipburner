import Foundation

/// Runs the minipro binary bundled inside the app (Contents/MacOS/minipro)
/// with the chip database from Contents/Resources/minipro.
final class Minipro {
    static let shared = Minipro()

    let executable: URL?

    /// Which database minipro should use when no programmer is plugged in
    /// (`-q`): TL866A, TL866II, T48 or T56. Updated by "Check Programmer".
    var programmerType = UserDefaults.standard.string(forKey: "programmerType") ?? "TL866A" {
        didSet { UserDefaults.standard.set(programmerType, forKey: "programmerType") }
    }

    /// Picks the programmer type out of `minipro -k` output (e.g. "tl866a: TL866A")
    /// and returns the model name to show, or nil if none is recognised.
    @discardableResult
    func updateProgrammerType(from output: String) -> String? {
        let up = output.uppercased()
        let models: [(key: String, type: String, display: String)] = [
            ("TL866II", "TL866II", "TL866II+"), ("T48", "T48", "T48"), ("T56", "T56", "T56"),
            ("TL866CS", "TL866A", "TL866CS"), ("TL866A", "TL866A", "TL866A"),
        ]
        for m in models where up.contains(m.key) {
            programmerType = m.type
            return m.display
        }
        return nil
    }
    let infoic: URL?
    let logicic: URL?

    private init() {
        executable = Bundle.main.url(forAuxiliaryExecutable: "minipro")
        let db = Bundle.main.resourceURL?.appendingPathComponent("minipro", isDirectory: true)
        infoic = db.map { $0.appendingPathComponent("infoic.xml") }
        logicic = db.map { $0.appendingPathComponent("logicic.xml") }
        dbArgs = computeDBArgs()   // once, at first use, before any background thread touches it
    }

    /// minipro 0.7 takes --infoic/--logicic to point at the database bundled in the app
    /// (the build checks that this minipro documents both options).
    private var dbArgs: [String] = []

    private func computeDBArgs() -> [String] {
        var args: [String] = []
        if let f = infoic, FileManager.default.fileExists(atPath: f.path) { args += ["--infoic", f.path] }
        if let f = logicic, FileManager.default.fileExists(atPath: f.path) { args += ["--logicic", f.path] }
        return args
    }

    var isAvailable: Bool {
        guard let exe = executable else { return false }
        return FileManager.default.isExecutableFile(atPath: exe.path)
    }

    private func makeProcess(_ args: [String], includeDB: Bool) -> Process? {
        guard let exe = executable else { return nil }
        let p = Process()
        p.executableURL = exe
        p.arguments = (includeDB ? dbArgs : []) + args
        p.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C"
        p.environment = env
        return p
    }

    /// Runs minipro and waits. Used for short queries (help, -k, -L, -d).
    func runSync(_ args: [String], includeDB: Bool = true) -> (status: Int32, output: String) {
        guard let p = makeProcess(args, includeDB: includeDB) else {
            return (-1, "minipro is missing from the app bundle.")
        }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "Could not start minipro: \(error.localizedDescription)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Runs minipro in the background, streaming its output.
    /// `onLine(text, isProgress)` is called on the main thread; progress lines are the ones
    /// minipro rewrites in place with a carriage return.
    @discardableResult
    func run(_ args: [String],
             onLine: @escaping (String, Bool) -> Void,
             completion: @escaping (Int32) -> Void) -> Process? {
        guard let p = makeProcess(args, includeDB: true) else {
            onLine("minipro is missing from the app bundle.", false)
            completion(-1)
            return nil
        }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let splitter = LineSplitter(onLine: onLine)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                splitter.feed(data)
            }
        }
        p.terminationHandler = { proc in
            // Drain anything still buffered before reporting completion.
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            splitter.feed(rest)
            splitter.flush()
            let status = proc.terminationStatus
            DispatchQueue.main.async { completion(status) }
        }
        do {
            try p.run()
        } catch {
            onLine("Could not start minipro: \(error.localizedDescription)", false)
            completion(-1)
            return nil
        }
        return p
    }
}

/// Splits a byte stream into lines on "\n" (finished lines) and "\r" (progress updates).
private final class LineSplitter {
    private var pending = ""
    private let lock = NSLock()
    private let onLine: (String, Bool) -> Void

    init(onLine: @escaping (String, Bool) -> Void) { self.onLine = onLine }

    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        pending += String(decoding: data, as: UTF8.self)
        var current = ""
        var out: [(String, Bool)] = []
        for ch in pending {
            if ch == "\n" {
                out.append((current, false)); current = ""
            } else if ch == "\r" {
                if !current.isEmpty { out.append((current, true)) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        pending = current
        emit(out)
    }

    func flush() {
        lock.lock(); defer { lock.unlock() }
        if !pending.isEmpty { emit([(pending, false)]); pending = "" }
    }

    private func emit(_ lines: [(String, Bool)]) {
        let cleaned = lines.map { (stripANSI($0.0).trimmingCharacters(in: .whitespaces), $0.1) }
            .filter { !$0.0.isEmpty }
        guard !cleaned.isEmpty else { return }
        let cb = onLine
        DispatchQueue.main.async { cleaned.forEach { cb($0.0, $0.1) } }
    }

    private func stripANSI(_ s: String) -> String {
        guard s.contains("\u{1B}") else { return s }
        return s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }
}
