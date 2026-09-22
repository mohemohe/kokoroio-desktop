import Foundation

public enum APIJSON {
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO 8601 timestamp")
        }
        return decoder
    }
}

public struct Avatar: Codable, Hashable, Sendable {
    public var size: Int
    public var url: URL?
    public var isDefault: Bool

    public init(size: Int = 40, url: URL? = nil, isDefault: Bool = false) {
        self.size = size; self.url = url; self.isDefault = isDefault
    }

    enum CodingKeys: String, CodingKey { case size, url; case isDefault = "is_default" }
}

public struct Profile: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var type: String
    public var screenName: String
    public var displayName: String
    public var avatar: URL?
    public var avatars: [Avatar]
    public var archived: Bool
    public var invitedChannelsCount: Int
    public var initials: String {
        let words = displayName.split(whereSeparator: { $0.isWhitespace })
        let value = words.count > 1 ? words.prefix(2).compactMap(\.first).map(String.init).joined() : String(displayName.prefix(2))
        return value.isEmpty ? String(screenName.prefix(2)).uppercased() : value.uppercased()
    }

    public init(id: String, type: String = "User", screenName: String = "", displayName: String = "", avatar: URL? = nil, avatars: [Avatar] = [], archived: Bool = false, invitedChannelsCount: Int = 0) {
        self.id = id; self.type = type; self.screenName = screenName; self.displayName = displayName
        self.avatar = avatar; self.avatars = avatars; self.archived = archived; self.invitedChannelsCount = invitedChannelsCount
    }

    enum CodingKeys: String, CodingKey {
        case id, type, avatar, avatars, archived
        case screenName = "screen_name", displayName = "display_name", invitedChannelsCount = "invited_channels_count"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(String.self, forKey: .id),
                  type: try values.decodeIfPresent(String.self, forKey: .type) ?? "User",
                  screenName: try values.decodeIfPresent(String.self, forKey: .screenName) ?? "",
                  displayName: try values.decodeIfPresent(String.self, forKey: .displayName) ?? "",
                  avatar: try values.decodeIfPresent(URL.self, forKey: .avatar),
                  avatars: try values.decodeIfPresent([Avatar].self, forKey: .avatars) ?? [],
                  archived: try values.decodeIfPresent(Bool.self, forKey: .archived) ?? false,
                  invitedChannelsCount: try values.decodeIfPresent(Int.self, forKey: .invitedChannelsCount) ?? 0)
    }
}

public struct MembershipDetails: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var authority: String
    public var disableNotification: Bool
    public var notificationPolicy: String
    public var readStateTrackingPolicy: String
    public var latestReadMessageID: Int
    public var unreadCount: Int
    public var visible: Bool
    public var muted: Bool
    public var profile: Profile?
    public var canPost: Bool { ["administrator", "maintainer", "member"].contains(authority) }

    public init(id: String, authority: String = "member", disableNotification: Bool = false, notificationPolicy: String = "all_messages", readStateTrackingPolicy: String = "keep_latest", latestReadMessageID: Int = 0, unreadCount: Int = 0, visible: Bool = true, muted: Bool = false, profile: Profile? = nil) {
        self.id = id; self.authority = authority; self.disableNotification = disableNotification
        self.notificationPolicy = notificationPolicy; self.readStateTrackingPolicy = readStateTrackingPolicy
        self.latestReadMessageID = latestReadMessageID; self.unreadCount = unreadCount
        self.visible = visible; self.muted = muted; self.profile = profile
    }

    enum CodingKeys: String, CodingKey {
        case id, authority, visible, muted, profile
        case disableNotification = "disable_notification", notificationPolicy = "notification_policy"
        case readStateTrackingPolicy = "read_state_tracking_policy", latestReadMessageID = "latest_read_message_id", unreadCount = "unread_count"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(String.self, forKey: .id),
                  authority: try values.decodeIfPresent(String.self, forKey: .authority) ?? "member",
                  disableNotification: try values.decodeIfPresent(Bool.self, forKey: .disableNotification) ?? false,
                  notificationPolicy: try values.decodeIfPresent(String.self, forKey: .notificationPolicy) ?? "all_messages",
                  readStateTrackingPolicy: try values.decodeIfPresent(String.self, forKey: .readStateTrackingPolicy) ?? "keep_latest",
                  latestReadMessageID: try values.decodeIfPresent(Int.self, forKey: .latestReadMessageID) ?? 0,
                  unreadCount: try values.decodeIfPresent(Int.self, forKey: .unreadCount) ?? 0,
                  visible: try values.decodeIfPresent(Bool.self, forKey: .visible) ?? true,
                  muted: try values.decodeIfPresent(Bool.self, forKey: .muted) ?? false,
                  profile: try values.decodeIfPresent(Profile.self, forKey: .profile))
    }
}

public struct Channel: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var channelName: String
    public var kind: String
    public var archived: Bool
    public var description: String
    public var latestMessageID: Int?
    public var latestMessagePublishedAt: Date?
    public var messagesCount: Int
    public var membership: MembershipDetails?
    public var name: String { channelName }
    public var isDirectMessage: Bool { kind == "direct_message" }
    public var unreadCount: Int { membership?.unreadCount ?? 0 }

    public init(id: String, channelName: String, kind: String = "public_channel", archived: Bool = false, description: String = "", latestMessageID: Int? = nil, latestMessagePublishedAt: Date? = nil, messagesCount: Int = 0, membership: MembershipDetails? = nil) {
        self.id = id; self.channelName = channelName; self.kind = kind; self.archived = archived; self.description = description
        self.latestMessageID = latestMessageID; self.latestMessagePublishedAt = latestMessagePublishedAt
        self.messagesCount = messagesCount; self.membership = membership
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, archived, description, membership
        case channelName = "channel_name", latestMessageID = "latest_message_id"
        case latestMessagePublishedAt = "latest_message_published_at", messagesCount = "messages_count"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(String.self, forKey: .id),
                  channelName: try values.decode(String.self, forKey: .channelName),
                  kind: try values.decodeIfPresent(String.self, forKey: .kind) ?? "public_channel",
                  archived: try values.decodeIfPresent(Bool.self, forKey: .archived) ?? false,
                  description: try values.decodeIfPresent(String.self, forKey: .description) ?? "",
                  latestMessageID: try values.decodeIfPresent(Int.self, forKey: .latestMessageID),
                  latestMessagePublishedAt: try values.decodeIfPresent(Date.self, forKey: .latestMessagePublishedAt),
                  messagesCount: try values.decodeIfPresent(Int.self, forKey: .messagesCount) ?? 0,
                  membership: try values.decodeIfPresent(MembershipDetails.self, forKey: .membership))
    }
}

/// Membership responses contain the channel and membership fields at the same JSON level.
public struct Membership: Codable, Identifiable, Hashable, Sendable {
    public var channel: Channel
    public var details: MembershipDetails
    public var id: String { details.id }
    public var unreadCount: Int { details.unreadCount }
    public var latestReadMessageID: Int { details.latestReadMessageID }

    public init(channel: Channel, details: MembershipDetails) {
        self.channel = channel; self.details = details
    }

    enum CodingKeys: String, CodingKey { case channel }
    public init(from decoder: Decoder) throws {
        channel = try decoder.container(keyedBy: CodingKeys.self).decode(Channel.self, forKey: .channel)
        details = try MembershipDetails(from: decoder)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(channel, forKey: .channel)
        try details.encode(to: encoder)
    }
    public var populatedChannel: Channel {
        var result = channel
        result.membership = details
        return result
    }
}

/// Resolved media use the server's `embed_contents` envelope for both URL previews and uploads.
public struct EmbedContent: Codable, Hashable, Sendable {
    public var url: URL?
    public var position: Int
    public var data: EmbedData?

    public init(url: URL? = nil, position: Int = 0, data: EmbedData? = nil) {
        self.url = url; self.position = position; self.data = data
    }

    public var isUploadedImage: Bool { data?.type == "UploadedImage" }
    public var isImageOnly: Bool { ["UploadedImage", "SingleImage", "photo", "image"].contains(data?.type ?? "") }
    public var isRestricted: Bool {
        data?.restrictionPolicy == "Restricted" || data?.metadataImage?.restrictionPolicy == "Restricted" || data?.nsfw == true
    }
    public var hasUnavailableImage: Bool { isUploadedImage && imagePreviews.isEmpty }
    public var linkURL: URL? { safeEmbedURL(data?.url) ?? safeEmbedURL(url) }

    public var imagePreviews: [EmbedImagePreview] {
        guard let data, data.available != false else { return [] }
        var result = data.medias.enumerated().compactMap { index, media -> EmbedImagePreview? in
            let isVideo = media.type == "Video"
            guard media.type == "Image" || isVideo || (isImageOnly && media.type == nil),
                  let thumbnail = safeEmbedURL(media.thumbnail?.url) ?? (isVideo ? nil : safeEmbedURL(media.rawURL)),
                  let destination = safeEmbedURL(media.rawURL) ?? linkURL ?? safeEmbedURL(media.thumbnail?.url) else { return nil }
            return EmbedImagePreview(id: "media-\(index)", thumbnailURL: thumbnail, linkURL: destination,
                                     isVideo: isVideo, isRestricted: isRestricted || media.restrictionPolicy == "Restricted")
        }
        result += data.images.enumerated().compactMap { index, image in
            guard let thumbnail = safeEmbedURL(image.thumbnailURL) ?? safeEmbedURL(image.url),
                  let destination = safeEmbedURL(image.url) ?? safeEmbedURL(image.thumbnailURL) else { return nil }
            return EmbedImagePreview(id: "image-\(index)", thumbnailURL: thumbnail, linkURL: destination, isRestricted: isRestricted)
        }
        if result.isEmpty, isImageOnly,
           let thumbnail = safeEmbedURL(data.thumbnailURL) ?? data.metadataImage?.previewURL ?? linkURL,
           let destination = linkURL ?? safeEmbedURL(data.thumbnailURL) ?? data.metadataImage?.previewURL {
            result.append(EmbedImagePreview(id: "image", thumbnailURL: thumbnail, linkURL: destination, isRestricted: isRestricted))
        }
        return result
    }

    public var cardTitle: String {
        if data?.available == false { return "参照先を表示できません" }
        if let title = data?.title?.nonemptyEmbedText { return title }
        if data?.type == "KokoroChannel", let name = data?.channel?.name?.nonemptyEmbedText { return "#\(name)" }
        if data?.type == "KokoroMessage", let name = data?.displayName?.nonemptyEmbedText { return name }
        return linkURL?.host ?? "リンク"
    }

    public var cardDescription: String? {
        guard data?.available != false else { return nil }
        return data?.description?.nonemptyEmbedText ?? data?.htmlContent?.plainEmbedText ?? data?.channel?.description?.nonemptyEmbedText
    }

    public var cardThumbnailURL: URL? {
        guard data?.available != false else { return nil }
        return data?.metadataImage?.previewURL ?? safeEmbedURL(data?.thumbnailURL) ?? imagePreviews.first?.thumbnailURL
    }

    enum CodingKeys: String, CodingKey { case url, position, data }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(url: values.embedURL(forKey: .url), position: values.embedValue(Int.self, forKey: .position) ?? 0,
                  data: values.embedValue(EmbedData.self, forKey: .data))
    }
}

public struct EmbedImagePreview: Identifiable, Hashable, Sendable {
    public var id: String
    public var thumbnailURL: URL
    public var linkURL: URL
    public var isVideo: Bool
    public var isRestricted: Bool

    public init(id: String, thumbnailURL: URL, linkURL: URL, isVideo: Bool = false, isRestricted: Bool = false) {
        self.id = id; self.thumbnailURL = thumbnailURL; self.linkURL = linkURL
        self.isVideo = isVideo; self.isRestricted = isRestricted
    }
}

public struct EmbedData: Codable, Hashable, Sendable {
    public var type: String?
    public var title: String?
    public var description: String?
    public var url: URL?
    public var thumbnailURL: URL?
    public var medias: [EmbedMedia]
    public var metadataImage: EmbedMedia?
    public var restrictionPolicy: String?
    public var providerName: String?
    public var authorName: String?
    public var available: Bool?
    public var displayName: String?
    public var htmlContent: String?
    public var channel: EmbedChannel?
    public var images: [EmbedImage]
    public var nsfw: Bool?

    public init(type: String? = nil, title: String? = nil, description: String? = nil, url: URL? = nil,
                thumbnailURL: URL? = nil, medias: [EmbedMedia] = [], metadataImage: EmbedMedia? = nil,
                restrictionPolicy: String? = nil, providerName: String? = nil, authorName: String? = nil,
                available: Bool? = nil, displayName: String? = nil, htmlContent: String? = nil,
                channel: EmbedChannel? = nil, images: [EmbedImage] = [], nsfw: Bool? = nil) {
        self.type = type; self.title = title; self.description = description; self.url = url
        self.thumbnailURL = thumbnailURL; self.medias = medias; self.metadataImage = metadataImage
        self.restrictionPolicy = restrictionPolicy; self.providerName = providerName; self.authorName = authorName
        self.available = available; self.displayName = displayName; self.htmlContent = htmlContent
        self.channel = channel; self.images = images; self.nsfw = nsfw
    }

    enum CodingKeys: String, CodingKey {
        case type, title, description, url, medias, available, channel, images, nsfw
        case thumbnailURL = "thumbnail_url", metadataImage = "metadata_image", restrictionPolicy = "restriction_policy"
        case providerName = "provider_name", authorName = "author_name", displayName = "display_name", htmlContent = "html_content"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(type: values.embedValue(String.self, forKey: .type), title: values.embedValue(String.self, forKey: .title),
                  description: values.embedValue(String.self, forKey: .description), url: values.embedURL(forKey: .url),
                  thumbnailURL: values.embedURL(forKey: .thumbnailURL), medias: values.embedArray(EmbedMedia.self, forKey: .medias),
                  metadataImage: values.embedValue(EmbedMedia.self, forKey: .metadataImage),
                  restrictionPolicy: values.embedValue(String.self, forKey: .restrictionPolicy),
                  providerName: values.embedValue(String.self, forKey: .providerName), authorName: values.embedValue(String.self, forKey: .authorName),
                  available: values.embedValue(Bool.self, forKey: .available), displayName: values.embedValue(String.self, forKey: .displayName),
                  htmlContent: values.embedValue(String.self, forKey: .htmlContent), channel: values.embedValue(EmbedChannel.self, forKey: .channel),
                  images: values.embedArray(EmbedImage.self, forKey: .images), nsfw: values.embedValue(Bool.self, forKey: .nsfw))
    }
}

public struct EmbedMedia: Codable, Hashable, Sendable {
    public var type: String?
    public var rawURL: URL?
    public var thumbnail: EmbedImageInfo?
    public var restrictionPolicy: String?
    public var previewURL: URL? { safeEmbedURL(thumbnail?.url) ?? (type == "Video" || type == "Audio" ? nil : safeEmbedURL(rawURL)) }

    public init(type: String? = nil, rawURL: URL? = nil, thumbnail: EmbedImageInfo? = nil, restrictionPolicy: String? = nil) {
        self.type = type; self.rawURL = rawURL; self.thumbnail = thumbnail; self.restrictionPolicy = restrictionPolicy
    }

    enum CodingKeys: String, CodingKey { case type, thumbnail; case rawURL = "raw_url", restrictionPolicy = "restriction_policy" }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(type: values.embedValue(String.self, forKey: .type), rawURL: values.embedURL(forKey: .rawURL),
                  thumbnail: values.embedValue(EmbedImageInfo.self, forKey: .thumbnail),
                  restrictionPolicy: values.embedValue(String.self, forKey: .restrictionPolicy))
    }
}

public struct EmbedImageInfo: Codable, Hashable, Sendable {
    public var url: URL?
    public var width: Int?
    public var height: Int?

    public init(url: URL? = nil, width: Int? = nil, height: Int? = nil) {
        self.url = url; self.width = width; self.height = height
    }

    enum CodingKeys: String, CodingKey { case url, width, height }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(url: values.embedURL(forKey: .url), width: values.embedValue(Int.self, forKey: .width),
                  height: values.embedValue(Int.self, forKey: .height))
    }
}

public struct EmbedImage: Codable, Hashable, Sendable {
    public var url: URL?
    public var thumbnailURL: URL?

    public init(url: URL? = nil, thumbnailURL: URL? = nil) { self.url = url; self.thumbnailURL = thumbnailURL }
    enum CodingKeys: String, CodingKey { case url; case thumbnailURL = "thumbnail_url" }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(url: values.embedURL(forKey: .url), thumbnailURL: values.embedURL(forKey: .thumbnailURL))
    }
}

public struct EmbedChannel: Codable, Hashable, Sendable {
    public var name: String?
    public var description: String?

    public init(name: String? = nil, description: String? = nil) { self.name = name; self.description = description }
    enum CodingKeys: String, CodingKey { case name, description }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: values.embedValue(String.self, forKey: .name), description: values.embedValue(String.self, forKey: .description))
    }
}

private func safeEmbedURL(_ url: URL?) -> URL? {
    guard let url, ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
          let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
    return url
}

private extension String {
    var nonemptyEmbedText: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }

    /// Preview text only: remove markup before decoding entities, so decoded tags remain plain text.
    var plainEmbedText: String? {
        var result = replacingOccurrences(of: #"(?is)<(script|style)\b[^>]*>.*?</\1\s*>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)<br\s*/?>|</(?:p|div|li)\s*>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        if let pattern = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#) {
            let matches = pattern.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let range = Range(match.range(at: 1), in: result), let fullRange = Range(match.range, in: result) else { continue }
                let value = String(result[range])
                let code = value.hasPrefix("x") ? UInt32(value.dropFirst(), radix: 16) : UInt32(value)
                if let code, let scalar = UnicodeScalar(code) { result.replaceSubrange(fullRange, with: String(scalar)) }
            }
        }
        for (entity, replacement) in [("&nbsp;", " "), ("&quot;", "\""), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines).nonemptyEmbedText
    }
}

private struct OptionalEmbedValue<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? decoder.singleValueContainer().decode(Value.self) }
}

private extension KeyedDecodingContainer {
    func embedValue<Value: Decodable>(_ type: Value.Type, forKey key: Key) -> Value? { try? decodeIfPresent(type, forKey: key) }
    func embedArray<Value: Decodable>(_ type: Value.Type, forKey key: Key) -> [Value] {
        (try? decodeIfPresent([OptionalEmbedValue<Value>].self, forKey: key))?.compactMap(\.value) ?? []
    }
    func embedURL(forKey key: Key) -> URL? {
        guard let value = embedValue(String.self, forKey: key) else { return nil }
        return safeEmbedURL(URL(string: value))
    }
}

public struct Message: Codable, Identifiable, Hashable, Sendable {
    /// Message IDs are database integers, unlike the Hashid strings used by other API entities.
    public var id: Int
    public var idempotentKey: String
    public var displayName: String
    public var avatar: URL?
    public var avatars: [Avatar]
    public var status: String
    public var htmlContent: String
    public var plaintextContent: String
    public var rawContent: String
    public var publishedAt: Date
    public var nsfw: Bool
    public var expandEmbedContents: Bool
    public var embeddedURLs: [URL]
    public var embedContents: [EmbedContent]
    public var channel: Channel
    public var profile: Profile
    public var text: String { plaintextContent.isEmpty ? rawContent : plaintextContent }
    public var isDeleted: Bool { status != "active" }

    public init(id: Int, idempotentKey: String = UUID().uuidString.lowercased(), displayName: String = "", avatar: URL? = nil, avatars: [Avatar] = [], status: String = "active", htmlContent: String = "", plaintextContent: String = "", rawContent: String = "", publishedAt: Date = Date(), nsfw: Bool = false, expandEmbedContents: Bool = true, embeddedURLs: [URL] = [], embedContents: [EmbedContent] = [], channel: Channel, profile: Profile) {
        self.id = id; self.idempotentKey = idempotentKey; self.displayName = displayName.isEmpty ? profile.displayName : displayName
        self.avatar = avatar; self.avatars = avatars; self.status = status; self.htmlContent = htmlContent
        self.plaintextContent = plaintextContent; self.rawContent = rawContent; self.publishedAt = publishedAt
        self.nsfw = nsfw; self.channel = channel; self.profile = profile
        self.expandEmbedContents = expandEmbedContents; self.embeddedURLs = embeddedURLs
        self.embedContents = embedContents.enumerated().sorted {
            $0.element.position == $1.element.position ? $0.offset < $1.offset : $0.element.position < $1.element.position
        }.map(\.element)
    }

    enum CodingKeys: String, CodingKey {
        case id, avatar, avatars, status, nsfw, channel, profile
        case idempotentKey = "idempotent_key", displayName = "display_name", htmlContent = "html_content"
        case plaintextContent = "plaintext_content", rawContent = "raw_content", publishedAt = "published_at"
        case expandEmbedContents = "expand_embed_contents", embeddedURLs = "embedded_urls", embedContents = "embed_contents"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(Int.self, forKey: .id),
                  idempotentKey: try values.decodeIfPresent(String.self, forKey: .idempotentKey) ?? "",
                  displayName: try values.decodeIfPresent(String.self, forKey: .displayName) ?? "",
                  avatar: try values.decodeIfPresent(URL.self, forKey: .avatar),
                  avatars: try values.decodeIfPresent([Avatar].self, forKey: .avatars) ?? [],
                  status: try values.decodeIfPresent(String.self, forKey: .status) ?? "active",
                  htmlContent: try values.decodeIfPresent(String.self, forKey: .htmlContent) ?? "",
                  plaintextContent: try values.decodeIfPresent(String.self, forKey: .plaintextContent) ?? "",
                  rawContent: try values.decodeIfPresent(String.self, forKey: .rawContent) ?? "",
                  publishedAt: try values.decode(Date.self, forKey: .publishedAt),
                  nsfw: try values.decodeIfPresent(Bool.self, forKey: .nsfw) ?? false,
                  expandEmbedContents: values.embedValue(Bool.self, forKey: .expandEmbedContents) ?? true,
                  embeddedURLs: values.embedArray(URL.self, forKey: .embeddedURLs).compactMap(safeEmbedURL),
                  embedContents: values.embedArray(EmbedContent.self, forKey: .embedContents),
                  channel: try values.decode(Channel.self, forKey: .channel),
                  profile: try values.decode(Profile.self, forKey: .profile))
    }
}
