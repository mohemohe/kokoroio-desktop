#if os(Windows)
import Foundation
import FoundationNetworking
import XCTest
@testable import KokoroCore

final class WindowsWebSocketTests: XCTestCase {
    func testCancellationBeforeConnectCompletesPendingReadAndWrite() async throws {
        let request = try ActionCableProtocol.request(baseURL: URL(string: "http://127.0.0.1:1")!, accessToken: "test-token")
        let socket = WindowsWebSocket(request: request)
        socket.cancel(with: .goingAway, reason: nil)
        socket.resume()
        do {
            _ = try await socket.receive()
            XCTFail("Cancelled socket must not receive")
        } catch { XCTAssertEqual((error as NSError).code, 995) }
        do {
            try await socket.send(.string("test"))
            XCTFail("Cancelled socket must not send")
        } catch { XCTAssertEqual((error as NSError).code, 995) }
        socket.cancel(with: .goingAway, reason: nil)
    }

    func testOversizedOutgoingMessageIsRejectedBeforeConnecting() async throws {
        let request = try ActionCableProtocol.request(baseURL: URL(string: "http://127.0.0.1:1")!, accessToken: "test-token")
        let socket = WindowsWebSocket(request: request)
        do {
            try await socket.send(.data(Data(count: ActionCableMessageBuffer.maximumMessageBytes + 1)))
            XCTFail("Oversized send must fail")
        } catch { XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum) }
    }
}
#endif
