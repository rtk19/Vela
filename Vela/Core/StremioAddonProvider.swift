import Foundation

private enum StremioAddonConfiguration {
    static var baseURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "ExternalStreamAddonManifestURL") as? String,
              let manifest = URL(string: raw) else { return nil }
        return manifest.deletingLastPathComponent()
    }
}

private struct StremioStreamPayload: Decodable, Sendable {
    let streams: [StremioStream]
}

private struct StremioSubtitlePayload: Decodable, Sendable {
    let subtitles: [StremioSubtitle]
}

private struct StremioStream: Decodable, Sendable {
    let name: String?
    let description: String?
    let url: URL?
    let ytId: String?
    let infoHash: String?
    let externalUrl: URL?
    let behaviorHints: BehaviorHints?

    struct BehaviorHints: Decodable, Sendable {
        let bingeGroup: String?
        let videoSize: Int64?
        let filename: String?
        let proxyHeaders: ProxyHeaders?
    }

    struct ProxyHeaders: Decodable, Sendable {
        let request: [String: String]?
    }
}

private struct StremioSubtitle: Decodable, Sendable {
    let id: String?
    let lang: String?
    let url: URL?
}

private struct StremioAddonClient: Sendable {
    let client: any HTTPClientProtocol
    let baseURL: URL?

    init(client: any HTTPClientProtocol = HTTPClient(), baseURL: URL? = StremioAddonConfiguration.baseURL) {
        self.client = client
        self.baseURL = baseURL
    }

    func streams(for context: PlaybackLookupContext) async throws -> [StremioStream] {
        guard let imdbID = context.request.media.imdbID,
              let url = resourceURL(name: "stream", kind: context.request.media.kind,
                                    imdbID: imdbID, episode: context.request.episode) else { return [] }
        return try await load(StremioStreamPayload.self, from: url).streams
    }

    func subtitles(for request: SubtitleLookupRequest) async throws -> [StremioSubtitle] {
        let episode = request.seasonNumber.flatMap { season in
            request.episodeNumber.map { MediaEpisode(id: "", providerID: "", showID: "", seasonNumber: season,
                                                      number: $0, title: nil, overview: nil, posterURL: nil) }
        }
        guard let url = resourceURL(name: "subtitles", kind: request.kind,
                                    imdbID: request.imdbID, episode: episode) else { return [] }
        return try await load(StremioSubtitlePayload.self, from: url).subtitles
    }

    private func resourceURL(name: String, kind: MediaKind, imdbID: String, episode: MediaEpisode?) -> URL? {
        guard let baseURL, imdbID.range(of: #"^tt\d{7,9}$"#, options: .regularExpression) != nil else { return nil }
        let type = kind == .movie ? "movie" : "series"
        var identifier = imdbID
        if kind == .series {
            guard let episode else { return nil }
            identifier += ":\(episode.seasonNumber):\(episode.number)"
        }
        return baseURL.appending(path: name).appending(path: type).appending(path: identifier + ".json")
    }

    private func load<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Vela-iOS", forHTTPHeaderField: "User-Agent")
        let response = try await client.data(for: request)
        try Task.checkCancellation()
        do { return try JSONDecoder().decode(type, from: response.data) }
        catch { throw AppError.decoding("External stream response") }
    }
}

struct StremioPlaybackProvider: PlaybackProvider {
    let id = "external-streams"
    private let addon: StremioAddonClient

    init(client: any HTTPClientProtocol = HTTPClient(), baseURL: URL? = StremioAddonConfiguration.baseURL) {
        addon = StremioAddonClient(client: client, baseURL: baseURL)
    }

    func candidates(for context: PlaybackLookupContext) async throws -> [PlaybackCandidate] {
        let streams = try await addon.streams(for: context)
        return streams.enumerated().compactMap { index, stream in candidate(stream, order: index, context: context) }
    }

    private func candidate(_ stream: StremioStream, order: Int, context: PlaybackLookupContext) -> PlaybackCandidate? {
        guard stream.ytId == nil, stream.infoHash == nil, stream.externalUrl == nil,
              let url = stream.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let format = Self.playableFormat(for: stream, url: url) else { return nil }
        let description = stream.description ?? ""
        let origin = Self.capture(#"(?im)^.*Source:\s*([^\n\r]+)"#, in: description)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let origin, !origin.isEmpty else { return nil }
        let quality = Self.capture(#"(?i)(2160p|1080p|720p|480p|360p|4K)"#, in: description)
        let release = Self.capture(#"(?i)\b(BluRay|WEB-DL|WEBRip|HDR|REMUX)\b"#, in: description)
        let audio = Self.capture(#"(?im)^.*Audio:\s*([^,\n\r]+)"#, in: description)
        let language = Self.languageCode(audio)
        let stableServer = [origin, quality, format, stream.behaviorHints?.bingeGroup ?? "\(order)"]
            .compactMap { $0 }.joined(separator: "|")
        let preference = PlaybackSourcePreference(providerID: id, serverName: stableServer,
                                                  audioLanguage: language ?? "")
        let candidateID = "\(id):\(stableServer.lowercased())"
        let metadata = StreamDisplayMetadata(origin: origin, quality: quality,
            sizeBytes: stream.behaviorHints?.videoSize, container: format.uppercased(),
            audioLanguage: audio, releaseType: release)
        let initial = Self.playbackSource(for: stream, url: url)
        let resolver = RefreshingStremioSource(initial: initial) {
            let refreshed = try await addon.streams(for: context)
            guard let match = refreshed.enumerated().first(where: { offset, candidate in
                Self.stableServer(for: candidate, order: offset) == stableServer
            }), let refreshedURL = match.element.url else { throw AppError.noStream }
            return Self.playbackSource(for: match.element, url: refreshedURL)
        }
        return PlaybackCandidate(id: candidateID, preference: preference, providerName: origin,
            subtitleKind: .unknown, displayMetadata: metadata,
            resolve: { try await resolver.resolve() })
    }

    private static func stableServer(for stream: StremioStream, order: Int) -> String? {
        let description = stream.description ?? ""
        guard let url = stream.url, playableFormat(for: stream, url: url) != nil,
              let origin = capture(#"(?im)^.*Source:\s*([^\n\r]+)"#, in: description)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !origin.isEmpty else { return nil }
        let quality = capture(#"(?i)(2160p|1080p|720p|480p|360p|4K)"#, in: description)
        let format = playableFormat(for: stream, url: url)
        return [origin, quality, format, stream.behaviorHints?.bingeGroup ?? "\(order)"]
            .compactMap { $0 }.joined(separator: "|")
    }

    private static func playbackSource(for stream: StremioStream, url: URL) -> PlaybackSource {
        PlaybackSource(url: url, headers: stream.behaviorHints?.proxyHeaders?.request ?? [:],
                       subtitles: [], preferredPeakBitRate: nil)
    }

    private static func playableFormat(for stream: StremioStream, url: URL) -> String? {
        let description = stream.description ?? ""
        let declared = capture(#"(?i)(?:^|[•\s])(HLS|MP4|M4V|MOV|MKV|AVI|WEBM|ZIP|ISO)(?:$|[•\s])"#,
                               in: description)?.lowercased()
        if let declared { return ["hls", "mp4", "m4v", "mov"].contains(declared) ? declared : nil }
        let ext = url.pathExtension.lowercased()
        if ["m3u8", "mp4", "m4v", "mov"].contains(ext) { return ext == "m3u8" ? "hls" : ext }
        let filename = stream.behaviorHints?.filename?.lowercased() ?? ""
        if [".mkv", ".avi", ".webm", ".zip", ".iso"].contains(where: filename.contains) { return nil }
        return nil
    }

    fileprivate static func capture(_ pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }

    fileprivate static func languageCode(_ value: String?) -> String? {
        guard let value else { return nil }
        let key = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return ["english": "en", "japanese": "ja", "hebrew": "he", "hindi": "hi", "tamil": "ta",
                "telugu": "te", "korean": "ko", "chinese": "zh", "spanish": "es", "french": "fr",
                "german": "de", "italian": "it", "portuguese": "pt", "russian": "ru", "arabic": "ar"][key]
    }
}

private actor RefreshingStremioSource {
    private var initial: PlaybackSource?
    private let refresh: @Sendable () async throws -> PlaybackSource

    init(initial: PlaybackSource, refresh: @escaping @Sendable () async throws -> PlaybackSource) {
        self.initial = initial
        self.refresh = refresh
    }

    func resolve() async throws -> PlaybackSource {
        if let initial {
            self.initial = nil
            return initial
        }
        return try await refresh()
    }
}

struct StremioSubtitleProvider: SubtitleProvider {
    let id = "external-stream-subtitles"
    let displayName = "External"
    private let addon: StremioAddonClient

    init(client: any HTTPClientProtocol = HTTPClient(), baseURL: URL? = StremioAddonConfiguration.baseURL) {
        addon = StremioAddonClient(client: client, baseURL: baseURL)
    }

    func subtitles(for request: SubtitleLookupRequest) async throws -> [SubtitleSource] {
        let entries = try await addon.subtitles(for: request)
        var seen = Set<String>()
        return entries.compactMap { entry in
            guard let url = entry.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            let provider = Self.origin(for: entry)
            let language = Self.language(for: entry.lang)
            let entryIdentity = entry.id.flatMap { raw in
                URL(string: raw).flatMap { $0.scheme == nil ? nil : $0.deletingQuery().absoluteString } ?? raw
            } ?? url.deletingQuery().absoluteString
            let stableID = "\(id):\(provider.lowercased()):\(entryIdentity)"
            guard seen.insert(stableID).inserted else { return nil }
            return SubtitleSource(id: stableID, providerID: id, providerName: provider,
                                  label: SubtitleLanguage.displayName(language),
                                  languageCode: language, url: url)
        }
    }

    private static func origin(for entry: StremioSubtitle) -> String {
        if let raw = entry.id?.split(separator: "-").first, !raw.contains("://") {
            let value = String(raw).lowercased()
            if value == "moviebox" { return "MovieBox" }
        }
        return "External"
    }

    private static func language(for raw: String?) -> String {
        SubtitleLanguage.canonicalCode(raw) ?? "und"
    }
}

private extension URL {
    func deletingQuery() -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return components?.url ?? self
    }
}
