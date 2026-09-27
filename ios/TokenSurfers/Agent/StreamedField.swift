import Foundation

/// One string field of a tool input that is still streaming, decoded
/// incrementally: every call reads only the bytes that arrived since the last
/// one, so following a 60 KB Write costs 60 KB of work, not 60 KB × 500 ticks.
/// Feed it the cumulative JSON text each time (the v1 feed sends it whole; the
/// v2 feed sends deltas the caller appends first).
struct StreamedField {
    let field: String
    /// Decoded so far.
    private(set) var text = ""
    /// The closing quote has arrived.
    private(set) var done = false
    private var started = false
    private var pos = 0                 // utf8 offset consumed so far
    private var pendingHigh: UInt32?    // a high surrogate waiting for its low half

    init(_ field: String) { self.field = field }

    /// Decodes whatever is new in `json`. Returns true when `text` changed.
    @discardableResult
    mutating func feed(_ json: String) -> Bool {
        if done { return false }
        let u = json.utf8
        if !started {
            guard let keyRange = json.range(of: "\"\(field)\"") else { return false }
            var i = keyRange.upperBound
            while i < json.endIndex, json[i] == " " || json[i] == "\n" || json[i] == "\t" || json[i] == "\r" { i = json.index(after: i) }
            guard i < json.endIndex, json[i] == ":" else { return false }
            i = json.index(after: i)
            while i < json.endIndex, json[i] == " " || json[i] == "\n" || json[i] == "\t" || json[i] == "\r" { i = json.index(after: i) }
            guard i < json.endIndex, json[i] == "\"" else { return false }
            i = json.index(after: i)
            pos = u.distance(from: u.startIndex, to: i)
            started = true
        }
        guard u.count > pos else { return false }
        let start = u.index(u.startIndex, offsetBy: pos)
        let bytes = Array(u[start...])
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        var consumed = 0
        let n = bytes.count
        scan: while i < n {
            let c = bytes[i]
            if c == UInt8(ascii: "\"") { done = true; consumed = i + 1; break }
            if c != UInt8(ascii: "\\") {
                // a raw UTF-8 sequence: only take it whole
                let len = c < 0x80 ? 1 : c >= 0xF0 ? 4 : c >= 0xE0 ? 3 : 2
                if i + len > n { break }
                out.append(contentsOf: bytes[i..<(i + len)])
                i += len; consumed = i
                continue
            }
            guard i + 1 < n else { break }          // a lone backslash: wait for the next byte
            let e = bytes[i + 1]
            switch e {
            case UInt8(ascii: "n"): out.append(0x0A); i += 2
            case UInt8(ascii: "t"): out.append(0x09); i += 2
            case UInt8(ascii: "r"): out.append(0x0D); i += 2
            case UInt8(ascii: "b"), UInt8(ascii: "f"): i += 2
            case UInt8(ascii: "u"):
                guard i + 6 <= n else { break scan }  // incomplete \uXXXX: wait
                let hex = String(decoding: bytes[(i + 2)..<(i + 6)], as: UTF8.self)
                guard let v = UInt32(hex, radix: 16) else { i += 6; consumed = i; continue }
                i += 6
                if (0xD800...0xDBFF).contains(v) { pendingHigh = v }
                else if (0xDC00...0xDFFF).contains(v), let hi = pendingHigh {
                    pendingHigh = nil
                    if let s = Unicode.Scalar(0x10000 + ((hi - 0xD800) << 10) + (v - 0xDC00)) { out.append(contentsOf: Array(String(s).utf8)) }
                } else if let s = Unicode.Scalar(v) {
                    out.append(contentsOf: Array(String(s).utf8))
                }
            default: out.append(e); i += 2            // \" \\ \/
            }
            consumed = i
        }
        pos += consumed
        guard !out.isEmpty else { return done }
        text.append(String(decoding: out, as: UTF8.self))
        return true
    }
}
