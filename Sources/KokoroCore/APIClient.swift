import Foundation

public enum APIError: Error, LocalizedError, Equatable {
    case invalidServerURL
    case invalidIdentifier
    case invalidResponse
    case unauthorized
    case server(status: Int, message: String)
    case unsafeRedirect
    case invalidMessage

    public var errorDescription: String? {
        switch self {
        case .invalidServerURL: return "有効な HTTPS サーバー URL を入力してください。ローカルサーバーは HTTP も利用できます。"
        case .invalidIdentifier: return "チャンネルまたはメンバーシップの ID が無効です。"
        case .invalidResponse: return "サーバーからの応答を読み取れませんでした。"
        case .unauthorized: return "アクセストークンが無効です。設定から接続し直してください。"
        case let .server(status, message): return "\(message) (HTTP \(status))"
        case .unsafeRedirect: return "認証情報を保護するため、別の接続先へのリダイレクトを停止しました。"
        case .invalidMessage: return "メッセージは 1〜4,000 文字で入力してください。"
        }
    }
}

/// REST API authentication uses a header only. Redirects are constrained to the original origin.
public final class APIClient: @unchecked Sendable {
    public let baseURL: URL
    private let token: String
    private let session: URLSession

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    public static func validatedServerURL(_ value: String) throws -> URL {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.scheme == "https" || (components.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)) else {
            throw APIError.invalidServerURL
        }
        return url
    }

    public func fetchProfile() async throws -> Profile {
        try await request(path: ["profiles", "me"])
    }

    public func fetchMemberships() async throws -> [Membership] {
        try await request(path: ["memberships"], query: [URLQueryItem(name: "archived", value: "false")])
    }

    public func fetchChannels() async throws -> [Channel] {
        try await fetchMemberships().map(\.populatedChannel)
    }

    /// The server returns newest first. `before` is an exclusive integer message ID.
    public func fetchMessages(channelID: String, before: Int? = nil, after: Int? = nil, limit: Int = 50) async throws -> [Message] {
        try validateID(channelID)
        var query = [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 1000)))]
        if let before { query.append(URLQueryItem(name: "before_id", value: String(before))) }
        if let after { query.append(URLQueryItem(name: "after_id", value: String(after))) }
        return try await request(path: ["channels", channelID, "messages"], query: query)
    }

    /// REST membership unread_count is not reset when its read cursor is updated.
    /// Count the actual messages beyond that cursor, paging backwards because the API
    /// returns IDs in descending order even when using an `after_id` lower bound.
    public func fetchUnreadCount(channelID: String, after messageID: Int, excludingProfileID: String) async throws -> Int {
        var before: Int?
        var count = 0
        while true {
            try Task.checkCancellation()
            let page = try await fetchMessages(channelID: channelID, before: before, after: messageID, limit: 1000)
            count += page.filter { $0.id > messageID && $0.profile.id != excludingProfileID }.count
            guard page.count == 1000, let minimum = page.map(\.id).min(), minimum > messageID,
                  before == nil || minimum < before! else { return count }
            before = minimum
        }
    }

    public func sendMessage(channelID: String, text: String, idempotentKey: String = UUID().uuidString.lowercased()) async throws -> Message {
        try validateID(channelID)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.unicodeScalars.count <= 4000 else { throw APIError.invalidMessage }
        return try await request(path: ["channels", channelID, "messages"], method: "POST", body: [
            "message": text, "idempotent_key": idempotentKey.lowercased(), "expand_embed_contents": true
        ])
    }

    /// The API updates the cursor but currently leaves unread_count unchanged; callers should
    /// maintain the acknowledged cursor when presenting badges from subsequent refreshes.
    @discardableResult
    public func markRead(membershipID: String, messageID: Int) async throws -> Membership {
        try validateID(membershipID)
        return try await request(path: ["memberships", membershipID], method: "PUT", body: ["latest_read_message_id": messageID])
    }

    private func validateID(_ id: String) throws {
        guard !id.isEmpty, id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else { throw APIError.invalidIdentifier }
    }

    private func request<T: Decodable>(path: [String], method: String = "GET", query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> T {
        let validated = try Self.validatedServerURL(baseURL.absoluteString)
        var url = validated.appendingPathComponent("api").appendingPathComponent("v1")
        for component in path { url.appendPathComponent(component) }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw APIError.invalidServerURL }
        components.queryItems = query.isEmpty ? nil : query
        guard let endpoint = components.url else { throw APIError.invalidServerURL }
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(token, forHTTPHeaderField: "X-Access-Token")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let redirectGuard = SameOriginRedirectGuard(origin: endpoint)
        let (data, response) = try await session.data(for: request, delegate: redirectGuard)
        guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if (300...399).contains(response.statusCode) { throw APIError.unsafeRedirect }
        if response.statusCode == 401 { throw APIError.unauthorized }
        guard (200...299).contains(response.statusCode) else {
            let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
            // Only the documented message is shown, never raw response bodies, URLs, or headers.
            let message = (envelope?.message ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode))
                .replacingOccurrences(of: token.isEmpty ? "\u{0}" : token, with: "[redacted]")
            throw APIError.server(status: response.statusCode, message: String(message.prefix(400)))
        }
        do { return try APIJSON.decoder().decode(T.self, from: data) }
        catch { throw APIError.invalidResponse }
    }

    private struct ErrorEnvelope: Decodable { let message: String }
}

final class SameOriginRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let origin: URL
    init(origin: URL) { self.origin = origin }

    static func isSameOrigin(_ candidate: URL, as origin: URL) -> Bool {
        func effectivePort(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return candidate.scheme?.lowercased() == origin.scheme?.lowercased()
            && candidate.host?.lowercased() == origin.host?.lowercased()
            && effectivePort(candidate) == effectivePort(origin)
            && candidate.user == nil && candidate.password == nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, Self.isSameOrigin(url, as: origin) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
