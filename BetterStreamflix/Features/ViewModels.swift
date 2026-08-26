import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var shelves: [MediaShelf] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    func load(registry: ProviderRegistry, force: Bool = false) async {
        guard force || shelves.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let provider = try await registry.selected()
            shelves = try await provider.home()
        }
        catch where error.isCancellation { }
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

    init(item: MediaItem) { self.item = item }

    func load(registry: ProviderRegistry) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let provider = try await registry.provider(id: item.providerID)
            item = try await provider.details(for: item)
            if let first = item.seasons.first { await loadEpisodes(first, registry: registry) }
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
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    @Published private(set) var request: PlaybackRequest

    init(request: PlaybackRequest) { self.request = request }

    func load(registry: ProviderRegistry, force: Bool = false) async {
        guard (source == nil || force), !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let provider = try await registry.provider(id: request.media.providerID)
            source = try await provider.playbackSource(for: request)
        } catch where error.isCancellation { }
        catch { errorMessage = error.localizedDescription }
    }

    func play(_ request: PlaybackRequest, registry: ProviderRegistry) async {
        self.request = request
        source = nil
        await load(registry: registry, force: true)
    }
}
