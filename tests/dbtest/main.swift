import Foundation

// Build-time test for ChipDatabase.swift against the real minipro database.
// Usage: dbtest infoic.xml logicic.xml
let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: dbtest infoic.xml logicic.xml"); exit(2) }
let db = ChipDatabase.shared
let t0 = Date()
db.load(infoic: URL(fileURLWithPath: args[1]), logicic: URL(fileURLWithPath: args[2]))
print(String(format: "loaded %d entries in %.1fs", db.count, Date().timeIntervalSince(t0)))
print("database sections: \(db.databaseTypes.joined(separator: ", "))")
print("load error: \(db.loadError ?? "none")")
for p in ["TL866A", "TL866II", "T48", "T56"] { print("programmer \(p) -> \(db.databaseName(for: p) ?? "none")") }

var failed = false
func expect(_ ok: Bool, _ what: String) { print((ok ? "ok   " : "FAIL ") + what); if !ok { failed = true } }

for n in ["AM27C256@DIP28", "M27C512@DIP28", "GAL16V8", "7400", "ATMEGA328P@DIP28", "PIC16F84A", "AT28C256@DIP28"] {
    print("  \(n): \(db.info(for: n, programmer: "TL866A")?.summary ?? "not found")")
}
let am = db.info(for: "AM27C256@DIP28", programmer: "TL866A")
expect(db.count > 1000, "database has entries")
expect(am != nil && am!.kind == .memory && am!.codeSize == 0x8000, "AM27C256@DIP28 is a 32 KB memory chip")
expect(db.info(for: "7400", programmer: "TL866A")?.kind == .logic, "7400 is a logic chip")
expect(db.info(for: "GAL16V8", programmer: "TL866A")?.kind == .pld, "GAL16V8 is a PLD")

let m = db.chips(withID: 0x0110, programmer: "TL866A", packageSuffix: "@DIP28").map { $0.name }
print("  ID 0x0110 @DIP28 (TL866A): \(m.prefix(15).joined(separator: ", "))\(m.count > 15 ? " …" : "")")
expect(m.contains("AM27C256@DIP28"), "ID 0x0110 finds AM27C256@DIP28")
let st = db.chips(withID: 0x208D, programmer: "TL866A", packageSuffix: "@DIP28").map { $0.name }
print("  ID 0x208D @DIP28 (TL866A): \(st.prefix(15).joined(separator: ", "))")
expect(!st.isEmpty, "ID 0x208D finds ST 27C256 parts")

let samples: [(String, UInt32?)] = [
    ("Chip ID: 0x0110  OK", 0x0110),
    ("Chip ID mismatch: expected 0x0110, got 0x208D.", 0x208D),
    ("Chip ID: 0x208D", 0x208D),
    ("No chip found", nil),
]
for (s, want) in samples {
    let got = ChipIDParser.parse(s)
    expect(got == want, "ID parser: \"\(s)\" -> \(got.map { String(format: "0x%04X", $0) } ?? "nil")")
}

// Logic auto-identify candidates
print("  logic pin counts: \(db.logicPinCounts.map(String.init).joined(separator: ", "))")
for pins in [14, 16, 20, 24] {
    let std = db.logicGroups(pins: pins, standardPowerOnly: true)
    let all = db.logicGroups(pins: pins, standardPowerOnly: false, voltage: "")
    print("  \(pins)-pin logic groups: \(std.count) standard-power 5V of \(all.count) total")
}
let g14 = db.logicGroups(pins: 14, standardPowerOnly: true)
expect(g14.contains(where: { $0.contains("7400") }), "14-pin standard groups include 7400")
if let i7490 = db.info(for: "7490", programmer: "TL866A") {
    print("  7490: GND \(i7490.gndPins) VCC \(i7490.vccPins) standard=\(i7490.hasStandardPower)")
    expect(!g14.contains(where: { $0.contains("7490") }), "7490 (VCC on pin 5) is left out of the standard scan")
}
let i7400 = db.info(for: "7400", programmer: "TL866A")
expect(i7400?.gndPins == [7] && i7400?.vccPins == [14], "7400 power pins are GND 7, VCC 14")

// minipro -d parsing (samples captured from minipro 0.7.4)
let amd = ChipCapabilities.parse("Name: AM27C256@DIP28\nAvailable on: TL866A/CS\nMemory: 32768 Bytes\nPackage: DIP28\nICSP: -\nProtocol: 0x31\n*******************************\nVPP programming voltage: 13.5V\nVDD write voltage: 6.5V\nVCC verify voltage: 5V\nPulse delay: 100us")
expect(!amd.icspSupported && amd.vpp == "13.5V" && amd.vdd == "6.5V" && amd.vcc == "5V" && amd.pulse == "100us", "AM27C256 -d: no ICSP, defaults 13.5/6.5/5 V, 100 us")
let pic = ChipCapabilities.parse("Name: PIC16F84A\nPackage: DIP18\nICSP: ICP002.JPG\nProtocol: 0x63")
expect(pic.icspSupported && !pic.hasVoltageOptions, "PIC16F84A -d: ICSP capable, no voltage options")
let gal = ChipCapabilities.parse("Name: GAL16V8\nICSP: -\n*******************************\nVPP programming voltage: 16V")
expect(gal.vpp == "16V" && gal.vdd == nil, "GAL16V8 -d: VPP 16 V only")
var ov = VoltageOverrides(); ov.vpp = "12.5"; ov.pulse = "50"
expect(ov.args == ["-o", "vpp=12.5", "-o", "pulse=50"], "voltage overrides become -o vpp=12.5 -o pulse=50")

for n in ["X28C256", "AT28C256", "W27C512@DIP28", "AM27C256@DIP28", "GAL16V8", "SST39SF010A"] {
    if let i = db.info(for: n, programmer: "TL866A") {
        print("  \(n): flags " + String(format: "0x%08X", i.flags) + " canErase \(i.canErase.map { "\($0)" } ?? "unknown")")
    }
}
expect(db.info(for: "GAL16V8", programmer: "TL866A")?.canErase == true, "GAL16V8 has an erase command")
expect(db.info(for: "AM27C256@DIP28", programmer: "TL866A")?.canErase == false, "AM27C256 (UV EPROM) has no erase command")

for n in ["PIC16F84A", "PIC16F628A", "ATMEGA8A", "ATMEGA88PA", "ATTINY2313", "AT89C2051", "AT89S52"] {
    guard let i = db.info(for: n, programmer: "TL866A") else { print("  \(n): not found"); continue }
    if let c = db.config(for: i) {
        let f = c.fuses.map { String(format: "%@ mask %04X def %04X", $0.name, $0.mask, $0.defaultValue) }
        let l = c.locks.map { String(format: "%@ mask %04X def %04X", $0.name, $0.mask, $0.defaultValue) }
        print("  \(n) config \(i.configName): fuses [\(f.joined(separator: "; "))] locks [\(l.joined(separator: "; "))] userIDs \(c.userIDs) other \(c.otherSections)")
    } else { print("  \(n): config '\(i.configName)' – none found") }
}
expect(db.info(for: "ATMEGA8A", programmer: "TL866A").flatMap { db.config(for: $0) }.map { !$0.fuses.isEmpty } == true, "ATMEGA8A has fuses")
expect(db.info(for: "PIC16F84A", programmer: "TL866A").flatMap { db.config(for: $0) }.map { !$0.isEmpty } == true, "PIC16F84A has a config layout")

let spi = SPIAutodetect.parse("Found TL866A 03.2.86 (0x256)\nDevice code: 12345\nAutodetecting device (ID:0xEF4016)\n2 device(s) found.\nW25Q32BV@SOIC8\nW25Q32FV@SOIC8\n")
expect(spi.id == 0xEF4016 && spi.names == ["W25Q32BV@SOIC8", "W25Q32FV@SOIC8"], "SPI autodetect output parsed: ID and 2 names")

let cfg = ConfigText.parse("lfuse = 0xe1\nhfuse = 0xd9\nlock = 0x3f\nconf_word = 0x3ffb\nuser_id0 = 0x0001\ncalibration bytes: 0x9a, 0x9b\n")
expect(cfg == ["lfuse": 0xE1, "hfuse": 0xD9, "lock": 0x3F, "conf_word": 0x3FFB, "user_id0": 0x0001], "config text parsed")
expect(ConfigText.line("lock", 0x3F, wide: false) == "lock = 0x3f" && ConfigText.line("conf_word", 0x3FFB, wide: true) == "conf_word = 0x3ffb", "config text written in minipro's format")

let plds = db.names(of: .pld, programmer: "TL866A")
print("  PLDs for TL866A (\(plds.count)): \(plds.joined(separator: " "))")

print(failed ? "DBTEST FAILED" : "DBTEST OK")
exit(failed ? 1 : 0)
