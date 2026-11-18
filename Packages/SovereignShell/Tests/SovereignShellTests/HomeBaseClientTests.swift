import Foundation
import Testing
@testable import SovereignShell

/// Answers every request with a canned response and remembers the last request it saw.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// One suite, run serially: the stub's answers are shared.
@Suite(.serialized) struct HomeBaseClientTests {
    private func client() throws -> HomeBaseClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return HomeBaseClient(address: try #require(HomeBaseAddress("home.example.ts.net")),
                              session: URLSession(configuration: configuration))
    }

    @Test func asksForApiHomeAsHomeBasesOwnClient() async throws {
        StubProtocol.status = 200
        StubProtocol.body = Data(#"{"state":"waiting","caller":null,"canUnlockAdmin":false,"apps":[]}"#.utf8)
        let home = try await client().home()
        #expect(home.state == .waiting)
        let request = try #require(StubProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://home.example.ts.net/api/home")
        #expect(request.httpMethod == "GET")
        // Without these, a strict Home Base hostname answers 403 fetch_metadata_missing.
        #expect(request.value(forHTTPHeaderField: "Sec-Fetch-Site") == "same-origin")
        #expect(request.value(forHTTPHeaderField: "Sec-Fetch-Mode") == "cors")
        #expect(request.value(forHTTPHeaderField: "Sec-Fetch-Dest") == "empty")
    }

    @Test func aRefusalIsAnHttpError() async throws {
        StubProtocol.status = 403
        StubProtocol.body = Data(#"{"error":"request_refused","reason":"fetch_metadata_missing"}"#.utf8)
        await #expect(throws: HomeBaseError.http(403)) { try await client().home() }
    }

    @Test func aNonJsonAnswerIsUnreadable() async throws {
        StubProtocol.status = 200
        StubProtocol.body = Data("<html>proxy login</html>".utf8)
        await #expect(throws: HomeBaseError.unreadable) { try await client().home() }
    }
}
