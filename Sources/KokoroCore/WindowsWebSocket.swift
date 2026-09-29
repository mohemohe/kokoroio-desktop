#if os(Windows)
import Foundation
import FoundationNetworking
import WindowsWebSocketNative

/// WinHTTP waits for network completion, avoiding the idle CPU observed with
/// FoundationNetworking's Windows WebSocket path. Each connection owns
/// one serial reader and writer; neither blocks Swift's cooperative executor.
final class WindowsWebSocket: @unchecked Sendable {
    private let handle: OpaquePointer?
    private let request: URLRequest
    private let reader = DispatchQueue(label: "Kokoro.WebSocket.receive", qos: .utility)
    private let writer = DispatchQueue(label: "Kokoro.WebSocket.send", qos: .utility)
    private let connected = DispatchGroup()
    // Written before connected.leave(), read only after connected.wait().
    private var connectionError: Error?

    init(request: URLRequest) {
        self.request = request
        handle = KokoroWebSocketCreate()
    }

    deinit { if let handle { KokoroWebSocketDestroy(handle) } }

    func resume() {
        // RealtimeClient starts each socket once, before scheduling reads/writes.
        connected.enter()
        reader.async { [self] in
            defer { connected.leave() }
            do {
                guard let handle, let url = request.url,
                      let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      let host = parts.host else { throw URLError(.badURL) }
                let secure = parts.scheme == "wss"
                guard let port = UInt16(exactly: parts.port ?? (secure ? 443 : 80)), port > 0 else {
                    throw URLError(.badURL)
                }
                let path = parts.percentEncodedPath + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")
                let headers = (request.allHTTPHeaderFields ?? [:]).sorted { $0.key < $1.key }
                    .map { "\($0.key): \($0.value)\r\n" }.joined()
                // WinHTTP expects an IPv6 hostname without URI brackets.
                let hostname = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
                let code = Array(hostname.utf16) + [0]
                let target = Array(path.utf16) + [0]
                let fields = Array(headers.utf16) + [0]
                try Self.check(KokoroWebSocketConnect(handle, code, port, target, fields, secure ? 1 : 0))
            } catch { connectionError = error }
        }
    }

    func cancel(with _: URLSessionWebSocketTask.CloseCode, reason _: Data?) {
        if let handle { KokoroWebSocketCancel(handle) }
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: throw URLError(.unsupportedURL)
        }
        guard data.count <= ActionCableMessageBuffer.maximumMessageBytes else { throw URLError(.dataLengthExceedsMaximum) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.async { [self] in
                do {
                    connected.wait()
                    if let connectionError { throw connectionError }
                    guard let handle else { throw URLError(.cannotConnectToHost) }
                    try data.withUnsafeBytes { bytes in
                        try Self.check(KokoroWebSocketWrite(handle, bytes.bindMemory(to: UInt8.self).baseAddress, UInt32(bytes.count)))
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            reader.async { [self] in
                do {
                    if let connectionError { throw connectionError }
                    guard let handle else { throw URLError(.cannotConnectToHost) }
                    var message = Data()
                    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                    while true {
                        var count: UInt32 = 0, complete: Int32 = 0
                        try Self.check(KokoroWebSocketRead(handle, &buffer, UInt32(buffer.count), &count, &complete))
                        guard message.count + Int(count) <= ActionCableMessageBuffer.maximumMessageBytes else {
                            KokoroWebSocketCancel(handle)
                            throw URLError(.dataLengthExceedsMaximum)
                        }
                        message.append(contentsOf: buffer.prefix(Int(count)))
                        if complete != 0 { break }
                    }
                    // Decode JSON only after all UTF-8 fragments are assembled.
                    continuation.resume(returning: .data(message))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func check(_ result: UInt32) throws {
        guard result != 0 else { return }
        throw NSError(domain: "Kokoro.WinHTTP", code: Int(result),
            userInfo: [NSLocalizedDescriptionKey: "WebSocket 接続エラー (Windows: \(result))"])
    }
}
#endif
