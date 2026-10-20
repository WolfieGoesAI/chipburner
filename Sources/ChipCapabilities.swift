import Foundation

/// What `minipro -d <chip>` says about ICSP support and the default programming voltages.
struct ChipCapabilities {
    var icspSupported = false
    var vpp: String?      // default programming voltage, e.g. "13.5V"
    var vdd: String?      // default write VDD
    var vcc: String?      // default verify VCC
    var pulse: String?    // default pulse delay, e.g. "100us"
    var logicVCC: String? // logic ICs: the logic-test supply ("Default VCC voltage: 5 V") – shown, never adjustable here

    var hasVoltageOptions: Bool { vpp != nil || vdd != nil || vcc != nil || pulse != nil }

    /// Parses minipro -d output. minipro 0.7.4+ prints "Default VPP programming voltage: 13.5 V",
    /// "Default VDD write voltage: 6.5 V", "Default VCC verify voltage: 5 V", "Default write pulse: 100 us"
    /// (each followed by an "Available …" list); older versions printed "VPP programming voltage: 13.5V" and
    /// "Pulse delay: 100us". Values are kept without spaces ("13.5V", "100us").
    static func parse(_ output: String) -> ChipCapabilities {
        var c = ChipCapabilities()
        for raw in output.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            var key = line[..<colon].lowercased()
            if key.hasPrefix("available") { continue }
            if key.hasPrefix("default ") { key = String(key.dropFirst("default ".count)) }
            let rawValue = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let value = rawValue.replacingOccurrences(of: " ", with: "")
            if key == "icsp" { c.icspSupported = !rawValue.isEmpty && rawValue != "-" }
            else if value.isEmpty { continue }
            else if key == "vcc voltage" { c.logicVCC = value }
            else if key.hasPrefix("vpp") { c.vpp = value }
            else if key.hasPrefix("vdd") { c.vdd = value }
            else if key.hasPrefix("vcc") { c.vcc = value }
            else if key.contains("pulse") { c.pulse = value }
        }
        return c
    }
}

/// Programming voltage overrides chosen in the Voltages sheet (nil = chip default).
struct VoltageOverrides: Equatable {
    var vpp: String?
    var vdd: String?
    var vcc: String?
    var pulse: String?

    var isEmpty: Bool { vpp == nil && vdd == nil && vcc == nil && pulse == nil }

    /// minipro's documented "-o name=value" form.
    var args: [String] {
        var a: [String] = []
        if let v = vpp { a += ["-o", "vpp=\(v)"] }
        if let v = vdd { a += ["-o", "vdd=\(v)"] }
        if let v = vcc { a += ["-o", "vcc=\(v)"] }
        if let v = pulse { a += ["-o", "pulse=\(v)"] }
        return a
    }

    var summary: String {
        if isEmpty { return "chip defaults" }
        var p: [String] = []
        if let v = vpp { p.append("VPP \(v) V") }
        if let v = vdd { p.append("VDD \(v) V") }
        if let v = vcc { p.append("VCC \(v) V") }
        if let v = pulse { p.append("pulse \(v) µs") }
        return p.joined(separator: ", ")
    }

    /// Voltage steps minipro accepts per programmer family (from minipro's manual).
    static func vppChoices(for programmer: String) -> [String] {
        programmer.uppercased() == "TL866A"
            ? ["10", "12.5", "13.5", "14", "15.5", "16", "17", "18", "21"]
            : ["9", "9.5", "10", "11", "11.5", "12", "12.5", "13", "13.5", "14", "14.5", "15.5", "16", "16.5", "17", "19"]
    }
    static let supplyChoices = ["3.3", "4", "4.5", "5", "5.5", "6.5"]
}

/// Reads what `minipro -a 8|16` prints: "Autodetecting device (ID:0xEF4016)" on stderr and the
/// matching chip names, one per line, on stdout (which can arrive in any order through a pipe).
enum SPIAutodetect {
    static func parse(_ output: String) -> (id: UInt32?, names: [String]) {
        var id: UInt32?
        var names: [String] = []
        let idRE = try? NSRegularExpression(pattern: "ID:\\s*0x([0-9A-Fa-f]+)")
        for raw in output.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let ns = line as NSString
            if let m = idRE?.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                id = UInt32(ns.substring(with: m.range(at: 1)), radix: 16)
                continue
            }
            // Chip names have no spaces; minipro's messages all do.
            if !line.isEmpty, line.rangeOfCharacter(from: .whitespaces) == nil,
               line.range(of: "^[A-Za-z0-9][A-Za-z0-9_.@()+/,-]*$", options: .regularExpression) != nil,
               !names.contains(line) {
                names.append(line)
            }
        }
        return (id, names)
    }
}

/// "name = 0xVALUE" text that minipro reads and writes for the config page (-c config).
enum ConfigText {
    static func parse(_ text: String) -> [String: UInt16] {
        var out: [String: UInt16] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let parts = raw.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            var v = parts[1].trimmingCharacters(in: .whitespaces)
            guard v.lowercased().hasPrefix("0x") else { continue }
            v.removeFirst(2)
            if let n = UInt16(v.prefix { $0.isHexDigit }, radix: 16) { out[name] = n }
        }
        return out
    }

    /// Exactly the layout minipro itself writes ("lfuse=0x62", no spaces): its config reader doesn't
    /// accept spaces around the '='.
    static func line(_ name: String, _ value: UInt16, wide: Bool) -> String {
        String(format: wide ? "%@=0x%04x" : "%@=0x%02x", name, value)
    }
}

