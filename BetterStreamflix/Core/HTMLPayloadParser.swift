import Foundation

enum HTMLPayloadParser {
    static func inertiaJSON(from data: Data) throws -> Data {
        guard let html = String(data: data, encoding: .utf8) else { throw AppError.decoding("HTML encoding") }
        let patterns = [
            #"id=[\"']app[\"'][^>]*data-page=[\"'](.*?)[\"'][^>]*>"#,
            #"data-page=[\"'](.*?)[\"'][^>]*id=[\"']app[\"'][^>]*>"#
        ]
        for pattern in patterns {
            let regex = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive])
            let range = NSRange(html.startIndex..., in: html)
            guard let match = regex.firstMatch(in: html, range: range),
                  let capture = Range(match.range(at: 1), in: html) else { continue }
            let decoded = decodeEntities(String(html[capture]))
            guard let json = decoded.data(using: .utf8) else { break }
            return json
        }
        throw AppError.decoding("Inertia data-page was not found")
    }

    static func firstIFrameURL(from data: Data, relativeTo baseURL: URL) throws -> URL {
        guard let html = String(data: data, encoding: .utf8) else { throw AppError.decoding("HTML encoding") }
        let regex = try NSRegularExpression(pattern: #"<iframe[^>]+src\s*=\s*[\"']([^\"']+)[\"']"#, options: .caseInsensitive)
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let capture = Range(match.range(at: 1), in: html),
              let url = URL(string: decodeEntities(String(html[capture])), relativeTo: baseURL)?.absoluteURL else {
            throw AppError.noStream
        }
        return url
    }

    static func scriptContaining(_ needle: String, from data: Data) throws -> String {
        guard let html = String(data: data, encoding: .utf8) else { throw AppError.decoding("HTML encoding") }
        let regex = try NSRegularExpression(pattern: #"<script[^>]*>([\s\S]*?)</script>"#, options: .caseInsensitive)
        let range = NSRange(html.startIndex..., in: html)
        for match in regex.matches(in: html, range: range) {
            guard let capture = Range(match.range(at: 1), in: html) else { continue }
            let script = String(html[capture])
            if script.contains(needle) { return script }
        }
        throw AppError.decoding("Player script was not found")
    }

    static func decodeEntities(_ value: String) -> String {
        var result = value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
        let regex = try? NSRegularExpression(pattern: #"&#(x?[0-9A-Fa-f]+);"#)
        let matches = (regex?.matches(in: result, range: NSRange(result.startIndex..., in: result)) ?? []).reversed()
        for match in matches {
            guard let whole = Range(match.range(at: 0), in: result),
                  let number = Range(match.range(at: 1), in: result) else { continue }
            let token = String(result[number])
            let scalarValue = token.lowercased().hasPrefix("x")
                ? UInt32(token.dropFirst(), radix: 16)
                : UInt32(token, radix: 10)
            if let scalarValue, let scalar = UnicodeScalar(scalarValue) {
                result.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }
        return result
    }
}
