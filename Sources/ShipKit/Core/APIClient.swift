import Foundation

public enum ShipKitError: Error, LocalizedError, Sendable, Equatable {
    case notConfigured
    case offline
    case rateLimited
    case invalidSignature
    case invalidResponse
    case server(status: Int, code: String?, message: String?)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "ShipKit is not configured."
        case .offline: return "The network is unavailable."
        case .rateLimited: return "Too many requests. Try again later."
        case .invalidSignature: return "The configuration signature could not be verified."
        case .invalidResponse: return "The server response could not be read."
        case .server(let status, _, let message): return message ?? "Server error (\(status))."
        }
    }

    /// Errors worth retrying later, as opposed to requests the server rejected.
    var isTransient: Bool {
        switch self {
        case .offline, .rateLimited: return true
        case .server(let status, _, _): return status >= 500
        default: return false
        }
    }
}

struct APIClient: Sendable {
    let baseURL: URL
    let clientKey: String
    let stableID: String
    let bundleID: String
    let session: URLSession

    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var url = baseURL
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        guard !query.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.queryItems = query
        return components.url ?? url
    }

    func makeRequest(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String = "application/json",
        headers: [String: String] = [:]
    ) -> URLRequest {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(clientKey)", forHTTPHeaderField: "Authorization")
        request.setValue(stableID, forHTTPHeaderField: "X-ShipKit-Stable-Id")
        request.setValue("ios/\(ShipKit.sdkVersion)", forHTTPHeaderField: "X-ShipKit-SDK")
        request.setValue(bundleID, forHTTPHeaderField: "X-Bundle-Id")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// Performs a request. Returns for 2xx and 304; throws `ShipKitError` otherwise.
    func send(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String = "application/json",
        headers: [String: String] = [:]
    ) async throws -> (Data, HTTPURLResponse) {
        let request = makeRequest(method, path, query: query, body: body, contentType: contentType, headers: headers)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw error.code == .cancelled ? CancellationError() as Error : ShipKitError.offline
        }
        guard let http = response as? HTTPURLResponse else { throw ShipKitError.invalidResponse }
        switch http.statusCode {
        case 200..<300, 304:
            return (data, http)
        case 429:
            throw ShipKitError.rateLimited
        default:
            let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
            throw ShipKitError.server(status: http.statusCode, code: envelope?.error.code, message: envelope?.error.message)
        }
    }

    func json<Response: Decodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: (some Encodable)? = Optional<BodyText>.none
    ) async throws -> Response {
        let payload = try body.map { try JSON.encoder.encode($0) }
        let (data, _) = try await send(method, path, query: query, body: payload)
        do {
            return try JSON.decoder.decode(Response.self, from: data)
        } catch {
            throw ShipKitError.invalidResponse
        }
    }

    func perform(_ method: String, _ path: String, body: (some Encodable)? = Optional<BodyText>.none) async throws {
        let payload = try body.map { try JSON.encoder.encode($0) }
        _ = try await send(method, path, body: payload)
    }
}
