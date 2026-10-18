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
    /// "TL866A – Serial 227631… – Firmware 03.2.86" from `minipro -k` output
    /// ("Found TL866A 03.2.86 (0x256)" … "Serial code: 227631…").
    /// "03.2.86" from "Found TL866A 03.2.86 (0x256)".
    static func firmwareVersion(from output: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "Found\\s+\\S+\\s+(\\d+\\.\\d+\\.\\d+)"),
              let m = re.firstMatch(in: output, range: NSRange(location: 0, length: (output as NSString).length)) else { return nil }
        return (output as NSString).substring(with: m.range(at: 1))
    }

    static func programmerSummary(model: String, from output: String) -> String {
        var parts = [model]
        func match(_ pattern: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return nil }
            let ns = output as NSString
            guard let m = re.firstMatch(in: output, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
            return ns.substring(with: m.range(at: 1))
        }
        if let serial = match("Serial code:\\s*([0-9A-Fa-f]+)") { parts.append("Serial " + serial) }
        if let fw = match("Found\\s+\\S+\\s+(\\d+\\.\\d+\\.\\d+)") { parts.append("Firmware " + fw) }
        return parts.joined(separator: " – ")
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

    private func makeProcess(_ args: [String], includeDB: Bool, logicic override: URL? = nil) -> Process? {
        guard let exe = executable else { return nil }
        let p = Process()
        p.executableURL = exe
        var db = includeDB ? dbArgs : []
        if let o = override {
            // A custom logic test file replaces the bundled logic database for this run.
            db = (infoic.map { ["--infoic", $0.path] } ?? []) + ["--logicic", o.path]
        }
        p.arguments = db + args
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
    func run(_ args: [String], logicic: URL? = nil,
             onLine: @escaping (String, Bool) -> Void,
             completion: @escaping (Int32) -> Void) -> Process? {
        guard let p = makeProcess(args, includeDB: true, logicic: logicic) else {
            onLine("minipro is missing from the app bundle.", false)
            completion(-1)
            return nil
        }
        guard Minipro.stream(p, onLine: onLine, completion: completion) else { return nil }
        return p
    }

    /// Starts `p` with stdout+stderr piped into a LineSplitter; `completion` runs on the main queue
    /// after the process has exited and every line has been delivered. Returns false if it didn't start.
    static func stream(_ p: Process, deliverOnMain: Bool = true,
                       onLine: @escaping (String, Bool) -> Void,
                       completion: @escaping (Int32) -> Void) -> Bool {
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let splitter = LineSplitter(deliverOnMain: deliverOnMain, onLine: onLine)
        // One reader only: the output is read on one queue until end-of-file, and completion is
        // reported once both the reading has finished and the process has exited. (Draining the pipe
        // from the termination handler as well raced with the reader – minipro writes long tables in
        // one burst at exit, and chunks were lost or spliced in the wrong order.)
        let finished = DispatchGroup()
        finished.enter()   // reading
        finished.enter()   // process exit
        let reader = pipe.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                let data = reader.availableData
                if data.isEmpty { break }
                splitter.feed(data)
            }
            splitter.flush()
            finished.leave()
        }
        p.terminationHandler = { _ in finished.leave() }
        finished.notify(queue: .main) {
            completion(p.terminationStatus)
        }
        do {
            try p.run()
        } catch {
            pipe.fileHandleForWriting.closeFile()   // lets the reader see end-of-file
            onLine("Could not start minipro: \(error.localizedDescription)", false)
            completion(-1)
            return false
        }
        return true
    }
}

/// Splits a byte stream into lines on "\n" (finished lines) and "\r" (progress updates).
/// Works on bytes, so a "\r\n" pair or a UTF-8 character split between two reads is handled.
final class LineSplitter {
    private var pending = Data()
    private let lock = NSLock()
    private let onLine: (String, Bool) -> Void
    private let deliverOnMain: Bool

    init(deliverOnMain: Bool = true, onLine: @escaping (String, Bool) -> Void) {
        self.onLine = onLine
        self.deliverOnMain = deliverOnMain
    }

    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        let bytes = [UInt8](pending)
        var out: [(String, Bool)] = []
        var start = 0
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x0A {
                out.append((String(decoding: bytes[start..<i], as: UTF8.self), false))
                start = i + 1
            } else if b == 0x0D {
                if i + 1 == bytes.count { break }                // wait: it may be "\r\n"
                if bytes[i + 1] == 0x0A {
                    out.append((String(decoding: bytes[start..<i], as: UTF8.self), false))
                    i += 1
                } else if i > start {
                    out.append((String(decoding: bytes[start..<i], as: UTF8.self), true))
                }
                start = i + 1
            }
            i += 1
        }
        pending = Data(bytes[start...])
        emit(out)
    }

    func flush() {
        lock.lock(); defer { lock.unlock() }
        var rest = [UInt8](pending)
        if rest.last == 0x0D { rest.removeLast() }
        if !rest.isEmpty { emit([(String(decoding: rest, as: UTF8.self), false)]) }
        pending = Data()
    }

    private func emit(_ lines: [(String, Bool)]) {
        let cleaned = lines.map { (LineSplitter.stripANSI($0.0).trimmingCharacters(in: .whitespaces), $0.1) }
            .filter { !$0.0.isEmpty }
        guard !cleaned.isEmpty else { return }
        let cb = onLine
        if deliverOnMain { DispatchQueue.main.async { cleaned.forEach { cb($0.0, $0.1) } } }
        else { cleaned.forEach { cb($0.0, $0.1) } }
    }

    static func stripANSI(_ s: String) -> String {
        guard s.contains("\u{1B}") else { return s }
        return s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }
}
