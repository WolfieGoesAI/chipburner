import Foundation

/// Disassemblers for the CPUs found in vintage gear: Z80, NEC µPD7810/7811, 6502, 6809 and 8051.
/// Ported line by line from MAME's disassemblers (BSD-3-Clause; see DisasmTables.swift for the
/// copyright holders). The build compares the output with MAME's own for thousands of test cases
/// (tests/disasm), so the text matches MAME exactly.
enum DisasmCPU: String, CaseIterable {
    case z80 = "Z80"
    case upd7810 = "µPD7810 / 7811"
    case m6502 = "6502"
    case m6809 = "6809"
    case i8051 = "8051"

    var testName: String {
        switch self {
        case .z80: return "z80"
        case .upd7810: return "7810"
        case .m6502: return "6502"
        case .m6809: return "6809"
        case .i8051: return "8051"
        }
    }

    var examples: String {
        switch self {
        case .z80: return "Z80 – e.g. Roland Jupiter-8, Sequential Prophet-5 rev 3, Oberheim OB-8"
        case .upd7810: return "µPD7810/7811 – e.g. Roland Juno-106, Alpha Juno, MKS-7"
        case .m6502: return "6502 – e.g. Commodore, Apple II, Atari, many drum machines"
        case .m6809: return "6809 – e.g. Ensoniq Mirage, Fairlight, Oberheim Matrix-12"
        case .i8051: return "8051 / 8031 – e.g. Roland and Korg controller boards"
        }
    }
}

struct DisasmLine: Equatable {
    let address: Int
    let length: Int
    let text: String
}

/// Reads bytes at CPU addresses; anything outside the data reads as 0 (like MAME's harness).
struct DisasmMemory {
    let bytes: [UInt8]
    let base: Int
    func r8(_ a: Int) -> Int {
        let i = a - base
        return i >= 0 && i < bytes.count ? Int(bytes[i]) : 0
    }
    func r16le(_ a: Int) -> Int { r8(a) | (r8(a + 1) << 8) }
    func r16be(_ a: Int) -> Int { (r8(a) << 8) | r8(a + 1) }
    func r32be(_ a: Int) -> Int { (r16be(a) << 16) | r16be(a + 2) }
}

// MARK: - Small printf helpers (only what the MAME formats need)

private func hex(_ v: Int, _ digits: Int, upper: Bool = true) -> String {
    // Negative values print as 32-bit unsigned, like C's %X of an unsigned int.
    let u = v < 0 ? UInt64(UInt32(truncatingIfNeeded: v)) : UInt64(v)
    var s = String(u, radix: 16, uppercase: upper)
    if s.count < digits { s = String(repeating: "0", count: digits - s.count) + s }
    return s
}
private func padRight(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

final class Disassembler {
    let cpu: DisasmCPU
    private var page6809 = 0          // MAME's 6809 disassembler keeps the page between calls
    private lazy var table6809: [UInt16: DisasmTables.Op6809] = {
        var d: [UInt16: DisasmTables.Op6809] = [:]
        for o in DisasmTables.m6809 where d[o.op] == nil { d[o.op] = o }
        return d
    }()

    init(_ cpu: DisasmCPU) { self.cpu = cpu }

    /// Disassembles `bytes` (loaded at `base`) from `start` until `end` or `maxLines`.
    func run(_ bytes: [UInt8], base: Int, start: Int? = nil, end: Int? = nil, maxLines: Int = .max) -> [DisasmLine] {
        let m = DisasmMemory(bytes: bytes, base: base)
        var pc = start ?? base
        let stop = end ?? (base + bytes.count)
        var out: [DisasmLine] = []
        page6809 = 0
        while pc < stop && out.count < maxLines {
            let (len, text) = one(m, pc)
            out.append(DisasmLine(address: pc, length: len, text: text))
            pc += max(1, len)
        }
        return out
    }

    func one(_ m: DisasmMemory, _ pc: Int) -> (Int, String) {
        switch cpu {
        case .z80: return z80(m, pc)
        case .upd7810: return upd7810(m, pc)
        case .m6502: return m6502(m, pc)
        case .m6809: return m6809(m, pc)
        case .i8051: return i8051(m, pc)
        }
    }

    // MARK: Z80

    private func z80(_ m: DisasmMemory, _ pc: Int) -> (Int, String) {
        typealias T = DisasmTables
        let zDB = 13
        var offset = 0
        var pos = pc
        var ixy = "oops!!"
        var op = m.r8(pos); pos += 1
        var mn: Int
        var args: String?
        switch op {
        case 0xCB:
            op = m.r8(pos); pos += 1
            mn = Int(T.z80CbM[op]); args = T.z80CbA[op]
        case 0xED:
            let o = m.r8(pos); pos += 1
            mn = Int(T.z80EdM[o]); args = T.z80EdA[o]
            if mn == zDB { pos -= 1 }
        case 0xDD, 0xFD:
            ixy = op == 0xDD ? "ix" : "iy"
            var op1 = m.r8(pos); pos += 1
            if op1 == 0xCB {
                offset = Int(Int8(bitPattern: UInt8(m.r8(pos)))); pos += 1
                op1 = m.r8(pos); pos += 1
                mn = Int(T.z80XxCbM[op1]); args = T.z80XxCbA[op1]
            } else {
                mn = Int(T.z80XxM[op1]); args = T.z80XxA[op1]
                if mn == zDB { pos -= 1 }
            }
        default:
            mn = Int(T.z80MainM[op]); args = T.z80MainA[op]
        }
        let name = T.z80Mnemonics[mn]
        guard let a = args else { return (pos - pc, name) }
        var s = padRight(name, 4) + " "
        var i = a.startIndex
        while i < a.endIndex {
            let c = a[i]
            switch c {
            case "?": s += "$" + hex(op, 2, upper: false)
            case "A", "N", "W": s += "$" + hex(m.r16le(pos), 4); pos += 2
            case "B", "P": s += "$" + hex(m.r8(pos), 2); pos += 1
            case "O": s += "$" + hex((pc + Int(Int8(bitPattern: UInt8(m.r8(pos)))) + 2) & 0xFFFF, 4); pos += 1
            case "V": s += "$" + hex(op & 0x38, 2)
            case "X", "Y":
                if c == "X" { offset = Int(Int8(bitPattern: UInt8(m.r8(pos)))); pos += 1 }
                s += "(\(ixy)\(offset < 0 ? "-" : "+")$\(hex(abs(offset), 2, upper: false)))"
            case "I": s += ixy
            default: s.append(c)
            }
            i = a.index(after: i)
        }
        return (pos - pc, s)
    }

    // MARK: µPD7810

    private static let upd7810Regname = [
        "illegal", "illegal", "illegal", "illegal", "illegal", "illegal", "illegal", "illegal",
        "illegal", "illegal", "illegal", "illegal", "illegal", "illegal", "illegal", "illegal",
        "PA", "PB", "PC", "PD", "illegal", "PF", "MKH", "MKL",
        "illegal", "SMH", "illegal", "EOM", "illegal", "TMM", "PT", "illegal",
    ]

    private static let upd7810Prefix: [String: [String]] = [
        "d60": DisasmTables.upd7810_d60, "d70": DisasmTables.upd7810_d70, "d74": DisasmTables.upd7810_d74,
        "d48_7810": DisasmTables.upd7810_d48_7810, "d4C_7810": DisasmTables.upd7810_d4C_7810,
        "d4D_7810": DisasmTables.upd7810_d4D_7810, "d64_7810": DisasmTables.upd7810_d64_7810,
    ]

    private func upd7810(_ m: DisasmMemory, _ pc: Int) -> (Int, String) {
        var idx = pc
        var op = m.r8(idx); idx += 1
        var entry = DisasmTables.upd7810_XX_7810[op]
        if entry.hasPrefix("@"), let t = Disassembler.upd7810Prefix[String(entry.dropFirst())] {
            op = m.r8(idx); idx += 1
            entry = t[op]
        }
        let parts = entry.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let name = DisasmTables.upd7810Tokens[Int(parts[0]) ?? 1]
        var s = padRight(String(name.prefix(8)), 8)
        guard parts.count > 1 else { return (idx - pc, s) }
        let a = Array(parts[1])
        var k = 0
        while k < a.count {
            if a[k] == "%" {
                k += 1
                guard k < a.count else { break }
                switch a[k] {
                case "a": s += "VV:" + hex(m.r8(idx), 2); idx += 1
                case "A": s += "$" + hex(op, 2)
                case "b": s += "$" + hex(m.r8(idx), 2); idx += 1
                case "w":
                    let ea = m.r8(idx) + (m.r8(idx + 1) << 8); idx += 2
                    s += "$" + hex(ea & 0xFFFF, 4)
                case "d":
                    let op2 = m.r8(idx); idx += 1
                    let off = (op & 1) != 0 ? -(256 - op2) : op2
                    s += "$" + hex((idx + off) & 0xFFFF, 4)
                case "t": s += "($" + hex(0x80 + 2 * (op & 0x1F), 4) + ")"
                case "f":
                    let op2 = m.r8(idx); idx += 1
                    s += "$" + hex(0x800 + 0x100 * (op & 0x07) + op2, 4)
                case "o":
                    let off = ((op & 0x20) != 0 ? -0x20 : 0) + (op & 0x1F)
                    s += "$" + hex((idx + off) & 0xFFFF, 4)
                case "i":
                    let op2 = m.r8(idx); idx += 1
                    s += "\(Disassembler.upd7810Regname[op2 & 0x1F]),\(op2 >> 5)"
                default: s.append(a[k])
                }
            } else {
                s.append(a[k])
            }
            k += 1
        }
        return (idx - pc, s)
    }

    // MARK: 6502

    private func m6502(_ m: DisasmMemory, _ pc: Int) -> (Int, String) {
        let e = DisasmTables.m6502[m.r8(pc)]
        let name = String(e.prefix(3)), mode = String(e.dropFirst(4))
        let b1 = m.r8(pc + 1), b2 = m.r8(pc + 2)
        let abs = "$" + hex(b2, 2, upper: false) + hex(b1, 2, upper: false)
        let zp = "$" + hex(b1, 2, upper: false)
        switch mode {
        case "non", "imp": return (1, name)
        case "acc": return (1, name + " a")
        case "aba", "adr": return (3, name + " " + abs)
        case "abx": return (3, name + " " + abs + ", x")
        case "aby": return (3, name + " " + abs + ", y")
        case "ind": return (3, name + " (" + abs + ")")
        case "idx": return (2, name + " (" + zp + ", x)")
        case "idy": return (2, name + " (" + zp + "), y")
        case "imm": return (2, name + " #" + zp)
        case "zpg": return (2, name + " " + zp)
        case "zpx": return (2, name + " " + zp + ", x")
        case "zpy": return (2, name + " " + zp + ", y")
        case "rel":
            let t = (pc & 0xFF0000) | ((pc + 2 + Int(Int8(bitPattern: UInt8(b1)))) & 0xFFFF)
            return (2, name + " $" + hex(t, 4, upper: false))
        default: return (1, name)
        }
    }

    // MARK: 6809

    private static let regs6809 = ["X", "Y", "U", "S", "PC"]
    private static let teregs6809 = ["D", "X", "Y", "U", "S", "PC", "inv", "inv", "A", "B", "CC", "DP", "inv", "inv", "inv", "inv"]
    private static let btwregs = ["CC", "A", "B", "inv"]
    private static let tfmregs = ["D", "X", "Y", "U", "S", "inv", "inv", "inv", "inv", "inv", "inv", "inv", "inv", "inv", "inv", "inv"]

    private func fetch6809(_ m: DisasmMemory, _ p: inout Int) -> DisasmTables.Op6809? {
        var pageCount = 0
        while true {
            let opcode = UInt16(page6809 | m.r8(p)); p += 1
            if let e = table6809[opcode] {
                switch e.mode {
                case .PG2, .PG3:
                    if page6809 == 0 {
                        pageCount += 1
                        page6809 = Int(e.op) << 8
                    } else {
                        let old = pageCount
                        pageCount += 1
                        if old != 0 { p -= 1; return nil }
                    }
                default:
                    page6809 = 0
                    return e
                }
            } else if page6809 != 0 {
                // An unimplemented page 2/3 opcode falls through to page 1 on the 6809.
                p -= 1
                page6809 = 0
            } else {
                return nil
            }
        }
    }

    private func m6809(_ m: DisasmMemory, _ pc: Int) -> (Int, String) {
        var p = pc
        guard let op = fetch6809(m, &p) else {
            var s = padRight("FCB", 7) + "$" + hex(m.r8(pc), 2)
            var q = pc + 1
            while q < p { s += ",$" + hex(m.r8(q), 2); q += 1 }
            return (p - pc, s)
        }
        let ppc = p
        p += op.len
        var s = op.mode == .INH ? op.name : padRight(op.name, 7)
        switch op.mode {
        case .PG2, .PG3, .INH: break
        case .PSHS, .PSHU:
            let pb = m.r8(ppc)
            if pb & 0x80 != 0 { s += "PC" }
            if pb & 0x40 != 0 { s += ((pb & 0x80) != 0 ? "," : "") + (op.mode == .PSHS ? "U" : "S") }
            if pb & 0x20 != 0 { s += ((pb & 0xC0) != 0 ? "," : "") + "Y" }
            if pb & 0x10 != 0 { s += ((pb & 0xE0) != 0 ? "," : "") + "X" }
            if pb & 0x08 != 0 { s += ((pb & 0xF0) != 0 ? "," : "") + "DP" }
            if pb & 0x04 != 0 { s += ((pb & 0xF8) != 0 ? "," : "") + ((pb & 0x02) != 0 ? "D" : "B") }
            else if pb & 0x02 != 0 { s += ((pb & 0xFC) != 0 ? "," : "") + "A" }
            if pb & 0x01 != 0 { s += ((pb & 0xFE) != 0 ? "," : "") + "CC" }
        case .PULS, .PULU:
            let pb = m.r8(ppc)
            if pb & 0x01 != 0 { s += "CC" }
            if pb & 0x02 != 0 { s += ((pb & 0x01) != 0 ? "," : "") + ((pb & 0x04) != 0 ? "D" : "A") }
            else if pb & 0x04 != 0 { s += ((pb & 0x03) != 0 ? "," : "") + "B" }
            if pb & 0x08 != 0 { s += ((pb & 0x07) != 0 ? "," : "") + "DP" }
            if pb & 0x10 != 0 { s += ((pb & 0x0F) != 0 ? "," : "") + "X" }
            if pb & 0x20 != 0 { s += ((pb & 0x1F) != 0 ? "," : "") + "Y" }
            if pb & 0x40 != 0 { s += ((pb & 0x3F) != 0 ? "," : "") + (op.mode == .PULS ? "U" : "S") }
            if pb & 0x80 != 0 { s += ((pb & 0x7F) != 0 ? "," : "") + "PC" }
        case .DIR: s += "<$" + hex(m.r8(ppc), 2)
        case .DIR_IM: s += "#$" + hex(m.r8(ppc), 2) + ";<$" + hex(m.r8(ppc + 1), 2)
        case .REL: s += "$" + hex((p + Int(Int8(bitPattern: UInt8(m.r8(ppc))))) & 0xFFFF, 4)
        case .LREL: s += "$" + hex((p + Int(Int16(bitPattern: UInt16(m.r16be(ppc))))) & 0xFFFF, 4)
        case .EXT:
            if op.len == 3 {
                s += "#$" + hex(m.r8(ppc), 2) + ",$" + hex(m.r16be(ppc + 1), 4)
            } else if op.len == 2 {
                let ea = m.r16be(ppc)
                if ea & 0xFF00 == 0 { s += ">" }
                s += "$" + hex(ea, 4)
            }
        case .IND:
            let pb: Int
            if op.len == 2 { s += "#$" + hex(m.r8(ppc), 2) + ";"; pb = m.r8(ppc + 1) } else { pb = m.r8(ppc) }
            s += indexed6809(m, pb, &p)
        case .IMM:
            if op.len == 4 { s += "#$" + hex(m.r32be(ppc), 8) }
            else if op.len == 2 { s += "#$" + hex(m.r16be(ppc), 4) }
            else if op.len == 1 { s += "#$" + hex(m.r8(ppc), 2) }
        case .IMM_RR:
            let pb = m.r8(ppc)
            s += Disassembler.teregs6809[(pb >> 4) & 0xF] + "," + Disassembler.teregs6809[pb & 0xF]
        case .IMM_BW:
            let pb = m.r8(ppc)
            s += "\(Disassembler.btwregs[(pb & 0xC0) >> 6]),\((pb & 0x38) >> 3),\(pb & 0x07),$" + hex(m.r8(ppc + 1), 2)
        case .IMM_TFM:
            let pb = m.r8(ppc)
            let a = Disassembler.tfmregs[(pb >> 4) & 0xF], b = Disassembler.tfmregs[pb & 0xF]
            switch op.op & 0x07 {
            case 0: s += "\(a)+,\(b)+"
            case 1: s += "\(a)-,\(b)-"
            case 2: s += "\(a)+,\(b)"
            default: s += "\(a),\(b)+"
            }
        }
        return (p - pc, s)
    }

    private func indexed6809(_ m: DisasmMemory, _ pb: Int, _ p: inout Int) -> String {
        let reg = (pb >> 5) & 3
        let pbm = pb & 0x8F
        let indirect = (pb & 0x90) == 0x90
        let r = Disassembler.regs6809[reg]
        var s = indirect && pbm != 0x82 ? "[" : ""
        func signed(_ o: Int, _ digits: Int) -> String { (o < 0 ? "-" : "") + "$" + hex(abs(o), digits) }
        func wRelative() {
            switch reg {
            case 0: s += ",W"
            case 1:
                let o = Int(Int16(bitPattern: UInt16(m.r16be(p)))); p += 2
                s += signed(o, 4) + ",W"
            case 2: s += ",W++"
            default: s += ",--W"
            }
        }
        switch pbm {
        case 0x80: if indirect { wRelative() } else { s += ",\(r)+" }
        case 0x81: s += ",\(r)++"
        case 0x82: s += indirect ? "Illegal Postbyte" : ",-\(r)"
        case 0x83: s += ",--\(r)"
        case 0x84: s += ",\(r)"
        case 0x85: s += "B,\(r)"
        case 0x86: s += "A,\(r)"
        case 0x87: s += "E,\(r)"
        case 0x88:
            let o = Int(Int8(bitPattern: UInt8(m.r8(p)))); p += 1
            s += signed(o, 2) + "," + r
        case 0x89:
            let o = Int(Int16(bitPattern: UInt16(m.r16be(p)))); p += 2
            s += signed(o, 4) + "," + r
        case 0x8A: s += "F,\(r)"
        case 0x8B: s += "D,\(r)"
        case 0x8C:
            let o = Int(Int8(bitPattern: UInt8(m.r8(p)))); p += 1
            s += "$" + hex((p + o) & 0xFFFF, 4) + ",PCR"
        case 0x8D:
            let o = Int(Int16(bitPattern: UInt16(m.r16be(p)))); p += 2
            s += "$" + hex((p + o) & 0xFFFF, 4) + ",PCR"
        case 0x8E: s += "W,\(r)"
        case 0x8F:
            if indirect {
                s += "$" + hex(m.r16be(p), 4); p += 2
            } else {
                wRelative()
            }
        default:
            var o = pb & 0x1F
            if o > 15 { o -= 32 }
            s += (o < 0 ? "-" : "") + "$" + hex(abs(o), 1) + "," + r
        }
        if indirect && pbm != 0x82 { s += "]" }
        return s
    }

    // MARK: 8051

    private func data8051(_ a: Int) -> String { DisasmTables.mcs51Names[a] ?? "$" + hex(a, 2) }

    private func bit8051(_ a: Int) -> String {
        if a < 0x80 { return "$" + hex((a >> 3) | 0x20, 2) + ".\(a & 7)" }
        if let n = DisasmTables.mcs51Names[a | 0x100] { return n }
        if let n = DisasmTables.mcs51Names[a & 0xF8] { return "\(n).\(a & 7)" }
        return "$" + hex(a & 0xF8, 2) + ".\(a & 7)"
    }

    private func i8051(_ m: DisasmMemory, _ pc: Int) -> (Int, String) {
        var PC = pc
        let op = m.r8(PC); PC += 1
        func next() -> Int { let v = m.r8(PC); PC += 1; return v }
        func rel() -> Int { Int(Int8(bitPattern: UInt8(next()))) }
        func target(_ r: Int) -> String { "$" + hex(PC + r, 4) }   // PC is unsigned in MAME: wraps to 32 bits
        func ins(_ mnem: String, _ args: String) -> String { padRight(mnem, 6) + args }
        let r1 = op & 1, r7 = op & 7
        let s: String
        switch op {
        case 0x00: s = "nop"
        case 0x01, 0x21, 0x41, 0x61, 0x81, 0xA1, 0xC1, 0xE1:
            var addr = next()
            addr |= (PC & 0xF800) | ((op & 0xE0) << 3)
            s = ins("ajmp", "$" + hex(addr & 0xFFFF, 4))
        case 0x02:
            let hi = next(), lo = next()
            s = ins("ljmp", "$" + hex(((hi << 8) & 0xFF00) | lo, 4))
        case 0x03: s = ins("rr", "a")
        case 0x04: s = ins("inc", "a")
        case 0x05: s = ins("inc", data8051(next()))
        case 0x06, 0x07: s = ins("inc", "@r\(r1)")
        case 0x08...0x0F: s = ins("inc", "r\(r7)")
        case 0x10: let b = bit8051(next()); let r = rel(); s = ins("jbc", "\(b),\(target(r))")
        case 0x11, 0x31, 0x51, 0x71, 0x91, 0xB1, 0xD1, 0xF1:
            s = ins("acall", "$" + hex((PC & 0xF800) | ((op & 0xE0) << 3) | m.r8(PC), 4)); PC += 1
        case 0x12:
            let hi = next(), lo = next()
            s = ins("lcall", "$" + hex(((hi << 8) & 0xFF00) | lo, 4))
        case 0x13: s = ins("rrc", "a")
        case 0x14: s = ins("dec", "a")
        case 0x15: s = ins("dec", data8051(next()))
        case 0x16, 0x17: s = ins("dec", "@r\(r1)")
        case 0x18...0x1F: s = ins("dec", "r\(r7)")
        case 0x20: let b = bit8051(next()); let r = rel(); s = ins("jb", "\(b),\(target(r))")
        case 0x22: s = "ret"
        case 0x23: s = ins("rl", "a")
        case 0x24: s = ins("add", "a,#$" + hex(next(), 2))
        case 0x25: s = ins("add", "a," + data8051(next()))
        case 0x26, 0x27: s = ins("add", "a,@r\(r1)")
        case 0x28...0x2F: s = ins("add", "a,r\(r7)")
        case 0x30: let b = bit8051(next()); let r = rel(); s = ins("jnb", "\(b),\(target(r))")
        case 0x32: s = "reti"
        case 0x33: s = ins("rlc", "a")
        case 0x34: s = ins("addc", "a,#$" + hex(next(), 2))
        case 0x35: s = ins("addc", "a," + data8051(next()))
        case 0x36, 0x37: s = ins("addc", "a,@r\(r1)")
        case 0x38...0x3F: s = ins("addc", "a,r\(r7)")
        case 0x40: let r = rel(); s = ins("jc", target(r))
        case 0x42: s = ins("orl", data8051(next()) + ",a")
        case 0x43: let d = data8051(next()); s = ins("orl", d + ",#$" + hex(next(), 2))
        case 0x44: s = ins("orl", "a,#$" + hex(next(), 2))
        case 0x45: s = ins("orl", "a," + data8051(next()))
        case 0x46, 0x47: s = ins("orl", "a,@r\(r1)")
        case 0x48...0x4F: s = ins("orl", "a,r\(r7)")
        case 0x50: let r = rel(); s = ins("jnc", target(r))
        case 0x52: s = ins("anl", data8051(next()) + ",a")
        case 0x53: let d = data8051(next()); s = ins("anl", d + ",#$" + hex(next(), 2))
        case 0x54: s = ins("anl", "a,#$" + hex(next(), 2))
        case 0x55: s = ins("anl", "a," + data8051(next()))
        case 0x56, 0x57: s = ins("anl", "a,@r\(r1)")
        case 0x58...0x5F: s = ins("anl", "a,r\(r7)")
        case 0x60: let r = rel(); s = ins("jz", target(r))
        case 0x62: s = ins("xrl", data8051(next()) + ",a")
        case 0x63: let d = data8051(next()); s = ins("xrl", d + ",#$" + hex(next(), 2))
        case 0x64: s = ins("xrl", "a,#$" + hex(next(), 2))
        case 0x65: s = ins("xrl", "a," + data8051(next()))
        case 0x66, 0x67: s = ins("xrl", "a,@r\(r1)")
        case 0x68...0x6F: s = ins("xrl", "a,r\(r7)")
        case 0x70: let r = rel(); s = ins("jnz", target(r))
        case 0x72: s = ins("orl", "c," + bit8051(next()))
        case 0x73: s = ins("jmp", "@a+dptr")
        case 0x74: s = ins("mov", "a,#$" + hex(next(), 2))
        case 0x75: let d = data8051(next()); s = ins("mov", d + ",#$" + hex(next(), 2))
        case 0x76, 0x77: s = ins("mov", "@r\(r1),#$" + hex(next(), 2))
        case 0x78...0x7F: s = ins("mov", "r\(r7),#$" + hex(next(), 2))
        case 0x80: let r = rel(); s = ins("sjmp", target(r))
        case 0x82: s = ins("anl", "c," + bit8051(next()))
        case 0x83: s = ins("movc", "a,@a+pc")
        case 0x84: s = ins("div", "ab")
        case 0x85: let src = data8051(next()); let dst = data8051(next()); s = ins("mov", "\(dst),\(src)")
        case 0x86, 0x87: s = ins("mov", data8051(next()) + ",@r\(r1)")
        case 0x88...0x8F: s = ins("mov", data8051(next()) + ",r\(r7)")
        case 0x90:
            let hi = next(), lo = next()
            s = ins("mov", "dptr,#$" + hex(((hi << 8) & 0xFF00) | lo, 4))
        case 0x92: s = ins("mov", bit8051(next()) + ",c")
        case 0x93: s = ins("movc", "a,@a+dptr")
        case 0x94: s = ins("subb", "a,#$" + hex(next(), 2))
        case 0x95: s = ins("subb", "a," + data8051(next()))
        case 0x96, 0x97: s = ins("subb", "a,@r\(r1)")
        case 0x98...0x9F: s = ins("subb", "a,r\(r7)")
        case 0xA0: s = ins("orl", "c,/" + bit8051(next()))
        case 0xA2: s = ins("mov", "c," + bit8051(next()))
        case 0xA3: s = ins("inc", "dptr")
        case 0xA4: s = ins("mul", "ab")
        case 0xA5: s = "ill/rsv"
        case 0xA6, 0xA7: s = ins("mov", "@r\(r1)," + data8051(next()))
        case 0xA8...0xAF: s = ins("mov", "r\(r7)," + data8051(next()))
        case 0xB0: s = ins("anl", "c,/" + bit8051(next()))
        case 0xB2: s = ins("cpl", bit8051(next()))
        case 0xB3: s = ins("cpl", "c")
        case 0xB4: let d = next(); let r = rel(); s = ins("cjne", "a,#$" + hex(d, 2) + "," + target(r))
        case 0xB5: let d = data8051(next()); let r = rel(); s = ins("cjne", "a,\(d),\(target(r))")
        case 0xB6, 0xB7: let d = next(); let r = rel(); s = ins("cjne", "@r\(r1),#$" + hex(d, 2) + "," + target(r))
        case 0xB8...0xBF: let d = next(); let r = rel(); s = ins("cjne", "r\(r7),#$" + hex(d, 2) + "," + target(r))
        case 0xC0: s = ins("push", data8051(next()))
        case 0xC2: s = ins("clr", bit8051(next()))
        case 0xC3: s = ins("clr", "c")
        case 0xC4: s = ins("swap", "a")
        case 0xC5: s = ins("xch", "a," + data8051(next()))
        case 0xC6, 0xC7: s = ins("xch", "a,@r\(r1)")
        case 0xC8...0xCF: s = ins("xch", "a,r\(r7)")
        case 0xD0: s = ins("pop", data8051(next()))
        case 0xD2: s = ins("setb", bit8051(next()))
        case 0xD3: s = ins("setb", "c")
        case 0xD4: s = ins("da", "a")
        case 0xD5: let d = data8051(next()); let r = rel(); s = ins("djnz", "\(d),\(target(r))")
        case 0xD6, 0xD7: s = ins("xchd", "a,@r\(r1)")
        case 0xD8...0xDF: let r = rel(); s = ins("djnz", "r\(r7),\(target(r))")
        case 0xE0: s = ins("movx", "a,@dptr")
        case 0xE2, 0xE3: s = ins("movx", "a,@r\(r1)")
        case 0xE4: s = ins("clr", "a")
        case 0xE5: s = ins("mov", "a," + data8051(next()))
        case 0xE6, 0xE7: s = ins("mov", "a,@r\(r1)")
        case 0xE8...0xEF: s = ins("mov", "a,r\(r7)")
        case 0xF0: s = ins("movx", "@dptr,a")
        case 0xF2, 0xF3: s = ins("movx", "@r\(r1),a")
        case 0xF4: s = ins("cpl", "a")
        case 0xF5: s = ins("mov", data8051(next()) + ",a")
        case 0xF6, 0xF7: s = ins("mov", "@r\(r1),a")
        case 0xF8...0xFF: s = ins("mov", "r\(r7),a")
        default: s = "illegal"
        }
        return (PC - pc, s)
    }
}
