import Foundation
import Testing
@testable import BetterStreamflix

@Suite("TMDB trending client")
struct TMDBClientTests {
    @Test("Maps movies and TV shows and omits unsupported results")
    func mapsTrendingTitles() async throws {
        let data = Data(
            """
            {
              "results": [
                {
                  "id": 101,
                  "media_type": "movie",
                  "title": "Example Movie",
                  "overview": "A movie overview.",
                  "release_date": "2026-08-01",
                  "vote_average": 8.2,
                  "genre_ids": [28, 878],
                  "poster_path": "/poster.jpg",
                  "backdrop_path": "/backdrop.jpg",
                  "adult": false
                },
                {
                  "id": 202,
                  "media_type": "tv",
                  "name": "Example Series",
                  "overview": "A series overview.",
                  "first_air_date": "2025-02-03",
                  "vote_average": 7.6,
                  "genre_ids": [18],
                  "poster_path": null,
                  "backdrop_path": "/series.jpg",
                  "adult": false
                },
                {
                  "id": 303,
                  "media_type": "person",
                  "name": "A Person",
                  "overview": "",
                  "genre_ids": [],
                  "backdrop_path": "/person.jpg"
                }
              ]
            }
            """.utf8
        )
        let transport = RecordingTMDBTransport(data: data)
        let client = TMDBClient(client: transport)

        let titles = try await client.trending(accessToken: "secret-token", language: "en-US")

        #expect(titles.count == 2)
        #expect(titles[0].title == "Example Movie")
        #expect(titles[0].kind == .movie)
        #expect(titles[0].genreNames == ["Action", "Sci-Fi"])
        #expect(titles[0].posterURL?.absoluteString == "https://image.tmdb.org/t/p/original/poster.jpg")
        #expect(titles[0].backdropURL?.absoluteString == "https://image.tmdb.org/t/p/original/backdrop.jpg")
        #expect(titles[1].title == "Example Series")
        #expect(titles[1].kind == .series)
        #expect(titles[1].year == "2025")

        let request = await transport.lastRequest
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
        #expect(request?.url?.query?.contains("language=en-US") == true)
    }

    @Test("Requires an API Read Access Token")
    func requiresToken() async {
        let transport = RecordingTMDBTransport(data: Data())
        let client = TMDBClient(client: transport)

        await #expect(throws: TMDBError.self) {
            _ = try await client.trending(accessToken: "")
        }
    }

    @Test("Builds typed trending and genre collection requests")
    func collectionRequests() async throws {
        let data = Data(
            """
            {
              "page": 2,
              "total_pages": 8,
              "results": [{
                "id": 404,
                "name": "Example Drama",
                "overview": "A dramatic series.",
                "first_air_date": "2026-04-05",
                "vote_average": 8.0,
                "genre_ids": [18],
                "poster_path": "/drama.jpg",
                "backdrop_path": null,
                "adult": false
              }]
            }
            """.utf8
        )
        let transport = RecordingTMDBTransport(data: data)
        let client = TMDBClient(client: transport)
        let collection = TMDBCollection.genre(kind: .series, id: 18, name: "Drama")

        let result = try await client.titles(
            in: collection,
            accessToken: "secret-token",
            language: "en-US",
            page: 2
        )

        #expect(result.page == 2)
        #expect(result.totalPages == 8)
        #expect(result.titles.first?.kind == .series)
        #expect(result.titles.first?.title == "Example Drama")
        let request = await transport.lastRequest
        #expect(request?.url?.path == "/3/discover/tv")
        #expect(request?.url?.query?.contains("with_genres=18") == true)
        #expect(request?.url?.query?.contains("page=2") == true)
    }

    @Test("Loads original-resolution artwork by TMDB ID")
    func artworkByIdentifier() async throws {
        let transport = RecordingTMDBTransport(data: Data(
            """
            {
              "poster_path": "/high-quality-poster.jpg",
              "backdrop_path": "/high-quality-backdrop.jpg"
            }
            """.utf8
        ))
        let client = TMDBClient(client: transport)
        let item = MediaItem(
            id: "provider-title",
            providerID: "provider",
            kind: .series,
            title: "Example Series",
            tmdbID: 202
        )

        let artwork = try await client.artwork(for: item, accessToken: "secret-token")

        #expect(artwork?.posterURL?.absoluteString == "https://image.tmdb.org/t/p/original/high-quality-poster.jpg")
        #expect(artwork?.backdropURL?.absoluteString == "https://image.tmdb.org/t/p/original/high-quality-backdrop.jpg")
        let request = await transport.lastRequest
        #expect(request?.url?.path == "/3/tv/202")
    }

    @Test("Searches TMDB for provider titles that have no TMDB ID")
    func artworkSearchFallback() async throws {
        let transport = RecordingTMDBTransport(data: Data(
            """
            {
              "results": [{
                "name": "Example Series",
                "poster_path": "/search-poster.jpg",
                "backdrop_path": null
              }]
            }
            """.utf8
        ))
        let client = TMDBClient(client: transport)
        let item = MediaItem(
            id: "provider-title",
            providerID: "provider",
            kind: .series,
            title: "Example Series",
            releaseDate: "2025-03-04"
        )

        let artwork = try await client.artwork(for: item, accessToken: "secret-token")

        #expect(artwork?.heroURL?.absoluteString == "https://image.tmdb.org/t/p/original/search-poster.jpg")
        let request = await transport.lastRequest
        #expect(request?.url?.path == "/3/search/tv")
        #expect(request?.url?.query?.contains("query=Example%20Series") == true)
        #expect(request?.url?.query?.contains("first_air_date_year=2025") == true)
    }

    @Test("Rejects artwork from a differently named TMDB search result")
    func artworkSearchRejectsDifferentTitle() async throws {
        let transport = RecordingTMDBTransport(data: Data(
            """
            {
              "results": [{
                "name": "Neuro: Supernatural Detective",
                "poster_path": "/wrong-series.jpg",
                "backdrop_path": null
              }]
            }
            """.utf8
        ))
        let client = TMDBClient(client: transport)
        let item = MediaItem(
            id: "supernatural",
            providerID: "provider",
            kind: .series,
            title: "Supernatural",
            releaseDate: "2007"
        )

        let artwork = try await client.artwork(for: item, accessToken: "secret-token")

        #expect(artwork == nil)
    }

    @Test("Caches TMDB images for three days and deletes expired files")
    func imageCacheExpiration() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = TMDBImageCache(directoryURL: directory)
        let remoteURL = try #require(URL(string: "https://image.tmdb.org/t/p/original/hero.jpg"))
        let imageData = Data("cached-image".utf8)
        let loadedAt = Date(timeIntervalSince1970: 1_000_000)

        await cache.store(imageData, for: remoteURL, now: loadedAt)

        let validData = await cache.data(
            for: remoteURL,
            now: loadedAt.addingTimeInterval(TMDBImageCache.threeDays - 1)
        )
        #expect(validData == imageData)

        let expiredData = await cache.data(
            for: remoteURL,
            now: loadedAt.addingTimeInterval(TMDBImageCache.threeDays + 1)
        )
        #expect(expiredData == nil)
        let cachedFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(cachedFiles.isEmpty)
    }
}

private actor RecordingTMDBTransport: HTTPClientProtocol {
    private let data: Data
    private(set) var lastRequest: URLRequest?

    init(data: Data) {
        self.data = data
    }

    func data(for request: URLRequest) async throws -> HTTPResponse {
        lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return HTTPResponse(data: data, response: response)
    }
}
