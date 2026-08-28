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
        return "Season \(episode.seasonNumber), Episode \(episode.number)"
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

    init(
        id: String? = nil,
        providerID: String = "stream",
        providerName: String = "Built-in",
        label: String,
        languageCode: String? = nil,
        url: URL,
        isDefault: Bool = false
    ) {
        self.id = id ?? "\(providerID):\(languageCode ?? "und"):\(url.absoluteString)"
        self.providerID = providerID
        self.providerName = providerName
        self.label = label
        self.languageCode = languageCode
        self.url = url
        self.isDefault = isDefault
    }
}

extension SubtitleSource {
    static func firstAlphabetically(
        matching languageCode: String,
        in subtitles: [SubtitleSource]
    ) -> SubtitleSource? {
        let language = canonicalLanguageCode(languageCode)
        guard !language.isEmpty else { return nil }
        return subtitles
            .filter { canonicalLanguageCode($0.languageCode ?? "") == language }
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

    private static func canonicalLanguageCode(_ code: String) -> String {
        let base = code
            .lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init) ?? ""
        switch base {
        case "heb", "iw": return "he"
        case "eng": return "en"
        default: return base
        }
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
