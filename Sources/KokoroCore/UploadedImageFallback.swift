import Foundation

/// Temporary compatibility for servers that omit UploadedImage URLs from their API.
/// The REST/event message remains authoritative; only missing image addresses are filled.
public struct UploadedImageFallback {
    public struct Request: Equatable, Sendable {
        public let channelID: String
        public let afterID: Int
    }

    private struct Source: Equatable {
        let channelID: String
        let status: String
        let content: String
        let nsfw: Bool
        let embeds: [EmbedContent]

        init(_ message: Message) {
            channelID = message.channel.id; status = message.status
            content = message.rawContent; nsfw = message.nsfw; embeds = message.embedContents
        }
    }

    private struct Resolution {
        let source: Source
        let images: [EmbedImagePreview]
    }

    private struct Pending {
        let request: Request
        var sources: [Int: Source]
    }

    private var resolutions: [Int: Resolution] = [:]
    private var attempted: [Int: Source] = [:]
    private var pending: Pending?
    private var unavailable = false

    public init() {}

    public var pendingChannelID: String? { pending?.request.channelID }

    /// One request at a time. A resume response contains at most 200 messages;
    /// subsequent requests start at the next unresolved message, not the channel origin.
    public mutating func nextRequest(in messages: [Message]) -> Request? {
        guard pending == nil, !unavailable else { return nil }
        let candidates = messages.filter {
            $0.id > 1 && !$0.isDeleted && $0.embedContents.contains(where: \.hasUnavailableImage)
                && attempted[$0.id] != Source($0)
                && resolutions[$0.id]?.source != Source($0)
        }.sorted { $0.id < $1.id }
        guard let first = candidates.first else { return nil }
        let request = Request(channelID: first.channel.id, afterID: first.id - 1)
        pending = Pending(request: request, sources: Dictionary(uniqueKeysWithValues: candidates
            .filter { $0.channel.id == first.channel.id }.map { ($0.id, Source($0)) }))
        return request
    }

    /// Only the response containing the requested first message can complete this batch.
    /// Edits/deletions received while it was in flight invalidate that message's snapshot.
    @discardableResult
    public mutating func accept(_ records: [HotwireMessageImages], currentMessages: [Message]) -> Bool {
        guard let pending,
              records.contains(where: { $0.channelID == pending.request.channelID && $0.messageID == pending.request.afterID + 1 })
        else { return false }
        let relevant = records.filter { $0.channelID == pending.request.channelID && $0.messageID > pending.request.afterID }
        let current = Dictionary(uniqueKeysWithValues: currentMessages.map { ($0.id, $0) })
        let lastID = relevant.map(\.messageID).max() ?? pending.request.afterID
        for (id, source) in pending.sources where id <= lastID {
            guard let message = current[id], Source(message) == source else { continue }
            attempted[id] = source
            let matches = relevant.filter { $0.messageID == id }
            // Full cardinality matters: never assign an adjacent upload's URL to a gap.
            guard matches.count == 1, let record = matches.first,
                  record.images.count == message.embedContents.filter(\.isUploadedImage).count,
                  !record.images.isEmpty, !message.isDeleted else { continue }
            resolutions[id] = Resolution(source: source, images: record.images)
        }
        self.pending = nil
        return true
    }

    public func applying(to message: Message) -> Message {
        guard !message.isDeleted, let resolution = resolutions[message.id], resolution.source == Source(message) else { return message }
        var result = message
        var imageIndex = 0
        for index in result.embedContents.indices where result.embedContents[index].isUploadedImage {
            defer { imageIndex += 1 }
            guard result.embedContents[index].hasUnavailableImage, imageIndex < resolution.images.count else { continue }
            result.embedContents[index].data?.url = resolution.images[imageIndex].linkURL
            result.embedContents[index].data?.thumbnailURL = resolution.images[imageIndex].thumbnailURL
            if resolution.images[imageIndex].isRestricted { result.embedContents[index].data?.nsfw = true }
        }
        return result
    }

    public mutating func invalidate(messageID: Int) {
        resolutions[messageID] = nil
        attempted[messageID] = nil
        pending?.sources[messageID] = nil
    }

    /// Older servers may not implement resume. Do not repeatedly request or accept late
    /// responses after a timeout; the next connection resets this compatibility state.
    public mutating func failPendingRequest() {
        pending = nil
        unavailable = true
    }

    public mutating func reset() { self = Self() }
}
