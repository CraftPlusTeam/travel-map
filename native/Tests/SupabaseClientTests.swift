import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import TravelMapCore

private let userID = "c0735426-912a-4f50-a0ad-f833b4a52f42"
private let responseSpot = """
[{"id":"spot-id","created_at":"2026-10-16T00:00:00.123456+00:00","user_id":null,"title":"景色","lat":35,"lng":135,"photo_path":"photo.jpg","taken_at":"2026-10-15T09:00:00Z"}]
"""
private let authResponse = """
{"access_token":"user-access-token","refresh_token":"user-refresh-token","expires_in":3600,"user":{"id":"\(userID)"}}
"""

private actor MockTransport: HTTPTransport {
    struct Reply: Sendable {
        let status: Int
        let body: Data
        init(_ status: Int = 200, _ body: String = "{}") {
            self.status = status
            self.body = Data(body.utf8)
        }
    }
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.networkConnectionLost) }
        let reply = replies.removeFirst()
        return (reply.body, HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                          httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

private struct TestSessionStore: AuthSessionStore {
    let existing: AuthSession?
    init(existing: AuthSession? = nil) { self.existing = existing }
    func load() throws -> AuthSession? { existing }
    func save(_ session: AuthSession) throws { }
}

private struct FailingSessionStore: AuthSessionStore {
    func load() throws -> AuthSession? { nil }
    func save(_ session: AuthSession) throws { throw TravelMapError.sessionStorage }
}

private func config(_ key: String = "sb_publishable_test") throws -> SupabaseConfiguration {
    try SupabaseConfiguration(url: URL(string: "https://example.supabase.co/")!, anonKey: key)
}

@Suite("Supabaseの設定と通信")
struct SupabaseClientTests {
    @Test func rejectsUnsafeConfiguration() throws {
        let invalidURLs = ["http://example.supabase.co", "https://user:password@example.com", "https://example.com/?key=x", "https://example.com/path"]
        for value in invalidURLs {
            #expect(throws: TravelMapError.self) {
                try SupabaseConfiguration(url: URL(string: value)!, anonKey: "sb_publishable_test")
            }
        }
        #expect(throws: TravelMapError.self) { try config("sb_secret_private") }
        #expect(throws: TravelMapError.self) { try config("your-local-anon-key") }
        let serviceRolePayload = Data("{\"role\":\"service_role\"}".utf8).base64EncodedString()
        #expect(throws: TravelMapError.self) { try config("header.\(serviceRolePayload).signature") }
        #expect(try config().url.absoluteString == "https://example.supabase.co")
    }

    @Test func fetchUsesPublicKeyAndDecodesSupabaseDates() async throws {
        let transport = MockTransport([.init(200, responseSpot)])
        let client = SupabaseClient(configuration: try config(), transport: transport, sessionStore: TestSessionStore())
        let spots = try await client.fetchSpots()
        #expect(spots.count == 1 && spots.first?.title == "景色")
        #expect(spots.first?.takenAt != nil)
        let request = try #require(await transport.requests.first)
        #expect(request.url?.path == "/rest/v1/spots")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.contains(URLQueryItem(name: "limit", value: "500")) == true)
        #expect(request.value(forHTTPHeaderField: "apikey") == "sb_publishable_test")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func backendErrorDoesNotExposeResponseBodyOrKeys() async throws {
        let transport = MockTransport([.init(403, "{\"message\":\"SECRET user-access-token\"}")])
        let client = SupabaseClient(configuration: try config(), transport: transport, sessionStore: TestSessionStore())
        await #expect(throws: TravelMapError.http(operation: "スポットの取得", statusCode: 403)) {
            try await client.fetchSpots()
        }
        let message = TravelMapError.http(operation: "スポットの取得", statusCode: 403).localizedDescription
        #expect(message.contains("403") && !message.contains("SECRET"))
    }

    @Test func photoURLsResolveWithoutTreatingOtherSchemesAsImages() throws {
        let client = SupabaseClient(configuration: try config())
        #expect(client.photoURL(for: "https://images.example.com/a.jpg")?.host == "images.example.com")
        #expect(client.photoURL(for: "user/景色.jpg")?.path == "/storage/v1/object/public/photos/user/景色.jpg")
        #expect(client.photoURL(for: "file:///etc/passwd") == nil)
        #expect(client.photoURL(for: "../other-bucket/p.jpg") == nil)
        #expect(client.photoURL(for: "") == nil)
    }

    @Test func createsAnonymousSessionThenUploadsAndInserts() async throws {
        let transport = MockTransport([.init(200, authResponse), .init(), .init(201, responseSpot)])
        let client = SupabaseClient(configuration: try config(), transport: transport, sessionStore: TestSessionStore())
        let spot = try await client.createSpot(title: " 景色 ", latitude: 35, longitude: 135,
                                             takenAt: nil, jpegData: Data([0xff, 0xd8, 0xff, 0xd9]))
        #expect(spot.id == "spot-id")
        let requests = await transport.requests
        #expect(requests.count == 3)
        #expect(requests[0].url?.path == "/auth/v1/signup")
        #expect(requests[1].url?.path.hasPrefix("/storage/v1/object/photos/\(userID)/") == true)
        #expect(requests[1].value(forHTTPHeaderField: "Content-Type") == "image/jpeg")
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer user-access-token")
        #expect(requests[2].value(forHTTPHeaderField: "Prefer") == "return=representation")
        let payload = try #require(try JSONSerialization.jsonObject(with: requests[2].httpBody!) as? [String: Any])
        #expect(payload["title"] as? String == "景色")
        #expect(payload["user_id"] as? String == userID)
        #expect(payload["bearing"] == nil)
    }

    @Test func refreshesExpiredSessionWithoutChangingIdentity() async throws {
        let saved = AuthSession(accessToken: "old-access", refreshToken: "old-refresh", expiresAt: .distantPast, userID: userID)
        let transport = MockTransport([.init(200, authResponse), .init(), .init(201, responseSpot)])
        let client = SupabaseClient(configuration: try config(), transport: transport, sessionStore: TestSessionStore(existing: saved))
        _ = try await client.createSpot(title: "景色", latitude: 35, longitude: 135, takenAt: nil,
                                        jpegData: Data([0xff, 0xd8]))
        let requests = await transport.requests
        #expect(requests[0].url?.path == "/auth/v1/token")
        #expect(requests[0].url?.query == "grant_type=refresh_token")
        #expect(String(data: requests[0].httpBody!, encoding: .utf8)?.contains("old-refresh") == true)
        #expect(requests.allSatisfy { $0.url?.path != "/auth/v1/signup" })
    }

    @Test func invalidRefreshNeverCreatesAReplacementIdentity() async throws {
        let saved = AuthSession(accessToken: "old-access", refreshToken: "old-refresh", expiresAt: .distantPast, userID: userID)
        let transport = MockTransport([.init(400)])
        let client = SupabaseClient(configuration: try config(), transport: transport, sessionStore: TestSessionStore(existing: saved))
        await #expect(throws: TravelMapError.authenticationExpired) {
            try await client.createSpot(title: "景色", latitude: 35, longitude: 135, takenAt: nil,
                                        jpegData: Data([0xff, 0xd8]))
        }
        #expect(await transport.requests.count == 1)
    }

    @Test func unauthorizedUploadRefreshesOnceAndInsertUsesFreshToken() async throws {
        let saved = AuthSession(accessToken: "old-access", refreshToken: "old-refresh", expiresAt: .distantFuture, userID: userID)
        let transport = MockTransport([.init(401), .init(200, authResponse), .init(), .init(201, responseSpot)])
        let client = SupabaseClient(configuration: try config(), transport: transport, sessionStore: TestSessionStore(existing: saved))
        _ = try await client.createSpot(title: "景色", latitude: 35, longitude: 135, takenAt: nil,
                                        jpegData: Data([0xff, 0xd8]))
        let requests = await transport.requests
        #expect(requests.count == 4)
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer old-access")
        #expect(requests[1].url?.path == "/auth/v1/token")
        #expect(requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer user-access-token")
        #expect(requests[3].value(forHTTPHeaderField: "Authorization") == "Bearer user-access-token")
    }

    @Test func sessionPersistenceFailureStopsBeforeUpload() async throws {
        let transport = MockTransport([.init(200, authResponse)])
        let client = SupabaseClient(configuration: try config(), transport: transport, sessionStore: FailingSessionStore())
        await #expect(throws: TravelMapError.sessionStorage) {
            try await client.createSpot(title: "景色", latitude: 35, longitude: 135, takenAt: nil,
                                        jpegData: Data([0xff, 0xd8]))
        }
        #expect(await transport.requests.count == 1)
    }

    @Test func insertFailureRemovesUnreferencedUpload() async throws {
        let transport = MockTransport([.init(200, authResponse), .init(), .init(400), .init()])
        let client = SupabaseClient(configuration: try config(), transport: transport, sessionStore: TestSessionStore())
        await #expect(throws: TravelMapError.http(operation: "スポットの投稿", statusCode: 400)) {
            try await client.createSpot(title: "景色", latitude: 35, longitude: 135, takenAt: nil,
                                        jpegData: Data([0xff, 0xd8]))
        }
        let requests = await transport.requests
        #expect(requests.last?.httpMethod == "DELETE")
        #expect(requests.last?.url?.path == "/storage/v1/object/photos")
        #expect(String(data: requests.last!.httpBody!, encoding: .utf8)?.contains("prefixes") == true)
    }

    @Test func missingDeletePolicyIsReportedHonestly() async throws {
        let transport = MockTransport([.init(200, authResponse), .init(), .init(400), .init(403)])
        let client = SupabaseClient(configuration: try config(), transport: transport, sessionStore: TestSessionStore())
        await #expect(throws: TravelMapError.postingFailedWithRemainingPhoto) {
            try await client.createSpot(title: "景色", latitude: 35, longitude: 135, takenAt: nil,
                                        jpegData: Data([0xff, 0xd8]))
        }
    }

    @Test func ambiguousInsertResultNeverDeletesAPossiblyPublishedPhoto() async throws {
        for replies: [MockTransport.Reply] in [
            [.init(200, authResponse), .init()],
            [.init(200, authResponse), .init(), .init(201, "unreadable")],
            [.init(200, authResponse), .init(), .init(502)]
        ] {
            let transport = MockTransport(replies)
            let client = SupabaseClient(configuration: try config(), transport: transport, sessionStore: TestSessionStore())
            await #expect(throws: TravelMapError.postingOutcomeUnknown) {
                try await client.createSpot(title: "景色", latitude: 35, longitude: 135, takenAt: nil,
                                            jpegData: Data([0xff, 0xd8]))
            }
            #expect(await transport.requests.allSatisfy { $0.httpMethod != "DELETE" })
        }
    }

    @Test func invalidInputDoesNotMakeAnyNetworkRequests() async throws {
        let transport = MockTransport([])
        let client = SupabaseClient(configuration: try config(), transport: transport, sessionStore: TestSessionStore())
        await #expect(throws: TravelMapError.self) {
            try await client.createSpot(title: " ", latitude: 35, longitude: 135, takenAt: nil, jpegData: Data([0xff, 0xd8]))
        }
        await #expect(throws: TravelMapError.self) {
            try await client.createSpot(title: "景色", latitude: .nan, longitude: 135, takenAt: nil, jpegData: Data([0xff, 0xd8]))
        }
        await #expect(throws: TravelMapError.self) {
            try await client.createSpot(title: "景色", latitude: 35, longitude: 135, takenAt: nil, jpegData: Data([0x89, 0x50]))
        }
        #expect(await transport.requests.isEmpty)
    }
}
