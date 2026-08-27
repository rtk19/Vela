import Foundation

@MainActor
final class AppEnvironment: ObservableObject {
    let registry: ProviderRegistry
    let subtitleRegistry: SubtitleProviderRegistry
    let library: LibraryStore
    let sourceLookup: SourceLookupCoordinator
    private let tmdbClient: TMDBClient
    private let tmdbCredentials: TMDBCredentialStore

    @Published var providerDomain: String {
        didSet { UserDefaults.standard.set(providerDomain, forKey: "provider.streamingcommunity.domain") }
    }

    init() {
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
