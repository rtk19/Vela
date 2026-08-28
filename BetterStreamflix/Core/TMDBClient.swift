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

struct TMDBCarouselAssets: Sendable {
    var artworkDataByKey: [String: Data] = [:]
    var logoDataByKey: [String: Data] = [:]
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
        let directTMDBURL = [item.posterURL, item.backdropURL]
            .compactMap { $0 }
            .first(where: { $0.host == "image.tmdb.org" })
        let url = if let directTMDBURL {
            directTMDBURL
        } else {
            try await artwork(
                for: item,
                accessToken: accessToken,
                language: language
            )?.heroURL
        }
        guard let url else { return nil }
        return try await imageData(for: url)
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
            return cachedData
        }
        if let existingTask = imageDownloadTasks[url] {
            return try await existingTask.value
        }

        let client = self.client
        let imageCache = self.imageCache
        let task = Task<Data, Error> {
            if let cachedData = await imageCache.data(for: url) {
                return cachedData
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let data = try await client.data(for: request).data
            try Task.checkCancellation()
            await imageCache.store(data, for: url)
            return data
        }
        imageDownloadTasks[url] = task
        defer { imageDownloadTasks[url] = nil }
        // Keep filling the shared disk cache even if the requesting view scrolls
        // away or is dismissed before this download completes.
        return try await task.value
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

    private static func normalizedTitle(_ title: String) -> String {
        title.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
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

private struct TMDBMetadataPayload: Decodable, Sendable {
    struct Genre: Decodable, Sendable {
        let id: Int
        let name: String
    }

    let id: Int
    let title: String?
    let name: String?
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
        return TrendingTitle(
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
    }

    private static func imageURL(path: String) -> URL? {
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
            genreNames: genreIDs.compactMap { TMDBGenres.names[$0] },
            posterURL: posterPath.flatMap { imageURL(path: $0, size: "original") },
            backdropURL: backdropPath.flatMap { imageURL(path: $0, size: "original") }
        )
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
