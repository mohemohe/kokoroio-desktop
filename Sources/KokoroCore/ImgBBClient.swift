import Foundation

public struct ImgBBUpload: Sendable {
    public let url: URL
    public let deleteURL: URL

    public init(url: URL, deleteURL: URL) {
        self.url = url
        self.deleteURL = deleteURL
    }
}

public enum ImgBBError: LocalizedError {
    case invalidImage
    case imageTooLarge
    case invalidResponse
    case server(Int)
    case unsafeDeleteURL
    case missingAPIKey

    public var errorDescription: String? {
        switch self {
        case .invalidImage: return "画像ファイルを読み込めませんでした。"
        case .imageTooLarge: return "ImgBB にアップロードできる画像は 32 MB 以下です。"
        case .invalidResponse: return "ImgBB の応答を読み取れませんでした。"
        case .server(let status): return "ImgBB のリクエストに失敗しました (HTTP \(status))。"
        case .unsafeDeleteURL: return "ImgBB の削除 URL が安全ではありません。"
        case .missingAPIKey: return "ImgBB の API キーを設定してください。"
        }
    }
}

public struct ImgBBClient: Sendable {
    private let session: URLSession
    private let uploadEndpoint: URL
    private static let maximumImageBytes = 32 * 1024 * 1024

    public init(session: URLSession = .shared, uploadEndpoint: URL = URL(string: "https://api.imgbb.com/1/upload")!) {
        self.session = session
        self.uploadEndpoint = uploadEndpoint
    }

    public func upload(data: Data, fileName: String, mimeType: String, apiKey: String) async throws -> ImgBBUpload {
        guard !data.isEmpty else { throw ImgBBError.invalidImage }
        guard data.count <= Self.maximumImageBytes else { throw ImgBBError.imageTooLarge }
        guard !apiKey.isEmpty, var components = URLComponents(url: uploadEndpoint, resolvingAgainstBaseURL: false) else {
            throw ImgBBError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else { throw ImgBBError.invalidResponse }

        let boundary = "KokoroImgBB-\(UUID().uuidString)"
        let safeFileName = fileName.replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"\(safeFileName)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8)
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        let (responseData, response) = try await session.data(for: request, delegate: SameOriginRedirectGuard(origin: url))
        guard let response = response as? HTTPURLResponse else { throw ImgBBError.invalidResponse }
        guard (200...299).contains(response.statusCode) else { throw ImgBBError.server(response.statusCode) }
        let payload = try? JSONDecoder().decode(UploadResponse.self, from: responseData)
        guard let payload, payload.success, payload.status == 200,
              Self.isSafeImageURL(payload.data.url), Self.isSafeDeleteURL(payload.data.deleteURL) else {
            throw ImgBBError.invalidResponse
        }
        return ImgBBUpload(url: payload.data.url, deleteURL: payload.data.deleteURL)
    }

    public func delete(_ upload: ImgBBUpload, apiKey: String) async throws {
        guard let (id, hash) = Self.deleteURLParts(upload.deleteURL) else { throw ImgBBError.unsafeDeleteURL }
        guard !apiKey.isEmpty else { throw ImgBBError.missingAPIKey }
        let endpoint = URL(string: "https://ibb.co/json")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("https://ibb.co", forHTTPHeaderField: "Origin")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        let fields = [
            ("auth_token", apiKey),
            ("pathname", "/\(id)/\(hash)"),
            ("action", "delete"),
            ("delete", "image"),
            ("from", "resource"),
            ("deleting[id]", id),
            ("deleting[type]", "image"),
            ("deleting[privacy]", "public"),
            ("deleting[hash]", hash)
        ]
        request.httpBody = Data(fields.map { "\(Self.formEncode($0.0))=\(Self.formEncode($0.1))" }.joined(separator: "&").utf8)
        let (_, response) = try await session.data(for: request, delegate: SameOriginRedirectGuard(origin: endpoint))
        guard let response = response as? HTTPURLResponse else { throw ImgBBError.invalidResponse }
        guard response.statusCode == 200 else { throw ImgBBError.server(response.statusCode) }
    }

    private static func isSafeImageURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil
    }

    private static func isSafeDeleteURL(_ url: URL) -> Bool {
        deleteURLParts(url) != nil
    }

    private static func deleteURLParts(_ url: URL) -> (String, String)? {
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == "ibb.co",
              url.port == nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let parts = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty,
              parts[1].utf8.allSatisfy(Self.isSafePathByte),
              parts[2].utf8.allSatisfy(Self.isSafePathByte),
              !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
        return (String(parts[1]), String(parts[2]))
    }

    private static func isSafePathByte(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte)
            || (0x61...0x7A).contains(byte) || byte == 0x2D || byte == 0x5F
    }

    private static func formEncode(_ value: String) -> String {
        value.utf8.map { byte in
            if isSafePathByte(byte) || byte == 0x2E || byte == 0x7E {
                return String(UnicodeScalar(byte))
            }
            if byte == 0x20 { return "+" }
            return String(format: "%%%02X", byte)
        }.joined()
    }

    private struct UploadResponse: Decodable {
        let data: UploadData
        let success: Bool
        let status: Int
    }

    private struct UploadData: Decodable {
        let url: URL
        let deleteURL: URL

        enum CodingKeys: String, CodingKey {
            case url
            case deleteURL = "delete_url"
        }
    }
}

public enum ComposerMessage {
    public static func text(_ draft: String, imageURLs: [URL]) -> String {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return ([body].filter { !$0.isEmpty } + imageURLs.map(\.absoluteString)).joined(separator: "\n")
    }
}
