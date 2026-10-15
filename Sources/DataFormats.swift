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
    static func write(_ data: Data) -> String {
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
            let hi = addr >> 16
            if hi != upper {
                lines.append(record(0x04, 0, [UInt8((hi >> 8) & 0xFF), UInt8(hi & 0xFF)]))
                upper = hi
            }
            let n = min(16, bytes.count - addr, 0x10000 - (addr & 0xFFFF))
            lines.append(record(0x00, addr & 0xFFFF, Array(bytes[addr..<(addr + n)])))
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
