import Foundation
import CoreFoundation
import OSLog

enum SubtitleDiagnostics {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "BetterStreamflix",
        category: "Subtitles"
    )
}

struct SubtitleLookupRequest: Hashable, Sendable {
    let kind: MediaKind
    let imdbID: String
    let seasonNumber: Int?
    let episodeNumber: Int?
}

protocol SubtitleProvider: Sendable {
    var id: String { get }
    var displayName: String { get }

    func subtitles(for request: SubtitleLookupRequest) async throws -> [SubtitleSource]
}

protocol IMDbIDResolving: Sendable {
    func imdbID(forTMDbID tmdbID: Int, kind: MediaKind) async throws -> String?
}

actor WikidataIMDbIDResolver: IMDbIDResolving {
    private struct CacheKey: Hashable {
        let tmdbID: Int
        let kind: MediaKind
    }

    private struct Response: Decodable {
        let results: Results

        struct Results: Decodable {
            let bindings: [Binding]
        }

        struct Binding: Decodable {
            let imdb: Value?
        }

        struct Value: Decodable {
            let value: String
        }
    }

    private let client: any HTTPClientProtocol
    private let baseURL: URL
    private let userDefaults: UserDefaults?
    private var attempted = Set<CacheKey>()
    private var resolvedIDs: [CacheKey: String] = [:]

    init(
        client: any HTTPClientProtocol = HTTPClient(),
        baseURL: URL = URL(string: "https://query.wikidata.org/sparql")!,
        userDefaults: UserDefaults? = .standard
    ) {
        self.client = client
        self.baseURL = baseURL
        self.userDefaults = userDefaults
    }

    func imdbID(forTMDbID tmdbID: Int, kind: MediaKind) async throws -> String? {
        let key = CacheKey(tmdbID: tmdbID, kind: kind)
        if attempted.contains(key) { return resolvedIDs[key] }

        let defaultsKey = "subtitle.imdb-fallback.\(kind.rawValue).\(tmdbID)"
        if let cached = userDefaults?.string(forKey: defaultsKey), Self.isValidIMDbID(cached) {
            attempted.insert(key)
            resolvedIDs[key] = cached
            SubtitleDiagnostics.logger.info(
                "IMDb fallback cache hit: tmdb=\(tmdbID) kind=\(kind.rawValue, privacy: .public) imdb=\(cached, privacy: .public)"
            )
            return cached
        }

        let tmdbProperty = kind == .movie ? "P4947" : "P4983"
        let sparql = "SELECT ?imdb WHERE { ?item wdt:\(tmdbProperty) \"\(tmdbID)\"; wdt:P345 ?imdb. } LIMIT 2"
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "query", value: sparql),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components?.url else { throw AppError.invalidURL }

        SubtitleDiagnostics.logger.info(
            "Resolving IMDb fallback: tmdb=\(tmdbID) kind=\(kind.rawValue, privacy: .public)"
        )
        var request = URLRequest(url: url)
        request.setValue("application/sparql-results+json", forHTTPHeaderField: "Accept")
        request.setValue("BetterStreamflix-iOS/1.0 subtitle-metadata-resolver", forHTTPHeaderField: "User-Agent")
        let response = try await client.data(for: request)
        let payload: Response
        do {
            payload = try JSONDecoder().decode(Response.self, from: response.data)
        } catch {
            throw AppError.decoding("Wikidata IMDb lookup response")
        }

        attempted.insert(key)
        guard let imdbID = payload.results.bindings.compactMap(\.imdb?.value).first(where: Self.isValidIMDbID) else {
            SubtitleDiagnostics.logger.info("IMDb fallback returned no match: tmdb=\(tmdbID)")
            return nil
        }
        resolvedIDs[key] = imdbID
        userDefaults?.set(imdbID, forKey: defaultsKey)
        SubtitleDiagnostics.logger.info(
            "IMDb fallback resolved: tmdb=\(tmdbID) imdb=\(imdbID, privacy: .public)"
        )
        return imdbID
    }

    private static func isValidIMDbID(_ value: String) -> Bool {
        value.range(of: #"^tt\d{7,9}$"#, options: .regularExpression) != nil
    }
}

actor SubtitleProviderRegistry {
    private var providers: [String: any SubtitleProvider]
    private let imdbIDResolver: any IMDbIDResolving

    init(
        providers: [any SubtitleProvider],
        imdbIDResolver: any IMDbIDResolving = WikidataIMDbIDResolver()
    ) {
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        self.imdbIDResolver = imdbIDResolver
    }

    func register(_ provider: any SubtitleProvider) {
        providers[provider.id] = provider
    }

    func subtitles(
        for request: SubtitleLookupRequest,
        fallbackTMDbID: Int? = nil,
        enabledProviderIDs: Set<String>
    ) async -> [SubtitleSource] {
        let enabled = providers.values.filter { enabledProviderIDs.contains($0.id) }
        let initialResults = await queryProviders(enabled, for: request)
        guard initialResults.isEmpty, !enabled.isEmpty, let fallbackTMDbID else {
            SubtitleDiagnostics.logger.info("Subtitle lookup finished: totalResults=\(initialResults.count)")
            return initialResults
        }

        do {
            guard let resolvedIMDbID = try await imdbIDResolver.imdbID(
                forTMDbID: fallbackTMDbID,
                kind: request.kind
            ) else {
                SubtitleDiagnostics.logger.info("Subtitle lookup finished: fallback unavailable, totalResults=0")
                return []
            }
            guard resolvedIMDbID != request.imdbID else {
                SubtitleDiagnostics.logger.info(
                    "Subtitle fallback matched original IMDb ID; retry skipped: imdb=\(resolvedIMDbID, privacy: .public)"
                )
                return []
            }

            SubtitleDiagnostics.logger.notice(
                "Retrying subtitle lookup with corrected IMDb ID: original=\(request.imdbID, privacy: .public) corrected=\(resolvedIMDbID, privacy: .public) tmdb=\(fallbackTMDbID)"
            )
            let correctedRequest = SubtitleLookupRequest(
                kind: request.kind,
                imdbID: resolvedIMDbID,
                seasonNumber: request.seasonNumber,
                episodeNumber: request.episodeNumber
            )
            let fallbackResults = await queryProviders(enabled, for: correctedRequest)
            SubtitleDiagnostics.logger.info(
                "Subtitle lookup finished after IMDb fallback: totalResults=\(fallbackResults.count)"
            )
            return fallbackResults
        } catch where error.isCancellation {
            return []
        } catch {
            SubtitleDiagnostics.logger.error(
                "Subtitle IMDb fallback failed: tmdb=\(fallbackTMDbID) error=\(String(describing: error), privacy: .public)"
            )
            return []
        }
    }

    private func queryProviders(
        _ enabled: [any SubtitleProvider],
        for request: SubtitleLookupRequest
    ) async -> [SubtitleSource] {
        let season = request.seasonNumber.map(String.init) ?? "none"
        let episode = request.episodeNumber.map(String.init) ?? "none"
        let providerNames = enabled.map(\.displayName).sorted().joined(separator: ", ")
        SubtitleDiagnostics.logger.info(
            "Subtitle lookup started: imdb=\(request.imdbID, privacy: .public) kind=\(request.kind.rawValue, privacy: .public) season=\(season, privacy: .public) episode=\(episode, privacy: .public) providers=[\(providerNames, privacy: .public)]"
        )

        let results = await withTaskGroup(of: [SubtitleSource].self) { group in
            for provider in enabled {
                group.addTask {
                    do {
                        SubtitleDiagnostics.logger.debug(
                            "Querying subtitle provider: \(provider.displayName, privacy: .public)"
                        )
                        let subtitles = try await provider.subtitles(for: request)
                        SubtitleDiagnostics.logger.info(
                            "Subtitle provider completed: provider=\(provider.displayName, privacy: .public) results=\(subtitles.count)"
                        )
                        return subtitles
                    } catch where error.isCancellation {
                        SubtitleDiagnostics.logger.debug(
                            "Subtitle provider cancelled: \(provider.displayName, privacy: .public)"
                        )
                        return []
                    } catch {
                        // Third-party subtitle failures must never prevent playback.
                        SubtitleDiagnostics.logger.error(
                            "Subtitle provider failed: provider=\(provider.displayName, privacy: .public) error=\(String(describing: error), privacy: .public)"
                        )
                        return []
                    }
                }
            }

            var results: [SubtitleSource] = []
            for await subtitles in group { results.append(contentsOf: subtitles) }
            return results.sorted {
                if $0.providerName != $1.providerName { return $0.providerName < $1.providerName }
                return $0.label.localizedStandardCompare($1.label) == .orderedAscending
            }
        }
        return results
    }
}

struct WizdomSubtitleProvider: SubtitleProvider {
    let id = "wizdom"
    let displayName = "Wizdom"

    private let client: any HTTPClientProtocol
    private let baseURL: URL

    init(
        client: any HTTPClientProtocol = HTTPClient(),
        baseURL: URL = URL(string: "https://4b139a4b7f94-wizdom-stremio-v2.baby-beamup.club/")!
    ) {
        self.client = client
        self.baseURL = baseURL
    }

    func subtitles(for request: SubtitleLookupRequest) async throws -> [SubtitleSource] {
        let contentID: String
        switch request.kind {
        case .movie:
            contentID = request.imdbID
        case .series:
            guard let season = request.seasonNumber, let episode = request.episodeNumber else {
                SubtitleDiagnostics.logger.error("Wizdom lookup skipped: missing season or episode number")
                return []
            }
            contentID = "\(request.imdbID):\(season):\(episode)"
        }

        let type = request.kind == .movie ? "movie" : "series"
        let url = baseURL
            .appending(path: "subtitles")
            .appending(path: type)
            .appending(path: "\(contentID).json")
        SubtitleDiagnostics.logger.debug(
            "Wizdom subtitle request: \(url.absoluteString, privacy: .public)"
        )
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(HTTPClient.desktopUserAgent, forHTTPHeaderField: "User-Agent")

        let response = try await client.data(for: urlRequest)
        SubtitleDiagnostics.logger.debug(
            "Wizdom subtitle response: status=\(response.response.statusCode) bytes=\(response.data.count)"
        )
        let payload: Response
        do {
            payload = try JSONDecoder().decode(Response.self, from: response.data)
        } catch {
            throw AppError.decoding("Wizdom subtitle response")
        }
        let subtitles: [SubtitleSource] = payload.subtitles.compactMap { subtitle in
            guard let url = URL(string: subtitle.url) else { return nil }
            return SubtitleSource(
                id: "\(id):\(subtitle.id):\(url.lastPathComponent)",
                providerID: id,
                providerName: displayName,
                label: subtitle.displayName,
                languageCode: Self.normalizedLanguageCode(subtitle.lang),
                url: url
            )
        }
        SubtitleDiagnostics.logger.debug(
            "Wizdom subtitle response decoded: raw=\(payload.subtitles.count) usable=\(subtitles.count)"
        )
        return subtitles
    }

    private struct Response: Decodable, Sendable {
        let subtitles: [Subtitle]
    }

    private struct Subtitle: Decodable, Sendable {
        let id: String
        let lang: String
        let url: String

        var displayName: String {
            let withoutPrefix = id.replacingOccurrences(of: #"^\[WIZDOM\]"#, with: "", options: .regularExpression)
            return withoutPrefix.trimmingCharacters(in: CharacterSet(charactersIn: " .:"))
        }
    }

    private static func normalizedLanguageCode(_ code: String) -> String {
        switch code.lowercased() {
        case "heb", "iw": "he"
        case "eng": "en"
        default: code.lowercased()
        }
    }
}

struct KtuvitSubtitleProvider: SubtitleProvider {
    let id = "ktuvit"
    let displayName = "Ktuvit"

    private let client: any HTTPClientProtocol
    private let baseURL: URL

    init(
        client: any HTTPClientProtocol = HTTPClient(),
        baseURL: URL = URL(string: "https://4b139a4b7f94-ktuvit-stremio.baby-beamup.club/")!
    ) {
        self.client = client
        self.baseURL = baseURL
    }

    func subtitles(for request: SubtitleLookupRequest) async throws -> [SubtitleSource] {
        let contentID: String
        switch request.kind {
        case .movie:
            contentID = request.imdbID
        case .series:
            guard let season = request.seasonNumber, let episode = request.episodeNumber else {
                SubtitleDiagnostics.logger.error("Ktuvit lookup skipped: missing season or episode number")
                return []
            }
            contentID = "\(request.imdbID):\(season):\(episode)"
        }

        let type = request.kind == .movie ? "movie" : "series"
        let url = baseURL
            .appending(path: "subtitles")
            .appending(path: type)
            .appending(path: "\(contentID).json")
        SubtitleDiagnostics.logger.debug(
            "Ktuvit subtitle request: \(url.absoluteString, privacy: .public)"
        )
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(HTTPClient.desktopUserAgent, forHTTPHeaderField: "User-Agent")

        let response = try await client.data(for: urlRequest)
        SubtitleDiagnostics.logger.debug(
            "Ktuvit subtitle response: status=\(response.response.statusCode) bytes=\(response.data.count)"
        )
        let payload: Response
        do {
            payload = try JSONDecoder().decode(Response.self, from: response.data)
        } catch {
            throw AppError.decoding("Ktuvit subtitle response")
        }
        let subtitles: [SubtitleSource] = payload.subtitles.compactMap { subtitle in
            guard let url = URL(string: subtitle.url) else { return nil }
            return SubtitleSource(
                id: "\(id):\(subtitle.id):\(url.lastPathComponent)",
                providerID: id,
                providerName: displayName,
                label: subtitle.displayName,
                languageCode: Self.normalizedLanguageCode(subtitle.lang),
                url: url
            )
        }
        SubtitleDiagnostics.logger.debug(
            "Ktuvit subtitle response decoded: raw=\(payload.subtitles.count) usable=\(subtitles.count)"
        )
        return subtitles
    }

    private struct Response: Decodable, Sendable {
        let subtitles: [Subtitle]
    }

    private struct Subtitle: Decodable, Sendable {
        let id: String
        let lang: String
        let url: String

        var displayName: String {
            let withoutPrefix = id.replacingOccurrences(of: #"^\[KTUVIT\]"#, with: "", options: .regularExpression)
            return withoutPrefix.trimmingCharacters(in: CharacterSet(charactersIn: " .:"))
        }
    }

    private static func normalizedLanguageCode(_ code: String) -> String {
        switch code.lowercased() {
        case "heb", "iw": "he"
        case "eng": "en"
        default: code.lowercased()
        }
    }
}

extension PlaybackRequest {
    var subtitleLookupRequest: SubtitleLookupRequest? {
        guard let imdbID = media.imdbID,
              imdbID.range(of: #"^tt\d{7,9}$"#, options: .regularExpression) != nil else { return nil }
        return SubtitleLookupRequest(
            kind: media.kind,
            imdbID: imdbID,
            seasonNumber: episode?.seasonNumber,
            episodeNumber: episode?.number
        )
    }
}

struct SubtitleCue: Hashable, Sendable {
    let startTime: Double
    let endTime: Double
    let text: String

    func shifted(by offset: Double) -> SubtitleCue {
        let shiftedStart = max(0, startTime + offset)
        let shiftedEnd = max(shiftedStart + 0.001, endTime + offset)
        return SubtitleCue(startTime: shiftedStart, endTime: shiftedEnd, text: text)
    }
}

enum SubtitleDirectionFormatter {
    private static let rightToLeftMark = "\u{200F}"

    static func displayText(_ text: String, languageCode: String?) -> String {
        guard isHebrew(languageCode: languageCode) || containsHebrew(text) else { return text }
        return text.components(separatedBy: "\n").map { line in
            guard containsHebrew(line) else { return line }
            return "\(rightToLeftMark)\(line)\(rightToLeftMark)"
        }.joined(separator: "\n")
    }

    static func usesRightToLeftLayout(_ text: String, languageCode: String?) -> Bool {
        isHebrew(languageCode: languageCode) || containsHebrew(text)
    }

    private static func isHebrew(languageCode: String?) -> Bool {
        guard let language = languageCode?
            .lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first else { return false }
        return language == "he" || language == "heb" || language == "iw"
    }

    private static func containsHebrew(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x0590...0x05FF).contains(scalar.value) ||
                (0xFB1D...0xFB4F).contains(scalar.value)
        }
    }
}

enum SubtitleParser {
    static func cues(from data: Data) throws -> [SubtitleCue] {
        guard let decoded = decode(data) else { throw AppError.decoding("Subtitle text encoding") }
        let normalized = decoded
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: #"\n[\t ]*\n"#, with: "\n\n", options: .regularExpression)
        let cues = normalized.components(separatedBy: "\n\n").compactMap(parseBlock)
        guard !cues.isEmpty else { throw AppError.decoding("Subtitle cues") }
        return cues.sorted {
            $0.startTime == $1.startTime ? $0.endTime < $1.endTime : $0.startTime < $1.startTime
        }
    }

    private static func decode(_ data: Data) -> String? {
        if let value = String(data: data, encoding: .utf8) { return value }
        if let value = String(data: data, encoding: .utf16) { return value }
        // Core Foundation's Windows Hebrew (code page 1255) identifier.
        let windowsHebrew = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(0x0505)
        ))
        if let value = String(data: data, encoding: windowsHebrew) { return value }
        if let value = String(data: data, encoding: .windowsCP1252) { return value }
        return String(data: data, encoding: .isoLatin1)
    }

    private static func parseBlock(_ block: String) -> SubtitleCue? {
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
        let timing = lines[timingIndex].components(separatedBy: "-->")
        guard timing.count == 2,
              let start = timestamp(timing[0]),
              let end = timestamp(timing[1]) else { return nil }
        let text = lines.dropFirst(timingIndex + 1)
            .joined(separator: "\n")
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\{\\[^}]+\}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&lrm;", with: "")
            .replacingOccurrences(of: "&rlm;", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard end > start, !text.isEmpty else { return nil }
        return SubtitleCue(startTime: start, endTime: end, text: text)
    }

    private static func timestamp(_ value: String) -> Double? {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").first.map(String.init) ?? ""
        let components = token.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard components.count == 2 || components.count == 3 else { return nil }
        let seconds = components.last.flatMap { Double($0) }
        let minutes = Double(components[components.count - 2])
        let hours = components.count == 3 ? Double(components[0]) : 0
        guard let seconds, let minutes, let hours else { return nil }
        return hours * 3_600 + minutes * 60 + seconds
    }
}

struct InjectedHLSSubtitleAsset: Sendable {
    let masterPlaylistURL: URL
    let workingDirectory: URL
    let displayNames: Set<String>
}

struct HLSSubtitleRendition: Sendable {
    let subtitle: SubtitleSource
    let cues: [SubtitleCue]
}

struct HLSSubtitleManifestRendition: Sendable {
    let playlistURL: URL
    let subtitle: SubtitleSource
    let displayName: String
}

enum HLSSubtitleInjector {
    private static let externalGroupID = "betterstreamflix-external-subtitles"

    static func prepare(
        source: PlaybackSource,
        renditions: [HLSSubtitleRendition],
        timingOffset: Double = 0,
        selectedQualityHeight: Int? = nil,
        client: any HTTPClientProtocol
    ) async throws -> InjectedHLSSubtitleAsset {
        var request = URLRequest(url: source.url)
        request.setValue("application/vnd.apple.mpegurl,application/x-mpegURL,*/*;q=0.8", forHTTPHeaderField: "Accept")
        for (name, value) in source.headers { request.setValue(value, forHTTPHeaderField: name) }
        let response = try await client.data(for: request)
        try Task.checkCancellation()
        guard let playlist = String(data: response.data, encoding: .utf8),
              playlist.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else {
            throw AppError.decoding("HLS playlist")
        }

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appending(path: "BetterStreamflix-HLS-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let masterURL = directory.appending(path: "master.m3u8")
            let subtitlePlaylistURLs = renditions.indices.map {
                directory.appending(path: "external-subtitles-\($0).m3u8")
            }
            let displayNames = uniqueDisplayNames(for: renditions.map(\.subtitle))
            let manifestRenditions = renditions.indices.map { index in
                HLSSubtitleManifestRendition(
                    playlistURL: subtitlePlaylistURLs[index],
                    subtitle: renditions[index].subtitle,
                    displayName: displayNames[index]
                )
            }
            let sourceURL = response.response.url ?? source.url
            let master = rewrittenMasterPlaylist(
                playlist,
                sourceURL: sourceURL,
                renditions: manifestRenditions,
                preferredPeakBitRate: source.preferredPeakBitRate,
                selectedQualityHeight: selectedQualityHeight
            )
            try Data(master.utf8).write(to: masterURL, options: .atomic)
            for (index, rendition) in renditions.enumerated() {
                let webVTTURL = directory.appending(path: "external-subtitles-\(index).vtt")
                let adjustedCues = rendition.cues.map { $0.shifted(by: timingOffset) }
                let subtitlePlaylist = subtitleMediaPlaylist(
                    cues: adjustedCues,
                    webVTTURL: webVTTURL
                )
                let webVTT = webVTT(
                    cues: adjustedCues,
                    languageCode: rendition.subtitle.languageCode
                )
                try Data(subtitlePlaylist.utf8).write(
                    to: subtitlePlaylistURLs[index],
                    options: .atomic
                )
                try Data(webVTT.utf8).write(to: webVTTURL, options: .atomic)
            }
            return InjectedHLSSubtitleAsset(
                masterPlaylistURL: masterURL,
                workingDirectory: directory,
                displayNames: Set(displayNames)
            )
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    static func rewrittenMasterPlaylist(
        _ playlist: String,
        sourceURL: URL,
        renditions: [HLSSubtitleManifestRendition],
        preferredPeakBitRate: Double? = nil,
        selectedQualityHeight: Int? = nil
    ) -> String {
        let qualityFilteredPlaylist = selectedQualityHeight.map {
            HLSMasterPlaylistParser.playlist(
                playlist,
                filteredToHeight: $0
            )
        } ?? playlist
        let lines = qualityFilteredPlaylist.components(separatedBy: .newlines)
        let isMasterPlaylist = lines.contains { $0.hasPrefix("#EXT-X-STREAM-INF:") }

        guard isMasterPlaylist else {
            let bandwidth = max(1, Int(preferredPeakBitRate ?? 10_000_000))
            let mediaTags = renditions.enumerated().map { index, rendition in
                subtitleMediaTag(
                    groupID: externalGroupID,
                    name: rendition.displayName,
                    language: uniqueLanguageTag(
                        for: rendition.subtitle.languageCode,
                        renditionIndex: index
                    ),
                    uri: rendition.playlistURL.absoluteString
                )
            }
            return """
            #EXTM3U
            #EXT-X-VERSION:5
            \(mediaTags.joined(separator: "\n"))
            #EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth),SUBTITLES=\"\(externalGroupID)\"
            \(sourceURL.absoluteString)

            """
        }

        let referencedGroups = Set(lines.compactMap { subtitleGroupID(in: $0) })
        let groups = referencedGroups.isEmpty ? [externalGroupID] : referencedGroups.sorted()
        let generatedMediaTags = groups.flatMap { groupID in
            renditions.enumerated().map { index, rendition in
                subtitleMediaTag(
                    groupID: groupID,
                    name: rendition.displayName,
                    language: uniqueLanguageTag(
                        for: rendition.subtitle.languageCode,
                        renditionIndex: index
                    ),
                    uri: rendition.playlistURL.absoluteString
                )
            }
        }
        let sortedSubtitleMediaTags = (
            lines
                .filter(isSubtitleMediaTag)
                .map { absolutizingURIAttributes(in: $0, relativeTo: sourceURL) }
                + generatedMediaTags
        ).sorted(by: subtitleMediaTagOrder)

        var output: [String] = []
        var insertedMediaTags = false
        for originalLine in lines {
            if isSubtitleMediaTag(originalLine) { continue }
            var line = absolutizingURIAttributes(in: originalLine, relativeTo: sourceURL)
            if line.hasPrefix("#EXT-X-STREAM-INF:"), subtitleGroupID(in: line) == nil {
                line += ",SUBTITLES=\"\(externalGroupID)\""
            } else if !line.isEmpty, !line.hasPrefix("#") {
                line = absoluteURLString(line, relativeTo: sourceURL)
            }
            output.append(line)
            if !insertedMediaTags, line == "#EXTM3U" {
                output.append(contentsOf: sortedSubtitleMediaTags)
                insertedMediaTags = true
            }
        }
        if !insertedMediaTags { output.insert(contentsOf: sortedSubtitleMediaTags, at: 0) }
        return output.joined(separator: "\n")
    }

    static func subtitleMediaPlaylist(cues: [SubtitleCue], webVTTURL: URL) -> String {
        let duration = max(1, cues.map(\.endTime).max() ?? 1)
        return """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:\(Int(ceil(duration)))
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:\(String(format: "%.3f", duration)),
        \(webVTTURL.absoluteString)
        #EXT-X-ENDLIST

        """
    }

    static func webVTT(cues: [SubtitleCue], languageCode: String?) -> String {
        let blocks = cues.enumerated().map { index, cue in
            let text = SubtitleDirectionFormatter
                .displayText(cue.text, languageCode: languageCode)
                .replacingOccurrences(of: "\n\n", with: "\n")
            return """
            \(index + 1)
            \(timestamp(cue.startTime)) --> \(timestamp(cue.endTime))
            \(text)
            """
        }
        return (["WEBVTT"] + blocks).joined(separator: "\n\n") + "\n"
    }

    static func displayName(for subtitle: SubtitleSource) -> String {
        let code = subtitle.languageCode ?? "und"
        let language = Locale(identifier: "en_US").localizedString(forLanguageCode: code)
            ?? code.uppercased()
        return "\(language) - \(subtitle.providerName) - \(subtitle.label)"
    }

    private static func uniqueDisplayNames(for subtitles: [SubtitleSource]) -> [String] {
        var occurrences: [String: Int] = [:]
        return subtitles.map { subtitle in
            let baseName = displayName(for: subtitle)
            let occurrence = occurrences[baseName, default: 0] + 1
            occurrences[baseName] = occurrence
            return occurrence == 1 ? baseName : "\(baseName) (\(occurrence))"
        }
    }

    private static func uniqueLanguageTag(
        for languageCode: String?,
        renditionIndex: Int
    ) -> String {
        let suppliedBase = languageCode?
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first
            .map(String.init) ?? "und"
        let base: String
        switch suppliedBase {
        case "heb", "iw": base = "he"
        case "eng": base = "en"
        default: base = suppliedBase.allSatisfy(\.isLetter) ? suppliedBase : "und"
        }
        return "\(base)-x-bsf-\(renditionIndex + 1)"
    }

    private static func subtitleMediaTag(
        groupID: String,
        name: String,
        language: String,
        uri: String
    ) -> String {
        "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"\(escapedAttribute(groupID))\"," +
            "NAME=\"\(escapedAttribute(name))\",LANGUAGE=\"\(escapedAttribute(language))\"," +
            "AUTOSELECT=NO,DEFAULT=NO,FORCED=NO,URI=\"\(uri)\""
    }

    private static func subtitleGroupID(in line: String) -> String? {
        capture(#"(?:^|,)SUBTITLES=\"([^\"]+)\""#, in: line)
    }

    private static func isSubtitleMediaTag(_ line: String) -> Bool {
        line.hasPrefix("#EXT-X-MEDIA:") && line.contains("TYPE=SUBTITLES")
    }

    private static func subtitleMediaTagOrder(_ left: String, _ right: String) -> Bool {
        let leftName = capture(#"(?:^|,)NAME=\"([^\"]+)\""#, in: left) ?? left
        let rightName = capture(#"(?:^|,)NAME=\"([^\"]+)\""#, in: right) ?? right
        let comparison = leftName.localizedCaseInsensitiveCompare(rightName)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return left < right
    }

    private static func absolutizingURIAttributes(in line: String, relativeTo baseURL: URL) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"URI=\"([^\"]+)\""#) else { return line }
        let range = NSRange(line.startIndex..., in: line)
        let matches = regex.matches(in: line, range: range).reversed()
        var result = line
        for match in matches {
            guard let valueRange = Range(match.range(at: 1), in: result) else { continue }
            let absolute = absoluteURLString(String(result[valueRange]), relativeTo: baseURL)
            result.replaceSubrange(valueRange, with: absolute)
        }
        return result
    }

    private static func absoluteURLString(_ value: String, relativeTo baseURL: URL) -> String {
        URL(string: value, relativeTo: baseURL)?.absoluteURL.absoluteString ?? value
    }

    private static func capture(_ pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }

    private static func escapedAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func timestamp(_ value: Double) -> String {
        let milliseconds = max(0, Int((value * 1_000).rounded()))
        let hours = milliseconds / 3_600_000
        let minutes = milliseconds / 60_000 % 60
        let seconds = milliseconds / 1_000 % 60
        let remainder = milliseconds % 1_000
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, remainder)
    }
}
