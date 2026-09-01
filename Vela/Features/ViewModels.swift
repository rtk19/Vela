import Foundation

enum TMDBCatalogMatcher {
    static func resolve(
        _ title: TrendingTitle,
        using provider: any MediaProvider,
        searchPageLimit: Int = 3
    ) async throws -> MediaItem? {
        let queries = [title.originalTitle, title.title]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .reduce(into: [String]()) { values, query in
                guard !query.isEmpty,
                      !values.contains(where: { $0.caseInsensitiveCompare(query) == .orderedSame }) else { return }
                values.append(query)
            }
        for query in queries {
            for page in 1...max(searchPageLimit, 1) {
                try Task.checkCancellation()
                let results = try await provider.search(query: query, page: page)
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
    private var playbackTask: Task<PlaybackSource, Error>?
    private var playbackOperationID: UUID?

    var activeKeys: Set<String> { Set(activeTitles.keys) }
    var activeCount: Int { activeTitles.count }

    func resolve(_ title: TrendingTitle, registry: ProviderRegistry) async -> ResolvedMediaItem? {
        ResolvedMediaItem(media: .tmdbCatalogItem(from: title), tmdbMetadata: title)
    }

    func resolvePlaybackSource(
        for request: PlaybackRequest,
        registry: ProviderRegistry
    ) async throws -> PlaybackSource {
        playbackTask?.cancel()
        let operationID = UUID()
        playbackOperationID = operationID
        let task = Task<PlaybackSource, Error> {
            let provider = try await registry.selected()
            let providerRequest = try await Self.providerRequest(for: request, using: provider)
            try Task.checkCancellation()
            return try await provider.playbackSource(for: providerRequest)
        }
        playbackTask = task
        defer {
            if playbackOperationID == operationID {
                playbackTask = nil
                playbackOperationID = nil
            }
        }
        let source = try await task.value
        guard playbackOperationID == operationID else { throw CancellationError() }
        return source
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
        playbackTask?.cancel()
        playbackTask = nil
        playbackOperationID = nil
    }

    private static func providerRequest(
        for request: PlaybackRequest,
        using provider: any MediaProvider
    ) async throws -> PlaybackRequest {
        let media = request.media
        let title = TrendingTitle(
            id: media.tmdbID ?? -1,
            kind: media.kind,
            title: media.title,
            originalTitle: media.originalTitle,
            overview: media.overview ?? "",
            releaseDate: media.releaseDate,
            rating: media.rating,
            genreNames: media.genres.map(\.name),
            posterURL: media.posterURL,
            backdropURL: media.backdropURL
        )
        guard title.id >= 0,
              let providerSummary = try await TMDBCatalogMatcher.resolve(title, using: provider) else {
            throw AppError.noStream
        }
        try Task.checkCancellation()
        guard media.kind == .series, let episode = request.episode else {
            return PlaybackRequest(media: providerSummary, episode: nil)
        }

        let providerShow = try await provider.details(for: providerSummary)
        guard let providerSeason = providerShow.seasons.first(where: {
            $0.number == episode.seasonNumber
        }) else { throw AppError.noStream }
        let providerEpisodes = try await provider.episodes(for: providerSeason, show: providerShow)
        try Task.checkCancellation()
        guard let providerEpisode = providerEpisodes.first(where: {
            $0.number == episode.number && $0.seasonNumber == episode.seasonNumber
        }) else { throw AppError.noStream }
        return PlaybackRequest(media: providerShow, episode: providerEpisode)
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

    func loadTrending(environment: AppEnvironment, force: Bool = false) async {
        guard force || trendingTitles.isEmpty else { return }
        isTrendingLoading = true
        defer { isTrendingLoading = false }
        do {
            async let hero = environment.trendingTitles()
            await withTaskGroup(of: (TMDBCollection, [TrendingTitle]?).self) { group in
                for collection in TMDBCollection.homeSections {
                    group.addTask {
                        let page = try? await environment.tmdbTitles(
                            in: collection,
                            forceRefresh: force
                        )
                        return (collection, page?.titles)
                    }
                }
                for await (collection, titles) in group {
                    if let titles { tmdbShelves[collection] = titles }
                }
            }
            let heroTitles = try await hero
            trendingTitles = heroTitles
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
        await withTaskGroup(of: (TMDBCollection, [TrendingTitle]?, String?).self) { group in
            for collection in collections {
                group.addTask {
                    do {
                        let page = try await environment.tmdbTitles(
                            in: collection,
                            forceRefresh: force
                        )
                        return (collection, page.titles, nil)
                    } catch where error.isCancellation {
                        return (collection, nil, nil)
                    } catch {
                        return (collection, nil, error.localizedDescription)
                    }
                }
            }
            for await (collection, loadedTitles, message) in group {
                if let loadedTitles { titles[collection] = loadedTitles }
                if errorMessage == nil, let message { errorMessage = message }
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
    private var searchGeneration = 0

    func search(environment: AppEnvironment) {
        task?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        isLoading = false
        errorMessage = nil
        guard !value.isEmpty else {
            results = []
            task = nil
            return
        }
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            guard let self, searchGeneration == generation else { return }
            isLoading = true
            defer {
                if searchGeneration == generation {
                    isLoading = false
                    task = nil
                }
            }
            do {
                let titles = try await environment.tmdbSearch(query: value).titles
                guard searchGeneration == generation else { return }
                results = titles.map {
                    MediaItem.tmdbCatalogItem(from: $0)
                }
            }
            catch where error.isCancellation { }
            catch {
                guard searchGeneration == generation else { return }
                errorMessage = error.localizedDescription
            }
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
            item = try await environment.tmdbDetails(for: item)
            if let season = preferredSeasonNumber.flatMap({ preferredNumber in
                item.seasons.first { $0.number == preferredNumber }
            }) ?? item.seasons.first {
                await loadEpisodes(season, environment: environment)
            }
        } catch where error.isCancellation { }
        catch { errorMessage = error.localizedDescription }
    }

    func loadEpisodes(_ season: MediaSeason, environment: AppEnvironment) async {
        guard episodes[season.id] == nil else { return }
        do {
            episodes[season.id] = try await environment.tmdbEpisodes(for: season, show: item)
        } catch where error.isCancellation { }
        catch { errorMessage = error.localizedDescription }
    }
}

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published private(set) var source: PlaybackSource?
    @Published private(set) var thirdPartySubtitles: [SubtitleSource] = []
    @Published private(set) var isLoading = false
    @Published private(set) var sourceRevision = 0
    @Published var errorMessage: String?

    @Published private(set) var request: PlaybackRequest

    init(request: PlaybackRequest) { self.request = request }

    func load(
        registry: ProviderRegistry,
        sourceLookup: SourceLookupCoordinator,
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
            async let playbackSource = playbackSourceWithRetry(
                sourceLookup: sourceLookup,
                registry: registry,
                request: playbackRequest
            )
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
            sourceRevision &+= 1
        } catch where error.isCancellation { }
        catch { errorMessage = error.localizedDescription }
    }

    func play(
        _ request: PlaybackRequest,
        registry: ProviderRegistry,
        sourceLookup: SourceLookupCoordinator,
        subtitleRegistry: SubtitleProviderRegistry,
        enabledSubtitleProviderIDs: Set<String>
    ) async {
        self.request = request
        source = nil
        thirdPartySubtitles = []
        await load(
            registry: registry,
            sourceLookup: sourceLookup,
            subtitleRegistry: subtitleRegistry,
            enabledSubtitleProviderIDs: enabledSubtitleProviderIDs,
            force: true
        )
    }

    func refreshPlaybackSource(
        registry: ProviderRegistry,
        sourceLookup: SourceLookupCoordinator
    ) async -> Bool {
        guard !isLoading else { return false }
        isLoading = true
        defer { isLoading = false }
        do {
            let refreshedSource = try await playbackSourceWithRetry(
                sourceLookup: sourceLookup,
                registry: registry,
                request: request
            )
            guard !Task.isCancelled else { return false }
            source = refreshedSource
            sourceRevision &+= 1
            return true
        } catch where error.isCancellation { }
        catch { return false }
        return false
    }

    private func playbackSourceWithRetry(
        sourceLookup: SourceLookupCoordinator,
        registry: ProviderRegistry,
        request: PlaybackRequest,
        maximumAttempts: Int = 3
    ) async throws -> PlaybackSource {
        var lastError: (any Error)?
        for attempt in 0..<maximumAttempts {
            do {
                return try await sourceLookup.resolvePlaybackSource(for: request, registry: registry)
            } catch where error.isCancellation {
                throw error
            } catch {
                lastError = error
                guard attempt < maximumAttempts - 1 else { break }
                try await Task.sleep(for: .seconds(attempt + 1))
            }
        }
        throw lastError ?? AppError.providerUnavailable("The video source is unavailable.")
    }
}
