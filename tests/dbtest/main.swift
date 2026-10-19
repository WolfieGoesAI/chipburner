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
expect(db.info(for: "23128@DIP28", programmer: "TL866A").map { $0.codeSize == 16384 && $0.canErase != true } == true
       && db.info(for: "23256@DIP28", programmer: "TL866A").map { $0.codeSize == 32768 } == true
       && db.info(for: "23C256@DIP28", programmer: "TL866A") != nil
       && db.info(for: "23128@DIP28", programmer: "TL866II") != nil, "23128/23256 mask ROMs in the TL866A and TL866II databases (patch-minipro.sh)")
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
    let m23128 = Pinouts.find(chip: "23128@DIP28", size: 16384)
    expect(m23128?.pins[0] == "NC" && m23128?.pins[19] == "/CS2" && m23128?.pins[21] == "/CS1" && m23128?.pins[25] == "A13" && m23128?.pins[26] == "CS3", "23128 mask ROM pinout")
    let m23256 = Pinouts.find(chip: "23256@DIP28", size: 32768)
    expect(m23256?.pins[0] == "NC/CS" && m23256?.pins[19] == "CE" && m23256?.pins[21] == "OE" && m23256?.pins[26] == "A14", "23256 mask ROM pinout")
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
// MARK: Helpers for the logic model checks

let expectedDsl: [String: (Int, Int, UInt64)] = [
    "4000": (128, 384, 0x4080ef7668c71aed),
    "4002": (256, 512, 0xd36fc18857c4e4cd),
    "4008": (512, 2560, 0x9079ec4c86ef167d),
    "4009": (64, 384, 0x241dcb4137ba82a5),
    "4010": (64, 384, 0x09a381e35463eb55),
    "40104": (1079, 3626, 0xd6be93c77f55c2a4),
    "4012": (256, 512, 0x527ba57ce360942d),
    "4015": (914, 7296, 0x03909e7bb88aaa1d),
    "40161": (1153, 5765, 0xcae5e3b698111d05),
    "40162": (1196, 5423, 0x553ec20859ad07e6),
    "40163": (1217, 5790, 0x8cde15190e8c689b),
    "40174": (894, 5364, 0x80dd4f109871b57a),
    "40175": (899, 7192, 0x9a2036aaac4605c0),
    "4019": (1024, 4096, 0x5da0bf786dc2d8d5),
    "40192": (1308, 4872, 0x634dcec6a06dc9a3),
    "40193": (1303, 7818, 0xf82350e3c8c1d8f2),
    "4020": (4679, 56148, 0x475d45d78b60bfa8),
    "4021": (971, 2913, 0xd2eea51e1abc5cb0),
    "4022": (670, 6030, 0x868cdc61dc8beeee),
    "4023": (512, 1536, 0x29cae5e4aefbc8a5),
    "4024": (709, 4963, 0xf2c2e75d518d998a),
    "4025": (512, 1536, 0xe68f960f1fd1d165),
    "4027": (1230, 4906, 0x476aaecaaef1881e),
    "4028": (16, 160, 0x259b1ff79eaf954d),
    "4030": (256, 1024, 0xe847e4d74babe545),
    "4041": (16, 128, 0x3e0987da9d5e77cd),
    "4042": (716, 5728, 0xb0d7c1f7d17827a5),
    "4043": (878, 3012, 0xd7fddb4c6d03b286),
    "4044": (863, 2928, 0x451e61b1f1a3d136),
    "4060": (4677, 56124, 0xbaf49ed0bf0c1d00),
    "4063": (2048, 6144, 0x4a3937c425206b15),
    "4068": (256, 256, 0x4d99f96429b07869),
    "4072": (256, 512, 0x2edd11d8475e003d),
    "4073": (512, 1536, 0xcf33a638d329e285),
    "4075": (512, 1536, 0xb6fa56daa8ea4dc5),
    "4076": (1240, 3880, 0xf2fc8bec0ea4cbd4),
    "4077": (256, 1024, 0x9ccc681c61b9a5c5),
    "4078": (256, 256, 0x08afad6e2a2d3bf1),
    "4082": (256, 512, 0x407b37fd6612279d),
    "4099": (1205, 9619, 0xda7ae5bedbdf1630),
    "4503": (256, 768, 0xd94b71b0066e6d05),
    "4510": (1165, 5482, 0x2d3ab62b3dc9e2f6),
    "4511": (605, 4235, 0x30ed3c1308bccb70),
    "4512": (2078, 1038, 0x901ac767fdea5897),
    "4514": (826, 13216, 0xcbb92892cf239144),
    "4515": (826, 13216, 0x4861a3bc07a0a622),
    "4516": (1201, 6005, 0x4954bf94354c732f),
    "4518": (785, 6272, 0x09a9c7fe5d9558cb),
    "4519": (1024, 4096, 0x1522591a2799f685),
    "4520": (821, 6560, 0xb93f724f6f3119b7),
    "4531": (2078, 2078, 0xe93678e83b2bc58c),
    "4532": (512, 2560, 0xda9d929c2913674d),
    "4543": (595, 4165, 0xc20f7a7490be8b40),
    "4555": (64, 512, 0x4685b720731786a5),
    "4556": (64, 512, 0xa11f23095fe0e625),
    "4572": (256, 1536, 0xb3c4923b7d0125e5),
    "7401": (256, 1024, 0xac164413b1842615),
    "7403": (256, 1024, 0x5b8163519e01f6e5),
    "7405@OC": (64, 384, 0x2c9d11b0cbcca4d5),
    "7407": (64, 384, 0xff46f3f0524822e5),
    "7407@OC": (64, 384, 0x802f91aa6cea58f5),
    "7409": (256, 1024, 0x1ec6da1e5df58c25),
    "74107": (993, 3964, 0x8259a67b08849888),
    "74109": (1179, 4700, 0xff270a21b50d8036),
    "74112": (1156, 4610, 0x34a52a85ad4cdbc1),
    "74113": (983, 3924, 0xf211f6146373b36c),
    "74114": (1083, 4324, 0x1a86418384b1e05c),
    "74133": (2078, 2078, 0x3d41fab60c3e318a),
    "74136": (256, 1024, 0x0a1ad250cf565685),
    "74137": (595, 4760, 0x3bf3723794ee5dcd),
    "74147": (512, 2048, 0x54fe55ee773aa861),
    "74148": (512, 2560, 0xe0033955105962ad),
    "7415": (512, 1536, 0x85075505a9e01535),
    "74150": (2094, 2094, 0x9d9f21cd2c1cf94e),
    "74154": (64, 1024, 0x23e7664c09147b35),
    "74155": (64, 512, 0x7eb906eebdf8343d),
    "74156": (64, 512, 0xef4795b958061e15),
    "74158": (1024, 4096, 0x4431aee2ae0b43e5),
    "74166": (1120, 1120, 0x9be050d9cbd16625),
    "74168": (1190, 5235, 0xf1c2338a36232795),
    "74173": (1229, 3944, 0x084e0e46780f879e),
    "74177": (1052, 4208, 0x5984c8f4f634dbde),
    "74181": (2088, 8352, 0x767b43cba0979986),
    "74182": (512, 2560, 0x6ad815e1854538fd),
    "7419": (64, 384, 0x492233cfe3d77265),
    "74190": (1093, 5882, 0xfef3aa3e52765d1b),
    "74191": (1105, 6630, 0x5f742c9675c33a50),
    "74194": (1160, 4640, 0xb5804e97fcfc6bfd),
    "74195": (1013, 5065, 0x979e92975039c131),
    "7422": (256, 512, 0x3302973a59b6311d),
    "74237": (596, 4768, 0x5478c29ea0daef76),
    "74238": (64, 512, 0x5cd78e686a09ae2d),
    "7424": (256, 1024, 0xa28297e3d9a12a75),
    "74241": (1024, 4096, 0xda659d0c7d239a65),
    "74242": (32, 128, 0x8e75fd36d778d155),
    "74243": (32, 128, 0x0e21bd45ba5f5875),
    "74247": (128, 896, 0xcc5f00202cecfaf1),
    "74248": (128, 896, 0x9963e30e8433a315),
    "74249": (128, 896, 0x9abb799e21c74589),
    "74250": (2094, 1064, 0xbe96f466c999ef8f),
    "74251": (4096, 4096, 0x869a38c6c2c4a705),
    "74253": (4096, 4096, 0x73e0d04a7de83825),
    "74257": (1024, 2048, 0xb690ff8a16726a65),
    "74258": (1024, 2048, 0xf4f96619156d3665),
    "74259": (1252, 9997, 0x0cb226ae549ea080),
    "7426": (256, 1024, 0x5b8163519e01f6e5),
    "74260": (1024, 2048, 0xbf89fd63f57e7425),
    "74266": (256, 1024, 0x7fd8f0e52f04b365),
    "74279": (931, 3692, 0xc893cab7d26e498f),
    "74280": (512, 1024, 0x6176e93d27a7eee5),
    "74283": (512, 2048, 0xc3a2f89b6eb7c875),
    "74290": (778, 2972, 0xab2342a9e6cedaf7),
    "74293": (668, 2536, 0xe83d49dd8d7cd9a2),
    "74298": (950, 3784, 0x84e37dcda366c4fe),
    "74347": (128, 896, 0xa8f2d55521018bbd),
    "74348": (512, 1789, 0x48aaee92f0abebfd),
    "74365": (256, 384, 0xefdaea7fd62cdfe5),
    "74366": (256, 384, 0xd057c0911fca7fe5),
    "74367": (256, 768, 0xd94b71b0066e6d05),
    "74368": (256, 768, 0x1f3448daef4877e5),
    "74375": (696, 5556, 0x39b0ad11341ada7c),
    "74377": (921, 7336, 0x7df7e3c523de3d53),
    "74378": (934, 5580, 0x09ec47bbb6f9f04e),
    "74379": (902, 7184, 0x9cf989119b601237),
    "74390": (716, 5720, 0xcef447322cb2912b),
    "74395": (1076, 4808, 0x0fbeb54c824f6043),
    "74399": (971, 3868, 0xb79f20ee0f8111ef),
    "7442": (16, 160, 0x002de275c064e45d),
    "74445": (16, 160, 0xb29aa203baddb8b1),
    "7447": (64, 512, 0xd39c66b9524deda9),
    "74490": (790, 6304, 0x6bdf525e3f681154),
    "7450": (1024, 2048, 0xa1292150a93b5545),
    "7451": (256, 512, 0xe7c2bb4be6a8bc65),
    "74533": (710, 4864, 0xaa3b78e6a155cc16),
    "74534": (936, 6448, 0xbf64b513a9d96d29),
    "7454": (256, 256, 0x90ed8fd287ffa1c9),
    "74540": (1024, 2048, 0xe7ed270c6a4d53a5),
    "7455": (256, 256, 0x3d7c436e584cd681),
    "74563": (704, 4784, 0x97277c638f78e444),
    "74564": (924, 6240, 0x36a3574d6473a15a),
    "74589": (1095, 929, 0x6a7e3d50cb9bcaa7),
    "74597": (1050, 1030, 0x265f7952a5466a9a),
    "74623": (512, 4096, 0xb8b8d24c96a44365),
    "7464": (2048, 2048, 0xe8e51c5e50b805f9),
    "74640": (512, 4096, 0x3b2ca825af5e5b65),
    "74641": (512, 4096, 0x02d9269a9b53cac5),
    "74642": (512, 4096, 0xa189799f1f4ed4e5),
    "74643": (512, 4096, 0xf8ba2e27733a0ca5),
    "74644": (512, 4096, 0x9cede49fd75d98e5),
    "74645": (512, 4096, 0xdeeee17707065625),
    "7465": (2048, 2048, 0x25b0ef636ed5112b),
    "74688": (2086, 2086, 0x2a5e68423269c1fb),
    "7472": (1010, 2020, 0xe9efb597c88fb0f4),
    "7473": (1021, 4076, 0x3a2ef75e444fcc9b),
    "7475": (702, 5600, 0xf91500da1089602d),
    "7476": (1188, 4736, 0xab892f153a41175b),
    "7487": (64, 256, 0x01acd6ca398e1ed5),
    "74906": (64, 384, 0xd28be0590b56f575),
    "7492": (677, 2544, 0x205586779433c053),
    "7495": (928, 3678, 0xa9d9ca70c7efe556),
    "74LS54": (1024, 1024, 0x987e3d89be380e61),
]

/// Every <ic> group of the logic database with its pin count and vectors.
func allLogicGroups(_ xml: String) -> [(names: [String], pins: Int, vectors: [[Character]])] {
    var out: [(names: [String], pins: Int, vectors: [[Character]])] = []
    var from = xml.startIndex
    while let r = xml.range(of: "<ic ", range: from..<xml.endIndex) {
        guard let tagEnd = xml.range(of: ">", range: r.upperBound..<xml.endIndex),
              let close = xml.range(of: "</ic>", range: tagEnd.upperBound..<xml.endIndex) else { break }
        let tag = String(xml[r.lowerBound..<tagEnd.upperBound])
        func attr(_ n: String) -> String? {
            guard let a = tag.range(of: n + "=\""), let e = tag.range(of: "\"", range: a.upperBound..<tag.endIndex) else { return nil }
            return String(tag[a.upperBound..<e.lowerBound])
        }
        let body = xml[tagEnd.upperBound..<close.lowerBound]
        var vectors: [[Character]] = []
        var vf = body.startIndex
        while let v = body.range(of: "<vector", range: vf..<body.endIndex),
              let gt = body.range(of: ">", range: v.upperBound..<body.endIndex),
              let ve = body.range(of: "</vector>", range: gt.upperBound..<body.endIndex) {
            vectors.append(Array(body[gt.upperBound..<ve.lowerBound].filter { !$0.isWhitespace }))
            vf = ve.upperBound
        }
        let names = (attr("name") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        out.append((names, Int(attr("pins") ?? "") ?? vectors.first?.count ?? 0, vectors))
        from = close.upperBound
    }
    return out
}

/// Pins applied one at a time (pin 1 first, or the last first), then C pins pulsed – the way a step races.
func simulateOrdered(_ model: LogicModels.Model, names: [String], vectors: [[Character]], ascending: Bool) -> [[Int: Bool]] {
    let s = LogicSim(names: names)
    var level = [Bool](repeating: false, count: names.count)
    var cur = [Bool?](repeating: nil, count: names.count)
    var results: [[Int: Bool]] = []
    func step(_ next: [Bool?]) { s.prev = s.cur; s.cur = next; s.out = []; model.step(s) }
    for vec in vectors {
        var clocks: [Int] = []
        let order = ascending ? Array(vec.indices) : vec.indices.reversed()
        for i in order where i < names.count {
            let c = vec[i]
            let nv: Bool? = c == "0" ? false : c == "1" ? true : c == "C" ? level[i] : nil
            if c == "C" { clocks.append(i) }
            if cur[i] != nv { cur[i] = nv; step(cur) }
        }
        step(cur)
        if !clocks.isEmpty {
            for i in clocks { cur[i] = true }; step(cur)
            for i in clocks { cur[i] = false }; step(cur)
        }
        for (i, c) in vec.enumerated() where i < names.count { if c == "0" || c == "1" { level[i] = c == "1" } else if c == "C" { level[i] = false } }
        var r: [Int: Bool] = [:]
        for (n, value) in s.out { if let i = s.idx(n), let b = value { r[i] = b } }
        results.append(r)
    }
    return results
}

/// The ZIF socket set in 8-pin groups, one group after another (a DIP chip sits bottom-aligned).
func simulateGrouped(_ model: LogicModels.Model, names: [String], vectors: [[Character]]) -> [[Int: Bool]] {
    let n = names.count
    func zif(_ p: Int) -> Int { p < n / 2 ? p + 1 : p + 1 + (40 - n) }
    let groups = Dictionary(grouping: 0..<n, by: { (zif($0) - 1) / 8 }).sorted { $0.key < $1.key }.map { $0.value }
    let s = LogicSim(names: names)
    var level = [Bool](repeating: false, count: n)
    var cur = [Bool?](repeating: nil, count: n)
    var results: [[Int: Bool]] = []
    func step(_ next: [Bool?]) { s.prev = s.cur; s.cur = next; s.out = []; model.step(s) }
    for vec in vectors {
        var clocks: [Int] = []
        for g in groups {
            var changed = false
            for i in g {
                let c = vec[i]
                let nv: Bool? = c == "0" ? false : c == "1" ? true : c == "C" ? level[i] : nil
                if c == "C" { clocks.append(i) }
                if cur[i] != nv { cur[i] = nv; changed = true }
            }
            if changed { step(cur) }
        }
        step(cur)
        if !clocks.isEmpty {
            for i in clocks { cur[i] = true }; step(cur)
            for i in clocks { cur[i] = false }; step(cur)
        }
        for (i, c) in vec.enumerated() where i < n { if c == "0" || c == "1" { level[i] = c == "1" } else if c == "C" { level[i] = false } }
        var r: [Int: Bool] = [:]
        for (nm, value) in s.out { if let i = s.idx(nm), let b = value { r[i] = b } }
        results.append(r)
    }
    return results
}

/// Outputs of the generated test that would differ if the pins of a step were set one at a time.
func raceMismatches(_ chip: String, names: [String], _ e: LogicModels.Extended) -> Int {
    let inputs = e.vectors.map { v in v.map { $0 == "H" || $0 == "L" || $0 == "Z" ? Character("X") : $0 } }
    var bad = 0
    for asc in [true, false] {
        guard let m = LogicModels.model(for: chip, names: names) else { return 1 }
        let ord = simulateOrdered(m, names: names, vectors: inputs, ascending: asc)
        for (vi, v) in e.vectors.enumerated() {
            for (i, c) in v.enumerated() where c == "H" || c == "L" || c == "Z" {
                if ord[vi][i] != (c != "L") { bad += 1 }
            }
        }
    }
    return bad
}


let expectedExtended: [String: (Int, Int, UInt64)] = [
    "4001": (256, 1024, 0xcecb16b5fbac0ae5),
    "4011": (256, 1024, 0x88d1e3ba18dc9485),
    "4013": (1120, 4466, 0xa3cd1236a70976c5),
    "4017": (642, 7062, 0x8f3a3204554390fc),
    "4040": (4666, 55992, 0x9fa54c7e3927d9fa),
    "4049": (64, 384, 0x65872d8dfd8ab865),
    "4050": (64, 384, 0x0b57060e268ada15),
    "4070": (256, 1024, 0xe847e4d74babe545),
    "4071": (256, 1024, 0x2c469fca26ef29c5),
    "4081": (256, 1024, 0x40c841e6ffe776e5),
    "4093": (256, 1024, 0x88d1e3ba18dc9485),
    "7400": (256, 1024, 0xa28297e3d9a12a75),
    "7402": (256, 1024, 0x74fc1ce417dd9345),
    "7404": (64, 384, 0x492233cfe3d77265),
    "7408": (256, 1024, 0x47d3a23f08195d15),
    "7410": (512, 1536, 0x9604c1979eeab4b5),
    "7411": (512, 1536, 0xa6fa855e411dd555),
    "74125": (256, 512, 0x9a8414036166ee15),
    "74126": (256, 512, 0x35679807b95e1db5),
    "74138": (64, 512, 0x4874eb594c71b26d),
    "74139": (64, 512, 0xa11f23095fe0e625),
    "74151": (4096, 8192, 0x82fd772942dc5905),
    "74153": (4096, 8192, 0xe0962355b0093725),
    "74157": (1024, 4096, 0xdf9d44be2be3f365),
    "74160": (1200, 5372, 0xa51944ad10d1ce5e),
    "74161": (1198, 5990, 0x5a47b704d18b42ba),
    "74162": (1151, 4712, 0xd15f8e44533f3615),
    "74163": (1217, 5785, 0xa09c72de4bbc54e4),
    "74164": (843, 6744, 0x29d53de556efdf70),
    "74165": (1097, 2194, 0x38e01b928374e937),
    "74174": (927, 5562, 0xfad86e4caef7750e),
    "74175": (905, 7240, 0xe18baa20be0f7219),
    "74193": (1352, 8112, 0x41275907171345ce),
    "7420": (256, 512, 0x7589a47ebeeea86d),
    "7421": (256, 512, 0xa1d69b927d41a28d),
    "74240": (1024, 4096, 0x7f4593647e0f94a5),
    "74244": (1024, 4096, 0x220fa476fa80cfe5),
    "74245": (512, 4096, 0xdeeee17707065625),
    "7427": (512, 1536, 0xb1871c1f926cc6d5),
    "74273": (934, 7472, 0x8300b1e6c472abb6),
    "7430": (256, 256, 0x73179affd0ed9531),
    "7432": (256, 1024, 0xe09f26e63534dd75),
    "74373": (860, 5976, 0x2221ce3c8bcfd046),
    "74374": (960, 6504, 0x493b6c3339de6608),
    "74393": (683, 5456, 0xfa1de3b6a4470eb9),
    "74541": (1024, 2048, 0x8c12902423ba33e5),
    "74573": (877, 6104, 0x72d8440dbf7c7918),
    "74574": (928, 6576, 0x62623743178c0173),
    "74595": (856, 6848, 0x39b99a98b5d64cfb),
    "7474": (1078, 4302, 0x207b391c2db1f500),
    "7483": (512, 2560, 0xf7f7d0b76d8b3c3d),
    "7485": (2048, 6144, 0x571f826f7d1114b5),
    "7486": (256, 1024, 0xb4f6a2048e139845),
    "7490": (811, 3092, 0x3ba182e443621c9a),
    "7493": (654, 2484, 0x3d9d0df639f6a5c5),
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

    // Models from logic-models.txt: they must agree with minipro's vectors, give the reference test vectors
    // (the Android build generates the same ones) and be free of pin-order races.
    if args.count > 3, let modelText = try? String(contentsOfFile: args[3]) {
        let errors = LogicDsl.load(modelText)
        expect(errors.isEmpty, "logic-models.txt parses" + (errors.isEmpty ? "" : ": " + errors.prefix(5).joined(separator: "; ")))
        var dslProblems: [String] = [], dslCount = 0
        var seenDefs = Set<String>()
        for (_, d) in LogicDsl.defs.sorted(by: { $0.key < $1.key }) where seenDefs.insert(d.key).inserted {
            dslCount += 1
            guard let model = LogicModels.model(for: d.key, names: d.pins) else { dslProblems.append("\(d.key): no model"); continue }
            var groupsSeen = 0, checks = 0
            for g in allLogicGroups(xml) where g.names.contains(where: { d.names.contains($0) || d.names.contains(Pinouts.logicBase($0)) }) && g.pins == d.pins.count {
                groupsSeen += 1
                // minipro's vectors may depend on the order the pins are set in: the best of the plausible orders must agree
                var best = Int.max, bestChecks = 0
                for res in [LogicModels.simulate(model, names: d.pins, vectors: g.vectors),
                            simulateOrdered(LogicModels.model(for: d.key, names: d.pins)!, names: d.pins, vectors: g.vectors, ascending: true),
                            simulateGrouped(LogicModels.model(for: d.key, names: d.pins)!, names: d.pins, vectors: g.vectors)] {
                    var bad = 0, n = 0
                    for (vec, r) in zip(g.vectors, res) {
                        for (i, c) in vec.enumerated() where c == "L" || c == "H" || c == "Z" {
                            guard let m = r[i] else { continue }
                            n += 1
                            if m != (c != "L") { bad += 1 }
                        }
                    }
                    if bad < best { best = bad; bestChecks = n }
                }
                checks += bestChecks   // summed over every group: a related chip's group (74LS54 for 7454) may check none of this model's outputs
                if best > 0 { dslProblems.append("\(d.key): \(best) mismatches with \(g.names.joined(separator: ","))") }
            }
            if groupsSeen == 0 { dslProblems.append("\(d.key): not in the logic database"); continue }
            if checks == 0 { dslProblems.append("\(d.key): no outputs checked") }
            guard let e = LogicModels.extended(chip: d.key, names: d.pins, roles: d.roles) else { dslProblems.append("\(d.key): no extended test"); continue }
            let fp = LogicModels.fingerprint(e.vectors)
            if let x = expectedDsl[d.key] {
                if x.0 != e.vectors.count || x.1 != e.checks || x.2 != fp {
                    dslProblems.append("\(d.key): extended \(e.vectors.count)/\(e.checks)/\(String(fp, radix: 16)) vs reference \(x.0)/\(x.1)/\(String(x.2, radix: 16))")
                }
            } else { dslProblems.append("\(d.key): no reference") }
            if raceMismatches(d.key, names: d.pins, e) > 0 { dslProblems.append("\(d.key): pin-order race") }
            let t = LogicTest(name: d.key, pins: d.pins.count, voltage: "5V", vectors: e.vectors)
            if !t.problems().isEmpty { dslProblems.append("\(d.key): " + t.problems()[0]) }
            if e.phases.map({ $0.range.count }).reduce(0, +) != e.vectors.count { dslProblems.append("\(d.key): phases don't cover the vectors") }
        }
        expect(dslProblems.isEmpty && dslCount == expectedDsl.count, "logic-models.txt models agree with minipro's vectors (\(dslCount) models)" + (dslProblems.isEmpty ? "" : ": " + dslProblems.prefix(10).joined(separator: "; ")))
        var raced: [String] = []
        for (chip, entry) in Pinouts.logicNames.sorted(by: { $0.key < $1.key }) {
            let items = entry.pins.split(separator: " ")
            let names = items.map { String($0.split(separator: ":", maxSplits: 1).last ?? "") }
            let roles = items.map { $0.first ?? "i" }
            guard LogicModels.model(for: chip, names: names) != nil, let e = LogicModels.extended(chip: chip, names: names, roles: roles) else { continue }
            if raceMismatches(chip, names: names, e) > 0 { raced.append(chip) }
        }
        expect(raced.isEmpty, "built-in models' extended tests are free of pin-order races" + (raced.isEmpty ? "" : ": " + raced.joined(separator: ", ")))
    } else {
        expect(false, "logic-models.txt not given to the dbtest")
    }
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
