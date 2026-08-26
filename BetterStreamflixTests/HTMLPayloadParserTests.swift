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
