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
let stripped = String(decoding: ChipDatabase.stripComments(Data("<a><!-- x -- y --><b/><!--z--></a>".utf8)), as: UTF8.self)
expect(stripped == "<a><b/></a>", "comments with -- inside are removed before parsing")
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
expect(ConfigText.line("lock", 0x3F, wide: false) == "lock=0x3f" && ConfigText.line("conf_word", 0x3FFB, wide: true) == "conf_word=0x3ffb" && ConfigText.parse("lfuse=0x62\nhfuse=0xd9\n") == ["lfuse": 0x62, "hfuse": 0xD9], "config text written in minipro's format")

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
// Chip tests: simulated faulty RAMs and EPROM reads
func simulateRAM(size: Int, write: Data, stuckAddressBit: Int? = nil, stuckHigh: Bool = false, dataBitStuck0: Int? = nil) -> Data {
    var cells = Data(repeating: 0, count: size)
    func map(_ a: Int) -> Int {
        guard let k = stuckAddressBit else { return a }
        return stuckHigh ? (a | (1 << k)) : (a & ~(1 << k))
    }
    for a in 0..<size { cells[map(a)] = write[a] }
    var out = Data(count: size)
    for a in 0..<size {
        var v = cells[map(a)]
        if let d = dataBitStuck0 { v &= ~UInt8(1 << d) }
        out[a] = v
    }
    return out
}
let ramSize = 0x2000
func addressTest(_ ram: (Data) -> Data) -> [Int] {
    var suspects: [Int] = []
    for p in ChipTests.Pattern.addressPatterns(for: ramSize) {
        let want = p.data(count: ramSize)
        suspects += ChipTests.compare(expected: want, got: ram(want), pattern: p).addressLineSuspects
    }
    return suspects
}
expect(addressTest { simulateRAM(size: ramSize, write: $0) }.isEmpty, "chip test: a good RAM passes the address patterns")
for (bit, high) in [(0, false), (3, false), (5, true), (8, false), (11, true), (12, false)] {
    let found = addressTest { simulateRAM(size: ramSize, write: $0, stuckAddressBit: bit, stuckHigh: high) }
    expect(found == [bit], "chip test: A\(bit) stuck \(high ? "high" : "low") is found exactly (\(found))")
}
let ffPat = ChipTests.Pattern.ones.data(count: ramSize)
let d3 = ChipTests.compare(expected: ffPat, got: simulateRAM(size: ramSize, write: ffPat, dataBitStuck0: 3), pattern: .ones)
expect(d3.badBytes == ramSize && d3.badBits == 0x08 && d3.addressLineSuspects.isEmpty, "chip test: D3 stuck at 0 shows as bit D3 in every byte")
var shaky = ChipTests.Pattern.addressLow.data(count: 1024); var shaky2 = shaky; shaky2[100] ^= 0x04; shaky2[700] ^= 0x04
let stab = ChipTests.stability([shaky, shaky2, shaky])
expect(stab.unstableBytes == 2 && stab.unstableBits == 0x04, "chip test: unstable bits between reads are found")
var lcg: UInt32 = 12345
var img = Data((0..<0x4000).map { _ -> UInt8 in lcg = lcg &* 1103515245 &+ 12345; return UInt8(truncatingIfNeeded: lcg >> 16) }); img.append(img)
let rep = ChipTests.analyse(img)
expect(rep.repeatsEvery == 0x4000, "chip test: a 16 KB image repeated in a 32 KB chip is spotted (\(rep.repeatsEvery ?? 0))")
expect(ChipTests.analyse(Data(repeating: 0xFF, count: 4096)).blank, "chip test: blank chip recognised")
let ascii = ChipTests.analyse(Data((0..<4096).map { UInt8($0 % 96 + 32) }))
expect(ascii.alwaysZero == 0x80 && ChipTests.hints(ascii).contains { $0.contains("7-bit") }, "chip test: 7-bit data recognised")
_ = shaky.count; shaky = Data()

// File formats and EPROM pair tools
let sample = Data((0..<300).map { UInt8(truncatingIfNeeded: $0 &* 7) })
expect((try? SRecord.parse(SRecord.write(sample))) == sample, "S-record round trip (S1)")
let bigS = Data(repeating: 0xA5, count: 70000)
let s2 = SRecord.write(bigS)
expect(s2.contains("\nS2") && (try? SRecord.parse(s2)) == bigS, "S-record round trip above 64 KB (S2)")
expect((try? SRecord.parse("S1130000285F245F2212226A000424290008237C2A\nS9030000FC\n"))?.prefix(4) == Data([0x28, 0x5F, 0x24, 0x5F]), "S-record: known example record with valid checksum")
expect((try? SRecord.parse("S1130000285F245F2212226A000424290008237C2B\n")) == nil, "S-record: bad checksum rejected")
expect((try? IntelHex.parse(IntelHex.write(sample))) == sample, "Intel HEX round trip")
let off = IntelHex.write(Data([1, 2, 3]), startAddress: 0x1000)
expect(off.contains(":03100000010203E7"), "Intel HEX with start address 0x1000")
let ev = Data([0x10, 0x30, 0x50]), od = Data([0x20, 0x40, 0x60])
let woven = PairTools.interleave(even: ev, odd: od)
expect(woven == Data([0x10, 0x20, 0x30, 0x40, 0x50, 0x60]) && PairTools.even(woven) == ev && PairTools.odd(woven) == od, "pair tools: interleave and split even/odd")
expect(PairTools.swap16(Data([1, 2, 3, 4, 5])) == Data([2, 1, 4, 3, 5]), "pair tools: byte swap")
expect(PairTools.lowerHalf(Data([1, 2, 3, 4])) == Data([1, 2]) && PairTools.upperHalf(Data([1, 2, 3, 4])) == Data([3, 4]), "pair tools: halves")
expect(PairTools.interleave(even: Data([1, 2]), odd: Data([9])) == Data([1, 9, 2, 0xFF]), "pair tools: shorter file padded with FF")

let plds = db.names(of: .pld, programmer: "TL866A")
print("  PLDs for TL866A (\(plds.count)): \(plds.joined(separator: " "))")

// Buffer compare
do {
    let a = Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
    var b = a; b[2] = 0xFF; b[3] = 0xFE; b[7] = 0x11
    let d = BufferDiff.compare(a, b)
    expect(d.runs == [BufferDiff.Run(start: 2, count: 2), BufferDiff.Run(start: 7, count: 1)] && d.differingBytes == 3, "compare finds two runs")
    let g = BufferDiff.compare(a, b, mergeGap: 4)
    expect(g.runs == [BufferDiff.Run(start: 2, count: 6)] && g.differingBytes == 3, "compare merges nearby runs")
    let t = BufferDiff.compare(a, a + Data([1, 2]))
    expect(t.runs.isEmpty && !t.identical && t.sizeB == 12, "compare reports a size difference")
    expect(BufferDiff.compare(a, a).identical, "identical images")
    expect(BufferDiff.compare(Data([1]), Data([2])).indexSet == IndexSet([0]), "diff index set")
}

// Pinouts
do {
    let p256 = Pinouts.find(chip: "AM27C256@DIP28", size: 32768)
    expect(p256?.title.hasPrefix("27256") == true && p256?.pins.count == 28 && p256?.pins[0] == "VPP" && p256?.pins[26] == "A14" && p256?.pins[13] == "GND", "pinout 27C256")
    let p512 = Pinouts.find(chip: "W27C512@DIP28", size: 65536)
    expect(p512?.pins[0] == "A15" && p512?.pins[21] == "/OE/VPP", "pinout 27C512")
    let p64 = Pinouts.find(chip: "2764@DIP28", size: 8192)
    expect(p64?.pins[25] == "NC" && p64?.pins[26] == "/PGM", "pinout 2764")
    let p801 = Pinouts.find(chip: "M27C801@DIP32", size: 1048576)
    expect(p801?.pins[0] == "A19" && p801?.pins[29] == "A17" && p801?.pins[30] == "A18" && p801?.pins.count == 32, "pinout 27C801")
    let e256 = Pinouts.find(chip: "AT28C256@DIP28", size: 32768)
    expect(e256?.title.hasPrefix("28C256") == true && e256?.pins[26] == "/WE" && e256?.pins[0] == "A14", "pinout 28C256")
    let f040 = Pinouts.find(chip: "SST39SF040@DIP32", size: 524288)
    expect(f040?.pins[0] == "A18" && f040?.pins[30] == "/WE" && f040?.pins[29] == "A17", "pinout 39SF040")
    let s62 = Pinouts.find(chip: "62256", size: 32768, isSRAM: true)
    expect(s62?.title.hasPrefix("62256") == true && s62?.pins[26] == "/WE" && s62?.pins[19] == "/CS", "pinout 62256")
    expect(Pinouts.find(chip: "ATMEGA328P@DIP28", size: 32768)?.pins[0] == "PC6/RESET", "pinout ATmega328P")
    expect(Pinouts.find(chip: "AT24C02@SOIC8", size: 256)?.pins[4] == "SDA", "pinout 24C02 (SO8)")
    expect(Pinouts.find(chip: "W25Q32@SOIC8", size: 4194304)?.pins[5] == "CLK", "pinout W25Q32")
    expect(Pinouts.find(chip: "GAL16V8@DIP20", size: nil)?.pins[10] == "/OE/I11", "pinout GAL16V8")
    expect(Pinouts.find(chip: "AT89C51@DIP40", size: 4096)?.pins[30] == "/EA/VPP", "pinout 8051")
    expect(Pinouts.find(chip: "AM29F040@TSOP32", size: 524288) == nil, "no pinout for TSOP")
    let m2364 = Pinouts.find(chip: "D2364C@DIP24", size: 8192)
    expect(m2364?.pins[17] == "A12" && m2364?.pins[19] == "CS" && m2364?.pins[20] == "A11", "2364 mask ROM pinout")
    // every generated layout has exactly one VCC and at least one ground
    for c in [("2716", 2048), ("2732", 4096), ("27128", 16384), ("27C010", 131072), ("27C020", 262144), ("27C040", 524288), ("28C16", 2048), ("28C64", 8192), ("6116", 2048), ("6264", 8192), ("628128", 131072), ("628512", 524288), ("29F010", 131072), ("29F020", 262144)] {
        let p = Pinouts.find(chip: c.0, size: c.1, isSRAM: c.0.hasPrefix("6"))
        let ok = p != nil && p!.pins.filter { $0 == "VCC" }.count == 1 && p!.pins.contains("GND") && p!.pins.count % 2 == 0
        expect(ok, "pinout \(c.0): \(p?.title ?? "none")")
    }
}

// Logic chip pinouts: the named pins must match the roles in minipro's test vectors.
if let xml = try? String(contentsOfFile: args[2]) {
    var checked = 0, generated = 0, problems: [String] = []
    for (chip, entry) in Pinouts.logicNames {
        guard let v = Pinouts.logicVectors(xml: xml, name: chip) else { problems.append("\(chip): not in logicic.xml"); continue }
        let items = entry.pins.split(separator: " ")
        guard items.count == v.pins else { problems.append("\(chip): \(items.count) names for \(v.pins) pins"); continue }
        let roles = Pinouts.logicRoles(v.vectors, pins: v.pins)
        for (i, item) in items.enumerated() {
            let mine = item.first!, db = roles[i]
            let name = item.split(separator: ":").last!
            let ok = mine == db || db == "n" || (mine == "i" && db == "c") || (mine == "n" && db == "i") || (mine == "b" && db != "g" && db != "v")
                || (name == "VEE") || (Pinouts.logicVectorQuirks[chip]?.contains(i + 1) ?? false)
            if !ok { problems.append("\(chip) pin \(i + 1) \(name): names say \(mine), vectors say \(db)") }
        }
        checked += 1
    }
    // Every chip in the logic database gets some pinout.
    var names: [String] = []
    var from = xml.startIndex
    while let r = xml.range(of: "<ic name=\"", range: from..<xml.endIndex), let e = xml.range(of: "\"", range: r.upperBound..<xml.endIndex) {
        names += xml[r.upperBound..<e.lowerBound].split(separator: ",").map { String($0) }
        from = e.upperBound
    }
    var missing: [String] = []
    for n in names {
        if let v = Pinouts.logicVectors(xml: xml, name: n), let p = Pinouts.logic(name: n, pins: v.pins, group: v.group, vectors: v.vectors), p.pins.count == v.pins { generated += 1 }
        else { missing.append(n) }
    }
    expect(problems.isEmpty, "logic pinout names match the test vectors (\(checked) chips)" + (problems.isEmpty ? "" : ": " + problems.prefix(12).joined(separator: "; ")))
    expect(generated > 250, "logic pinouts for \(generated) of \(names.count) names" + (missing.isEmpty ? "" : " – none for " + missing.prefix(10).joined(separator: ", ")))
    let p00 = Pinouts.find(chip: "", size: nil)  // keeps the non-logic lookup honest for empty names
    expect(p00 == nil, "no pinout for an empty name")
    if let v = Pinouts.logicVectors(xml: xml, name: "74132"), let p = Pinouts.logic(name: "74132", pins: v.pins, group: v.group, vectors: v.vectors) {
        expect(p.pins[2] == "1Y" && p.title.contains("same pinout as 7400"), "74132 uses the 7400 names")
    }
    expect(Pinouts.logicBase("SN74LS00N") == "7400" && Pinouts.logicBase("74HCT245") == "74245" && Pinouts.logicBase("CD4011BE") == "4011", "logic part numbers")
}

// PLCC32 and the extra microcontroller layouts
do {
    let c010 = Pinouts.find(chip: "AM27C010@PLCC32", size: 131072)
    expect(c010?.package == .plcc32 && c010?.pins[0] == "VPP" && c010?.pins[15] == "GND" && c010?.pins[31] == "VCC" && c010?.pins[30] == "/PGM", "PLCC32 27C010")
    let c256 = Pinouts.find(chip: "AT27C256R@PLCC32", size: 32768)
    expect(c256?.pins.count == 32 && c256?.pins[0] == "NC" && c256?.pins[1] == "VPP" && c256?.pins[10] == "A0" && c256?.pins[11] == "NC"
           && c256?.pins[12] == "D0" && c256?.pins[15] == "GND" && c256?.pins[16] == "NC" && c256?.pins[17] == "D3"
           && c256?.pins[22] == "/CE" && c256?.pins[25] == "NC" && c256?.pins[26] == "A11" && c256?.pins[31] == "VCC", "PLCC32 27C256 (28-pin chip)")
    expect(Pinouts.find(chip: "SST39SF040@PLCC32", size: 524288)?.pins[0] == "A18", "PLCC32 39SF040")
    expect(Pinouts.find(chip: "ATMEGA32A@DIP40", size: 32768)?.pins[9] == "VCC", "ATmega32 (DIP40)")
    expect(Pinouts.find(chip: "ATMEGA644PA", size: 65536)?.title.contains("644") == true, "ATmega644PA")
    expect(Pinouts.find(chip: "ATTINY84", size: 8192)?.pins[13] == "GND", "ATtiny84")
    expect(Pinouts.find(chip: "ATTINY861", size: 8192)?.pins[4] == "VCC", "ATtiny861")
    expect(Pinouts.find(chip: "PIC16F877A", size: 16384)?.pins.count == 40, "PIC16F877A (40 pins)")
    expect(Pinouts.find(chip: "PIC16F876A", size: 16384)?.pins.count == 28, "PIC16F876A (28 pins)")
    expect(Pinouts.find(chip: "PIC18F25K22", size: 32768)?.pins[19] == "VDD", "PIC18F25K22 (28 pins)")
    expect(Pinouts.find(chip: "PIC18F4550", size: 32768)?.pins[17] == "VUSB", "PIC18F4550 USB pins")
    expect(Pinouts.find(chip: "PIC18F24J10", size: 16384) == nil, "no pinout for J-series PICs")
}

// Pinout coverage for the TL866A's chips (printed for the build notes).
do {
    for (kind, label) in [(ChipInfo.Kind.memory, "memory"), (.mcu, "MCU"), (.pld, "PLD"), (.sram, "SRAM")] {
        let names = db.names(of: kind, programmer: "TL866A")
        var have = 0, dip = 0, dipHave = 0
        var pkgs: [String: Int] = [:]
        for n in names {
            let info = db.info(for: n, programmer: "TL866A")
            let p = Pinouts.find(chip: n, size: info?.codeSize, isSRAM: kind == .sram)
            if p != nil { have += 1 }
            let pkg = n.uppercased().split(separator: "@").dropFirst().first.map { String($0.prefix { $0.isLetter }) } ?? "none"
            pkgs[pkg, default: 0] += 1
            if pkg == "DIP" || pkg == "none" { dip += 1; if p != nil { dipHave += 1 } }
        }
        let top = pkgs.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        print("PINCOVER \(label): \(have) of \(names.count) have a drawing; DIP/no package \(dipHave) of \(dip); packages: \(top)")
    }
}


// Logic chip models (Extended Logic Test): each must agree with minipro's own vectors, and the generated
// sequences must match the reference generator the models were developed with.
let expectedExtended: [String: (Int, Int, UInt64)] = [
    "7400": (256, 1024, 0xa28297e3d9a12a75),
    "7402": (256, 1024, 0x74fc1ce417dd9345),
    "7404": (64, 384, 0x492233cfe3d77265),
    "7408": (256, 1024, 0x47d3a23f08195d15),
    "7410": (512, 1536, 0x9604c1979eeab4b5),
    "7411": (512, 1536, 0xa6fa855e411dd555),
    "7420": (256, 512, 0x7589a47ebeeea86d),
    "7421": (256, 512, 0xa1d69b927d41a28d),
    "7427": (512, 1536, 0xb1871c1f926cc6d5),
    "7430": (256, 256, 0x73179affd0ed9531),
    "7432": (256, 1024, 0xe09f26e63534dd75),
    "7474": (540, 2142, 0x62949a2bb921a540),
    "7486": (256, 1024, 0xb4f6a2048e139845),
    "74125": (256, 512, 0x9a8414036166ee15),
    "74126": (256, 512, 0x35679807b95e1db5),
    "74138": (64, 512, 0x4874eb594c71b26d),
    "74139": (64, 512, 0xa11f23095fe0e625),
    "74151": (4096, 8192, 0x82fd772942dc5905),
    "74153": (4096, 8192, 0xe0962355b0093725),
    "74157": (1024, 4096, 0xdf9d44be2be3f365),
    "74161": (561, 2805, 0xf077bac9355457a0),
    "74160": (555, 2464, 0x7b6fb5be68d06d57),
    "74162": (555, 2254, 0xd478233fb9ba170c),
    "74163": (561, 2657, 0xb5a409e49d40c5ee),
    "74164": (537, 4296, 0x6df6aad704e72341),
    "74165": (555, 1110, 0xa6c022a44d83e3e6),
    "74174": (533, 3198, 0xd4eeb5a91863df94),
    "74175": (529, 4232, 0x4f14bebafea24aa7),
    "74193": (580, 3480, 0x47ef7bcca7d0b2c7),
    "74240": (1024, 4096, 0x7f4593647e0f94a5),
    "74244": (1024, 4096, 0x220fa476fa80cfe5),
    "74245": (512, 4096, 0xdeeee17707065625),
    "74273": (537, 4296, 0xe645a4d939aed3ff),
    "74373": (538, 3880, 0xbaf9ec583d3d1456),
    "74374": (537, 3792, 0x5c2b2eb01d93d152),
    "74393": (568, 4536, 0x627c5a310777e0d7),
    "74541": (1024, 2048, 0x8c12902423ba33e5),
    "74573": (538, 3896, 0x0e351ca0c243f1ac),
    "74574": (537, 3920, 0x5d06e44de18e87ef),
    "74595": (554, 4586, 0x69721985dbfb6bf5),
    "7483": (512, 2560, 0xf7f7d0b76d8b3c3d),
    "7485": (2048, 6144, 0x571f826f7d1114b5),
    "7490": (560, 2072, 0x83bd027782a1743b),
    "7493": (552, 2064, 0x20c71e4c3f28d60a),
    "4001": (256, 1024, 0xcecb16b5fbac0ae5),
    "4011": (256, 1024, 0x88d1e3ba18dc9485),
    "4071": (256, 1024, 0x2c469fca26ef29c5),
    "4081": (256, 1024, 0x40c841e6ffe776e5),
    "4070": (256, 1024, 0xe847e4d74babe545),
    "4093": (256, 1024, 0x88d1e3ba18dc9485),
    "4013": (540, 2106, 0xa0e5d7fc90f99043),
    "4017": (549, 6039, 0x0a2eae31cc7e5d82),
    "4040": (4621, 55452, 0x006f24d5d8371bff),
    "4049": (64, 384, 0x65872d8dfd8ab865),
    "4050": (64, 384, 0x0b57060e268ada15),
]
if let xml = try? String(contentsOfFile: args[2]) {
    var problems: [String] = [], modelled = 0
    for (chip, entry) in Pinouts.logicNames.sorted(by: { $0.key < $1.key }) {
        let items = entry.pins.split(separator: " ")
        let names = items.map { String($0.split(separator: ":", maxSplits: 1).last ?? "") }
        let roles = items.map { $0.first ?? "i" }
        guard let model = LogicModels.model(for: chip, names: names) else { continue }
        modelled += 1
        guard let v = Pinouts.logicVectors(xml: xml, name: chip) else { problems.append("\(chip): no vectors"); continue }
        let res = LogicModels.simulate(model, names: names, vectors: v.vectors)
        var checks = 0, bad: [String] = []
        for (vi, (vec, r)) in zip(v.vectors, res).enumerated() {
            for (i, c) in vec.enumerated() where c == "L" || c == "H" {
                guard let m = r[i] else { continue }
                checks += 1
                if m != (c == "H") { bad.append("v\(vi) pin \(i + 1) \(names[i]) db \(c)") }
            }
        }
        if checks == 0 { problems.append("\(chip): no outputs checked") }
        if !bad.isEmpty { problems.append("\(chip): " + bad.prefix(4).joined(separator: ", ")) }
        guard let e = LogicModels.extended(chip: chip, names: names, roles: roles) else { problems.append("\(chip): no extended test"); continue }
        let fp = LogicModels.fingerprint(e.vectors)
        if let x = expectedExtended[chip] {
            if x.0 != e.vectors.count || x.1 != e.checks || x.2 != fp {
                problems.append("\(chip): extended \(e.vectors.count)/\(e.checks)/\(String(fp, radix: 16)) vs reference \(x.0)/\(x.1)/\(String(x.2, radix: 16))")
            }
        } else { problems.append("\(chip): no reference") }
        let t = LogicTest(name: chip, pins: names.count, voltage: "5V", vectors: e.vectors)
        if !t.problems().isEmpty { problems.append("\(chip): " + t.problems()[0]) }
        if e.phases.map({ $0.range.count }).reduce(0, +) != e.vectors.count { problems.append("\(chip): phases don't cover the vectors") }
    }
    expect(problems.isEmpty && modelled == expectedExtended.count, "logic models agree with minipro's vectors (\(modelled) models)" + (problems.isEmpty ? "" : ": " + problems.prefix(10).joined(separator: "; ")))
    let g = LogicModels.pins(for: "74132", xml: xml)
    expect(g?.key == "7400", "74132 is tested with the 7400 model")
    expect(LogicModels.pins(for: "74LS161", xml: xml)?.key == "74161" || LogicModels.pins(for: "74161", xml: xml)?.key == "74161", "74161 model found")
    var all: [String] = [], have = 0
    var from = xml.startIndex
    while let r = xml.range(of: "<ic name=\"", range: from..<xml.endIndex), let e = xml.range(of: "\"", range: r.upperBound..<xml.endIndex) {
        all += xml[r.upperBound..<e.lowerBound].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        from = e.upperBound
    }
    for n in all where LogicModels.pins(for: n, xml: xml) != nil { have += 1 }
    print("LOGICMODELS: \(have) of \(all.count) logic chip names have an exhaustive or sequence test")
}

// Health check: reads are compared one at a time with the first
do {
    let base = Data((0..<8).map { UInt8($0) })
    let acc = ChipTests.StabilityAccumulator(base: base)
    var b = base; b[3] = 0x13
    var c = base; c[3] = 0x13; c[5] = 0x45
    acc.add(base); acc.add(b); acc.add(base); acc.add(c)
    let r = acc.result()
    let c3 = r.counts.first { $0.address == 3 }?.counts.map { "\($0.value)x\($0.count)" } ?? []
    let c5 = r.counts.first { $0.address == 5 }?.counts.map { "\($0.value)x\($0.count)" } ?? []
    expect(acc.reads == 5 && r.unstableBytes == 2 && r.unstableBits == 0x50 && c3 == ["3x3", "19x2"] && c5 == ["5x4", "69x1"],
           "health check counts unstable bytes read by read (\(r.unstableBytes), \(c3), \(c5))")
}

print(failed ? "DBTEST FAILED" : "DBTEST OK")
exit(failed ? 1 : 0)
