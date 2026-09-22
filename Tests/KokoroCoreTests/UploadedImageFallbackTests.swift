import Foundation
import XCTest
@testable import KokoroCore

final class UploadedImageFallbackTests: XCTestCase {
    func testOnlyMissingUploadsAreRequestedAndAPIURLsWin() throws {
        var fallback = UploadedImageFallback()
        var mixed = message(20, count: 2)
        mixed.embedContents[0].data?.url = URL(string: "https://api.example/one.png")!
        mixed.nsfw = true
        mixed.expandEmbedContents = false
        var deleted = message(10)
        deleted.status = "deleted_by_publisher"
        XCTAssertNil(fallback.nextRequest(in: [deleted, message(1), message(15, count: 0)]))
        let request = try XCTUnwrap(fallback.nextRequest(in: [mixed]))
        XCTAssertEqual(request.channelID, "CHANNEL01")
        XCTAssertEqual(request.afterID, 19)
        XCTAssertTrue(fallback.accept([record(20, count: 2)], currentMessages: [mixed]))
        let displayed = fallback.applying(to: mixed)
        XCTAssertEqual(displayed.embedContents[0].linkURL?.absoluteString, "https://api.example/one.png")
        XCTAssertEqual(displayed.embedContents[1].linkURL?.absoluteString, "https://media.example/20-1.png")
        XCTAssertTrue(displayed.nsfw)
        XCTAssertFalse(displayed.expandEmbedContents)
        XCTAssertTrue(mixed.embedContents[1].hasUnavailableImage, "The API message must remain unmodified")
        XCTAssertNil(fallback.nextRequest(in: [mixed]))
    }

    func testCoalescesRequestsAndContinuesBeyondServerPage() throws {
        var fallback = UploadedImageFallback()
        let messages = [message(20), message(219), message(250)]
        XCTAssertEqual(fallback.nextRequest(in: messages)?.afterID, 19)
        XCTAssertNil(fallback.nextRequest(in: messages))
        let page = (20...219).map { record($0, count: $0 == 20 || $0 == 219 ? 1 : 0) }
        XCTAssertTrue(fallback.accept(page, currentMessages: messages))
        XCTAssertEqual(fallback.nextRequest(in: messages)?.afterID, 249)
        XCTAssertTrue(fallback.accept([record(250)], currentMessages: messages))
        XCTAssertNil(fallback.nextRequest(in: messages))
    }

    func testWrongChannelUnsolicitedAndUncachedMessagesAreIgnored() throws {
        var fallback = UploadedImageFallback()
        let source = message(20)
        _ = fallback.nextRequest(in: [source])
        XCTAssertFalse(fallback.accept([record(20, channel: "OTHER")], currentMessages: [source]))
        XCTAssertFalse(fallback.accept([record(21)], currentMessages: [source]))
        XCTAssertTrue(fallback.accept([record(20), record(21)], currentMessages: [source]))
        XCTAssertTrue(fallback.applying(to: message(21)).embedContents[0].hasUnavailableImage)
    }

    func testCountMismatchDoesNotShiftURLsOrLoop() {
        var fallback = UploadedImageFallback()
        let source = message(20, count: 2)
        _ = fallback.nextRequest(in: [source])
        XCTAssertTrue(fallback.accept([record(20)], currentMessages: [source]))
        XCTAssertTrue(fallback.applying(to: source).embedContents.allSatisfy(\.hasUnavailableImage))
        XCTAssertNil(fallback.nextRequest(in: [source]))
    }

    func testEditWhileRequestIsInFlightCannotApplyOldImages() {
        var fallback = UploadedImageFallback()
        let source = message(20)
        _ = fallback.nextRequest(in: [source])
        fallback.invalidate(messageID: 20)
        XCTAssertTrue(fallback.accept([record(20)], currentMessages: [source]))
        XCTAssertTrue(fallback.applying(to: source).embedContents[0].hasUnavailableImage)
        XCTAssertEqual(fallback.nextRequest(in: [source])?.afterID, 19)
    }

    func testChangedRESTMessageAndDeletionInvalidateResolution() {
        var fallback = UploadedImageFallback()
        let source = message(20)
        _ = fallback.nextRequest(in: [source])
        var edited = source
        edited.rawContent = "edited"
        XCTAssertTrue(fallback.accept([record(20)], currentMessages: [edited]))
        XCTAssertTrue(fallback.applying(to: edited).embedContents[0].hasUnavailableImage)
        _ = fallback.nextRequest(in: [edited])
        XCTAssertTrue(fallback.accept([record(20)], currentMessages: [edited]))
        XCTAssertFalse(fallback.applying(to: edited).embedContents[0].hasUnavailableImage)
        var deleted = edited
        deleted.status = "deleted_by_publisher"
        XCTAssertEqual(fallback.applying(to: deleted), deleted)
        fallback.invalidate(messageID: 20)
        XCTAssertTrue(fallback.applying(to: edited).embedContents[0].hasUnavailableImage)
    }

    func testTimeoutRejectsLateResponseUntilNextConnection() {
        var fallback = UploadedImageFallback()
        let source = message(20)
        _ = fallback.nextRequest(in: [source])
        fallback.failPendingRequest()
        XCTAssertFalse(fallback.accept([record(20)], currentMessages: [source]))
        XCTAssertNil(fallback.nextRequest(in: [source, message(21)]))
        fallback.reset()
        XCTAssertEqual(fallback.nextRequest(in: [source])?.afterID, 19)
    }

    func testBackgroundChannelResponseOnlyDecoratesItsOwnCache() {
        var fallback = UploadedImageFallback()
        let oldChannel = message(20)
        var selected = message(30)
        selected.channel.id = "CHANNEL02"
        _ = fallback.nextRequest(in: [oldChannel])
        XCTAssertNil(fallback.nextRequest(in: [selected]))
        XCTAssertTrue(fallback.accept([record(20)], currentMessages: [oldChannel]))
        XCTAssertTrue(fallback.applying(to: selected).embedContents[0].hasUnavailableImage)
        XCTAssertEqual(fallback.nextRequest(in: [selected])?.channelID, "CHANNEL02")
    }

    private func message(_ id: Int, count: Int = 1) -> Message {
        Message(id: id, embedContents: (0..<count).map { EmbedContent(position: $0, data: EmbedData(type: "UploadedImage")) },
                channel: Channel(id: "CHANNEL01", channelName: "general"), profile: Profile(id: "PROFILE01"))
    }

    private func record(_ id: Int, count: Int = 1, channel: String = "CHANNEL01") -> HotwireMessageImages {
        HotwireMessageImages(channelID: channel, messageID: id, images: (0..<count).map {
            EmbedImagePreview(id: "upload-\($0)", thumbnailURL: URL(string: "https://media.example/\(id)-\($0)-thumb.png")!,
                              linkURL: URL(string: "https://media.example/\(id)-\($0).png")!)
        })
    }
}
