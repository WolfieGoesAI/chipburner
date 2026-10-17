import Foundation

// Compares Sources/Disassembler.swift with MAME's output (tests/disasm/vectors.txt).
guard CommandLine.arguments.count >= 2, let text = try? String(contentsOfFile: CommandLine.arguments[1]) else {
    print("usage: disasmtest vectors.txt"); exit(2)
}
let cpus: [String: DisasmCPU] = ["z80": .z80, "7810": .upd7810, "6502": .m6502, "6809": .m6809, "8051": .i8051]
var passed: [String: Int] = [:], failed: [String: Int] = [:]
var shown = 0

func check(_ cpu: String, _ base: Int, _ hex: String, _ expected: [String]) {
    guard let c = cpus[cpu] else { return }
    var bytes: [UInt8] = []
    var i = hex.startIndex
    while i < hex.endIndex {
        let j = hex.index(i, offsetBy: 2)
        bytes.append(UInt8(hex[i..<j], radix: 16)!)
        i = j
    }
    let got = Disassembler(c).run(bytes, base: base).map { String(format: "%X %d ", $0.address, $0.length) + $0.text + "|" }
    if got == expected {
        passed[cpu, default: 0] += 1
    } else {
        failed[cpu, default: 0] += 1
        if shown < 40 {
            shown += 1
            print("FAIL \(cpu) base \(String(base, radix: 16)) bytes \(hex)")
            for k in 0..<max(got.count, expected.count) {
                let g = k < got.count ? got[k] : "-", e = k < expected.count ? expected[k] : "-"
                if g != e { print("   MAME:  \(e)\n   ours:  \(g)") }
            }
        }
    }
}

var cur: (String, Int, String)?
var exp: [String] = []
for line in text.components(separatedBy: "\n") {
    if line.hasPrefix("@ ") {
        if let c = cur { check(c.0, c.1, c.2, exp) }
        let p = line.split(separator: " ")
        cur = (String(p[1]), Int(p[2], radix: 16)!, String(p[3]))
        exp = []
    } else if !line.isEmpty {
        exp.append(line)
    }
}
if let c = cur { check(c.0, c.1, c.2, exp) }
for k in cpus.keys.sorted() {
    print("disasm \(k): \(passed[k] ?? 0) passed, \(failed[k] ?? 0) failed")
}
let ok = failed.values.reduce(0, +) == 0 && passed.values.reduce(0, +) > 5000
print(ok ? "DISASMTEST OK" : "DISASMTEST FAILED")
exit(ok ? 0 : 1)
