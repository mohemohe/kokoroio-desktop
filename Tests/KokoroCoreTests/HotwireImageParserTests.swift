import Foundation
import XCTest
@testable import KokoroCore

final class HotwireImageParserTests: XCTestCase {
    private let baseURL = URL(string: "https://chat.example.test/chat/")!

    func testResumeExtractsOnlyUploadedImagesAndDecodesHTMLAttributeEntities() throws {
        let html = stream(message(87, attachments: image("/full.png?x=1&amp;y=2", thumbnail: "/thumb.png?x=1&#38;y=2")))
        let record = try XCTUnwrap(HotwireImageParser.parse(html, baseURL: baseURL).first)
        XCTAssertEqual(record.channelID, "CHANNEL01")
        XCTAssertEqual(record.messageID, 87)
        XCTAssertEqual(record.images.first?.linkURL.absoluteString, "https://chat.example.test/full.png?x=1&y=2")
        XCTAssertEqual(record.images.first?.thumbnailURL.absoluteString, "https://chat.example.test/thumb.png?x=1&y=2")
        XCTAssertFalse(try XCTUnwrap(record.images.first).isRestricted)
    }

    func testRelativeAndProtocolRelativeURLsResolveAgainstServer() throws {
        let html = stream(message(87, attachments: image("../full.png", thumbnail: "//cdn.example.test/thumb.png")))
        let preview = try XCTUnwrap(HotwireImageParser.parse(html, baseURL: baseURL).first?.images.first)
        XCTAssertEqual(preview.linkURL.absoluteString, "https://chat.example.test/full.png")
        XCTAssertEqual(preview.thumbnailURL.absoluteString, "https://cdn.example.test/thumb.png")
    }

    func testNSFWWrapperAndOrderArePreserved() {
        let restricted = "<div class=\"nsfw-media\">\(image("/first.png"))<svg class=\"nsfw-mark\"><path d=\"M1 2\"/></svg></div>"
        let html = stream(message(87, attachments: restricted + image("/second.png")))
        let images = HotwireImageParser.parse(html, baseURL: baseURL).first?.images ?? []
        XCTAssertEqual(images.map(\.linkURL.path), ["/first.png", "/second.png"])
        XCTAssertEqual(images.map(\.isRestricted), [true, false])
        XCTAssertEqual(Set(images.map(\.id)).count, 2)
    }

    func testImageFreeAndDeletedMessagesRemainInResumePage() {
        let html = stream(message(1, attachments: "")) + stream(message(2, attachments: image("/stale.png"), deleted: true))
            + stream(message(3, attachments: image("/valid.png")))
        let records = HotwireImageParser.parse(html, baseURL: baseURL)
        XCTAssertEqual(records.map(\.messageID), [1, 2, 3])
        XCTAssertTrue(records[0].images.isEmpty)
        XCTAssertTrue(records[1].images.isEmpty)
        XCTAssertEqual(records[2].images.count, 1)
    }

    func testAllTwoHundredResumeMessagesAreReturnedEvenWithoutAttachments() {
        let html = (1...200).map { stream(message($0, attachments: "")) }.joined()
        XCTAssertEqual(HotwireImageParser.parse(html, baseURL: baseURL).map(\.messageID), Array(1...200))
    }

    func testMixedEmbedsAndQuotedMessagesCannotContributeUploadedImages() {
        let quoted = message(999, attachments: image("/quoted.png"))
        let text = "<div class=\"filtered-text\">\(quoted)</div>"
        let mixed = "<div class=\"embed-contents\"><div class=\"embed-item\">\(quoted)</div><img src=\"/card.png\"></div>"
        let html = stream(message(87, attachments: image("/own.png"), extraContent: text + mixed))
        let records = HotwireImageParser.parse(html, baseURL: baseURL)
        XCTAssertEqual(records.map(\.messageID), [87])
        XCTAssertEqual(records.first?.images.map(\.linkURL.path), ["/own.png"])
    }

    func testLookalikeClassesAndNestedAttachmentGroupsAreIgnored() {
        let injected = "<div class=\"embed-contents\"><div><div class=\"embed-uploaded-images\">\(image("/nested.png"))</div></div></div>"
        let html = stream(message(87, attachments: "", extraContent: injected))
        XCTAssertEqual(HotwireImageParser.parse(html, baseURL: baseURL).first?.images, [])
        let lookalike = stream(message(87, attachments: image("/bad.png").replacingOccurrences(of: "embed-uploaded-image-link", with: "not-embed-uploaded-image-link")))
        XCTAssertEqual(HotwireImageParser.parse(lookalike, baseURL: baseURL).first?.images, [])
    }

    func testOneBrokenImageDiscardsWholeArrayWithoutShiftingPositions() {
        for broken in [image("/broken.png", thumbnail: ""), "<a class=\"embed-uploaded-image-link\" href=\"/broken.png\"></a>",
                       image("/broken.png").replacingOccurrences(of: "href=", with: "data-href=")] {
            let html = stream(message(87, attachments: image("/first.png") + broken + image("/last.png")))
            let records = HotwireImageParser.parse(html, baseURL: baseURL)
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records.first?.images, [])
        }
    }

    func testUnsafeURLsAreRejectedInBothLinkAndThumbnail() {
        let unsafe = ["javascript:alert(1)", "data:image/png;base64,a", "file:///tmp/image.png",
                      "ftp://example.test/image.png", "https://user:password@example.test/image.png",
                      "//user@example.test/image.png", "http://[broken", "https://user&#58;password@example.test/image.png"]
        for url in unsafe {
            for attachment in [image(url), image("/full.png", thumbnail: url)] {
                let records = HotwireImageParser.parse(stream(message(87, attachments: attachment)), baseURL: baseURL)
                XCTAssertEqual(records.first?.images, [], "Unsafe URL: \(url)")
            }
        }
    }

    func testHTMLURLWhitespaceNormalizationStillProducesOnlySafeHTTPURLs() {
        let html = stream(message(87, attachments: image(" https://example.test/image.png", thumbnail: "https://example.test/&#10;image.png")))
        let preview = HotwireImageParser.parse(html, baseURL: baseURL).first?.images.first
        XCTAssertEqual(preview?.linkURL.absoluteString, "https://example.test/image.png")
        XCTAssertEqual(preview?.thumbnailURL.absoluteString, "https://example.test/%20image.png")
    }

    func testMessageIdentityAndEnvelopeAreRequired() {
        let body = message(87, attachments: image("/own.png"))
        let invalid = [body, stream(body.replacingOccurrences(of: "data-channel-hashid", with: "data-other")),
                       stream(body.replacingOccurrences(of: "CHANNEL01", with: "")),
                       stream(body.replacingOccurrences(of: "message_87", with: "message_-87")),
                       stream(body.replacingOccurrences(of: "message_87", with: "message_087")),
                       stream(body, action: "append", target: "elsewhere"),
                       stream(body, action: "replace", target: "message_88"),
                       stream(body, action: "remove", target: "message_87")]
        for html in invalid { XCTAssertTrue(HotwireImageParser.parse(html, baseURL: baseURL).isEmpty) }
    }

    func testReplaceAndUpdateRequireMatchingFullMessage() {
        for action in ["replace", "update"] {
            let html = stream(message(87, attachments: image("/own.png")), action: action, target: "message_87")
            XCTAssertEqual(HotwireImageParser.parse(html, baseURL: baseURL).first?.images.count, 1)
        }
        let contentOnly = "<div id=\"message_87_content\"><div class=\"embed-contents\"><div class=\"embed-uploaded-images\">\(image("/unknown-channel.png"))</div></div></div>"
        XCTAssertTrue(HotwireImageParser.parse(stream(contentOnly, action: "replace", target: "message_87_content"), baseURL: baseURL).isEmpty)
    }

    func testRemoveStreamDoesNotPreventParsingOtherMessages() {
        let removal = "<turbo-stream action=\"remove\" target=\"message_86\"></turbo-stream>"
        XCTAssertEqual(HotwireImageParser.parse(removal + stream(message(87, attachments: "")), baseURL: baseURL).map(\.messageID), [87])
    }

    func testExternalEntitiesAndEntityExpansionAreRejectedBeforeParsing() {
        let declarations = [
            "<!DOCTYPE html SYSTEM \"file:///etc/passwd\">",
            "<!DOCTYPE html [<!ENTITY secret SYSTEM \"file:///etc/passwd\">]>",
            "<!DOCTYPE html [<!ENTITY a \"xxxxxxxx\"><!ENTITY b \"&a;&a;&a;&a;\">]>"
        ]
        for declaration in declarations {
            let html = stream(declaration + message(87, attachments: image("/full.png?secret=&secret;")))
            XCTAssertTrue(HotwireImageParser.parse(html, baseURL: baseURL).isEmpty)
        }
    }

    func testMalformedHTMLFailsClosedAndOrdinaryVoidImageTagWorks() {
        let valid = stream(message(87, attachments: image("/image.png")))
        XCTAssertEqual(HotwireImageParser.parse(valid, baseURL: baseURL).first?.images.count, 1)
        XCTAssertTrue(HotwireImageParser.parse(String(valid.dropLast(5)), baseURL: baseURL).isEmpty)
        XCTAssertTrue(HotwireImageParser.parse("garbage" + valid, baseURL: baseURL).isEmpty)
        let broken = stream(message(87, attachments: "<a class=\"embed-uploaded-image-link\" href=\"/first.png\"><img class=\"embed-uploaded-image\" src=\"/first.png\">" + image("/last.png")))
        // HTML's implicit anchor closing is safe when each recovered item retains its URL pair.
        XCTAssertEqual(HotwireImageParser.parse(broken, baseURL: baseURL).first?.images.map(\.linkURL.path), ["/first.png", "/last.png"])
    }

    func testOversizedInputAndExcessiveStreamCountAreRejected() {
        XCTAssertTrue(HotwireImageParser.parse(String(repeating: " ", count: 4 * 1_024 * 1_024 + 1), baseURL: baseURL).isEmpty)
        let html = (1...257).map { stream(message($0, attachments: "")) }.joined()
        XCTAssertTrue(HotwireImageParser.parse(html, baseURL: baseURL).isEmpty)
    }

    private func stream(_ content: String, action: String = "append", target: String = "messages") -> String {
        "<turbo-stream action=\"\(action)\" target=\"\(target)\"><template>\(content)</template></turbo-stream>"
    }

    private func message(_ id: Int, attachments: String, deleted: Bool = false, extraContent: String = "") -> String {
        """
        <div class="talk not-continued \(deleted ? "message--deleted" : "")" id="message_\(id)" data-channel-hashid="CHANNEL01">
          <div class="avatar"><img src="/avatar.png"></div>
          <div class="message"><div class="speaker">Alice</div><div>
            <div id="message_\(id)_content" data-controller="message-link">
              <div class="filtered-text">Hello</div>
              <div class="embed-contents"><div class="embed-uploaded-images">\(attachments)</div></div>
              \(extraContent)
            </div>
          </div></div>
        </div>
        """
    }

    private func image(_ full: String, thumbnail: String? = nil) -> String {
        "<a class=\"embed-uploaded-image-link\" href=\"\(full)\"><img class=\"embed-uploaded-image\" src=\"\(thumbnail ?? full)\"></a>"
    }
}
