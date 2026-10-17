import Foundation

enum DataFormatError: LocalizedError {
    case badRecord(line: Int, reason: String)
    case empty

    var errorDescription: String? {
        switch self {
        case .badRecord(let line, let reason): return "Intel hex error on line \(line): \(reason)"
        case .empty: return "The file contains no data."
        }
    }
}

enum IntelHex {
    /// Parses Intel hex (record types 00, 01, 02, 04; 03/05 ignored).
    /// Gaps are filled with 0xFF; the result starts at address 0.
    static func parse(_ text: String) throws -> Data {
        var chunks: [(addr: Int, bytes: [UInt8])] = []
        var base = 0
        var lineNo = 0
        for raw in text.components(separatedBy: .newlines) {
            lineNo += 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard line.hasPrefix(":") else { throw DataFormatError.badRecord(line: lineNo, reason: "missing ':'") }
            let hex = Array(line.dropFirst())
            guard hex.count >= 10, hex.count % 2 == 0 else {
                throw DataFormatError.badRecord(line: lineNo, reason: "bad length")
            }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(hex.count / 2)
            var i = 0
            while i < hex.count {
                guard let b = UInt8(String(hex[i...i + 1]), radix: 16) else {
                    throw DataFormatError.badRecord(line: lineNo, reason: "not hex")
                }
                bytes.append(b); i += 2
            }
            let count = Int(bytes[0])
            guard bytes.count == count + 5 else { throw DataFormatError.badRecord(line: lineNo, reason: "byte count mismatch") }
            let sum = bytes.reduce(0) { ($0 + Int($1)) & 0xFF }
            guard sum == 0 else { throw DataFormatError.badRecord(line: lineNo, reason: "checksum") }
            let offset = Int(bytes[1]) << 8 | Int(bytes[2])
            let type = bytes[3]
            let payload = Array(bytes[4..<(4 + count)])
            switch type {
            case 0x00: chunks.append((base + offset, payload))
            case 0x01: break
            case 0x02:
                guard count == 2 else { throw DataFormatError.badRecord(line: lineNo, reason: "bad segment record") }
                base = (Int(payload[0]) << 8 | Int(payload[1])) << 4
            case 0x04:
                guard count == 2 else { throw DataFormatError.badRecord(line: lineNo, reason: "bad linear record") }
                base = (Int(payload[0]) << 8 | Int(payload[1])) << 16
            case 0x03, 0x05: break
            default: throw DataFormatError.badRecord(line: lineNo, reason: "unknown record type \(type)")
            }
            if type == 0x01 { break }
        }
        guard let end = chunks.map({ $0.addr + $0.bytes.count }).max(), end > 0 else { throw DataFormatError.empty }
        var out = [UInt8](repeating: 0xFF, count: end)
        for c in chunks { out.replaceSubrange(c.addr..<(c.addr + c.bytes.count), with: c.bytes) }
        return Data(out)
    }

    /// Writes 16 data bytes per record, with type 04 records above 64 KB.
    static func write(_ data: Data, startAddress: Int = 0) -> String {
        var lines: [String] = []
        let bytes = [UInt8](data)
        var upper = -1
        var addr = 0
        func record(_ type: UInt8, _ offset: Int, _ payload: [UInt8]) -> String {
            var rec: [UInt8] = [UInt8(payload.count), UInt8((offset >> 8) & 0xFF), UInt8(offset & 0xFF), type] + payload
            let sum = rec.reduce(0) { ($0 + Int($1)) & 0xFF }
            rec.append(UInt8((0x100 - sum) & 0xFF))
            return ":" + rec.map { String(format: "%02X", $0) }.joined()
        }
        while addr < bytes.count {
            let abs = startAddress + addr
            let hi = abs >> 16
            if hi != upper {
                lines.append(record(0x04, 0, [UInt8((hi >> 8) & 0xFF), UInt8(hi & 0xFF)]))
                upper = hi
            }
            let n = min(16, bytes.count - addr, 0x10000 - (abs & 0xFFFF))
            lines.append(record(0x00, abs & 0xFFFF, Array(bytes[addr..<(addr + n)])))
            addr += n
        }
        lines.append(":00000001FF")
        return lines.joined(separator: "\n") + "\n"
    }
}

enum Checksums {
    /// Byte sum truncated to 16 bits (the checksum most programmer tools show).
    static func sum16(_ data: Data) -> UInt16 {
        var s: UInt32 = 0
        for b in data { s = s &+ UInt32(b) }
        return UInt16(truncatingIfNeeded: s)
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }
}

enum HexDump {
    /// Classic 16-bytes-per-row dump: offset, hex, ASCII.
    static func render(_ data: Data, limit: Int = 1 << 20) -> String {
        let bytes = [UInt8](data.prefix(limit))
        var out = ""
        out.reserveCapacity(bytes.count / 16 * 78 + 64)
        let digits = Array("0123456789ABCDEF")
        var row = 0
        while row < bytes.count {
            let end = min(row + 16, bytes.count)
            out += String(format: "%06X  ", row)
            for i in row..<(row + 16) {
                if i < end {
                    let b = bytes[i]
                    out.append(digits[Int(b >> 4)]); out.append(digits[Int(b & 0xF)]); out.append(" ")
                } else {
                    out += "   "
                }
                if i == row + 7 { out += " " }
            }
            out += " "
            for i in row..<end {
                let b = bytes[i]
                out.append((b >= 0x20 && b < 0x7F) ? Character(UnicodeScalar(b)) : ".")
            }
            out += "\n"
            row += 16
        }
        if data.count > limit { out += "… (\(data.count - limit) more bytes not shown)\n" }
        return out
    }
}

enum SRecordError: LocalizedError {
    case bad(line: Int, reason: String)
    var errorDescription: String? {
        if case .bad(let l, let r) = self { return "S-record error on line \(l): \(r)" }
        return nil
    }
}

/// Motorola S-record (.s19 / .s28 / .s37 / .srec).
enum SRecord {
    /// Reads S1/S2/S3 data records (S0 header, S5/S6 counts and S7/S8/S9 ends are skipped).
    /// Gaps are filled with 0xFF; the result starts at address 0, like Intel hex.
    static func parse(_ text: String) throws -> Data {
        var chunks: [(addr: Int, bytes: [UInt8])] = []
        var lineNo = 0
        for raw in text.components(separatedBy: .newlines) {
            lineNo += 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard line.count >= 4, line.first == "S" || line.first == "s" else { throw SRecordError.bad(line: lineNo, reason: "missing 'S'") }
            let type = line[line.index(after: line.startIndex)]
            let hex = Array(line.dropFirst(2))
            guard hex.count % 2 == 0 else { throw SRecordError.bad(line: lineNo, reason: "odd number of hex digits") }
            var bytes: [UInt8] = []
            var i = 0
            while i < hex.count {
                guard let b = UInt8(String(hex[i...i + 1]), radix: 16) else { throw SRecordError.bad(line: lineNo, reason: "not hex") }
                bytes.append(b); i += 2
            }
            guard let count = bytes.first, bytes.count == Int(count) + 1 else { throw SRecordError.bad(line: lineNo, reason: "byte count mismatch") }
            let sum = bytes.dropLast().reduce(0) { ($0 + Int($1)) & 0xFF }
            guard UInt8(0xFF - sum) == bytes.last else { throw SRecordError.bad(line: lineNo, reason: "checksum") }
            let addrLen: Int
            switch type {
            case "1": addrLen = 2
            case "2": addrLen = 3
            case "3": addrLen = 4
            case "0", "5", "6", "7", "8", "9": continue
            default: throw SRecordError.bad(line: lineNo, reason: "unknown record type S\(type)")
            }
            guard bytes.count >= 1 + addrLen + 1 else { throw SRecordError.bad(line: lineNo, reason: "record too short") }
            var addr = 0
            for k in 0..<addrLen { addr = addr << 8 | Int(bytes[1 + k]) }
            chunks.append((addr, Array(bytes[(1 + addrLen)..<(bytes.count - 1)])))
        }
        guard let end = chunks.map({ $0.addr + $0.bytes.count }).max(), end > 0 else { throw DataFormatError.empty }
        guard end <= 256 << 20 else { throw SRecordError.bad(line: 0, reason: "addresses above 256 MB") }
        var out = [UInt8](repeating: 0xFF, count: end)
        for c in chunks { out.replaceSubrange(c.addr..<(c.addr + c.bytes.count), with: c.bytes) }
        return Data(out)
    }

    /// Writes 32 data bytes per record, using S1, S2 or S3 depending on the highest address.
    static func write(_ data: Data, startAddress: Int = 0, header: String = "ChipBurner") -> String {
        let bytes = [UInt8](data)
        let top = startAddress + max(bytes.count, 1) - 1
        let (dataType, endType, addrLen): (Character, Character, Int) = top <= 0xFFFF ? ("1", "9", 2) : top <= 0xFFFFFF ? ("2", "8", 3) : ("3", "7", 4)
        func record(_ type: Character, _ addr: Int, _ alen: Int, _ payload: [UInt8]) -> String {
            var rec: [UInt8] = [UInt8(alen + payload.count + 1)]
            for k in stride(from: alen - 1, through: 0, by: -1) { rec.append(UInt8((addr >> (8 * k)) & 0xFF)) }
            rec += payload
            let sum = rec.reduce(0) { ($0 + Int($1)) & 0xFF }
            rec.append(UInt8(0xFF - sum))
            return "S\(type)" + rec.map { String(format: "%02X", $0) }.joined()
        }
        var lines = [record("0", 0, 2, Array(header.utf8.prefix(20)))]
        var i = 0, n = 0
        while i < bytes.count {
            let len = min(32, bytes.count - i)
            lines.append(record(dataType, startAddress + i, addrLen, Array(bytes[i..<(i + len)])))
            i += len; n += 1
        }
        if n <= 0xFFFF { lines.append(record("5", n, 2, [])) } else { lines.append(record("6", n, 3, [])) }
        lines.append(record(endType, startAddress, addrLen, []))
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Tools for 16-bit systems that use a pair of 8-bit EPROMs (even/low and odd/high bytes).
enum PairTools {
    static func even(_ d: Data) -> Data { Data(stride(from: 0, to: d.count, by: 2).map { d[d.startIndex + $0] }) }
    static func odd(_ d: Data) -> Data { Data(stride(from: 1, to: d.count, by: 2).map { d[d.startIndex + $0] }) }

    /// Even bytes from `even`, odd bytes from `odd`; a shorter file is padded with FF.
    static func interleave(even e: Data, odd o: Data) -> Data {
        let n = max(e.count, o.count)
        var out = Data(count: 2 * n)
        let ea = [UInt8](e), oa = [UInt8](o)
        for i in 0..<n {
            out[2 * i] = i < ea.count ? ea[i] : 0xFF
            out[2 * i + 1] = i < oa.count ? oa[i] : 0xFF
        }
        return out
    }

    /// Swaps the two bytes of every 16-bit word (a trailing odd byte stays where it is).
    static func swap16(_ d: Data) -> Data {
        var a = [UInt8](d)
        var i = 0
        while i + 1 < a.count { a.swapAt(i, i + 1); i += 2 }
        return Data(a)
    }

    static func lowerHalf(_ d: Data) -> Data { Data(d.prefix(d.count / 2)) }
    static func upperHalf(_ d: Data) -> Data { Data(d.suffix(d.count - d.count / 2)) }
}
