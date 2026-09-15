import Foundation
import Testing
@testable import Vela

@Suite("External Stremio source provider")
struct StremioAddonProviderTests {
    private let baseURL = URL(string: "https://addon.example/config")!

    @Test("Movie streams keep playable formats, metadata, and proxy headers")
    func movieStreams() async throws {
        let client = StremioFixtureClient(streamBody: #"""
        {
          "streams": [
            {"name":"support", "description":"donate"},
            {"name":"Provider", "description":"🎞️ 4K • MKV • HDR\n🛰️ Source: 4KHDHub", "url":"https://cdn.example/movie.mkv"},
            {"name":"Provider", "description":"🎞️ 1080p • MP4 • BluRay\n🛰️ Source: 2Peckle\n💾 4 GB\n🎧 Audio: English", "url":"https://cdn.example/movie.mp4?token=one",
             "behaviorHints":{"videoSize":4294967296,"bingeGroup":"twopeckle-1080-1","filename":"original.mkv1080pMP4.pad-2Peckle","proxyHeaders":{"request":{"Referer":"https://upstream.example/"}}}},
            {"name":"Provider", "description":"🎞️ 720p • HLS\n🛰️ Source: Cinejoy · Lisbon", "url":"https://cdn.example/master.m3u8"},
            {"name":"torrent", "description":"🎞️ 1080p • MP4\n🛰️ Source: Torrent", "infoHash":"abc"}
          ]
        }
        """#)
        let provider = StremioPlaybackProvider(client: client, baseURL: baseURL)
        let movie = MediaItem(id: "movie", providerID: "tmdb", kind: .movie,
                              title: "Example", imdbID: "tt0133093")
        let candidates = try await provider.candidates(for: .init(request: .init(media: movie, episode: nil)))

        #expect(client.requestedPaths == ["/config/stream/movie/tt0133093.json"])
        #expect(candidates.count == 2)
        let direct = try #require(candidates.first { $0.providerName == "2Peckle" })
        #expect(direct.preference.audioLanguage == "en")
        #expect(direct.displayMetadata?.quality == "1080p")
        #expect(direct.displayMetadata?.sizeBytes == 4_294_967_296)
        #expect(!direct.id.lowercased().contains("pengu"))
        let source = try await direct.resolve()
        #expect(source.headers["Referer"] == "https://upstream.example/")
        let refreshed = try await direct.resolve()
        #expect(refreshed.url == source.url)
        #expect(client.requestedPaths.count == 2)
        let stream = PlayableStream(candidate: direct, source: source, qualities: [])
        #expect(stream.label.contains("2Peckle"))
        #expect(stream.label.contains("1080p"))
        #expect(!stream.label.lowercased().contains("pengu"))
    }

    @Test("Series routes use the Stremio season and episode identifier")
    func seriesRoute() async throws {
        let client = StremioFixtureClient(streamBody: #"{"streams":[]}"#)
        let provider = StremioPlaybackProvider(client: client, baseURL: baseURL)
        let show = MediaItem(id: "show", providerID: "tmdb", kind: .series,
                             title: "Show", imdbID: "tt0944947")
        let episode = MediaEpisode(id: "episode", providerID: "tmdb", showID: "show",
                                   seasonNumber: 2, number: 3, title: nil, overview: nil, posterURL: nil)
        _ = try await provider.candidates(for: .init(request: .init(media: show, episode: episode)))
        #expect(client.requestedPaths == ["/config/stream/series/tt0944947:2:3.json"])
    }

    @Test("External subtitles have stable private-use tags and provider labels")
    func subtitles() async throws {
        let body = #"""
        {"subtitles":[
          {"id":"moviebox-123","lang":"eng","url":"https://subs.example/en.srt?Policy=first"},
          {"id":"https://proxy.example/sub/456","lang":"deu","url":"https://subs.example/de.srt?token=second"},
          {"id":"bad","lang":"eng","url":"file:///tmp/subtitle.srt"}
        ]}
        """#
        let client = StremioFixtureClient(subtitleBody: body)
        let provider = StremioSubtitleProvider(client: client, baseURL: baseURL)
        let request = SubtitleLookupRequest(kind: .series, imdbID: "tt0944947",
                                            seasonNumber: 1, episodeNumber: 2)
        let subtitles = try await provider.subtitles(for: request)

        #expect(client.requestedPaths == ["/config/subtitles/series/tt0944947:1:2.json"])
        #expect(subtitles.count == 2)
        #expect(subtitles.first?.providerName == "MovieBox")
        #expect(subtitles.first?.languageCode == "en-x-external-moviebox")
        #expect(subtitles.last?.providerName == "External")
        #expect(subtitles.last?.languageCode == "de-x-external-external")
        #expect(subtitles.allSatisfy { !$0.id.contains("Policy=") && !$0.id.contains("token=") })
    }

    @Test("Missing and malformed IMDb identifiers make no request")
    func missingIdentifier() async throws {
        let client = StremioFixtureClient(streamBody: #"{"streams":[]}"#)
        let provider = StremioPlaybackProvider(client: client, baseURL: baseURL)
        for imdbID in [nil, "12345", "tt12"] {
            let movie = MediaItem(id: "movie", providerID: "tmdb", kind: .movie,
                                  title: "Example", imdbID: imdbID)
            #expect(try await provider.candidates(for: .init(request: .init(media: movie, episode: nil))).isEmpty)
        }
        #expect(client.requestedPaths.isEmpty)
    }
}

private final class StremioFixtureClient: HTTPClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    private let streamBody: String
    private let subtitleBody: String
    var requestedPaths: [String] { lock.withLock { paths } }

    init(streamBody: String = #"{"streams":[]}"#, subtitleBody: String = #"{"subtitles":[]}"#) {
        self.streamBody = streamBody
        self.subtitleBody = subtitleBody
    }

    func data(for request: URLRequest) async throws -> HTTPResponse {
        let url = try #require(request.url)
        lock.withLock { paths.append(url.path) }
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        let body = url.path.contains("/subtitles/") ? subtitleBody : streamBody
        return HTTPResponse(data: Data(body.utf8), response: HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: nil
        )!)
    }
}
