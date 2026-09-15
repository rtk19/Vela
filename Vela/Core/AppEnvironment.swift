import Foundation
import ImageIO
import SwiftUI
import UIKit

enum VelaTheme: String, CaseIterable, Identifiable {
    case blue = "velaBlue"
    case silver = "velaSilver"
    case violet = "velaViolet"
    case aurora = "velaAurora"
    case rose = "velaRose"
    case ember = "velaEmber"

    var id: Self { self }

    var name: String {
        switch self {
        case .blue: "Vela Blue"
        case .silver: "Vela Silver"
        case .violet: "Vela Violet"
        case .aurora: "Vela Aurora"
        case .rose: "Vela Rose"
        case .ember: "Vela Ember"
        }
    }

    var accent: Color {
        switch self {
        case .blue: Color(hex: 0x397BFF)
        case .silver: Color(hex: 0xB8C2D4)
        case .violet: Color(hex: 0x765BFF)
        case .aurora: Color(hex: 0x20C7C5)
        case .rose: Color(hex: 0xC85C9E)
        case .ember: Color(hex: 0xDF6045)
        }
    }

    var accentBright: Color {
        switch self {
        case .blue: Color(hex: 0x86D2FF)
        case .silver: Color(hex: 0xF1F5FF)
        case .violet: Color(hex: 0xB4A3FF)
        case .aurora: Color(hex: 0x7BECE3)
        case .rose: Color(hex: 0xEFA1CC)
        case .ember: Color(hex: 0xFF9B70)
        }
    }

    var backgroundSecondary: Color {
        switch self {
        case .blue: Color(hex: 0x10182A)
        case .silver: Color(hex: 0x141821)
        case .violet: Color(hex: 0x171228)
        case .aurora: Color(hex: 0x0B1A20)
        case .rose: Color(hex: 0x1B111B)
        case .ember: Color(hex: 0x1D1311)
        }
    }

    var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [Self.background, backgroundSecondary, Self.background],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var heroTransition: Color { backgroundSecondary }
    var glow: Color { accent.opacity(0.28) }

    static let background = Color(hex: 0x080A10)
    static let surface = Color(hex: 0x11141C)
    static let elevatedSurface = Color(hex: 0x171B25)
    static let border = Color.white.opacity(0.07)
    static let primaryText = Color(hex: 0xF3F5FA)

    init(persistedValue: String?) {
        if let persistedValue, let value = Self(rawValue: persistedValue) {
            self = value
            return
        }
        switch persistedValue {
        case "white": self = .silver
        case "purple": self = .violet
        case "green": self = .aurora
        case "pink": self = .rose
        case "red": self = .ember
        case "blue": self = .blue
        default: self = .blue
        }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

@MainActor
final class AppEnvironment: ObservableObject {
    private struct TMDBPageCacheKey: Hashable {
        let collection: TMDBCollection
        let page: Int
        let language: String
    }

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
    private let decodedImageCache = NSCache<NSURL, UIImage>()
    private var decodedImageTasks: [URL: Task<UIImage, Error>] = [:]
    private var tmdbPageCache: [TMDBPageCacheKey: TMDBTitlePage] = [:]
    private var tmdbPageTasks: [TMDBPageCacheKey: Task<TMDBTitlePage, Error>] = [:]

    @Published var theme: VelaTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "appearance.themeColor") }
    }

    @Published var providerDomain: String {
        didSet { UserDefaults.standard.set(providerDomain, forKey: "provider.streamingcommunity.domain") }
    }

    init() {
        theme = VelaTheme(
            persistedValue: UserDefaults.standard.string(forKey: "appearance.themeColor")
        )
        let credentials = TMDBCredentialStore()
        tmdbCredentials = credentials
        tmdbClient = TMDBClient()
        decodedImageCache.countLimit = 180
        decodedImageCache.totalCostLimit = 192 * 1_024 * 1_024
        Self.importBundledTMDBAccessTokenIfNeeded(into: credentials)
        sourceLookup = SourceLookupCoordinator()
        let savedDomain = UserDefaults.standard.string(forKey: "provider.streamingcommunity.domain") ?? "streamingunity.cc"
        providerDomain = savedDomain
        let provider = StreamingCommunityProvider(domain: savedDomain)
        registry = ProviderRegistry(providers: [provider], selectedProviderID: provider.id)
        subtitleRegistry = SubtitleProviderRegistry(providers: [
            SubDLSubtitleProvider(),
            WizdomSubtitleProvider(),
            KtuvitSubtitleProvider(),
            StremioSubtitleProvider(),
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

    func cachedImageData(for url: URL) async throws -> Data {
        try await tmdbClient.imageData(for: url)
    }

    /// Returns a display-ready, downsampled image from the process-wide artwork cache.
    /// Keeping decoded images here prevents cards from flashing their placeholders whenever
    /// SwiftUI recreates a tab or navigation destination.
    func cachedImage(for url: URL) async throws -> UIImage {
        if let cached = decodedImageCache.object(forKey: url as NSURL) {
            return cached
        }
        if let task = decodedImageTasks[url] {
            return try await task.value
        }

        let client = tmdbClient
        let task = Task.detached(priority: .userInitiated) {
            let data = try await client.imageData(for: url)
            guard let image = Self.downsampledImage(from: data) else {
                throw AppError.decoding("The image response could not be decoded.")
            }
            return image
        }
        decodedImageTasks[url] = task
        defer { decodedImageTasks[url] = nil }

        let image = try await task.value
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        decodedImageCache.setObject(image, forKey: url as NSURL, cost: cost)
        return image
    }

    func cachedImageIfAvailable(for url: URL?) -> UIImage? {
        guard let url else { return nil }
        return decodedImageCache.object(forKey: url as NSURL)
    }

    func preloadPosterImages(for titles: [TrendingTitle], limit: Int = 8) async {
        let urls = titles.prefix(limit).compactMap { $0.posterURL ?? $0.backdropURL }
        await preloadImages(at: urls)
    }

    /// Warms the immediately visible shelves on the Movies and Series tabs once Home has
    /// finished. The page cache also lets those tabs publish their first shelves immediately.
    func preloadPrimaryNavigationArtwork() async {
        let collections = [MediaKind.movie, .series].flatMap {
            Array(TMDBCollection.catalogSections(for: $0).prefix(4))
        }
        await withTaskGroup(of: [TrendingTitle].self) { group in
            for collection in collections {
                group.addTask { [weak self] in
                    guard let self else { return [] }
                    return (try? await self.tmdbTitles(in: collection).titles) ?? []
                }
            }
            for await titles in group {
                await preloadPosterImages(for: titles)
            }
        }
    }

    private func preloadImages(at urls: [URL]) async {
        await withTaskGroup(of: Void.self) { group in
            for url in Set(urls) where decodedImageCache.object(forKey: url as NSURL) == nil {
                group.addTask { [weak self] in
                    _ = try? await self?.cachedImage(for: url)
                }
            }
        }
    }

    private nonisolated static func downsampledImage(from data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 720,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: image)
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

    func tmdbTitles(
        in collection: TMDBCollection,
        page: Int = 1,
        forceRefresh: Bool = false
    ) async throws -> TMDBTitlePage {
        let token = try tmdbAccessToken()
        let language = Locale.preferredLanguages.first ?? "en-US"
        let key = TMDBPageCacheKey(collection: collection, page: page, language: language)
        if !forceRefresh, let cached = tmdbPageCache[key] { return cached }
        if !forceRefresh, let task = tmdbPageTasks[key] { return try await task.value }

        let client = tmdbClient
        let task = Task {
            try await client.titles(
                in: collection,
                accessToken: token,
                language: language,
                page: page
            )
        }
        tmdbPageTasks[key] = task
        defer { tmdbPageTasks[key] = nil }
        let result = try await task.value
        tmdbPageCache[key] = result
        return result
    }

    func tmdbSearch(query: String, page: Int = 1) async throws -> TMDBTitlePage {
        let token = try tmdbAccessToken()
        let language = Locale.preferredLanguages.first ?? "en-US"
        return try await tmdbClient.search(
            query: query,
            accessToken: token,
            language: language,
            page: page
        )
    }

    func playbackContext(for request: PlaybackRequest) async -> PlaybackLookupContext {
        guard let token = try? tmdbAccessToken() else { return PlaybackLookupContext(request: request) }
        return (try? await tmdbClient.playbackContext(for: request, accessToken: token)) ?? PlaybackLookupContext(request: request)
    }

    func tmdbDetails(for item: MediaItem) async throws -> MediaItem {
        let token = try tmdbAccessToken()
        let language = Locale.preferredLanguages.first ?? "en-US"
        return try await tmdbClient.details(for: item, accessToken: token, language: language)
    }

    func tmdbEpisodes(for season: MediaSeason, show: MediaItem) async throws -> [MediaEpisode] {
        let token = try tmdbAccessToken()
        let language = Locale.preferredLanguages.first ?? "en-US"
        return try await tmdbClient.episodes(
            for: season,
            show: show,
            accessToken: token,
            language: language
        )
    }

    func refreshContinueWatchingForNewEpisodes() async {
        guard !isRefreshingCompletedSeries else { return }
        isRefreshingCompletedSeries = true
        defer { isRefreshingCompletedSeries = false }

        await removeUnavailableQueuedEpisodes()

        for completedRequest in library.completedSeriesRequests {
            guard !Task.isCancelled,
                  let completedEpisode = completedRequest.episode else { continue }
            do {
                let show = try await tmdbDetails(for: completedRequest.media)
                let seasons = show.seasons
                    .filter { $0.number >= completedEpisode.seasonNumber }
                    .sorted { $0.number < $1.number }

                for season in seasons {
                    let episodes = try await tmdbEpisodes(for: season, show: show)
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

    private func removeUnavailableQueuedEpisodes() async {
        let queuedEpisodes = library.continueWatching.filter { $0.isNextUp }
        for progress in queuedEpisodes {
            guard !Task.isCancelled, let episode = progress.episode else { return }
            do {
                let show = try await tmdbDetails(for: progress.media)
                guard let season = show.seasons.first(where: { $0.number == episode.seasonNumber }) else {
                    library.deferUnavailableNextUp(progress)
                    continue
                }
                let releasedEpisodes = try await tmdbEpisodes(for: season, show: show)
                let isReleased = releasedEpisodes.contains {
                    $0.seasonNumber == episode.seasonNumber && $0.number == episode.number
                }
                if !isReleased {
                    library.deferUnavailableNextUp(progress)
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

    func reloadAfterUserDataImport() async {
        theme = VelaTheme(
            persistedValue: UserDefaults.standard.string(forKey: "appearance.themeColor")
        )
        providerDomain = UserDefaults.standard.string(forKey: "provider.streamingcommunity.domain")
            ?? "streamingunity.cc"
        await registry.register(StreamingCommunityProvider(domain: providerDomain))
    }
}
