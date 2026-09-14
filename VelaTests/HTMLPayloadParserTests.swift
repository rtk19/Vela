import Foundation
import AVFoundation
import Testing
@testable import Vela

@Suite("Provider parsing boundaries")
struct HTMLPayloadParserTests {
    @Test("Decodes Hebrew subtitles across Unicode and Windows encodings")
    func subtitleEncodingVariants() throws {
        let text = "בדיקה בעברית!"
        let srt = "1\r\n00:00:01,000 --> 00:00:03,000\r\n\(text)\r\n"
        let hebrew = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(0x0505))
        for encoding in [String.Encoding.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian,
                         .utf32, .utf32LittleEndian, .utf32BigEndian, hebrew] {
            let data = try #require(srt.data(using: encoding))
            let cues = try SubtitleParser.cues(from: data, languageCode: "he")
            #expect(cues.count == 1)
            #expect(cues.first?.text == text)
            #expect(cues.first?.startTime == 1)
            #expect(cues.first?.endTime == 3)
        }
    }

    @Test("Recovers Hebrew transcoded through Western encodings")
    func repairsHebrewMojibake() throws {
        let text = "בדיקה בעברית!"
        let hebrew = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(0x0505))
        for original in [String.Encoding.utf8, hebrew] {
            for western in [String.Encoding.windowsCP1252, .isoLatin1] {
                let bytes = try #require(text.data(using: original))
                let garbled = try #require(String(data: bytes, encoding: western))
                let data = Data("1\n00:00:01,000 --> 00:00:03,000\n\(garbled)".utf8)
                #expect(try SubtitleParser.cues(from: data, languageCode: "he-IL").first?.text == text)
                #expect(try SubtitleParser.cues(from: data, languageCode: "fr").first?.text == garbled)
            }
        }
    }

    @Test("Repairs short replies after establishing a file-wide Hebrew encoding error")
    func repairsShortHebrewReplies() throws {
        // Reproduce the Western-to-UTF-8 conversion observed in Ktuvit's episode 3 file.
        let lines = Array(repeating: "<i>בדיקה בעברית</i>", count: 5) + ["כן.", "לא!", "שלום עולם, John!"]
        let hebrew = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(0x0505))
        let blocks = try lines.enumerated().map { index, line in
            let bytes = try #require(line.data(using: hebrew))
            let garbled = try #require(String(data: bytes, encoding: .isoLatin1))
            return "\(index + 1)\n00:00:01,000 --> 00:00:03,000\n\(garbled)"
        }
        let cues = try SubtitleParser.cues(from: Data(blocks.joined(separator: "\n\n").utf8), languageCode: "he")
        #expect(cues.map(\.text) == Array(repeating: "בדיקה בעברית", count: 5) + ["כן.", "לא!", "שלום עולם, John!"])
    }

    @Test("Preserves valid multilingual subtitles and rejects damaged Unicode")
    func subtitleEncodingSafety() throws {
        for text in ["שלום, John!", "Hello world!", "Café déjà vu", "كيف حالك؟", "日本語"] {
            let data = Data("1\n00:00:01,000 --> 00:00:03,000\n\(text)".utf8)
            #expect(try SubtitleParser.cues(from: data, languageCode: "he").first?.text == text)
        }
        let damaged = Data([0xEF, 0xBB, 0xBF, 0xFF])
        #expect(throws: (any Error).self) { try SubtitleParser.cues(from: damaged, languageCode: "he") }
    }

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
        #expect(seriesRequest.nowPlayingSubtitle == "S02E04 • The Fourth Episode")

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

    @Test("Manual HLS quality keeps only the selected resolution")
    func filtersHLSMasterPlaylistToSelectedQuality() {
        let playlist = #"""
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",URI="audio/en.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=854x480,AUDIO="audio"
        480/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1280x720,AUDIO="audio"
        720/index.m3u8
        #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=300000,RESOLUTION=1280x720,URI="720/iframes.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=6200000,RESOLUTION=1920x1080,AUDIO="audio"
        1080/index.m3u8
        """#

        let filtered = HLSMasterPlaylistParser.playlist(playlist, filteredToHeight: 720)

        #expect(filtered.contains("720/index.m3u8"))
        #expect(filtered.contains("720/iframes.m3u8"))
        #expect(filtered.contains(#"TYPE=AUDIO,GROUP-ID="audio""#))
        #expect(!filtered.contains("480/index.m3u8"))
        #expect(!filtered.contains("1080/index.m3u8"))
        #expect(HLSMasterPlaylistParser.qualities(from: filtered).map(\.height) == [720])
    }

    @Test("Escalates a stagnant stream from play retry to bounded source recovery")
    func playbackRecoveryPolicy() {
        #expect(PlaybackRecoveryPolicy.action(
            stagnantChecks: 0,
            sourceRefreshAttempts: 0
        ) == .keepWaiting)
        #expect(PlaybackRecoveryPolicy.action(
            stagnantChecks: 1,
            sourceRefreshAttempts: 0
        ) == .retryPlay)
        #expect(PlaybackRecoveryPolicy.action(
            stagnantChecks: 2,
            sourceRefreshAttempts: 0
        ) == .refreshSource)
        #expect(PlaybackRecoveryPolicy.action(
            stagnantChecks: 2,
            sourceRefreshAttempts: PlaybackRecoveryPolicy.maximumSourceRefreshes
        ) == .fail)
    }

    @Test("Retries transient subtitle resource failures with fresh requests")
    func subtitleResourceRetry() async throws {
        let client = FailingThenSucceedingHTTPClient(failuresBeforeSuccess: 2)
        let url = try #require(URL(string: "https://example.com/subtitles.vtt"))

        let response = try await SubtitleResourceRetry.load(
            request: URLRequest(url: url),
            client: client
        )
        let requestCount = await client.requestCount
        let cachePolicies = await client.cachePolicies

        #expect(response.data == Data("WEBVTT\n".utf8))
        #expect(requestCount == 3)
        #expect(cachePolicies.allSatisfy { $0 == .reloadIgnoringLocalCacheData })
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

    @Test("Ktuvit recovers Paradise S1E6 through its full IMDb link when the bridge is empty")
    func ktuvitDirectEpisodeFallback() async throws {
        let bridge = URL(string: "https://subtitles.example/")!
        let searchURL = URL(string: "https://www.ktuvit.me/Services/ContentProvider.svc/SearchPage_search")!
        let episodeURL = URL(string: "https://www.ktuvit.me/Services/GetModuleAjax.ashx?moduleName=SubtitlesList&SeriesID=correct&Season=1&Episode=6")!
        let films = #"{"Films":[{"ID":"wrong","IMDB_Link":"https://www.imdb.com/title/tt2744420/","ImdbID":"tt2744420"},{"ID":"correct","IMDB_Link":"https://www.imdb.com/title/tt27444205/","ImdbID":"tt2744420"}]}"#
        let envelope = try JSONSerialization.data(withJSONObject: ["d": films])
        let html = #"<tr><td><div>Paradise.2025.S01E06.1080p.WEB.h264-ETHEL<br /><small>Credit</small></div></td><td><a data-subtitle-id="episode-six"></a></td></tr><tr><td>No subtitles</td></tr>"#
        let client = RoutingHTTPClient(bodies: [
            bridge.appending(path: "subtitles/series/tt27444205:1:6.json"): Data(#"{"subtitles":[]}"#.utf8),
            searchURL: envelope,
            episodeURL: Data(html.utf8),
        ])
        let results = try await KtuvitSubtitleProvider(client: client, baseURL: bridge).subtitles(for:
            SubtitleLookupRequest(kind: .series, imdbID: "tt27444205", seasonNumber: 1, episodeNumber: 6, title: "Paradise"))
        #expect(results.count == 1)
        #expect(results.first?.languageCode == "he")
        #expect(results.first?.label == "Paradise.2025.S01E06.1080p.WEB.h264-ETHEL")
        #expect(results.first?.url.path == "/srt/correct/episode-six.srt")
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

    @Test("Normalizes RTL punctuation only when the subtitle file needs it")
    func formatsRightToLeftSubtitleDirection() {
        let rightToLeftMark = "\u{200F}"
        let cues = [
            SubtitleCue(startTime: 0, endTime: 1, text: "שלום עולם.\nVersion 2.0"),
            SubtitleCue(startTime: 1, endTime: 2, text: "- מה שלומך?"),
        ]

        #expect(SubtitleDirectionFormatter.needsNormalization(cues, languageCode: "he"))
        let normalized = SubtitleDirectionFormatter.normalizedCues(cues, languageCode: "he")
        #expect(normalized[0].text == "\(rightToLeftMark)שלום עולם.\nVersion 2.0")
        #expect(normalized[1].text == "\(rightToLeftMark)- מה שלומך?")
        #expect(!SubtitleDirectionFormatter.needsNormalization(normalized, languageCode: "he"))
        #expect(SubtitleDirectionFormatter.normalizedCues(normalized, languageCode: "he") == normalized)
    }

    @Test("Repairs legacy reversed punctuation in RTL subtitle files")
    func repairsLegacyRightToLeftPunctuation() {
        let rightToLeftMark = "\u{200F}"
        let cues = [
            SubtitleCue(startTime: 0, endTime: 1, text: ",אבל טיפ הוא טיפ\n.והיינו חייבים לפעול מהר"),
            SubtitleCue(startTime: 1, endTime: 2, text: ".מצטערת. בטח יש לי דם באוזניים -"),
            SubtitleCue(startTime: 2, endTime: 3, text: "?את בסדר"),
            SubtitleCue(startTime: 3, endTime: 4, text: "?\"איך זה בשביל \"מוכן"),
            SubtitleCue(startTime: 4, endTime: 5, text: "!?הכל מוכן"),
            SubtitleCue(startTime: 5, endTime: 6, text: "?\"\"מפילה אותי מהרגליים"),
            SubtitleCue(startTime: 6, endTime: 7, text: ".\"\"האמת שאת מפילה אותי מהרגליים"),
            SubtitleCue(startTime: 7, endTime: 8, text: "?)(בדיקה"),
            SubtitleCue(startTime: 8, endTime: 9, text: ".טוען - -"),
            SubtitleCue(startTime: 9, endTime: 10, text: "\"\"ציטוט מלא"),
            SubtitleCue(startTime: 10, endTime: 11, text: ")(הערת סוגריים"),
            SubtitleCue(startTime: 11, endTime: 12, text: "”“ציטוט חכם"),
            SubtitleCue(startTime: 12, endTime: 13, text: "；גרסה 2.0 (Beta)"),
        ]

        let normalized = SubtitleDirectionFormatter.normalizedCues(cues, languageCode: "he")

        #expect(normalized[0].text == "\(rightToLeftMark)אבל טיפ הוא טיפ,\n\(rightToLeftMark)והיינו חייבים לפעול מהר.")
        #expect(normalized[1].text == "\(rightToLeftMark)- מצטערת. בטח יש לי דם באוזניים.")
        #expect(normalized[2].text == "\(rightToLeftMark)את בסדר?")
        #expect(normalized[3].text == "\(rightToLeftMark)איך זה בשביל \"מוכן\"?")
        #expect(normalized[4].text == "\(rightToLeftMark)הכל מוכן?!")
        #expect(normalized[5].text == "\(rightToLeftMark)\"מפילה אותי מהרגליים\"?")
        #expect(normalized[6].text == "\(rightToLeftMark)\"האמת שאת מפילה אותי מהרגליים\".")
        #expect(normalized[7].text == "\(rightToLeftMark)(בדיקה)?")
        #expect(normalized[8].text == "\(rightToLeftMark)- - טוען.")
        #expect(normalized[9].text == "\(rightToLeftMark)\"ציטוט מלא\"")
        #expect(normalized[10].text == "\(rightToLeftMark)(הערת סוגריים)")
        #expect(normalized[11].text == "\(rightToLeftMark)“ציטוט חכם”")
        #expect(normalized[12].text == "\(rightToLeftMark)גרסה 2.0 (Beta)；")
        #expect(SubtitleDirectionFormatter.normalizedCues(normalized, languageCode: "he") == normalized)
    }

    @Test("Preserves already logical RTL delimiters and dialogue runs")
    func preservesLogicalRightToLeftBoundaries() {
        let rightToLeftMark = "\u{200F}"
        let cues = [
            SubtitleCue(startTime: 0, endTime: 1, text: "\"ציטוט מלא\"."),
            SubtitleCue(startTime: 1, endTime: 2, text: "(הערת סוגריים)?"),
            SubtitleCue(startTime: 2, endTime: 3, text: "“ציטוט חכם”"),
            SubtitleCue(startTime: 3, endTime: 4, text: "- - טוען..."),
            SubtitleCue(startTime: 4, endTime: 5, text: "גרסה 2.0 (Beta);"),
            SubtitleCue(startTime: 5, endTime: 6, text: "- מבוקש לחקירה -"),
            SubtitleCue(startTime: 6, endTime: 7, text: "- עונה 3, פרק 6 -"),
            SubtitleCue(startTime: 7, endTime: 8, text: "— גבול חכם —"),
            SubtitleCue(startTime: 8, endTime: 9, text: "- פענוח רשת \"טור\" -"),
            SubtitleCue(startTime: 9, endTime: 10, text: "- \"ציטוט מלא\" -"),
        ]

        let normalized = SubtitleDirectionFormatter.normalizedCues(cues, languageCode: "he")

        for (original, result) in zip(cues, normalized) {
            #expect(result.text == "\(rightToLeftMark)\(original.text)")
        }
    }

    @Test("Formats the reported quote, bracket, number, and dialogue cases in logical order")
    func formatsReportedRightToLeftBoundaryCases() {
        let rightToLeftMark = "\u{200F}"
        let legacyCues = [
            SubtitleCue(startTime: 0, endTime: 1, text: "?\"\"מפילה אותי מהרגליים"),
            SubtitleCue(startTime: 1, endTime: 2, text: ".\"\"האמת שאת מפילה אותי מהרגליים"),
            SubtitleCue(startTime: 2, endTime: 3, text: "?\"איך זה בשביל \"מוכן"),
            SubtitleCue(startTime: 3, endTime: 4, text: ")שדר ראשון: יוני 23 (מסווג"),
            SubtitleCue(startTime: 4, endTime: 5, text: "טוען - -"),
            SubtitleCue(startTime: 5, endTime: 6, text: "- \"פענוח רשת \"טור -"),
            SubtitleCue(startTime: 6, endTime: 7, text: "— ״פענוח רשת ״טור —"),
        ]

        let normalized = SubtitleDirectionFormatter.normalizedCues(
            legacyCues,
            languageCode: "he"
        )

        #expect(normalized.map(\.text) == [
            "\(rightToLeftMark)\"מפילה אותי מהרגליים\"?",
            "\(rightToLeftMark)\"האמת שאת מפילה אותי מהרגליים\".",
            "\(rightToLeftMark)איך זה בשביל \"מוכן\"?",
            "\(rightToLeftMark)(שדר ראשון: יוני 23 (מסווג",
            "\(rightToLeftMark)- - טוען",
            "\(rightToLeftMark)- פענוח רשת \"טור\" -",
            "\(rightToLeftMark)— פענוח רשת ״טור״ —",
        ])
    }

    @Test("Keeps enclosing quotes when terminal punctuation is displaced inside the opening boundary")
    func repairsSplitQuotedSentenceBoundaries() {
        let cases: [(String, String)] = [
            ("\".זה הגרנד קניון שלנו\"", "\"זה הגרנד קניון שלנו\"."),
            ("\",בוא נלך לצוד את בית מורטון\"\nאמרת.", "\"בוא נלך לצוד את בית מורטון\",\nאמרת."),
            ("זה הגרנד קניון שלנו\".\"", "\"זה הגרנד קניון שלנו\"."),
            ("בוא נלך לצוד את בית מורטון\",\"\nאמרת.", "\"בוא נלך לצוד את בית מורטון\",\nאמרת."),
        ]
        for (input, expected) in cases {
            let cues = [SubtitleCue(startTime: 0, endTime: 1, text: input)]
            let result = SubtitleDirectionFormatter.normalizedCues(cues, languageCode: "he")
            let marked = expected.components(separatedBy: "\n").map { "\u{200F}\($0)" }.joined(separator: "\n")
            #expect(result[0].text == marked)
            #expect(SubtitleDirectionFormatter.normalizedCues(result, languageCode: "he") == result)
            #expect(HLSSubtitleInjector.webVTT(cues: cues, languageCode: "he").contains(marked))
        }
    }

    @Test("Repairs enclosing quote boundaries across neutral quote and punctuation types",
          arguments: ["\"", "'", "׳", "״"], [".", ",", "!", "؟", "；"])
    func repairsEnclosingQuotationMatrix(quote: String, mark: String) {
        let expected = "\(quote)בדיקת ציטוט\(quote)\(mark)"
        for input in ["\(quote)\(mark)בדיקת ציטוט\(quote)", "בדיקת ציטוט\(quote)\(mark)\(quote)", expected] {
            let cues = [SubtitleCue(startTime: 0, endTime: 1, text: input)]
            let result = SubtitleDirectionFormatter.normalizedCues(cues, languageCode: "he")
            #expect(result[0].text == "\u{200F}\(expected)")
            #expect(SubtitleDirectionFormatter.normalizedCues(result, languageCode: "he") == result)
        }
        for input in ["\(quote)בדיקת ציטוט\(mark)\(quote)", "זהו \(quote)ציטוט\(quote)\(mark)"] {
            let cues = [SubtitleCue(startTime: 0, endTime: 1, text: input)]
            #expect(SubtitleDirectionFormatter.normalizedCues(cues, languageCode: "he")[0].text == "\u{200F}\(input)")
        }
    }

    @Test("Repairs punctuation inside caption dashes and preserves first-word quotations")
    func repairsCaptionBodiesAndFirstWordQuotes() {
        let pairs = [
            ("- !אל תדלגו -", "- אל תדלגו! -"),
            ("- אל תדלגו! -", "- אל תדלגו! -"),
            ("— ؟אל תדלגו —", "— אל תדלגו؟ —"),
            ("- וודיו\" שק\".", "- \"וודיו\" שק."),
            ("- וודיו״ שק״.", "- ״וודיו״ שק."),
            ("- ״וודיו״ שק.", "- ״וודיו״ שק."),
            ("\"וודיו\" שק.", "\"וודיו\" שק."),
            ("- \"פענוח רשת \"טור -", "- פענוח רשת \"טור\" -"),
            ("- \".זה הגרנד קניון שלנו\" -", "- \"זה הגרנד קניון שלנו\". -"),
        ]
        for (input, expected) in pairs {
            let cues = [SubtitleCue(startTime: 0, endTime: 1, text: input)]
            let result = SubtitleDirectionFormatter.normalizedCues(cues, languageCode: "he")
            #expect(result[0].text == "\u{200F}\(expected)")
            #expect(SubtitleDirectionFormatter.normalizedCues(result, languageCode: "he") == result)
            #expect(HLSSubtitleInjector.webVTT(cues: cues, languageCode: "he").contains("\u{200F}\(expected)"))
        }
    }

    @Test("Removes inherited LTR controls that override RTL subtitle rendering")
    func removesConflictingRightToLeftSubtitleControls() {
        let rightToLeftMark = "\u{200F}"
        let leftToRightMark = "\u{200E}"
        let leftToRightEmbedding = "\u{202A}"
        let popDirectionalFormatting = "\u{202C}"
        let cues = [
            SubtitleCue(
                startTime: 0,
                endTime: 1,
                text: "\(leftToRightMark)\(leftToRightEmbedding)- מבוקש לחקירה -\(popDirectionalFormatting)"
            ),
            SubtitleCue(
                startTime: 1,
                endTime: 2,
                text: "\(leftToRightEmbedding)- עונה 3, פרק 6 -\(popDirectionalFormatting)"
            ),
            SubtitleCue(
                startTime: 2,
                endTime: 3,
                text: "\(leftToRightEmbedding)(שדר ראשון: יוני 23 (מסווג\(popDirectionalFormatting)"
            ),
        ]

        let normalized = SubtitleDirectionFormatter.normalizedCues(cues, languageCode: "he")

        #expect(normalized.map(\.text) == [
            "\(rightToLeftMark)- מבוקש לחקירה -",
            "\(rightToLeftMark)- עונה 3, פרק 6 -",
            "\(rightToLeftMark)(שדר ראשון: יוני 23 (מסווג",
        ])
        #expect(SubtitleDirectionFormatter.normalizedCues(normalized, languageCode: "he") == normalized)
        #expect(!SubtitleDirectionFormatter.needsNormalization(normalized, languageCode: "he"))
    }

    @Test("Canonicalizes every Unicode bidi wrapper used by legacy subtitle files")
    func canonicalizesLegacySubtitleBidiWrappers() {
        let rightToLeftMark = "\u{200F}"
        let logicalText = "(בדיקה 23)."
        let wrappers = [
            ("\u{061C}", ""),
            ("\u{200E}", ""),
            ("\u{200F}", ""),
            ("\u{202A}", "\u{202C}"),
            ("\u{202B}", "\u{202C}"),
            ("\u{202D}", "\u{202C}"),
            ("\u{202E}", "\u{202C}"),
            ("\u{2066}", "\u{2069}"),
            ("\u{2067}", "\u{2069}"),
            ("\u{2068}", "\u{2069}"),
        ]
        let cues = wrappers.enumerated().map { index, wrapper in
            SubtitleCue(
                startTime: Double(index),
                endTime: Double(index + 1),
                text: "\(wrapper.0)\(logicalText)\(wrapper.1)"
            )
        }

        let normalized = SubtitleDirectionFormatter.normalizedCues(cues, languageCode: "he")

        #expect(normalized.allSatisfy { $0.text == "\(rightToLeftMark)\(logicalText)" })
    }

    @Test("Uses Unicode punctuation categories instead of a finite mark list")
    func repairsUnicodeRightToLeftPunctuationCategories() {
        let rightToLeftMark = "\u{200F}"
        // Characters intentionally span multiple scripts and Unicode blocks.
        let marks = ["٪", "؞", "੶", "꘍", "꛷", "𑂻"]
        let cues = marks.enumerated().map { index, mark in
            SubtitleCue(
                startTime: Double(index),
                endTime: Double(index + 1),
                text: "\(mark)בדיקה"
            )
        }

        let normalized = SubtitleDirectionFormatter.normalizedCues(cues, languageCode: "he")

        #expect(normalized.map(\.text) == marks.map { "\(rightToLeftMark)בדיקה\($0)" })
    }

    @Test("Repairs legacy RTL outliers in an otherwise logical subtitle file")
    func repairsMixedRightToLeftPunctuationLayoutsPerLine() {
        let rightToLeftMark = "\u{200F}"
        let cues = [
            SubtitleCue(startTime: 0, endTime: 1, text: "שורה תקינה."),
            SubtitleCue(startTime: 1, endTime: 2, text: "- גם השורה הזאת תקינה."),
            SubtitleCue(startTime: 2, endTime: 3, text: "חצר ,2-איי מצלמה --"),
            SubtitleCue(startTime: 3, endTime: 4, text: "?לאן הולכים"),
            SubtitleCue(startTime: 4, endTime: 5, text: "...אבל אולי"),
        ]

        let normalized = SubtitleDirectionFormatter.normalizedCues(cues, languageCode: "he")

        #expect(normalized[0].text == "\(rightToLeftMark)שורה תקינה.")
        #expect(normalized[1].text == "\(rightToLeftMark)- גם השורה הזאת תקינה.")
        #expect(normalized[2].text == "\(rightToLeftMark)-- חצר ,2-איי מצלמה")
        #expect(normalized[3].text == "\(rightToLeftMark)לאן הולכים?")
        #expect(normalized[4].text == "\(rightToLeftMark)...אבל אולי")
    }

    @Test("Repairs a broad matrix of legacy RTL terminal marks")
    func repairsLegacyRightToLeftTerminalMarkMatrix() {
        let rightToLeftMark = "\u{200F}"
        let marks = [".", ",", "!", "?", ";", ":", "…", "‥", "،", "؛", "؟", "۔", "׃", "。", "！", "？"]
        let cues = marks.enumerated().map { index, mark in
            SubtitleCue(startTime: Double(index), endTime: Double(index + 1), text: "\(mark)בדיקה")
        }

        let normalized = SubtitleDirectionFormatter.normalizedCues(cues, languageCode: "he")

        for (mark, cue) in zip(marks, normalized) {
            #expect(cue.text == "\(rightToLeftMark)בדיקה\(mark)")
        }
    }

    @Test("Repairs Arabic legacy punctuation without rewriting intentional ellipses")
    func repairsLegacyArabicPunctuation() {
        let rightToLeftMark = "\u{200F}"
        let legacyArabic = [
            SubtitleCue(startTime: 0, endTime: 1, text: "؟كيف حالك"),
            SubtitleCue(startTime: 1, endTime: 2, text: "،ولكن علينا الذهاب"),
        ]
        let intentionalEllipsis = [
            SubtitleCue(startTime: 0, endTime: 1, text: "...אבל אולי"),
        ]

        let normalizedArabic = SubtitleDirectionFormatter.normalizedCues(legacyArabic, languageCode: "ar")
        let normalizedEllipsis = SubtitleDirectionFormatter.normalizedCues(intentionalEllipsis, languageCode: "he")

        #expect(normalizedArabic[0].text == "\(rightToLeftMark)كيف حالك؟")
        #expect(normalizedArabic[1].text == "\(rightToLeftMark)ولكن علينا الذهاب،")
        #expect(normalizedEllipsis[0].text == "\(rightToLeftMark)...אבל אולי")
    }

    @Test("Detects RTL content across languages and ignores mislabeled LTR files")
    func detectsRightToLeftSubtitleFiles() {
        let arabic = [SubtitleCue(startTime: 0, endTime: 1, text: "كيف حالك؟")]
        let persian = [SubtitleCue(startTime: 0, endTime: 1, text: "حالت چطور است؟")]
        let mislabeledEnglish = [SubtitleCue(startTime: 0, endTime: 1, text: "English text.")]

        #expect(SubtitleDirectionFormatter.needsNormalization(arabic, languageCode: "ar"))
        #expect(SubtitleDirectionFormatter.needsNormalization(persian, languageCode: "fa"))
        #expect(!SubtitleDirectionFormatter.needsNormalization(mislabeledEnglish, languageCode: "he"))
        #expect(SubtitleDirectionFormatter.normalizedCues(mislabeledEnglish, languageCode: "he") == mislabeledEnglish)
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
        let cues = [
            SubtitleCue(startTime: 1.25, endTime: 3.5, text: "שלום עולם."),
            SubtitleCue(
                startTime: 0.5,
                endTime: 1,
                text: "\u{200E}\u{202A}- מבוקש לחקירה -\u{202C}"
            ),
        ]
        let webVTT = HLSSubtitleInjector.webVTT(cues: cues, languageCode: "he")
        let playlist = HLSSubtitleInjector.subtitleMediaPlaylist(
            cues: cues,
            webVTTURL: URL(fileURLWithPath: "/tmp/external-subtitles.vtt")
        )

        #expect(webVTT.hasPrefix("WEBVTT\n"))
        #expect(webVTT.contains("00:00:01.250 --> 00:00:03.500"))
        #expect(webVTT.contains("\u{200F}שלום עולם."))
        #expect(webVTT.contains("\u{200F}- מבוקש לחקירה -"))
        #expect(!webVTT.contains("\u{200E}"))
        #expect(!webVTT.contains("\u{202A}"))
        #expect(!webVTT.contains("\u{202C}"))
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

    @Test("Loads built-in segmented HLS subtitles with timestamp maps")
    func loadsNativeHLSSubtitleRendition() async throws {
        let masterURL = try #require(URL(string: "https://media.example/master.m3u8"))
        let subtitlePlaylistURL = try #require(URL(string: "https://media.example/subs/en/index.m3u8"))
        let firstSegmentURL = try #require(URL(string: "https://media.example/subs/en/000.vtt"))
        let secondSegmentURL = try #require(URL(string: "https://media.example/subs/en/001.vtt"))
        let client = RoutingHTTPClient(bodies: [
            masterURL: Data(#"""
            #EXTM3U
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="eng",DEFAULT=YES,AUTOSELECT=YES,FORCED=NO,URI="subs/en/index.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=1000000,SUBTITLES="subs"
            video/index.m3u8
            """#.utf8),
            subtitlePlaylistURL: Data(#"""
            #EXTM3U
            #EXT-X-TARGETDURATION:5
            #EXTINF:5.0,
            000.vtt
            #EXTINF:5.0,
            001.vtt
            #EXT-X-ENDLIST
            """#.utf8),
            firstSegmentURL: Data(#"""
            WEBVTT
            X-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:900000

            00:00:01.000 --> 00:00:02.000
            First
            """#.utf8),
            secondSegmentURL: Data(#"""
            WEBVTT
            X-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:1350000

            00:00:00.500 --> 00:00:01.500
            Second
            """#.utf8),
        ])

        let renditions = await HLSNativeSubtitleLoader.load(
            from: PlaybackSource(
                url: masterURL,
                headers: ["Referer": "https://media.example/watch"],
                subtitles: [],
                preferredPeakBitRate: nil
            ),
            client: client
        )

        let rendition = try #require(renditions.first)
        #expect(renditions.count == 1)
        #expect(rendition.subtitle.providerName == "Built-in")
        #expect(rendition.subtitle.languageCode == "en")
        #expect(rendition.subtitle.isDefault)
        #expect(rendition.cues.map(\.text) == ["First", "Second"])
        #expect(abs(rendition.cues[0].startTime - 1) < 0.000_001)
        #expect(abs(rendition.cues[1].startTime - 5.5) < 0.000_001)
        #expect(await client.allRequestsCarriedHeader(named: "Referer"))
    }

    @Test("A saved subtitle sync rendition leaves the original cues untouched")
    func buildsIndependentSubtitleSyncRendition() async throws {
        let masterURL = try #require(URL(string: "https://media.example/video.m3u8"))
        let subtitle = SubtitleSource(
            providerID: "ktuvit",
            providerName: "Ktuvit",
            label: "Release 1080p",
            languageCode: "en",
            url: try #require(URL(string: "https://subtitles.example/subtitle.srt"))
        )
        let cue = SubtitleCue(startTime: 1, endTime: 2, text: "Subtitle")
        let versionID = UUID()
        let asset = try await HLSSubtitleInjector.prepare(
            source: PlaybackSource(
                url: masterURL,
                headers: [:],
                subtitles: [],
                preferredPeakBitRate: nil
            ),
            renditions: [
                HLSSubtitleRendition(subtitle: subtitle, cues: [cue]),
                HLSSubtitleRendition(
                    subtitle: subtitle,
                    cues: [cue],
                    timingOffset: 0.3,
                    syncVersionID: versionID,
                    displayNameOverride: "Saved Sync +0.3s"
                ),
            ],
            client: StubHTTPClient(body: Data("#EXTM3U\n#EXTINF:5,\nsegment.ts\n".utf8))
        )
        defer { try? FileManager.default.removeItem(at: asset.workingDirectory) }

        let master = try String(contentsOf: asset.masterPlaylistURL)
        let original = try String(contentsOf: asset.workingDirectory.appending(path: "external-subtitles-0.vtt"))
        let synced = try String(contentsOf: asset.workingDirectory.appending(path: "external-subtitles-1.vtt"))
        #expect(original.contains("00:00:01.000 --> 00:00:02.000"))
        #expect(synced.contains("00:00:01.300 --> 00:00:02.300"))
        #expect(asset.orderedDisplayNames.last == "Saved Sync +0.3s")
        #expect(asset.orderedLanguageTags == ["en-x-bsf-1", "en-x-bsf-2"])
        #expect(asset.languageTags.count == 2)
        #expect(master.contains(#"NAME="Saved Sync +0.3s",LANGUAGE="en-x-bsf-2""#))
    }

    @MainActor
    @Test("AVPlayer uses private-use labels only for third-party subtitle versions", arguments: ["ktuvit", "wizdom", "native-hls", "stream"])
    func nativeSubtitleSelectionNames(providerID: String) async throws {
        let subtitle = SubtitleSource(id: "he", providerID: providerID, providerName: providerID,
                                      label: "Release", languageCode: "he", url: URL(string: "https://example.com/sub.srt")!)
        let asset = try await HLSSubtitleInjector.prepare(
            source: PlaybackSource(url: URL(string: "https://example.com/video.m3u8")!, headers: [:], subtitles: [], preferredPeakBitRate: nil),
            renditions: [
                HLSSubtitleRendition(subtitle: subtitle, cues: [SubtitleCue(startTime: 0, endTime: 5, text: "Hello")]),
                HLSSubtitleRendition(subtitle: subtitle, cues: [SubtitleCue(startTime: 0, endTime: 5, text: "Hello")], displayNameOverride: "Hebrew (Resynced 1)"),
            ],
            client: StubHTTPClient(body: Data("#EXTM3U\n#EXTINF:5,\nsegment.ts\n#EXT-X-ENDLIST\n".utf8))
        )
        // One black H.264 frame in MPEG-TS; keep this check entirely offline.
        let video = Data(base64Encoded: "R0AREABC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9HQAAQAACwDQABwQAAAAHwACqxBLL//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////0dQABAAArASAAHBAADhAPAAG+EA8AAVvU1W////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R0EAMAdQAAB7DH4AAAAB4AAAgIAFIQAH2GEAAAABCfAAAAABZ2QACqzZXsBEAAADAAQAAAMACDxIllgAAAABaOvjyyLAAAABBgX//6ncRem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY1IHIzMjIyIGIzNTYwNWEgLSBILjI2NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0cDovL3d3dy52aWRlb2xHAQARYW4ub3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTEgcmVmPTMgZGVibG9jaz0xOjA6MCBhbmFseXNlPTB4MzoweDExMyBtZT1oZXggc3VibWU9NyBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0xIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MSA4eDhkY3Q9MSBjcW09MCBkZWFkem9uZT0yMUcBABIsMTEgZmFzdF9wc2tpcD0xIGNocm9tYV9xcF9vZmZzZXQ9LTIgdGhyZWFkcz0xIGxvb2thaGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MyBiX3B5cmFtaWQ9MiBiX2FkYXB0PTEgYl9iRwEAE2lhcz0wIGRpcmVjdD0xIHdlaWdodGI9MSBvcGVuX2dvcD0wIHdlaWdodHA9MiBrZXlpbnQ9MjUwIGtleWludF9taW49MSBzY2VuZWN1dD00MCBpbnRyYV9yZWZyZXNoPTAgcmNfbG9va2FoZWFkPTQwIHJjPWNyZiBtYnRyZWU9MSBjcmY9MjMuMCBxY29tcD0wLjYwIHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW9HAQA0kwD//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////z0xLjQwIGFxPTE6MS4wMACAAAABZYiEABX//vfJ78Cm69vfgQ==")!
        let videoURL = asset.workingDirectory.appending(path: "video.m3u8")
        let segmentURL = asset.workingDirectory.appending(path: "video.ts")
        try video.write(to: segmentURL)
        try Data("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:1.0,\n\(segmentURL.absoluteString)\n#EXT-X-ENDLIST\n".utf8).write(to: videoURL)
        let master = try String(contentsOf: asset.masterPlaylistURL)
            .replacingOccurrences(of: "https://example.com/video.m3u8", with: videoURL.absoluteString)
        try Data(master.utf8).write(to: asset.masterPlaylistURL)
        let server = HLSSubtitleLoopbackServer()
        let url = try await server.publish(asset)
        let (masterData, _) = try await URLSession.shared.data(from: url)
        #expect(String(data: masterData, encoding: .utf8)?.contains("#EXTM3U") == true)
        let avAsset = AVURLAsset(url: url)
        let group = try #require(try await avAsset.loadMediaSelectionGroup(for: .legible))
        #expect(group.options.count == 2)
        var titles: [String] = []
        for option in group.options {
            let isThirdParty = providerID == "ktuvit" || providerID == "wizdom"
            #expect(option.extendedLanguageTag?.contains("-x-bsf-") == isThirdParty)
            if isThirdParty {
                #expect(option.displayName.localizedCaseInsensitiveContains("private"))
            } else {
                #expect(option.extendedLanguageTag == "he")
                #expect(!option.displayName.localizedCaseInsensitiveContains("private"))
            }
            for metadata in option.commonMetadata where metadata.commonKey == .commonKeyTitle {
                if let title = try await metadata.load(.stringValue) { titles.append(title) }
            }
        }
        #expect(Set(titles) == Set(asset.orderedDisplayNames))
        server.clear()
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
        let responseBody = url.path.hasPrefix("/playlist/")
            ? Data("#EXTM3U\n#EXTINF:5,\nsegment.ts\n".utf8)
            : body
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: ["Content-Type": "text/html"]
        ))
        return HTTPResponse(data: responseBody, response: response)
    }
}

private actor FailingThenSucceedingHTTPClient: HTTPClientProtocol {
    let failuresBeforeSuccess: Int
    private(set) var requestCount = 0
    private(set) var cachePolicies: [URLRequest.CachePolicy] = []

    init(failuresBeforeSuccess: Int) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func data(for request: URLRequest) async throws -> HTTPResponse {
        requestCount += 1
        cachePolicies.append(request.cachePolicy)
        guard requestCount > failuresBeforeSuccess else {
            throw AppError.providerUnavailable("Transient subtitle failure")
        }
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: ["Content-Type": "text/vtt"]
        ))
        return HTTPResponse(data: Data("WEBVTT\n".utf8), response: response)
    }
}

private actor RoutingHTTPClient: HTTPClientProtocol {
    let bodies: [URL: Data]
    private var requests: [URLRequest] = []

    init(bodies: [URL: Data]) {
        self.bodies = bodies
    }

    func data(for request: URLRequest) async throws -> HTTPResponse {
        guard let url = request.url,
              let body = bodies[url],
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/2",
                headerFields: ["Content-Type": url.pathExtension == "vtt" ? "text/vtt" : "application/vnd.apple.mpegurl"]
              ) else { throw AppError.invalidResponse }
        requests.append(request)
        return HTTPResponse(data: body, response: response)
    }

    func allRequestsCarriedHeader(named name: String) -> Bool {
        !requests.isEmpty && requests.allSatisfy { $0.value(forHTTPHeaderField: name) != nil }
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
