import Foundation

/// Native client for AnimeIL's public stream API. The endpoint follows the
/// Stremio resource shape, but Vela consumes it directly as a playback source.
struct AnimeILPlaybackProvider: PlaybackProvider {
    let client: any HTTPClientProtocol
    let baseURL: URL
    let id = "animeil"

    init(
        client: any HTTPClientProtocol = HTTPClient(),
        baseURL: URL = URL(string: "https://addon.animeil.qzz.io")!
    ) {
        self.client = client
        self.baseURL = baseURL
    }

    func candidates(for context: PlaybackLookupContext) async throws -> [PlaybackCandidate] {
        guard context.request.media.genres.contains(where: { $0.id == "16" || $0.name.lowercased() == "animation" }),
              let imdbID = context.request.media.imdbID?.trimmingCharacters(in: .whitespacesAndNewlines),
              imdbID.range(of: #"^tt\d{7,9}$"#, options: .regularExpression) != nil else { return [] }

        let mediaType: String
        let contentID: String
        switch context.request.media.kind {
        case .movie:
            mediaType = "movie"
            contentID = imdbID
        case .series:
            guard let episode = context.request.episode, episode.seasonNumber >= 0, episode.number > 0 else { return [] }
            mediaType = "series"
            contentID = "\(imdbID):\(episode.seasonNumber):\(episode.number)"
        }

        guard let endpoint = URL(string: "stream/\(mediaType)/\(contentID).json", relativeTo: baseURL)?.absoluteURL else {
            throw AppError.invalidURL
        }
        var request = URLRequest.providerRequest(url: endpoint, referer: baseURL, acceptsJSON: true)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadRevalidatingCacheData
        let response = try await client.data(for: request)
        let payload: StreamPayload
        do { payload = try JSONDecoder().decode(StreamPayload.self, from: response.data) }
        catch { throw AppError.decoding(error.localizedDescription) }

        return payload.streams.enumerated().compactMap { index, stream in
            guard let url = stream.url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            let serverName = stream.name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "AnimeIL"
            let headers = stream.behaviorHints?.proxyHeaders?.request ?? [:]
            return PlaybackCandidate(
                id: "\(id):\(index):\(url.absoluteString)",
                preference: .init(providerID: id, serverName: serverName, audioLanguage: "he"),
                providerName: "AnimeIL",
                subtitleKind: .unknown,
                resolve: {
                    PlaybackSource(url: url, headers: headers, subtitles: [], preferredPeakBitRate: nil)
                }
            )
        }
    }

    private struct StreamPayload: Decodable, Sendable {
        let streams: [Stream]
    }

    private struct Stream: Decodable, Sendable {
        let name: String?
        let url: URL?
        let behaviorHints: BehaviorHints?
    }

    private struct BehaviorHints: Decodable, Sendable {
        let proxyHeaders: ProxyHeaders?
    }

    private struct ProxyHeaders: Decodable, Sendable {
        let request: [String: String]?
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// Small read-only HTML tree for the provider pages; never evaluates page scripts.
final class AnimeHTML {
    let tag: String
    let attributes: [String: String]
    var children: [AnimeHTML] = []
    weak var parent: AnimeHTML?
    private var content = ""
    init(tag: String = "root", attributes: [String: String] = [:]) { self.tag = tag; self.attributes = attributes }
    subscript(_ key: String) -> String { attributes[key] ?? "" }
    var text: String { HTMLPayloadParser.decodeEntities(content).split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    func hasClass(_ name: String) -> Bool { self["class"].split(separator: " ").contains(Substring(name)) }
    func all(_ predicate: (AnimeHTML) -> Bool) -> [AnimeHTML] {
        children.flatMap { (predicate($0) ? [$0] : []) + $0.all(predicate) }
    }
    func first(_ predicate: (AnimeHTML) -> Bool) -> AnimeHTML? { all(predicate).first }
    func ancestor(_ predicate: (AnimeHTML) -> Bool) -> AnimeHTML? {
        var node = parent
        while let current = node { if predicate(current) { return current }; node = current.parent }
        return nil
    }
    static func captures(_ pattern: String, in string: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        return regex.matches(in: string, range: NSRange(string.startIndex..., in: string)).map { match in
            (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: string).map { String(string[$0]) } ?? "" }
        }
    }
    static func parse(_ html: String) -> AnimeHTML {
        let root = AnimeHTML()
        var stack = [root]
        let tokens = captures(#"<!--[\s\S]*?-->|<[^>]+>|[^<]+"#, in: html)
        let voids: Set<String> = ["img", "br", "hr", "input", "meta", "link", "source", "track", "wbr", "area", "base", "embed"]
        for match in tokens {
            let token = match[0]
            if token.hasPrefix("</") {
                let name = token.dropFirst(2).prefix { $0.isLetter || $0.isNumber }.lowercased()
                if let index = stack.lastIndex(where: { $0.tag == name }), index > 0 { stack.removeSubrange(index...) }
            } else if token.hasPrefix("<") {
                guard let name = captures(#"^<([a-z][a-z0-9-]*)"#, in: token).first?[1] else { continue }
                var attrs: [String: String] = [:]
                for attr in captures(#"([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#, in: token) {
                    attrs[attr[1].lowercased()] = HTMLPayloadParser.decodeEntities(attr[2...4].first { !$0.isEmpty } ?? "")
                }
                let node = AnimeHTML(tag: name.lowercased(), attributes: attrs)
                node.parent = stack.last
                stack.last?.children.append(node)
                if !voids.contains(node.tag), !token.hasSuffix("/>") { stack.append(node) }
            } else {
                for node in stack { node.content += token + " " }
            }
        }
        return root
    }
}

struct AnimeEpisodeMatch: Sendable {
    let id: String
    let number: Int
    let title: String
}

enum AnimeMatching {
    static func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    static func year(_ text: String?) -> Int? {
        guard let text, let value = AnimeHTML.captures(#"\b((?:19|20)\d{2})\b"#, in: text).first?[1] else { return nil }
        return Int(value)
    }
    static func isSeasonTitle(_ name: String, baseTitles: [String], season: Int) -> Bool {
        guard season > 1 else { return false }
        let normalizedName = normalized(name)
        let markers = [" season \(season)", " \(season)nd season", " \(season)rd season", " \(season)th season"]
        return baseTitles.contains { title in
            let base = normalized(title)
            guard !base.isEmpty else { return false }
            return markers.contains { marker in
                let prefix = base + marker
                return normalizedName == prefix || normalizedName.hasPrefix(prefix + " ")
            }
        }
    }

    static func matches(names: [String], year: Int?, kind: MediaKind, context: PlaybackLookupContext, separateSeason: Bool, allowMissingYear: Bool = false) -> Bool {
        guard kind == context.request.media.kind else { return false }
        let wanted = context.titles + (separateSeason ? [context.seasonTitle].compactMap { $0 } : [])
        let expectedYear = separateSeason ? context.seasonYear : self.year(context.request.media.releaseDate)
        if let year, let expectedYear {
            guard year == expectedYear else { return false }
        } else if !allowMissingYear { return false }
        return names.contains { name in
            wanted.contains { normalized($0) == normalized(name) } ||
                (separateSeason && isSeasonTitle(name, baseTitles: context.titles, season: context.request.episode?.seasonNumber ?? 1))
        }
    }
    static func episodeTitlesAgree(_ first: String?, _ second: String) -> Bool {
        guard let first else { return false }
        let stop: Set<String> = ["a", "an", "the", "i", "m", "is", "s", "of", "to", "be", "who", "will", "and", "it", "episode"]
        func words(_ value: String) -> Set<String> {
            var result: Set<String> = []
            for substring in normalized(value).split(separator: " ") {
                let word = String(substring)
                guard word.count > 1, !stop.contains(word) else { continue }
                result.insert(word.hasSuffix("s") && word.count > 4 ? String(word.dropLast()) : word)
            }
            return result
        }
        let a = words(first), b = words(second), common = a.intersection(b).count
        if normalized(first) == normalized(second), a.count >= 2 { return true }
        return common >= 3 && Double(common) / Double(max(1, min(a.count, b.count))) >= 0.75
    }

    static func episode(in episodes: [AnimeEpisodeMatch], context: PlaybackLookupContext, separateSeason: Bool) -> AnimeEpisodeMatch? {
        guard let requested = context.request.episode else { return episodes.count == 1 ? episodes.first : nil }
        guard requested.seasonNumber > 0 else { return nil }
        let number = separateSeason || requested.seasonNumber == 1 ? requested.number : context.absoluteEpisodeNumber
        guard let number else { return nil }
        let matches = episodes.filter { $0.number == number }
        guard matches.count == 1, let match = matches.first else { return nil }
        // Continuous numbering across TMDB seasons requires corroborating episode metadata.
        if !separateSeason && requested.seasonNumber > 1 {
            guard let title = requested.title, normalized(title).count > 4,
                  episodeTitlesAgree(title, match.title) else { return nil }
        }
        return match
    }
}

struct AnimePlaybackProvider: PlaybackProvider {
    enum Site: String, Sendable { case hiAnime = "hianime", anikoto }
    let site: Site
    let client: any HTTPClientProtocol
    let baseURL: URL
    var id: String { site.rawValue }
    var name: String { site == .hiAnime ? "HiAnime" : "Anikoto" }
    init(site: Site, client: any HTTPClientProtocol = HTTPClient(), baseURL: URL? = nil) {
        self.site = site
        self.client = client
        self.baseURL = baseURL ?? URL(string: site == .hiAnime ? "https://hianime.cv" : "https://anikoto.net")!
    }

    private func url(_ path: String, query: [String: String] = [:]) throws -> URL {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { throw AppError.invalidURL }
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) } }
        guard let result = components.url else { throw AppError.invalidURL }
        return result
    }
    private func fetch(_ url: URL, referer: URL? = nil, form: [String: String]? = nil) async throws -> String {
        var request = URLRequest.providerRequest(url: url, referer: referer ?? baseURL, acceptsJSON: url.path.contains("ajax") || url.path.contains("api/"))
        request.timeoutInterval = 12
        request.setValue("country_code=US", forHTTPHeaderField: "Cookie")
        if let form {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var fields = URLComponents()
            fields.queryItems = form.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }
            request.httpBody = fields.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        }
        let response = try await client.data(for: request)
        guard let result = String(data: response.data, encoding: .utf8) else { throw AppError.invalidResponse }
        return result
    }
    private func json(_ string: String) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any] else { throw AppError.invalidResponse }
        return value
    }
    private func ajaxHTML(_ url: URL, referer: URL, form: [String: String]? = nil) async throws -> AnimeHTML {
        let payload = try json(await fetch(url, referer: referer, form: form))
        guard let html = payload["result"] as? String ?? payload["html"] as? String else { throw AppError.noStream }
        return AnimeHTML.parse(html)
    }

    func candidates(for context: PlaybackLookupContext) async throws -> [PlaybackCandidate] {
        // TMDB's Animation genre includes anime but avoids querying anime sites for live-action titles.
        guard context.request.media.genres.contains(where: { $0.id == "16" || $0.name.lowercased() == "animation" }) else { return [] }
        var visited: Set<URL> = []
        var matches: [[PlaybackCandidate]] = []
        let season = context.request.episode?.seasonNumber ?? 1
        let seasonQueries = season > 1 ? context.titles.prefix(1).map { "\($0) Season \(season)" } : []
        let queries = Array(NSOrderedSet(array: seasonQueries + context.titles).array.compactMap { $0 as? String }.prefix(6))
        for query in queries {
            try Task.checkCancellation()
            for page in 1...2 {
                try Task.checkCancellation()
                let searchQuery = AnimeMatching.normalized(query)
                let searchURL = try url(site == .hiAnime ? "/" : "/filter",
                    query: site == .hiAnime ? ["s": searchQuery, "page": String(page)] : ["keyword": searchQuery, "page": String(page)])
                let searchText: String
                do { searchText = try await fetch(searchURL) }
                catch where error.isCancellation { throw error }
                catch { break }
                let search = AnimeHTML.parse(searchText)
                let links = search.all { $0.tag == "a" && $0["href"].contains(site == .hiAnime ? "/anime/" : "/watch/") }
                if links.isEmpty { break }
                for link in links {
                    let href = link["href"].components(separatedBy: "/ep-").first ?? link["href"]
                    guard let detailURL = URL(string: href, relativeTo: baseURL)?.absoluteURL,
                          detailURL.host == baseURL.host, !visited.contains(detailURL) else { continue }
                    // Avoid fetching every recommendation: title/aliases must match before detail validation.
                    let names = [link.text, link["title"], link["data-jname"], link["data-jp"], link["data-en"], link.first { $0.hasClass("d-title") }?.text ?? ""]
                    let wanted = context.titles + context.titles.map { "\($0) Season \(season)" } + [context.seasonTitle].compactMap { $0 }
                    guard names.contains(where: { n in
                        wanted.contains { AnimeMatching.normalized(n) == AnimeMatching.normalized($0) } ||
                        AnimeMatching.isSeasonTitle(n, baseTitles: context.titles, season: season)
                    }) else { continue }
                    visited.insert(detailURL)
                    let detailText: String
                    do { detailText = try await fetch(detailURL) }
                    catch where error.isCancellation { throw error }
                    catch { continue }
                    let detail = AnimeHTML.parse(detailText)
                    let titleNode = detail.first { $0.tag == "h1" || ($0.tag == "h2" && $0.hasClass("film-name")) }
                    let detailNames = names + [titleNode?.text ?? "", titleNode?["data-jname"] ?? ""]
                    let info = detail.first { $0["id"] == "w-info" } ?? detail.first { $0.hasClass("anisc-info") } ?? detail
                    let aired = info.all { ($0.tag == "div") && $0.text.hasPrefix("Aired:") }.last?.text
                    let type = info.all { $0.tag == "div" && $0.text.hasPrefix("Type:") }.last?.text ?? ""
                    let breadcrumbType = detail.first { $0.tag == "a" && $0["href"].contains("/type/") && $0.ancestor { $0.hasClass("breadcrumb") } != nil }?.text ?? ""
                    let verifiedType = type.isEmpty ? breadcrumbType : type
                    guard !verifiedType.isEmpty else { continue }
                    let kind: MediaKind = verifiedType.lowercased().contains("movie") ? .movie : .series
                    let separate = season > 1 && detailNames.contains { name in
                        AnimeMatching.isSeasonTitle(name, baseTitles: context.titles, season: season) ||
                        (context.seasonTitle.map { AnimeMatching.normalized($0) } == AnimeMatching.normalized(name))
                    }
                    var matchingContext = context
                    if separate { matchingContext.alternativeTitles += context.titles.map { "\($0) Season \(season)" } }
                    let sourceYear = AnimeMatching.year(aired)
                    let aliases = Set(context.titles.map(AnimeMatching.normalized))
                    let matchedAliases = Set(detailNames.map(AnimeMatching.normalized)).intersection(aliases)
                    // Missing dates require independent title aliases for movies or episode-title evidence.
                    let missingYearAllowed = kind == .series || matchedAliases.count >= 2
                    if AnimeMatching.matches(names: detailNames, year: sourceYear, kind: kind, context: matchingContext,
                        separateSeason: separate, allowMissingYear: missingYearAllowed) {
                        do {
                            let candidates = try await servers(detailURL: detailURL, detail: detail, context: context,
                                separateSeason: separate, verifyEpisodeTitle: sourceYear == nil && kind == .series)
                            if !candidates.isEmpty { matches.append(candidates) }
                        } catch where error.isCancellation { throw error }
                        catch { continue }
                    }
            }
            if !matches.isEmpty { break }
            }
            if !matches.isEmpty { break }
        }
        guard matches.count == 1, let match = matches.first else { return [] }
        return match
    }

    private func servers(detailURL: URL, detail: AnimeHTML, context: PlaybackLookupContext, separateSeason: Bool, verifyEpisodeTitle: Bool) async throws -> [PlaybackCandidate] {
        let episodeHTML: AnimeHTML
        var nonce = ""
        var watchURL = detailURL
        if site == .anikoto {
            guard let animeID = detail.first({ $0["id"] == "watch-main" })?["data-id"], !animeID.isEmpty else { return [] }
            episodeHTML = try await ajaxHTML(url("/ajax/episode/list/\(animeID)"), referer: detailURL)
        } else {
            guard let watch = detail.first({ $0.tag == "a" && $0.hasClass("btn-play") }),
                  let target = URL(string: watch["href"], relativeTo: baseURL)?.absoluteURL else { return [] }
            watchURL = target
            // The site caches watch pages longer than its nonce lifetime. Request a
            // fresh page so a valid title is not rejected because of a stale nonce.
            var freshPage = URLComponents(url: target, resolvingAgainstBaseURL: true)
            let queryItems = (freshPage?.queryItems ?? []) + [URLQueryItem(name: "_refresh", value: String(Int(Date().timeIntervalSince1970 / 60)))]
            freshPage?.queryItems = queryItems
            let page = try await fetch(freshPage?.url ?? target)
            let tree = AnimeHTML.parse(page)
            let animeID = tree.first { $0["id"] == "ani_detail" }?["data-anime-id"] ?? ""
            nonce = AnimeHTML.captures(#""episode_nonce"\s*:\s*"([^"]+)""#, in: page).first?[1] ?? ""
            guard !animeID.isEmpty, !nonce.isEmpty else { return [] }
            episodeHTML = try await ajaxHTML(url("/wp-admin/admin-ajax.php"), referer: target,
                form: ["action": "hianime_episode_list", "anime_id": animeID, "nonce": nonce])
        }
        let episodes = episodeHTML.all { $0.tag == "a" && (!$0["data-ids"].isEmpty || $0.hasClass("ep-item")) }.compactMap { node -> AnimeEpisodeMatch? in
            guard let number = Int(node[site == .anikoto ? "data-num" : "data-number"]) else { return nil }
            return AnimeEpisodeMatch(id: node[site == .anikoto ? "data-ids" : "data-id"], number: number,
                title: node.first { $0.hasClass("d-title") || $0.hasClass("ep-name") }?.text ??
                    (node["title"].isEmpty ? node.ancestor { $0.tag == "li" && !$0["title"].isEmpty }?["title"] ?? "" : node["title"]))
        }
        if separateSeason, let count = context.seasonEpisodeCount,
           let maximum = episodes.map(\.number).max(), maximum > count { return [] }
        guard let episode = AnimeMatching.episode(in: episodes, context: context, separateSeason: separateSeason) else { return [] }
        if verifyEpisodeTitle, !AnimeMatching.episodeTitlesAgree(context.request.episode?.title, episode.title) { return [] }
        let serverHTML: AnimeHTML
        if site == .anikoto {
            serverHTML = try await ajaxHTML(url("/ajax/server/list", query: ["servers": episode.id]), referer: watchURL)
        } else {
            serverHTML = try await ajaxHTML(url("/wp-admin/admin-ajax.php"), referer: watchURL,
                form: ["action": "hianime_episode_servers", "episode_id": episode.id, "nonce": nonce])
        }
        let referer = watchURL
        return serverHTML.all { !$0["data-link-id"].isEmpty || !$0["data-hash"].isEmpty }.compactMap { node in
            let type = (node["data-type"].isEmpty ? node.ancestor { !$0["data-type"].isEmpty }?["data-type"] ?? "" : node["data-type"]).lowercased()
            let serverName = node["data-server-name"].isEmpty ? node.text : node["data-server-name"]
            let language = type.contains("dub") || serverName.lowercased().contains("dub") ? "en" : "ja"
            let linkID = node["data-link-id"]
            let embeddedURL = Data(base64Encoded: node["data-hash"]).flatMap { String(data: $0, encoding: .utf8) }.flatMap(URL.init(string:))
            guard !linkID.isEmpty || embeddedURL != nil else { return nil }
            let preference = PlaybackSourcePreference(providerID: id, serverName: serverName, audioLanguage: language)
            return PlaybackCandidate(id: "\(id):\(serverName):\(language)", preference: preference, providerName: name,
                subtitleKind: type.contains("hard") ? .embeddedEnglish : .unknown) {
                let embed: URL
                if let embeddedURL { embed = embeddedURL }
                else {
                    let payload = try json(await fetch(url("/ajax/server", query: ["get": linkID]), referer: referer))
                    guard let result = payload["result"] as? [String: Any], let link = result["url"] as? String,
                          let resolved = URL(string: link, relativeTo: baseURL)?.absoluteURL else { throw AppError.noStream }
                    embed = resolved
                }
                return try await AnimeStreamResolver(client: client).resolve(embed, referer: referer)
            }
        }
    }
}
