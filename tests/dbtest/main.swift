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

print(failed ? "DBTEST FAILED" : "DBTEST OK")
exit(failed ? 1 : 0)
