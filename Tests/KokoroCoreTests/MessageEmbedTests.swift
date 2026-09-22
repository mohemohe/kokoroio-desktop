import Foundation
import XCTest
@testable import KokoroCore

final class MessageEmbedTests: XCTestCase {
    func testRESTMessageDecodesResolvedImagesAndLinkMetadata() throws {
        let payload = messageJSON(embeds: [
            ["url": "https://images.example.test/original.png", "position": 0, "data": [
                "type": "SingleImage", "cache_age": 3600,
                "medias": [["type": "Image", "raw_url": "https://images.example.test/original.png",
                            "thumbnail": ["url": "https://images.example.test/thumb.png", "width": 330, "height": 220]]]]],
            ["url": "https://github.com/example/project", "position": 1, "data": [
                "type": "MixedContent", "url": "https://github.com/example/project", "title": "GitHub project",
                "description": "Project description", "provider_name": "GitHub", "medias": [],
                "metadata_image": ["type": "Image", "raw_url": "https://images.example.test/og.png",
                                   "thumbnail": ["url": "https://images.example.test/og-thumb.png"]]]]
        ])
        let messages = try APIJSON.decoder().decode([Message].self, from: JSONSerialization.data(withJSONObject: [payload]))
        let message = try XCTUnwrap(messages.first)
        XCTAssertTrue(message.expandEmbedContents)
        XCTAssertEqual(message.embeddedURLs.map(\.absoluteString), ["https://github.com/example/project"])
        XCTAssertEqual(message.embedContents.map(\.position), [0, 1])
        let image = try XCTUnwrap(message.embedContents.first?.imagePreviews.first)
        XCTAssertEqual(image.thumbnailURL.absoluteString, "https://images.example.test/thumb.png")
        XCTAssertEqual(image.linkURL.absoluteString, "https://images.example.test/original.png")
        XCTAssertTrue(message.embedContents[0].isImageOnly)
        XCTAssertFalse(message.embedContents[1].isImageOnly)
        XCTAssertEqual(message.embedContents[1].cardTitle, "GitHub project")
        XCTAssertEqual(message.embedContents[1].cardDescription, "Project description")
        XCTAssertEqual(message.embedContents[1].cardThumbnailURL?.absoluteString, "https://images.example.test/og-thumb.png")
    }

    func testRealtimeMessageUpdatedDecodesResolutionAddedAfterCreation() throws {
        let payload = messageJSON(embeds: [["url": "https://example.test/article", "position": 0,
                                           "data": ["type": "MixedContent", "title": "Resolved later", "medias": []]]])
        let wire: [String: Any] = ["identifier": ActionCableProtocol.identifier,
                                  "message": ["event": "message_updated", "data": payload]]
        let frame = try ActionCableProtocol.parse(JSONSerialization.data(withJSONObject: wire))
        guard case .event(let event) = frame else { return XCTFail("Expected message_updated event") }
        let message = try APIJSON.decoder().decode(Message.self, from: event.payload)
        XCTAssertEqual(event.name, "message_updated")
        XCTAssertEqual(message.id, 87)
        XCTAssertEqual(message.embedContents.first?.cardTitle, "Resolved later")
        XCTAssertEqual(message.embedContents.first?.linkURL?.absoluteString, "https://example.test/article")
    }

    func testOldMessagesWithoutEmbedFieldsRemainDecodable() throws {
        var payload = messageJSON(embeds: [])
        for key in ["expand_embed_contents", "embedded_urls", "embed_contents"] { payload.removeValue(forKey: key) }
        let message = try decodeMessage(payload)
        XCTAssertTrue(message.expandEmbedContents)
        XCTAssertTrue(message.embeddedURLs.isEmpty)
        XCTAssertTrue(message.embedContents.isEmpty)
    }

    func testMalformedOptionalMetadataDoesNotDiscardMessageOrOtherEmbeds() throws {
        let payload = messageJSON(embeds: [
            NSNull(), "bad embed",
            ["url": "https://example.test/article", "position": "bad position", "data": [
                "type": "MixedContent", "title": ["bad": "title"], "description": "Still useful", "metadata_image": false,
                "medias": [NSNull(), 4, ["type": "Image", "raw_url": "https://images.example.test/valid.png",
                                       "thumbnail": ["url": "http://[broken", "width": "unknown"]]]]],
            ["url": "https://example.test/second", "position": 1, "data": "bad data"]
        ])
        let message = try decodeMessage(payload)
        XCTAssertEqual(message.text, "Hello")
        XCTAssertEqual(message.embedContents.count, 2)
        XCTAssertEqual(message.embedContents[0].cardTitle, "example.test")
        XCTAssertEqual(message.embedContents[0].cardDescription, "Still useful")
        XCTAssertEqual(message.embedContents[0].imagePreviews.first?.thumbnailURL.absoluteString, "https://images.example.test/valid.png")
        XCTAssertEqual(message.embedContents[1].linkURL?.absoluteString, "https://example.test/second")
        XCTAssertNil(message.embedContents[1].data)
    }

    func testOnlyHTTPMediaAndLinkURLsAreExposed() throws {
        let payload = messageJSON(embeds: [
            ["url": "https://example.test/safe", "data": ["type": "MixedContent", "url": "javascript:alert(1)",
                                                         "metadata_image": ["raw_url": "file:///tmp/secret.png"],
                                                         "medias": [["type": "Image", "raw_url": "data:image/png;base64,secret"]]]],
            ["url": "https://user:password@example.test/secret", "data": ["type": "photo", "url": "/relative.png"]]
        ])
        let embeds = try decodeMessage(payload).embedContents
        XCTAssertEqual(embeds[0].linkURL?.absoluteString, "https://example.test/safe")
        XCTAssertNil(embeds[0].cardThumbnailURL)
        XCTAssertTrue(embeds[0].imagePreviews.isEmpty)
        XCTAssertNil(embeds[1].linkURL)
        XCTAssertTrue(embeds[1].imagePreviews.isEmpty)
    }

    func testUploadedImagesWithAndWithoutURLsPreserveExpansionPreference() throws {
        var payload = messageJSON(embeds: [
            ["url": NSNull(), "position": 0, "data": ["type": "UploadedImage", "content_type": "image/png"]],
            ["url": NSNull(), "position": 1, "data": ["type": "UploadedImage", "url": "https://images.example.test/full.png",
                                                       "thumbnail_url": "https://images.example.test/thumb.png"]]
        ])
        payload["expand_embed_contents"] = false
        let message = try decodeMessage(payload)
        XCTAssertFalse(message.expandEmbedContents)
        XCTAssertTrue(message.embedContents.allSatisfy(\.isUploadedImage))
        XCTAssertTrue(message.embedContents[0].hasUnavailableImage)
        XCTAssertFalse(message.embedContents[1].hasUnavailableImage)
        XCTAssertEqual(message.embedContents[1].imagePreviews.first?.linkURL.absoluteString, "https://images.example.test/full.png")
    }

    func testDirectPhotoURLAndVideoThumbnailFallback() throws {
        let embeds = try decodeMessage(messageJSON(embeds: [
            ["url": "https://images.example.test/photo.png", "data": ["type": "photo"]],
            ["url": "https://example.test/watch", "data": ["type": "SingleVideo", "medias": [
                ["type": "Video", "raw_url": "https://videos.example.test/video.mp4", "restriction_policy": "Restricted",
                 "thumbnail": ["url": "https://images.example.test/poster.png"]]]]],
            ["url": "https://example.test/watch2", "data": ["type": "SingleVideo", "medias": [
                ["type": "Video", "raw_url": "https://videos.example.test/video2.mp4"]]]]
        ])).embedContents
        XCTAssertEqual(embeds[0].imagePreviews.first?.thumbnailURL.absoluteString, "https://images.example.test/photo.png")
        let video = try XCTUnwrap(embeds[1].imagePreviews.first)
        XCTAssertTrue(video.isVideo)
        XCTAssertTrue(video.isRestricted)
        XCTAssertEqual(video.linkURL.absoluteString, "https://videos.example.test/video.mp4")
        XCTAssertTrue(embeds[2].imagePreviews.isEmpty, "A video file must not be sent to an image loader")
        XCTAssertEqual(embeds[2].linkURL?.absoluteString, "https://example.test/watch2")
    }

    func testUnavailableInternalReferencesDoNotExposeStalePreviewContent() throws {
        let payload = messageJSON(embeds: [
            ["url": "https://chat.example.test/messages/MESSAGE01", "data": [
                "type": "KokoroMessage", "available": false, "title": "Stale title", "description": "Stale description",
                "images": [["url": "https://images.example.test/stale.png"]]]],
            ["url": "https://chat.example.test/channels/CHANNEL01", "data": [
                "type": "KokoroChannel", "available": true, "channel": ["name": "general", "description": "A public channel"]]]
        ])
        let embeds = try decodeMessage(payload).embedContents
        XCTAssertEqual(embeds[0].cardTitle, "参照先を表示できません")
        XCTAssertNil(embeds[0].cardDescription)
        XCTAssertNil(embeds[0].cardThumbnailURL)
        XCTAssertTrue(embeds[0].imagePreviews.isEmpty)
        XCTAssertEqual(embeds[1].cardTitle, "#general")
        XCTAssertEqual(embeds[1].cardDescription, "A public channel")
    }

    func testEmbedDataSurvivesCodableRoundTrip() throws {
        let message = try decodeMessage(messageJSON(embeds: [["url": "https://example.test/article", "data": [
            "type": "MixedContent", "title": "Article", "description": "Summary", "restriction_policy": "Restricted",
            "metadata_image": ["type": "Image", "raw_url": "https://images.example.test/og.png"]]]]))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoded = try APIJSON.decoder().decode(Message.self, from: encoder.encode(message))
        XCTAssertEqual(decoded, message)
        XCTAssertTrue(decoded.embedContents[0].isRestricted)
    }

    func testPositionsSortStablyAndInternalHTMLBecomesPlainPreviewText() throws {
        let message = try decodeMessage(messageJSON(embeds: [
            ["position": 3, "url": "https://example.test/last", "data": ["title": "Last"]],
            ["position": 0, "url": "https://example.test/first", "data": ["type": "KokoroMessage", "available": true,
                "html_content": "<p>Hello &amp; <strong>world</strong>&#33;</p><script>danger()</script><p>&lt;tag&gt; &#x1F600;</p>"]],
            ["position": 3, "url": "https://example.test/tie", "data": ["title": "Tie"]]
        ]))
        XCTAssertEqual(message.embedContents.map { $0.linkURL?.path }, ["/first", "/last", "/tie"])
        XCTAssertEqual(message.embedContents[0].cardDescription, "Hello & world!\n<tag> 😀")
    }

    func testRestrictionOnMetadataImageAppliesToCard() throws {
        let message = try decodeMessage(messageJSON(embeds: [["url": "https://example.test/page", "data": [
            "type": "MixedContent", "metadata_image": ["type": "Image", "raw_url": "https://images.example.test/restricted.png",
                                                        "restriction_policy": "Restricted"]]]]))
        XCTAssertTrue(message.embedContents[0].isRestricted)
    }

    private func decodeMessage(_ payload: [String: Any]) throws -> Message {
        try APIJSON.decoder().decode(Message.self, from: JSONSerialization.data(withJSONObject: payload))
    }

    private func messageJSON(embeds: [Any]) -> [String: Any] {
        ["id": 87, "raw_content": "Hello", "published_at": "2026-09-22T10:05:00+09:00",
         "expand_embed_contents": true, "embedded_urls": ["https://github.com/example/project"], "embed_contents": embeds,
         "channel": ["id": "CHANNEL01", "channel_name": "general"], "profile": ["id": "PROFILE01"]]
    }
}
