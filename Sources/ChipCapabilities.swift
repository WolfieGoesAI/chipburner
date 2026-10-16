import Foundation

/// What `minipro -d <chip>` says about ICSP support and the default programming voltages.
struct ChipCapabilities {
    var icspSupported = false
    var vpp: String?      // default programming voltage, e.g. "13.5V"
    var vdd: String?      // default write VDD
    var vcc: String?      // default verify VCC
    var pulse: String?    // default pulse delay, e.g. "100us"

    var hasVoltageOptions: Bool { vpp != nil || vdd != nil || vcc != nil || pulse != nil }

    /// Parses lines like "ICSP: -", "VPP programming voltage: 13.5V", "Pulse delay: 100us".
    static func parse(_ output: String) -> ChipCapabilities {
        var c = ChipCapabilities()
        for raw in output.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key == "icsp" { c.icspSupported = !value.isEmpty && value != "-" }
            else if key.hasPrefix("vpp") { c.vpp = value }
            else if key.hasPrefix("vdd") { c.vdd = value }
            else if key.hasPrefix("vcc") { c.vcc = value }
            else if key.hasPrefix("pulse") { c.pulse = value }
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
