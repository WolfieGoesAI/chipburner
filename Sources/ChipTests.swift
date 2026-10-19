import Foundation

/// Test patterns and result analysis for the SRAM test and the EPROM/EEPROM/flash health check.
/// Pure data functions (no UI, no programmer) so the build can test them with simulated faulty chips.
enum ChipTests {

    // MARK: Patterns

    enum Pattern: String, CaseIterable {
        case zeros = "all 00", ones = "all FF", x55 = "55 (01010101)", xAA = "AA (10101010)"
        case checker = "checkerboard 55/AA"
        case addressLow = "address A0–A7 pattern", addressHigh = "address A8–A15 pattern", addressTop = "address A16–A23 pattern"

        /// The address bits an address pattern checks (each appears in exactly one pattern).
        var addressBits: Range<Int>? {
            switch self {
            case .addressLow: return 0..<8
            case .addressHigh: return 8..<16
            case .addressTop: return 16..<24
            default: return nil
            }
        }

        /// The address patterns needed for a chip of this size.
        static func addressPatterns(for size: Int) -> [Pattern] {
            var p: [Pattern] = [.addressLow]
            if size > 0x100 { p.append(.addressHigh) }
            if size > 0x10000 { p.append(.addressTop) }
            return p
        }

        func byte(at a: Int) -> UInt8 {
            switch self {
            case .zeros: return 0x00
            case .ones: return 0xFF
            case .x55: return 0x55
            case .xAA: return 0xAA
            case .checker: return a & 1 == 0 ? 0x55 : 0xAA
            case .addressLow: return UInt8(truncatingIfNeeded: a)
            case .addressHigh: return UInt8(truncatingIfNeeded: a >> 8)
            case .addressTop: return UInt8(truncatingIfNeeded: a >> 16)
            }
        }

        func data(count: Int) -> Data {
            var d = Data(count: count)
            d.withUnsafeMutableBytes { (p: UnsafeMutableRawBufferPointer) in
                let b = p.bindMemory(to: UInt8.self)
                for i in 0..<count { b[i] = byte(at: i) }
            }
            return d
        }
    }

    // An address pattern stores one byte of each cell's own address. If an address line is stuck or
    // shorted, two addresses share a cell, so one of them reads back the value of the address one
    // bit away – which tells exactly which line it is.

    // MARK: Comparing a pattern with what was read back

    struct Mismatch: Equatable { let address: Int; let expected: UInt8; let got: UInt8 }

    struct CompareResult {
        var badBytes = 0
        var badBits: UInt8 = 0                 // OR of every expected^got
        var samples: [Mismatch] = []           // the first few
        var addressLineSuspects: [Int] = []    // address bits that look stuck or shorted
        var sizeMismatch = false
        var ok: Bool { badBytes == 0 && !sizeMismatch }
    }

    static func compare(expected: Data, got: Data, pattern: Pattern?, maxSamples: Int = 12) -> CompareResult {
        var r = CompareResult()
        if expected.count != got.count { r.sizeMismatch = true }
        let n = min(expected.count, got.count)
        guard n > 0 else { return r }
        let e = [UInt8](expected.prefix(n)), g = [UInt8](got.prefix(n))
        var failing: [Int] = []
        for i in 0..<n where e[i] != g[i] {
            r.badBytes += 1
            r.badBits |= e[i] ^ g[i]
            if r.samples.count < maxSamples { r.samples.append(Mismatch(address: i, expected: e[i], got: g[i])) }
            if failing.count < 200_000 { failing.append(i) }
        }
        // Address-line check: a failing byte that holds the value of the address one bit away.
        if let p = pattern, let range = p.addressBits, !failing.isEmpty {
            var bits = 0
            while (1 << bits) < n { bits += 1 }
            for k in range where k < bits {
                var hits = 0
                for a in failing {
                    let b = a ^ (1 << k)
                    if b < n && g[a] == p.byte(at: b) { hits += 1 }
                }
                // Aliasing hits about half the addresses of the chip.
                if hits >= max(4, n / 8) { r.addressLineSuspects.append(k) }
            }
        }
        return r
    }

    // MARK: Repeated reads

    struct StabilityResult {
        var unstableBytes = 0
        var unstableBits: UInt8 = 0
        var samples: [(address: Int, values: [UInt8])] = []
        /// Per unstable address: each value read and how many times.
        var counts: [(address: Int, counts: [(value: UInt8, count: Int)])] = []
        var ok: Bool { unstableBytes == 0 }
    }

    /// Compares reads one at a time with the first, so even 256 reads of a large chip need only two reads in
    /// memory. For the first unstable addresses it counts how often each value was read.
    final class StabilityAccumulator {
        let base: [UInt8]
        private var diff: [UInt8]
        private var tracked: [(address: Int, counts: [(value: UInt8, count: Int)])] = []
        private let maxSamples: Int
        private(set) var reads = 1

        init(base: Data, maxSamples: Int = 12) {
            self.base = [UInt8](base)
            diff = [UInt8](repeating: 0, count: base.count)
            self.maxSamples = maxSamples
        }

        func add(_ data: Data) {
            let read = [UInt8](data)
            let n = min(base.count, read.count)
            for t in tracked.indices where tracked[t].address < n {
                let v = read[tracked[t].address]
                if let k = tracked[t].counts.firstIndex(where: { $0.value == v }) { tracked[t].counts[k].count += 1 }
                else { tracked[t].counts.append((v, 1)) }
            }
            for i in 0..<n {
                let x = read[i] ^ base[i]
                if x == 0 { continue }
                if diff[i] == 0 && tracked.count < maxSamples {
                    // first time this byte differs: every earlier read gave the base value
                    tracked.append((i, [(base[i], reads), (read[i], 1)]))
                }
                diff[i] |= x
            }
            reads += 1
        }

        func result() -> StabilityResult {
            var r = StabilityResult()
            for d in diff where d != 0 { r.unstableBytes += 1; r.unstableBits |= d }
            r.counts = tracked
            return r
        }
    }

    static func stability(_ reads: [Data], maxSamples: Int = 12) -> StabilityResult {
        var r = StabilityResult()
        guard let first = reads.first else { return r }
        let arrays = reads.map { [UInt8]($0) }
        let n = arrays.map { $0.count }.min() ?? 0
        for i in 0..<n {
            let v0 = arrays[0][i]
            var diff: UInt8 = 0
            for a in arrays.dropFirst() { diff |= a[i] ^ v0 }
            if diff != 0 {
                r.unstableBytes += 1
                r.unstableBits |= diff
                if r.samples.count < maxSamples { r.samples.append((i, arrays.map { $0[i] })) }
            }
        }
        _ = first
        return r
    }

    // MARK: Content analysis (one read of an EPROM/EEPROM/flash)

    struct ContentReport {
        var size = 0
        var blank = false
        var ffBytes = 0
        var zeroBytes = 0
        var alwaysOne: UInt8 = 0      // bits that are 1 in every byte
        var alwaysZero: UInt8 = 0     // bits that are 0 in every byte
        var repeatsEvery: Int?        // smallest power of two the content repeats with, if < size
    }

    static func analyse(_ data: Data) -> ContentReport {
        var r = ContentReport()
        let b = [UInt8](data)
        r.size = b.count
        guard !b.isEmpty else { return r }
        var andAll: UInt8 = 0xFF, orAll: UInt8 = 0
        for x in b {
            andAll &= x; orAll |= x
            if x == 0xFF { r.ffBytes += 1 } else if x == 0 { r.zeroBytes += 1 }
        }
        r.blank = r.ffBytes == b.count
        r.alwaysOne = andAll
        r.alwaysZero = ~orAll
        // Find the smallest period 2^k (k ≥ 8) with b[a] == b[a + 2^k] everywhere.
        if !r.blank && r.zeroBytes != b.count {
            var period = 256
            while period < b.count {
                var same = true
                var i = 0
                while i + period < b.count { if b[i] != b[i + period] { same = false; break }; i += 1 }
                if same { r.repeatsEvery = period; break }
                period <<= 1
            }
        }
        return r
    }

    static func bitList(_ mask: UInt8) -> String {
        (0..<8).filter { mask & (1 << $0) != 0 }.map { "D\($0)" }.joined(separator: ", ")
    }

    static func hex(_ v: Int, digits: Int) -> String { String(format: "%0\(digits)X", v) }

    /// Plain-language hints from a content report.
    static func hints(_ r: ContentReport) -> [String] {
        var out: [String] = []
        if r.size == 0 { return ["Nothing was read."] }
        if r.blank { return ["The chip is blank (every byte is FF) – erased or never programmed."] }
        if r.zeroBytes == r.size {
            return ["Every byte reads 00. That usually means the chip isn't seated properly, is in the wrong way round, or the wrong chip type is selected."]
        }
        let pct = Double(r.ffBytes) * 100 / Double(r.size)
        out.append(String(format: "%.1f%% of the bytes are FF (unprogrammed).", pct))
        if r.alwaysOne != 0 {
            out.append("Bit \(bitList(r.alwaysOne)) is 1 in every byte. Possible with some data, but it can also mean a broken data line or a bad pin contact.")
        }
        if r.alwaysZero != 0 {
            let only7 = r.alwaysZero == 0x80
            out.append("Bit \(bitList(r.alwaysZero)) is 0 in every byte." + (only7 ? " Normal for 7-bit data such as character ROMs; otherwise check D7's pin." : " This can mean a broken data line or a bad pin contact."))
        }
        if let p = r.repeatsEvery {
            var k = 0
            while (1 << k) < p { k += 1 }
            out.append("The contents repeat every \(p / 1024 > 0 ? "\(p / 1024) KB" : "\(p) bytes"): address line A\(k) and above make no difference. Either the image is a smaller one repeated (common), or A\(k) isn't working.")
        }
        return out
    }
}
