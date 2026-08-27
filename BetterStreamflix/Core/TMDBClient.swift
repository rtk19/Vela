import CryptoKit
import Foundation
import Security

struct TrendingTitle: Identifiable, Hashable, Sendable {
    let id: Int
    let kind: MediaKind
    let title: String
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

    var heroURL: URL? { posterURL ?? backdropURL }
}

enum TMDBCollection: Identifiable, Hashable, Sendable {
    case trending(MediaKind)
    case topToday(MediaKind)
    case genre(kind: MediaKind, id: Int, name: String)

    var id: String {
        switch self {
        case .trending(let kind): "trending-\(kind.rawValue)"
        case .topToday(let kind): "top-today-\(kind.rawValue)"
        case .genre(let kind, let id, _): "genre-\(kind.rawValue)-\(id)"
        }
    }

    var title: String {
        switch self {
        case .trending(.movie): "Trending Movies"
        case .trending(.series): "Trending Shows"
        case .topToday(.movie): "Top 10 Movies Today"
        case .topToday(.series): "Top 10 Shows Today"
        case .genre(_, _, let name): name
        }
    }

    var kind: MediaKind {
        switch self {
        case .trending(let kind), .topToday(let kind), .genre(let kind, _, _): kind
        }
    }

    static func catalogSections(for kind: MediaKind) -> [TMDBCollection] {
        let genres: [(Int, String)] = kind == .movie
            ? [(28, "Action"), (12, "Adventure"), (16, "Animation"), (35, "Comedy"),
               (80, "Crime"), (18, "Drama"), (27, "Horror"), (878, "Sci-Fi"), (53, "Thriller")]
            : [(10759, "Action & Adventure"), (16, "Animation"), (35, "Comedy"), (80, "Crime"),
               (99, "Documentary"), (18, "Drama"), (10751, "Family"), (9648, "Mystery"),
               (10765, "Sci-Fi & Fantasy")]
        return [.trending(kind)]
            + genres.map { .genre(kind: kind, id: $0.0, name: $0.1) }
    }
}

actor TMDBClient {
    private let client: any HTTPClientProtocol
    private let imageCache: TMDBImageCache

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
        guard let url = try await artwork(
            for: item,
            accessToken: accessToken,
            language: language
        )?.heroURL else { return nil }
        if let cachedData = await imageCache.data(for: url) {
            return cachedData
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let data = try await client.data(for: request).data
        await imageCache.store(data, for: url)
        return data
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

private struct TMDBTrendingResult: Decodable, Sendable {
    let id: Int
    let mediaType: String?
    let title: String?
    let name: String?
    let overview: String
    let releaseDate: String?
    let firstAirDate: String?
    let voteAverage: Double?
    let genreIDs: [Int]
    let posterPath: String?
    let backdropPath: String?
    let adult: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, name, overview, adult
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
              posterPath != nil || backdropPath != nil,
              let kind = mediaType.flatMap(MediaKind.init(tmdbMediaType:)) ?? fallbackKind,
              let displayTitle = title ?? name else { return nil }

        return TrendingTitle(
            id: id,
            kind: kind,
            title: displayTitle,
            overview: overview,
            releaseDate: releaseDate ?? firstAirDate,
            rating: voteAverage,
            genreNames: genreIDs.compactMap { Self.genreNames[$0] },
            posterURL: posterPath.flatMap { imageURL(path: $0, size: "original") },
            backdropURL: backdropPath.flatMap { imageURL(path: $0, size: "original") }
        )
    }

    private func imageURL(path: String, size: String) -> URL? {
        URL(string: "https://image.tmdb.org/t/p/\(size)\(path)")
    }

    private static let genreNames: [Int: String] = [
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
