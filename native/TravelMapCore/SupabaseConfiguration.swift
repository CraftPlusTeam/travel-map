import Foundation

public struct SupabaseConfiguration: Sendable {
    public let url: URL
    public let anonKey: String

    public init(url: URL, anonKey: String) throws {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw TravelMapError.invalidConfiguration("SupabaseのURLを確認してください。")
        }
        var secure = components.scheme?.lowercased() == "https"
        #if DEBUG
        if components.scheme?.lowercased() == "http",
           ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased()) {
            secure = true
        }
        #endif
        guard secure else {
            throw TravelMapError.invalidConfiguration("SupabaseにはHTTPSのURLが必要です。")
        }
        let key = anonKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace || $0.isNewline }),
              !key.lowercased().contains("your-"), !key.hasPrefix("sb_secret_"),
              Self.jwtRole(key) != "service_role" else {
            throw TravelMapError.invalidConfiguration("Supabaseの公開キー（anonまたはpublishable）を設定してください。")
        }
        components.path = ""
        guard let normalizedURL = components.url else {
            throw TravelMapError.invalidConfiguration("SupabaseのURLを確認してください。")
        }
        self.url = normalizedURL
        self.anonKey = key
    }

    private static func jwtRole(_ key: String) -> String? {
        let parts = key.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return payload["role"] as? String
    }
}

public enum TravelMapError: LocalizedError, Sendable, Equatable {
    case invalidConfiguration(String)
    case invalidInput(String)
    case network(operation: String)
    case http(operation: String, statusCode: Int)
    case invalidResponse(operation: String)
    case sessionStorage
    case authenticationExpired
    case postingOutcomeUnknown
    case postingFailedWithRemainingPhoto

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message), .invalidInput(let message):
            return message
        case .network(let operation):
            return "\(operation)に失敗しました。通信状態を確認して再試行してください。"
        case .http(let operation, let statusCode):
            switch statusCode {
            case 401: return "\(operation)に失敗しました。認証設定を確認してください（401）。"
            case 403: return "\(operation)の権限がありません。Supabaseの設定を確認してください（403）。"
            case 429: return "リクエストが多すぎます。時間をおいて再試行してください（429）。"
            default: return "\(operation)に失敗しました（HTTP \(statusCode)）。"
            }
        case .invalidResponse(let operation):
            return "\(operation)の応答を読み取れませんでした。サーバーの設定を確認してください。"
        case .sessionStorage:
            return "認証情報を安全に保存・読み込みできませんでした。端末のロックを解除して再試行してください。"
        case .authenticationExpired:
            return "認証の有効期限が切れています。Supabaseの匿名認証設定を確認してください。"
        case .postingOutcomeUnknown:
            return "投稿結果を確認できませんでした。地図を再読み込みし、同じ投稿がないか確認してから再試行してください。"
        case .postingFailedWithRemainingPhoto:
            return "投稿情報の保存に失敗しました。アップロード済み写真の削除も完了できなかったため、管理者による確認が必要です。"
        }
    }
}
