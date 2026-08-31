import Foundation

actor VixcloudResolver {
    private let client: any HTTPClientProtocol

    init(client: any HTTPClientProtocol) {
        self.client = client
    }

    func resolve(iframeURL: URL, referer: URL) async throws -> PlaybackSource {
        var request = URLRequest.providerRequest(url: iframeURL, referer: referer)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let response = try await client.data(for: request)
        let script = try HTMLPayloadParser.scriptContaining("window.video", from: response.data)

        guard let videoID = capture(#"window\.video\s*=\s*\{[\s\S]*?\bid\s*:\s*[\"']?(\d+)"#, in: script),
              let token = capture(#"[\"']?token[\"']?\s*:\s*[\"']([^\"']+)"#, in: script),
              let expires = capture(#"[\"']?expires[\"']?\s*:\s*[\"']([^\"']+)"#, in: script) else {
            throw AppError.decoding("Vixcloud token")
        }

        var components = URLComponents()
        components.scheme = iframeURL.scheme ?? "https"
        components.host = iframeURL.host
        components.path = "/playlist/\(videoID)"
        var query = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "expires", value: expires),
            URLQueryItem(name: "language", value: "en")
        ]
        if script.range(of: #"\bb\s*=\s*1"#, options: .regularExpression) != nil {
            query.append(URLQueryItem(name: "b", value: "1"))
        }
        if URLComponents(url: iframeURL, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "canPlayFHD" }) == true {
            query.append(URLQueryItem(name: "h", value: "1"))
        }
        components.queryItems = query
        guard let playlistURL = components.url else { throw AppError.invalidURL }

        return PlaybackSource(
            url: playlistURL,
            headers: [
                "Referer": "\(iframeURL.scheme ?? "https")://\(iframeURL.host ?? "")/",
                "User-Agent": HTTPClient.desktopUserAgent,
                "Accept-Language": "en-US,en;q=0.9",
                "Cookie": "language=en"
            ],
            subtitles: [],
            preferredPeakBitRate: nil
        )
    }

    private func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
