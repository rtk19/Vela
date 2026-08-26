import Foundation

@MainActor
final class AppEnvironment: ObservableObject {
    let registry: ProviderRegistry
    let library: LibraryStore

    @Published var providerDomain: String {
        didSet { UserDefaults.standard.set(providerDomain, forKey: "provider.streamingcommunity.domain") }
    }

    init() {
        let savedDomain = UserDefaults.standard.string(forKey: "provider.streamingcommunity.domain") ?? "streamingunity.cc"
        providerDomain = savedDomain
        let provider = StreamingCommunityProvider(domain: savedDomain)
        registry = ProviderRegistry(providers: [provider], selectedProviderID: provider.id)
        library = LibraryStore()
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
