import Foundation

/// What the app needs to know about one chip from minipro's infoic.xml / logicic.xml.
struct ChipInfo {
    enum Kind: Int {
        case memory = 1, mcu = 2, pld = 3, sram = 4, logic = 5, nand = 6, emmc = 7, video = 8, unknown = 0

        var label: String {
            switch self {
            case .memory: return "Memory (EPROM/EEPROM/flash)"
            case .mcu: return "Microcontroller"
            case .pld: return "PLD/GAL"
            case .sram: return "SRAM"
            case .logic: return "Logic IC"
            case .nand: return "NAND flash"
            case .emmc: return "eMMC/SD"
            case .video: return "VGA/HDMI"
            case .unknown: return "Unknown type"
            }
        }
    }

    let name: String
    let kind: Kind
    let chipID: UInt32
    let codeSize: Int
    let dataSize: Int
    let database: String   // e.g. INFOIC, INFOIC2PLUS, LOGIC
    let pins: Int          // logic chips only
    var flags: UInt32 = 0  // minipro device flags (bit 0x10 = chip has an erase command)
    var hasFlags = false
    /// nil when the database entry carries no flags.
    var canErase: Bool? { hasFlags ? (flags & 0x10) != 0 : nil }
    // Logic chips only:
    var group: String = ""        // names sharing the same test vectors, e.g. "7400,7437,74132"
    var voltage: String = ""      // test supply, e.g. "5V"
    var gndPins: [Int] = []       // pins the vectors tie to ground ("G")
    var vccPins: [Int] = []       // pins the vectors tie to supply ("V")

    /// Ground on the last pin of the first row and supply on the last pin – the usual DIP logic layout.
    var hasStandardPower: Bool { pins > 0 && gndPins == [pins / 2] && vccPins == [pins] }

    /// "@DIP28" style package suffix, or "" when the name has none.
    var packageSuffix: String {
        guard let at = name.firstIndex(of: "@") else { return "" }
        return String(name[at...])
    }

    var sizeText: String {
        func fmt(_ n: Int) -> String {
            if n >= 1024 * 1024, n % (1024 * 1024) == 0 { return "\(n / (1024 * 1024)) MB" }
            if n >= 1024, n % 1024 == 0 { return "\(n / 1024) KB" }
            return "\(n) bytes"
        }
        var parts: [String] = []
        if codeSize > 0 { parts.append(kind == .pld ? "\(codeSize) fuses" : fmt(codeSize)) }
        if dataSize > 0 { parts.append("+ \(fmt(dataSize)) data EEPROM") }
        return parts.joined(separator: " ")
    }

    var summary: String {
        var s = kind.label
        if kind == .logic { s += pins > 0 ? " · \(pins) pins" : "" }
        else if !sizeText.isEmpty { s += " · \(sizeText)" }
        if chipID != 0 { s += String(format: " · ID 0x%04X", chipID) }
        return s
    }
}

/// Loads minipro's XML databases once and answers lookups by name and by chip ID.
final class ChipDatabase {
    static let shared = ChipDatabase()

    private(set) var isLoaded = false
    private(set) var loadError: String?
    private var byName: [String: [ChipInfo]] = [:]   // uppercased name -> entries (one per database)
    private(set) var databaseTypes: [String] = []
    private var all: [ChipInfo] = []
    private let lock = NSLock()

    /// Parses both files (call off the main thread; takes a second or two).
    func load(infoic: URL?, logicic: URL?) {
        var entries: [ChipInfo] = []
        var types: [String] = []
        var errors: [String] = []
        for url in [infoic, logicic].compactMap({ $0 }) {
            guard let parser = XMLParser(contentsOf: url) else { errors.append("Can't open \(url.lastPathComponent)"); continue }
            let d = Delegate()
            parser.delegate = d
            if !parser.parse() {
                errors.append("\(url.lastPathComponent): \(parser.parserError?.localizedDescription ?? "parse error")")
            }
            entries += d.entries
            for t in d.types where !types.contains(t) { types.append(t) }
        }
        var index: [String: [ChipInfo]] = [:]
        for e in entries { index[e.name.uppercased(), default: []].append(e) }
        lock.lock()
        all = entries
        byName = index
        databaseTypes = types
        loadError = errors.isEmpty ? nil : errors.joined(separator: "; ")
        isLoaded = true
        lock.unlock()
    }

    /// The infoic database section that belongs to a programmer type (TL866A, TL866II, T48, T56).
    func databaseName(for programmer: String) -> String? {
        let p = programmer.uppercased()
        let candidates = databaseTypes.filter { $0 != "LOGIC" }
        func find(_ pred: (String) -> Bool) -> String? { candidates.first(where: pred) }
        switch p {
        case "TL866A", "TL866CS": return find { $0 == "INFOIC" } ?? find { !$0.contains("2PLUS") && !$0.contains("T56") && !$0.contains("T76") }
        case "TL866II", "T48": return find { $0.contains("2PLUS") }
        case "T56": return find { $0.contains("T56") }
        default: return nil
        }
    }

    /// Looks a chip up for the given programmer (logic chips are shared by all programmers).
    func info(for name: String, programmer: String) -> ChipInfo? {
        lock.lock(); defer { lock.unlock() }
        guard let list = byName[name.uppercased()], !list.isEmpty else { return nil }
        if let db = databaseName(for: programmer), let hit = list.first(where: { $0.database == db }) { return hit }
        return list.first(where: { $0.database == "LOGIC" }) ?? list.first
    }

    /// All chips with this ID in the programmer's database, optionally limited to one package suffix.
    func chips(withID id: UInt32, programmer: String, packageSuffix: String?) -> [ChipInfo] {
        guard id != 0 else { return [] }
        lock.lock(); defer { lock.unlock() }
        let db = databaseName(for: programmer)
        return all.filter { c in
            c.chipID == id
                && (db == nil || c.database == db)
                && (packageSuffix == nil || packageSuffix!.isEmpty || c.packageSuffix.uppercased() == packageSuffix!.uppercased())
        }
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return all.count }

    /// Logic chip groups (chips sharing test vectors) with this pin count, for auto-identify.
    /// Each group is returned once, as its list of names.
    func logicGroups(pins: Int, standardPowerOnly: Bool, voltage: String = "5V") -> [[String]] {
        lock.lock(); defer { lock.unlock() }
        var seen = Set<String>()
        var out: [[String]] = []
        for c in all where c.kind == .logic && c.pins == pins {
            if standardPowerOnly && !c.hasStandardPower { continue }
            if !voltage.isEmpty && c.voltage.uppercased() != voltage.uppercased() { continue }
            guard seen.insert(c.group).inserted else { continue }
            out.append(c.group.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
        return out
    }

    /// Names of all chips of one kind in a programmer's database section, sorted.
    func names(of kind: ChipInfo.Kind, programmer: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        let db = databaseName(for: programmer)
        return all.filter { $0.kind == kind && (db == nil || $0.database == db) }.map { $0.name }.sorted()
    }

    /// Pin counts that occur among logic chips, smallest first.
    var logicPinCounts: [Int] {
        lock.lock(); defer { lock.unlock() }
        return Array(Set(all.filter { $0.kind == .logic && $0.pins > 0 }.map { $0.pins })).sorted()
    }

    // MARK: XML

    private final class Delegate: NSObject, XMLParserDelegate {
        var entries: [ChipInfo] = []
        var types: [String] = []
        private var database = ""
        // Logic chip being read: entries are added once its first vector shows the power pins.
        private var pendingLogic: (names: String, pins: Int, voltage: String)?
        private var vectorText: String?
        private var logicDone = false

        private func hex(_ s: String?) -> UInt32 {
            guard var s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return 0 }
            if s.hasPrefix("0x") || s.hasPrefix("0X") { s.removeFirst(2); return UInt32(s, radix: 16) ?? 0 }
            return UInt32(s) ?? 0
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attr: [String: String] = [:]) {
            switch elementName {
            case "database":
                database = attr["type"] ?? ""
                if !types.contains(database) { types.append(database) }
            case "ic" where database == "LOGIC":
                guard let names = attr["name"] else { return }
                pendingLogic = (names, Int(attr["pins"] ?? "") ?? 0, attr["voltage"] ?? "")
                logicDone = false
            case "vector" where pendingLogic != nil && !logicDone:
                vectorText = ""
            case "ic":
                guard let names = attr["name"] else { return }
                let kind = ChipInfo.Kind(rawValue: Int(attr["type"] ?? "") ?? 0) ?? .unknown
                let id = hex(attr["chip_id"])
                let code = Int(hex(attr["code_memory_size"]))
                let data = Int(hex(attr["data_memory_size"]))
                let pins = Int(attr["pins"] ?? "") ?? 0
                let flagText = attr["flags"]
                let flags = hex(flagText)
                for n in names.split(separator: ",") {
                    let name = n.trimmingCharacters(in: .whitespaces)
                    if name.isEmpty { continue }
                    var info = ChipInfo(name: name, kind: database == "LOGIC" ? .logic : kind, chipID: id,
                                        codeSize: code, dataSize: data, database: database, pins: pins)
                    info.flags = flags
                    info.hasFlags = flagText != nil
                    entries.append(info)
                }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if vectorText != nil { vectorText! += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == "vector", let text = vectorText {
                vectorText = nil
                addLogic(vector: text)
            } else if elementName == "ic", pendingLogic != nil {
                if !logicDone { addLogic(vector: nil) }
                pendingLogic = nil
            }
        }

        private func addLogic(vector: String?) {
            guard let p = pendingLogic, !logicDone else { return }
            logicDone = true
            var gnd: [Int] = [], vcc: [Int] = []
            if let v = vector {
                let tokens = v.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
                for (i, t) in tokens.enumerated() {
                    if t == "G" { gnd.append(i + 1) } else if t == "V" { vcc.append(i + 1) }
                }
            }
            for n in p.names.split(separator: ",") {
                let name = n.trimmingCharacters(in: .whitespaces)
                if name.isEmpty { continue }
                entries.append(ChipInfo(name: name, kind: .logic, chipID: 0, codeSize: 0, dataSize: 0,
                                        database: "LOGIC", pins: p.pins, group: p.names, voltage: p.voltage,
                                        gndPins: gnd, vccPins: vcc))
            }
        }
    }
}

/// Pulls the chip ID that `minipro -D` reports out of its output.
enum ChipIDParser {
    static func parse(_ output: String) -> UInt32? {
        let lines = output.components(separatedBy: .newlines).filter { $0.range(of: "id", options: .caseInsensitive) != nil }
        let re = try? NSRegularExpression(pattern: "0x([0-9A-Fa-f]+)")
        for line in lines.reversed() {
            let ns = line as NSString
            let matches = re?.matches(in: line, range: NSRange(location: 0, length: ns.length)) ?? []
            guard !matches.isEmpty else { continue }
            // In "expected 0x0110, got 0x208D" style lines the value read is after "got".
            if let gotRange = line.range(of: "got", options: .caseInsensitive) {
                let gotPos = line.distance(from: line.startIndex, to: gotRange.lowerBound)
                if let m = matches.first(where: { $0.range.location > gotPos }) {
                    return UInt32(ns.substring(with: m.range(at: 1)), radix: 16)
                }
            }
            if let m = matches.last { return UInt32(ns.substring(with: m.range(at: 1)), radix: 16) }
        }
        return nil
    }
}
