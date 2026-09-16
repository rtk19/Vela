import Foundation

enum MediaKind: String, Codable, Sendable {
    case movie
    case series = "tv"
}

struct MediaItem: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let providerID: String
    let kind: MediaKind
    let title: String
    let originalTitle: String?
    let overview: String?
    let releaseDate: String?
    let rating: Double?
    let quality: String?
    let runtimeMinutes: Int?
    let imdbID: String?
    let tmdbID: Int?
    let posterURL: URL?
    let backdropURL: URL?
    let genres: [MediaGenre]
    let cast: [CastMember]
    let seasons: [MediaSeason]

    init(
        id: String,
        providerID: String,
        kind: MediaKind,
        title: String,
        originalTitle: String? = nil,
        overview: String? = nil,
        releaseDate: String? = nil,
        rating: Double? = nil,
        quality: String? = nil,
        runtimeMinutes: Int? = nil,
        imdbID: String? = nil,
        tmdbID: Int? = nil,
        posterURL: URL? = nil,
        backdropURL: URL? = nil,
        genres: [MediaGenre] = [],
        cast: [CastMember] = [],
        seasons: [MediaSeason] = []
    ) {
        self.id = id
        self.providerID = providerID
        self.kind = kind
        self.title = title
        self.originalTitle = originalTitle
        self.overview = overview
        self.releaseDate = releaseDate
        self.rating = rating
        self.quality = quality
        self.runtimeMinutes = runtimeMinutes
        self.imdbID = imdbID
        self.tmdbID = tmdbID
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.genres = genres
        self.cast = cast
        self.seasons = seasons
    }
}

extension MediaItem {
    static let tmdbCatalogProviderID = "tmdb"

    var artworkIdentityKey: String {
        if let tmdbID {
            return "tmdb:\(kind.rawValue):\(tmdbID)"
        }
        return "provider:\(providerID):\(kind.rawValue):\(id)"
    }

    /// Keeps provider-owned playback data while replacing display metadata with TMDB's values.
    func applyingTMDBMetadata(_ metadata: TrendingTitle) -> MediaItem {
        let tmdbOverview = metadata.overview.trimmingCharacters(in: .whitespacesAndNewlines)
        return MediaItem(
            id: id,
            providerID: providerID,
            kind: kind,
            title: metadata.title,
            originalTitle: metadata.originalTitle ?? originalTitle,
            overview: tmdbOverview.isEmpty ? nil : tmdbOverview,
            releaseDate: metadata.releaseDate,
            rating: metadata.rating,
            quality: quality,
            runtimeMinutes: runtimeMinutes,
            imdbID: imdbID,
            tmdbID: metadata.id,
            posterURL: metadata.posterURL ?? posterURL,
            backdropURL: metadata.backdropURL ?? backdropURL,
            genres: metadata.genreNames.enumerated().map { index, name in
                MediaGenre(id: "tmdb-\(metadata.id)-genre-\(index)", name: name)
            },
            cast: cast,
            seasons: seasons
        )
    }

    static func tmdbCatalogItem(from title: TrendingTitle) -> MediaItem {
        MediaItem(
            id: "tmdb:\(title.kind.rawValue):\(title.id)",
            providerID: tmdbCatalogProviderID,
            kind: title.kind,
            title: title.title,
            originalTitle: title.originalTitle,
            overview: title.overview.isEmpty ? nil : title.overview,
            releaseDate: title.releaseDate,
            rating: title.rating,
            tmdbID: title.id,
            posterURL: title.posterURL,
            backdropURL: title.backdropURL,
            genres: title.genreNames.enumerated().map { index, name in
                MediaGenre(id: "tmdb-\(title.id)-genre-\(index)", name: name)
            }
        )
    }
}

struct MediaGenre: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
}

struct CastMember: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let imageURL: URL?
}

struct MediaSeason: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let number: Int
    let title: String?
    let posterURL: URL?
}

struct MediaEpisode: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let providerID: String
    let showID: String
    let seasonNumber: Int
    let number: Int
    let title: String?
    let overview: String?
    let posterURL: URL?
}

struct MediaShelf: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let items: [MediaItem]

    init(title: String, items: [MediaItem]) {
        id = title.lowercased().replacingOccurrences(of: " ", with: "-")
        self.title = title
        self.items = items
    }
}

struct PlaybackRequest: Hashable, Sendable {
    let media: MediaItem
    let episode: MediaEpisode?

    var contentID: String { episode?.id ?? media.id }
    var nowPlayingTitle: String { media.title }
    var nowPlayingSubtitle: String? {
        guard let episode else { return nil }
        let episodeCode = String(format: "S%02dE%02d", episode.seasonNumber, episode.number)
        guard let title = episode.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return episodeCode }
        return "\(episodeCode) • \(title)"
    }
    var displayTitle: String {
        guard let episode else { return media.title }
        return "\(media.title) · S\(episode.seasonNumber) E\(episode.number)"
    }
}

enum PlaybackCompletionPolicy {
    static let episodeExitThreshold: TimeInterval = 60

    static func shouldFinishEpisodeOnExit(
        request: PlaybackRequest,
        position: Double,
        duration: Double
    ) -> Bool {
        guard request.episode != nil,
              position.isFinite,
              duration.isFinite,
              position > 0,
              duration > 0 else { return false }
        return max(duration - position, 0) <= episodeExitThreshold
    }
}

struct PlaybackSource: Sendable {
    let url: URL
    let headers: [String: String]
    let subtitles: [SubtitleSource]
    let preferredPeakBitRate: Double?
}

struct SubtitleSource: Identifiable, Hashable, Sendable {
    let id: String
    let providerID: String
    let providerName: String
    let label: String
    let languageCode: String?
    let url: URL
    let isDefault: Bool
    let headers: [String: String]

    init(
        id: String? = nil,
        providerID: String = "stream",
        providerName: String = "Built-in",
        label: String,
        languageCode: String? = nil,
        url: URL,
        isDefault: Bool = false,
        headers: [String: String] = [:]
    ) {
        self.id = id ?? "\(providerID):\(languageCode ?? "und"):\(url.absoluteString)"
        self.providerID = providerID
        self.providerName = providerName
        self.label = label
        self.languageCode = languageCode
        self.url = url
        self.isDefault = isDefault
        self.headers = headers
    }
}

enum SubtitleLanguage {
    private static let aliases: [String: String] = [
        "heb": "he", "iw": "he",
        "eng": "en",
        "deu": "de", "ger": "de",
        "fra": "fr", "fre": "fr",
        "spa": "es",
        "ita": "it",
        "por": "pt",
        "rus": "ru",
        "ara": "ar",
        "jpn": "ja",
        "kor": "ko",
        "zho": "zh", "chi": "zh",
        "ell": "el", "gre": "el",
        "ind": "id",
        "ben": "bn",
        "pan": "pa",
    ]

    static func canonicalCode(_ value: String?) -> String? {
        guard let value else { return nil }
        let base = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first
            .map(String.init) ?? ""
        guard !base.isEmpty, base != "und" else { return nil }
        let canonical = aliases[base] ?? base
        guard canonical.allSatisfy(\.isLetter), (2...3).contains(canonical.count) else { return nil }
        return canonical
    }

    static func displayName(_ value: String?, locale: Locale = Locale(identifier: "en_US")) -> String {
        guard let code = canonicalCode(value) else { return "Unknown" }
        return locale.localizedString(forLanguageCode: code) ?? code.uppercased()
    }

    static func identifiers(for value: String, locale: Locale = .current) -> Set<String> {
        guard let code = canonicalCode(value) else { return [] }
        var values = Set([code])
        if let alpha3 = Locale.LanguageCode(code).identifier(.alpha3) {
            values.insert(alpha3.lowercased())
        }
        for locale in [locale, Locale(identifier: "en_US")] {
            if let name = locale.localizedString(forLanguageCode: code) {
                values.insert(name.lowercased())
            }
        }
        if code == "he" { values.formUnion(["iw", "heb"]) }
        if code == "en" { values.insert("eng") }
        return values
    }
}

enum SubtitlePreferenceSelection {
    static func firstIndex(
        candidateLanguageCodes: [String?],
        primary: String,
        secondary: String = ""
    ) -> Int? {
        let candidates = candidateLanguageCodes.map(SubtitleLanguage.canonicalCode)
        for preference in [primary, secondary] {
            guard let preferred = SubtitleLanguage.canonicalCode(preference) else { continue }
            if let index = candidates.firstIndex(where: { $0 == preferred }) { return index }
        }
        return nil
    }
}

struct SubtitleSelectionAuthority {
    private(set) var userHasSelected = false

    var allowsAutomaticSelection: Bool { !userHasSelected }

    mutating func beginPlayerItem() { userHasSelected = false }
    mutating func recordExplicitUserSelection() { userHasSelected = true }
}

extension SubtitleSource {
    var canonicalLanguageCode: String? {
        SubtitleLanguage.canonicalCode(languageCode)
    }

    var userFacingDisplayName: String {
        let language = SubtitleLanguage.displayName(languageCode)
        let separator = "\u{00A0}•\u{00A0}"

        if providerID == "native-hls" || providerID == "stream" {
            let cleanedLabel = label
                .replacingOccurrences(of: language, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-·"))

            if cleanedLabel.isEmpty {
                return "\(language)\(separator)Built in"
            }

            return "\(language)\(separator)Built in\(separator)\(cleanedLabel)"
        }

        return "\(language)\(separator)\(providerName)\(separator)\(label)"
    }

    func resyncDisplayName(offset: Double? = nil) -> String {
        let language = SubtitleLanguage.displayName(languageCode)
        let separator = "\u{00A0}•\u{00A0}"

        if let offset {
            let timing = String(format: "%+.1fs", offset)
            return "\(language)\(separator)Resynced (\(timing))\(separator)\(label)"
        }

        return "\(language)\(separator)Resynced\(separator)\(label)"
    }

    /// A stable identity for user-created timing versions. Subtitle URLs often
    /// contain short-lived tokens, so they must not participate in persistence.
    var syncKey: String {
        let stableProviderID = id.contains("://") ? "" : id
        return [providerID, stableProviderID, canonicalLanguageCode ?? "und", label]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: "|")
    }

    func matchesSyncKey(_ key: String) -> Bool {
        if key == syncKey { return true }
        // Stremio subtitles historically persisted their presentation-only
        // private-use language tag. Accept that key without putting it back in
        // the shared source contract.
        guard providerID == "external-stream-subtitles",
              let language = canonicalLanguageCode else { return false }
        let providerSlug = providerName.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let legacyLanguage = "\(language)-x-external-\(providerSlug)"
        let stableProviderID = id.contains("://") ? "" : id
        let legacyKey = [providerID, stableProviderID, legacyLanguage, label]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: "|")
        return key == legacyKey
    }

    static func firstAlphabetically(
        matching languageCode: String,
        in subtitles: [SubtitleSource]
    ) -> SubtitleSource? {
        guard let language = SubtitleLanguage.canonicalCode(languageCode) else { return nil }
        return subtitles
            .filter { $0.canonicalLanguageCode == language }
            .sorted(by: alphabeticalOrder)
            .first
    }

    private static func alphabeticalOrder(_ left: SubtitleSource, _ right: SubtitleSource) -> Bool {
        let providerOrder = left.providerName.localizedCaseInsensitiveCompare(right.providerName)
        if providerOrder != .orderedSame { return providerOrder == .orderedAscending }
        let labelOrder = left.label.localizedCaseInsensitiveCompare(right.label)
        if labelOrder != .orderedSame { return labelOrder == .orderedAscending }
        return left.id < right.id
    }

}

struct SubtitleSyncVersion: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let subtitleKey: String
    let subtitleProviderName: String
    let subtitleLabel: String
    let languageCode: String?
    let offsetTenths: Int
    let createdAt: Date

    var offset: Double { Double(offsetTenths) / 10 }

    init(
        id: UUID = UUID(),
        subtitle: SubtitleSource,
        offset: Double,
        createdAt: Date = Date()
    ) {
        self.id = id
        subtitleKey = subtitle.syncKey
        subtitleProviderName = subtitle.providerName
        subtitleLabel = subtitle.label
        languageCode = subtitle.languageCode
        offsetTenths = min(3000, max(-3000, Int((offset * 10).rounded())))
        self.createdAt = createdAt
    }

    var displayName: String {
        let timing = String(format: "%+.1fs", offset)
        return "\(subtitleProviderName) · \(subtitleLabel) · Sync \(timing)"
    }
}

struct WatchProgress: Identifiable, Codable, Hashable, Sendable {
    var id: String { contentID }
    let contentID: String
    let providerID: String
    let media: MediaItem
    let episode: MediaEpisode?
    var position: Double
    var duration: Double
    var updatedAt: Date

    var fraction: Double { duration > 0 ? min(max(position / duration, 0), 1) : 0 }

    var isNextUp: Bool {
        media.kind == .series && episode != nil && position <= 0 && duration <= 0
    }

    var displayTitle: String {
        guard let episode else { return media.title }
        return "\(media.title) · S\(episode.seasonNumber) E\(episode.number)"
    }

    var resumeLabel: String? {
        guard position >= 1 else { return nil }
        return positionLabel
    }

    var positionLabel: String {
        let total = Int(position.rounded(.down))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    var shelfProgressLabel: String {
        guard let episode else { return positionLabel }
        return String(format: "S%02dE%02d • %@", episode.seasonNumber, episode.number, positionLabel)
    }
}

struct WatchedEpisode: Codable, Hashable, Sendable {
    let providerID: String
    let showID: String
    let seasonNumber: Int
    let episodeNumber: Int

    init(request: PlaybackRequest) {
        providerID = request.media.providerID
        showID = request.media.id
        seasonNumber = request.episode?.seasonNumber ?? 0
        episodeNumber = request.episode?.number ?? 0
    }

    func matches(_ episode: MediaEpisode, in item: MediaItem) -> Bool {
        providerID == item.providerID &&
            showID == item.id &&
            seasonNumber == episode.seasonNumber &&
            episodeNumber == episode.number
    }
}

extension Error {
    var isCancellation: Bool {
        if self is CancellationError { return true }
        return (self as? URLError)?.code == .cancelled
    }
}

enum AppError: LocalizedError, Sendable {
    case invalidResponse
    case invalidURL
    case decoding(String)
    case providerUnavailable(String)
    case noStream

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The server returned an invalid response."
        case .invalidURL: "The server returned an invalid URL."
        case .decoding(let detail): "The provider response could not be read: \(detail)"
        case .providerUnavailable(let detail): "The provider is unavailable: \(detail)"
        case .noStream: "No playable stream was found."
        }
    }
}
