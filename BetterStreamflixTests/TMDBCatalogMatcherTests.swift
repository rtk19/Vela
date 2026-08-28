import Foundation
import Testing
@testable import BetterStreamflix

@Suite("TMDB catalog identity matching")
struct TMDBCatalogMatcherTests {
    @Test("Rejects a same-name title with a different TMDB ID")
    func rejectsWrongIdentifier() async throws {
        let wrongMovie = media(title: "Obsession", tmdbID: 999)
        let provider = MatcherProvider(searchPages: [1: [wrongMovie]])

        let result = try await TMDBCatalogMatcher.resolve(
            tmdbTitle(id: 123, title: "Obsession"),
            using: provider
        )

        #expect(result == nil)
    }

    @Test("Verifies detail metadata when search results omit the TMDB ID")
    func verifiesMissingIdentifierFromDetails() async throws {
        let summary = media(id: "correct", title: "Supergirl", tmdbID: nil)
        let verifiedDetails = media(id: "correct", title: "Supergirl", tmdbID: 456)
        let provider = MatcherProvider(
            searchPages: [1: [summary]],
            detailsByID: [summary.id: verifiedDetails]
        )

        let result = try await TMDBCatalogMatcher.resolve(
            tmdbTitle(id: 456, title: "Supergirl"),
            using: provider
        )

        #expect(result?.tmdbID == 456)
        #expect(result?.id == "correct")
    }

    @Test("Uses TMDB display metadata while preserving provider quality")
    func appliesTMDBMetadataAndPreservesQuality() async throws {
        let providerItem = MediaItem(
            id: "dark-matter",
            providerID: "matcher",
            kind: .series,
            title: "Provider Title",
            overview: "Provider synopsis",
            releaseDate: "2026",
            rating: 8.0,
            quality: "HD",
            tmdbID: 456,
            posterURL: URL(string: "https://provider.example/provider-poster.jpg")
        )
        let provider = MatcherProvider(searchPages: [1: [providerItem]])
        let tmdb = TrendingTitle(
            id: 456,
            kind: .series,
            title: "Dark Matter",
            overview: "TMDB synopsis",
            releaseDate: "2024-05-08",
            rating: 7.8,
            genreNames: ["Sci-Fi & Fantasy"],
            posterURL: URL(string: "https://image.tmdb.org/t/p/original/tmdb-poster.jpg"),
            backdropURL: nil
        )

        let result = try await TMDBCatalogMatcher.resolve(tmdb, using: provider)

        #expect(result?.title == "Dark Matter")
        #expect(result?.overview == "TMDB synopsis")
        #expect(result?.releaseDate == "2024-05-08")
        #expect(result?.rating == 7.8)
        #expect(result?.quality == "HD")
        #expect(result?.posterURL == tmdb.posterURL)
    }

    @Test("TMDB identity gives duplicate media one shared artwork key")
    func sharesArtworkIdentityAcrossProviderCopies() {
        let watchlistCopy = MediaItem(
            id: "provider-dark-matter",
            providerID: "streaming-provider",
            kind: .series,
            title: "Dark Matter",
            tmdbID: 196322,
            posterURL: URL(string: "https://provider.example/dark-matter.jpg")
        )
        let refreshedCopy = MediaItem(
            id: "different-provider-id",
            providerID: "another-provider",
            kind: .series,
            title: "Dark Matter",
            tmdbID: 196322,
            posterURL: URL(string: "https://image.tmdb.org/t/p/original/dark-matter.jpg")
        )

        #expect(watchlistCopy.artworkIdentityKey == refreshedCopy.artworkIdentityKey)
    }

    @MainActor
    @Test("Carries the exact TMDB list snapshot into title details")
    func carriesTMDBSnapshotIntoDetails() async throws {
        let providerItem = MediaItem(
            id: "mutiny",
            providerID: "matcher",
            kind: .movie,
            title: "Mutiny",
            rating: 6.5,
            quality: "HD",
            tmdbID: 1_234
        )
        let provider = MatcherProvider(searchPages: [1: [providerItem]])
        let registry = ProviderRegistry(providers: [provider], selectedProviderID: provider.id)
        let tmdbSnapshot = TrendingTitle(
            id: 1_234,
            kind: .movie,
            title: "Mutiny",
            overview: "TMDB synopsis",
            releaseDate: "2026-01-09",
            rating: 6.4,
            genreNames: ["Action"],
            posterURL: nil,
            backdropURL: nil
        )

        let resolved = await SourceLookupCoordinator().resolve(tmdbSnapshot, registry: registry)

        #expect(resolved?.tmdbMetadata?.rating == 6.4)
        #expect(resolved?.media.rating == 6.4)
        #expect(resolved?.media.quality == "HD")
    }

    private func tmdbTitle(id: Int, title: String) -> TrendingTitle {
        TrendingTitle(
            id: id,
            kind: .movie,
            title: title,
            overview: "",
            releaseDate: nil,
            rating: nil,
            genreNames: [],
            posterURL: nil,
            backdropURL: nil
        )
    }

    private func media(id: String = "candidate", title: String, tmdbID: Int?) -> MediaItem {
        MediaItem(
            id: id,
            providerID: "matcher",
            kind: .movie,
            title: title,
            tmdbID: tmdbID
        )
    }
}

private struct MatcherProvider: MediaProvider {
    let id = "matcher"
    let displayName = "Matcher"
    let languageCode = "en"
    let searchPages: [Int: [MediaItem]]
    let detailsByID: [String: MediaItem]

    init(searchPages: [Int: [MediaItem]], detailsByID: [String: MediaItem] = [:]) {
        self.searchPages = searchPages
        self.detailsByID = detailsByID
    }

    func home() async throws -> [MediaShelf] { [] }
    func movies(page: Int) async throws -> [MediaItem] { [] }
    func series(page: Int) async throws -> [MediaItem] { [] }
    func search(query: String, page: Int) async throws -> [MediaItem] { searchPages[page] ?? [] }
    func details(for item: MediaItem) async throws -> MediaItem { detailsByID[item.id] ?? item }
    func episodes(for season: MediaSeason, show: MediaItem) async throws -> [MediaEpisode] { [] }
    func playbackSource(for request: PlaybackRequest) async throws -> PlaybackSource {
        throw AppError.noStream
    }
}
