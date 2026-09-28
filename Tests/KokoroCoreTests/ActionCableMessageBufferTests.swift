import Foundation
import XCTest
@testable import KokoroCore

final class ActionCableMessageBufferTests: XCTestCase {
    func testHTMLIsDeliveredOnlyAfterAllChunksArrive() throws {
        let html = "<turbo-stream><template>" + String(repeating: "画像 {text} \\\" 😀", count: 3000) + "</template></turbo-stream>"
        let data = try encode(["identifier": ActionCableProtocol.identifier, "message": html])
        var buffer = ActionCableMessageBuffer()
        var frames: [ActionCableProtocol.Frame] = []
        for start in stride(from: 0, to: data.count, by: 6986) {
            let end = min(start + 6986, data.count)
            frames += try buffer.append(data.subdata(in: start..<end))
            if end < data.count { XCTAssertTrue(frames.isEmpty) }
        }
        XCTAssertEqual(frames, [.html(html)])
        XCTAssertEqual(try buffer.append(encode(["type": "ping"])), [.ping])
    }

    func testEveryByteBoundaryPreservesUnicodeQuotesAndBackslashes() throws {
        let html = "日本語😀 { [ ] } \" \\ \\\" \\u1234"
        let data = try encode(["identifier": ActionCableProtocol.identifier, "message": html])
        for split in 1..<data.count {
            var buffer = ActionCableMessageBuffer()
            XCTAssertEqual(try buffer.append(Data(data.prefix(split))), [], "split \(split)")
            XCTAssertEqual(try buffer.append(Data(data.dropFirst(split))), [.html(html)], "split \(split)")
        }
        var buffer = ActionCableMessageBuffer()
        var frames: [ActionCableProtocol.Frame] = []
        for byte in data { frames += try buffer.append(Data([byte])) }
        XCTAssertEqual(frames, [.html(html)])
    }

    func testNestedEventDataIsNotMistakenForASeparateFrame() throws {
        let data = try encode(["identifier": ActionCableProtocol.identifier,
                               "message": ["event": "message_updated", "data": ["id": 42, "images": [["url": "/photo.png"]]]]])
        var buffer = ActionCableMessageBuffer()
        var frames: [ActionCableProtocol.Frame] = []
        for byte in data { frames += try buffer.append(Data([byte])) }
        XCTAssertEqual(frames, [try ActionCableProtocol.parse(data)])
    }

    func testConsecutiveFramesAndPartialTailRemainSeparate() throws {
        var buffer = ActionCableMessageBuffer()
        let welcome = try encode(["type": "welcome"])
        let ping = try encode(["type": "ping"])
        let combined = Data(" \n".utf8) + welcome + Data("\r\n".utf8) + ping
        XCTAssertEqual(try buffer.append(combined + Data(welcome.prefix(5))), [.welcome, .ping])
        XCTAssertEqual(try buffer.append(Data(welcome.dropFirst(5))), [.welcome])
        XCTAssertEqual(try buffer.append(Data(" \n".utf8)), [])
    }

    func testCompleteMessagesRetainProtocolIdentityChecks() throws {
        var buffer = ActionCableMessageBuffer()
        XCTAssertEqual(try buffer.append(encode(["identifier": "other", "message": "<html>"])), [.ignored])
        XCTAssertEqual(try buffer.append(encode(["type": "welcome"])), [.welcome])
    }

    func testMalformedAndOversizedMessagesFailAndClearPendingBytes() throws {
        var buffer = ActionCableMessageBuffer(maximumBytes: 128)
        XCTAssertEqual(try buffer.append(Data("{\"message\":\"".utf8)), [])
        XCTAssertThrowsError(try buffer.append(Data(repeating: 0x61, count: 128)))
        XCTAssertEqual(try buffer.append(encode(["type": "welcome"])), [.welcome])
        for invalid in ["garbage", "[]", "{\"message\":}", "{]"] {
            XCTAssertThrowsError(try buffer.append(Data(invalid.utf8)))
            XCTAssertEqual(try buffer.append(encode(["type": "ping"])), [.ping])
        }
    }
}

private func encode(_ value: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}
