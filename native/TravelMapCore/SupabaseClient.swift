import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

private struct URLSessionTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw TravelMapError.invalidResponse(operation: "通信")
        }
        return (data, response)
    }
}

public actor SupabaseClient {
    public nonisolated let configuration: SupabaseConfiguration
    private let transport: any HTTPTransport
    private let sessionStore: any AuthSessionStore
    private var loadedSession = false
    private var session: AuthSession?
    private var sessionTask: Task<AuthSession, Error>?

    public init(configuration: SupabaseConfiguration) {
        self.configuration = configuration
        self.transport = URLSessionTransport()
        #if canImport(Security)
        self.sessionStore = KeychainSessionStore(service: "com.craftplus.travelmap.supabase.\(configuration.url.absoluteString)")
        #else
        self.sessionStore = UnavailableSessionStore()
        #endif
    }

    init(configuration: SupabaseConfiguration, transport: any HTTPTransport, sessionStore: any AuthSessionStore) {
        self.configuration = configuration
        self.transport = transport
        self.sessionStore = sessionStore
    }

    public func fetchSpots() async throws -> [Spot] {
        let request = request(path: "rest/v1/spots", query: [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "500")
        ])
        let data = try await send(request, operation: "スポットの取得")
        do { return try Self.decoder().decode([Spot].self, from: data) }
        catch { throw TravelMapError.invalidResponse(operation: "スポットの取得") }
    }

    public nonisolated func photoURL(for path: String) -> URL? {
        if let absolute = URL(string: path), let scheme = absolute.scheme {
            return ["https", "http"].contains(scheme.lowercased()) && absolute.host != nil
                && absolute.user == nil && absolute.password == nil ? absolute : nil
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return parts.reduce(configuration.url.appendingPathComponent("storage/v1/object/public/photos")) {
            $0.appendingPathComponent(String($1))
        }
    }

    public func createSpot(
        title: String, latitude: Double, longitude: Double, takenAt: Date?, jpegData: Data
    ) async throws -> Spot {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...100).contains(title.unicodeScalars.count) else {
            throw TravelMapError.invalidInput("タイトルは1〜100文字で入力してください。")
        }
        guard SpotGrouping.isValidCoordinate(latitude, longitude) else {
            throw TravelMapError.invalidInput("撮影地点の位置情報が正しくありません。")
        }
        guard jpegData.count >= 2, jpegData.count <= 10 * 1_024 * 1_024,
              jpegData.prefix(2) == Data([0xff, 0xd8]) else {
            throw TravelMapError.invalidInput("写真は10MiB以下のJPEG画像を使用してください。")
        }
        let signedIn = try await ensureSession()
        let path = "\(signedIn.userID)/\(UUID().uuidString.lowercased()).jpg"
        var upload = request(path: "storage/v1/object/photos/\(path)", method: "POST", token: signedIn.accessToken)
        upload.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        upload.setValue("false", forHTTPHeaderField: "x-upsert")
        upload.httpBody = jpegData
        _ = try await authenticatedSend(upload, signedIn: signedIn, operation: "写真のアップロード")

        struct NewSpot: Encodable {
            let user_id: String
            let title: String
            let lat: Double
            let lng: Double
            let photo_path: String
            let taken_at: Date?
        }
        var insert = request(path: "rest/v1/spots", method: "POST", token: signedIn.accessToken)
        insert.setValue("return=representation", forHTTPHeaderField: "Prefer")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        insert.httpBody = try encoder.encode(NewSpot(
            user_id: signedIn.userID, title: title, lat: latitude, lng: longitude,
            photo_path: path, taken_at: takenAt
        ))
        let data: Data
        do {
            data = try await authenticatedSend(insert, signedIn: signedIn, operation: "スポットの投稿")
        } catch is CancellationError {
            throw TravelMapError.postingOutcomeUnknown
        } catch let error as TravelMapError {
            switch error {
            case .network, .invalidResponse:
                // The INSERT may have succeeded. Deleting its photo would corrupt a real post.
                throw TravelMapError.postingOutcomeUnknown
            case .http(_, let status) where status >= 500 || status == 408:
                // An upstream timeout/gateway failure can happen after the database commits.
                throw TravelMapError.postingOutcomeUnknown
            default:
                // Existing schema has no storage DELETE policy. Preserve that limitation explicitly.
                do { try await removeUploadedPhoto(path, signedIn: signedIn) }
                catch { throw TravelMapError.postingFailedWithRemainingPhoto }
                throw error
            }
        }
        do {
            let spots = try Self.decoder().decode([Spot].self, from: data)
            guard let spot = spots.first, spots.count == 1 else { throw TravelMapError.postingOutcomeUnknown }
            return spot
        } catch {
            // A successful HTTP status with an unreadable body must not trigger destructive cleanup.
            throw TravelMapError.postingOutcomeUnknown
        }
    }

    private func removeUploadedPhoto(_ path: String, signedIn: AuthSession) async throws {
        var request = request(path: "storage/v1/object/photos", method: "DELETE", token: signedIn.accessToken)
        request.httpBody = try JSONEncoder().encode(["prefixes": [path]])
        _ = try await authenticatedSend(request, signedIn: signedIn, operation: "写真の削除")
    }

    private func ensureSession(forceRefresh: Bool = false) async throws -> AuthSession {
        if let task = sessionTask { return try await task.value }
        if !loadedSession {
            session = try sessionStore.load()
            loadedSession = true
        }
        if let session, !forceRefresh, session.expiresAt > Date().addingTimeInterval(60) {
            return session
        }
        let previousSession = session
        let task = Task<AuthSession, Error> {
            let result = try await self.authenticate(previousSession: previousSession)
            // Every waiter must finish persistence before it is allowed to publish.
            try self.sessionStore.save(result)
            self.session = result
            return result
        }
        sessionTask = task
        do {
            let result = try await task.value
            sessionTask = nil
            return result
        } catch {
            sessionTask = nil
            throw error
        }
    }

    private func authenticate(previousSession: AuthSession?) async throws -> AuthSession {
        var auth: URLRequest
        if let previousSession {
            auth = request(path: "auth/v1/token", method: "POST", query: [URLQueryItem(name: "grant_type", value: "refresh_token")])
            auth.httpBody = try JSONEncoder().encode(["refresh_token": previousSession.refreshToken])
        } else {
            auth = request(path: "auth/v1/signup", method: "POST")
            auth.httpBody = Data("{}".utf8)
        }
        let data: Data
        do { data = try await send(auth, operation: previousSession == nil ? "匿名サインイン" : "認証の更新") }
        catch let error as TravelMapError {
            if previousSession != nil, case .http(_, let status) = error, [400, 401, 403].contains(status) {
                // Never silently replace an anonymous identity, which would lose ownership of old posts.
                throw TravelMapError.authenticationExpired
            }
            throw error
        }
        struct Response: Decodable {
            struct User: Decodable { let id: String }
            let access_token: String
            let refresh_token: String
            let expires_in: Double?
            let expires_at: Double?
            let user: User
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              !response.access_token.isEmpty, !response.refresh_token.isEmpty,
              UUID(uuidString: response.user.id) != nil,
              previousSession == nil || previousSession?.userID == response.user.id else {
            throw TravelMapError.invalidResponse(operation: "匿名認証")
        }
        let expiry = response.expires_at.map(Date.init(timeIntervalSince1970:))
            ?? Date().addingTimeInterval(response.expires_in ?? 3_600)
        return AuthSession(accessToken: response.access_token, refreshToken: response.refresh_token,
                           expiresAt: expiry, userID: response.user.id)
    }

    private func authenticatedSend(
        _ request: URLRequest, signedIn: AuthSession, operation: String
    ) async throws -> Data {
        var authorized = request
        // A preceding upload or a concurrent post may already have refreshed this identity.
        if let session, session.userID == signedIn.userID {
            authorized.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        }
        do { return try await send(authorized, operation: operation) }
        catch TravelMapError.http(_, let status) where status == 401 {
            let refreshed = try await ensureSession(forceRefresh: true)
            guard refreshed.userID == signedIn.userID else { throw TravelMapError.authenticationExpired }
            var retry = request
            retry.setValue("Bearer \(refreshed.accessToken)", forHTTPHeaderField: "Authorization")
            return try await send(retry, operation: operation)
        }
    }

    private nonisolated func request(
        path: String, method: String = "GET", token: String? = nil, query: [URLQueryItem] = []
    ) -> URLRequest {
        var components = URLComponents(url: configuration.url.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 45
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else if !configuration.anonKey.hasPrefix("sb_publishable_") {
            // Publishable keys belong only in apikey. Legacy anon keys are JWTs.
            request.setValue("Bearer \(configuration.anonKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func send(_ request: URLRequest, operation: String) async throws -> Data {
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw TravelMapError.network(operation: operation) }
        guard (200..<300).contains(response.statusCode) else {
            // Backend response bodies can contain credentials or implementation details; never expose them.
            throw TravelMapError.http(operation: operation, statusCode: response.statusCode)
        }
        return data
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            if let date = ISO8601DateFormatter().date(from: value) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid ISO8601 timestamp"))
        }
        return decoder
    }
}
