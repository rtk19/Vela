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
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.genres = genres
        self.cast = cast
        self.seasons = seasons
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
    var displayTitle: String {
        guard let episode else { return media.title }
        return "\(media.title) · S\(episode.seasonNumber) E\(episode.number)"
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
    let label: String
    let languageCode: String?
    let url: URL
    let isDefault: Bool

    init(label: String, languageCode: String? = nil, url: URL, isDefault: Bool = false) {
        id = "\(languageCode ?? "und"):\(url.absoluteString)"
        self.label = label
        self.languageCode = languageCode
        self.url = url
        self.isDefault = isDefault
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
