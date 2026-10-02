import Foundation

/// The server processes media and returns a signed reference for attaching it to a message.
public struct ImageUpload: Codable, Sendable {
    public let signedID: String
    public let contentType: String
    public let animated: Bool
    public let animationFormat: String?

    public init(signedID: String, contentType: String, animated: Bool, animationFormat: String? = nil) {
        self.signedID = signedID
        self.contentType = contentType
        self.animated = animated
        self.animationFormat = animationFormat
    }

    enum CodingKeys: String, CodingKey {
        case signedID = "signed_id", contentType = "content_type", animated, animationFormat = "animation_format"
    }
}

public enum ImageUploadError: LocalizedError, Equatable {
    case invalidImage

    public var errorDescription: String? {
        switch self {
        case .invalidImage: return "画像ファイルを読み込めませんでした。"
        }
    }
}
