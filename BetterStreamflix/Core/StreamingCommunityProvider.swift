import Foundation

final class StreamingCommunityProvider: MediaProvider, @unchecked Sendable {
    let id = "streamingcommunity.en"
    let displayName = "StreamingCommunity (EN)"
    let languageCode = "en"

    private let service: Service

    init(client: any HTTPClientProtocol = HTTPClient(), domain: String = "streamingunity.cc") {
        service = Service(client: client, domain: domain)
    }

    func home() async throws -> [MediaShelf] { try await service.home(providerID: id) }
    func movies(page: Int) async throws -> [MediaItem] { try await service.catalog(kind: .movie, page: page, providerID: id) }
    func series(page: Int) async throws -> [MediaItem] { try await service.catalog(kind: .series, page: page, providerID: id) }
    func search(query: String, page: Int) async throws -> [MediaItem] { try await service.search(query: query, page: page, providerID: id) }
    func details(for item: MediaItem) async throws -> MediaItem { try await service.details(for: item) }
    func episodes(for season: MediaSeason, show: MediaItem) async throws -> [MediaEpisode] { try await service.episodes(for: season, show: show) }
    func playbackSource(for request: PlaybackRequest) async throws -> PlaybackSource { try await service.playbackSource(for: request) }

    actor Service {
        private let client: any HTTPClientProtocol
        private let resolver: VixcloudResolver
        private var domain: String
        private var inertiaVersion: String?

        private let blockedDomains = [
            "streamingcommunityz.green", "streamingunity.club",
            "streamingunity.bike", "streamingcommunityz.buzz"
        ]

        init(client: any HTTPClientProtocol, domain: String) {
            self.client = client
            self.resolver = VixcloudResolver(client: client)
            self.domain = domain
        }

        func home(providerID: String) async throws -> [MediaShelf] {
            let page = try await fetchPage(path: "en/")
            let props = page.props
            var shelves: [MediaShelf] = []
            var used = Set<String>()

            if let hero = props?.sliders?.first(where: { $0.name.lowercased() == "hero" }) ?? props?.sliders?.first {
                appendShelf("Featured", shows: Array(hero.titles.prefix(10)), providerID: providerID, into: &shelves, used: &used)
                used.insert(hero.name.lowercased())
            }
            for slider in props?.sliders ?? [] where !used.contains(slider.name.lowercased()) {
                let title = englishShelfName(for: slider.name) ?? slider.label ?? humanized(slider.name)
                appendShelf(title, shows: slider.titles, providerID: providerID, into: &shelves, used: &used)
            }
            let fallbacks: [(String, [SCShow]?)] = [
                ("Trending Now", props?.trendingTitles ?? props?.trending),
                ("Recently Added Movies", props?.latestMovies),
                ("Recently Added Series", props?.latestTVShows),
                ("Top 10 Today", props?.top10Titles ?? props?.top10),
                ("Coming Soon", props?.upcomingTitles ?? props?.upcoming),
                ("Movies", props?.movies?.data),
                ("Series", props?.tvShows?.data ?? props?.tv?.data),
                ("Browse", props?.archive?.data ?? props?.titles?.data)
            ]
            for (title, shows) in fallbacks {
                appendShelf(title, shows: shows ?? [], providerID: providerID, into: &shelves, used: &used)
            }
            return shelves.filter { !$0.items.isEmpty }
        }

        func search(query: String, page: Int, providerID: String) async throws -> [MediaItem] {
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            var components = URLComponents(url: try baseURL().appending(path: "en/search"), resolvingAgainstBaseURL: false)
            components?.queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "lang", value: "en")
            ]
            guard let url = components?.url else { throw AppError.invalidURL }
            let response = try await request(url: url, acceptsJSON: true)
            let decoded = try JSONDecoder.provider.decode(SCSearchResponse.self, from: response.data)
            guard decoded.currentPage.map({ $0 <= (decoded.lastPage ?? $0) }) ?? true else { return [] }
            return decoded.data.map { media(from: $0, providerID: providerID) }
        }

        func catalog(kind: MediaKind, page: Int, providerID: String) async throws -> [MediaItem] {
            if page == 1 {
                let page = try await fetchPage(path: "en/archive?type=\(kind.rawValue)")
                let props = page.props
                let shows = props?.archive?.data ?? props?.titles?.data ?? props?.movies?.data ?? props?.tv?.data ?? props?.tvShows?.data ?? []
                return shows.map { media(from: $0, providerID: providerID) }
            }
            var components = URLComponents(url: try baseURL().appending(path: "en/archive"), resolvingAgainstBaseURL: false)
            components?.queryItems = [
                URLQueryItem(name: "lang", value: "en"),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "type", value: kind.rawValue)
            ]
            guard let url = components?.url else { throw AppError.invalidURL }
            let response = try await request(url: url, acceptsJSON: true)
            return try JSONDecoder.provider.decode(SCSearchResponse.self, from: response.data).data.map {
                media(from: $0, providerID: providerID)
            }
        }

        func details(for item: MediaItem) async throws -> MediaItem {
            let page = try await fetchPage(path: "en/titles/\(item.id)")
            guard let show = page.props?.title else { throw AppError.decoding("Title details") }
            return media(from: show, providerID: item.providerID, forcedKind: item.kind)
        }

        func episodes(for season: MediaSeason, show: MediaItem) async throws -> [MediaEpisode] {
            let page = try await fetchPage(path: "en/titles/\(season.id)")
            let episodes = page.props?.loadedSeason?.episodes ?? []
            return episodes.enumerated().map { index, episode in
                MediaEpisode(
                    id: "\(show.id.components(separatedBy: "-").first ?? show.id)?episode_id=\(episode.id)",
                    providerID: show.providerID,
                    showID: show.id,
                    seasonNumber: season.number,
                    number: Int(episode.number) ?? index + 1,
                    title: episode.name,
                    overview: episode.plot,
                    posterURL: imageURL(episode.images.first(where: { $0.type == "cover" })?.filename)
                )
            }
        }

        func playbackSource(for playbackRequest: PlaybackRequest) async throws -> PlaybackSource {
            let rawID = playbackRequest.episode?.id ?? playbackRequest.media.id.components(separatedBy: "-").first ?? playbackRequest.media.id
            var components = URLComponents(url: try baseURL().appending(path: "en/iframe/\(rawID.components(separatedBy: "?").first ?? rawID)"), resolvingAgainstBaseURL: false)
            var query = [URLQueryItem(name: "language", value: "en")]
            if let episodeID = playbackRequest.episode?.id.components(separatedBy: "episode_id=").last {
                query.insert(URLQueryItem(name: "episode_id", value: episodeID), at: 0)
                query.append(URLQueryItem(name: "next_episode", value: "1"))
            }
            components?.queryItems = query
            guard let iframeEndpoint = components?.url else { throw AppError.invalidURL }
            let response = try await request(url: iframeEndpoint, acceptsJSON: true)
            let playerURL = try HTMLPayloadParser.firstIFrameURL(from: response.data, relativeTo: iframeEndpoint)
            do {
                return try await resolver.resolve(iframeURL: playerURL, referer: iframeEndpoint)
            } catch where error.isCancellation {
                throw error
            } catch {
                // Player tokens are short-lived. Refetch once before surfacing the error.
                let retry = try await request(url: iframeEndpoint, acceptsJSON: true)
                let refreshedURL = try HTMLPayloadParser.firstIFrameURL(from: retry.data, relativeTo: iframeEndpoint)
                return try await resolver.resolve(iframeURL: refreshedURL, referer: iframeEndpoint)
            }
        }

        private func fetchPage(path: String) async throws -> SCPage {
            let url = try endpoint(path)
            if let version = inertiaVersion {
                do {
                    let response = try await request(url: url, inertiaVersion: version)
                    let page = try JSONDecoder.provider.decode(SCPage.self, from: response.data)
                    inertiaVersion = page.version ?? version
                    return page
                } catch where error.isCancellation {
                    throw error
                } catch {
                    inertiaVersion = nil
                }
            }
            let response = try await request(url: url)
            let json = try HTMLPayloadParser.inertiaJSON(from: response.data)
            let page = try JSONDecoder.provider.decode(SCPage.self, from: json)
            inertiaVersion = page.version
            return page
        }

        private func request(url: URL, inertiaVersion: String? = nil, acceptsJSON: Bool = false) async throws -> HTTPResponse {
            let response = try await client.data(for: .providerRequest(
                url: url,
                referer: try? baseURL(),
                inertiaVersion: inertiaVersion,
                acceptsJSON: acceptsJSON
            ))
            if let finalHost = response.response.url?.host,
               finalHost != domain,
               !blockedDomains.contains(where: { finalHost.contains($0) }) {
                domain = finalHost
            }
            return response
        }

        private func baseURL() throws -> URL {
            guard let url = URL(string: "https://\(domain)/") else { throw AppError.invalidURL }
            return url
        }

        private func endpoint(_ path: String) throws -> URL {
            guard let url = URL(string: path, relativeTo: try baseURL())?.absoluteURL else { throw AppError.invalidURL }
            return url
        }

        private func media(from show: SCShow, providerID: String, forcedKind: MediaKind? = nil) -> MediaItem {
            let kind = forcedKind ?? (show.type.lowercased() == "movie" ? .movie : .series)
            let mediaID = "\(show.id)-\(show.slug)"
            let seasons = (show.seasons ?? []).enumerated().map { index, season in
                let number = Int(season.number) ?? index + 1
                return MediaSeason(id: "\(mediaID)/season-\(season.number)", number: number, title: season.name, posterURL: nil)
            }
            return MediaItem(
                id: mediaID,
                providerID: providerID,
                kind: kind,
                title: show.name,
                overview: show.plot,
                releaseDate: show.lastAirDate,
                rating: show.score.flatMap(Double.init),
                quality: show.quality,
                runtimeMinutes: show.runtime,
                posterURL: imageURL(show.images.first(where: { $0.type == "poster" })?.filename
                    ?? show.images.first(where: { $0.type == "cover" })?.filename),
                backdropURL: imageURL(show.images.first(where: { $0.type == "background" })?.filename
                    ?? show.images.first(where: { $0.type == "cover" })?.filename),
                genres: (show.genres ?? []).map { MediaGenre(id: $0.id, name: $0.name) },
                cast: (show.actors ?? []).map { CastMember(id: $0.id ?? $0.name, name: $0.name, imageURL: nil) },
                seasons: seasons
            )
        }

        private func imageURL(_ filename: String?) -> URL? {
            guard let filename, !filename.isEmpty else { return nil }
            return URL(string: "https://cdn.\(domain)/images/\(filename)")
        }

        private func appendShelf(_ title: String, shows: [SCShow], providerID: String, into shelves: inout [MediaShelf], used: inout Set<String>) {
            guard !shows.isEmpty else { return }
            let key = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard used.insert(key).inserted else { return }
            shelves.append(MediaShelf(title: title, items: shows.map { media(from: $0, providerID: providerID) }))
        }

        private func englishShelfName(for value: String) -> String? {
            let lower = value.lowercased()
            if lower.contains("trending") { return "Trending Now" }
            if lower.contains("latest-movies") { return "Recently Added Movies" }
            if lower.contains("latest-tv") { return "Recently Added Series" }
            if lower.contains("top-10") { return "Top 10 Today" }
            if lower.contains("upcoming") { return "Coming Soon" }
            if lower.contains("new-releases") { return "New Releases" }
            return nil
        }

        private func humanized(_ value: String) -> String {
            value.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }
}
