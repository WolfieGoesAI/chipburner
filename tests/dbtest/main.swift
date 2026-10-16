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
expect(db.loadError == nil, "the whole database file parses")
expect(db.databaseName(for: "TL866A") != nil, "the TL866A section is present")
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
expect(db.info(for: "PIC16F84A", programmer: "TL866A").flatMap { db.config(for: $0) }.map { $0.userIDs > 0 && !$0.fuses.isEmpty } == true, "PIC16F84A has a config word and user IDs")
expect(db.info(for: "PIC16F84A", programmer: "TL866A")?.wordSize == 2 && db.info(for: "ATMEGA8A", programmer: "TL866A")?.wordSize == 1, "word size: PIC 2 bytes, AVR 1 byte")

let spi = SPIAutodetect.parse("Found TL866A 03.2.86 (0x256)\nDevice code: 12345\nAutodetecting device (ID:0xEF4016)\n2 device(s) found.\nW25Q32BV@SOIC8\nW25Q32FV@SOIC8\n")
expect(spi.id == 0xEF4016 && spi.names == ["W25Q32BV@SOIC8", "W25Q32FV@SOIC8"], "SPI autodetect output parsed: ID and 2 names")

let cfg = ConfigText.parse("lfuse = 0xe1\nhfuse = 0xd9\nlock = 0x3f\nconf_word = 0x3ffb\nuser_id0 = 0x0001\ncalibration bytes: 0x9a, 0x9b\n")
expect(cfg == ["lfuse": 0xE1, "hfuse": 0xD9, "lock": 0x3F, "conf_word": 0x3FFB, "user_id0": 0x0001], "config text parsed")
expect(ConfigText.line("lock", 0x3F, wide: false) == "lock = 0x3f" && ConfigText.line("conf_word", 0x3FFB, wide: true) == "conf_word = 0x3ffb", "config text written in minipro's format")

// Which chips have fuses / user ID / lock bits (the Fuses & Locks window), by family.
var families: [String: (count: Int, f: Bool, u: Bool, l: Bool, kinds: Set<String>, examples: [String])] = [:]
for kind in [ChipInfo.Kind.mcu, .memory, .pld, .sram, .unknown] {
    for n in db.names(of: kind, programmer: "TL866A") {
        guard let i = db.info(for: n, programmer: "TL866A"), let c = db.config(for: i), !c.isEmpty else { continue }
        let base = n.split(separator: "@")[0].uppercased()
        let letters = String(base.prefix { $0.isLetter })
        var fam = letters
        if letters.count <= 3, let r = base.range(of: "^[A-Z]+[0-9]+[A-Z]*", options: .regularExpression) { fam = String(base[r]) }
        var e = families[fam] ?? (0, false, false, false, [], [])
        e.count += 1; e.f = e.f || !c.fuses.isEmpty; e.u = e.u || c.userIDs > 0; e.l = e.l || !c.locks.isEmpty
        e.kinds.insert(kind.label)
        if e.examples.count < 4 && !e.examples.contains(base) { e.examples.append(base) }
        families[fam] = e
    }
}
print("TL866A entries: memory \(db.names(of: .memory, programmer: "TL866A").count), MCU \(db.names(of: .mcu, programmer: "TL866A").count), PLD \(db.names(of: .pld, programmer: "TL866A").count), SRAM \(db.names(of: .sram, programmer: "TL866A").count), logic \(db.names(of: .logic, programmer: "TL866A").count)")
print("FUSES-AND-LOCKS families (TL866A): \(families.count), chips: \(families.values.map { $0.count }.reduce(0, +))")
for (k, v) in families.sorted(by: { $0.value.count > $1.value.count }) {
    let s = [v.f ? "fuses" : nil, v.u ? "user ID" : nil, v.l ? "lock" : nil].compactMap { $0 }.joined(separator: "+")
    print("FL \(k): \(v.count) [\(s)] \(v.kinds.sorted().joined(separator: "/")) e.g. \(v.examples.joined(separator: ", "))")
}

// Buffer editing
var eb = EditableBuffer(Data([0x00, 0x11, 0x22, 0x33]))
eb.setByte(1, 0xAA)
eb.replace(2..<4, with: Data([0xFF, 0xFF, 0xFF]))
expect(eb.data == Data([0x00, 0xAA, 0xFF, 0xFF, 0xFF]), "buffer edits: set byte, replace with longer range")
eb.undo(); expect(eb.data == Data([0x00, 0xAA, 0x22, 0x33]), "undo restores the replaced range")
eb.undo(); expect(eb.data == Data([0x00, 0x11, 0x22, 0x33]) && !eb.canUndo, "undo restores the byte")
eb.redo(); eb.redo(); expect(eb.data == Data([0x00, 0xAA, 0xFF, 0xFF, 0xFF]) && !eb.canRedo, "redo replays both edits")
eb.replace(1..<5, with: Data()); expect(eb.data == Data([0x00]), "truncate"); eb.undo(); expect(eb.count == 5, "undo truncate")
expect(BufferOps.parseNumber("1F00") == 0x1F00 && BufferOps.parseNumber("0x10") == 16 && BufferOps.parseNumber("$FF") == 255
       && BufferOps.parseNumber("100h") == 256 && BufferOps.parseNumber("#100") == 100 && BufferOps.parseNumber("32K") == 32768
       && BufferOps.parseNumber("xyz") == nil, "number parsing: hex, 0x, $, h, #decimal, K")
expect(BufferOps.parsePattern("55 AA") ?? [] == [0x55, 0xAA] && BufferOps.parsePattern("55AA") ?? [] == [0x55, 0xAA]
       && BufferOps.parsePattern("C3 ?? 12") ?? [] == [0xC3, nil, 0x12] && BufferOps.parsePattern("\"AB\"") ?? [] == [0x41, 0x42]
       && BufferOps.parsePattern("ZZ") == nil, "pattern parsing: hex, packed hex, wildcard, text")
let hay = Data([0x00, 0xC3, 0x10, 0x20, 0xC3, 0x99, 0x20])
expect(BufferOps.find([0xC3, nil, 0x20], in: hay, from: 0) == 1 && BufferOps.find([0xC3, nil, 0x20], in: hay, from: 2) == 4
       && BufferOps.find([0xC3, nil, 0x20], in: hay, from: 5) == 1 && BufferOps.find([0x77], in: hay, from: 0) == nil, "find with wildcard and wrap-around")
expect(BufferOps.fill(count: 5, pattern: [0x55, 0xAA]) == Data([0x55, 0xAA, 0x55, 0xAA, 0x55]), "fill with repeating pattern")
let cs = BufferOps.checksums(Data("123456789".utf8))
expect(cs.crc32 == 0xCBF43926 && cs.sum16 == 0x01DD && cs.sum8 == 0xDD && cs.twosComplement8 == 0x23 && cs.xor8 == 0x31, "checksums of \"123456789\" (CRC-32 check value CBF43926)")

let srams = db.names(of: .sram, programmer: "TL866A")
print("SRAM TL866A: \(srams.count): \(srams.prefix(60).joined(separator: " "))")
let logicAll = db.names(of: .logic, programmer: "TL866A")
let dramish = logicAll.filter { $0.range(of: "^(41|44|TMS4|MK4|HM50|KM41|MB81|D41|UPD41|4164|41256)", options: .regularExpression) != nil }
print("DRAMLOGIC: \(dramish.count): \(dramish.prefix(40).joined(separator: " "))")
let notTTL = logicAll.filter { $0.range(of: "^(74|54|40|45|CD4|HEF|MC14)", options: .regularExpression) == nil }
print("LOGICNAMES non-74/4000 (\(notTTL.count)): \(notTTL.prefix(80).joined(separator: " "))")
let plds = db.names(of: .pld, programmer: "TL866A")
print("  PLDs for TL866A (\(plds.count)): \(plds.joined(separator: " "))")

print(failed ? "DBTEST FAILED" : "DBTEST OK")
exit(failed ? 1 : 0)
