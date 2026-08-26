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
