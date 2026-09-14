import Foundation
import Testing
@testable import Vela

@Suite("Automatic playback source discovery")
struct PlaybackDiscoveryTests {
    static let request = PlaybackRequest(media: MediaItem(id: "1", providerID: "tmdb", kind: .movie, title: "Example", releaseDate: "2020-01-01", tmdbID: 1), episode: nil)

    static func candidate(_ id: String, language: String = "en", kind: StreamSubtitleKind = .selectable) -> PlaybackCandidate {
        PlaybackCandidate(id: id, preference: .init(providerID: id, serverName: "HD", audioLanguage: language),
            providerName: id, subtitleKind: kind,
            resolve: { PlaybackSource(url: URL(string: "https://example.com/\(id).m3u8")!, headers: [:], subtitles: [], preferredPeakBitRate: nil) })
    }
    static func prepare(_ candidate: PlaybackCandidate) async throws -> PlayableStream {
        PlayableStream(candidate: candidate, source: try await candidate.resolve(), qualities: [])
    }

    @Test("Saved source wins; audio and controllable subtitles guide automatic selection")
    func ranking() async throws {
        let english = try await Self.prepare(Self.candidate("english"))
        let japanese = try await Self.prepare(Self.candidate("japanese", language: "ja"))
        let embedded = try await Self.prepare(Self.candidate("embedded", kind: .embeddedEnglish))
        #expect(StreamSelectionPolicy().best(in: [embedded, japanese, english])?.id == "english")
        #expect(StreamSelectionPolicy(audioLanguage: "ja").best(in: [english, japanese])?.id == "japanese")
        #expect(StreamSelectionPolicy(preference: japanese.candidate.preference).best(in: [english, japanese])?.id == "japanese")
        #expect(StreamSelectionPolicy(preference: Self.candidate("missing").preference).best(in: [embedded, english])?.id == "english")
        #expect(StreamSelectionPolicy().best(in: [embedded])?.id == "embedded")
    }

    @Test("Quality preference breaks ties before readiness")
    func qualityRanking() async throws {
        let low = try await Self.prepare(Self.candidate("low"))
        let high = try await Self.prepare(Self.candidate("high"))
        let first = PlayableStream(candidate: low.candidate, source: low.source,
            qualities: [.init(width: 640, height: 360, peakBitRate: 500_000)])
        let second = PlayableStream(candidate: high.candidate, source: high.source,
            qualities: [.init(width: 1920, height: 1080, peakBitRate: 3_000_000)])
        #expect(StreamSelectionPolicy(qualityHeight: 1080).best(in: [first, second])?.id == "high")
        #expect(StreamSelectionPolicy().best(in: [first, second])?.id == "low")
    }

    @MainActor @Test("Late sources are appended without changing the delivered initial selection")
    func lateSources() async throws {
        let discovery = PlaybackDiscovery(settleDelay: .milliseconds(10), deadline: .seconds(2), prepare: { try await Self.prepare($0) })
        defer { discovery.cancel() }
        let first = try await discovery.start(context: .init(request: Self.request), providers: [
            DelayedProvider(id: "early", delay: .milliseconds(1)),
            DelayedProvider(id: "late", delay: .milliseconds(90))
        ], policy: .init())
        #expect(first.id == "early")
        try await Task.sleep(for: .milliseconds(150))
        #expect(discovery.streams.map(\.id) == ["early", "late"])
        #expect(!discovery.isSearching)
    }

    @MainActor @Test("Failed providers do not suppress a usable source")
    func partialFailure() async throws {
        let discovery = PlaybackDiscovery(prepare: { try await Self.prepare($0) })
        let result = try await discovery.start(context: .init(request: Self.request), providers: [
            DelayedProvider(id: "bad", fails: true), DelayedProvider(id: "good")
        ], policy: .init())
        #expect(result.id == "good")
        discovery.cancel()
    }

    @MainActor @Test("The overall deadline ends a slow lookup")
    func deadline() async {
        let discovery = PlaybackDiscovery(deadline: .milliseconds(20), prepare: { try await Self.prepare($0) })
        do {
            _ = try await discovery.start(context: .init(request: Self.request), providers: [DelayedProvider(id: "slow", delay: .seconds(10))], policy: .init())
            Issue.record("Expected no stream")
        } catch { #expect(!discovery.isSearching) }
        discovery.cancel()
    }

    @MainActor @Test("Cancellation rejects stale results")
    func cancellation() async throws {
        let discovery = PlaybackDiscovery(prepare: { try await Self.prepare($0) })
        let task = Task { try await discovery.start(context: .init(request: Self.request), providers: [DelayedProvider(id: "slow", delay: .seconds(10))], policy: .init()) }
        try await Task.sleep(for: .milliseconds(10))
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") } catch { #expect(error is CancellationError) }
        #expect(discovery.streams.isEmpty)
    }

    @MainActor @Test("All missing sources produce a single failure")
    func empty() async {
        let discovery = PlaybackDiscovery(prepare: { try await Self.prepare($0) })
        do { _ = try await discovery.start(context: .init(request: Self.request), providers: [], policy: .init()); Issue.record("Expected failure") }
        catch { #expect(!discovery.isSearching) }
    }
}

private struct DelayedProvider: PlaybackProvider {
    let id: String
    var delay: Duration = .zero
    var fails = false
    func candidates(for context: PlaybackLookupContext) async throws -> [PlaybackCandidate] {
        try await Task.sleep(for: delay)
        if fails { throw AppError.noStream }
        return [PlaybackDiscoveryTests.candidate(id)]
    }
}

@Suite("Anime provider matching and extraction")
struct AnimePlaybackTests {
    func context(season: Int = 1) -> PlaybackLookupContext {
        let show = MediaItem(id: "1", providerID: "tmdb", kind: .series, title: "Example Anime", originalTitle: "Example Original", releaseDate: "2020-01-01", tmdbID: 1, genres: [.init(id: "16", name: "Animation")])
        let episode = MediaEpisode(id: "2", providerID: "tmdb", showID: "1", seasonNumber: season, number: 1, title: "A new beginning", overview: nil, posterURL: nil)
        return PlaybackLookupContext(request: .init(media: show, episode: episode))
    }

    @Test("Matching requires title, year, and media type")
    func identity() {
        #expect(AnimeMatching.matches(names: ["Example Original"], year: 2020, kind: .series, context: context(), separateSeason: false))
        #expect(!AnimeMatching.matches(names: ["Example Anime"], year: 2021, kind: .series, context: context(), separateSeason: false))
        #expect(!AnimeMatching.matches(names: ["Example Anime"], year: 2020, kind: .movie, context: context(), separateSeason: false))
        #expect(!AnimeMatching.matches(names: ["Example Anime"], year: nil, kind: .series, context: context(), separateSeason: false))
    }

    @Test("Continuous numbering needs a verified offset and matching episode title")
    func continuousNumbering() {
        var request = context(season: 2)
        let episodes = [AnimeEpisodeMatch(id: "13", number: 13, title: "A new beginning")]
        #expect(AnimeMatching.episode(in: episodes, context: request, separateSeason: false) == nil)
        request.absoluteEpisodeNumber = 13
        #expect(AnimeMatching.episode(in: episodes, context: request, separateSeason: false)?.id == "13")
        #expect(AnimeMatching.episode(in: [.init(id: "wrong", number: 13, title: "Something else")], context: request, separateSeason: false) == nil)
        #expect(AnimeMatching.episode(in: [.init(id: "1", number: 1, title: "A new beginning")], context: request, separateSeason: true)?.id == "1")
        #expect(AnimeMatching.episode(in: [.init(id: "1", number: 1, title: "Special")], context: context(season: 0), separateSeason: false) == nil)
    }

    @Test("TMDB local and continuous season numbering are mapped exactly once")
    func tmdbNumbering() {
        #expect(TMDBClient.absoluteEpisodeNumber(episodeNumber: 1, seasonNumber: 2,
            seasonEpisodeCount: 13, precedingSeasonCounts: [12]) == 13)
        #expect(TMDBClient.absoluteEpisodeNumber(episodeNumber: 62, seasonNumber: 2,
            seasonEpisodeCount: 16, precedingSeasonCounts: [61]) == 62)
        #expect(TMDBClient.absoluteEpisodeNumber(episodeNumber: 1, seasonNumber: 3,
            seasonEpisodeCount: 12, precedingSeasonCounts: [12]) == nil)
    }

    @Test("Episode-title corroboration rejects generic and unrelated labels")
    func episodeEvidence() {
        #expect(AnimeMatching.episodeTitlesAgree("You Aren't E-Rank, Are You?", "You Aren’t E-rank, Are You"))
        #expect(!AnimeMatching.episodeTitlesAgree("A new beginning", "Full"))
        #expect(!AnimeMatching.episodeTitlesAgree("Episode 1", "Episode 1"))
        #expect(!AnimeMatching.episodeTitlesAgree("A new beginning", "An old enemy returns"))
    }

    @Test("HTML parser preserves nested server metadata and attribute order")
    func html() {
        let html = AnimeHTML.parse(#"<div data-type='dub' class='type'><ul><li data-link-id='123'>HD &amp; 1</li></ul></div>"#)
        let server = html.first { !$0["data-link-id"].isEmpty }
        #expect(server?.text == "HD & 1")
        #expect(server?.ancestor { !$0["data-type"].isEmpty }?["data-type"] == "dub")
    }

    @MainActor @Test("Encrypted source responses receive a refreshable CDN token")
    func encryptedSources() throws {
        let decoded = try AnimeStreamResolver.decodeNekostream("wdeBruh3qqn_i5wUNnyaPbKpTPjtcIqcJEMLxz3xCfFGXP4hFKAGHO-Q-yT7pLg5yT9k5Ga1L3sCQOuNwpkEqUXxsgVoBo5VoViEgMu8-Xtpr-QEKO5n9srHbNIzDJKpZfHHAR0vXZSEtxc_1vvIqwh_VVsbwTjbWOTVpHyF0Q0", now: Date(timeIntervalSince1970: 1000))
        let url = try #require(decoded["file"].flatMap(URL.init(string:)))
        #expect(url.host == "example.com")
        #expect(PlayerSession.expirationDate(in: url) == Date(timeIntervalSince1970: 1090))
        #expect(throws: (any Error).self) { try AnimeStreamResolver.decodeNekostream("not-a-source") }
    }

    @Test("Megacloud encrypted sources validate ranges and decrypt the payload")
    func megacloudSources() throws {
        let script = "switch(x){case 0x1:a=b,c=d;}var z=0,b=0x0,d=0x3;"
        let decoded = try AnimeStreamResolver.decryptSources("abcU2FsdGVkX18xMjM0NTY3OKBGR9dW9L6KTbpXJU8nDOZUWIN8zmRGi4ewUEoRYPnSTr0E+oM3YWaMqsRBPlLqfQ==", script: script)
        #expect(String(data: decoded, encoding: .utf8) == #"[{"file":"https://example.com/master.m3u8"}]"#)
        #expect(throws: (any Error).self) { try AnimeStreamResolver.decryptSources("short", script: "switch(x){case 0x1:a=b,c=d;}var z=0,b=0xffff,d=0x3;") }
    }

    @Test("Source extraction retains headers and normal built-in language tags")
    func sources() throws {
        let payload = Data(#"{"sources":{"file":"https://example.com/master.m3u8"},"tracks":[{"kind":"captions","file":"/en.vtt","label":"English","default":true},{"kind":"thumbnails","file":"/thumb.vtt"}]}"#.utf8)
        let source = try AnimeStreamResolver.source(from: payload, relativeTo: URL(string: "https://example.com/embed")!, headers: ["Referer": "https://example.com/"])
        #expect(source.subtitles.count == 1)
        #expect(source.subtitles.first?.languageCode == "en")
        #expect(source.subtitles.first?.providerID == "stream")
        #expect(source.subtitles.first?.isDefault == true)
        #expect(source.headers["Referer"] == "https://example.com/")
        #expect(throws: (any Error).self) {
            try AnimeStreamResolver.source(from: Data(#"{"sources":null}"#.utf8), relativeTo: URL(string: "https://example.com")!, headers: [:])
        }
    }
}

@Suite("Anime provider response fixtures")
struct AnimeProviderFixtureTests {
    @Test("Anikoto resolves title, episode, dub server and playable source")
    func anikoto() async throws {
        let client = AnimeFixtureClient(site: .anikoto)
        let provider = AnimePlaybackProvider(site: .anikoto, client: client)
        let candidates = try await provider.candidates(for: AnimePlaybackTests().context())
        #expect(candidates.count == 1)
        let candidate = try #require(candidates.first)
        #expect(candidate.preference.audioLanguage == "en")
        #expect(candidate.preference.serverName == "HD-1")
        let source = try await candidate.resolve()
        #expect(source.url.absoluteString == "https://video.example/master.m3u8")
        #expect(source.headers["Referer"] == "https://megaplay.buzz/")
    }

    @Test("Current HiAnime API discovers base64-encoded servers")
    func hiAnime() async throws {
        let provider = AnimePlaybackProvider(site: .hiAnime, client: AnimeFixtureClient(site: .hiAnime))
        let candidates = try await provider.candidates(for: AnimePlaybackTests().context())
        #expect(candidates.count == 1)
        let candidate = try #require(candidates.first)
        #expect(candidate.preference.audioLanguage == "ja")
        #expect(try await candidate.resolve().url.absoluteString == "https://video.example/master.m3u8")
    }

    @Test("A rejected recap does not hide the matching series on the next page")
    func rejectsRecapThenContinues() async throws {
        let provider = AnimePlaybackProvider(site: .hiAnime, client: RecapFixtureClient())
        #expect(try await provider.candidates(for: AnimePlaybackTests().context()).count == 1)
    }

    @Test("Duplicate equally matching titles are rejected")
    func ambiguousTitles() async throws {
        let provider = AnimePlaybackProvider(site: .anikoto, client: AnimeFixtureClient(site: .anikoto, ambiguous: true))
        #expect(try await provider.candidates(for: AnimePlaybackTests().context()).isEmpty)
    }

    @Test("Missing or changed provider responses do not invent streams")
    func changedPage() async throws {
        let provider = AnimePlaybackProvider(site: .hiAnime, client: AnimeFixtureClient(site: .hiAnime, empty: true))
        #expect(try await provider.candidates(for: AnimePlaybackTests().context()).isEmpty)
    }
}

private struct AnimeFixtureClient: HTTPClientProtocol {
    let site: AnimePlaybackProvider.Site
    var ambiguous = false
    var empty = false
    func data(for request: URLRequest) async throws -> HTTPResponse {
        let url = try #require(request.url)
        let path = url.path
        let host = site == .anikoto ? "https://anikoto.net" : "https://hianime.cv"
        let titlePath = site == .anikoto ? "/watch/example" : "/anime/example/"
        let body: String
        if empty { body = "<html>Site unavailable</html>" }
        else if path == "/filter" || path == "/" {
            body = "<a href='\(host)\(titlePath)'><img src='poster.jpg'></a><a href='\(host)\(titlePath)'>Example Anime</a>" +
                (ambiguous ? "<a href='\(host)/watch/duplicate'>Example Anime</a>" : "")
        } else if path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == titlePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) || path == "/watch/duplicate" {
            body = "<h1>Example Anime</h1><div id='w-info'><div>Aired: <span>Jan 1, 2020</span></div><div>Type: <span>TV</span></div></div><div id='watch-main' data-id='12'></div><a class='btn-play' href='/example-episode-1/'>Play</a>"
        } else if path == "/example-episode-1" {
            body = #"<div id="ani_detail" data-anime-id="12"></div><script>var hianime_ep_ajax = {"episode_nonce":"fixture"};</script>"#
        } else if path == "/ajax/episode/list/12" {
            body = try json(["result": "<div class='episodes'><a data-ids='token' data-num='1'><span class='d-title'>A new beginning</span></a></div>"])
        } else if path == "/ajax/server/list" {
            body = try json(["result": "<div class='servers'><div class='type' data-type='dub'><li data-link-id='server1'>HD-1</li></div></div>"])
        } else if path == "/ajax/server" {
            body = #"{"result":{"url":"https://megaplay.buzz/stream/1/dub"}}"#
        } else if path == "/wp-admin/admin-ajax.php" {
            let form = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            #expect(request.httpMethod == "POST")
            #expect(form.contains("nonce=fixture"))
            if form.contains("hianime_episode_list") {
                body = try json(["html": "<a class='ep-item' data-id='ep1' data-number='1'><span class='ep-name'>A new beginning</span></a>"])
            } else {
                let hash = Data("https://megaplay.buzz/stream/1/sub".utf8).base64EncodedString()
                body = try json(["html": "<div class='server-item' data-type='sub' data-server-name='HD-SUB' data-hash='\(hash)'></div>"])
            }
        } else if path.hasPrefix("/stream/getSources") {
            #expect(request.value(forHTTPHeaderField: "X-Requested-With") == "XMLHttpRequest")
            body = #"{"sources":{"file":"https://video.example/master.m3u8"},"tracks":[{"file":"https://video.example/en.vtt","label":"English","kind":"captions"}]}"#
        } else if path.hasPrefix("/stream/1/") {
            body = #"<div data-id="file1" id="megaplay-player"></div><script>type: 'sub'</script>"#
        } else { throw AppError.noStream }
        return HTTPResponse(data: Data(body.utf8), response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    private func json(_ value: [String: String]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self) }
}

private struct RecapFixtureClient: HTTPClientProtocol {
    func data(for request: URLRequest) async throws -> HTTPResponse {
        let url = try #require(request.url)
        let body: String?
        let page = URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems?.first { $0.name == "page" }?.value
        if url.path == "/", page == "1" {
            body = "<a href='/anime/recap/' title='Example Anime'>Example Anime Recap</a>"
        } else if url.path == "/anime/recap" {
            body = "<h1>Example Anime Recap</h1><div>Type: TV</div><a class='btn-play' href='/recap-episode-1/'>Play</a>"
        } else if url.path == "/recap-episode-1" {
            body = #"<div id="ani_detail" data-anime-id="99"></div><script>{"episode_nonce":"fixture"}</script>"#
        } else if String(data: request.httpBody ?? Data(), encoding: .utf8)?.contains("anime_id=99") == true {
            body = #"{"html":"<a class='ep-item' data-id='recap' data-number='1'><span class='ep-name'>Full</span></a>"}"#
        } else { body = nil }
        guard let body else { return try await AnimeFixtureClient(site: .hiAnime).data(for: request) }
        return HTTPResponse(data: Data(body.utf8), response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
