import Foundation

struct HTTPResponse: Sendable {
    let data: Data
    let response: HTTPURLResponse
}

protocol HTTPClientProtocol: Sendable {
    func data(for request: URLRequest) async throws -> HTTPResponse
}

actor HTTPClient: HTTPClientProtocol {
    static let desktopUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"

    private let session: URLSession

    init(configuration: URLSessionConfiguration = .default) {
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        configuration.waitsForConnectivity = true
        configuration.httpShouldSetCookies = true
        session = URLSession(configuration: configuration)
    }

    func data(for request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw AppError.providerUnavailable("HTTP \(http.statusCode)")
        }
        return HTTPResponse(data: data, response: http)
    }
}

extension URLRequest {
    static func providerRequest(
        url: URL,
        referer: URL? = nil,
        inertiaVersion: String? = nil,
        acceptsJSON: Bool = false
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(HTTPClient.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("language=en", forHTTPHeaderField: "Cookie")
        request.setValue(referer?.absoluteString, forHTTPHeaderField: "Referer")
        if acceptsJSON {
            request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        }
        if let inertiaVersion {
            request.setValue("true", forHTTPHeaderField: "X-Inertia")
            request.setValue(inertiaVersion, forHTTPHeaderField: "X-Inertia-Version")
            request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        }
        return request
    }
}

struct GitHubRelease: Decodable, Sendable, Equatable, Identifiable {
    let tagName: String
    let name: String?
    let body: String
    let htmlURL: URL

    var id: String { tagName }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decode(String.self, forKey: .tagName)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        htmlURL = try container.decode(URL.self, forKey: .htmlURL)
    }
}

struct GitHubReleaseClient: Sendable {
    private static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/rtk19/BetterStreamflix-iOS-port/releases/latest"
    )!

    private let client: any HTTPClientProtocol

    init(client: any HTTPClientProtocol = HTTPClient()) {
        self.client = client
    }

    func latestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadRevalidatingCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("BetterStreamflix-iOS", forHTTPHeaderField: "User-Agent")

        let response = try await client.data(for: request)
        return try JSONDecoder().decode(GitHubRelease.self, from: response.data)
    }

    static func isNewer(tagName: String, than currentVersion: String) -> Bool {
        guard let release = Version(tagName), let current = Version(currentVersion) else {
            return tagName.compare(currentVersion, options: .numeric) == .orderedDescending
        }
        return release > current
    }

    static func shouldOfferUpdate(
        tagName: String,
        currentVersion: String,
        skippedTagName: String
    ) -> Bool {
        guard isNewer(tagName: tagName, than: currentVersion) else { return false }
        guard !skippedTagName.isEmpty else { return true }

        if let release = Version(tagName), let skipped = Version(skippedTagName) {
            return release != skipped
        }
        return tagName.compare(skippedTagName, options: [.caseInsensitive, .numeric]) != .orderedSame
    }
}

private struct Version: Comparable {
    private let components: [Int]

    init?(_ rawValue: String) {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" {
            value.removeFirst()
        }
        value = String(value.split(whereSeparator: { $0 == "-" || $0 == "+" }).first ?? "")

        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        let parsed = parts.compactMap { Int($0) }
        guard !parsed.isEmpty, parsed.count == parts.count else { return nil }
        components = parsed
    }

    static func < (lhs: Version, rhs: Version) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

enum ReleaseNotesMarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case unorderedItem(indentation: Int, text: String)
    case orderedItem(indentation: Int, marker: String, text: String)
    case quote(String)
    case code(String)
    case divider
}

enum ReleaseNotesMarkdownParser {
    static func parse(_ source: String) -> [ReleaseNotesMarkdownBlock] {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var blocks: [ReleaseNotesMarkdownBlock] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var isInCodeBlock = false

        func paragraphText() -> String {
            paragraphLines.reduce(into: "") { result, line in
                guard !result.isEmpty else {
                    result = line
                    return
                }
                if result.hasSuffix("  ") {
                    result.removeLast(2)
                    result += "\n" + line
                } else {
                    result += " " + line
                }
            }
        }

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(paragraphText()))
            paragraphLines.removeAll(keepingCapacity: true)
        }

        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if isInCodeBlock {
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    codeLines.removeAll(keepingCapacity: true)
                } else {
                    flushParagraph()
                }
                isInCodeBlock.toggle()
                continue
            }

            if isInCodeBlock {
                codeLines.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            if let heading = heading(from: trimmed) {
                flushParagraph()
                blocks.append(heading)
                continue
            }

            if isDivider(trimmed) {
                if paragraphLines.isEmpty {
                    blocks.append(.divider)
                } else {
                    let level = trimmed.first == "=" ? 1 : 2
                    blocks.append(.heading(level: level, text: paragraphText()))
                    paragraphLines.removeAll(keepingCapacity: true)
                }
                continue
            }

            let indentation = line.prefix(while: { $0 == " " }).count / 2
            if let item = unorderedItem(from: trimmed, indentation: indentation) {
                flushParagraph()
                blocks.append(item)
                continue
            }
            if let item = orderedItem(from: trimmed, indentation: indentation) {
                flushParagraph()
                blocks.append(item)
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
                continue
            }

            paragraphLines.append(trimmed)
        }

        flushParagraph()
        if isInCodeBlock, !codeLines.isEmpty {
            blocks.append(.code(codeLines.joined(separator: "\n")))
        }
        return blocks.isEmpty ? [.paragraph("No release notes were provided.")] : blocks
    }

    private static func heading(from line: String) -> ReleaseNotesMarkdownBlock? {
        let level = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level), line.dropFirst(level).first == " " else { return nil }
        let text = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
        return .heading(level: level, text: text)
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let character = compact.first else { return false }
        return ["-", "*", "_", "="].contains(String(character)) && compact.allSatisfy { $0 == character }
    }

    private static func unorderedItem(
        from line: String,
        indentation: Int
    ) -> ReleaseNotesMarkdownBlock? {
        guard line.count >= 2, ["- ", "* ", "+ "].contains(String(line.prefix(2))) else { return nil }
        return .unorderedItem(indentation: indentation, text: String(line.dropFirst(2)))
    }

    private static func orderedItem(
        from line: String,
        indentation: Int
    ) -> ReleaseNotesMarkdownBlock? {
        guard let space = line.firstIndex(of: " ") else { return nil }
        let marker = String(line[..<space])
        guard marker.hasSuffix("."), !marker.dropLast().isEmpty,
              marker.dropLast().allSatisfy(\.isNumber) else { return nil }
        return .orderedItem(
            indentation: indentation,
            marker: marker,
            text: String(line[line.index(after: space)...])
        )
    }
}
