import CryptoKit
import Foundation
import ImageIO
import Security

struct TrendingTitle: Identifiable, Hashable, Sendable {
    let id: Int
    let kind: MediaKind
    let title: String
    var originalTitle: String? = nil
    let overview: String
    let releaseDate: String?
    let rating: Double?
    let genreNames: [String]
    let posterURL: URL?
    let backdropURL: URL?

    var lookupKey: String { "\(kind.rawValue):\(id)" }

    var year: String? {
        guard let releaseDate, releaseDate.count >= 4 else { return nil }
        return String(releaseDate.prefix(4))
    }
}

struct TMDBTitlePage: Sendable {
    let titles: [TrendingTitle]
    let page: Int
    let totalPages: Int
}

struct TMDBArtwork: Equatable, Sendable {
    let posterURL: URL?
    let backdropURL: URL?

    /// The app's portrait hero matches the Home carousel, so posters are the
    /// primary artwork and backdrops are only a fallback when no poster loads.
    var heroURLs: [URL] {
        [posterURL, backdropURL].compactMap { $0 }.reduce(into: []) { urls, url in
            if !urls.contains(url) { urls.append(url) }
        }
    }

    var heroURL: URL? { heroURLs.first }
}

struct TMDBCarouselAssets: Sendable {
    var artworkDataByKey: [String: Data] = [:]
    var logoDataByKey: [String: Data] = [:]
}

enum TMDBCollection: Identifiable, Hashable, Sendable {
    case trending(MediaKind)
    case topToday(MediaKind)
    case popular(MediaKind)
    case topRated(MediaKind)
    case newReleases(MediaKind)
    case genre(kind: MediaKind, id: Int, name: String)

    var id: String {
        switch self {
        case .trending(let kind): "trending-\(kind.rawValue)"
        case .topToday(let kind): "top-today-\(kind.rawValue)"
        case .popular(let kind): "popular-\(kind.rawValue)"
        case .topRated(let kind): "top-rated-\(kind.rawValue)"
        case .newReleases(let kind): "new-releases-\(kind.rawValue)"
        case .genre(let kind, let id, _): "genre-\(kind.rawValue)-\(id)"
        }
    }

    var title: String {
        switch self {
        case .trending(.movie): "Trending Movies"
        case .trending(.series): "Trending Shows"
        case .topToday(.movie): "Top 10 Movies Today"
        case .topToday(.series): "Top 10 Shows Today"
        case .popular(.movie): "Popular Movies"
        case .popular(.series): "Popular Series"
        case .topRated(.movie): "Critically Acclaimed Movies"
        case .topRated(.series): "Top Rated Series"
        case .newReleases(.movie): "Now Playing"
        case .newReleases(.series): "New Episodes This Week"
        case .genre(_, _, let name): name
        }
    }

    var kind: MediaKind {
        switch self {
        case .trending(let kind), .topToday(let kind), .popular(let kind),
             .topRated(let kind), .newReleases(let kind), .genre(let kind, _, _): kind
        }
    }

    static func catalogSections(for kind: MediaKind) -> [TMDBCollection] {
        let genres: [(Int, String)] = kind == .movie
            ? [(28, "Action"), (12, "Adventure"), (16, "Animation"), (35, "Comedy"),
               (80, "Crime"), (99, "Documentaries"), (18, "Drama"), (10751, "Family"),
               (14, "Fantasy"), (36, "History"), (27, "Horror"), (10402, "Music"),
               (9648, "Mystery"), (10749, "Romance"), (878, "Sci-Fi"), (53, "Thriller"),
               (10752, "War"), (37, "Western")]
            : [(10759, "Action & Adventure"), (16, "Animation"), (35, "Comedy"), (80, "Crime"),
               (99, "Documentary"), (18, "Drama"), (10751, "Family"), (9648, "Mystery"),
               (10765, "Sci-Fi & Fantasy"), (10762, "Kids"), (10763, "News"), (10764, "Reality"),
               (10766, "Soap"), (10767, "Talk"), (10768, "War & Politics"), (37, "Western")]
        return [.trending(kind), .popular(kind), .topRated(kind), .newReleases(kind)]
            + genres.map { .genre(kind: kind, id: $0.0, name: $0.1) }
    }

    static let homeSections: [TMDBCollection] = [
        .trending(.series), .trending(.movie),
        .topToday(.series), .topToday(.movie),
        .popular(.series), .popular(.movie),
        .newReleases(.series), .newReleases(.movie),
        .genre(kind: .movie, id: 28, name: "Action Hits"),
        .genre(kind: .series, id: 18, name: "Binge-Worthy Drama"),
        .genre(kind: .movie, id: 35, name: "Feel-Good Comedy"),
        .genre(kind: .series, id: 10765, name: "Sci-Fi & Fantasy Worlds"),
    ]
}

actor TMDBClient {
    private let client: any HTTPClientProtocol
    private let imageCache: TMDBImageCache
    private var imageDownloadTasks: [URL: Task<Data, Error>] = [:]

    init(
        client: any HTTPClientProtocol = HTTPClient(),
        imageCache: TMDBImageCache = TMDBImageCache()
    ) {
        self.client = client
        self.imageCache = imageCache
        Task { await imageCache.removeExpiredEntries() }
    }

    func trending(accessToken: String, language: String = "en-US") async throws -> [TrendingTitle] {
        let page = try await fetch(
            path: "trending/all/day",
            accessToken: accessToken,
            language: language,
            page: 1,
            fallbackKind: nil
        )
        return Array(page.titles.prefix(10))
    }

    func titles(
        in collection: TMDBCollection,
        accessToken: String,
        language: String = "en-US",
        page: Int = 1
    ) async throws -> TMDBTitlePage {
        let path: String
        var extraQueryItems: [URLQueryItem] = []
        switch collection {
        case .trending(let kind):
            path = "trending/\(kind == .movie ? "movie" : "tv")/day"
        case .topToday(let kind):
            path = "trending/\(kind == .movie ? "movie" : "tv")/day"
        case .popular(let kind):
            path = "\(kind == .movie ? "movie" : "tv")/popular"
        case .topRated(let kind):
            path = "\(kind == .movie ? "movie" : "tv")/top_rated"
        case .newReleases(let kind):
            path = kind == .movie ? "movie/now_playing" : "tv/on_the_air"
        case .genre(let kind, let genreID, _):
            path = "discover/\(kind == .movie ? "movie" : "tv")"
            extraQueryItems = [
                URLQueryItem(name: "with_genres", value: String(genreID)),
                URLQueryItem(name: "sort_by", value: "popularity.desc"),
                URLQueryItem(name: "include_adult", value: "false"),
            ]
        }
        var result = try await fetch(
            path: path,
            accessToken: accessToken,
            language: language,
            page: page,
            fallbackKind: collection.kind,
            extraQueryItems: extraQueryItems
        )
        if case .topToday = collection {
            result = TMDBTitlePage(
                titles: Array(result.titles.prefix(10)),
                page: result.page,
                totalPages: 1
            )
        }
        return result
    }

    func search(
        query: String,
        accessToken: String,
        language: String = "en-US",
        page: Int = 1
    ) async throws -> TMDBTitlePage {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return TMDBTitlePage(titles: [], page: page, totalPages: page)
        }
        return try await fetch(
            path: "search/multi",
            accessToken: accessToken,
            language: language,
            page: page,
            fallbackKind: nil,
            extraQueryItems: [
                URLQueryItem(name: "query", value: trimmedQuery),
                URLQueryItem(name: "include_adult", value: "false"),
            ]
        )
    }

    func details(
        for item: MediaItem,
        accessToken: String,
        language: String = "en-US"
    ) async throws -> MediaItem {
        guard let tmdbID = item.tmdbID else {
            guard let metadata = try await titleMetadata(
                for: item,
                accessToken: accessToken,
                language: language
            ) else { throw AppError.decoding("TMDB title identity") }
            return try await details(
                for: item.applyingTMDBMetadata(metadata),
                accessToken: accessToken,
                language: language
            )
        }
        guard !accessToken.isEmpty else { throw TMDBError.missingAccessToken }
        var components = URLComponents(
            string: "https://api.themoviedb.org/3/\(item.kind == .movie ? "movie" : "tv")/\(tmdbID)"
        )
        components?.queryItems = [
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "append_to_response", value: "external_ids,credits"),
        ]
        guard let url = components?.url else { throw AppError.invalidURL }
        let response = try await client.data(for: authorizedRequest(url: url, accessToken: accessToken))
        do {
            return try JSONDecoder().decode(TMDBDetailsPayload.self, from: response.data)
                .mediaItem(replacing: item)
        } catch {
            throw AppError.decoding(error.localizedDescription)
        }
    }

    func episodes(
        for season: MediaSeason,
        show: MediaItem,
        accessToken: String,
        language: String = "en-US",
        asOf date: Date = Date()
    ) async throws -> [MediaEpisode] {
        guard show.kind == .series, let tmdbID = show.tmdbID else { return [] }
        guard !accessToken.isEmpty else { throw TMDBError.missingAccessToken }
        var components = URLComponents(
            string: "https://api.themoviedb.org/3/tv/\(tmdbID)/season/\(season.number)"
        )
        components?.queryItems = [URLQueryItem(name: "language", value: language)]
        guard let url = components?.url else { throw AppError.invalidURL }
        let response = try await client.data(for: authorizedRequest(url: url, accessToken: accessToken))
        do {
            let payload = try JSONDecoder().decode(TMDBSeasonPayload.self, from: response.data)
            return payload.episodes
                .filter { $0.hasAired(asOf: date) }
                .map { $0.mediaEpisode(show: show, fallbackSeason: season.number) }
        } catch {
            throw AppError.decoding(error.localizedDescription)
        }
    }

    func titleMetadata(
        for item: MediaItem,
        accessToken: String,
        language: String = "en-US"
    ) async throws -> TrendingTitle? {
        if let tmdbID = item.tmdbID {
            return try await titleMetadata(
                path: "\(item.kind == .movie ? "movie" : "tv")/\(tmdbID)",
                kind: item.kind,
                accessToken: accessToken,
                language: language,
                queryItems: []
            )
        }

        if let imdbID = item.imdbID?.trimmingCharacters(in: .whitespacesAndNewlines),
           Self.isIMDbTitleID(imdbID) {
            do {
                if let metadata = try await titleMetadata(
                    imdbID: imdbID,
                    kind: item.kind,
                    accessToken: accessToken,
                    language: language
                ) {
                    return metadata
                }
            } catch where error.isCancellation {
                throw error
            } catch {
                // A stale provider IMDb ID must not prevent the title fallback.
            }
        }

        let queryItems = [
            URLQueryItem(name: "query", value: item.title),
            URLQueryItem(name: "include_adult", value: "false"),
        ]
        var datedQueryItems = queryItems
        if let year = item.releaseDate.map({ String($0.prefix(4)) }), year.count == 4 {
            datedQueryItems.append(URLQueryItem(
                name: item.kind == .movie ? "year" : "first_air_date_year",
                value: year
            ))
        }
        let datedMatch = try await titleMetadata(
            path: "search/\(item.kind == .movie ? "movie" : "tv")",
            kind: item.kind,
            accessToken: accessToken,
            language: language,
            queryItems: datedQueryItems,
            preferredTitle: item.title
        )
        guard datedMatch == nil, datedQueryItems.count != queryItems.count else {
            return datedMatch
        }

        // Some providers expose a last-air or catalog year as the title's release
        // date. Keep the year for precision first, then retry without it so an
        // otherwise exact title match is not lost to unreliable provider metadata.
        return try await titleMetadata(
            path: "search/\(item.kind == .movie ? "movie" : "tv")",
            kind: item.kind,
            accessToken: accessToken,
            language: language,
            queryItems: queryItems,
            preferredTitle: item.title
        )
    }

    func artwork(
        for item: MediaItem,
        accessToken: String,
        language: String = "en-US"
    ) async throws -> TMDBArtwork? {
        if let tmdbID = item.tmdbID {
            return try await artwork(
                path: "\(item.kind == .movie ? "movie" : "tv")/\(tmdbID)",
                accessToken: accessToken,
                language: language,
                queryItems: []
            )
        }

        var queryItems = [
            URLQueryItem(name: "query", value: item.title),
            URLQueryItem(name: "include_adult", value: "false"),
        ]
        if let year = item.releaseDate.map({ String($0.prefix(4)) }), year.count == 4 {
            queryItems.append(URLQueryItem(
                name: item.kind == .movie ? "year" : "first_air_date_year",
                value: year
            ))
        }
        return try await artwork(
            path: "search/\(item.kind == .movie ? "movie" : "tv")",
            accessToken: accessToken,
            language: language,
            queryItems: queryItems,
            preferredTitle: item.title
        )
    }

    func heroArtworkData(
        for item: MediaItem,
        accessToken: String,
        language: String = "en-US"
    ) async throws -> Data? {
        var attemptedURLs = Set<URL>()

        let directTMDBURLs = [item.posterURL, item.backdropURL]
            .compactMap { $0 }
            .filter { $0.host?.lowercased() == "image.tmdb.org" }
        var result = await firstLoadableImage(from: directTMDBURLs, excluding: attemptedURLs)
        attemptedURLs = result.attemptedURLs
        if let data = result.data {
            return data
        }

        // Refresh the artwork record after direct URLs fail. This also supplies
        // TMDB artwork for provider items that arrived without TMDB image URLs.
        if let refreshedArtwork = try? await artwork(
            for: item,
            accessToken: accessToken,
            language: language
        ) {
            result = await firstLoadableImage(
                from: refreshedArtwork.heroURLs,
                excluding: attemptedURLs
            )
            attemptedURLs = result.attemptedURLs
            if let data = result.data { return data }
        }

        // Provider artwork is the final fallback when TMDB is missing or its CDN
        // object cannot be decoded. Keep poster-first ordering consistent with
        // the Home carousel here as well.
        let providerURLs = [item.posterURL, item.backdropURL]
            .compactMap { $0 }
            .filter { $0.host?.lowercased() != "image.tmdb.org" }
        return await firstLoadableImage(
            from: providerURLs,
            excluding: attemptedURLs
        ).data
    }

    private func firstLoadableImage(
        from urls: [URL],
        excluding previouslyAttemptedURLs: Set<URL>
    ) async -> (data: Data?, attemptedURLs: Set<URL>) {
        var attemptedURLs = previouslyAttemptedURLs
        for url in urls where attemptedURLs.insert(url).inserted {
            do {
                return (try await imageData(for: url), attemptedURLs)
            } catch where error.isCancellation {
                return (nil, attemptedURLs)
            } catch {
                // Artwork records and CDN objects can temporarily disagree.
                // Continue through the remaining known sources rather than
                // leaving the entire hero empty because one URL is stale.
                continue
            }
        }
        return (nil, attemptedURLs)
    }

    func carouselAssets(
        for titles: [TrendingTitle],
        accessToken: String,
        language: String = "en-US",
        timeout: Duration = .seconds(5)
    ) async -> TMDBCarouselAssets {
        enum Result: Sendable {
            case title(key: String, artwork: Data?, logo: Data?)
            case timeout
        }

        return await withTaskGroup(of: Result.self) { group in
            for title in titles {
                group.addTask { [self] in
                    async let artwork: Data? = {
                        guard let url = title.posterURL ?? title.backdropURL else { return nil }
                        return try? await imageData(for: url)
                    }()
                    async let logo = try? logoData(
                        for: title,
                        accessToken: accessToken,
                        language: language
                    )
                    return await .title(key: title.lookupKey, artwork: artwork, logo: logo)
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .timeout
            }

            var assets = TMDBCarouselAssets()
            var completedTitles = 0
            while let result = await group.next() {
                switch result {
                case .title(let key, let artwork, let logo):
                    completedTitles += 1
                    if let artwork { assets.artworkDataByKey[key] = artwork }
                    if let logo { assets.logoDataByKey[key] = logo }
                    if completedTitles == titles.count {
                        group.cancelAll()
                        return assets
                    }
                case .timeout:
                    group.cancelAll()
                    return assets
                }
            }
            return assets
        }
    }

    func imageData(for url: URL) async throws -> Data {
        if let cachedData = await imageCache.data(for: url) {
            if Self.isDecodableImage(cachedData) {
                return cachedData
            }
            await imageCache.removeData(for: url)
        }
        if let existingTask = imageDownloadTasks[url] {
            return try await existingTask.value
        }

        let client = self.client
        let imageCache = self.imageCache
        let task = Task<Data, Error> {
            if let cachedData = await imageCache.data(for: url) {
                if Self.isDecodableImage(cachedData) {
                    return cachedData
                }
                await imageCache.removeData(for: url)
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let data = try await client.data(for: request).data
            try Task.checkCancellation()
            guard Self.isDecodableImage(data) else {
                throw AppError.decoding("The image response could not be decoded.")
            }
            await imageCache.store(data, for: url)
            return data
        }
        imageDownloadTasks[url] = task
        defer { imageDownloadTasks[url] = nil }
        // Keep filling the shared disk cache even if the requesting view scrolls
        // away or is dismissed before this download completes.
        return try await task.value
    }

    private nonisolated static func isDecodableImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return false }
        return CGImageSourceGetStatus(source) == .statusComplete
    }

    func logoData(
        for title: TrendingTitle,
        accessToken: String,
        language: String = "en-US"
    ) async throws -> Data? {
        try await logoData(
            tmdbID: title.id,
            kind: title.kind,
            accessToken: accessToken,
            language: language
        )
    }

    func logoData(
        for item: MediaItem,
        accessToken: String,
        language: String = "en-US"
    ) async throws -> Data? {
        let reference: (id: Int, kind: MediaKind)
        if let tmdbID = item.tmdbID {
            reference = (tmdbID, item.kind)
        } else if let metadata = try await titleMetadata(
            for: item,
            accessToken: accessToken,
            language: language
        ) {
            reference = (metadata.id, metadata.kind)
        } else {
            return nil
        }

        return try await logoData(
            tmdbID: reference.id,
            kind: reference.kind,
            accessToken: accessToken,
            language: language
        )
    }

    func logoURL(
        tmdbID: Int,
        kind: MediaKind,
        accessToken: String,
        language: String = "en-US"
    ) async throws -> URL? {
        guard !accessToken.isEmpty else { throw TMDBError.missingAccessToken }
        let preferredLanguage = Self.imageLanguageCode(from: language)
        let lookupCacheURL = try Self.logoLookupCacheURL(
            tmdbID: tmdbID,
            kind: kind,
            language: preferredLanguage
        )
        if let cachedLookup = await imageCache.data(for: lookupCacheURL),
           let value = String(data: cachedLookup, encoding: .utf8) {
            return value == "none" ? nil : URL(string: value)
        }
        let includedLanguages = [preferredLanguage, "en", "null"]
            .reduce(into: [String]()) { values, language in
                if !values.contains(language) { values.append(language) }
            }
            .joined(separator: ",")

        var components = URLComponents(
            string: "https://api.themoviedb.org/3/\(kind == .movie ? "movie" : "tv")/\(tmdbID)/images"
        )
        components?.queryItems = [
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "include_image_language", value: includedLanguages),
        ]
        guard let url = components?.url else { throw AppError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .returnCacheDataElseLoad
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let response = try await client.data(for: request)
        do {
            let payload = try JSONDecoder().decode(TMDBImagesPayload.self, from: response.data)
            let logoURL = payload.preferredLogoURL(language: preferredLanguage)
            let cachedValue = logoURL?.absoluteString ?? "none"
            await imageCache.store(Data(cachedValue.utf8), for: lookupCacheURL)
            return logoURL
        } catch {
            throw AppError.decoding(error.localizedDescription)
        }
    }

    private func logoData(
        tmdbID: Int,
        kind: MediaKind,
        accessToken: String,
        language: String
    ) async throws -> Data? {
        guard let url = try await logoURL(
            tmdbID: tmdbID,
            kind: kind,
            accessToken: accessToken,
            language: language
        ) else { return nil }
        return try await imageData(for: url)
    }

    private func fetch(
        path: String,
        accessToken: String,
        language: String,
        page: Int,
        fallbackKind: MediaKind?,
        extraQueryItems: [URLQueryItem] = []
    ) async throws -> TMDBTitlePage {
        guard !accessToken.isEmpty else { throw TMDBError.missingAccessToken }
        var components = URLComponents(string: "https://api.themoviedb.org/3/\(path)")
        components?.queryItems = [
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "page", value: String(page)),
        ] + extraQueryItems
        guard let url = components?.url else { throw AppError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .returnCacheDataElseLoad
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let response = try await client.data(for: request)
        do {
            let payload = try JSONDecoder().decode(TMDBTrendingResponse.self, from: response.data)
            return TMDBTitlePage(
                titles: payload.results.compactMap { $0.trendingTitle(fallbackKind: fallbackKind) },
                page: payload.page ?? page,
                totalPages: max(payload.totalPages ?? page, page)
            )
        } catch {
            throw AppError.decoding(error.localizedDescription)
        }
    }

    private func authorizedRequest(url: URL, accessToken: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .returnCacheDataElseLoad
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func artwork(
        path: String,
        accessToken: String,
        language: String,
        queryItems: [URLQueryItem],
        preferredTitle: String? = nil
    ) async throws -> TMDBArtwork? {
        guard !accessToken.isEmpty else { throw TMDBError.missingAccessToken }
        var components = URLComponents(string: "https://api.themoviedb.org/3/\(path)")
        components?.queryItems = [URLQueryItem(name: "language", value: language)] + queryItems
        guard let url = components?.url else { throw AppError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .returnCacheDataElseLoad
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let response = try await client.data(for: request)
        if preferredTitle == nil {
            let payload = try JSONDecoder().decode(TMDBArtworkPayload.self, from: response.data)
            return payload.artwork
        }

        let payload = try JSONDecoder().decode(TMDBArtworkSearchResponse.self, from: response.data)
        let normalizedTitle = preferredTitle?.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        let match = payload.results.first(where: {
            ($0.title ?? $0.name)?.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            ) == normalizedTitle && $0.artwork.heroURL != nil
        })
        return match?.artwork
    }

    private func titleMetadata(
        path: String,
        kind: MediaKind,
        accessToken: String,
        language: String,
        queryItems: [URLQueryItem],
        preferredTitle: String? = nil
    ) async throws -> TrendingTitle? {
        guard !accessToken.isEmpty else { throw TMDBError.missingAccessToken }
        var components = URLComponents(string: "https://api.themoviedb.org/3/\(path)")
        components?.queryItems = [URLQueryItem(name: "language", value: language)] + queryItems
        guard let url = components?.url else { throw AppError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .returnCacheDataElseLoad
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let response = try await client.data(for: request)
        do {
            if let preferredTitle {
                let payload = try JSONDecoder().decode(TMDBMetadataSearchResponse.self, from: response.data)
                let normalizedTitle = Self.normalizedTitle(preferredTitle)
                return payload.results.first(where: {
                    Self.normalizedTitle($0.displayTitle ?? "") == normalizedTitle
                })?.metadata(kind: kind)
            }
            return try JSONDecoder().decode(TMDBMetadataPayload.self, from: response.data)
                .metadata(kind: kind)
        } catch {
            throw AppError.decoding(error.localizedDescription)
        }
    }

    private func titleMetadata(
        imdbID: String,
        kind: MediaKind,
        accessToken: String,
        language: String
    ) async throws -> TrendingTitle? {
        guard !accessToken.isEmpty else { throw TMDBError.missingAccessToken }
        var components = URLComponents(string: "https://api.themoviedb.org/3/find/\(imdbID)")
        components?.queryItems = [
            URLQueryItem(name: "external_source", value: "imdb_id"),
            URLQueryItem(name: "language", value: language),
        ]
        guard let url = components?.url else { throw AppError.invalidURL }

        let response = try await client.data(for: authorizedRequest(
            url: url,
            accessToken: accessToken
        ))
        do {
            return try JSONDecoder().decode(TMDBFindResponse.self, from: response.data)
                .metadata(kind: kind)
        } catch {
            throw AppError.decoding(error.localizedDescription)
        }
    }

    private static func normalizedTitle(_ title: String) -> String {
        title.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }

    private static func isIMDbTitleID(_ value: String) -> Bool {
        value.count > 2 && value.hasPrefix("tt") && value.dropFirst(2).allSatisfy(\.isNumber)
    }

    private static func imageLanguageCode(from language: String) -> String {
        let identifier = language.replacingOccurrences(of: "_", with: "-")
        return identifier.split(separator: "-").first.map(String.init) ?? "en"
    }

    private static func logoLookupCacheURL(
        tmdbID: Int,
        kind: MediaKind,
        language: String
    ) throws -> URL {
        var components = URLComponents()
        components.scheme = "tmdb-logo"
        components.host = kind.rawValue
        components.path = "/\(tmdbID)"
        components.queryItems = [URLQueryItem(name: "language", value: language)]
        guard let url = components.url else { throw AppError.invalidURL }
        return url
    }
}

actor TMDBImageCache {
    static let threeDays: TimeInterval = 3 * 24 * 60 * 60

    private let directoryURL: URL
    private let lifetime: TimeInterval
    private let fileManager: FileManager

    init(
        directoryURL: URL? = nil,
        lifetime: TimeInterval = TMDBImageCache.threeDays,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("TMDBImages", isDirectory: true)
        self.lifetime = lifetime
        self.fileManager = fileManager
    }

    func data(for remoteURL: URL, now: Date = Date()) -> Data? {
        let localURL = fileURL(for: remoteURL)
        guard let modificationDate = try? localURL.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate else {
            return nil
        }
        guard now.timeIntervalSince(modificationDate) <= lifetime else {
            try? fileManager.removeItem(at: localURL)
            return nil
        }
        return try? Data(contentsOf: localURL)
    }

    func store(_ data: Data, for remoteURL: URL, now: Date = Date()) {
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let localURL = fileURL(for: remoteURL)
            try data.write(to: localURL, options: .atomic)
            try fileManager.setAttributes(
                [.modificationDate: now],
                ofItemAtPath: localURL.path
            )
        } catch {
            // A cache write must never prevent artwork from being displayed.
        }
    }

    func removeData(for remoteURL: URL) {
        try? fileManager.removeItem(at: fileURL(for: remoteURL))
    }

    func removeExpiredEntries(now: Date = Date()) {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for file in files where file.pathExtension == "tmdb-image" {
            guard let modificationDate = try? file.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate,
                  now.timeIntervalSince(modificationDate) > lifetime else { continue }
            try? fileManager.removeItem(at: file)
        }
    }

    private func fileURL(for remoteURL: URL) -> URL {
        let digest = SHA256.hash(data: Data(remoteURL.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directoryURL
            .appendingPathComponent(digest)
            .appendingPathExtension("tmdb-image")
    }
}

enum TMDBError: LocalizedError, Sendable {
    case missingAccessToken
    case credentialStorage(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingAccessToken:
            "The bundled TMDB access token is unavailable."
        case .credentialStorage(let status):
            "The TMDB credential could not be stored securely (\(status))."
        }
    }
}

struct TMDBCredentialStore: Sendable {
    private let service: String
    private let account = "tmdb-api-read-access-token"

    init(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "BetterStreamflix") {
        service = "\(bundleIdentifier).credentials"
    }

    func read() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw TMDBError.credentialStorage(status)
        }
        return value
    }

    func save(_ value: String) throws {
        try remove()
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw TMDBError.credentialStorage(status) }
    }

    func remove() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TMDBError.credentialStorage(status)
        }
    }
}

private struct TMDBTrendingResponse: Decodable, Sendable {
    let results: [TMDBTrendingResult]
    let page: Int?
    let totalPages: Int?

    enum CodingKeys: String, CodingKey {
        case results, page
        case totalPages = "total_pages"
    }
}

private struct TMDBArtworkPayload: Decodable, Sendable {
    let posterPath: String?
    let backdropPath: String?

    enum CodingKeys: String, CodingKey {
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
    }

    var artwork: TMDBArtwork {
        TMDBArtwork(
            posterURL: posterPath.flatMap { Self.imageURL(path: $0) },
            backdropURL: backdropPath.flatMap { Self.imageURL(path: $0) }
        )
    }

    private static func imageURL(path: String) -> URL? {
        URL(string: "https://image.tmdb.org/t/p/original\(path)")
    }
}

private struct TMDBImagesPayload: Decodable, Sendable {
    let logos: [TMDBLogoPayload]

    func preferredLogoURL(language: String) -> URL? {
        logos
            .enumerated()
            .sorted { lhs, rhs in
                let lhsRank = Self.languageRank(lhs.element.languageCode, preferred: language)
                let rhsRank = Self.languageRank(rhs.element.languageCode, preferred: language)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                if lhs.element.voteAverage != rhs.element.voteAverage {
                    return lhs.element.voteAverage > rhs.element.voteAverage
                }
                if lhs.element.width != rhs.element.width {
                    return lhs.element.width > rhs.element.width
                }
                return lhs.offset < rhs.offset
            }
            .first?
            .element
            .url
    }

    private static func languageRank(_ language: String?, preferred: String) -> Int {
        if language == preferred { return 0 }
        if language == "en" { return 1 }
        if language == nil { return 2 }
        return 3
    }
}

private struct TMDBLogoPayload: Decodable, Sendable {
    let filePath: String
    let languageCode: String?
    let voteAverage: Double
    let width: Int

    enum CodingKeys: String, CodingKey {
        case width
        case filePath = "file_path"
        case languageCode = "iso_639_1"
        case voteAverage = "vote_average"
    }

    var url: URL? {
        URL(string: "https://image.tmdb.org/t/p/original\(filePath)")
    }
}

private struct TMDBArtworkSearchResponse: Decodable, Sendable {
    let results: [TMDBArtworkSearchResult]
}

private struct TMDBArtworkSearchResult: Decodable, Sendable {
    let title: String?
    let name: String?
    let posterPath: String?
    let backdropPath: String?

    enum CodingKeys: String, CodingKey {
        case title, name
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
    }

    var artwork: TMDBArtwork {
        TMDBArtwork(
            posterURL: posterPath.flatMap { imageURL(path: $0) },
            backdropURL: backdropPath.flatMap { imageURL(path: $0) }
        )
    }

    private func imageURL(path: String) -> URL? {
        URL(string: "https://image.tmdb.org/t/p/original\(path)")
    }
}

private struct TMDBMetadataSearchResponse: Decodable, Sendable {
    let results: [TMDBMetadataPayload]
}

private struct TMDBFindResponse: Decodable, Sendable {
    let movieResults: [TMDBMetadataPayload]
    let tvResults: [TMDBMetadataPayload]

    enum CodingKeys: String, CodingKey {
        case movieResults = "movie_results"
        case tvResults = "tv_results"
    }

    func metadata(kind: MediaKind) -> TrendingTitle? {
        let results = kind == .movie ? movieResults : tvResults
        return results.lazy.compactMap { $0.metadata(kind: kind) }.first
    }
}

private struct TMDBMetadataPayload: Decodable, Sendable {
    struct Genre: Decodable, Sendable {
        let id: Int
        let name: String
    }

    let id: Int
    let title: String?
    let name: String?
    let originalTitle: String?
    let originalName: String?
    let overview: String?
    let releaseDate: String?
    let firstAirDate: String?
    let voteAverage: Double?
    let genreIDs: [Int]?
    let genres: [Genre]?
    let posterPath: String?
    let backdropPath: String?
    let adult: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, name, overview, genres, adult
        case originalTitle = "original_title"
        case originalName = "original_name"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
        case genreIDs = "genre_ids"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
    }

    var displayTitle: String? { title ?? name }

    func metadata(kind: MediaKind) -> TrendingTitle? {
        guard adult != true, let displayTitle else { return nil }
        let names = genres?.map(\.name)
            ?? (genreIDs ?? []).compactMap { TMDBGenres.names[$0] }
        var result = TrendingTitle(
            id: id,
            kind: kind,
            title: displayTitle,
            overview: overview ?? "",
            releaseDate: releaseDate ?? firstAirDate,
            rating: voteAverage,
            genreNames: names,
            posterURL: posterPath.flatMap(Self.imageURL),
            backdropURL: backdropPath.flatMap(Self.imageURL)
        )
        result.originalTitle = originalTitle ?? originalName
        return result
    }

    private static func imageURL(path: String) -> URL? {
        URL(string: "https://image.tmdb.org/t/p/original\(path)")
    }
}

private struct TMDBDetailsPayload: Decodable, Sendable {
    struct Genre: Decodable, Sendable {
        let id: Int
        let name: String
    }

    struct Season: Decodable, Sendable {
        let id: Int
        let name: String?
        let seasonNumber: Int
        let episodeCount: Int?
        let posterPath: String?

        enum CodingKeys: String, CodingKey {
            case id, name
            case seasonNumber = "season_number"
            case episodeCount = "episode_count"
            case posterPath = "poster_path"
        }
    }

    struct ExternalIDs: Decodable, Sendable {
        let imdbID: String?

        enum CodingKeys: String, CodingKey { case imdbID = "imdb_id" }
    }

    struct Credits: Decodable, Sendable {
        struct Person: Decodable, Sendable {
            let id: Int
            let name: String
            let profilePath: String?

            enum CodingKeys: String, CodingKey {
                case id, name
                case profilePath = "profile_path"
            }
        }
        let cast: [Person]
    }

    let id: Int
    let title: String?
    let name: String?
    let originalTitle: String?
    let originalName: String?
    let overview: String?
    let releaseDate: String?
    let firstAirDate: String?
    let voteAverage: Double?
    let runtime: Int?
    let episodeRunTime: [Int]?
    let imdbID: String?
    let externalIDs: ExternalIDs?
    let posterPath: String?
    let backdropPath: String?
    let genres: [Genre]
    let seasons: [Season]?
    let credits: Credits?

    enum CodingKeys: String, CodingKey {
        case id, title, name, overview, runtime, genres, seasons, credits
        case originalTitle = "original_title"
        case originalName = "original_name"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
        case episodeRunTime = "episode_run_time"
        case imdbID = "imdb_id"
        case externalIDs = "external_ids"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
    }

    func mediaItem(replacing item: MediaItem) -> MediaItem {
        MediaItem(
            id: item.id,
            providerID: item.providerID,
            kind: item.kind,
            title: title ?? name ?? item.title,
            originalTitle: originalTitle ?? originalName ?? item.originalTitle,
            overview: overview?.isEmpty == false ? overview : nil,
            releaseDate: releaseDate ?? firstAirDate,
            rating: voteAverage,
            quality: item.quality,
            runtimeMinutes: runtime ?? episodeRunTime?.first,
            imdbID: imdbID ?? externalIDs?.imdbID ?? item.imdbID,
            tmdbID: id,
            posterURL: posterPath.flatMap(Self.imageURL) ?? item.posterURL,
            backdropURL: backdropPath.flatMap(Self.imageURL) ?? item.backdropURL,
            genres: genres.map { MediaGenre(id: "tmdb-\(id)-genre-\($0.id)", name: $0.name) },
            cast: (credits?.cast ?? []).prefix(20).map {
                CastMember(
                    id: "tmdb-person-\($0.id)",
                    name: $0.name,
                    imageURL: $0.profilePath.flatMap(Self.imageURL)
                )
            },
            seasons: (seasons ?? [])
                .filter { ($0.episodeCount ?? 1) > 0 }
                .map {
                    MediaSeason(
                        id: "\(item.id)/tmdb-season-\($0.seasonNumber)",
                        number: $0.seasonNumber,
                        title: $0.name,
                        posterURL: $0.posterPath.flatMap(Self.imageURL)
                    )
                }
        )
    }

    private static func imageURL(path: String) -> URL? {
        URL(string: "https://image.tmdb.org/t/p/original\(path)")
    }
}

private struct TMDBSeasonPayload: Decodable, Sendable {
    let episodes: [Episode]

    struct Episode: Decodable, Sendable {
        let id: Int
        let name: String?
        let overview: String?
        let seasonNumber: Int?
        let episodeNumber: Int
        let airDate: String?
        let stillPath: String?

        enum CodingKeys: String, CodingKey {
            case id, name, overview
            case seasonNumber = "season_number"
            case episodeNumber = "episode_number"
            case airDate = "air_date"
            case stillPath = "still_path"
        }

        func hasAired(asOf date: Date, calendar: Calendar = .current) -> Bool {
            guard let airDate, airDate.count == 10 else { return false }
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day else { return false }
            let currentDate = String(format: "%04d-%02d-%02d", year, month, day)
            return airDate <= currentDate
        }

        func mediaEpisode(show: MediaItem, fallbackSeason: Int) -> MediaEpisode {
            let season = seasonNumber ?? fallbackSeason
            return MediaEpisode(
                id: "\(show.id)/tmdb-s\(season)e\(episodeNumber)",
                providerID: show.providerID,
                showID: show.id,
                seasonNumber: season,
                number: episodeNumber,
                title: name,
                overview: overview?.isEmpty == false ? overview : nil,
                posterURL: stillPath.flatMap {
                    URL(string: "https://image.tmdb.org/t/p/original\($0)")
                }
            )
        }
    }
}

private struct TMDBTrendingResult: Decodable, Sendable {
    let id: Int
    let mediaType: String?
    let title: String?
    let name: String?
    let originalTitle: String?
    let originalName: String?
    let overview: String?
    let releaseDate: String?
    let firstAirDate: String?
    let voteAverage: Double?
    let genreIDs: [Int]?
    let posterPath: String?
    let backdropPath: String?
    let adult: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, name, overview, adult
        case originalTitle = "original_title"
        case originalName = "original_name"
        case mediaType = "media_type"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
        case genreIDs = "genre_ids"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
    }

    func trendingTitle(fallbackKind: MediaKind?) -> TrendingTitle? {
        guard adult != true,
              let kind = mediaType.flatMap(MediaKind.init(tmdbMediaType:)) ?? fallbackKind,
              let displayTitle = title ?? name else { return nil }

        var result = TrendingTitle(
            id: id,
            kind: kind,
            title: displayTitle,
            overview: overview ?? "",
            releaseDate: releaseDate ?? firstAirDate,
            rating: voteAverage,
            genreNames: (genreIDs ?? []).compactMap { TMDBGenres.names[$0] },
            posterURL: posterPath.flatMap { imageURL(path: $0, size: "original") },
            backdropURL: backdropPath.flatMap { imageURL(path: $0, size: "original") }
        )
        result.originalTitle = originalTitle ?? originalName
        return result
    }

    private func imageURL(path: String, size: String) -> URL? {
        URL(string: "https://image.tmdb.org/t/p/\(size)\(path)")
    }

}

private enum TMDBGenres {
    static let names: [Int: String] = [
        12: "Adventure", 14: "Fantasy", 16: "Animation", 18: "Drama",
        27: "Horror", 28: "Action", 35: "Comedy", 36: "History",
        37: "Western", 53: "Thriller", 80: "Crime", 99: "Documentary",
        878: "Sci-Fi", 9648: "Mystery", 10402: "Music", 10749: "Romance",
        10751: "Family", 10752: "War", 10759: "Action & Adventure",
        10762: "Kids", 10763: "News", 10764: "Reality", 10765: "Sci-Fi & Fantasy",
        10766: "Soap", 10767: "Talk", 10768: "War & Politics",
    ]
}

private extension MediaKind {
    init?(tmdbMediaType: String) {
        switch tmdbMediaType {
        case "movie": self = .movie
        case "tv": self = .series
        default: return nil
        }
    }
}
