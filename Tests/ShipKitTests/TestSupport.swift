import Foundation
import os
@testable import ShipKit

struct MockResponse: Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var body: Data = Data()
}

struct RecordedRequest: Sendable {
    var method: String
    var url: URL
    var headers: [String: String]
    var body: Data?
}

/// Routes URLSession traffic to an in-process handler. `nil` simulates having no network.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (RecordedRequest) -> MockResponse?

    private static let state = OSAllocatedUnfairLock<(handler: Handler?, requests: [RecordedRequest])>(initialState: (nil, []))

    static func setHandler(_ handler: Handler?) {
        state.withLock { $0 = (handler, []) }
    }

    static var requests: [RecordedRequest] { state.withLock { $0.requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = RecordedRequest(
            method: request.httpMethod ?? "GET",
            url: request.url!,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody ?? request.httpBodyStream.map(Self.read)
        )
        let handler = Self.state.withLock { state -> Handler? in
            state.requests.append(recorded)
            return state.handler
        }
        guard let response = handler?(recorded) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

enum TestEnv {
    static func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ShipKitTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func preferences() -> Preferences {
        let suite = "ShipKitTests-\(UUID().uuidString)"
        return Preferences(defaults: UserDefaults(suiteName: suite)!)
    }

    static func makeEngine(
        directory: URL,
        preferences: Preferences = TestEnv.preferences(),
        appVersion: String = "2.4.0",
        build: String = "311",
        configure: (inout ShipKitOptions) -> Void = { _ in }
    ) -> Engine {
        var options = ShipKitOptions()
        options.apiURL = URL(string: "https://api.test")!
        options.telemetry = .off
        configure(&options)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        return Engine(
            configuration: .init(
                clientKey: "skc_test",
                options: options,
                appInfo: AppInfo(bundleID: "dev.shipkit.tests", marketingVersion: appVersion, build: build),
                preferences: preferences,
                directory: directory,
                session: URLSession(configuration: sessionConfiguration),
                useKeychain: false
            )
        )
    }

    static func snapshotJSON(status: String, extra: String = "") -> Data {
        Data("""
        {"release":1,"ttl":900,"settings":{"max_upload_mb":50},"flags":{"new_onboarding":true},
         "version":{"status":"\(status)","min":"2.0.0","recommended":"2.5.0","latest":"2.5.1",
         "storeURL":"https://apps.apple.com/app/id1"\(extra)},"inbox":{"unread":2}}
        """.utf8)
    }

    static func fixture(_ name: String, ext: String) -> Data? {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else { return nil }
        return try? Data(contentsOf: url)
    }
}
