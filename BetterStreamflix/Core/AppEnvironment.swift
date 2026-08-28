import Foundation

enum AppThemeColor: String, CaseIterable, Identifiable {
    case red
    case white
    case blue
    case purple
    case green
    case pink

    var id: Self { self }
    var name: String { rawValue.capitalized }
}

@MainActor
final class AppEnvironment: ObservableObject {
    let registry: ProviderRegistry
    let subtitleRegistry: SubtitleProviderRegistry
    let library: LibraryStore
    let sourceLookup: SourceLookupCoordinator
    private let tmdbClient: TMDBClient
    private let tmdbCredentials: TMDBCredentialStore
    private var isRefreshingCompletedSeries = false
    private var posterURLsByMediaKey: [String: URL] = [:]
    private var resolvedPosterKeys: Set<String> = []
    private var posterResolutionTasks: [String: Task<URL?, Never>] = [:]

    @Published var themeColor: AppThemeColor {
        didSet { UserDefaults.standard.set(themeColor.rawValue, forKey: "appearance.themeColor") }
    }

    @Published var providerDomain: String {
        didSet { UserDefaults.standard.set(providerDomain, forKey: "provider.streamingcommunity.domain") }
    }

    init() {
        let savedThemeColor = UserDefaults.standard.string(forKey: "appearance.themeColor")
            .flatMap(AppThemeColor.init(rawValue:)) ?? .red
        themeColor = savedThemeColor
        let credentials = TMDBCredentialStore()
        tmdbCredentials = credentials
        tmdbClient = TMDBClient()
        Self.importBundledTMDBAccessTokenIfNeeded(into: credentials)
        sourceLookup = SourceLookupCoordinator()
        let savedDomain = UserDefaults.standard.string(forKey: "provider.streamingcommunity.domain") ?? "streamingunity.cc"
        providerDomain = savedDomain
        let provider = StreamingCommunityProvider(domain: savedDomain)
        registry = ProviderRegistry(providers: [provider], selectedProviderID: provider.id)
        subtitleRegistry = SubtitleProviderRegistry(providers: [
            WizdomSubtitleProvider(),
            KtuvitSubtitleProvider(),
        ])
        library = LibraryStore()
    }

    private static func importBundledTMDBAccessTokenIfNeeded(into credentials: TMDBCredentialStore) {
        guard ((try? credentials.read()) ?? nil)?.isEmpty != false else { return }

        guard let bundledToken = Bundle.main.object(forInfoDictionaryKey: "TMDBReadAccessToken") as? String else {
            return
        }
        let token = bundledToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        try? credentials.save(token)
    }

    func trendingTitles() async throws -> [TrendingTitle] {
        let token = try tmdbAccessToken()
        let language = Locale.preferredLanguages.first ?? "en-US"
        return try await tmdbClient.trending(accessToken: token, language: language)
    }

    func tmdbHeroArtworkData(for item: MediaItem) async throws -> Data? {
        let token = try tmdbAccessToken()
        let language = Locale.preferredLanguages.first ?? "en-US"
        return try await tmdbClient.heroArtworkData(
            for: item,
            accessToken: token,
            language: language
        )
    }

    func tmdbLogoData(for title: TrendingTitle) async throws -> Data? {
        let token = try tmdbAccessToken()
        let language = Locale.preferredLanguages.first ?? "en-US"
        return try await tmdbClient.logoData(
            for: title,
            accessToken: token,
            language: language
        )
    }

    func tmdbLogoData(for item: MediaItem) async throws -> Data? {
        let token = try tmdbAccessToken()
        let language = Locale.preferredLanguages.first ?? "en-US"
        return try await tmdbClient.logoData(
            for: item,
            accessToken: token,
            language: language
        )
    }

    func preloadCarouselAssets(
        for titles: [TrendingTitle],
        timeout: Duration = .seconds(5)
    ) async -> TMDBCarouselAssets {
        guard let token = try? tmdbAccessToken() else { return TMDBCarouselAssets() }
        let language = Locale.preferredLanguages.first ?? "en-US"
        return await tmdbClient.carouselAssets(
            for: titles,
            accessToken: token,
            language: language,
            timeout: timeout
        )
    }

    func tmdbTitleMetadata(for item: MediaItem) async throws -> TrendingTitle? {
        let token = try tmdbAccessToken()
        let language = Locale.preferredLanguages.first ?? "en-US"
        return try await tmdbClient.titleMetadata(
            for: item,
            accessToken: token,
            language: language
        )
    }

    /// Returns one canonical poster source for provider-backed media everywhere in the app.
    /// TMDB artwork wins so a title cannot change posters between provider shelves and TMDB shelves.
    func canonicalPosterURL(for item: MediaItem) async -> URL? {
        if let posterURL = item.posterURL, posterURL.host == "image.tmdb.org" {
            return posterURL
        }

        let key = item.artworkIdentityKey
        if resolvedPosterKeys.contains(key) {
            return posterURLsByMediaKey[key] ?? item.posterURL ?? item.backdropURL
        }
        if let task = posterResolutionTasks[key] {
            return await task.value
        }

        let fallbackURL = item.posterURL ?? item.backdropURL
        let task = Task { [weak self] in
            guard let self else { return fallbackURL }
            let metadata = try? await self.tmdbTitleMetadata(for: item)
            return metadata?.posterURL ?? metadata?.backdropURL ?? fallbackURL
        }
        posterResolutionTasks[key] = task

        let resolvedURL = await task.value
        posterResolutionTasks[key] = nil
        resolvedPosterKeys.insert(key)
        if let resolvedURL {
            posterURLsByMediaKey[key] = resolvedURL
        }
        return resolvedURL
    }

    func tmdbTitles(in collection: TMDBCollection, page: Int = 1) async throws -> TMDBTitlePage {
        let token = try tmdbAccessToken()
        let language = Locale.preferredLanguages.first ?? "en-US"
        return try await tmdbClient.titles(
            in: collection,
            accessToken: token,
            language: language,
            page: page
        )
    }

    func refreshContinueWatchingForNewEpisodes() async {
        guard !isRefreshingCompletedSeries else { return }
        isRefreshingCompletedSeries = true
        defer { isRefreshingCompletedSeries = false }

        for completedRequest in library.completedSeriesRequests {
            guard !Task.isCancelled,
                  let completedEpisode = completedRequest.episode else { continue }
            do {
                let provider = try await registry.provider(id: completedRequest.media.providerID)
                let show = try await provider.details(for: completedRequest.media)
                let seasons = show.seasons
                    .filter { $0.number >= completedEpisode.seasonNumber }
                    .sorted { $0.number < $1.number }

                for season in seasons {
                    let episodes = try await provider.episodes(for: season, show: show)
                    let nextEpisode = episodes
                        .filter {
                            ($0.seasonNumber, $0.number) >
                                (completedEpisode.seasonNumber, completedEpisode.number) &&
                                !library.isWatched($0, in: show)
                        }
                        .sorted {
                            ($0.seasonNumber, $0.number) < ($1.seasonNumber, $1.number)
                        }
                        .first
                    if let nextEpisode {
                        library.promoteToContinueWatching(
                            PlaybackRequest(media: show, episode: nextEpisode)
                        )
                        break
                    }
                }
            } catch where error.isCancellation {
                return
            } catch {
                continue
            }
        }
    }

    private func tmdbAccessToken() throws -> String {
        if let stored = try tmdbCredentials.read(), !stored.isEmpty { return stored }
        guard let bundled = Bundle.main.object(forInfoDictionaryKey: "TMDBReadAccessToken") as? String else {
            throw TMDBError.missingAccessToken
        }
        let token = bundled.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw TMDBError.missingAccessToken }
        try? tmdbCredentials.save(token)
        return token
    }

    func applyProviderDomain(_ value: String) async throws {
        let domain = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .split(separator: "/", maxSplits: 1)
            .first
            .map(String.init) ?? ""
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix("."),
              domain.unicodeScalars.allSatisfy(allowed.contains) else {
            throw AppError.invalidURL
        }

        providerDomain = domain
        await registry.register(StreamingCommunityProvider(domain: domain))
    }
}
