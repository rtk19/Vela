import Foundation
import Testing
@testable import BetterStreamflix

@Suite("Provider parsing boundaries")
struct HTMLPayloadParserTests {
    @Test("Extracts and decodes an Inertia payload")
    func extractsAndDecodesInertiaPayload() throws {
        let html = #"<main id="app" data-page="{&quot;version&quot;:&quot;abc&quot;,&quot;props&quot;:{}}"></main>"#
        let data = try HTMLPayloadParser.inertiaJSON(from: Data(html.utf8))
        let page = try JSONDecoder.provider.decode(SCPage.self, from: data)
        #expect(page.version == "abc")
    }

    @Test("Extracts a relative iframe URL")
    func extractsRelativeIframeURL() throws {
        let html = #"<iframe allowfullscreen src="/embed/123?token=a"></iframe>"#
        let baseURL = try #require(URL(string: "https://example.com/en/iframe"))
        let url = try HTMLPayloadParser.firstIFrameURL(from: Data(html.utf8), relativeTo: baseURL)
        #expect(url.absoluteString == "https://example.com/embed/123?token=a")
    }

    @Test("Decodes current archive arrays and numeric identifiers")
    func decodesCurrentArchiveAndDetailsShapes() throws {
        let json = #"""
        {
          "version": "live-shape",
          "props": {
            "titles": [{
              "id": 1190,
              "slug": "outer-banks",
              "name": "Outer Banks",
              "type": "tv",
              "images": [],
              "genres": [{"id": 1, "name": "Drama"}],
              "main_actors": [{"id": 105530, "name": "Chase Stokes"}],
              "seasons": [{"number": 1, "name": null}]
            }]
          }
        }
        """#

        let page = try JSONDecoder.provider.decode(SCPage.self, from: Data(json.utf8))
        let show = try #require(page.props?.titles?.data?.first)
        #expect(show.id == "1190")
        #expect(show.genres?.first?.id == "1")
        #expect(show.actors?.first?.id == "105530")
        #expect(show.seasons?.first?.number == "1")
    }

    @Test("Builds a Vixcloud playlist from quoted token keys")
    func buildsVixcloudPlaylistFromCurrentScript() async throws {
        let html = #"""
        <html><script>
        window.video = { id: '316051', filename: '' };
        window.masterPlaylist = {
          params: { 'token': 'token-value', 'expires': '1792907350', 'asn': '' },
          url: 'https://vixcloud.co/playlist/316051?b=1'
        };
        </script></html>
        """#
        let client = StubHTTPClient(body: Data(html.utf8))
        let resolver = VixcloudResolver(client: client)
        let iframeURL = try #require(URL(string: "https://vixcloud.co/embed/316051?canPlayFHD=1&b=1"))
        let referer = try #require(URL(string: "https://streamingunity.vip/en/iframe/1190"))

        let source = try await resolver.resolve(iframeURL: iframeURL, referer: referer)
        let query = try #require(URLComponents(url: source.url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value) })
        #expect(source.url.path == "/playlist/316051")
        #expect(values["token"] == "token-value")
        #expect(values["expires"] == "1792907350")
        #expect(values["b"] == "1")
        #expect(values["h"] == "1")
        #expect(values["language"] == "en")
        #expect(source.headers["User-Agent"] == HTTPClient.desktopUserAgent)
    }

    @Test("Round-trips shared media independently of a provider")
    func mediaItemRoundTrip() throws {
        let item = MediaItem(id: "1-test", providerID: "test", kind: .movie, title: "Test")
        let decoded = try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(item))
        #expect(decoded == item)
    }

    @Test("Formats Now Playing metadata for series and movies")
    func nowPlayingMetadata() {
        let show = MediaItem(id: "show", providerID: "test", kind: .series, title: "Example Show")
        let episode = MediaEpisode(
            id: "episode",
            providerID: "test",
            showID: "show",
            seasonNumber: 2,
            number: 4,
            title: "The Fourth Episode",
            overview: nil,
            posterURL: nil
        )
        let seriesRequest = PlaybackRequest(media: show, episode: episode)
        #expect(seriesRequest.nowPlayingTitle == "Example Show")
        #expect(seriesRequest.nowPlayingSubtitle == "Season 2, Episode 4")

        let movie = MediaItem(id: "movie", providerID: "test", kind: .movie, title: "Example Movie")
        let movieRequest = PlaybackRequest(media: movie, episode: nil)
        #expect(movieRequest.nowPlayingTitle == "Example Movie")
        #expect(movieRequest.nowPlayingSubtitle == nil)
    }

    @Test("Formats series progress with its show and episode identity")
    func seriesProgressDisplay() {
        let show = MediaItem(id: "show", providerID: "test", kind: .series, title: "Example Show")
        let episode = MediaEpisode(
            id: "episode",
            providerID: "test",
            showID: "show",
            seasonNumber: 2,
            number: 4,
            title: "The Fourth Episode",
            overview: nil,
            posterURL: nil
        )
        let progress = WatchProgress(
            contentID: episode.id,
            providerID: "test",
            media: show,
            episode: episode,
            position: 2_601,
            duration: 3_600,
            updatedAt: .now
        )

        #expect(progress.displayTitle == "Example Show · S2 E4")
        #expect(progress.resumeLabel == "00:43:21")
        #expect(progress.shelfProgressLabel == "S02E04 • 00:43:21")
    }

    @Test("Formats movie shelf progress compactly")
    func movieShelfProgressDisplay() {
        let movie = MediaItem(id: "movie", providerID: "test", kind: .movie, title: "Example Movie")
        let progress = WatchProgress(
            contentID: movie.id,
            providerID: "test",
            media: movie,
            episode: nil,
            position: 2_601,
            duration: 7_200,
            updatedAt: .now
        )

        #expect(progress.shelfProgressLabel == "00:43:21")
    }

    @Test("Marks only an untouched queued episode as Next Up")
    func nextUpStatus() {
        let show = MediaItem(id: "show", providerID: "test", kind: .series, title: "Example Show")
        let episode = MediaEpisode(
            id: "episode",
            providerID: "test",
            showID: "show",
            seasonNumber: 1,
            number: 2,
            title: "The Next Episode",
            overview: nil,
            posterURL: nil
        )
        let queued = WatchProgress(
            contentID: episode.id,
            providerID: "test",
            media: show,
            episode: episode,
            position: 0,
            duration: 0,
            updatedAt: .now
        )
        var started = queued
        started.position = 1
        started.duration = 3_600
        let movie = MediaItem(id: "movie", providerID: "test", kind: .movie, title: "Example Movie")
        let untouchedMovie = WatchProgress(
            contentID: movie.id,
            providerID: "test",
            media: movie,
            episode: nil,
            position: 0,
            duration: 0,
            updatedAt: .now
        )

        #expect(queued.isNextUp)
        #expect(!started.isNextUp)
        #expect(!untouchedMovie.isNextUp)
    }

    @Test("Discovers real HLS qualities and chooses the closest lower default")
    func hlsQualityDiscovery() throws {
        let playlist = #"""
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=854x480
        480/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2800000,AVERAGE-BANDWIDTH=2400000,RESOLUTION=1280x720
        720/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=6200000,RESOLUTION=1920x1080
        1080/index.m3u8
        """#

        let qualities = HLSMasterPlaylistParser.qualities(from: playlist)
        #expect(qualities.map(\.height) == [480, 720, 1080])
        #expect(qualities[1].peakBitRate == 2_400_000)
        #expect(StreamQuality.closest(to: 1080, in: Array(qualities.dropLast()))?.height == 720)
        #expect(StreamQuality.closest(to: 480, in: Array(qualities.dropFirst()))?.height == 720)
        #expect(StreamQuality.closest(to: 0, in: qualities) == nil)
    }

    @Test("Builds Wizdom's movie and episode routes and maps its response")
    func wizdomRoutesAndResponse() async throws {
        let json = #"{"subtitles":[{"url":"https://example.com/42.srt","lang":"heb","id":"[WIZDOM]Example.Release.1080p"},{"url":"https://example.com/43.srt","lang":"heb","id":"[WIZDOM]Example.Release.1080p"}]}"#
        let client = CapturingHTTPClient(body: Data(json.utf8))
        let baseURL = try #require(URL(string: "https://subtitles.example/"))
        let provider = WizdomSubtitleProvider(client: client, baseURL: baseURL)

        let movie = try await provider.subtitles(for: SubtitleLookupRequest(
            kind: .movie,
            imdbID: "tt0133093",
            seasonNumber: nil,
            episodeNumber: nil
        ))
        let movieURL = await client.lastURL
        #expect(movieURL?.path == "/subtitles/movie/tt0133093.json")
        #expect(movie.first?.providerID == "wizdom")
        #expect(movie.count == 2)
        #expect(Set(movie.map(\.id)).count == 2)
        #expect(movie.first?.languageCode == "he")
        #expect(movie.first?.label == "Example.Release.1080p")

        _ = try await provider.subtitles(for: SubtitleLookupRequest(
            kind: .series,
            imdbID: "tt0944947",
            seasonNumber: 2,
            episodeNumber: 3
        ))
        let episodeURL = await client.lastURL
        #expect(episodeURL?.path == "/subtitles/series/tt0944947:2:3.json")
    }

    @Test("Chooses the first matching third-party subtitle by provider and option name")
    func preferredThirdPartySubtitleOrder() throws {
        let baseURL = try #require(URL(string: "https://subtitles.example/"))
        let subtitles = [
            SubtitleSource(id: "z-2", providerID: "z", providerName: "Zeta", label: "Alpha", languageCode: "he", url: baseURL.appending(path: "z-alpha.srt")),
            SubtitleSource(id: "a-2", providerID: "a", providerName: "Alpha", label: "Zulu", languageCode: "heb", url: baseURL.appending(path: "a-zulu.srt")),
            SubtitleSource(id: "a-1", providerID: "a", providerName: "Alpha", label: "Bravo", languageCode: "iw", url: baseURL.appending(path: "a-bravo.srt")),
            SubtitleSource(id: "a-en", providerID: "a", providerName: "Alpha", label: "Aardvark", languageCode: "en", url: baseURL.appending(path: "a-english.srt")),
        ]

        #expect(SubtitleSource.firstAlphabetically(matching: "he-IL", in: subtitles)?.id == "a-1")
        #expect(SubtitleSource.firstAlphabetically(matching: "eng", in: subtitles)?.id == "a-en")
        #expect(SubtitleSource.firstAlphabetically(matching: "it", in: subtitles) == nil)
    }

    @Test("Builds Ktuvit's movie and episode routes and maps Hebrew subtitles")
    func ktuvitRoutesAndResponse() async throws {
        let json = #"{"subtitles":[{"url":"https://subtitles.example/srt/TITLE/SUBTITLE.srt","lang":"heb","id":"[KTUVIT]Example.Release.1080p"},{"url":"https://subtitles.example/srt/TITLE/SECOND.srt","lang":"heb","id":"[KTUVIT]Example.Release.1080p"}]}"#
        let client = CapturingHTTPClient(body: Data(json.utf8))
        let baseURL = try #require(URL(string: "https://subtitles.example/"))
        let provider = KtuvitSubtitleProvider(client: client, baseURL: baseURL)

        let movie = try await provider.subtitles(for: SubtitleLookupRequest(
            kind: .movie,
            imdbID: "tt0110912",
            seasonNumber: nil,
            episodeNumber: nil
        ))
        let movieURL = await client.lastURL
        #expect(movieURL?.path == "/subtitles/movie/tt0110912.json")
        #expect(movie.first?.providerID == "ktuvit")
        #expect(movie.first?.providerName == "Ktuvit")
        #expect(movie.count == 2)
        #expect(Set(movie.map(\.id)).count == 2)
        #expect(movie.first?.languageCode == "he")
        #expect(movie.first?.label == "Example.Release.1080p")
        #expect(movie.first?.id.hasSuffix("SUBTITLE.srt") == true)

        _ = try await provider.subtitles(for: SubtitleLookupRequest(
            kind: .series,
            imdbID: "tt0944947",
            seasonNumber: 2,
            episodeNumber: 3
        ))
        let episodeURL = await client.lastURL
        #expect(episodeURL?.path == "/subtitles/series/tt0944947:2:3.json")
    }

    @Test("Resolves a series IMDb ID from its exact TMDb ID")
    func resolvesIMDbIDFromTMDbID() async throws {
        let json = #"{"results":{"bindings":[{"imdb":{"type":"literal","value":"tt15677150"}}]}}"#
        let client = CapturingHTTPClient(body: Data(json.utf8))
        let baseURL = try #require(URL(string: "https://metadata.example/sparql"))
        let resolver = WikidataIMDbIDResolver(
            client: client,
            baseURL: baseURL,
            userDefaults: nil
        )

        let imdbID = try await resolver.imdbID(forTMDbID: 136_311, kind: .series)
        let requestedURL = try #require(await client.lastURL)
        let queryItems = try #require(URLComponents(
            url: requestedURL,
            resolvingAgainstBaseURL: false
        )?.queryItems)
        let query = try #require(queryItems.first(where: { $0.name == "query" })?.value)

        #expect(imdbID == "tt15677150")
        #expect(query.contains("wdt:P4983 \"136311\""))
        #expect(query.contains("wdt:P345"))
    }

    @Test("Retries empty subtitle results with the IMDb ID resolved from TMDb")
    func retriesSubtitlesWithResolvedIMDbID() async throws {
        let recorder = SubtitleRequestRecorder()
        let provider = ConditionalSubtitleProvider(
            matchingIMDbID: "tt15677150",
            recorder: recorder
        )
        let registry = SubtitleProviderRegistry(
            providers: [provider],
            imdbIDResolver: StubIMDbIDResolver(result: "tt15677150")
        )
        let request = SubtitleLookupRequest(
            kind: .series,
            imdbID: "tt0115531",
            seasonNumber: 1,
            episodeNumber: 2
        )

        let subtitles = await registry.subtitles(
            for: request,
            fallbackTMDbID: 136_311,
            enabledProviderIDs: [provider.id]
        )
        let requestedIMDbIDs = await recorder.requests().map(\.imdbID)

        #expect(requestedIMDbIDs == ["tt0115531", "tt15677150"])
        #expect(subtitles.count == 1)
        #expect(subtitles.first?.label == "Shrinking.S01E02")
    }

    @Test("Parses SRT and WebVTT cues including Hebrew text")
    func parsesThirdPartySubtitleFormats() throws {
        let srt = #"""
        1
        00:00:01,250 --> 00:00:03,500
        <i>שלום עולם</i>

        2
        00:01:04.000 --> 00:01:05.250
        Second line
        """#
        let srtCues = try SubtitleParser.cues(from: Data(srt.utf8))
        #expect(srtCues.count == 2)
        #expect(srtCues[0] == SubtitleCue(startTime: 1.25, endTime: 3.5, text: "שלום עולם"))
        #expect(srtCues[1].startTime == 64)

        let vtt = #"""
        WEBVTT

        00:02.000 --> 00:04.000 align:middle
        A WebVTT cue
        """#
        let vttCues = try SubtitleParser.cues(from: Data(vtt.utf8))
        #expect(vttCues == [SubtitleCue(startTime: 2, endTime: 4, text: "A WebVTT cue")])
    }

    @Test("Keeps Hebrew punctuation on the RTL side without changing non-Hebrew lines")
    func formatsHebrewSubtitleDirection() {
        let rightToLeftMark = "\u{200F}"
        let mixedText = "שלום עולם.\nVersion 2.0"
        let formatted = SubtitleDirectionFormatter.displayText(mixedText, languageCode: "he")

        #expect(formatted == "\(rightToLeftMark)שלום עולם.\(rightToLeftMark)\nVersion 2.0")
        #expect(SubtitleDirectionFormatter.usesRightToLeftLayout(mixedText, languageCode: "he"))
        #expect(SubtitleDirectionFormatter.displayText("English text.", languageCode: "en") == "English text.")
        #expect(!SubtitleDirectionFormatter.usesRightToLeftLayout("English text.", languageCode: "en"))
    }

    @Test("Injects an external WebVTT rendition while preserving native HLS subtitles")
    func injectsExternalSubtitleIntoHLSMasterPlaylist() throws {
        let original = #"""
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="native-subs",NAME="English",LANGUAGE="en",URI="subs/en.m3u8"
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="native-subs",NAME="Hebrew",LANGUAGE="he",URI="subs/he.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1280x720,SUBTITLES="native-subs"
        video/720.m3u8
        """#
        let sourceURL = try #require(URL(string: "https://media.example/catalog/master.m3u8"))
        let subtitlePlaylistURL = URL(fileURLWithPath: "/tmp/external-subtitles.m3u8")
        let subtitleURL = try #require(URL(string: "https://subtitles.example/subtitle.srt"))
        let subtitle = SubtitleSource(
            providerID: "ktuvit",
            providerName: "Ktuvit",
            label: "Release 1080p",
            languageCode: "he",
            url: subtitleURL
        )
        let secondSubtitle = SubtitleSource(
            providerID: "wizdom",
            providerName: "Wizdom",
            label: "Another Release",
            languageCode: "he",
            url: subtitleURL.appending(path: "second")
        )

        let rewritten = HLSSubtitleInjector.rewrittenMasterPlaylist(
            original,
            sourceURL: sourceURL,
            renditions: [
                HLSSubtitleManifestRendition(
                    playlistURL: subtitlePlaylistURL,
                    subtitle: subtitle,
                    displayName: HLSSubtitleInjector.displayName(for: subtitle)
                ),
                HLSSubtitleManifestRendition(
                    playlistURL: URL(fileURLWithPath: "/tmp/external-subtitles-2.m3u8"),
                    subtitle: secondSubtitle,
                    displayName: HLSSubtitleInjector.displayName(for: secondSubtitle)
                ),
            ]
        )

        #expect(rewritten.contains(#"TYPE=SUBTITLES,GROUP-ID="native-subs",NAME="Hebrew - Ktuvit - Release 1080p""#))
        #expect(rewritten.contains(#"NAME="Hebrew - Wizdom - Another Release""#))
        #expect(rewritten.components(separatedBy: "TYPE=SUBTITLES").count == 5)
        #expect(rewritten.contains(#"NAME="Hebrew - Ktuvit - Release 1080p",LANGUAGE="he-x-bsf-1""#))
        #expect(rewritten.contains(#"NAME="Hebrew - Wizdom - Another Release",LANGUAGE="he-x-bsf-2""#))
        #expect(rewritten.contains(#"SUBTITLES="native-subs""#))
        #expect(rewritten.contains("https://media.example/catalog/subs/en.m3u8"))
        #expect(rewritten.contains("https://media.example/catalog/subs/he.m3u8"))
        #expect(rewritten.contains("https://media.example/catalog/video/720.m3u8"))
        let englishIndex = try #require(rewritten.range(of: #"NAME="English""#)?.lowerBound)
        let nativeHebrewIndex = try #require(rewritten.range(of: #"NAME="Hebrew""#)?.lowerBound)
        let ktuvitIndex = try #require(rewritten.range(of: #"NAME="Hebrew - Ktuvit"#)?.lowerBound)
        let wizdomIndex = try #require(rewritten.range(of: #"NAME="Hebrew - Wizdom"#)?.lowerBound)
        #expect(englishIndex < nativeHebrewIndex)
        #expect(nativeHebrewIndex < ktuvitIndex)
        #expect(ktuvitIndex < wizdomIndex)
    }

    @Test("Converts parsed Hebrew cues into an HLS-compatible WebVTT segment")
    func buildsExternalSubtitleWebVTT() {
        let cues = [SubtitleCue(startTime: 1.25, endTime: 3.5, text: "שלום עולם.")]
        let webVTT = HLSSubtitleInjector.webVTT(cues: cues, languageCode: "he")
        let playlist = HLSSubtitleInjector.subtitleMediaPlaylist(
            cues: cues,
            webVTTURL: URL(fileURLWithPath: "/tmp/external-subtitles.vtt")
        )

        #expect(webVTT.hasPrefix("WEBVTT\n"))
        #expect(webVTT.contains("00:00:01.250 --> 00:00:03.500"))
        #expect(webVTT.contains("\u{200F}שלום עולם.\u{200F}"))
        #expect(playlist.contains("#EXT-X-TARGETDURATION:4"))
        #expect(playlist.contains("#EXTINF:3.500,"))
    }

    @Test("Shifts subtitle timing in tenths while keeping cues valid")
    func shiftsSubtitleCueTiming() {
        let cue = SubtitleCue(startTime: 1.25, endTime: 3.5, text: "Subtitle")

        let delayed = cue.shifted(by: 0.1)
        #expect(abs(delayed.startTime - 1.35) < 0.000_001)
        #expect(abs(delayed.endTime - 3.6) < 0.000_001)
        #expect(delayed.text == "Subtitle")
        let clamped = cue.shifted(by: -2)
        #expect(clamped.startTime == 0)
        #expect(clamped.endTime == 1.5)
    }

    @Test("Decodes external title identifiers from StreamingCommunity")
    func decodesExternalTitleIdentifiers() throws {
        let json = #"{"id":6203,"name":"John Wick 4","type":"movie","slug":"john-wick-4","images":[],"tmdb_id":603692,"imdb_id":"tt10366206"}"#
        let show = try JSONDecoder.provider.decode(SCShow.self, from: Data(json.utf8))
        #expect(show.tmdbID == 603_692)
        #expect(show.imdbID == "tt10366206")

        let stringIDJSON = #"{"id":6204,"name":"Supergirl","type":"movie","slug":"supergirl","images":[],"tmdb_id":"123456"}"#
        let showWithStringID = try JSONDecoder.provider.decode(SCShow.self, from: Data(stringIDJSON.utf8))
        #expect(showWithStringID.tmdbID == 123_456)
    }

    @Test("Reuses cached title details and season episodes")
    func reusesCachedProviderDetails() async throws {
        let client = ProviderCacheHTTPClient()
        let provider = StreamingCommunityProvider(client: client, domain: "example.com")
        let item = MediaItem(
            id: "101-cached-show",
            providerID: provider.id,
            kind: .series,
            title: "Cached Show"
        )

        let firstDetails = try await provider.details(for: item)
        let secondDetails = try await provider.details(for: item)
        let season = try #require(firstDetails.seasons.first)
        let firstEpisodes = try await provider.episodes(for: season, show: firstDetails)
        let secondEpisodes = try await provider.episodes(for: season, show: secondDetails)

        #expect(firstDetails == secondDetails)
        #expect(firstEpisodes == secondEpisodes)
        #expect(firstEpisodes.first?.posterURL?.absoluteString == "https://cdn.example.com/images/episode.jpg")
        #expect(await client.requestCount(for: "/en/titles/101-cached-show") == 1)
        #expect(await client.requestCount(for: "/en/titles/101-cached-show/season-1") == 1)
    }
}

private struct StubHTTPClient: HTTPClientProtocol {
    let body: Data

    func data(for request: URLRequest) async throws -> HTTPResponse {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: ["Content-Type": "text/html"]
        ))
        return HTTPResponse(data: body, response: response)
    }
}

private actor CapturingHTTPClient: HTTPClientProtocol {
    let body: Data
    private(set) var lastURL: URL?

    init(body: Data) {
        self.body = body
    }

    func data(for request: URLRequest) async throws -> HTTPResponse {
        let url = try #require(request.url)
        lastURL = url
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: ["Content-Type": "application/json"]
        ))
        return HTTPResponse(data: body, response: response)
    }
}

private actor ProviderCacheHTTPClient: HTTPClientProtocol {
    private var requestCounts: [String: Int] = [:]

    func data(for request: URLRequest) async throws -> HTTPResponse {
        let url = try #require(request.url)
        requestCounts[url.path, default: 0] += 1

        let body: Data
        let contentType: String
        if url.path.hasSuffix("/season-1") {
            body = Data(
                #"{"version":"cache-test","props":{"loadedSeason":{"episodes":[{"id":"501","images":[{"filename":"episode.jpg","type":"cover"}],"name":"Pilot","number":"1","plot":"First episode"}]}}}"#.utf8
            )
            contentType = "application/json"
        } else {
            let page = #"{"version":"cache-test","props":{"title":{"id":"101","name":"Cached Show","type":"tv","slug":"cached-show","images":[],"seasons":[{"number":"1","name":"Season 1"}]}}}"#
            let escapedPage = page.replacingOccurrences(of: "\"", with: "&quot;")
            body = Data(#"<main id="app" data-page="\#(escapedPage)"></main>"#.utf8)
            contentType = "text/html"
        }

        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: ["Content-Type": contentType]
        ))
        return HTTPResponse(data: body, response: response)
    }

    func requestCount(for path: String) -> Int {
        requestCounts[path, default: 0]
    }
}

private struct StubIMDbIDResolver: IMDbIDResolving {
    let result: String?

    func imdbID(forTMDbID tmdbID: Int, kind: MediaKind) async throws -> String? {
        result
    }
}

private actor SubtitleRequestRecorder {
    private var captured: [SubtitleLookupRequest] = []

    func append(_ request: SubtitleLookupRequest) {
        captured.append(request)
    }

    func requests() -> [SubtitleLookupRequest] {
        captured
    }
}

private struct ConditionalSubtitleProvider: SubtitleProvider {
    let id = "conditional"
    let displayName = "Conditional"
    let matchingIMDbID: String
    let recorder: SubtitleRequestRecorder

    func subtitles(for request: SubtitleLookupRequest) async throws -> [SubtitleSource] {
        await recorder.append(request)
        guard request.imdbID == matchingIMDbID,
              let url = URL(string: "https://subtitles.example/shrinking-s01e02.srt") else {
            return []
        }
        return [SubtitleSource(
            providerID: id,
            providerName: displayName,
            label: "Shrinking.S01E02",
            languageCode: "he",
            url: url
        )]
    }
}
