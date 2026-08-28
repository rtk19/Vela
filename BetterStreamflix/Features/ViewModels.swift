import Foundation

enum TMDBCatalogMatcher {
    static func resolve(
        _ title: TrendingTitle,
        using provider: any MediaProvider,
        searchPageLimit: Int = 3
    ) async throws -> MediaItem? {
        for page in 1...max(searchPageLimit, 1) {
            try Task.checkCancellation()
            let results = try await provider.search(query: title.title, page: page)
            guard !results.isEmpty else { break }
            let candidates = results.filter { $0.kind == title.kind }

            if let identifierMatch = candidates.first(where: { $0.tmdbID == title.id }) {
                return identifierMatch.applyingTMDBMetadata(title)
            }

            // Search payloads sometimes omit TMDB metadata. Verify those candidates
            // against their full detail payload before accepting them.
            for candidate in candidates where candidate.tmdbID == nil {
                try Task.checkCancellation()
                do {
                    let details = try await provider.details(for: candidate)
                    if details.kind == title.kind, details.tmdbID == title.id {
                        return details.applyingTMDBMetadata(title)
                    }
                } catch where error.isCancellation {
                    throw error
                } catch {
                    continue
                }
            }
        }
        return nil
    }
}

struct SourceLookupFailure: Identifiable, Equatable, Sendable {
    let id = UUID()
    let title: String
    let message: String
}

struct ResolvedMediaItem: Identifiable, Hashable, Sendable {
    let media: MediaItem
    let tmdbMetadata: TrendingTitle?

    var id: String { "\(media.providerID):\(media.id)" }
}

@MainActor
final class SourceLookupCoordinator: ObservableObject {
    private enum Outcome: Sendable {
        case found(ResolvedMediaItem)
        case failed(String)
        case cancelled
    }

    private enum ArtworkOutcome: Sendable {
        case found(Data?)
        case cancelled
    }

    @Published private(set) var activeTitles: [String: TrendingTitle] = [:]
    @Published private(set) var activeArtworkKeys: Set<String> = []
    @Published private(set) var failure: SourceLookupFailure?

    private var tasks: [String: Task<Outcome, Never>] = [:]
    private var operationIDs: [String: UUID] = [:]
    private var artworkTasks: [String: Task<ArtworkOutcome, Never>] = [:]
    private var artworkOperationIDs: [String: UUID] = [:]
    private var failureDismissTask: Task<Void, Never>?

    var activeKeys: Set<String> { Set(activeTitles.keys) }
    var activeCount: Int { activeTitles.count }

    func resolve(_ title: TrendingTitle, registry: ProviderRegistry) async -> ResolvedMediaItem? {
        let key = title.lookupKey
        guard tasks[key] == nil else { return nil }

        let operationID = UUID()
        let task = Task { () -> Outcome in
            do {
                let provider = try await registry.selected()
                guard let item = try await TMDBCatalogMatcher.resolve(title, using: provider) else {
                    return .failed("\(title.title) (TMDB ID \(title.id)) is not available in the current streaming catalog.")
                }
                try Task.checkCancellation()
                return .found(ResolvedMediaItem(media: item, tmdbMetadata: title))
            } catch where error.isCancellation {
                return .cancelled
            } catch {
                return .failed(error.localizedDescription)
            }
        }

        activeTitles[key] = title
        operationIDs[key] = operationID
        tasks[key] = task

        let outcome = await task.value
        guard operationIDs[key] == operationID else { return nil }
        activeTitles[key] = nil
        operationIDs[key] = nil
        tasks[key] = nil

        switch outcome {
        case .found(let item):
            return item
        case .failed(let message):
            showFailure(message)
            return nil
        case .cancelled:
            return nil
        }
    }

    func resolveArtwork(for item: MediaItem, environment: AppEnvironment) async -> Data? {
        let key = "artwork:\(item.providerID):\(item.id)"
        if let existingTask = artworkTasks[key] {
            if case .found(let artwork) = await existingTask.value { return artwork }
            return nil
        }

        let operationID = UUID()
        let task = Task { () -> ArtworkOutcome in
            do {
                let artwork = try await environment.tmdbHeroArtworkData(for: item)
                try Task.checkCancellation()
                return .found(artwork)
            } catch {
                return .cancelled
            }
        }

        activeArtworkKeys.insert(key)
        artworkOperationIDs[key] = operationID
        artworkTasks[key] = task

        let outcome = await task.value
        guard artworkOperationIDs[key] == operationID else { return nil }
        activeArtworkKeys.remove(key)
        artworkOperationIDs[key] = nil
        artworkTasks[key] = nil

        if case .found(let artwork) = outcome { return artwork }
        return nil
    }

    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        artworkTasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        artworkTasks.removeAll()
        operationIDs.removeAll()
        artworkOperationIDs.removeAll()
        activeTitles.removeAll()
        activeArtworkKeys.removeAll()
    }

    private func showFailure(_ message: String) {
        let value = SourceLookupFailure(title: "Something went wrong", message: message)
        failure = value
        failureDismissTask?.cancel()
        failureDismissTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            guard self?.failure?.id == value.id else { return }
            self?.failure = nil
        }
    }
}

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var shelves: [MediaShelf] = []
    @Published private(set) var trendingTitles: [TrendingTitle] = []
    @Published private(set) var tmdbShelves: [TMDBCollection: [TrendingTitle]] = [:]
    @Published private(set) var carouselAssets = TMDBCarouselAssets()
    @Published private(set) var isLoading = false
    @Published private(set) var isTrendingLoading = false
    @Published var errorMessage: String?
    @Published var trendingMessage: String?

    func load(registry: ProviderRegistry, force: Bool = false) async {
        guard force || shelves.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let provider = try await registry.selected()
            shelves = try await provider.home().filter {
                !$0.title.localizedCaseInsensitiveContains("trending")
            }
        }
        catch where error.isCancellation { }
        catch { errorMessage = error.localizedDescription }
    }

    func loadTrending(environment: AppEnvironment, force: Bool = false) async {
        guard force || trendingTitles.isEmpty else { return }
        isTrendingLoading = true
        defer { isTrendingLoading = false }
        do {
            async let hero = environment.trendingTitles()
            async let movies = environment.tmdbTitles(in: .trending(.movie))
            async let shows = environment.tmdbTitles(in: .trending(.series))
            let (heroTitles, moviePage, showPage) = try await (hero, movies, shows)
            trendingTitles = heroTitles
            tmdbShelves[.trending(.movie)] = moviePage.titles
            tmdbShelves[.trending(.series)] = showPage.titles
            trendingMessage = trendingTitles.isEmpty ? "TMDB did not return any trending titles." : nil
            carouselAssets = await environment.preloadCarouselAssets(for: heroTitles)
        }
        catch where error.isCancellation { }
        catch { trendingMessage = error.localizedDescription }
    }

}

@MainActor
final class TMDBCollectionsViewModel: ObservableObject {
    let collections: [TMDBCollection]
    @Published private(set) var titles: [TMDBCollection: [TrendingTitle]] = [:]
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    init(collections: [TMDBCollection]) {
        self.collections = collections
    }

    func load(environment: AppEnvironment, force: Bool = false) async {
        guard !isLoading, force || titles.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        if force { titles = [:] }
        for collection in collections {
            do {
                titles[collection] = try await environment.tmdbTitles(in: collection).titles
            } catch where error.isCancellation {
                return
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
    }
}

@MainActor
final class TMDBCollectionGridViewModel: ObservableObject {
    @Published private(set) var titles: [TrendingTitle] = []
    @Published private(set) var isLoading = false
    @Published private(set) var canLoadMore = true
    @Published var errorMessage: String?
    private var page = 0

    func loadNext(collection: TMDBCollection, environment: AppEnvironment) async {
        guard !isLoading, canLoadMore else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await environment.tmdbTitles(in: collection, page: page + 1)
            titles.append(contentsOf: result.titles.filter { candidate in
                !titles.contains { $0.id == candidate.id && $0.kind == candidate.kind }
            })
            page = result.page
            canLoadMore = result.page < result.totalPages && !result.titles.isEmpty
        } catch where error.isCancellation { }
        catch { errorMessage = error.localizedDescription }
    }
}

@MainActor
final class CatalogViewModel: ObservableObject {
    @Published private(set) var items: [MediaItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var canLoadMore = true
    @Published var errorMessage: String?
    private var page = 0
    let kind: MediaKind

    init(kind: MediaKind) { self.kind = kind }

    func loadNext(registry: ProviderRegistry) async {
        guard !isLoading, canLoadMore else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let next = page + 1
            let provider = try await registry.selected()
            let result = try await (kind == .movie ? provider.movies(page: next) : provider.series(page: next))
            items.append(contentsOf: result.filter { candidate in !items.contains(where: { $0.id == candidate.id }) })
            page = next
            canLoadMore = !result.isEmpty
        } catch where error.isCancellation { }
        catch { errorMessage = error.localizedDescription }
    }
}

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var results: [MediaItem] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    private var task: Task<Void, Never>?

    func search(registry: ProviderRegistry) {
        task?.cancel()
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { results = []; return }
        task = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            isLoading = true
            defer { isLoading = false }
            do {
                let provider = try await registry.selected()
                results = try await provider.search(query: value, page: 1)
            }
            catch where error.isCancellation { }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

@MainActor
final class DetailsViewModel: ObservableObject {
    @Published private(set) var item: MediaItem
    @Published private(set) var episodes: [String: [MediaEpisode]] = [:]
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    private let tmdbMetadataSnapshot: TrendingTitle?

    init(item: MediaItem, tmdbMetadataSnapshot: TrendingTitle? = nil) {
        self.item = item
        self.tmdbMetadataSnapshot = tmdbMetadataSnapshot
    }

    func load(environment: AppEnvironment, preferredSeasonNumber: Int? = nil) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let provider = try await environment.registry.provider(id: item.providerID)
            let providerItem = try await provider.details(for: item)
            if let tmdbMetadataSnapshot {
                item = providerItem.applyingTMDBMetadata(tmdbMetadataSnapshot)
            } else {
                do {
                    if let metadata = try await environment.tmdbTitleMetadata(for: providerItem) {
                        item = providerItem.applyingTMDBMetadata(metadata)
                    } else {
                        item = providerItem
                    }
                } catch where error.isCancellation {
                    throw error
                } catch {
                    item = providerItem
                    errorMessage = "TMDB metadata could not be loaded: \(error.localizedDescription)"
                }
            }
            if let season = preferredSeasonNumber.flatMap({ preferredNumber in
                item.seasons.first { $0.number == preferredNumber }
            }) ?? item.seasons.first {
                await loadEpisodes(season, registry: environment.registry)
            }
        } catch where error.isCancellation { }
        catch { errorMessage = error.localizedDescription }
    }

    func loadEpisodes(_ season: MediaSeason, registry: ProviderRegistry) async {
        guard episodes[season.id] == nil else { return }
        do {
            let provider = try await registry.provider(id: item.providerID)
            episodes[season.id] = try await provider.episodes(for: season, show: item)
        } catch where error.isCancellation { }
        catch { errorMessage = error.localizedDescription }
    }
}

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published private(set) var source: PlaybackSource?
    @Published private(set) var thirdPartySubtitles: [SubtitleSource] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    @Published private(set) var request: PlaybackRequest

    init(request: PlaybackRequest) { self.request = request }

    func load(
        registry: ProviderRegistry,
        subtitleRegistry: SubtitleProviderRegistry,
        enabledSubtitleProviderIDs: Set<String>,
        force: Bool = false
    ) async {
        guard (source == nil || force), !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let playbackRequest = request
            let media = playbackRequest.media
            let season = playbackRequest.episode.map { String($0.seasonNumber) } ?? "none"
            let episode = playbackRequest.episode.map { String($0.number) } ?? "none"
            let enabledProviders = enabledSubtitleProviderIDs.sorted().joined(separator: ", ")
            SubtitleDiagnostics.logger.info(
                "Preparing subtitle lookup: title=\(media.title, privacy: .public) kind=\(media.kind.rawValue, privacy: .public) imdb=\(media.imdbID ?? "missing", privacy: .public) tmdb=\(media.tmdbID.map(String.init) ?? "missing", privacy: .public) season=\(season, privacy: .public) episode=\(episode, privacy: .public) enabled=[\(enabledProviders, privacy: .public)]"
            )
            let subtitleLookup = playbackRequest.subtitleLookupRequest
            if subtitleLookup == nil {
                SubtitleDiagnostics.logger.error(
                    "Subtitle lookup skipped: missing or invalid IMDb ID"
                )
            }
            let provider = try await registry.provider(id: playbackRequest.media.providerID)
            async let playbackSource = provider.playbackSource(for: playbackRequest)
            async let fetchedSubtitles: [SubtitleSource] = {
                guard let subtitleLookup else { return [] }
                return await subtitleRegistry.subtitles(
                    for: subtitleLookup,
                    fallbackTMDbID: playbackRequest.media.tmdbID,
                    enabledProviderIDs: enabledSubtitleProviderIDs
                )
            }()
            let resolvedSource = try await playbackSource
            let resolvedSubtitles = await fetchedSubtitles
            guard !Task.isCancelled else { return }
            thirdPartySubtitles = resolvedSubtitles
            source = resolvedSource
        } catch where error.isCancellation { }
        catch { errorMessage = error.localizedDescription }
    }

    func play(
        _ request: PlaybackRequest,
        registry: ProviderRegistry,
        subtitleRegistry: SubtitleProviderRegistry,
        enabledSubtitleProviderIDs: Set<String>
    ) async {
        self.request = request
        source = nil
        thirdPartySubtitles = []
        await load(
            registry: registry,
            subtitleRegistry: subtitleRegistry,
            enabledSubtitleProviderIDs: enabledSubtitleProviderIDs,
            force: true
        )
    }
}
