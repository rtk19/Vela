import Foundation
import CommonCrypto
import CryptoKit

/// Native stream extraction adapted from BetterStreamflix's Nekostream and
/// Megacloud extractors (Apache-2.0). No embedded web player or script execution.
struct AnimeStreamResolver: Sendable {
    let client: any HTTPClientProtocol

    func resolve(_ embed: URL, referer: URL, depth: Int = 0) async throws -> PlaybackSource {
        guard depth < 3, ["https", "http"].contains(embed.scheme ?? "") else { throw AppError.noStream }
        let origin = URL(string: "\(embed.scheme!)://\(embed.host ?? "")")!
        let headers = ["Referer": origin.absoluteString + "/", "Origin": origin.absoluteString,
                       "User-Agent": HTTPClient.desktopUserAgent]
        if ["m3u8", "mp4"].contains(embed.pathExtension.lowercased()) {
            var directHeaders = headers
            directHeaders["Referer"] = referer.absoluteString
            directHeaders["Origin"] = "\(referer.scheme ?? "https")://\(referer.host ?? "")"
            return PlaybackSource(url: embed, headers: directHeaders, subtitles: [], preferredPeakBitRate: nil)
        }
        let page = try await get(embed, referer: referer)
        let tree = AnimeHTML.parse(page)
        let fileID = tree.first { $0["id"] == "megaplay-player" }?["data-id"] ??
            tree.first { $0.hasClass("form-area") && !$0["data-id"].isEmpty }?["data-id"]
        if let fileID, !fileID.isEmpty {
            let type = AnimeHTML.captures(#"type:\s*['"]([^'"]+)['"]"#, in: page).first?[1] ??
                embed.pathComponents.last(where: { ["sub", "dub", "raw"].contains($0) })
            let hint = URLComponents(url: embed, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "s" }?.value
            for endpoint in ["getSourcesNew", "getSources"] {
                try Task.checkCancellation()
                var components = URLComponents(url: origin.appending(path: "stream/\(endpoint)"), resolvingAgainstBaseURL: false)!
                components.queryItems = [.init(name: "id", value: fileID)]
                if let type { components.queryItems?.append(.init(name: "type", value: type)) }
                if let hint { components.queryItems?.append(.init(name: "s", value: hint)) }
                do {
                    let body = try await get(components.url!, referer: embed, ajax: true)
                    if var object = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
                       let encrypted = object["enc"] as? String {
                        let decoded = try Self.decodeNekostream(encrypted)
                        object["sources"] = decoded
                        return try Self.source(from: JSONSerialization.data(withJSONObject: object), relativeTo: embed, headers: headers)
                    }
                    return try Self.source(from: Data(body.utf8), relativeTo: embed, headers: headers)
                } catch where error.isCancellation { throw error }
                catch { continue }
            }
            throw AppError.noStream
        }
        if embed.path.contains("/embed-") || embed.path.contains("/e-") {
            var components = URLComponents(url: embed.deletingLastPathComponent().appending(path: "getSources"), resolvingAgainstBaseURL: false)!
            components.queryItems = [.init(name: "id", value: embed.lastPathComponent)]
            if let token = Self.token(in: page) { components.queryItems?.append(.init(name: "_k", value: token)) }
            let body = try await get(components.url!, referer: embed, ajax: true)
            if let object = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
               let encrypted = object["sources"] as? String {
                let script = try await get(origin.appending(path: "js/player/a/prod/e1-player.min.js"), referer: embed)
                let sources = try Self.decryptSources(encrypted, script: script)
                var result = object
                result["sources"] = try JSONSerialization.jsonObject(with: sources)
                return try Self.source(from: JSONSerialization.data(withJSONObject: result), relativeTo: embed, headers: headers)
            }
            return try Self.source(from: Data(body.utf8), relativeTo: embed, headers: headers)
        }
        // Plain HTML5 sources and an explicitly embedded child player are safe fallbacks.
        if let node = tree.first({ $0.tag == "source" || $0.tag == "video" }),
           let url = URL(string: node["src"], relativeTo: embed)?.absoluteURL,
           ["m3u8", "mp4"].contains(url.pathExtension.lowercased()) {
            return PlaybackSource(url: url, headers: headers, subtitles: [], preferredPeakBitRate: nil)
        }
        if let node = tree.first({ $0.tag == "iframe" }), let child = URL(string: node["src"], relativeTo: embed)?.absoluteURL {
            return try await resolve(child, referer: embed, depth: depth + 1)
        }
        throw AppError.noStream
    }

    private func get(_ url: URL, referer: URL, ajax: Bool = false) async throws -> String {
        var request = URLRequest.providerRequest(url: url, referer: referer, acceptsJSON: ajax)
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        request.setValue("\(url.scheme ?? "https")://\(url.host ?? "")", forHTTPHeaderField: "Origin")
        request.timeoutInterval = 10
        let response = try await client.data(for: request)
        guard let string = String(data: response.data, encoding: .utf8) else { throw AppError.invalidResponse }
        return string
    }

    static func source(from data: Data, relativeTo base: URL, headers: [String: String]) throws -> PlaybackSource {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AppError.noStream }
        let sources: [[String: Any]]
        if let list = object["sources"] as? [[String: Any]] { sources = list }
        else if let value = object["sources"] as? [String: Any] { sources = [value] + (value["list"] as? [[String: Any]] ?? []) }
        else { throw AppError.noStream }
        guard let file = sources.compactMap({ $0["file"] as? String }).first(where: { !$0.isEmpty }),
              let url = URL(string: file, relativeTo: base)?.absoluteURL,
              ["https", "http"].contains(url.scheme ?? "") else { throw AppError.noStream }
        let subtitles = (object["tracks"] as? [[String: Any]] ?? []).compactMap { track -> SubtitleSource? in
            guard track["kind"] == nil || ["captions", "subtitles"].contains(track["kind"] as? String ?? ""),
                  let file = track["file"] as? String, let url = URL(string: file, relativeTo: base)?.absoluteURL else { return nil }
            let label = track["label"] as? String ?? "Subtitle"
            let language = track["srclang"] as? String ?? languageCode(label)
            return SubtitleSource(label: label, languageCode: language, url: url, isDefault: track["default"] as? Bool ?? false, headers: headers)
        }
        return PlaybackSource(url: url, headers: headers, subtitles: subtitles, preferredPeakBitRate: nil)
    }

    // Public client wire-format constants observed in newclient.min.js v4.8 /
    // e1-player.min.js v2.8. These are provider protocol values, not user secrets.
    static func decodeNekostream(_ encoded: String, now: Date = Date()) throws -> [String: String] {
        var key = Data("i?LMTAx0Q6,:}50U".utf8)
        key.append(Data(repeating: 0, count: 32 - key.count))
        let iv = Data("W0;27ToaUpl_P%'c".utf8)
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let encrypted = Data(base64Encoded: base64), !encrypted.isEmpty else { throw AppError.noStream }
        let decoded = try aesCBC(encrypted, key: key, iv: iv)
        guard let payload = try JSONSerialization.jsonObject(with: decoded) as? [String: String],
              let file = payload["file"], var url = URLComponents(string: file),
              ["https", "http"].contains(url.scheme ?? "") else { throw AppError.noStream }
        if url.queryItems?.contains(where: { $0.name == "token" }) != true,
           let path = AnimeHTML.captures(#"/([a-f0-9]{32})/([a-f0-9]{32})/"#, in: file).first {
            let message = "\(Int(now.timeIntervalSince1970) + 90)|\(path[1].lowercased())/\(path[2].lowercased())"
            let signature = HMAC<SHA256>.authenticationCode(for: Data(message.utf8),
                using: SymmetricKey(data: Data("MpCdnT0k3n!9f2K#xQ7vL5mR8wN1pY4s".utf8)))
            func safe64(_ data: Data) -> String {
                data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            }
            var items = url.queryItems ?? []
            items.append(.init(name: "token", value: safe64(Data(message.utf8)) + "." + safe64(Data(signature))))
            url.queryItems = items
        }
        guard let result = url.url else { throw AppError.noStream }
        return ["file": result.absoluteString]
    }

    static func aesCBC(_ encrypted: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == 32, iv.count == 16, encrypted.count % 16 == 0 else { throw AppError.noStream }
        var output = [UInt8](repeating: 0, count: encrypted.count + kCCBlockSizeAES128)
        let capacity = output.count
        var written = 0
        let status = key.withUnsafeBytes { k in iv.withUnsafeBytes { v in encrypted.withUnsafeBytes { e in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    k.baseAddress, kCCKeySizeAES256, v.baseAddress, e.baseAddress, encrypted.count, &output, capacity, &written)
        } } }
        guard status == kCCSuccess else { throw AppError.noStream }
        return Data(output.prefix(written))
    }

    static func languageCode(_ label: String) -> String? {
        let names = ["english": "en", "japanese": "ja", "hebrew": "he", "arabic": "ar", "spanish": "es", "french": "fr", "german": "de", "italian": "it", "portuguese": "pt", "russian": "ru", "chinese": "zh", "korean": "ko"]
        return names.first { label.lowercased().hasPrefix($0.key) }?.value
    }
    static func token(in html: String) -> String? {
        if let values = AnimeHTML.captures(#"\w+\s*=\s*\{[^}]*?\w+:\s*"([^"]+)",\s*\w+:\s*"([^"]+)"(?:,\s*\w+:\s*"([^"]+)")?"#, in: html).first {
            return values.dropFirst().joined()
        }
        return AnimeHTML.captures(#"[A-Za-z0-9+/=]{30,}"#, in: html).map { $0[0] }.max { $0.count < $1.count }
    }

    static func decryptSources(_ value: String, script: String) throws -> Data {
        let matches = AnimeHTML.captures(#"case\s*0x[0-9a-f]+:(?![^;]*=partKey)\s*\w+\s*=\s*(\w+)\s*,\s*\w+\s*=\s*(\w+);"#, in: script)
        var chars = Array(value)
        var secret = ""
        var offset = 0
        guard !matches.isEmpty else { throw AppError.noStream }
        for match in matches {
            let numbers = try match.dropFirst().map { variable -> Int in
                let pattern = "," + NSRegularExpression.escapedPattern(for: variable) + #"=((?:0x)?[0-9a-fA-F]+)"#
                guard let token = AnimeHTML.captures(pattern, in: script).first?[1],
                      let number = Int(token.replacingOccurrences(of: "0x", with: ""), radix: 16) else { throw AppError.noStream }
                return number
            }
            let start = numbers[0] + offset, length = numbers[1]
            guard start >= 0, length > 0, start <= chars.count, length <= chars.count - start else { throw AppError.noStream }
            for index in start..<(start + length) { secret.append(chars[index]); chars[index] = " " }
            offset += length
        }
        guard let cipher = Data(base64Encoded: String(chars).replacingOccurrences(of: " ", with: "")),
              cipher.count > 16, cipher.prefix(8) == Data("Salted__".utf8) else { throw AppError.noStream }
        let salt = cipher.subdata(in: 8..<16)
        var material = Data(), previous = Data()
        while material.count < 48 {
            let input = previous + Data(secret.utf8) + salt
            // Required by this upstream OpenSSL-compatible wire format, not used for security decisions.
            previous = Data(Insecure.MD5.hash(data: input))
            material.append(previous)
        }
        let key = material.prefix(32), iv = material.suffix(16), encrypted = cipher.dropFirst(16)
        var output = [UInt8](repeating: 0, count: encrypted.count + kCCBlockSizeAES128)
        let capacity = output.count
        var written = 0
        let status = key.withUnsafeBytes { k in iv.withUnsafeBytes { v in encrypted.withUnsafeBytes { e in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    k.baseAddress, kCCKeySizeAES256, v.baseAddress, e.baseAddress, encrypted.count, &output, capacity, &written)
        } } }
        guard status == kCCSuccess else { throw AppError.noStream }
        return Data(output.prefix(written))
    }
}
