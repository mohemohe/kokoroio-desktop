import Foundation
import XCTest
@testable import KokoroCore

final class MessageEmbedFallbackTests: XCTestCase {
    private let link = URL(string: "https://x.com/kiwicopple/status/2106047481851326869")!
    private let serverDescription = "@supabase has acquired @tursodatabase\n\ni'm been a huge fan of the team and what they've built.\n\nhttps://t.co/fwDsA2WLkd"

    func testMissingAPIDescriptionUsesServerCardWithoutOverwritingAPIFields() throws {
        var fallback = MessageEmbedFallback()
        let source = message(828076)
        XCTAssertEqual(fallback.nextRequest(in: [source])?.afterID, 828075)
        XCTAssertTrue(fallback.accept([], linkRecords: [record(source.id)], currentMessages: [source]))
        let displayed = fallback.applying(to: source)
        let embed = try XCTUnwrap(displayed.embedContents.first)
        XCTAssertEqual(embed.cardDescription, serverDescription)
        XCTAssertEqual(embed.cardTitle, "API title")
        XCTAssertEqual(embed.cardThumbnailURL?.absoluteString, "https://api.example/author.jpg")
        XCTAssertTrue(embed.cardThumbnailIsAuthor)
        XCTAssertEqual(embed.linkURL, link)
        XCTAssertNil(source.embedContents[0].cardDescription)
        XCTAssertNil(fallback.nextRequest(in: [source]))
    }

    func testCompleteAPIMetadataAndDisabledOrUnavailableEmbedsDoNotRequestWeb() {
        var fallback = MessageEmbedFallback()
        var complete = message(20)
        complete.embedContents[0].data?.description = "API description"
        complete.embedContents[0].data?.metadataImageIsAuthor = false
        var disabled = message(21)
        disabled.expandEmbedContents = false
        var deleted = message(22)
        deleted.status = "deleted_by_publisher"
        var unavailable = message(23)
        unavailable.embedContents[0].data?.available = false
        XCTAssertNil(fallback.nextRequest(in: [complete, disabled, deleted, unavailable]))
    }

    func testAPIDescriptionIsPreservedWhenOnlyAuthorClassificationIsMissing() {
        var fallback = MessageEmbedFallback()
        var source = message(20)
        source.embedContents[0].data?.description = "API description"
        XCTAssertNotNil(fallback.nextRequest(in: [source]))
        XCTAssertTrue(fallback.accept([], linkRecords: [record(20)], currentMessages: [source]))
        let embed = fallback.applying(to: source).embedContents[0]
        XCTAssertEqual(embed.cardDescription, "API description")
        XCTAssertTrue(embed.cardThumbnailIsAuthor)
    }

    func testChannelAndLinkMustMatchAndDuplicateCardsAreNotApplied() {
        for cards in [[record(20, channelID: "OTHER")], [record(21)],
                      [record(20, url: URL(string: "https://example.test/other")!)],
                      [record(20, copies: 2)]] {
            var fallback = MessageEmbedFallback()
            let source = message(20)
            _ = fallback.nextRequest(in: [source])
            _ = fallback.accept([], linkRecords: cards, currentMessages: [source])
            XCTAssertNil(fallback.applying(to: source).embedContents[0].cardDescription)
        }
    }

    func testContentOnlyReplacementRequiresPendingMessageSnapshot() {
        var fallback = MessageEmbedFallback()
        let source = message(20)
        XCTAssertFalse(fallback.accept([], linkRecords: [record(20, channelID: nil)], currentMessages: [source]))
        _ = fallback.nextRequest(in: [source])
        XCTAssertFalse(fallback.accept([], linkRecords: [record(21, channelID: nil)], currentMessages: [source]))
        XCTAssertTrue(fallback.accept([], linkRecords: [record(20, channelID: nil)], currentMessages: [source]))
        XCTAssertEqual(fallback.applying(to: source).embedContents[0].cardDescription, serverDescription)
    }

    func testLaterContentReplacementSupersedesInitialAppendInResponse() {
        var fallback = MessageEmbedFallback()
        let source = message(20)
        _ = fallback.nextRequest(in: [source])
        let append = HotwireMessageEmbeds(channelID: "CHANNEL01", messageID: 20, cards: [])
        XCTAssertTrue(fallback.accept([], linkRecords: [append, record(20, channelID: nil)], currentMessages: [source]))
        XCTAssertEqual(fallback.applying(to: source).embedContents[0].cardDescription, serverDescription)
    }

    func testEditsExpansionPreferenceDeletionAndTimeoutInvalidateWebMetadata() {
        var fallback = MessageEmbedFallback()
        let source = message(20)
        _ = fallback.nextRequest(in: [source])
        var edited = source
        edited.rawContent = "edited"
        XCTAssertTrue(fallback.accept([], linkRecords: [record(20)], currentMessages: [edited]))
        XCTAssertNil(fallback.applying(to: edited).embedContents[0].cardDescription)
        _ = fallback.nextRequest(in: [edited])
        XCTAssertTrue(fallback.accept([], linkRecords: [record(20)], currentMessages: [edited]))
        var hidden = edited
        hidden.expandEmbedContents = false
        XCTAssertEqual(fallback.applying(to: hidden), hidden)
        var deleted = edited
        deleted.status = "deleted_by_publisher"
        XCTAssertEqual(fallback.applying(to: deleted), deleted)
        fallback.invalidate(messageID: 20)
        XCTAssertNil(fallback.applying(to: edited).embedContents[0].cardDescription)
        _ = fallback.nextRequest(in: [edited])
        fallback.failPendingRequest()
        XCTAssertFalse(fallback.accept([], linkRecords: [record(20)], currentMessages: [edited]))
        XCTAssertNil(fallback.nextRequest(in: [edited]))
        fallback.reset()
        XCTAssertNotNil(fallback.nextRequest(in: [edited]))
    }

    func testUploadedImageAndLinkMetadataShareOneRequestAndSensitiveGate() throws {
        var fallback = MessageEmbedFallback()
        var source = message(20)
        source.embedContents.append(EmbedContent(position: 1, data: EmbedData(type: "UploadedImage")))
        _ = fallback.nextRequest(in: [source])
        let image = EmbedImagePreview(id: "upload", thumbnailURL: URL(string: "https://media.example/thumb.png")!,
                                     linkURL: URL(string: "https://media.example/full.png")!)
        XCTAssertTrue(fallback.accept([HotwireMessageImages(channelID: "CHANNEL01", messageID: 20, images: [image])],
                                      linkRecords: [record(20, restricted: true)], currentMessages: [source]))
        let displayed = fallback.applying(to: source)
        XCTAssertEqual(displayed.embedContents[0].cardDescription, serverDescription)
        XCTAssertTrue(displayed.embedContents[0].isRestricted)
        XCTAssertEqual(displayed.embedContents[1].imagePreviews, [EmbedImagePreview(id: "image", thumbnailURL: image.thumbnailURL, linkURL: image.linkURL)])
    }

    func testEmptyFirstPageCompletesAndNextUnresolvedMessageStartsNextPage() {
        var fallback = MessageEmbedFallback()
        let sources = [message(20), message(250)]
        _ = fallback.nextRequest(in: sources)
        let records = (20...219).map { HotwireMessageEmbeds(channelID: "CHANNEL01", messageID: $0, cards: []) }
        XCTAssertTrue(fallback.accept([], linkRecords: records, currentMessages: sources))
        XCTAssertEqual(fallback.nextRequest(in: sources)?.afterID, 249)
    }

    private func message(_ id: Int) -> Message {
        Message(id: id, rawContent: link.absoluteString, embedContents: [EmbedContent(url: link, data: EmbedData(
            type: "MixedContent", title: "API title", metadataImage: EmbedMedia(type: "Image", rawURL: URL(string: "https://api.example/author.jpg"))))],
                channel: Channel(id: "CHANNEL01", channelName: "general"), profile: Profile(id: "PROFILE01"))
    }

    private func record(_ id: Int, channelID: String? = "CHANNEL01", url: URL? = nil,
                        copies: Int = 1, restricted: Bool = false) -> HotwireMessageEmbeds {
        HotwireMessageEmbeds(channelID: channelID, messageID: id, cards: Array(repeating: HotwireLinkCard(
            url: url ?? link, title: "Web title", description: serverDescription,
            thumbnailURL: URL(string: "https://web.example/author.jpg"), thumbnailIsAuthor: true, isRestricted: restricted), count: copies))
    }
}
