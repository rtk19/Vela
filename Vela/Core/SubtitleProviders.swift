import Foundation

enum SubtitleResourceRetry {
    static let maximumAttempts = 3

    static func load(
        request originalRequest: URLRequest,
        client: any HTTPClientProtocol
    ) async throws -> HTTPResponse {
        var lastError: (any Error)?
        for attempt in 0..<maximumAttempts {
            do {
                var request = originalRequest
                request.cachePolicy = .reloadIgnoringLocalCacheData
                return try await client.data(for: request)
            } catch where error.isCancellation {
                throw error
            } catch {
                lastError = error
                guard attempt < maximumAttempts - 1 else { break }
                try await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
            }
        }
        throw lastError ?? AppError.invalidResponse
    }
}
import CoreFoundation
import OSLog

enum SubtitleDiagnostics {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Vela",
        category: "Subtitles"
    )
}

struct SubtitleLookupRequest: Hashable, Sendable {
    let kind: MediaKind
    let imdbID: String
    let seasonNumber: Int?
    let episodeNumber: Int?
    var title: String? = nil
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
        request.setValue("Vela-iOS/1.0 subtitle-metadata-resolver", forHTTPHeaderField: "User-Agent")
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
        guard !enabled.isEmpty, let fallbackTMDbID else {
            SubtitleDiagnostics.logger.info("Subtitle lookup finished: totalResults=\(initialResults.count)")
            return initialResults
        }

        do {
            guard let resolvedIMDbID = try await imdbIDResolver.imdbID(
                forTMDbID: fallbackTMDbID,
                kind: request.kind
            ) else {
                SubtitleDiagnostics.logger.info(
                    "Subtitle lookup finished: fallback unavailable, totalResults=\(initialResults.count)"
                )
                return initialResults
            }
            guard resolvedIMDbID != request.imdbID else {
                SubtitleDiagnostics.logger.info(
                    "Subtitle fallback matched original IMDb ID; retry skipped: imdb=\(resolvedIMDbID, privacy: .public)"
                )
                return initialResults
            }

            SubtitleDiagnostics.logger.notice(
                "Retrying subtitle lookup with corrected IMDb ID: original=\(request.imdbID, privacy: .public) corrected=\(resolvedIMDbID, privacy: .public) tmdb=\(fallbackTMDbID)"
            )
            let correctedRequest = SubtitleLookupRequest(
                kind: request.kind,
                imdbID: resolvedIMDbID,
                seasonNumber: request.seasonNumber,
                episodeNumber: request.episodeNumber,
                title: request.title
            )
            let fallbackResults = await queryProviders(enabled, for: correctedRequest)
            var seenResources = Set<String>()
            let mergedResults = (initialResults + fallbackResults).filter { subtitle in
                seenResources.insert("\(subtitle.providerID):\(subtitle.url.absoluteString)").inserted
            }
            SubtitleDiagnostics.logger.info(
                "Subtitle lookup finished after IMDb fallback: totalResults=\(mergedResults.count)"
            )
            return mergedResults
        } catch where error.isCancellation {
            return initialResults
        } catch {
            SubtitleDiagnostics.logger.error(
                "Subtitle IMDb fallback failed: tmdb=\(fallbackTMDbID) error=\(String(describing: error), privacy: .public)"
            )
            return initialResults
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

struct SubDLSubtitleProvider: SubtitleProvider {
    let id = "subdl"
    let displayName = "SubDL"

    private let client: any HTTPClientProtocol
    private let baseURL: URL
    private let apiKey: String
    private let preferredLanguageCodes: @Sendable () -> [String]

    init(
        client: any HTTPClientProtocol = HTTPClient(),
        baseURL: URL = URL(string: "https://api.subdl.com/")!,
        apiKey: String? = Bundle.main.object(forInfoDictionaryKey: "SubDLAPIKey") as? String,
        preferredLanguageCodes: @escaping @Sendable () -> [String] = {
            let defaults = UserDefaults.standard
            return [
                defaults.string(forKey: "player.subtitleLanguage.primary"),
                defaults.string(forKey: "player.subtitleLanguage.secondary"),
            ].compactMap { $0 }
        }
    ) {
        self.client = client
        self.baseURL = baseURL
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.preferredLanguageCodes = preferredLanguageCodes
    }

    func subtitles(for lookup: SubtitleLookupRequest) async throws -> [SubtitleSource] {
        guard !apiKey.isEmpty else {
            SubtitleDiagnostics.logger.error("SubDL lookup skipped: missing API key")
            return []
        }
        if lookup.kind == .series,
           (lookup.seasonNumber == nil || lookup.episodeNumber == nil) {
            SubtitleDiagnostics.logger.error("SubDL lookup skipped: missing season or episode number")
            return []
        }

        var components = URLComponents(
            url: baseURL.appending(path: "api/v2/subtitles/search"),
            resolvingAgainstBaseURL: false
        )
        var queryItems = [
            URLQueryItem(name: "imdb_id", value: lookup.imdbID),
            URLQueryItem(name: "type", value: lookup.kind == .movie ? "movie" : "tv"),
            URLQueryItem(name: "unpack", value: "1"),
            URLQueryItem(name: "subs_per_page", value: "30"),
        ]
        if let season = lookup.seasonNumber, let episode = lookup.episodeNumber {
            queryItems.append(URLQueryItem(name: "season", value: String(season)))
            queryItems.append(URLQueryItem(name: "episode", value: String(episode)))
        }
        let languages = Self.normalizedLanguageCodes(preferredLanguageCodes())
        if !languages.isEmpty {
            queryItems.append(URLQueryItem(name: "languages", value: languages.joined(separator: ",")))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { throw AppError.invalidURL }

        var request = authenticatedRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await SubtitleResourceRetry.load(request: request, client: client)
        let payload: Response
        do {
            payload = try JSONDecoder().decode(Response.self, from: response.data)
        } catch {
            throw AppError.decoding("SubDL subtitle response")
        }
        guard payload.status != false else {
            SubtitleDiagnostics.logger.error("SubDL returned an unsuccessful response")
            return []
        }

        var seenIDs = Set<String>()
        return payload.subtitles.flatMap { subtitle in
            subtitle.unpackFiles.compactMap { file -> SubtitleSource? in
                guard Self.matches(file: file, lookup: lookup),
                      let url = resolvedDownloadURL(file.url) else { return nil }
                let stableID = "\(id):\(file.fileNID)"
                guard seenIDs.insert(stableID).inserted else { return nil }
                let language = SubtitleLanguage.canonicalCode(file.language ?? subtitle.language ?? subtitle.lang)
                let releaseName = file.releaseName ?? subtitle.releaseName
                let baseLabel = releaseName?.trimmingCharacters(in: .whitespacesAndNewlines)
                let fallbackLabel = file.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let label = (baseLabel.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackLabel)
                    + ((file.hi ?? subtitle.hi) == true ? " (SDH)" : "")
                return SubtitleSource(
                    id: stableID,
                    providerID: id,
                    providerName: displayName,
                    label: label,
                    languageCode: language,
                    url: url,
                    headers: ["Authorization": "Bearer \(apiKey)"]
                )
            }
        }
    }

    private func authenticatedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(HTTPClient.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private func resolvedDownloadURL(_ value: String) -> URL? {
        guard let unresolved = URL(string: value, relativeTo: baseURL)?.absoluteURL else { return nil }
        // SubDL still returns legacy api_key query parameters. Downloads also
        // support the Authorization header, so keep credentials out of URLs.
        guard var components = URLComponents(url: unresolved, resolvingAgainstBaseURL: false) else {
            return unresolved
        }
        components.queryItems = components.queryItems?.filter { $0.name != "api_key" }
        return components.url
    }

    private static func matches(file: UnpackedFile, lookup: SubtitleLookupRequest) -> Bool {
        guard lookup.kind == .series else { return true }
        guard let season = lookup.seasonNumber, let episode = lookup.episodeNumber else { return false }
        let fileSeason = file.season ?? season
        let fileEpisode = file.episode ?? episode
        return (fileSeason == 0 || fileSeason == season) && (fileEpisode == 0 || fileEpisode == episode)
    }

    private static func normalizedLanguageCodes(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            guard let code = SubtitleLanguage.canonicalCode(value), !code.isEmpty,
                  seen.insert(code).inserted else { return nil }
            return code
        }
    }

    private struct Response: Decodable, Sendable {
        let status: Bool?
        let subtitles: [Subtitle]

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try container.decodeIfPresent(Bool.self, forKey: .status)
            subtitles = try container.decodeIfPresent([Subtitle].self, forKey: .subtitles) ?? []
        }

        private enum CodingKeys: String, CodingKey { case status, subtitles }
    }

    private struct Subtitle: Decodable, Sendable {
        let releaseName: String?
        let lang: String?
        let language: String?
        let hi: Bool?
        let unpackFiles: [UnpackedFile]

        enum CodingKeys: String, CodingKey {
            case releaseName = "release_name"
            case lang, language, hi
            case unpackFiles = "unpack_files"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            releaseName = try container.decodeIfPresent(String.self, forKey: .releaseName)
            lang = try container.decodeIfPresent(String.self, forKey: .lang)
            language = try container.decodeIfPresent(String.self, forKey: .language)
            hi = try container.decodeIfPresent(Bool.self, forKey: .hi)
            unpackFiles = try container.decodeIfPresent([UnpackedFile].self, forKey: .unpackFiles) ?? []
        }
    }

    private struct UnpackedFile: Decodable, Sendable {
        let fileNID: String
        let name: String
        let releaseName: String?
        let season: Int?
        let episode: Int?
        let language: String?
        let hi: Bool?
        let url: String

        enum CodingKeys: String, CodingKey {
            case fileNID = "file_n_id"
            case name
            case releaseName = "release_name"
            case season, episode, language, hi, url
        }
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

        let response = try await SubtitleResourceRetry.load(request: urlRequest, client: client)
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
                languageCode: SubtitleLanguage.canonicalCode(subtitle.lang),
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
        do {
            let results = try await bridgeSubtitles(for: request)
            if !results.isEmpty { return results }
        } catch where error.isCancellation {
            throw error
        } catch {
            SubtitleDiagnostics.logger.error("Ktuvit bridge lookup failed; trying direct search")
        }
        return try await directSubtitles(for: request)
    }

    private func bridgeSubtitles(for request: SubtitleLookupRequest) async throws -> [SubtitleSource] {
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

        let response = try await SubtitleResourceRetry.load(request: urlRequest, client: client)
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
                languageCode: SubtitleLanguage.canonicalCode(subtitle.lang),
                url: url
            )
        }
        SubtitleDiagnostics.logger.debug(
            "Ktuvit subtitle response decoded: raw=\(payload.subtitles.count) usable=\(subtitles.count)"
        )
        return subtitles
    }

    private func directSubtitles(for lookup: SubtitleLookupRequest) async throws -> [SubtitleSource] {
        guard let title = lookup.title, !title.isEmpty else { return [] }
        let site = URL(string: "https://www.ktuvit.me/")!
        var request = URLRequest(url: site.appending(path: "Services/ContentProvider.svc/SearchPage_search"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["request": [
            "FilmName": title, "Actors": [], "Studios": NSNull(), "Directors": [],
            "Genres": [], "Countries": [], "Languages": [], "Year": "", "Rating": [],
            "Page": 1, "SearchType": lookup.kind == .movie ? "0" : "1", "WithSubsOnly": false,
        ]])
        let response = try await SubtitleResourceRetry.load(request: request, client: client)
        struct Envelope: Decodable { let d: String }
        struct Search: Decodable {
            let Films: [Film]
            struct Film: Decodable {
                let ID: String
                let EngName: String?
                let IMDB_Link: String?
                let ImdbID: String?
            }
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: response.data)
        let search = try JSONDecoder().decode(Search.self, from: Data(envelope.d.utf8))
        // Ktuvit's ImdbID field can truncate eight-digit IDs. Prefer the full link.
        // Some catalogs also expose that same truncated ID, so accept it only when
        // Ktuvit's English title is an exact normalized match. This avoids treating
        // a bare IMDb prefix or a similarly named series as the requested title.
        let normalizedLookupTitle = Self.normalizedTitle(title)
        guard let film = search.Films.first(where: {
            let linkedID = $0.IMDB_Link.flatMap { link in
                link.range(of: #"tt[0-9]+"#, options: .regularExpression).map { String(link[$0]) }
            }
            if linkedID == lookup.imdbID { return true }
            return $0.ImdbID == lookup.imdbID
                && $0.EngName.map(Self.normalizedTitle) == normalizedLookupTitle
        }) else { return [] }
        var components = URLComponents(url: site, resolvingAgainstBaseURL: false)!
        if lookup.kind == .series {
            guard let season = lookup.seasonNumber, let episode = lookup.episodeNumber else { return [] }
            components.path = "/Services/GetModuleAjax.ashx"
            components.queryItems = [
                URLQueryItem(name: "moduleName", value: "SubtitlesList"),
                URLQueryItem(name: "SeriesID", value: film.ID),
                URLQueryItem(name: "Season", value: String(season)),
                URLQueryItem(name: "Episode", value: String(episode)),
            ]
        } else {
            components.path = "/MovieInfo.aspx"
            components.queryItems = [URLQueryItem(name: "ID", value: film.ID)]
        }
        guard let url = components.url else { throw AppError.invalidURL }
        let page = try await SubtitleResourceRetry.load(request: URLRequest(url: url), client: client)
        guard let html = String(data: page.data, encoding: .utf8) else { throw AppError.decoding("Ktuvit subtitles") }
        let rows = try NSRegularExpression(pattern: #"(?is)<tr\b[^>]*>(.*?)</tr>"#)
        let identifier = try NSRegularExpression(pattern: #"data-subtitle-id=["']([^"']+)["']"#)
        let name = try NSRegularExpression(pattern: #"(?is)<div\b[^>]*>\s*(.*?)<br\s*/?>"#)
        func capture(_ regex: NSRegularExpression, _ value: String) -> String? {
            guard let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                  let range = Range(match.range(at: 1), in: value) else { return nil }
            return String(value[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return rows.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { row in
            guard let range = Range(row.range, in: html) else { return nil }
            let value = String(html[range])
            guard let subtitleID = capture(identifier, value), let label = capture(name, value) else { return nil }
            let url = baseURL.appending(path: "srt").appending(path: film.ID).appending(path: "\(subtitleID).srt")
            return SubtitleSource(id: "\(id):\(subtitleID)", providerID: id,
                                  providerName: displayName, label: label, languageCode: "he", url: url)
        }
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

    private static func normalizedTitle(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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
            episodeNumber: episode?.number,
            title: media.title
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
    // WebVTT determines each cue line's base direction from its first strong
    // directional character. AVPlayer does not consistently resolve neutral
    // punctuation inside an RLI/PDI wrapper, especially paired delimiters and
    // quotation marks. A leading RLM is the WebVTT-defined way to force an RTL
    // base direction while leaving the Unicode bidi algorithm free to resolve
    // numbers, embedded LTR runs, and punctuation in their logical order.
    private static let rightToLeftMark = "\u{200F}"

    private struct DirectionalCounts {
        var rightToLeft = 0
        var leftToRight = 0
    }

    private struct PunctuationLayoutScore {
        var legacy = 0
        var logical = 0

        var usesLegacyLayout: Bool {
            legacy >= 2 && legacy >= logical * 2
        }
    }

    static func displayText(_ text: String, languageCode: String?) -> String {
        let cue = SubtitleCue(startTime: 0, endTime: 1, text: text)
        return normalizedCues([cue], languageCode: languageCode).first?.text ?? text
    }

    static func normalizedCues(
        _ cues: [SubtitleCue],
        languageCode: String?
    ) -> [SubtitleCue] {
        let sanitizedCues = cues.map { cue in
            SubtitleCue(
                startTime: cue.startTime,
                endTime: cue.endTime,
                text: removingDirectionalControls(from: cue.text)
            )
        }
        let combinedText = sanitizedCues.map(\.text).joined(separator: "\n")
        guard usesRightToLeftLayout(combinedText, languageCode: languageCode) else {
            return cues
        }
        let repairsLegacyPunctuation = usesLegacyPunctuationLayout(sanitizedCues)
        let addsDirectionMark = sanitizedCues.contains { cue in
            cue.text.components(separatedBy: "\n").contains { line in
                shouldMarkRightToLeft(line)
            }
        }
        let removesDirectionalControls = sanitizedCues != cues
        guard repairsLegacyPunctuation || addsDirectionMark || removesDirectionalControls else {
            return cues
        }

        return sanitizedCues.map { cue in
            SubtitleCue(
                startTime: cue.startTime,
                endTime: cue.endTime,
                text: normalizedText(
                    cue.text,
                    repairsLegacyPunctuation: repairsLegacyPunctuation
                )
            )
        }
    }

    static func needsNormalization(
        _ cues: [SubtitleCue],
        languageCode: String?
    ) -> Bool {
        normalizedCues(cues, languageCode: languageCode) != cues
    }

    static func usesRightToLeftLayout(_ text: String, languageCode: String?) -> Bool {
        let counts = directionalCounts(in: text)
        let languageIsRightToLeft = isRightToLeft(languageCode: languageCode)

        if counts.rightToLeft == 0 {
            return languageIsRightToLeft && counts.leftToRight == 0 && !text.isEmpty
        }
        if languageIsRightToLeft {
            // Metadata is only a hint: require meaningful RTL content when the
            // file also contains LTR text so a mislabeled file is left alone.
            return counts.rightToLeft * 3 >= counts.leftToRight
        }
        return counts.rightToLeft > counts.leftToRight
    }

    private static func normalizedText(
        _ text: String,
        repairsLegacyPunctuation: Bool
    ) -> String {
        return text.components(separatedBy: "\n").map { line in
            let correctedLine = correctedLegacyPunctuation(
                in: line,
                repairsAmbiguousLeadingPunctuation: repairsLegacyPunctuation
            )
            guard shouldMarkRightToLeft(correctedLine) else {
                return correctedLine
            }
            return "\(rightToLeftMark)\(correctedLine)"
        }.joined(separator: "\n")
    }

    private static func usesLegacyPunctuationLayout(_ cues: [SubtitleCue]) -> Bool {
        let score = cues.reduce(into: PunctuationLayoutScore()) { total, cue in
            for line in cue.text.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard directionalCounts(in: trimmed).rightToLeft > 0 else { continue }

                let leadingDecoration = leadingVisualDecoration(in: trimmed)
                let leadingTerminal = leadingDecoration.filter(isTerminalPunctuation)
                let trailingTerminal = edgeToken(in: trimmed, fromStart: false, matching: isTerminalPunctuation)
                let leadingDialogueDash = edgeToken(in: trimmed, fromStart: true, matching: isDialogueDash)
                let trailingDialogueDash = trailingVisualDialogueRun(in: trimmed)
                let hasPairedDialogueBoundary = !leadingDialogueDash.isEmpty &&
                    !trailingDialogueDash.isEmpty
                let pairedBoundary = hasLegacyPairedBoundary(
                    leadingDecoration,
                    remainingText: String(trimmed.dropFirst(leadingDecoration.count))
                )

                if !leadingTerminal.isEmpty {
                    // A leading ellipsis is commonly intentional. It only
                    // contributes weak evidence unless the rest of the file
                    // also follows the legacy convention.
                    total.legacy += isOnlyEllipsis(leadingTerminal) ? 1 : 2
                }
                if leadingTerminal.isEmpty, pairedBoundary { total.legacy += 2 }
                if !trailingDialogueDash.isEmpty, !hasPairedDialogueBoundary {
                    total.legacy += 2
                }
                if !trailingTerminal.isEmpty { total.logical += 2 }
                if !leadingDialogueDash.isEmpty { total.logical += 2 }
            }
        }
        return score.usesLegacyLayout
    }

    private static func correctedLegacyPunctuation(
        in line: String,
        repairsAmbiguousLeadingPunctuation: Bool
    ) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard directionalCounts(in: trimmed).rightToLeft > 0 else { return line }
        // Dialogue/caption dashes form an outer boundary, not part of the
        // sentence decoration. Normalize inside them so a dash cannot hide a
        // displaced exclamation mark or quote from the same repair rules.
        let prefix = edgeToken(in: trimmed, fromStart: true) {
            isDialogueDash($0) || $0.isWhitespace
        }
        if prefix.contains(where: isDialogueDash), prefix.count < trimmed.count {
            let remainder = String(trimmed.dropFirst(prefix.count))
            let suffix = trailingVisualDialogueRun(in: remainder)
            let body = String(remainder.dropLast(suffix.count))
            let correctedBody = correctedLegacyPunctuation(
                in: body,
                repairsAmbiguousLeadingPunctuation: repairsAmbiguousLeadingPunctuation
            )
            return prefix + correctedBody + suffix
        }
        if let correctedQuotation = correctedTrailingOpeningQuote(in: trimmed) {
            return correctedQuotation
        }
        if let correctedQuotation = correctedEnclosingQuotation(in: trimmed) {
            return correctedQuotation
        }
        if let correctedOpening = correctedMirroredLeadingOpening(in: trimmed) {
            return correctedOpening
        }

        let quoteCorrected = correctedRotatedQuotationPair(in: trimmed) ?? trimmed

        let leadingDecoration = leadingVisualDecoration(in: quoteCorrected)
        let leadingTerminal = leadingDecoration.filter(isTerminalPunctuation)
        let undecoratedText = String(quoteCorrected.dropFirst(leadingDecoration.count))
            .trimmingCharacters(in: .whitespaces)
        let retainedOpeningLength = retainedOpeningDelimiterCount(
            in: leadingDecoration,
            remainingText: undecoratedText
        )
        let retainedOpening = String(leadingDecoration.suffix(retainedOpeningLength))
            .trimmingCharacters(in: .whitespaces)
        let displacedSuffix = String(leadingDecoration.dropLast(retainedOpeningLength))
            .trimmingCharacters(in: .whitespaces)
        let textWithOpening = "\(retainedOpening)\(undecoratedText)"
        let hasLeadingDialogueDash = !edgeToken(
            in: textWithOpening,
            fromStart: true,
            matching: isDialogueDash
        ).isEmpty
        // A dash at both boundaries is intentional paired punctuation (`- text -`).
        // It must not be mistaken for a legacy visual-order dialogue run and
        // collapsed into two dashes at the logical beginning of the line.
        let trailingDialogueDash = hasLeadingDialogueDash
            ? ""
            : trailingVisualDialogueRun(in: textWithOpening)
        let core = String(textWithOpening.dropLast(trailingDialogueDash.count))
            .trimmingCharacters(in: .whitespaces)

        let repairsPairedBoundary = hasLegacyPairedBoundary(
            leadingDecoration,
            remainingText: undecoratedText
        )
        let repairsLeadingTerminal = !leadingTerminal.isEmpty && (
            !isOnlyEllipsis(leadingTerminal) || repairsAmbiguousLeadingPunctuation
        )
        let repairsLeadingDecoration = repairsLeadingTerminal || repairsPairedBoundary

        guard repairsLeadingDecoration || !trailingDialogueDash.isEmpty else {
            return quoteCorrected == trimmed ? line : quoteCorrected
        }

        let dialoguePrefix = trailingDialogueDash.isEmpty
            ? ""
            : "\(String(trailingDialogueDash.reversed()).trimmingCharacters(in: .whitespaces)) "
        guard repairsLeadingDecoration else {
            let dialogueCore = String(quoteCorrected.dropLast(trailingDialogueDash.count))
                .trimmingCharacters(in: .whitespaces)
            guard !dialogueCore.isEmpty else { return line }
            return "\(dialoguePrefix)\(dialogueCore)"
        }

        guard !core.isEmpty else { return line }
        // Legacy visual-order subtitle files reverse the complete decoration
        // at the logical end of an RTL line. Opening delimiters which happen
        // to follow that decoration in the raw file must stay at the start.
        let logicalSuffix = String(displacedSuffix.reversed())
        return "\(dialoguePrefix)\(core)\(logicalSuffix)"
    }

    private static func correctedTrailingOpeningQuote(in text: String) -> String? {
        let terminal = edgeToken(in: text, fromStart: false, matching: isTerminalPunctuation)
        let body = String(text.dropLast(terminal.count))
        guard let quote = body.last, isAmbiguousQuotationMark(quote),
              body.first != quote,
              body.filter({ $0 == quote }).count == 2,
              let closingIndex = body.firstIndex(of: quote) else { return nil }
        let afterClosing = body.index(after: closingIndex)
        // A quote attached to the preceding word and followed by whitespace
        // closes that word. Its partner at the end is a displaced opener.
        guard closingIndex > body.startIndex,
              !body[body.index(before: closingIndex)].isWhitespace,
              body[afterClosing].isWhitespace else { return nil }
        let tail = String(body[afterClosing...].dropLast())
        guard directionalCounts(in: String(body[..<closingIndex])).rightToLeft > 0,
              directionalCounts(in: tail).rightToLeft > 0 else { return nil }
        return "\(quote)\(body.dropLast())\(terminal)"
    }

    private static func correctedEnclosingQuotation(in text: String) -> String? {
        let leading = leadingVisualDecoration(in: text)
        let quotes = leading.filter(isAmbiguousQuotationMark)
        let terminal = leading.filter(isTerminalPunctuation)
        let remainder = String(text.dropFirst(leading.count))
        // A quote before displaced sentence punctuation is still an opener
        // when its sole partner closes the body. The suffix-only boundary
        // scanner cannot retain it across the intervening period/comma.
        if let quote = quotes.first, quotes.count == 1, !terminal.isEmpty,
           leading.allSatisfy({ $0 == quote || isTerminalPunctuation($0) || $0.isWhitespace }),
           remainder.last == quote, remainder.filter({ $0 == quote }).count == 1 {
            return "\(quote)\(remainder)\(String(terminal.reversed()))"
        }

        // Also repair previously displaced openers: text + quote + punctuation
        // + quote. Require the entire quote pair to be in this terminal run;
        // ordinary inline quotes and punctuation inside valid quotes stay intact.
        let trailing = edgeToken(in: text, fromStart: false) {
            isAmbiguousQuotationMark($0) || isTerminalPunctuation($0)
        }
        guard let quote = trailing.first, isAmbiguousQuotationMark(quote),
              trailing.last == quote,
              text.filter({ $0 == quote }).count == 2 else { return nil }
        let punctuation = trailing.dropFirst().dropLast()
        guard !punctuation.isEmpty, punctuation.allSatisfy(isTerminalPunctuation) else { return nil }
        let body = String(text.dropLast(trailing.count))
        guard directionalCounts(in: body).rightToLeft > 0 else { return nil }
        return "\(quote)\(body)\(quote)\(punctuation)"
    }

    private static func correctedRotatedQuotationPair(in text: String) -> String? {
        let leadingBoundary = edgeToken(in: text, fromStart: true) { character in
            isDialogueDash(character) || character.isWhitespace
        }
        let trailingBoundary = trailingVisualDialogueRun(in: text)
        let hasPairedDialogueBoundary = leadingBoundary.contains(where: isDialogueDash) &&
            !trailingBoundary.isEmpty &&
            leadingBoundary.count + trailingBoundary.count < text.count

        let body: String
        if hasPairedDialogueBoundary {
            body = String(
                text
                    .dropFirst(leadingBoundary.count)
                    .dropLast(trailingBoundary.count)
            ).trimmingCharacters(in: .whitespaces)
        } else {
            body = text
        }

        guard let quotationMark = body.first,
              isAmbiguousQuotationMark(quotationMark),
              body.filter({ $0 == quotationMark }).count == 2 else {
            return nil
        }

        let afterLeadingQuote = body.dropFirst()
        guard let displacedOpeningIndex = afterLeadingQuote.firstIndex(of: quotationMark) else {
            return nil
        }
        // Only relocate a quote that opens the following phrase. A quote
        // attached to the preceding word (\"וודיו\" שק.) is already a closer.
        let followingIndex = afterLeadingQuote.index(after: displacedOpeningIndex)
        guard displacedOpeningIndex > afterLeadingQuote.startIndex,
              afterLeadingQuote[afterLeadingQuote.index(before: displacedOpeningIndex)].isWhitespace,
              followingIndex < afterLeadingQuote.endIndex,
              !afterLeadingQuote[followingIndex].isWhitespace else { return nil }
        let precedingText = String(afterLeadingQuote[..<displacedOpeningIndex])
            .trimmingCharacters(in: .whitespaces)
        let quotedTail = String(afterLeadingQuote[afterLeadingQuote.index(after: displacedOpeningIndex)...])
            .trimmingCharacters(in: .whitespaces)
        let terminalSuffix = edgeToken(
            in: quotedTail,
            fromStart: false,
            matching: isTerminalPunctuation
        )
        let quotedText = String(quotedTail.dropLast(terminalSuffix.count))
            .trimmingCharacters(in: .whitespaces)

        // In legacy visual-order files, the closing neutral quote may be stored
        // at the beginning of the RTL body while its matching opening quote is
        // left immediately before the final quoted phrase. Require meaningful
        // RTL text on both sides so correctly balanced quotations, apostrophes,
        // measurements, and LTR text are never rewritten.
        guard directionalCounts(in: precedingText).rightToLeft > 0,
              directionalCounts(in: quotedText).rightToLeft > 0 else {
            return nil
        }

        let correctedBody = "\(precedingText) \(quotationMark)\(quotedText)\(quotationMark)\(terminalSuffix)"
        guard hasPairedDialogueBoundary else { return correctedBody }
        return "\(leadingBoundary.trimmingCharacters(in: .whitespaces)) \(correctedBody) \(trailingBoundary.trimmingCharacters(in: .whitespaces))"
    }

    private static func correctedMirroredLeadingOpening(in text: String) -> String? {
        guard let first = text.first,
              let opening = mirroredOpeningDelimiter(for: first) else {
            return nil
        }
        let remainder = text.dropFirst()
        // `)(text` and `”“text` are complete legacy-reversed pairs handled by
        // the general boundary repair below. This path is only for a lone
        // mirrored opener whose matching glyph occurs later in the sentence.
        guard remainder.drop(while: { $0.isWhitespace }).first != opening else {
            return nil
        }
        // A lone closing glyph at the logical beginning can be a legacy visual
        // representation of an opening delimiter. Only correct it when the
        // remainder has an unmatched opener of the same kind; balanced text
        // and ordinary closing punctuation are left unchanged.
        let openingCount = remainder.filter { $0 == opening }.count
        let closingCount = remainder.filter { $0 == first }.count
        guard openingCount > closingCount else { return nil }
        return "\(opening)\(remainder)"
    }

    private static func mirroredOpeningDelimiter(for closing: Character) -> Character? {
        let pairs: [Character: Character] = [
            ")": "(", "]": "[", "}": "{",
            "）": "（", "］": "［", "｝": "｛",
            "〉": "〈", "》": "《", "」": "「", "』": "『",
            "】": "【", "〕": "〔", "〗": "〖", "〙": "〘", "〛": "〚",
            "⟩": "⟨", "⟫": "⟪", "⟭": "⟬", "⟯": "⟮",
            "❩": "❨", "❫": "❪", "❭": "❬", "❯": "❮", "❱": "❰",
            "❳": "❲", "❵": "❴",
            "»": "«", "›": "‹", "”": "“", "’": "‘",
        ]
        return pairs[closing]
    }

    private static func leadingVisualDecoration(in text: String) -> String {
        edgeToken(in: text, fromStart: true) { character in
            isTerminalPunctuation(character) ||
                isOpeningDelimiter(character) ||
                isClosingDelimiter(character) ||
                isAmbiguousQuotationMark(character) ||
                character.isWhitespace
        }
    }

    private static func trailingVisualDialogueRun(in text: String) -> String {
        let candidate = edgeToken(in: text, fromStart: false) { character in
            isDialogueDash(character) || character.isWhitespace
        }
        return candidate.contains(where: isDialogueDash) ? candidate : ""
    }

    private static func retainedOpeningDelimiterCount(
        in decoration: String,
        remainingText: String
    ) -> Int {
        let characters = Array(decoration)
        guard !characters.isEmpty else { return 0 }

        var retained = 0
        var index = characters.count - 1
        while true {
            let character = characters[index]
            if character.isWhitespace {
                retained += 1
            } else if isOpeningDelimiter(character) {
                retained += 1
            } else if isAmbiguousQuotationMark(character) {
                let decorationCount = characters.filter { $0 == character }.count
                let remainingCount = remainingText.filter { $0 == character }.count
                let retainableCount = max(0, decorationCount - remainingCount % 2) / 2
                let alreadyRetained = characters.suffix(retained).filter { $0 == character }.count
                guard alreadyRetained < retainableCount else { break }
                retained += 1
            } else {
                break
            }

            guard index > 0 else { break }
            index -= 1
        }
        return retained
    }

    private static func hasLegacyPairedBoundary(
        _ decoration: String,
        remainingText: String
    ) -> Bool {
        let retainedCount = retainedOpeningDelimiterCount(
            in: decoration,
            remainingText: remainingText
        )
        guard retainedCount > 0 else { return false }

        let retainedOpening = decoration.suffix(retainedCount)
        let displacedClosing = decoration.dropLast(retainedCount)
        return retainedOpening.contains {
            isOpeningDelimiter($0) || isAmbiguousQuotationMark($0)
        } && displacedClosing.contains {
            isClosingDelimiter($0) || isAmbiguousQuotationMark($0)
        }
    }

    private static func edgeToken(
        in text: String,
        fromStart: Bool,
        matching predicate: (Character) -> Bool
    ) -> String {
        let characters = fromStart ? Array(text) : Array(text.reversed())
        let token = characters.prefix(while: predicate)
        return fromStart ? String(token) : String(token.reversed())
    }

    private static func isTerminalPunctuation(_ character: Character) -> Bool {
        guard !isOpeningDelimiter(character),
              !isClosingDelimiter(character),
              !isAmbiguousQuotationMark(character) else {
            return false
        }
        return character.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .otherPunctuation:
                true
            default:
                false
            }
        }
    }

    private static func isDialogueDash(_ character: Character) -> Bool {
        ["-", "–", "—"].contains(character)
    }

    private static func isOpeningDelimiter(_ character: Character) -> Bool {
        if ["“", "‘", "«", "‹"].contains(character) { return true }
        return character.unicodeScalars.allSatisfy {
            $0.properties.generalCategory == .openPunctuation
        }
    }

    private static func isClosingDelimiter(_ character: Character) -> Bool {
        if ["”", "’", "»", "›"].contains(character) { return true }
        return character.unicodeScalars.allSatisfy {
            $0.properties.generalCategory == .closePunctuation ||
                $0.properties.generalCategory == .finalPunctuation
        }
    }

    private static func isAmbiguousQuotationMark(_ character: Character) -> Bool {
        ["\"", "'", "׳", "״"].contains(character)
    }

    private static func isOnlyEllipsis(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy { $0 == "." || $0 == "…" }
    }

    private static func shouldMarkRightToLeft(_ line: String) -> Bool {
        let counts = directionalCounts(in: line)
        // Punctuation-only lines inherit the file direction from their cue and
        // need a direction mark too. Pure LTR lines in an RTL file do not.
        return counts.rightToLeft > 0 || (counts.leftToRight == 0 && !line.isEmpty)
    }

    private static func removingDirectionalControls(from text: String) -> String {
        let filtered = text.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x061C,       // ARABIC LETTER MARK
                 0x200E...0x200F, // LEFT/RIGHT-TO-LEFT MARK
                 0x202A...0x202E, // embeddings, overrides, and PDF
                 0x2066...0x2069, // directional isolates and PDI
                 0x206A...0x206F: // deprecated directional formatting controls
                false
            default:
                true
            }
        }
        return String(String.UnicodeScalarView(filtered))
    }

    private static func isRightToLeft(languageCode: String?) -> Bool {
        guard let languageCode, !languageCode.isEmpty else { return false }
        return Locale.Language(identifier: SubtitleLanguage.canonicalCode(languageCode) ?? languageCode)
            .characterDirection == .rightToLeft
    }

    private static func directionalCounts(in text: String) -> DirectionalCounts {
        text.unicodeScalars.reduce(into: DirectionalCounts()) { counts, scalar in
            guard scalar.properties.isAlphabetic else { return }
            if isRightToLeft(scalar) {
                counts.rightToLeft += 1
            } else {
                counts.leftToRight += 1
            }
        }
    }

    private static func isRightToLeft(_ scalar: Unicode.Scalar) -> Bool {
        isRightToLeftBlock(scalar)
    }

    private static func isRightToLeftBlock(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x0590...0x08FF).contains(value) ||
            (0xFB1D...0xFDFF).contains(value) ||
            (0xFE70...0xFEFF).contains(value) ||
            (0x10840...0x1085F).contains(value) ||
            (0x10860...0x1087F).contains(value) ||
            (0x10880...0x108AF).contains(value) ||
            (0x108E0...0x108FF).contains(value) ||
            (0x10900...0x1093F).contains(value) ||
            (0x10A00...0x10AFF).contains(value) ||
            (0x10B00...0x10BAF).contains(value) ||
            (0x10D00...0x10D3F).contains(value) ||
            (0x10E80...0x10EFF).contains(value) ||
            (0x10F00...0x10FDF).contains(value) ||
            (0x1E800...0x1E8DF).contains(value) ||
            (0x1E900...0x1E95F).contains(value) ||
            (0x1EC70...0x1EEFF).contains(value)
    }
}

enum SubtitleParser {
    static func cues(from data: Data, languageCode: String? = nil) throws -> [SubtitleCue] {
        guard let decoded = decode(data, languageCode: languageCode) else { throw AppError.decoding("Subtitle text encoding") }
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

    private static let windowsHebrew = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(0x0505)
    ))

    private static func decode(_ data: Data, languageCode: String?) -> String? {
        let bytes = Array(data.prefix(4))
        // Check UTF-32 first: its little-endian BOM starts with the UTF-16 BOM.
        let signatures: [([UInt8], String.Encoding)] = [
            ([0xFF, 0xFE, 0, 0], .utf32LittleEndian),
            ([0, 0, 0xFE, 0xFF], .utf32BigEndian),
            ([0xFF, 0xFE], .utf16LittleEndian),
            ([0xFE, 0xFF], .utf16BigEndian),
            ([0xEF, 0xBB, 0xBF], .utf8)
        ]
        let decoded: String?
        if let (signature, encoding) = signatures.first(where: { bytes.starts(with: $0.0) }) {
            // A declared Unicode encoding must never fall through to a legacy guess.
            decoded = String(data: data.dropFirst(signature.count), encoding: encoding)
        } else if data.contains(0) {
            // BOM-less Unicode must preserve the ASCII subtitle timing syntax.
            decoded = [String.Encoding.utf32LittleEndian, .utf32BigEndian,
                       .utf16LittleEndian, .utf16BigEndian].compactMap {
                String(data: data, encoding: $0)
            }.first { $0.contains("-->") && !$0.contains("\0") }
        } else if let unicode = String(data: data, encoding: .utf8) {
            decoded = unicode
        } else {
            let encodings: [String.Encoding] = isHebrew(languageCode) || languageCode == nil
                ? [windowsHebrew, .windowsCP1252, .isoLatin1]
                : [.windowsCP1252, .isoLatin1]
            decoded = encodings.lazy.compactMap { String(data: data, encoding: $0) }.first
        }
        guard let decoded, !decoded.contains("\u{FFFD}"), !decoded.contains("\0") else { return nil }
        guard isHebrew(languageCode) else { return decoded }
        let lines = decoded.components(separatedBy: "\n")
        let repaired = lines.map { repairHebrewLine($0) }
        let changed = zip(lines, repaired).filter { $0 != $1 }.count
        // Repeated successful repairs establish the encoding for short replies too.
        if changed >= 5 {
            return repaired.map { repairHebrewLine($0, minimumLetters: 1) }.joined(separator: "\n")
        }
        return repaired.joined(separator: "\n")
    }

    private static func isHebrew(_ languageCode: String?) -> Bool {
        SubtitleLanguage.canonicalCode(languageCode) == "he"
    }

    private static func repairHebrewLine(_ line: String, minimumLetters: Int = 3) -> String {
        var result = line
        // Some providers transcode bytes through a Western encoding before serving UTF-8.
        // Only accept lossless reversals with strong Hebrew evidence; leave mixed/valid text alone.
        for _ in 0..<2 {
            guard !result.unicodeScalars.contains(where: { (0x0590...0x05FF).contains($0.value) }) else { break }
            var replacement: String?
            for western in [String.Encoding.windowsCP1252, .isoLatin1] {
                guard let bytes = result.data(using: western, allowLossyConversion: false),
                      String(data: bytes, encoding: western) == result else { continue }
                for encoding in [String.Encoding.utf8, windowsHebrew] {
                    guard let candidate = String(data: bytes, encoding: encoding), candidate != result else { continue }
                    let visible = candidate.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                    let letters = visible.unicodeScalars.filter { $0.properties.isAlphabetic }
                    let hebrew = letters.filter { (0x05D0...0x05EA).contains($0.value) }.count
                    guard hebrew >= minimumLetters, hebrew * 5 >= letters.count * 3,
                          !candidate.contains("\u{FFFD}") else { continue }
                    replacement = candidate
                    break
                }
                if replacement != nil { break }
            }
            guard let replacement else { break }
            result = replacement
        }
        return result
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
    let orderedDisplayNames: [String]
    let languageTags: Set<String>
    let orderedLanguageTags: [String]
}

struct HLSSubtitleRendition: Sendable {
    let subtitle: SubtitleSource
    let cues: [SubtitleCue]
    let timingOffset: Double
    let syncVersionID: UUID?
    let displayNameOverride: String?

    init(
        subtitle: SubtitleSource,
        cues: [SubtitleCue],
        timingOffset: Double = 0,
        syncVersionID: UUID? = nil,
        displayNameOverride: String? = nil
    ) {
        self.subtitle = subtitle
        self.cues = cues
        self.timingOffset = timingOffset
        self.syncVersionID = syncVersionID
        self.displayNameOverride = displayNameOverride
    }
}

/// Converts subtitle renditions already advertised by an HLS master playlist
/// into the cue model used by the sync studio. The stream's original rendition
/// remains untouched; timed copies are injected alongside it.
enum HLSNativeSubtitleLoader {
    private struct Descriptor: Sendable {
        let groupID: String
        let name: String
        let languageCode: String?
        let playlistURL: URL
        let isDefault: Bool
        let isForced: Bool
    }

    private struct Segment: Sendable {
        let index: Int
        let startTime: Double
        let duration: Double
        let url: URL
    }

    private struct LoadedSegment: Sendable {
        let segment: Segment
        let cues: [SubtitleCue]
        let timestampAnchor: Double?
    }

    static func load(
        from source: PlaybackSource,
        client: any HTTPClientProtocol
    ) async -> [HLSSubtitleRendition] {
        guard source.url.pathExtension.lowercased() != "mp4" else { return [] }
        do {
            let response = try await fetch(
                source.url,
                headers: source.headers,
                accept: "application/vnd.apple.mpegurl,application/x-mpegURL,*/*;q=0.8",
                client: client
            )
            try Task.checkCancellation()
            guard let playlist = String(data: response.data, encoding: .utf8) else { return [] }
            let baseURL = response.response.url ?? source.url
            let descriptors = subtitleDescriptors(in: playlist, relativeTo: baseURL)

            return await withTaskGroup(of: (Int, HLSSubtitleRendition?).self) { group in
                for (index, descriptor) in descriptors.enumerated() {
                    group.addTask {
                        do {
                            let cues = try await loadCues(
                                from: descriptor.playlistURL,
                                headers: source.headers,
                                client: client
                            )
                            try Task.checkCancellation()
                            let label = descriptor.isForced
                                ? "\(descriptor.name) (Forced)"
                                : descriptor.name
                            let identity = [
                                descriptor.groupID,
                                descriptor.name,
                                descriptor.languageCode ?? "und",
                                descriptor.isForced ? "forced" : "regular",
                            ].joined(separator: ":")
                            let subtitle = SubtitleSource(
                                id: "native-hls:\(identity)",
                                providerID: "native-hls",
                                providerName: "Built-in",
                                label: label,
                                languageCode: descriptor.languageCode,
                                url: descriptor.playlistURL,
                                isDefault: descriptor.isDefault
                            )
                            return (
                                index,
                                HLSSubtitleRendition(
                                    subtitle: subtitle,
                                    cues: SubtitleDirectionFormatter.normalizedCues(
                                        cues,
                                        languageCode: descriptor.languageCode
                                    )
                                )
                            )
                        } catch {
                            return (index, nil)
                        }
                    }
                }

                var loaded: [(Int, HLSSubtitleRendition)] = []
                for await (index, rendition) in group {
                    if let rendition { loaded.append((index, rendition)) }
                }
                return loaded.sorted { $0.0 < $1.0 }.map(\.1)
            }
        } catch {
            return []
        }
    }

    private static func loadCues(
        from url: URL,
        headers: [String: String],
        client: any HTTPClientProtocol,
        playlistDepth: Int = 0
    ) async throws -> [SubtitleCue] {
        guard playlistDepth <= 2 else { throw AppError.decoding("Nested HLS subtitle playlist") }
        let response = try await fetch(
            url,
            headers: headers,
            accept: "application/vnd.apple.mpegurl,application/x-mpegURL,text/vtt,text/plain,*/*;q=0.8",
            client: client
        )
        try Task.checkCancellation()
        guard let text = String(data: response.data, encoding: .utf8) else {
            return try SubtitleParser.cues(from: response.data)
        }
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else {
            return try SubtitleParser.cues(from: response.data)
        }

        let playlistURL = response.response.url ?? url
        let segments = mediaSegments(in: text, relativeTo: playlistURL)
        if segments.isEmpty,
           let nestedURL = firstMediaURL(in: text, relativeTo: playlistURL),
           nestedURL != url {
            return try await loadCues(
                from: nestedURL,
                headers: headers,
                client: client,
                playlistDepth: playlistDepth + 1
            )
        }
        guard !segments.isEmpty else { throw AppError.decoding("HLS subtitle playlist") }

        var loaded: [LoadedSegment] = []
        let maximumConcurrentDownloads = 8
        for start in stride(from: 0, to: segments.count, by: maximumConcurrentDownloads) {
            try Task.checkCancellation()
            let end = min(start + maximumConcurrentDownloads, segments.count)
            let batch = Array(segments[start..<end])
            let batchResults = try await withThrowingTaskGroup(
                of: LoadedSegment.self,
                returning: [LoadedSegment].self
            ) { group in
                for segment in batch {
                    group.addTask {
                        let segmentResponse = try await fetch(
                            segment.url,
                            headers: headers,
                            accept: "text/vtt,text/plain,*/*;q=0.8",
                            client: client
                        )
                        return LoadedSegment(
                            segment: segment,
                            cues: try SubtitleParser.cues(from: segmentResponse.data),
                            timestampAnchor: timestampMapAnchor(in: segmentResponse.data)
                        )
                    }
                }
                var result: [LoadedSegment] = []
                for try await value in group { result.append(value) }
                return result
            }
            loaded.append(contentsOf: batchResults)
        }

        let ordered = loaded.sorted { $0.segment.index < $1.segment.index }
        let firstTimestampAnchor = ordered.compactMap(\.timestampAnchor).first
        let adjusted = ordered.flatMap { loadedSegment -> [SubtitleCue] in
            let offset: Double
            if let anchor = loadedSegment.timestampAnchor, let firstTimestampAnchor {
                offset = normalizedTimestampDelta(anchor - firstTimestampAnchor)
            } else if cuesAreSegmentRelative(
                loadedSegment.cues,
                segmentDuration: loadedSegment.segment.duration
            ) {
                offset = loadedSegment.segment.startTime
            } else {
                offset = 0
            }
            return loadedSegment.cues.map { $0.shifted(by: offset) }
        }

        return Array(Set(adjusted)).sorted {
            $0.startTime == $1.startTime ? $0.endTime < $1.endTime : $0.startTime < $1.startTime
        }
    }

    private static func fetch(
        _ url: URL,
        headers: [String: String],
        accept: String,
        client: any HTTPClientProtocol
    ) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(HTTPClient.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return try await SubtitleResourceRetry.load(request: request, client: client)
    }

    private static func subtitleDescriptors(in playlist: String, relativeTo baseURL: URL) -> [Descriptor] {
        playlist.components(separatedBy: .newlines).compactMap { line in
            guard line.hasPrefix("#EXT-X-MEDIA:"),
                  attribute("TYPE", in: line)?.uppercased() == "SUBTITLES",
                  let uri = attribute("URI", in: line),
                  let playlistURL = URL(string: uri, relativeTo: baseURL)?.absoluteURL else { return nil }
            let groupID = attribute("GROUP-ID", in: line) ?? "subtitles"
            let language = SubtitleLanguage.canonicalCode(attribute("LANGUAGE", in: line))
            let name = attribute("NAME", in: line)
                ?? language.flatMap { Locale(identifier: "en_US").localizedString(forLanguageCode: $0) }
                ?? "Subtitles"
            return Descriptor(
                groupID: groupID,
                name: name,
                languageCode: language,
                playlistURL: playlistURL,
                isDefault: attribute("DEFAULT", in: line)?.uppercased() == "YES",
                isForced: attribute("FORCED", in: line)?.uppercased() == "YES"
            )
        }
    }

    private static func mediaSegments(in playlist: String, relativeTo baseURL: URL) -> [Segment] {
        let lines = playlist.components(separatedBy: .newlines)
        var result: [Segment] = []
        var pendingDuration: Double?
        var elapsed = 0.0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#EXTINF:") {
                pendingDuration = Double(
                    trimmed.dropFirst("#EXTINF:".count).split(separator: ",").first ?? ""
                )
            } else if !trimmed.isEmpty,
                      !trimmed.hasPrefix("#"),
                      let duration = pendingDuration,
                      let url = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL {
                result.append(Segment(index: result.count, startTime: elapsed, duration: duration, url: url))
                elapsed += duration
                pendingDuration = nil
            }
        }
        return result
    }

    private static func firstMediaURL(in playlist: String, relativeTo baseURL: URL) -> URL? {
        playlist.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") }
            .flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
    }

    private static func timestampMapAnchor(in data: Data) -> Double? {
        guard let text = String(data: data, encoding: .utf8),
              let local = capture(#"LOCAL:([^,\r\n]+)"#, in: text).flatMap(timestamp),
              let ticks = capture(#"MPEGTS:(\d+)"#, in: text).flatMap(Double.init) else { return nil }
        return ticks / 90_000 - local
    }

    private static func cuesAreSegmentRelative(_ cues: [SubtitleCue], segmentDuration: Double) -> Bool {
        guard let latestEnd = cues.map(\.endTime).max() else { return true }
        return latestEnd <= segmentDuration + 2
    }

    /// MPEG-TS timestamps wrap every 2^33 ticks (about 26.5 hours).
    private static func normalizedTimestampDelta(_ value: Double) -> Double {
        let wrap = Double(1 << 33) / 90_000
        if value > wrap / 2 { return value - wrap }
        if value < -wrap / 2 { return value + wrap }
        return value
    }

    private static func attribute(_ name: String, in line: String) -> String? {
        capture("(?:^|[:,])\(name)=\"([^\"]*)\"", in: line)
            ?? capture("(?:^|[:,])\(name)=([^,]*)", in: line)
    }

    private static func capture(_ pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }

    private static func timestamp(_ value: String) -> Double? {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
            .split(separator: ":")
        guard parts.count == 2 || parts.count == 3,
              let seconds = Double(parts.last ?? ""),
              let minutes = Double(parts[parts.count - 2]) else { return nil }
        let hours = parts.count == 3 ? Double(parts[0]) ?? 0 : 0
        return hours * 3_600 + minutes * 60 + seconds
    }
}

struct HLSSubtitleManifestRendition: Sendable {
    let playlistURL: URL
    let subtitle: SubtitleSource
    let displayName: String
    let languageTag: String?

    init(
        playlistURL: URL,
        subtitle: SubtitleSource,
        displayName: String,
        languageTag: String? = nil
    ) {
        self.playlistURL = playlistURL
        self.subtitle = subtitle
        self.displayName = displayName
        self.languageTag = languageTag
    }
}

struct HLSVideoTimelineAnchor: Sendable, Equatable {
    let playerStart: Double
    let mpegTimestamp: UInt64
    let mechanism: String

    static let zero = HLSVideoTimelineAnchor(
        playerStart: 0,
        mpegTimestamp: 0,
        mechanism: "unavailable"
    )
}

/// Resolves AVPlayer elapsed time zero onto the elementary-stream clock used
/// by an HLS rendition. This is intentionally repeated for every rebuilt item:
/// PTS/decode epochs are properties of a rendition, not of a title or episode.
enum HLSVideoTimelineResolver {
    private struct Resource {
        let url: URL
        let byteRange: String?
    }

    static func resolve(
        playlist: String,
        playlistURL: URL,
        headers: [String: String],
        selectedQualityHeight: Int?,
        preferredPeakBitRate: Double?,
        client: any HTTPClientProtocol
    ) async -> HLSVideoTimelineAnchor {
        do {
            let media = try await mediaPlaylist(
                playlist,
                url: playlistURL,
                headers: headers,
                selectedQualityHeight: selectedQualityHeight,
                preferredPeakBitRate: preferredPeakBitRate,
                client: client
            )
            guard let segment = firstSegment(in: media.text, relativeTo: media.url) else {
                return .zero
            }
            let segmentData = try await fetch(segment, headers: headers, client: client).data

            if let ticks = webVTTTimestampMap(in: segmentData) {
                return HLSVideoTimelineAnchor(playerStart: 0, mpegTimestamp: ticks, mechanism: "webvtt")
            }
            if let ticks = transportStreamPTS(in: segmentData) {
                return HLSVideoTimelineAnchor(playerStart: 0, mpegTimestamp: ticks, mechanism: "mpeg-ts-pts")
            }
            if let map = initializationMap(in: media.text, relativeTo: media.url) {
                let initializationData = try await fetch(map, headers: headers, client: client).data
                if let ticks = fragmentedMP4Timestamp(
                    initializationData: initializationData,
                    mediaData: segmentData
                ) {
                    return HLSVideoTimelineAnchor(playerStart: 0, mpegTimestamp: ticks, mechanism: "fmp4-tfdt")
                }
            }
            if let ticks = try await programDateTimeAnchor(
                masterPlaylist: playlist,
                masterURL: playlistURL,
                videoPlaylist: media.text,
                headers: headers,
                client: client
            ) {
                return HLSVideoTimelineAnchor(playerStart: 0, mpegTimestamp: ticks, mechanism: "program-date-time/webvtt")
            }
        } catch where error.isCancellation {
            return .zero
        } catch {
            SubtitleDiagnostics.logger.error(
                "SUBSYNC source video anchor resolution failed: \(String(describing: error), privacy: .public)"
            )
        }
        SubtitleDiagnostics.logger.error(
            "SUBSYNC source video anchor unavailable; falling back to MPEGTS zero"
        )
        return .zero
    }

    private static func mediaPlaylist(
        _ playlist: String,
        url: URL,
        headers: [String: String],
        selectedQualityHeight: Int?,
        preferredPeakBitRate: Double?,
        client: any HTTPClientProtocol,
        depth: Int = 0
    ) async throws -> (text: String, url: URL) {
        guard depth < 4 else { throw AppError.decoding("Nested HLS master playlist") }
        guard playlist.contains("#EXT-X-STREAM-INF:") else { return (playlist, url) }
        guard let variant = selectedVariant(
            in: playlist,
            relativeTo: url,
            selectedQualityHeight: selectedQualityHeight,
            preferredPeakBitRate: preferredPeakBitRate
        ) else { throw AppError.decoding("HLS video rendition") }
        let response = try await fetch(variant, headers: headers, client: client)
        guard let text = String(data: response.data, encoding: .utf8) else {
            throw AppError.decoding("HLS video playlist")
        }
        return try await mediaPlaylist(
            text,
            url: response.response.url ?? variant.url,
            headers: headers,
            selectedQualityHeight: selectedQualityHeight,
            preferredPeakBitRate: preferredPeakBitRate,
            client: client,
            depth: depth + 1
        )
    }

    private static func selectedVariant(
        in playlist: String,
        relativeTo baseURL: URL,
        selectedQualityHeight: Int?,
        preferredPeakBitRate: Double?
    ) -> Resource? {
        struct Variant {
            let resource: Resource
            let height: Int?
            let bandwidth: Double
        }
        let lines = playlist.components(separatedBy: .newlines)
        var variants: [Variant] = []
        for index in lines.indices where lines[index].hasPrefix("#EXT-X-STREAM-INF:") {
            guard let uri = lines[(index + 1)...].first(where: {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#")
            })?.trimmingCharacters(in: .whitespaces),
                  let url = URL(string: uri, relativeTo: baseURL)?.absoluteURL else { continue }
            let line = lines[index]
            variants.append(Variant(
                resource: Resource(url: url, byteRange: nil),
                height: capture(#"RESOLUTION=\d+x(\d+)"#, in: line).flatMap(Int.init),
                bandwidth: capture(#"(?:AVERAGE-)?BANDWIDTH=(\d+)"#, in: line).flatMap(Double.init) ?? 0
            ))
        }
        if let selectedQualityHeight,
           let exact = variants.filter({ $0.height == selectedQualityHeight }).max(by: { $0.bandwidth < $1.bandwidth }) {
            return exact.resource
        }
        if let preferredPeakBitRate, preferredPeakBitRate > 0 {
            return variants.min { abs($0.bandwidth - preferredPeakBitRate) < abs($1.bandwidth - preferredPeakBitRate) }?.resource
        }
        return variants.max(by: { $0.bandwidth < $1.bandwidth })?.resource
    }

    private static func firstSegment(in playlist: String, relativeTo baseURL: URL) -> Resource? {
        let lines = playlist.components(separatedBy: .newlines)
        var pendingRange: String?
        var hasDuration = false
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXTINF:") { hasDuration = true }
            else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingRange = String(line.dropFirst("#EXT-X-BYTERANGE:".count))
            } else if hasDuration, !line.isEmpty, !line.hasPrefix("#"),
                      let url = URL(string: line, relativeTo: baseURL)?.absoluteURL {
                return Resource(url: url, byteRange: pendingRange)
            }
        }
        return nil
    }

    private static func initializationMap(in playlist: String, relativeTo baseURL: URL) -> Resource? {
        guard let line = playlist.components(separatedBy: .newlines).first(where: {
            $0.hasPrefix("#EXT-X-MAP:")
        }), let uri = capture(#"URI=\"([^\"]+)\""#, in: line),
              let url = URL(string: uri, relativeTo: baseURL)?.absoluteURL else { return nil }
        return Resource(url: url, byteRange: capture(#"BYTERANGE=\"([^\"]+)\""#, in: line))
    }

    private static func fetch(
        _ resource: Resource,
        headers: [String: String],
        client: any HTTPClientProtocol
    ) async throws -> HTTPResponse {
        var request = URLRequest(url: resource.url)
        request.setValue("application/vnd.apple.mpegurl,video/mp2t,video/mp4,text/vtt,*/*;q=0.8", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let byteRange = resource.byteRange,
           let range = httpRange(from: byteRange) {
            request.setValue(range, forHTTPHeaderField: "Range")
        }
        return try await SubtitleResourceRetry.load(request: request, client: client)
    }

    private static func httpRange(from value: String) -> String? {
        let parts = value.split(separator: "@", maxSplits: 1).compactMap { UInt64($0) }
        guard let length = parts.first, length > 0 else { return nil }
        let start = parts.count == 2 ? parts[1] : 0
        return "bytes=\(start)-\(start + length - 1)"
    }

    static func webVTTTimestampMap(in data: Data) -> UInt64? {
        guard let text = String(data: data, encoding: .utf8),
              let ticks = capture(#"MPEGTS:(\d+)"#, in: text).flatMap(UInt64.init) else { return nil }
        let localSeconds = capture(#"LOCAL:([^,\r\n]+)"#, in: text).flatMap(timestamp) ?? 0
        return wrappedMPEGTimestamp(Double(ticks) - localSeconds * 90_000)
    }

    private static func programDateTimeAnchor(
        masterPlaylist: String,
        masterURL: URL,
        videoPlaylist: String,
        headers: [String: String],
        client: any HTTPClientProtocol
    ) async throws -> UInt64? {
        guard let videoDate = firstProgramDateTime(in: videoPlaylist),
              let mediaLine = masterPlaylist.components(separatedBy: .newlines).first(where: {
                  $0.hasPrefix("#EXT-X-MEDIA:") && $0.contains("TYPE=SUBTITLES")
              }),
              let uri = capture(#"URI=\"([^\"]+)\""#, in: mediaLine),
              let subtitlePlaylistURL = URL(string: uri, relativeTo: masterURL)?.absoluteURL else { return nil }
        let playlistResponse = try await fetch(
            Resource(url: subtitlePlaylistURL, byteRange: nil), headers: headers, client: client
        )
        guard let subtitlePlaylist = String(data: playlistResponse.data, encoding: .utf8),
              let subtitleDate = firstProgramDateTime(in: subtitlePlaylist),
              let subtitleSegment = firstSegment(
                  in: subtitlePlaylist,
                  relativeTo: playlistResponse.response.url ?? subtitlePlaylistURL
              ) else { return nil }
        let subtitleData = try await fetch(subtitleSegment, headers: headers, client: client).data
        guard let subtitleAnchor = webVTTTimestampMap(in: subtitleData) else { return nil }
        let delta = videoDate.timeIntervalSince(subtitleDate)
        return wrappedMPEGTimestamp(Double(subtitleAnchor) + delta * 90_000)
    }

    private static func firstProgramDateTime(in playlist: String) -> Date? {
        guard let line = playlist.components(separatedBy: .newlines).first(where: {
            $0.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:")
        }) else { return nil }
        let value = String(line.dropFirst("#EXT-X-PROGRAM-DATE-TIME:".count))
        return ISO8601DateFormatter().date(from: value)
    }

    private static func timestamp(_ value: String) -> Double? {
        let parts = value.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else { return nil }
        return hours * 3_600 + minutes * 60 + seconds
    }

    private static func wrappedMPEGTimestamp(_ value: Double) -> UInt64 {
        let wrap = Double(UInt64(1) << 33)
        let normalized = value.truncatingRemainder(dividingBy: wrap)
        return UInt64((normalized < 0 ? normalized + wrap : normalized).rounded())
    }

    /// Extracts the earliest video PES PTS, preferring video stream IDs over
    /// audio. PTS is a 33-bit clock and is deliberately kept wrapped here.
    static func transportStreamPTS(in data: Data) -> UInt64? {
        let bytes = [UInt8](data)
        guard bytes.count >= 14 else { return nil }
        var audioPTS: UInt64?
        for index in 0...(bytes.count - 14) where
            bytes[index] == 0 && bytes[index + 1] == 0 && bytes[index + 2] == 1 {
            let streamID = bytes[index + 3]
            guard (0xC0...0xEF).contains(streamID),
                  bytes[index + 7] & 0x80 != 0 else { continue }
            let p = index + 9
            guard bytes[p] & 0x01 == 1,
                  bytes[p + 2] & 0x01 == 1,
                  bytes[p + 4] & 0x01 == 1 else { continue }
            let value = (UInt64(bytes[p] & 0x0E) << 29)
                | (UInt64(bytes[p + 1]) << 22)
                | (UInt64(bytes[p + 2] & 0xFE) << 14)
                | (UInt64(bytes[p + 3]) << 7)
                | UInt64(bytes[p + 4] >> 1)
            if (0xE0...0xEF).contains(streamID) { return value }
            if audioPTS == nil { audioPTS = value }
        }
        return audioPTS
    }

    static func fragmentedMP4Timestamp(initializationData: Data, mediaData: Data) -> UInt64? {
        let tracks = mp4TrackTimescales(in: initializationData)
        for (trackID, decodeTime) in mp4DecodeTimes(in: mediaData) {
            guard let timescale = tracks[trackID], timescale > 0 else { continue }
            return UInt64((Double(decodeTime) * 90_000 / Double(timescale)).rounded()) & ((1 << 33) - 1)
        }
        return nil
    }

    private static func mp4TrackTimescales(in data: Data) -> [UInt32: UInt32] {
        var result: [UInt32: UInt32] = [:]
        for trak in boxes(named: "trak", in: data) {
            guard let tkhd = boxes(named: "tkhd", in: trak).first,
                  let mdhd = boxes(named: "mdhd", in: trak).first else { continue }
            let tkhdVersion = tkhd.byte(at: 8) ?? 0
            let trackOffset = tkhdVersion == 1 ? 28 : 20
            let mdhdVersion = mdhd.byte(at: 8) ?? 0
            let scaleOffset = mdhdVersion == 1 ? 28 : 20
            if let trackID = tkhd.uint32BE(at: trackOffset),
               let timescale = mdhd.uint32BE(at: scaleOffset) {
                result[trackID] = timescale
            }
        }
        return result
    }

    private static func mp4DecodeTimes(in data: Data) -> [(UInt32, UInt64)] {
        boxes(named: "traf", in: data).compactMap { traf in
            guard let tfhd = boxes(named: "tfhd", in: traf).first,
                  let tfdt = boxes(named: "tfdt", in: traf).first,
                  let trackID = tfhd.uint32BE(at: 12) else { return nil }
            let version = tfdt.byte(at: 8) ?? 0
            let decodeTime = version == 1
                ? tfdt.uint64BE(at: 12)
                : tfdt.uint32BE(at: 12).map(UInt64.init)
            return decodeTime.map { (trackID, $0) }
        }
    }

    private static func boxes(named target: String, in data: Data) -> [Data] {
        var matches: [Data] = []
        func walk(_ range: Range<Int>) {
            var offset = range.lowerBound
            while offset + 8 <= range.upperBound,
                  let size32 = data.uint32BE(at: offset) {
                let typeData = data[(offset + 4)..<(offset + 8)]
                let type = String(data: typeData, encoding: .ascii) ?? ""
                let header = size32 == 1 ? 16 : 8
                let size = size32 == 1 ? Int(data.uint64BE(at: offset + 8) ?? 0) : Int(size32)
                guard size >= header, offset + size <= range.upperBound else { break }
                let box = data.subdata(in: offset..<(offset + size))
                if type == target { matches.append(box) }
                if ["moov", "trak", "mdia", "moof", "traf"].contains(type) {
                    walk((offset + header)..<(offset + size))
                }
                offset += size
            }
        }
        walk(0..<data.count)
        return matches
    }

    private static func capture(_ pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }
}

private extension Data {
    func byte(at offset: Int) -> UInt8? {
        guard indices.contains(offset) else { return nil }
        return self[offset]
    }

    func uint32BE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return self[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    func uint64BE(at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        return self[offset..<(offset + 8)].reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

enum HLSSubtitleInjector {
    private static let externalGroupID = "vela-external-subtitles"

    static func prepare(
        source: PlaybackSource,
        renditions: [HLSSubtitleRendition],
        timingOffset: Double = 0,
        selectedQualityHeight: Int? = nil,
        primarySubtitleLanguage: String = "",
        secondarySubtitleLanguage: String = "",
        client: any HTTPClientProtocol
    ) async throws -> InjectedHLSSubtitleAsset {
        var request = URLRequest(url: source.url)
        request.setValue("application/vnd.apple.mpegurl,application/x-mpegURL,*/*;q=0.8", forHTTPHeaderField: "Accept")
        for (name, value) in source.headers { request.setValue(value, forHTTPHeaderField: name) }
        let response = try await SubtitleResourceRetry.load(request: request, client: client)
        try Task.checkCancellation()
        guard let playlist = String(data: response.data, encoding: .utf8),
              playlist.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else {
            throw AppError.decoding("HLS playlist")
        }

        let sourceURL = response.response.url ?? source.url
        let timelineAnchor = await HLSVideoTimelineResolver.resolve(
            playlist: playlist,
            playlistURL: sourceURL,
            headers: source.headers,
            selectedQualityHeight: selectedQualityHeight,
            preferredPeakBitRate: source.preferredPeakBitRate,
            client: client
        )
        SubtitleDiagnostics.logger.notice(
            "SUBSYNC source video anchor: playerStart=\(timelineAnchor.playerStart, privacy: .public) mpegTS=\(timelineAnchor.mpegTimestamp, privacy: .public) seconds=\(Double(timelineAnchor.mpegTimestamp) / 90_000, privacy: .public) mechanism=\(timelineAnchor.mechanism, privacy: .public)"
        )

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appending(path: "Vela-HLS-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let masterURL = directory.appending(path: "master.m3u8")
            let subtitlePlaylistURLs = renditions.indices.map {
                directory.appending(path: "external-subtitles-\($0).m3u8")
            }
            let displayNames = uniqueDisplayNames(for: renditions)
            var providerOccurrences: [String: Int] = [:]
            let languageTags = renditions.map { rendition in
                let providerKey = rendition.subtitle.providerID.lowercased()
                let occurrence = providerOccurrences[providerKey, default: 0] + 1
                providerOccurrences[providerKey] = occurrence
                return renditionLanguageTag(
                    for: rendition.subtitle,
                    occurrence: occurrence
                )
            }
            let manifestRenditions = renditions.indices.map { index in
                HLSSubtitleManifestRendition(
                    playlistURL: subtitlePlaylistURLs[index],
                    subtitle: renditions[index].subtitle,
                    displayName: displayNames[index],
                    languageTag: languageTags[index]
                )
            }
            let master = rewrittenMasterPlaylist(
                playlist,
                sourceURL: sourceURL,
                renditions: manifestRenditions,
                preferredPeakBitRate: source.preferredPeakBitRate,
                selectedQualityHeight: selectedQualityHeight,
                primarySubtitleLanguage: primarySubtitleLanguage,
                secondarySubtitleLanguage: secondarySubtitleLanguage
            )
            try Data(master.utf8).write(to: masterURL, options: .atomic)
            for (index, rendition) in renditions.enumerated() {
                let adjustedCues = rendition.cues.map {
                    $0.shifted(by: rendition.timingOffset + timingOffset)
                }
                let segments = segmentedWebVTT(
                    cues: adjustedCues,
                    renditionIndex: index,
                    directory: directory
                )
                let subtitlePlaylist = subtitleMediaPlaylist(
                    segments: segments.map { ($0.url, $0.duration) }
                )
                try Data(subtitlePlaylist.utf8).write(
                    to: subtitlePlaylistURLs[index],
                    options: .atomic
                )
                for segment in segments {
                    let content = webVTT(
                        cues: segment.cues,
                        languageCode: rendition.subtitle.languageCode,
                        mpegTimestamp: timelineAnchor.mpegTimestamp
                    )
                    try Data(content.utf8).write(to: segment.url, options: .atomic)
                }
                if let firstCue = adjustedCues.first {
                    SubtitleDiagnostics.logger.notice(
                        "SUBSYNC generated subtitle: provider=\(rendition.subtitle.providerID, privacy: .public) cueStart=\(firstCue.startTime, privacy: .public) mappedMPEGTS=\(timelineAnchor.mpegTimestamp, privacy: .public)"
                    )
                }
            }
            return InjectedHLSSubtitleAsset(
                masterPlaylistURL: masterURL,
                workingDirectory: directory,
                displayNames: Set(displayNames),
                orderedDisplayNames: displayNames,
                languageTags: Set(languageTags),
                orderedLanguageTags: languageTags
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
        selectedQualityHeight: Int? = nil,
        primarySubtitleLanguage: String = "",
        secondarySubtitleLanguage: String = ""
    ) -> String {
        // Keep every variant in the master playlist. Manual quality is an
        // AVPlayerItem preference, not a different playback source; retaining
        // the full master also makes returning to Automatic restore ABR in-place.
        let lines = playlist.components(separatedBy: .newlines)
        let isMasterPlaylist = lines.contains { $0.hasPrefix("#EXT-X-STREAM-INF:") }
        var providerOccurrences: [String: Int] = [:]
        let effectiveLanguageTags = renditions.map { rendition in
            if let languageTag = rendition.languageTag { return languageTag }
            let provider = rendition.subtitle.providerID.lowercased()
            let occurrence = providerOccurrences[provider, default: 0] + 1
            providerOccurrences[provider] = occurrence
            return renditionLanguageTag(for: rendition.subtitle, occurrence: occurrence)
        }

        guard isMasterPlaylist else {
            let bandwidth = max(1, Int(preferredPeakBitRate ?? 10_000_000))
            let mediaTags = renditions.enumerated().map { index, rendition in
                subtitleMediaTag(
                    groupID: externalGroupID,
                    name: rendition.displayName,
                    language: effectiveLanguageTags[index],
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
        let primaryLanguage =
            SubtitleLanguage.canonicalCode(primarySubtitleLanguage)

        let secondaryLanguage =
            SubtitleLanguage.canonicalCode(secondarySubtitleLanguage)

        let builtInEntries = lines
            .filter(isSubtitleMediaTag)
            .enumerated()
            .map { index, line in
                (
                    line: absolutizingURIAttributes(
                        in: line,
                        relativeTo: sourceURL
                    ),
                    language: SubtitleLanguage.canonicalCode(
                        attribute("LANGUAGE", in: line)
                    ),
                    isBuiltIn: true,
                    originalOrder: index
                )
            }

        let generatedEntries = groups
            .flatMap { groupID in
                renditions.enumerated().map { index, rendition in
                    (
                        line: subtitleMediaTag(
                            groupID: groupID,
                            name: rendition.displayName,
                            language: effectiveLanguageTags[index],
                            uri: rendition.playlistURL.absoluteString
                        ),
                        language: rendition.subtitle.canonicalLanguageCode,
                        isBuiltIn: false
                    )
                }
            }
            .enumerated()
            .map { index, entry in
                (
                    line: entry.line,
                    language: entry.language,
                    isBuiltIn: entry.isBuiltIn,
                    originalOrder: builtInEntries.count + index
                )
            }

        let allSubtitleEntries =
            builtInEntries + generatedEntries

        let sortedSubtitleMediaTags = allSubtitleEntries
            .sorted { left, right in
                func group(
                    language: String?,
                    isBuiltIn: Bool
                ) -> Int {
                    if let primaryLanguage,
                       language == primaryLanguage {
                        return 0
                    }

                    if let secondaryLanguage,
                       language == secondaryLanguage {
                        return 1
                    }

                    return isBuiltIn ? 2 : 3
                }

                let leftGroup = group(
                    language: left.language,
                    isBuiltIn: left.isBuiltIn
                )

                let rightGroup = group(
                    language: right.language,
                    isBuiltIn: right.isBuiltIn
                )

                if leftGroup != rightGroup {
                    return leftGroup < rightGroup
                }

                // Inside Primary / Secondary, Built-in comes first.
                if leftGroup <= 1,
                   left.isBuiltIn != right.isBuiltIn {
                    return left.isBuiltIn
                }

                let leftLanguage =
                    SubtitleLanguage.displayName(left.language)

                let rightLanguage =
                    SubtitleLanguage.displayName(right.language)

                let languageComparison =
                    leftLanguage.localizedCaseInsensitiveCompare(
                        rightLanguage
                    )

                if languageComparison != .orderedSame {
                    return languageComparison == .orderedAscending
                }

                let leftName =
                    attribute("NAME", in: left.line) ?? left.line

                let rightName =
                    attribute("NAME", in: right.line) ?? right.line

                let nameComparison =
                    leftName.localizedCaseInsensitiveCompare(
                        rightName
                    )

                if nameComparison != .orderedSame {
                    return nameComparison == .orderedAscending
                }

                return left.originalOrder < right.originalOrder
            }
            .map(\.line)
        let primaryLanguage =
            SubtitleLanguage.canonicalCode(primarySubtitleLanguage)

        let secondaryLanguage =
            SubtitleLanguage.canonicalCode(secondarySubtitleLanguage)

        let builtInEntries = lines
            .filter(isSubtitleMediaTag)
            .enumerated()
            .map { index, line in
                (
                    line: absolutizingURIAttributes(
                        in: line,
                        relativeTo: sourceURL
                    ),
                    language: SubtitleLanguage.canonicalCode(
                        attribute("LANGUAGE", in: line)
                    ),
                    isBuiltIn: true,
                    originalOrder: index
                )
            }

        let generatedEntries = groups
            .flatMap { groupID in
                renditions.enumerated().map { index, rendition in
                    (
                        line: subtitleMediaTag(
                            groupID: groupID,
                            name: rendition.displayName,
                            language: effectiveLanguageTags[index],
                            uri: rendition.playlistURL.absoluteString
                        ),
                        language: rendition.subtitle.canonicalLanguageCode,
                        isBuiltIn: false
                    )
                }
            }
            .enumerated()
            .map { index, entry in
                (
                    line: entry.line,
                    language: entry.language,
                    isBuiltIn: entry.isBuiltIn,
                    originalOrder: builtInEntries.count + index
                )
            }

        let allSubtitleEntries =
            builtInEntries + generatedEntries

        let sortedSubtitleMediaTags = allSubtitleEntries
            .sorted { left, right in
                func group(
                    language: String?,
                    isBuiltIn: Bool
                ) -> Int {
                    if let primaryLanguage,
                       language == primaryLanguage {
                        return 0
                    }

                    if let secondaryLanguage,
                       language == secondaryLanguage {
                        return 1
                    }

                    return isBuiltIn ? 2 : 3
                }

                let leftGroup = group(
                    language: left.language,
                    isBuiltIn: left.isBuiltIn
                )

                let rightGroup = group(
                    language: right.language,
                    isBuiltIn: right.isBuiltIn
                )

                if leftGroup != rightGroup {
                    return leftGroup < rightGroup
                }

                // Inside Primary / Secondary, Built-in comes first.
                if leftGroup <= 1,
                   left.isBuiltIn != right.isBuiltIn {
                    return left.isBuiltIn
                }

                let leftLanguage =
                    SubtitleLanguage.displayName(left.language)

                let rightLanguage =
                    SubtitleLanguage.displayName(right.language)

                let languageComparison =
                    leftLanguage.localizedCaseInsensitiveCompare(
                        rightLanguage
                    )

                if languageComparison != .orderedSame {
                    return languageComparison == .orderedAscending
                }

                let leftName =
                    attribute("NAME", in: left.line) ?? left.line

                let rightName =
                    attribute("NAME", in: right.line) ?? right.line

                let nameComparison =
                    leftName.localizedCaseInsensitiveCompare(
                        rightName
                    )

                if nameComparison != .orderedSame {
                    return nameComparison == .orderedAscending
                }

                return left.originalOrder < right.originalOrder
            }
            .map(\.line)

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
        return subtitleMediaPlaylist(segments: [(webVTTURL, duration)])
    }

    private static func subtitleMediaPlaylist(segments: [(url: URL, duration: Double)]) -> String {
        let targetDuration = max(1, Int(ceil(segments.map { $0.duration }.max() ?? 1)))
        let entries = segments.map { segment in
            "#EXTINF:\(String(format: "%.3f", segment.duration)),\n\(segment.url.absoluteString)"
        }.joined(separator: "\n")
        return """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:\(targetDuration)
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:VOD
        \(entries)
        #EXT-X-ENDLIST

        """
    }

    private struct WebVTTSegment {
        let url: URL
        let duration: Double
        let cues: [SubtitleCue]
    }

    private static func segmentedWebVTT(
        cues: [SubtitleCue],
        renditionIndex: Int,
        directory: URL
    ) -> [WebVTTSegment] {
        // Small enough for reliable seeking/switching, without producing the
        // thousands of files created by broadcast-sized six-second segments.
        let segmentDuration = 60.0
        let totalDuration = max(1, cues.map(\.endTime).max() ?? 1)
        let segmentCount = max(1, Int(ceil(totalDuration / segmentDuration)))
        return (0..<segmentCount).map { segmentIndex in
            let start = Double(segmentIndex) * segmentDuration
            let duration = min(segmentDuration, totalDuration - start)
            let end = start + duration
            return WebVTTSegment(
                url: directory.appending(
                    path: "external-subtitles-\(renditionIndex)-\(segmentIndex).vtt"
                ),
                duration: duration,
                cues: cues.filter { $0.endTime > start && $0.startTime < end }
            )
        }
    }

    static func webVTT(
        cues: [SubtitleCue],
        languageCode: String?,
        mpegTimestamp: UInt64 = 0
    ) -> String {
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
        // The item clock presented by AVPlayer starts at zero even when the
        // underlying PES/decode timeline does not. Every segment uses absolute
        // cue times and the same source-derived map, including boundary-spanning
        // cues duplicated into adjacent subtitle segments.
        let header = "WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:\(mpegTimestamp)"
        guard !blocks.isEmpty else { return header + "\n" }
        return header + "\n\n" + blocks.joined(separator: "\n\n") + "\n"
    }

    static func displayName(for subtitle: SubtitleSource) -> String {
        subtitle.userFacingDisplayName
    }

    private static func uniqueDisplayNames(for renditions: [HLSSubtitleRendition]) -> [String] {
        var occurrences: [String: Int] = [:]
        return renditions.map { rendition in
            let baseName = rendition.displayNameOverride ?? displayName(for: rendition.subtitle)
            let occurrence = occurrences[baseName, default: 0] + 1
            occurrences[baseName] = occurrence
            return occurrence == 1 ? baseName : "\(baseName) (\(occurrence))"
        }
    }

    private static func renditionLanguageTag(
        for subtitle: SubtitleSource,
        occurrence: Int
    ) -> String {
        subtitle.canonicalLanguageCode ?? "und"
    }

    private static func subtitleMediaTag(
        groupID: String,
        name: String,
        language: String,
        uri: String
    ) -> String {
        // AVPlayer replaces NAME with a localized LANGUAGE label in its native
        // picker. External renditions therefore keep canonical language in the
        // shared source model and omit LANGUAGE so the exact NAME is visible.
        // Selection still uses the rendition-backed canonical source language.
        "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"\(escapedAttribute(groupID))\"," +
            "NAME=\"\(escapedAttribute(name))\"," +
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
