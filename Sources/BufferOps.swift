import Foundation

/// The byte buffer with undo/redo. Every change is a "replace this range with these bytes",
/// so undo only has to remember the bytes that were overwritten.
struct EditableBuffer {
    private(set) var data: Data
    private var undoStack: [(range: Range<Int>, old: Data)] = []
    private var redoStack: [(range: Range<Int>, old: Data)] = []
    /// Undo history is trimmed when the saved bytes exceed this.
    var undoLimitBytes = 64 << 20

    init(_ data: Data = Data()) { self.data = Data(data) }   // Data(...) rebases slices to index 0

    var count: Int { data.count }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    subscript(i: Int) -> UInt8 { data[i] }

    /// Replaces `range` (clamped to the buffer) with `bytes`; returns the range now holding them.
    @discardableResult
    mutating func replace(_ range: Range<Int>, with bytes: Data) -> Range<Int> {
        let r = max(0, min(range.lowerBound, data.count))..<max(0, min(range.upperBound, data.count))
        let old = data.subdata(in: r)
        if old == bytes { return r.lowerBound..<(r.lowerBound + bytes.count) }
        data.replaceSubrange(r, with: bytes)
        let newRange = r.lowerBound..<(r.lowerBound + bytes.count)
        undoStack.append((newRange, old))
        redoStack.removeAll()
        trimUndo()
        return newRange
    }

    mutating func setByte(_ i: Int, _ v: UInt8) { replace(i..<(i + 1), with: Data([v])) }

    @discardableResult
    mutating func undo() -> Range<Int>? {
        guard let e = undoStack.popLast() else { return nil }
        let current = data.subdata(in: e.range)
        data.replaceSubrange(e.range, with: e.old)
        let r = e.range.lowerBound..<(e.range.lowerBound + e.old.count)
        redoStack.append((r, current))
        return r
    }

    @discardableResult
    mutating func redo() -> Range<Int>? {
        guard let e = redoStack.popLast() else { return nil }
        let current = data.subdata(in: e.range)
        data.replaceSubrange(e.range, with: e.old)
        let r = e.range.lowerBound..<(e.range.lowerBound + e.old.count)
        undoStack.append((r, current))
        return r
    }

    private mutating func trimUndo() {
        var total = undoStack.reduce(0) { $0 + $1.old.count }
        while total > undoLimitBytes, !undoStack.isEmpty {
            total -= undoStack.removeFirst().old.count
        }
    }
}

enum BufferOps {
    /// Addresses and sizes are hexadecimal: "1F00", "0x1F00", "$1F00", "1F00h".
    /// A leading "#" means decimal ("#8192"); "32K"/"1M" mean kilobytes/megabytes.
    static func parseNumber(_ text: String) -> Int? {
        var t = text.trimmingCharacters(in: .whitespaces).uppercased().replacingOccurrences(of: "_", with: "")
        guard !t.isEmpty else { return nil }
        if t.hasPrefix("#") { return Int(t.dropFirst()) }
        if let unit = t.last, unit == "K" || unit == "M", let n = Int(t.dropLast()) {
            return n * (unit == "K" ? 1024 : 1024 * 1024)
        }
        if t.hasPrefix("0X") { t.removeFirst(2) } else if t.hasPrefix("$") { t.removeFirst() } else if t.hasSuffix("H") { t.removeLast() }
        return Int(t, radix: 16)
    }

    /// A byte pattern: hex bytes ("AA 55", "AA55", "?? for any byte") or text in quotes ("\"HELLO\"").
    /// nil entries are wildcards.
    static func parsePattern(_ text: String) -> [UInt8?]? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if (t.hasPrefix("\"") && t.hasSuffix("\"") && t.count >= 3) || (t.hasPrefix("'") && t.hasSuffix("'") && t.count >= 3) {
            return Array(t.dropFirst().dropLast().utf8).map { Optional($0) }
        }
        var out: [UInt8?] = []
        for token in t.split(whereSeparator: { $0 == " " || $0 == "," }) {
            var s = String(token).uppercased()
            if s.hasPrefix("0X") { s.removeFirst(2) }
            guard !s.isEmpty else { continue }
            if s.count % 2 == 1 { s = "0" + s }
            var i = s.startIndex
            while i < s.endIndex {
                let pair = String(s[i..<s.index(i, offsetBy: 2)])
                if pair == "??" { out.append(nil) } else if let b = UInt8(pair, radix: 16) { out.append(b) } else { return nil }
                i = s.index(i, offsetBy: 2)
            }
        }
        return out.isEmpty ? nil : out
    }

    /// Next match at or after `start`, wrapping around to the beginning once.
    static func find(_ pattern: [UInt8?], in data: Data, from start: Int) -> Int? {
        let n = data.count, m = pattern.count
        guard m > 0, m <= n else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int? in
            let p = raw.bindMemory(to: UInt8.self)
            func matches(_ i: Int) -> Bool {
                for j in 0..<m { if let b = pattern[j], p[i + j] != b { return false } }
                return true
            }
            let s = max(0, start)
            if s <= n - m { for i in s...(n - m) where matches(i) { return i } }
            for i in 0..<min(s, n - m + 1) where matches(i) { return i }   // wrap around
            return nil
        }
    }

    /// `count` bytes repeating `pattern`.
    static func fill(count: Int, pattern: [UInt8]) -> Data {
        guard !pattern.isEmpty, count > 0 else { return Data(count: max(0, count)) }
        if pattern.count == 1 { return Data(repeating: pattern[0], count: count) }
        var d = Data(capacity: count)
        while d.count < count { d.append(contentsOf: pattern.prefix(count - d.count)) }
        return d
    }

    struct Sums: Equatable {
        var sum8: UInt8, sum16: UInt16, sum32: UInt32, xor8: UInt8, crc32: UInt32
        var twosComplement8: UInt8 { UInt8(truncatingIfNeeded: 0x100 - Int(sum8)) }
    }

    static func checksums(_ data: Data) -> Sums {
        var s: UInt32 = 0, x: UInt8 = 0
        for b in data { s = s &+ UInt32(b); x ^= b }
        return Sums(sum8: UInt8(truncatingIfNeeded: s), sum16: UInt16(truncatingIfNeeded: s), sum32: s,
                    xor8: x, crc32: Checksums.crc32(data))
    }

    /// Address column width for a buffer of this size.
    static func addressDigits(for count: Int) -> Int {
        count > 0x1000000 ? 8 : count > 0x10000 ? 6 : 4
    }
}
