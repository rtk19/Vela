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
