import Foundation

struct SCPage: Decodable, Sendable {
    let version: String?
    let props: SCProps?
}

struct SCProps: Decodable, Sendable {
    let genres: [SCGenre]?
    let sliders: [SCSlider]?
    let archive: SCPagedTitles?
    let titles: SCPagedTitles?
    let movies: SCPagedTitles?
    let tv: SCPagedTitles?
    let tvShows: SCPagedTitles?
    let latestMovies: [SCShow]?
    let latestTVShows: [SCShow]?
    let trendingTitles: [SCShow]?
    let trending: [SCShow]?
    let top10Titles: [SCShow]?
    let top10: [SCShow]?
    let upcomingTitles: [SCShow]?
    let upcoming: [SCShow]?
    let title: SCShow?
    let loadedSeason: SCLoadedSeason?

    enum CodingKeys: String, CodingKey {
        case genres, sliders, archive, titles, movies, tv, trending, upcoming, title
        case tvShows = "tv_shows"
        case latestMovies = "latest_movies"
        case latestTVShows = "latest_tv_shows"
        case trendingTitles = "trending_titles"
        case top10Titles = "top_10_titles"
        case top10 = "top_10"
        case upcomingTitles = "upcoming_titles"
        case loadedSeason
    }
}

struct SCShow: Decodable, Sendable {
    let id: String
    let name: String
    let type: String
    let tmdbID: Int?
    let score: String?
    let lastAirDate: String?
    let images: [SCImage]
    let slug: String
    let plot: String?
    let genres: [SCGenre]?
    let actors: [SCActor]?
    let seasons: [SCSeason]?
    let quality: String?
    let runtime: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, type, score, images, slug, plot, genres, seasons, quality, runtime
        case tmdbID = "tmdb_id"
        case lastAirDate = "last_air_date"
        case actors = "main_actors"
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        if let string = try? box.decode(String.self, forKey: .id) { id = string }
        else if let number = try? box.decode(Int.self, forKey: .id) { id = String(number) }
        else { throw AppError.decoding("Missing title id") }
        name = (try? box.decode(String.self, forKey: .name)) ?? "Untitled"
        type = (try? box.decode(String.self, forKey: .type)) ?? "movie"
        tmdbID = try? box.decodeIfPresent(Int.self, forKey: .tmdbID)
        if let string = try? box.decode(String.self, forKey: .score) {
            score = string
        } else if let number = try? box.decode(Double.self, forKey: .score) {
            score = String(number)
        } else {
            score = nil
        }
        lastAirDate = try? box.decodeIfPresent(String.self, forKey: .lastAirDate)
        images = (try? box.decode([SCImage].self, forKey: .images)) ?? []
        slug = (try? box.decode(String.self, forKey: .slug)) ?? id
        plot = try? box.decodeIfPresent(String.self, forKey: .plot)
        genres = try? box.decodeIfPresent([SCGenre].self, forKey: .genres)
        actors = try? box.decodeIfPresent([SCActor].self, forKey: .actors)
        seasons = try? box.decodeIfPresent([SCSeason].self, forKey: .seasons)
        quality = try? box.decodeIfPresent(String.self, forKey: .quality)
        runtime = try? box.decodeIfPresent(Int.self, forKey: .runtime)
    }
}

struct SCImage: Decodable, Sendable { let filename: String; let type: String }
struct SCGenre: Decodable, Sendable {
    let id: String
    let name: String

    private enum CodingKeys: String, CodingKey { case id, name }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decodeFlexibleString(forKey: .id)
        name = try box.decode(String.self, forKey: .name)
    }
}

struct SCActor: Decodable, Sendable {
    let id: String?
    let name: String

    private enum CodingKeys: String, CodingKey { case id, name }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try? box.decodeFlexibleString(forKey: .id)
        name = try box.decode(String.self, forKey: .name)
    }
}

struct SCSeason: Decodable, Sendable {
    let number: String
    let name: String?

    private enum CodingKeys: String, CodingKey { case number, name }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        number = try box.decodeFlexibleString(forKey: .number)
        name = try box.decodeIfPresent(String.self, forKey: .name)
    }
}
struct SCSlider: Decodable, Sendable { let label: String?; let name: String; let titles: [SCShow] }

struct SCPagedTitles: Decodable, Sendable {
    let data: [SCShow]?
    let currentPage: Int?
    let lastPage: Int?
    enum CodingKeys: String, CodingKey {
        case data
        case currentPage = "current_page"
        case lastPage = "last_page"
    }

    init(from decoder: Decoder) throws {
        if let titles = try? decoder.singleValueContainer().decode([SCShow].self) {
            data = titles
            currentPage = 1
            lastPage = 1
            return
        }
        let box = try decoder.container(keyedBy: CodingKeys.self)
        data = try box.decodeIfPresent([SCShow].self, forKey: .data)
        currentPage = try box.decodeIfPresent(Int.self, forKey: .currentPage)
        lastPage = try box.decodeIfPresent(Int.self, forKey: .lastPage)
    }
}

struct SCSearchResponse: Decodable, Sendable {
    let data: [SCShow]
    let currentPage: Int?
    let lastPage: Int?
    enum CodingKeys: String, CodingKey {
        case data
        case currentPage = "current_page"
        case lastPage = "last_page"
    }
}

struct SCArchiveResponse: Decodable, Sendable { let titles: [SCShow] }

struct SCLoadedSeason: Decodable, Sendable { let episodes: [SCEpisode] }
struct SCEpisode: Decodable, Sendable {
    let id: String
    let images: [SCImage]
    let name: String
    let number: String
    let plot: String?

    enum CodingKeys: String, CodingKey { case id, images, name, number, plot }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        if let string = try? box.decode(String.self, forKey: .id) { id = string }
        else { id = String(try box.decode(Int.self, forKey: .id)) }
        images = (try? box.decode([SCImage].self, forKey: .images)) ?? []
        name = (try? box.decode(String.self, forKey: .name)) ?? "Episode"
        if let string = try? box.decode(String.self, forKey: .number) { number = string }
        else { number = String((try? box.decode(Int.self, forKey: .number)) ?? 0) }
        plot = try? box.decodeIfPresent(String.self, forKey: .plot)
    }
}

extension JSONDecoder {
    static let provider: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        return decoder
    }()
}

private extension KeyedDecodingContainer {
    func decodeFlexibleString(forKey key: Key) throws -> String {
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return String(value) }
        if let value = try? decode(Double.self, forKey: key) { return String(value) }
        throw DecodingError.typeMismatch(
            String.self,
            .init(codingPath: codingPath + [key], debugDescription: "Expected a string or number")
        )
    }
}
