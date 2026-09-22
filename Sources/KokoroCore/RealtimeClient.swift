import Foundation

public struct RealtimeEvent: Equatable, Sendable {
    public let name: String
    public let payload: Data

    public init(name: String, payload: Data) {
        self.name = name
        self.payload = payload
    }
}

public enum RealtimeConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case failed(String)
}

public enum RealtimeResumeError: LocalizedError, Equatable, Sendable {
    case invalidChannelID
    case invalidAfterID
    case channelNotSubscribed
    case notConnected
    case connectionChanged

    public var errorDescription: String? {
        switch self {
        case .invalidChannelID: return "チャンネル ID が無効です。"
        case .invalidAfterID: return "メッセージ ID が無効です。"
        case .channelNotSubscribed: return "チャンネルを購読していません。"
        case .notConnected: return "リアルタイム接続が確立されていません。"
        case .connectionChanged: return "リアルタイム接続が切り替わりました。"
        }
    }
}

/// The JSON protocol used by Rails ActionCable, independently testable without a socket.
public enum ActionCableProtocol {
    public static let identifier = #"{"channel":"ChatChannel"}"#

    public enum Frame: Equatable, Sendable {
        case welcome
        case ping
        case confirmed
        case rejected
        case disconnected(reason: String, reconnect: Bool)
        case event(RealtimeEvent)
        case html(String)
        case ignored
    }

    public enum ConfigurationError: LocalizedError {
        case invalidServer
        case invalidToken

        public var errorDescription: String? {
            switch self {
            case .invalidServer: return "HTTPS のサーバー URL を指定してください。HTTP は localhost のみ利用できます。"
            case .invalidToken: return "アクセストークンが無効です。"
            }
        }
    }

    public static func request(baseURL: URL, accessToken: String) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host))
        else { throw ConfigurationError.invalidServer }
        guard !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !accessToken.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw ConfigurationError.invalidToken }

        var origin = components
        origin.path = ""
        components.scheme = scheme == "https" ? "wss" : "ws"
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + (components.path.isEmpty ? "" : components.path + "/") + "cable"
        guard let socketURL = components.url, let originURL = origin.url else {
            throw ConfigurationError.invalidServer
        }
        var request = URLRequest(url: socketURL)
        request.setValue(accessToken, forHTTPHeaderField: "X-Access-Token")
        request.setValue(originURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue("actioncable-v1-json", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        request.timeoutInterval = 30
        return request
    }

    public static func subscribeFrame() throws -> String {
        try encode(["command": "subscribe", "identifier": identifier])
    }

    /// `subscribe` is an action in ChatChannel, separate from the ActionCable subscription.
    public static func channelsFrame(_ channelIDs: [String]) throws -> String {
        try actionFrame(["action": "subscribe", "channels": Array(Set(channelIDs)).sorted()])
    }

    public static func clearChannelsFrame() throws -> String {
        try actionFrame(["action": "unsubscribe"])
    }

    /// Reuses the Web client's catch-up action to obtain rendered attachment URLs.
    public static func resumeFrame(channelID: String, afterID: Int) throws -> String {
        guard !channelID.isEmpty,
              channelID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) })
        else { throw RealtimeResumeError.invalidChannelID }
        guard afterID > 0 else { throw RealtimeResumeError.invalidAfterID }
        return try actionFrame(["action": "resume", "channel_hashid": channelID, "after_id": afterID])
    }

    public static func parse(_ data: Data) throws -> Frame {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .ignored }
        if let type = object["type"] as? String {
            switch type {
            case "welcome": return .welcome
            case "ping": return .ping
            case "disconnect":
                return .disconnected(reason: object["reason"] as? String ?? "接続が終了しました", reconnect: object["reconnect"] as? Bool ?? true)
            case "confirm_subscription": return object["identifier"] as? String == identifier ? .confirmed : .ignored
            case "reject_subscription": return object["identifier"] as? String == identifier ? .rejected : .ignored
            default: return .ignored
            }
        }
        guard object["identifier"] as? String == identifier else { return .ignored }
        if let html = object["message"] as? String { return .html(html) }
        guard let message = object["message"] as? [String: Any],
              let event = message["event"] as? String,
              let payload = message["data"] else { return .ignored }
        return .event(RealtimeEvent(name: event, payload: try JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed, .sortedKeys])))
    }

    private static func actionFrame(_ action: [String: Any]) throws -> String {
        try encode(["command": "message", "identifier": identifier, "data": try encode(action)])
    }

    private static func encode(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
}

/// Reject every HTTP redirect so the access token never follows a server-controlled URL.
private final class RealtimeSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
public final class RealtimeClient {
    public var onEvent: ((RealtimeEvent) -> Void)?
    public var onHTML: ((String) -> Void)?
    public var onStateChange: ((RealtimeConnectionState) -> Void)?
    public private(set) var state: RealtimeConnectionState = .disconnected {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    private var request: URLRequest?
    private var channelIDs: [String] = []
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var subscriptionTask: Task<Void, Never>?
    private var wantsConnection = false
    private var isSubscribed = false
    private var generation = 0
    private var subscriptionRevision = 0
    private var reconnectAttempt = 0
    private var lastFrameAt = Date()
    private let sessionDelegate = RealtimeSessionDelegate()

    public init() {}

    deinit {
        receiveTask?.cancel()
        watchdogTask?.cancel()
        reconnectTask?.cancel()
        subscriptionTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    public func connect(baseURL: URL, accessToken: String, channelIDs: [String]) {
        disconnect()
        do {
            request = try ActionCableProtocol.request(baseURL: baseURL, accessToken: accessToken)
            self.channelIDs = Array(Set(channelIDs)).sorted()
            wantsConnection = true
            reconnectAttempt = 0
            openConnection()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Replaces the complete set; all joined channels should be included for notifications.
    public func updateSubscriptions(channelIDs: [String]) {
        let desired = Array(Set(channelIDs)).sorted()
        guard desired != self.channelIDs else { return }
        self.channelIDs = desired
        subscriptionRevision += 1
        synchronizeSubscriptions()
    }

    public func resumeMessages(channelID: String, afterID: Int) async throws {
        try Task.checkCancellation()
        let frame = try ActionCableProtocol.resumeFrame(channelID: channelID, afterID: afterID)
        guard channelIDs.contains(channelID) else { throw RealtimeResumeError.channelNotSubscribed }
        guard state == .connected, isSubscribed, let socket else { throw RealtimeResumeError.notConnected }
        let currentGeneration = generation
        do {
            try await socket.send(.string(frame))
        } catch {
            guard generation == currentGeneration, self.socket === socket else {
                throw RealtimeResumeError.connectionChanged
            }
            throw error
        }
        try Task.checkCancellation()
        guard generation == currentGeneration, self.socket === socket else {
            throw RealtimeResumeError.connectionChanged
        }
        guard state == .connected, isSubscribed else { throw RealtimeResumeError.notConnected }
        guard channelIDs.contains(channelID) else { throw RealtimeResumeError.channelNotSubscribed }
    }

    public func disconnect() {
        wantsConnection = false
        reconnectTask?.cancel()
        reconnectTask = nil
        stopConnection()
        request = nil
        state = .disconnected
    }

    public func reconnect() {
        guard request != nil else { return }
        wantsConnection = true
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        openConnection()
    }

    private func openConnection() {
        guard wantsConnection, let request else { return }
        stopConnection()
        let currentGeneration = generation
        state = .connecting
        lastFrameAt = Date()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration, delegate: sessionDelegate, delegateQueue: nil)
        self.session = session
        let socket = session.webSocketTask(with: request)
        self.socket = socket
        socket.resume()

        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    guard let self, self.generation == currentGeneration else { return }
                    self.lastFrameAt = Date()
                    let data: Data
                    switch message {
                    case .data(let value): data = value
                    case .string(let value): data = Data(value.utf8)
                    @unknown default: continue
                    }
                    guard let frame = try? ActionCableProtocol.parse(data) else { continue }
                    await self.receive(frame, generation: currentGeneration)
                } catch {
                    guard !Task.isCancelled, let self, self.generation == currentGeneration else { return }
                    self.connectionFailed()
                    return
                }
            }
        }
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard let self, self.generation == currentGeneration else { return }
                // ActionCable emits an application-level ping every few seconds. A silent
                // connection must recover even if the OS has not noticed the disconnection.
                if Date().timeIntervalSince(self.lastFrameAt) > 45 {
                    self.connectionFailed()
                    return
                }
            }
        }
    }

    private func receive(_ frame: ActionCableProtocol.Frame, generation currentGeneration: Int) async {
        guard generation == currentGeneration else { return }
        switch frame {
        case .welcome:
            do { try await socket?.send(.string(ActionCableProtocol.subscribeFrame())) }
            catch { if generation == currentGeneration { connectionFailed() } }
        case .confirmed:
            isSubscribed = true
            reconnectAttempt = 0
            state = .connected
            subscriptionRevision += 1
            synchronizeSubscriptions()
        case .rejected:
            stopWithFailure("チャンネルの購読が拒否されました。アクセストークンを確認してください。")
        case .disconnected(let reason, let reconnect):
            if reconnect { connectionFailed() }
            else { stopWithFailure(reason == "unauthorized" ? "認証に失敗しました。アクセストークンを確認してください。" : "サーバーによって接続が終了しました。") }
        case .event(let event): onEvent?(event)
        case .html(let html): onHTML?(html)
        case .ping, .ignored: break
        }
    }

    private func synchronizeSubscriptions() {
        guard isSubscribed, subscriptionTask == nil else { return }
        let currentGeneration = generation
        subscriptionTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == currentGeneration { self.subscriptionTask = nil } }
            repeat {
                let revision = self.subscriptionRevision
                let channelIDs = self.channelIDs
                do {
                    guard let socket = self.socket else { return }
                    // Server's subscribe action only adds streams; clear first to remove
                    // memberships the user has left, then restore the desired subscriptions.
                    try await socket.send(.string(ActionCableProtocol.clearChannelsFrame()))
                    guard !Task.isCancelled, self.generation == currentGeneration else { return }
                    try await socket.send(.string(ActionCableProtocol.channelsFrame(channelIDs)))
                } catch {
                    if !Task.isCancelled, self.generation == currentGeneration { self.connectionFailed() }
                    return
                }
                guard !Task.isCancelled, self.generation == currentGeneration else { return }
                if revision == self.subscriptionRevision { return }
            } while self.isSubscribed
        }
    }

    private func connectionFailed() {
        guard wantsConnection else { return }
        stopConnection()
        reconnectAttempt += 1
        state = .reconnecting(attempt: reconnectAttempt)
        let delay = min(30.0, pow(2.0, Double(min(reconnectAttempt - 1, 5))))
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.wantsConnection else { return }
            self.reconnectTask = nil
            self.openConnection()
        }
    }

    private func stopWithFailure(_ message: String) {
        wantsConnection = false
        reconnectTask?.cancel()
        reconnectTask = nil
        stopConnection()
        state = .failed(message)
    }

    private func stopConnection() {
        generation += 1
        isSubscribed = false
        receiveTask?.cancel()
        receiveTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        subscriptionTask?.cancel()
        subscriptionTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
    }
}
