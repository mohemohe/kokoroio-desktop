import Foundation

/// Compatibility for API projections that omit uploaded-image URLs or link descriptions.
/// Missing metadata is recovered from kokoro.io's own rendered message, never the linked site.
public struct MessageEmbedFallback {
    public struct Request: Equatable, Sendable {
        public let channelID: String
        public let afterID: Int
    }

    private struct Source: Equatable {
        let channelID: String
        let status: String
        let content: String
        let nsfw: Bool
        let expandsEmbeds: Bool
        let embeds: [EmbedContent]

        init(_ message: Message) {
            channelID = message.channel.id; status = message.status
            content = message.rawContent; nsfw = message.nsfw; embeds = message.embedContents
            expandsEmbeds = message.expandEmbedContents
        }
    }

    private struct Resolution {
        let source: Source
        let images: [EmbedImagePreview]
        let cards: [HotwireLinkCard]
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
        let candidates = messages.filter { message in
            message.id > 1 && !message.isDeleted && message.embedContents.contains(where: {
                $0.hasUnavailableImage || ($0.needsWebLinkMetadata && message.expandEmbedContents)
            })
                && attempted[message.id] != Source(message)
                && resolutions[message.id]?.source != Source(message)
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
    public mutating func accept(_ records: [HotwireMessageImages], linkRecords: [HotwireMessageEmbeds] = [], currentMessages: [Message]) -> Bool {
        guard let pending,
              records.contains(where: { $0.channelID == pending.request.channelID && $0.messageID == pending.request.afterID + 1 }) ||
                linkRecords.contains(where: { ($0.channelID == pending.request.channelID || $0.channelID == nil) && $0.messageID == pending.request.afterID + 1 })
        else { return false }
        let relevant = records.filter { $0.channelID == pending.request.channelID && $0.messageID > pending.request.afterID }
        let links = linkRecords.filter {
            $0.messageID > pending.request.afterID && ($0.channelID == pending.request.channelID ||
                ($0.channelID == nil && pending.sources[$0.messageID] != nil))
        }
        let current = Dictionary(uniqueKeysWithValues: currentMessages.map { ($0.id, $0) })
        let lastID = (relevant.map(\.messageID) + links.map(\.messageID)).max() ?? pending.request.afterID
        for (id, source) in pending.sources where id <= lastID {
            guard let message = current[id], Source(message) == source else { continue }
            attempted[id] = source
            let matches = relevant.filter { $0.messageID == id }
            // Full cardinality matters: never assign an adjacent upload's URL to a gap.
            let images = matches.count == 1 && matches.first?.images.count == message.embedContents.filter(\.isUploadedImage).count
                ? matches.first?.images ?? [] : []
            // Turbo applies streams in order: a later content replacement supersedes an append.
            let cards = links.last(where: { $0.messageID == id })?.cards ?? []
            guard !message.isDeleted, !images.isEmpty || !cards.isEmpty else { continue }
            resolutions[id] = Resolution(source: source, images: images, cards: cards)
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
        if message.expandEmbedContents {
            for index in result.embedContents.indices where result.embedContents[index].needsWebLinkMetadata {
                guard let url = result.embedContents[index].linkURL else { continue }
                let matches = resolution.cards.filter { $0.url == url }
                guard matches.count == 1, let card = matches.first else { continue }
                if result.embedContents[index].cardDescription == nil {
                    result.embedContents[index].data?.description = card.description
                }
                if result.embedContents[index].data?.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    result.embedContents[index].data?.title = card.title
                }
                if result.embedContents[index].cardThumbnailURL == nil {
                    result.embedContents[index].data?.thumbnailURL = card.thumbnailURL
                }
                result.embedContents[index].data?.metadataImageIsAuthor = card.thumbnailIsAuthor
                if card.isRestricted { result.embedContents[index].data?.nsfw = true }
            }
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

    /// Search changes the visible messages, not the connection or the source of
    /// already resolved images. Cancel the old batch without dropping that cache.
    public mutating func cancelPendingRequest() { pending = nil }

    public mutating func reset() { self = Self() }
}

/// Kept for callers of the original uploaded-image compatibility helper.
public typealias UploadedImageFallback = MessageEmbedFallback
