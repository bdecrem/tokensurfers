import Foundation

/// One streamed Messages call through hilma's /api/surf/llm. The server adds
/// the system prompt, tools and key and passes Anthropic's SSE through as-is.
enum StreamEvent {
    case messageStart(inputTokens: Int, cacheRead: Int)
    case blockStart(index: Int, block: [String: Any])
    case textDelta(index: Int, text: String)
    case thinkingDelta(index: Int, text: String)
    case signatureDelta(index: Int, signature: String)
    case inputJSONDelta(index: Int, partial: String)
    case blockStop(index: Int)
    case messageDelta(stopReason: String?, outputTokens: Int)
    case messageStop
}

struct SurfAPIError: LocalizedError {
    let message: String
    /// Worth one more try in a few seconds (overloaded, rate limited, a 5xx).
    var transient = false
    var errorDescription: String? { message }
}

/// hilma, or TS_BACKEND=http://localhost:3219 in the simulator to hit a dev server.
func backendURL() -> URL {
    if let raw = ProcessInfo.processInfo.environment["TS_BACKEND"], let url = URL(string: raw) { return url }
    return Secrets.backendURL
}

enum SurfAPI {
    static func stream(messages: [[String: Any]], effort: String = "medium") -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: backendURL().appendingPathComponent("api/surf/llm"))
                    req.httpMethod = "POST"
                    req.timeoutInterval = 300
                    req.setValue("application/json", forHTTPHeaderField: "content-type")
                    req.setValue(Secrets.appKey, forHTTPHeaderField: "x-surf-key")
                    req.httpBody = try JSONSerialization.data(withJSONObject: ["messages": messages, "effort": effort])

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if status != 200 {
                        var body = ""
                        for try await line in bytes.lines { body += line; if body.count > 2000 { break } }
                        let msg = (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])?["error"] as? String
                        throw SurfAPIError(message: msg ?? "server said \(status)",
                                           transient: [408, 409, 425, 429, 500, 502, 503, 504, 529].contains(status))
                    }

                    var eventName = ""
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        if line.hasPrefix("event:") {
                            eventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                            continue
                        }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
                        let type = obj["type"] as? String ?? eventName
                        if let ev = try parse(type: type, obj) { continuation.yield(ev) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func parse(type: String, _ obj: [String: Any]) throws -> StreamEvent? {
        switch type {
        case "message_start":
            let usage = (obj["message"] as? [String: Any])?["usage"] as? [String: Any]
            return .messageStart(inputTokens: usage?["input_tokens"] as? Int ?? 0,
                                 cacheRead: (usage?["cache_read_input_tokens"] as? Int ?? 0) + (usage?["cache_creation_input_tokens"] as? Int ?? 0))
        case "content_block_start":
            return .blockStart(index: obj["index"] as? Int ?? 0,
                               block: obj["content_block"] as? [String: Any] ?? [:])
        case "content_block_delta":
            let i = obj["index"] as? Int ?? 0
            let d = obj["delta"] as? [String: Any] ?? [:]
            switch d["type"] as? String {
            case "text_delta": return .textDelta(index: i, text: d["text"] as? String ?? "")
            case "thinking_delta": return .thinkingDelta(index: i, text: d["thinking"] as? String ?? "")
            case "signature_delta": return .signatureDelta(index: i, signature: d["signature"] as? String ?? "")
            case "input_json_delta": return .inputJSONDelta(index: i, partial: d["partial_json"] as? String ?? "")
            default: return nil
            }
        case "content_block_stop":
            return .blockStop(index: obj["index"] as? Int ?? 0)
        case "message_delta":
            let d = obj["delta"] as? [String: Any]
            let u = obj["usage"] as? [String: Any]
            return .messageDelta(stopReason: d?["stop_reason"] as? String, outputTokens: u?["output_tokens"] as? Int ?? 0)
        case "message_stop":
            return .messageStop
        case "error":
            let e = obj["error"] as? [String: Any]
            let kind = e?["type"] as? String ?? ""
            throw SurfAPIError(message: e?["message"] as? String ?? "stream error",
                               transient: ["overloaded_error", "api_error", "rate_limit_error", "timeout_error"].contains(kind))
        default:
            return nil
        }
    }
}

/// Reads string fields out of a tool input that is still being streamed
/// (`{"caption": "so it's 3am", "content": "<!DOCTYPE html>\n<ht…`).
enum PartialJSON {
    /// The (possibly unfinished) value of a top-level string field.
    static func string(_ field: String, in json: String) -> String? { field2(field, in: json)?.0 }

    /// The value and whether its closing quote has arrived.
    static func field2(_ field: String, in json: String) -> (String, Bool)? {
        guard let keyRange = json.range(of: "\"\(field)\"") else { return nil }
        var i = keyRange.upperBound
        let chars = json
        // skip whitespace, colon, whitespace, opening quote
        while i < chars.endIndex, chars[i] == " " || chars[i] == "\n" || chars[i] == "\t" { i = chars.index(after: i) }
        guard i < chars.endIndex, chars[i] == ":" else { return nil }
        i = chars.index(after: i)
        while i < chars.endIndex, chars[i] == " " || chars[i] == "\n" || chars[i] == "\t" { i = chars.index(after: i) }
        guard i < chars.endIndex, chars[i] == "\"" else { return nil }
        i = chars.index(after: i)
        return decode(chars[i...])
    }

    /// Decodes a JSON string body up to its closing quote or the end of input.
    private static func decode(_ s: Substring) -> (String, Bool) {
        var out = ""
        out.reserveCapacity(s.count)
        var it = s.unicodeScalars.makeIterator()
        var pendingHigh: UInt32?
        while let c = it.next() {
            if c == "\"" { return (out, true) }
            if c != "\\" { out.unicodeScalars.append(c); continue }
            guard let e = it.next() else { return (out, false) }
            switch e {
            case "n": out += "\n"
            case "t": out += "\t"
            case "r": out += "\r"
            case "b", "f": break
            case "u":
                var hex = ""
                for _ in 0..<4 { if let h = it.next() { hex.unicodeScalars.append(h) } }
                guard hex.count == 4, let v = UInt32(hex, radix: 16) else { return (out, false) }
                if (0xD800...0xDBFF).contains(v) { pendingHigh = v; continue }
                if (0xDC00...0xDFFF).contains(v), let hi = pendingHigh {
                    let code = 0x10000 + ((hi - 0xD800) << 10) + (v - 0xDC00)
                    if let u = Unicode.Scalar(code) { out.unicodeScalars.append(u) }
                    pendingHigh = nil
                    continue
                }
                if let u = Unicode.Scalar(v) { out.unicodeScalars.append(u) }
            default: out.unicodeScalars.append(e)   // \" \\ \/
            }
        }
        return (out, false)
    }
}
