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

    @Test("Loads authoritative title metadata by TMDB ID")
    func titleMetadataByIdentifier() async throws {
        let transport = RecordingTMDBTransport(data: Data(
            """
            {
              "id": 202,
              "name": "TMDB Series Name",
              "overview": "The TMDB synopsis.",
              "first_air_date": "2024-05-08",
              "vote_average": 7.8,
              "genres": [{"id": 18, "name": "Drama"}],
              "poster_path": "/tmdb-poster.jpg",
              "backdrop_path": "/tmdb-backdrop.jpg",
              "adult": false
            }
            """.utf8
        ))
        let client = TMDBClient(client: transport)
        let item = MediaItem(
            id: "provider-title",
            providerID: "provider",
            kind: .series,
            title: "Provider Series Name",
            tmdbID: 202
        )

        let metadata = try await client.titleMetadata(for: item, accessToken: "secret-token")

        #expect(metadata?.title == "TMDB Series Name")
        #expect(metadata?.overview == "The TMDB synopsis.")
        #expect(metadata?.releaseDate == "2024-05-08")
        #expect(metadata?.year == "2024")
        #expect(metadata?.rating == 7.8)
        #expect(metadata?.genreNames == ["Drama"])
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

    @Test("Loads the preferred-language ClearLogo with English and neutral fallbacks")
    func clearLogoSelection() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = RecordingTMDBTransport(data: Data(
            """
            {
              "logos": [
                {
                  "file_path": "/english-logo.png",
                  "iso_639_1": "en",
                  "vote_average": 9.5,
                  "width": 1200
                },
                {
                  "file_path": "/neutral-logo.png",
                  "iso_639_1": null,
                  "vote_average": 10.0,
                  "width": 1400
                },
                {
                  "file_path": "/hebrew-logo.png",
                  "iso_639_1": "he",
                  "vote_average": 6.0,
                  "width": 900
                }
              ]
            }
            """.utf8
        ))
        let client = TMDBClient(
            client: transport,
            imageCache: TMDBImageCache(directoryURL: directory)
        )

        let logoURL = try await client.logoURL(
            tmdbID: 202,
            kind: .series,
            accessToken: "secret-token",
            language: "he-IL"
        )

        #expect(logoURL?.absoluteString == "https://image.tmdb.org/t/p/original/hebrew-logo.png")
        let recordedRequest = await transport.lastRequest
        let request = try #require(recordedRequest)
        #expect(request.url?.path == "/3/tv/202/images")
        let queryItems = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems
        #expect(queryItems?.first(where: { $0.name == "language" })?.value == "he-IL")
        #expect(queryItems?.first(where: { $0.name == "include_image_language" })?.value == "he,en,null")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")

        let cachedURL = try await client.logoURL(
            tmdbID: 202,
            kind: .series,
            accessToken: "secret-token",
            language: "he-IL"
        )
        #expect(cachedURL == logoURL)
        #expect(await transport.requestCount == 1)
    }

    @Test("Returns no ClearLogo when TMDB has none")
    func missingClearLogo() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = RecordingTMDBTransport(data: Data(#"{"logos":[]}"#.utf8))
        let client = TMDBClient(
            client: transport,
            imageCache: TMDBImageCache(directoryURL: directory)
        )

        let logoURL = try await client.logoURL(
            tmdbID: 101,
            kind: .movie,
            accessToken: "secret-token"
        )

        #expect(logoURL == nil)
        let cachedMissingLogo = try await client.logoURL(
            tmdbID: 101,
            kind: .movie,
            accessToken: "secret-token"
        )
        #expect(cachedMissingLogo == nil)
        #expect(await transport.requestCount == 1)
    }

    @Test("Uses the disk cache and deduplicates concurrent TMDB image downloads")
    func imageDownloadCaching() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let imageData = Data("tmdb-image-data".utf8)
        let transport = RecordingTMDBTransport(data: imageData)
        let client = TMDBClient(
            client: transport,
            imageCache: TMDBImageCache(directoryURL: directory)
        )
        let remoteURL = try #require(URL(
            string: "https://image.tmdb.org/t/p/original/carousel-poster.jpg"
        ))

        async let first = client.imageData(for: remoteURL)
        async let second = client.imageData(for: remoteURL)
        let (firstData, secondData) = try await (first, second)
        let thirdData = try await client.imageData(for: remoteURL)

        #expect(firstData == imageData)
        #expect(secondData == imageData)
        #expect(thirdData == imageData)
        #expect(await transport.requestCount == 1)
    }

    @Test("Uses an existing TMDB poster URL without repeating the artwork lookup")
    func directHeroArtworkCaching() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let imageData = Data("direct-poster-data".utf8)
        let transport = RecordingTMDBTransport(data: imageData)
        let client = TMDBClient(
            client: transport,
            imageCache: TMDBImageCache(directoryURL: directory)
        )
        let posterURL = try #require(URL(
            string: "https://image.tmdb.org/t/p/original/direct-poster.jpg"
        ))
        let item = MediaItem(
            id: "provider-title",
            providerID: "provider",
            kind: .movie,
            title: "Example Movie",
            tmdbID: 404,
            posterURL: posterURL
        )

        let firstData = try await client.heroArtworkData(for: item, accessToken: "secret-token")
        let secondData = try await client.heroArtworkData(for: item, accessToken: "secret-token")
        let lastRequest = await transport.lastRequest
        let requestCount = await transport.requestCount

        #expect(firstData == imageData)
        #expect(secondData == imageData)
        #expect(lastRequest?.url == posterURL)
        #expect(requestCount == 1)
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

@Suite("GitHub release client")
struct GitHubReleaseClientTests {
    @Test("Loads the latest release and preserves its Markdown notes")
    func latestRelease() async throws {
        let transport = RecordingTMDBTransport(data: Data(
            """
            {
              "tag_name": "v1.2.0",
              "name": "BetterStreamflix 1.2.0",
              "body": "## Changes\\n\\n- Added update checks\\n- Fixed playback",
              "html_url": "https://github.com/rtk19/BetterStreamflix-iOS-port/releases/tag/v1.2.0"
            }
            """.utf8
        ))

        let release = try await GitHubReleaseClient(client: transport).latestRelease()

        #expect(release.tagName == "v1.2.0")
        #expect(release.body.contains("## Changes"))
        #expect(release.htmlURL.path.hasSuffix("/releases/tag/v1.2.0"))
        let request = await transport.lastRequest
        #expect(request?.url?.path.hasSuffix("/releases/latest") == true)
        #expect(request?.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
    }

    @Test("Compares version tags numerically")
    func comparesVersions() {
        #expect(GitHubReleaseClient.isNewer(tagName: "v1.2.0", than: "1.1.9"))
        #expect(GitHubReleaseClient.isNewer(tagName: "1.10.0", than: "1.9.9"))
        #expect(!GitHubReleaseClient.isNewer(tagName: "v1.1.2", than: "1.1.2"))
        #expect(!GitHubReleaseClient.isNewer(tagName: "1.1", than: "1.1.0"))
    }

    @Test("A skipped release stays hidden until a newer tag is published")
    func skipsOneRelease() {
        #expect(!GitHubReleaseClient.shouldOfferUpdate(
            tagName: "v1.2.0",
            currentVersion: "1.1.2",
            skippedTagName: "1.2.0"
        ))
        #expect(GitHubReleaseClient.shouldOfferUpdate(
            tagName: "v1.2.1",
            currentVersion: "1.1.2",
            skippedTagName: "v1.2.0"
        ))
        #expect(!GitHubReleaseClient.shouldOfferUpdate(
            tagName: "v1.2.0",
            currentVersion: "1.2.0",
            skippedTagName: ""
        ))
    }

    @Test("Preserves block Markdown structure in release notes")
    func parsesReleaseNotesMarkdown() {
        let blocks = ReleaseNotesMarkdownParser.parse(
            """
            ## Not much

            but keep it **up**!

            - First fix
            - Second fix
            """
        )

        #expect(blocks == [
            .heading(level: 2, text: "Not much"),
            .paragraph("but keep it **up**!"),
            .unorderedItem(indentation: 0, text: "First fix"),
            .unorderedItem(indentation: 0, text: "Second fix"),
        ])
    }
}

private actor RecordingTMDBTransport: HTTPClientProtocol {
    private let data: Data
    private(set) var lastRequest: URLRequest?
    private(set) var requestCount = 0

    init(data: Data) {
        self.data = data
    }

    func data(for request: URLRequest) async throws -> HTTPResponse {
        requestCount += 1
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
