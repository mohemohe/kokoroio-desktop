import Foundation
import XCTest
@testable import KokoroCore

final class RealtimeTests: XCTestCase {
    func testSubscriptionUsesActionCableIdentifierAndNestedActionJSON() throws {
        let subscription = try decode(ActionCableProtocol.subscribeFrame())
        XCTAssertEqual(subscription["command"] as? String, "subscribe")
        XCTAssertEqual(subscription["identifier"] as? String, #"{"channel":"ChatChannel"}"#)

        let frame = try decode(ActionCableProtocol.channelsFrame(["XYZ123ABC", "ABC123XYZ", "XYZ123ABC"]))
        XCTAssertEqual(frame["command"] as? String, "message")
        XCTAssertEqual(frame["identifier"] as? String, ActionCableProtocol.identifier)
        let action = try decode(XCTUnwrap(frame["data"] as? String))
        XCTAssertEqual(action["action"] as? String, "subscribe")
        XCTAssertEqual(action["channels"] as? [String], ["ABC123XYZ", "XYZ123ABC"])
    }

    func testReplacingSubscriptionsClearsExistingStreamsAndEmptyListStillSubscribesUserStream() throws {
        let clear = try decode(ActionCableProtocol.clearChannelsFrame())
        let action = try decode(XCTUnwrap(clear["data"] as? String))
        XCTAssertEqual(action["action"] as? String, "unsubscribe")
        let empty = try decode(ActionCableProtocol.channelsFrame([]))
        let emptyAction = try decode(XCTUnwrap(empty["data"] as? String))
        XCTAssertEqual(emptyAction["channels"] as? [String], [])
    }

    func testResumeUsesExistingChatChannelWithBoundedCatchUpCursor() throws {
        let frame = try decode(ActionCableProtocol.resumeFrame(channelID: "AbC123xyz", afterID: 424))
        XCTAssertEqual(frame["command"] as? String, "message")
        XCTAssertEqual(frame["identifier"] as? String, ActionCableProtocol.identifier)
        let action = try decode(XCTUnwrap(frame["data"] as? String))
        XCTAssertEqual(action["action"] as? String, "resume")
        XCTAssertEqual(action["channel_hashid"] as? String, "AbC123xyz")
        XCTAssertEqual(action["after_id"] as? Int, 424)
    }

    func testResumeRejectsInvalidChannelAndNonpositiveCursor() throws {
        for channelID in ["", "ABC/123", "ABC 123", "ABC\n123", "チャンネル", "ＡＢＣ123"] {
            XCTAssertThrowsError(try ActionCableProtocol.resumeFrame(channelID: channelID, afterID: 1)) {
                XCTAssertEqual($0 as? RealtimeResumeError, .invalidChannelID)
            }
        }
        for afterID in [0, -1, Int.min] {
            XCTAssertThrowsError(try ActionCableProtocol.resumeFrame(channelID: "ABC123", afterID: afterID)) {
                XCTAssertEqual($0 as? RealtimeResumeError, .invalidAfterID)
            }
        }
    }

    func testParsesServerControlFrames() throws {
        XCTAssertEqual(try parse(["type": "welcome"]), .welcome)
        XCTAssertEqual(try parse(["type": "ping", "message": 1_799_999_999]), .ping)
        XCTAssertEqual(try parse(["type": "confirm_subscription", "identifier": ActionCableProtocol.identifier]), .confirmed)
        XCTAssertEqual(try parse(["type": "reject_subscription", "identifier": ActionCableProtocol.identifier]), .rejected)
        XCTAssertEqual(try parse(["type": "disconnect", "reason": "unauthorized", "reconnect": false]), .disconnected(reason: "unauthorized", reconnect: false))
    }

    func testMessagePayloadPreservesNumericIDsAndNestedData() throws {
        let payload: [String: Any] = ["id": 425, "raw_content": "こんにちは <@123ABC456|alice>", "channel": ["id": "CHAN123AB"]]
        let frame = try parse(["identifier": ActionCableProtocol.identifier, "message": ["event": "message_created", "data": payload]])
        guard case .event(let event) = frame else { return XCTFail("Expected a message event") }
        XCTAssertEqual(event.name, "message_created")
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: event.payload) as? [String: Any])
        XCTAssertEqual(decoded["id"] as? Int, 425)
        XCTAssertEqual(decoded["raw_content"] as? String, payload["raw_content"] as? String)
        XCTAssertEqual((decoded["channel"] as? [String: String])?["id"], "CHAN123AB")
    }

    func testChannelsArrayAndUnknownEventsRemainAvailableToStore() throws {
        let frame = try parse(["identifier": ActionCableProtocol.identifier, "message": ["event": "channels_updated", "data": [["id": "ABC"]]]])
        guard case .event(let event) = frame else { return XCTFail("Expected channels event") }
        XCTAssertEqual(event.name, "channels_updated")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: event.payload) as? [[String: String]], [["id": "ABC"]])
        XCTAssertEqual(try parse(["identifier": "other", "message": ["event": "message_created", "data": [:]]]), .ignored)
    }

    func testHTMLIsDeliveredOnlyForTheAuthenticatedChatChannelIdentifier() throws {
        let html = "<turbo-stream action=\"append\" target=\"messages\"><template><img src=\"https://example.com/image.png\"></template></turbo-stream>"
        XCTAssertEqual(try parse(["identifier": ActionCableProtocol.identifier, "message": html]), .html(html))
        XCTAssertEqual(try parse(["identifier": "other", "message": html]), .ignored)
        XCTAssertEqual(try parse(["message": html]), .ignored)
        XCTAssertEqual(try parse(["identifier": ActionCableProtocol.identifier, "message": [html]]), .ignored)
    }

    func testWebsocketTokenIsHeaderOnlyAndOriginUsesHTTPS() throws {
        let request = try ActionCableProtocol.request(baseURL: XCTUnwrap(URL(string: "https://kokoro.io")), accessToken: "secret-token")
        XCTAssertEqual(request.url?.absoluteString, "wss://kokoro.io/cable")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Access-Token"), "secret-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://kokoro.io")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol"), "actioncable-v1-json")
        XCTAssertFalse(request.url!.absoluteString.contains("secret-token"))
    }

    func testDevelopmentURLPreservesPortAndPrefix() throws {
        let request = try ActionCableProtocol.request(baseURL: XCTUnwrap(URL(string: "http://localhost:3000/chat/")), accessToken: "token")
        XCTAssertEqual(request.url?.absoluteString, "ws://localhost:3000/chat/cable")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "http://localhost:3000")
    }

    func testRejectsUnsafeServerURLAndHeaderInjection() throws {
        for url in ["http://example.com", "https://name:password@example.com", "https://example.com?token=secret", "https://example.com/#fragment"] {
            XCTAssertThrowsError(try ActionCableProtocol.request(baseURL: XCTUnwrap(URL(string: url)), accessToken: "token"))
        }
        XCTAssertThrowsError(try ActionCableProtocol.request(baseURL: XCTUnwrap(URL(string: "https://kokoro.io")), accessToken: "token\r\nAnother: value"))
    }

    @MainActor
    func testExplicitDisconnectCancelsReconnectAndInvalidConfigurationNeverConnects() {
        let client = RealtimeClient()
        client.connect(baseURL: URL(string: "http://unsafe.example")!, accessToken: "token", channelIDs: [])
        guard case .failed = client.state else { return XCTFail("Expected invalid configuration failure") }
        client.disconnect()
        client.reconnect()
        XCTAssertEqual(client.state, .disconnected)
    }

    @MainActor
    func testResumeRequiresChannelMembershipAndAConnectedSubscription() async {
        let client = RealtimeClient()
        do {
            try await client.resumeMessages(channelID: "ABC123", afterID: 1)
            XCTFail("Expected an unsubscribed channel to be rejected")
        } catch {
            XCTAssertEqual(error as? RealtimeResumeError, .channelNotSubscribed)
        }
        client.updateSubscriptions(channelIDs: ["ABC123"])
        do {
            try await client.resumeMessages(channelID: "ABC123", afterID: 1)
            XCTFail("Expected a disconnected socket to be rejected")
        } catch {
            XCTAssertEqual(error as? RealtimeResumeError, .notConnected)
        }
    }

    private func decode(_ value: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
    }

    private func parse(_ value: [String: Any]) throws -> ActionCableProtocol.Frame {
        try ActionCableProtocol.parse(JSONSerialization.data(withJSONObject: value))
    }
}
