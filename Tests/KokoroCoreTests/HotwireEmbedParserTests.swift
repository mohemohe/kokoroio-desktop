import Foundation
import XCTest
@testable import KokoroCore

final class HotwireEmbedParserTests: XCTestCase {
    private let baseURL = URL(string: "https://chat.example.test/chat/")!
    private let tweetURL = "https://x.com/kiwicopple/status/2106047481851326869"
    private let sampleDescription = """
    @supabase has acquired @tursodatabase\u{20}

    i'm been a huge fan of the team and what they've built. we have big plans together. more to share in our keynote in a few hours

    this is the tweet that convinced us they'll fit right in

    https://t.co/fwDsA2WLkd
    """

    func testSuppliedMixedContentExtractsServerTitleBodyAndAuthorThumbnail() throws {
        let html = stream(content(828076, embeds: sampleCard), action: "replace", target: "message_828076_content")
        let record = try XCTUnwrap(HotwireEmbedParser.parse(html, baseURL: baseURL).first)
        XCTAssertNil(record.channelID)
        XCTAssertEqual(record.messageID, 828076)
        let card = try XCTUnwrap(record.cards.first)
        XCTAssertEqual(card.url.absoluteString, tweetURL)
        XCTAssertEqual(card.title, "Paul Copplestone - e/postgres (@kiwicopple)")
        XCTAssertEqual(card.description, sampleDescription)
        XCTAssertEqual(card.thumbnailURL?.absoluteString,
                       "https://pbs.twimg.com/profile_images/1664343166630109202/xcBMGPSE_normal.jpg")
        XCTAssertTrue(card.thumbnailIsAuthor)
        XCTAssertFalse(card.isRestricted)
    }

    func testInitialAppendAndLaterContentReplacementRemainSeparateRecords() {
        let html = stream(message(828076, embeds: ""))
            + stream(content(828076, embeds: sampleCard), action: "replace", target: "message_828076_content")
        let records = HotwireEmbedParser.parse(html, baseURL: baseURL)
        XCTAssertEqual(records.map(\.messageID), [828076, 828076])
        XCTAssertEqual(records.map(\.channelID), ["CHANNEL01", nil])
        XCTAssertEqual(records.map { $0.cards.count }, [0, 1])
    }

    func testChatChannelProjectedMetadataUsesExactServerResumeCard() throws {
        let authorThumbnail = "https://pbs.twimg.com/profile_images/1664343166630109202/xcBMGPSE_normal.jpg"
        let serverTitle = "Paul Copplestone - e/postgres (@kiwicopple)"
        let messageJSON: [String: Any] = [
            "id": 828076, "raw_content": tweetURL, "published_at": "2026-10-02T21:03:39Z",
            "expand_embed_contents": true, "embedded_urls": [tweetURL],
            "embed_contents": [["url": tweetURL, "position": 0, "data": [
                "type": "MixedContent", "url": tweetURL, "title": serverTitle,
                "metadata_image": ["type": "Image", "raw_url": authorThumbnail], "medias": []]]],
            "channel": ["id": "CHANNEL01", "channel_name": "general"],
            "profile": ["id": "PROFILE01", "display_name": "mohemohe"]
        ]
        let wire: [String: Any] = ["identifier": ActionCableProtocol.identifier,
                                  "message": ["event": "message_updated", "data": messageJSON]]
        let frame = try ActionCableProtocol.parse(JSONSerialization.data(withJSONObject: wire))
        guard case .event(let event) = frame else { return XCTFail("Expected ChatChannel message_updated") }
        XCTAssertEqual(event.name, "message_updated")
        let source = try APIJSON.decoder().decode(Message.self, from: event.payload)
        XCTAssertNil(source.embedContents.first?.cardDescription)
        XCTAssertFalse(try XCTUnwrap(source.embedContents.first).cardThumbnailIsAuthor)

        var fallback = MessageEmbedFallback()
        let request = try XCTUnwrap(fallback.nextRequest(in: [source]))
        XCTAssertEqual(request.channelID, "CHANNEL01")
        XCTAssertEqual(request.afterID, 828075)
        let resumeRecords = HotwireEmbedParser.parse(stream(message(828076, embeds: sampleCard)), baseURL: baseURL)
        XCTAssertTrue(fallback.accept([], linkRecords: resumeRecords, currentMessages: [source]))
        let finalCard = try XCTUnwrap(fallback.applying(to: source).embedContents.first)
        XCTAssertEqual(finalCard.cardTitle, serverTitle)
        XCTAssertEqual(finalCard.cardDescription, sampleDescription)
        XCTAssertEqual(finalCard.cardThumbnailURL?.absoluteString, authorThumbnail)
        XCTAssertTrue(finalCard.cardThumbnailIsAuthor)
        XCTAssertEqual(finalCard.linkURL?.absoluteString, tweetURL)
        XCTAssertNil(source.embedContents.first?.cardDescription)
    }

    func testTitleAndDescriptionEntitiesDecodeWithoutLosingNewlines() throws {
        let cardHTML = card("/article?one=1&amp;two=2", title: "Alice &amp; Bob &#39;News&#39;",
                            description: "first &lt;line&gt;\n\nsecond &#x1F600; &quot;line&quot;",
                            thumbnail: "/thumb.png?one=1&#38;two=2")
        let preview = try XCTUnwrap(HotwireEmbedParser.parse(stream(message(1, embeds: cardHTML)), baseURL: baseURL).first?.cards.first)
        XCTAssertEqual(preview.url.absoluteString, "https://chat.example.test/article?one=1&two=2")
        XCTAssertEqual(preview.thumbnailURL?.absoluteString, "https://chat.example.test/thumb.png?one=1&two=2")
        XCTAssertEqual(preview.title, "Alice & Bob 'News'")
        XCTAssertEqual(preview.description, "first <line>\n\nsecond 😀 \"line\"")
    }

    func testServerTextPreservesLeadingTrailingWhitespaceAndLiteralEntityText() throws {
        let text = " \nfirst\t\tline\r\n\nsecond &amp;#10; &amp;lt;tag&amp;gt; \n "
        let preview = try XCTUnwrap(HotwireEmbedParser.parse(stream(message(1, embeds: card("/article", description: text))), baseURL: baseURL).first?.cards.first)
        XCTAssertEqual(preview.description, " \nfirst\t\tline\r\n\nsecond &#10; &lt;tag&gt; \n ")
    }

    func testRelativeAndProtocolRelativeURLsResolveAgainstServer() throws {
        let cardHTML = card("../article", thumbnail: "//cdn.example.test/thumb.png")
        let preview = try XCTUnwrap(HotwireEmbedParser.parse(stream(message(1, embeds: cardHTML)), baseURL: baseURL).first?.cards.first)
        XCTAssertEqual(preview.url.absoluteString, "https://chat.example.test/article")
        XCTAssertEqual(preview.thumbnailURL?.absoluteString, "https://cdn.example.test/thumb.png")
    }

    func testMissingTitleCanUseThumbnailLinkAndMissingThumbnailKeepsServerText() throws {
        let withoutTitle = card("/article", title: nil, description: "Body")
        let first = try XCTUnwrap(HotwireEmbedParser.parse(stream(message(1, embeds: withoutTitle)), baseURL: baseURL).first?.cards.first)
        XCTAssertEqual(first.url.path, "/article")
        XCTAssertNil(first.title)
        XCTAssertEqual(first.description, "Body")
        let withoutThumbnail = card("/article", title: "Title", description: "Body", thumbnail: nil)
        let second = try XCTUnwrap(HotwireEmbedParser.parse(stream(message(1, embeds: withoutThumbnail)), baseURL: baseURL).first?.cards.first)
        XCTAssertEqual(second.title, "Title")
        XCTAssertEqual(second.description, "Body")
        XCTAssertNil(second.thumbnailURL)
        XCTAssertFalse(second.thumbnailIsAuthor)
    }

    func testNSFWMetadataAndMediaWrappersRestrictTheCard() throws {
        let first = card("/article", restricted: true)
        let second = String(card("/article").dropLast("</div>".count))
            + "<div class=\"embed-mixed-medias\"><div class=\"embed-media-item\"><div class=\"embed-thumbnail nsfw-media\"><img src=\"/media.png\"></div></div></div></div>"
        for html in [first, second] {
            let preview = try XCTUnwrap(HotwireEmbedParser.parse(stream(message(1, embeds: html)), baseURL: baseURL).first?.cards.first)
            XCTAssertTrue(preview.isRestricted)
        }
    }

    func testEmptyAndDeletedFullMessagesStillCountTowardResumePage() {
        let html = stream(message(1, embeds: ""))
            + stream(message(2, embeds: sampleCard, deleted: true))
            + stream(message(3, embeds: sampleCard))
        let records = HotwireEmbedParser.parse(html, baseURL: baseURL)
        XCTAssertEqual(records.map(\.messageID), [1, 2, 3])
        XCTAssertEqual(records.map { $0.cards.count }, [0, 0, 1])
        let deletedContent = content(3, embeds: sampleCard).replacingOccurrences(of: "<div class=\"filtered-text\">", with: "<div class=\"deleted-text\">")
        XCTAssertEqual(HotwireEmbedParser.parse(stream(deletedContent, action: "replace", target: "message_3_content"), baseURL: baseURL).first?.cards, [])
    }

    func testAllTwoHundredResumeMessagesAreReturnedEvenWithoutCards() {
        let html = (1...200).map { stream(message($0, embeds: "")) }.joined()
        XCTAssertEqual(HotwireEmbedParser.parse(html, baseURL: baseURL).map(\.messageID), Array(1...200))
    }

    func testQuotedMessagesAndNestedMixedCardsCannotContributeMetadata() {
        let quote = message(999, embeds: card("/quoted", title: "Quoted"), channelID: "OTHERCHANNEL")
        let nested = "<div class=\"embed-contents\"><div class=\"embed-item\">\(quote)</div><div>\(sampleCard)</div></div>"
        let html = stream(message(1, embeds: card("/own", title: "Own"), extraContent: "<div class=\"filtered-text\">\(quote)</div>" + nested))
        let records = HotwireEmbedParser.parse(html, baseURL: baseURL)
        XCTAssertEqual(records.map(\.messageID), [1])
        XCTAssertEqual(records.map(\.channelID), ["CHANNEL01"])
        XCTAssertEqual(records.first?.cards.map(\.title), ["Own"])
        XCTAssertEqual(records.first?.cards.map(\.url.path), ["/own"])
    }

    func testExactClassNamesAndDirectMetadataPathAreRequired() {
        let invalid = [
            sampleCard.replacingOccurrences(of: "embed-mixedcontent", with: "not-embed-mixedcontent"),
            sampleCard.replacingOccurrences(of: "embed-mixed-info", with: "not-embed-mixed-info"),
            "<div>\(sampleCard)</div>",
            sampleCard.replacingOccurrences(of: "<div class=\"embed-mixed-meta\">", with: "<div><div class=\"embed-mixed-meta\">") + "</div>"
        ]
        for html in invalid {
            XCTAssertEqual(HotwireEmbedParser.parse(stream(message(1, embeds: html)), baseURL: baseURL).first?.cards, [])
        }
    }

    func testFullMessagesRequireExactMessageChannelIdentityAndStreamTarget() {
        let full = message(87, embeds: sampleCard)
        let invalid = [
            full,
            stream(full.replacingOccurrences(of: "data-channel-hashid", with: "data-other-channel")),
            stream(full.replacingOccurrences(of: "CHANNEL01", with: "")),
            stream(full.replacingOccurrences(of: "CHANNEL01", with: "bad channel")),
            stream(full.replacingOccurrences(of: "message_87", with: "message_087")),
            stream(full.replacingOccurrences(of: "message_87", with: "message_-87")),
            stream(full, target: "message_87_content"),
            stream(full, target: "elsewhere"),
            stream(full, action: "replace", target: "message_88"),
            stream(full, action: "remove", target: "message_87")
        ]
        for html in invalid { XCTAssertTrue(HotwireEmbedParser.parse(html, baseURL: baseURL).isEmpty) }
        let otherChannel = HotwireEmbedParser.parse(stream(message(87, embeds: sampleCard, channelID: "OTHERCHANNEL")), baseURL: baseURL)
        // Preserve the exact full-message channel for the caller's subscription/channel check.
        XCTAssertEqual(otherChannel.first?.channelID, "OTHERCHANNEL")
    }

    func testReplaceAndUpdateSupportFullMessageAndExactContentRoot() {
        for action in ["replace", "update"] {
            let full = stream(message(87, embeds: sampleCard), action: action, target: "message_87")
            XCTAssertEqual(HotwireEmbedParser.parse(full, baseURL: baseURL).first?.channelID, "CHANNEL01")
            let replacement = stream(content(87, embeds: sampleCard), action: action, target: "message_87_content")
            XCTAssertEqual(HotwireEmbedParser.parse(replacement, baseURL: baseURL).first?.cards.count, 1)
            XCTAssertNil(HotwireEmbedParser.parse(replacement, baseURL: baseURL).first?.channelID)
            let wrong = [
                stream(content(88, embeds: sampleCard), action: action, target: "message_87_content"),
                stream(content(87, embeds: sampleCard), action: action, target: "message_087_content"),
                stream("<div>\(content(87, embeds: sampleCard))</div>", action: action, target: "message_87_content"),
                stream(content(87, embeds: sampleCard) + "<div></div>", action: action, target: "message_87_content"),
                stream(content(87, embeds: sampleCard) + "<div ></div>", action: action, target: "message_87_content"),
                stream(content(87, embeds: sampleCard) + "<span></span>", action: action, target: "message_87_content"),
                stream(content(87, embeds: sampleCard) + "<p></p>", action: action, target: "message_87_content"),
                stream(content(87, embeds: sampleCard) + "unexpected text", action: action, target: "message_87_content")
            ]
            for html in wrong { XCTAssertTrue(HotwireEmbedParser.parse(html, baseURL: baseURL).isEmpty) }
        }
        XCTAssertTrue(HotwireEmbedParser.parse(stream(content(87, embeds: sampleCard), action: "append", target: "message_87_content"), baseURL: baseURL).isEmpty)
    }

    func testUnsafeRequiredURLsAreRejectedAndUnsafeOptionalThumbnailsAreOmitted() {
        let unsafe = ["javascript:alert(1)", "data:image/png;base64,a", "file:///tmp/image.png",
                      "ftp://example.test/image.png", "https://user:password@example.test/image.png",
                      "//user@example.test/image.png", "http://[broken", "https://user&#58;password@example.test/image.png"]
        for value in unsafe {
            XCTAssertEqual(HotwireEmbedParser.parse(stream(message(1, embeds: card(value))), baseURL: baseURL).first?.cards, [], value)
            let safeCard = HotwireEmbedParser.parse(stream(message(1, embeds: card("/article", thumbnail: value))), baseURL: baseURL).first?.cards.first
            XCTAssertEqual(safeCard?.url.path, "/article")
            XCTAssertNil(safeCard?.thumbnailURL, value)
        }
    }

    func testExternalEntityDeclarationsAndMalformedEnvelopesAreRejected() {
        let declarations = ["<!DOCTYPE html SYSTEM \"file:///etc/passwd\">",
                            "<!DOCTYPE html [<!ENTITY secret SYSTEM \"file:///etc/passwd\">]>",
                            "<!doctype html [<!entity a \"xxxxxxxx\"><!entity b \"&a;&a;\">]>"]
        for declaration in declarations {
            XCTAssertTrue(HotwireEmbedParser.parse(stream(declaration + message(1, embeds: sampleCard)), baseURL: baseURL).isEmpty)
        }
        let valid = stream(message(1, embeds: sampleCard))
        XCTAssertTrue(HotwireEmbedParser.parse(String(valid.dropLast(5)), baseURL: baseURL).isEmpty)
        XCTAssertTrue(HotwireEmbedParser.parse("garbage" + valid, baseURL: baseURL).isEmpty)
        let removal = "<turbo-stream action=\"remove\" target=\"message_0\"></turbo-stream>"
        XCTAssertEqual(HotwireEmbedParser.parse(removal + valid, baseURL: baseURL).first?.cards.count, 1)
    }

    func testOversizedInputAndExcessiveStreamAndCardCountsAreBounded() {
        XCTAssertTrue(HotwireEmbedParser.parse(String(repeating: " ", count: 4 * 1_024 * 1_024 + 1), baseURL: baseURL).isEmpty)
        let html = (1...257).map { stream(message($0, embeds: "")) }.joined()
        XCTAssertTrue(HotwireEmbedParser.parse(html, baseURL: baseURL).isEmpty)
        let tooManyCards = String(repeating: sampleCard, count: 101)
        XCTAssertEqual(HotwireEmbedParser.parse(stream(message(1, embeds: tooManyCards)), baseURL: baseURL).first?.cards, [])
    }

    private var sampleCard: String {
        """
        <div class="embed-mixedcontent">
          <div class="embed-mixed-meta">
            <div class="embed-mixed-thumb">
              <div class="embed-thumbnail ">
                <a href="\(tweetURL)" || embed.url rel="noopener">
                  <img class="meta-thumb-author" src="https://pbs.twimg.com/profile_images/1664343166630109202/xcBMGPSE_normal.jpg">
                </a>
              </div>
            </div>
            <div class="embed-mixed-info">
              <div class="embed-mixed-title"><a href="\(tweetURL)" || embed.url rel="noopener"><strong>Paul Copplestone - e/postgres (@kiwicopple)</strong></a></div>
              <div class="embed-mixed-desc"><p>\(sampleDescription.replacingOccurrences(of: "'", with: "&#39;"))</p></div>
            </div>
          </div>
        </div>
        """
    }

    private func stream(_ body: String, action: String = "append", target: String = "messages") -> String {
        "<turbo-stream action=\"\(action)\" target=\"\(target)\"><template>\(body)</template></turbo-stream>"
    }

    private func message(_ id: Int, embeds: String, deleted: Bool = false, channelID: String = "CHANNEL01", extraContent: String = "") -> String {
        "<div class=\"talk continued \(deleted ? "message--deleted" : "")\" id=\"message_\(id)\" data-channel-hashid=\"\(channelID)\"><div class=\"avatar\"></div><div class=\"message\"><div class=\"speaker\">Alice</div><div>\(content(id, embeds: embeds, extraContent: extraContent))</div></div></div>"
    }

    private func content(_ id: Int, embeds: String, extraContent: String = "") -> String {
        "<div id=\"message_\(id)_content\" data-controller=\"message-link\"><div class=\"filtered-text\"><p>Link</p></div><div class=\"embed-contents\">\(embeds)</div>\(extraContent)</div>"
    }

    private func card(_ url: String, title: String? = "Title", description: String? = "Body",
                      thumbnail: String? = "/thumb.png", restricted: Bool = false) -> String {
        let titleHTML = title.map { "<div class=\"embed-mixed-title\"><a href=\"\(url)\"><strong>\($0)</strong></a></div>" } ?? ""
        let descriptionHTML = description.map { "<div class=\"embed-mixed-desc\"><p>\($0)</p></div>" } ?? ""
        let thumbnailHTML = thumbnail.map { "<div class=\"embed-mixed-thumb\"><div class=\"embed-thumbnail \(restricted ? "nsfw-media" : "")\"><a href=\"\(url)\"><img class=\"meta-thumb-page\" src=\"\($0)\"></a>\(restricted ? "<svg class=\"nsfw-mark\"></svg>" : "")</div></div>" } ?? ""
        return "<div class=\"embed-mixedcontent\"><div class=\"embed-mixed-meta\">\(thumbnailHTML)<div class=\"embed-mixed-info\">\(titleHTML)\(descriptionHTML)</div></div></div>"
    }
}
