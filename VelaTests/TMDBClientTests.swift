import Foundation
import Testing
@testable import Vela

private let decodableTestImageData = Data(base64Encoded:
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)!

@Suite("TMDB trending client")
struct TMDBClientTests {
    @Test("Movie and series catalogs omit Top 10 Today")
    func catalogsOmitTopToday() {
        for kind in [MediaKind.movie, .series] {
            let sections = TMDBCollection.catalogSections(for: kind)

            #expect(!sections.contains(.topToday(kind)))
        }
    }

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

    @Test("Builds a complete TMDB series detail page")
    func seriesDetails() async throws {
        let transport = RecordingTMDBTransport(data: Data(
            """
            {
              "id": 202,
              "name": "TMDB Series",
              "overview": "Authoritative synopsis.",
              "first_air_date": "2024-05-08",
              "vote_average": 8.1,
              "episode_run_time": [52],
              "external_ids": {"imdb_id": "tt1234567"},
              "genres": [{"id": 18, "name": "Drama"}],
              "poster_path": "/poster.jpg",
              "backdrop_path": "/backdrop.jpg",
              "seasons": [
                {"id": 10, "name": "Specials", "season_number": 0, "episode_count": 0, "poster_path": null},
                {"id": 11, "name": "Season 1", "season_number": 1, "episode_count": 8, "poster_path": "/season.jpg"}
              ],
              "credits": {"cast": [{"id": 99, "name": "Example Actor", "profile_path": "/actor.jpg"}]}
            }
            """.utf8
        ))
        let client = TMDBClient(client: transport)
        let summary = MediaItem.tmdbCatalogItem(from: TrendingTitle(
            id: 202,
            kind: .series,
            title: "Summary Name",
            overview: "",
            releaseDate: nil,
            rating: nil,
            genreNames: [],
            posterURL: nil,
            backdropURL: nil
        ))

        let details = try await client.details(for: summary, accessToken: "secret-token")

        #expect(details.id == summary.id)
        #expect(details.providerID == MediaItem.tmdbCatalogProviderID)
        #expect(details.title == "TMDB Series")
        #expect(details.imdbID == "tt1234567")
        #expect(details.runtimeMinutes == 52)
        #expect(details.seasons.map(\.number) == [1])
        #expect(details.seasons.first?.posterURL?.absoluteString.hasSuffix("/season.jpg") == true)
        #expect(details.cast.first?.name == "Example Actor")
        let request = await transport.lastRequest
        #expect(request?.url?.path == "/3/tv/202")
        #expect(request?.url?.query?.contains("append_to_response=external_ids,credits") == true)
    }

    @Test("Loads episode names, synopses and stills from TMDB")
    func seasonEpisodes() async throws {
        let transport = RecordingTMDBTransport(data: Data(
            """
            {
              "episodes": [{
                "id": 701,
                "name": "Pilot",
                "overview": "The story begins.",
                "season_number": 1,
                "episode_number": 1,
                "air_date": "2020-01-01",
                "still_path": "/pilot.jpg"
              }]
            }
            """.utf8
        ))
        let client = TMDBClient(client: transport)
        let show = MediaItem(
            id: "tmdb:tv:202",
            providerID: MediaItem.tmdbCatalogProviderID,
            kind: .series,
            title: "Example",
            tmdbID: 202
        )
        let season = MediaSeason(id: "season-1", number: 1, title: "Season 1", posterURL: nil)

        let episodes = try await client.episodes(
            for: season,
            show: show,
            accessToken: "secret-token"
        )

        #expect(episodes.first?.title == "Pilot")
        #expect(episodes.first?.overview == "The story begins.")
        #expect(episodes.first?.id == "tmdb:tv:202/tmdb-s1e1")
        #expect(episodes.first?.posterURL?.absoluteString.hasSuffix("/pilot.jpg") == true)
        #expect(await transport.lastRequest?.url?.path == "/3/tv/202/season/1")
    }

    @Test("Season episodes include only episodes released by the selected date")
    func seasonEpisodesExcludeUnreleasedEpisodes() async throws {
        let transport = RecordingTMDBTransport(data: Data(
            """
            {
              "episodes": [
                {"id": 701, "name": "Released", "season_number": 1, "episode_number": 1, "air_date": "2026-08-30"},
                {"id": 702, "name": "Today", "season_number": 1, "episode_number": 2, "air_date": "2026-08-31"},
                {"id": 703, "name": "Scheduled", "season_number": 1, "episode_number": 3, "air_date": "2026-09-01"},
                {"id": 704, "name": "Undated", "season_number": 1, "episode_number": 4, "air_date": null}
              ]
            }
            """.utf8
        ))
        let client = TMDBClient(client: transport)
        let show = MediaItem(
            id: "tmdb:tv:202",
            providerID: MediaItem.tmdbCatalogProviderID,
            kind: .series,
            title: "Example",
            tmdbID: 202
        )
        let season = MediaSeason(id: "season-1", number: 1, title: "Season 1", posterURL: nil)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 8, day: 31))!

        let episodes = try await client.episodes(
            for: season,
            show: show,
            accessToken: "secret-token",
            asOf: date
        )

        #expect(episodes.map(\.number) == [1, 2])
    }

    @Test("Search uses TMDB multi search and ignores people")
    func multiSearch() async throws {
        let transport = RecordingTMDBTransport(data: Data(
            """
            {
              "page": 1,
              "total_pages": 1,
              "results": [
                {"id": 1, "media_type": "person", "name": "Someone"},
                {"id": 2, "media_type": "movie", "title": "A Movie", "overview": "", "genre_ids": [], "poster_path": "/movie.jpg", "adult": false}
              ]
            }
            """.utf8
        ))
        let client = TMDBClient(client: transport)

        let result = try await client.search(query: "A Movie", accessToken: "secret-token")

        #expect(result.titles.map(\.title) == ["A Movie"])
        #expect(await transport.lastRequest?.url?.path == "/3/search/multi")
        #expect(await transport.lastRequest?.url?.query?.contains("query=A%20Movie") == true)
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

    @Test("Retries title identity without an incorrect provider year")
    func titleMetadataRetriesWithoutIncorrectYear() async throws {
        let transport = SequencedTMDBTransport(responses: [
            Data(#"{"results":[]}"#.utf8),
            Data(
                """
                {
                  "results": [{
                    "id": 1622,
                    "name": "Supernatural",
                    "overview": "Two brothers hunt supernatural threats.",
                    "first_air_date": "2005-09-13",
                    "vote_average": 8.3,
                    "genre_ids": [18, 9648],
                    "poster_path": "/supernatural.jpg",
                    "adult": false
                  }]
                }
                """.utf8
            ),
        ])
        let client = TMDBClient(client: transport)
        let item = MediaItem(
            id: "provider-supernatural",
            providerID: "provider",
            kind: .series,
            title: "Supernatural",
            releaseDate: "2007"
        )

        let metadata = try await client.titleMetadata(
            for: item,
            accessToken: "secret-token"
        )

        #expect(metadata?.id == 1622)
        #expect(metadata?.releaseDate == "2005-09-13")
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].url?.query?.contains("first_air_date_year=2007") == true)
        #expect(requests[1].url?.query?.contains("first_air_date_year") == false)
        #expect(requests[1].url?.query?.contains("query=Supernatural") == true)
    }

    @Test("Resolves title identity by IMDb ID before using ambiguous metadata")
    func titleMetadataUsesIMDbIdentityFirst() async throws {
        let transport = SequencedTMDBTransport(responses: [
            Data(
                """
                {
                  "movie_results": [],
                  "tv_results": [{
                    "id": 1622,
                    "name": "Supernatural",
                    "overview": "Two brothers hunt supernatural threats.",
                    "first_air_date": "2005-09-13",
                    "vote_average": 8.3,
                    "genre_ids": [18, 9648],
                    "adult": false
                  }]
                }
                """.utf8
            ),
        ])
        let client = TMDBClient(client: transport)
        let item = MediaItem(
            id: "provider-supernatural",
            providerID: "provider",
            kind: .series,
            title: "A localized or incorrect provider title",
            releaseDate: "2007",
            imdbID: "tt0460681"
        )

        let metadata = try await client.titleMetadata(
            for: item,
            accessToken: "secret-token"
        )

        #expect(metadata?.id == 1622)
        #expect(metadata?.title == "Supernatural")
        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests[0].url?.path == "/3/find/tt0460681")
        #expect(requests[0].url?.query?.contains("external_source=imdb_id") == true)
        #expect(requests[0].url?.query?.contains("first_air_date_year") == false)
    }

    @Test("Falls back to exact title search when an IMDb ID is stale")
    func titleMetadataFallsBackFromStaleIMDbIdentity() async throws {
        let transport = SequencedTMDBTransport(responses: [
            Data(#"{"movie_results":[],"tv_results":[]}"#.utf8),
            Data(
                """
                {
                  "results": [{
                    "id": 202,
                    "name": "Example Series",
                    "first_air_date": "2025-03-04",
                    "adult": false
                  }]
                }
                """.utf8
            ),
        ])
        let client = TMDBClient(client: transport)
        let item = MediaItem(
            id: "provider-title",
            providerID: "provider",
            kind: .series,
            title: "Example Series",
            releaseDate: "2025-03-04",
            imdbID: "tt9999999"
        )

        let metadata = try await client.titleMetadata(
            for: item,
            accessToken: "secret-token"
        )

        #expect(metadata?.id == 202)
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].url?.path == "/3/find/tt9999999")
        #expect(requests[1].url?.path == "/3/search/tv")
        #expect(requests[1].url?.query?.contains("first_air_date_year=2025") == true)
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

        let imageData = decodableTestImageData
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

        let imageData = decodableTestImageData
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

    @Test("Hero artwork matches the carousel poster and falls back when it is invalid")
    func heroArtworkFallback() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let transport = SequencedTMDBTransport(responses: [
            Data("not-an-image".utf8),
            decodableTestImageData,
        ])
        let client = TMDBClient(
            client: transport,
            imageCache: TMDBImageCache(directoryURL: directory)
        )
        let backdropURL = try #require(URL(
            string: "https://image.tmdb.org/t/p/original/backdrop.jpg"
        ))
        let posterURL = try #require(URL(
            string: "https://image.tmdb.org/t/p/original/poster.jpg"
        ))
        let item = MediaItem(
            id: "provider-title",
            providerID: "provider",
            kind: .series,
            title: "Example Series",
            tmdbID: 404,
            posterURL: posterURL,
            backdropURL: backdropURL
        )

        let data = try await client.heroArtworkData(for: item, accessToken: "secret-token")
        let requests = await transport.requests

        #expect(data == decodableTestImageData)
        #expect(requests.map(\.url) == [posterURL, backdropURL])
    }

    @Test("An invalid cached response is evicted and downloaded again")
    func invalidCachedImageIsReplaced() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = TMDBImageCache(directoryURL: directory)
        let remoteURL = try #require(URL(
            string: "https://image.tmdb.org/t/p/original/recovered.jpg"
        ))
        await cache.store(Data("not-an-image".utf8), for: remoteURL)
        let transport = RecordingTMDBTransport(data: decodableTestImageData)
        let client = TMDBClient(client: transport, imageCache: cache)

        let data = try await client.imageData(for: remoteURL)

        #expect(data == decodableTestImageData)
        #expect(await transport.requestCount == 1)
        #expect(await cache.data(for: remoteURL) == decodableTestImageData)
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
              "name": "Vela 1.2.0",
              "body": "## Changes\\n\\n- Added update checks\\n- Fixed playback",
              "html_url": "https://github.com/rtk19/Vela/releases/tag/v1.2.0"
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

private actor SequencedTMDBTransport: HTTPClientProtocol {
    private var responses: [Data]
    private(set) var requests: [URLRequest] = []

    init(responses: [Data]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw AppError.invalidResponse }
        let data = responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return HTTPResponse(data: data, response: response)
    }
}
