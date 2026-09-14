import Foundation

protocol MediaProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var languageCode: String { get }

    func home() async throws -> [MediaShelf]
    func movies(page: Int) async throws -> [MediaItem]
    func series(page: Int) async throws -> [MediaItem]
    func search(query: String, page: Int) async throws -> [MediaItem]
    func details(for item: MediaItem) async throws -> MediaItem
    func episodes(for season: MediaSeason, show: MediaItem) async throws -> [MediaEpisode]
    func playbackSource(for request: PlaybackRequest) async throws -> PlaybackSource
}

actor ProviderRegistry {
    private var providers: [String: any MediaProvider] = [:]
    private(set) var selectedProviderID: String

    init(providers: [any MediaProvider], selectedProviderID: String) {
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        self.selectedProviderID = selectedProviderID
    }

    func register(_ provider: any MediaProvider) {
        providers[provider.id] = provider
    }

    func select(_ id: String) throws {
        guard providers[id] != nil else { throw AppError.providerUnavailable(id) }
        selectedProviderID = id
    }

    func selected() throws -> any MediaProvider {
        guard let provider = providers[selectedProviderID] else {
            throw AppError.providerUnavailable(selectedProviderID)
        }
        return provider
    }

    func provider(id: String) throws -> any MediaProvider {
        guard let provider = providers[id] else { throw AppError.providerUnavailable(id) }
        return provider
    }

    func playbackProviders() -> [any PlaybackProvider] {
        providers.values.sorted { $0.id < $1.id }.map { StreamingCommunityPlaybackProvider(provider: $0) as any PlaybackProvider }
            + [AnimePlaybackProvider(site: .hiAnime), AnimePlaybackProvider(site: .anikoto)]
    }

    func all() -> [any MediaProvider] {
        providers.values.sorted { $0.displayName < $1.displayName }
    }
}
