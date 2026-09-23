import Foundation
import XCTest
@testable import KokoroCore

final class APITests: XCTestCase {
    private var session: URLSession!
    private let baseURL = URL(string: "https://chat.example.test/prefix")!
    private let token = "private-test-token"

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        APIURLProtocol.handler = nil
        super.tearDown()
    }

    private var client: APIClient { APIClient(baseURL: baseURL, token: token, session: session) }

    func testProfileUsesHeaderAuthenticationAndDecodesProfile() async throws {
        APIURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/prefix/api/v1/profiles/me")
            XCTAssertNil(request.url?.query)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Access-Token"), "private-test-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return (200, Data(Self.profile.utf8))
        }
        let profile = try await client.fetchProfile()
        XCTAssertEqual(profile.id, "PROFILE01")
        XCTAssertEqual(profile.screenName, "alice")
        XCTAssertEqual(profile.initials, "AK")
        XCTAssertEqual(profile.avatar?.host, "chat.example.test")
    }

    func testMembershipArrayBecomesChannelsWithUnreadSettingsAndFractionalDate() async throws {
        APIURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/prefix/api/v1/memberships")
            XCTAssertEqual(request.url?.query, "archived=false")
            return (200, Data("[\(Self.membership)]".utf8))
        }
        let channels = try await client.fetchChannels()
        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels[0].id, "CHANNEL01")
        XCTAssertEqual(channels[0].name, "general")
        XCTAssertEqual(channels[0].latestMessageID, 87)
        XCTAssertEqual(channels[0].unreadCount, 3)
        XCTAssertEqual(channels[0].membership?.id, "MEMBERS01")
        XCTAssertEqual(channels[0].membership?.notificationPolicy, "only_mentions")
        XCTAssertNotNil(channels[0].latestMessagePublishedAt)
    }

    func testMessagesUseExclusiveIntegerPaginationAndDecodeMessage() async throws {
        APIURLProtocol.handler = { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(Set(items.map { "\($0.name)=\($0.value!)" }), Set(["before_id=100", "after_id=20", "limit=1000"]))
            XCTAssertFalse(request.url!.absoluteString.contains("private-test-token"))
            return (200, Data("[\(Self.message)]".utf8))
        }
        let messages = try await client.fetchMessages(channelID: "CHANNEL01", before: 100, after: 20, limit: 2000)
        XCTAssertEqual(messages[0].id, 87)
        XCTAssertEqual(messages[0].text, "Hello, kokoro.io")
        XCTAssertEqual(messages[0].rawContent, "**Hello**, kokoro.io")
        XCTAssertEqual(messages[0].profile.displayName, "Alice K")
        XCTAssertEqual(messages[0].publishedAt.timeIntervalSince1970, 1790039100, accuracy: 1)
    }

    func testChannelSearchUsesEncodedQueryAndDecodesMessages() async throws {
        APIURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/prefix/api/v1/channels/CHANNEL01/messages/search")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(items, [URLQueryItem(name: "query", value: "日本語 test & more")])
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Access-Token"), self.token)
            return (200, Data("[\(Self.message)]".utf8))
        }
        let results = try await client.searchMessages(channelID: "CHANNEL01", query: "日本語 test & more")
        XCTAssertEqual(results.map(\.id), [87])
    }

    func testChannelSearchAcceptsEmptyResults() async throws {
        APIURLProtocol.handler = { _ in (200, Data("[]".utf8)) }
        let empty = try await client.searchMessages(channelID: "CHANNEL01", query: "missing")
        XCTAssertTrue(empty.isEmpty)
    }

    func testSendMessageUsesJSONBodyWithLowercaseIdempotencyKey() async throws {
        APIURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/prefix/api/v1/channels/CHANNEL01/messages")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try Self.readBody(request)
            XCTAssertEqual(body["message"] as? String, "Hello")
            XCTAssertEqual(body["idempotent_key"] as? String, "d341c706-d340-4c78-8723-19897291723c")
            return (201, Data(Self.message.utf8))
        }
        let message = try await client.sendMessage(channelID: "CHANNEL01", text: "Hello", idempotentKey: "D341C706-D340-4C78-8723-19897291723C")
        XCTAssertEqual(message.id, 87)
    }

    func testReadCursorUpdatesMembershipEndpoint() async throws {
        APIURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/prefix/api/v1/memberships/MEMBERS01")
            XCTAssertEqual(try Self.readBody(request)["latest_read_message_id"] as? Int, 87)
            return (200, Data(Self.membership.utf8))
        }
        let membership = try await client.markRead(membershipID: "MEMBERS01", messageID: 87)
        XCTAssertEqual(membership.id, "MEMBERS01")
    }

    func testUnreadCountBackfillsFullPagesEvenWhenEveryMessageIsOwn() async throws {
        var requests = 0
        APIURLProtocol.handler = { request in
            requests += 1
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
            XCTAssertEqual(query["after_id"], "10")
            XCTAssertEqual(query["limit"], "1000")
            func message(id: Int, profileID: String) -> [String: Any] {
                ["id": id, "published_at": "2026-09-22T10:05:00+09:00",
                 "channel": ["id": "CHANNEL01", "channel_name": "general"], "profile": ["id": profileID]]
            }
            let page: [[String: Any]]
            if requests == 1 {
                XCTAssertNil(query["before_id"])
                page = (1001...2000).reversed().map { message(id: $0, profileID: "SELF") }
            } else {
                XCTAssertEqual(requests, 2)
                XCTAssertEqual(query["before_id"], "1001")
                page = [message(id: 999, profileID: "OTHER"), message(id: 500, profileID: "SELF"), message(id: 11, profileID: "OTHER")]
            }
            return (200, try JSONSerialization.data(withJSONObject: page))
        }
        let unread = try await client.fetchUnreadCount(channelID: "CHANNEL01", after: 10, excludingProfileID: "SELF")
        XCTAssertEqual(unread, 2)
        XCTAssertEqual(requests, 2)
    }

    func testUnreadCountReturnsZeroForEmptyPage() async throws {
        APIURLProtocol.handler = { _ in (200, Data("[]".utf8)) }
        let unread = try await client.fetchUnreadCount(channelID: "CHANNEL01", after: 87, excludingProfileID: "PROFILE01")
        XCTAssertEqual(unread, 0)
    }

    func testUnauthorizedIsActionableAndServerEchoNeverRevealsToken() async throws {
        APIURLProtocol.handler = { _ in (401, Data("{\"message\":\"Invalid user token\"}".utf8)) }
        do { _ = try await client.fetchProfile(); XCTFail("Expected 401") }
        catch { XCTAssertEqual(error as? APIError, .unauthorized) }

        APIURLProtocol.handler = { _ in (400, Data("{\"message\":\"Rejected private-test-token\"}".utf8)) }
        do { _ = try await client.fetchProfile(); XCTFail("Expected 400") }
        catch { XCTAssertFalse(error.localizedDescription.contains("private-test-token")) }
    }

    func testInvalidPayloadAndRedirectResponsesAreRejected() async throws {
        APIURLProtocol.handler = { _ in (200, Data("<html>not JSON</html>".utf8)) }
        do { _ = try await client.fetchProfile(); XCTFail("Expected decoding failure") }
        catch { XCTAssertEqual(error as? APIError, .invalidResponse) }
        APIURLProtocol.handler = { _ in (302, Data()) }
        do { _ = try await client.fetchProfile(); XCTFail("Expected redirect rejection") }
        catch { XCTAssertEqual(error as? APIError, .unsafeRedirect) }
    }

    func testServerValidationAndOriginBoundaryProtectCredentials() throws {
        XCTAssertThrowsError(try APIClient.validatedServerURL("http://chat.example.test"))
        XCTAssertThrowsError(try APIClient.validatedServerURL("https://name:password@chat.example.test"))
        XCTAssertThrowsError(try APIClient.validatedServerURL("https://chat.example.test/?token=secret"))
        XCTAssertNoThrow(try APIClient.validatedServerURL("http://127.0.0.1:3000"))
        XCTAssertTrue(SameOriginRedirectGuard.isSameOrigin(URL(string: "https://chat.example.test/next")!, as: baseURL))
        XCTAssertFalse(SameOriginRedirectGuard.isSameOrigin(URL(string: "https://other.example.test/next")!, as: baseURL))
        XCTAssertFalse(SameOriginRedirectGuard.isSameOrigin(URL(string: "http://chat.example.test/next")!, as: baseURL))
        XCTAssertFalse(SameOriginRedirectGuard.isSameOrigin(URL(string: "https://chat.example.test:8443/next")!, as: baseURL))
    }

    func testInvalidIdentifiersAndEmptyMessageNeverSendRequest() async throws {
        APIURLProtocol.handler = { _ in XCTFail("Should not send request"); return (500, Data()) }
        do { _ = try await client.fetchMessages(channelID: "../secret"); XCTFail("Expected invalid ID") }
        catch { XCTAssertEqual(error as? APIError, .invalidIdentifier) }
        do { _ = try await client.sendMessage(channelID: "CHANNEL01", text: " \n "); XCTFail("Expected invalid message") }
        catch { XCTAssertEqual(error as? APIError, .invalidMessage) }
    }

    func testImgBBUploadUsesMultipartAndReturnsImageAndDeleteURLs() async throws {
        APIURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.host, "api.imgbb.com")
            XCTAssertEqual(request.url?.path, "/1/upload")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                           [URLQueryItem(name: "key", value: "secret+key")])
            let body = Self.rawBody(request)
            let text = String(decoding: body, as: UTF8.self)
            XCTAssertTrue(text.contains("name=\"image\"; filename=\"photo.png\""))
            XCTAssertTrue(text.contains("Content-Type: image/png"))
            XCTAssertTrue(text.contains("image bytes"))
            return (200, Data(#"{"data":{"url":"https://i.ibb.co/img/photo.png","delete_url":"https://ibb.co/img/token"},"success":true,"status":200}"#.utf8))
        }
        let upload = try await ImgBBClient(session: session).upload(
            data: Data("image bytes".utf8), fileName: "photo.png", mimeType: "image/png", apiKey: "secret+key"
        )
        XCTAssertEqual(upload.url.absoluteString, "https://i.ibb.co/img/photo.png")
        XCTAssertEqual(upload.deleteURL.absoluteString, "https://ibb.co/img/token")
    }

    func testImgBBDeletePostsParsedURLAndEncodedForm() async throws {
        APIURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "https://ibb.co/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded; charset=UTF-8")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://ibb.co")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Requested-With"), "XMLHttpRequest")
            let form = String(decoding: Self.rawBody(request), as: UTF8.self)
            XCTAssertTrue(form.contains("auth_token=secret%2Bkey"))
            let fields = URLComponents(string: "?\(form)")!.queryItems!
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.value!) }), [
                "auth_token": "secret+key", "pathname": "/img/token", "action": "delete",
                "delete": "image", "from": "resource", "deleting[id]": "img",
                "deleting[type]": "image", "deleting[privacy]": "public", "deleting[hash]": "token"
            ])
            return (200, Data())
        }
        let client = ImgBBClient(session: session)
        try await client.delete(ImgBBUpload(url: URL(string: "https://i.ibb.co/img/photo.png")!,
                                             deleteURL: URL(string: "https://ibb.co/img/token")!), apiKey: "secret+key")
    }

    func testImgBBDeleteRejectsInvalidURLsAndMissingKeyBeforeRequest() async throws {
        APIURLProtocol.handler = { _ in XCTFail("Should not send request"); return (500, Data()) }
        let client = ImgBBClient(session: session)
        let imageURL = URL(string: "https://i.ibb.co/img/photo.png")!
        for value in ["https://example.com/img/token", "http://ibb.co/img/token",
                      "https://ibb.co:8443/img/token", "https://ibb.co/img/token?key=secret",
                      "https://ibb.co/img/%2Ftoken", "https://ibb.co/img/"] {
            do {
                try await client.delete(ImgBBUpload(url: imageURL, deleteURL: URL(string: value)!), apiKey: "secret")
                XCTFail("Expected unsafe delete URL: \(value)")
            } catch ImgBBError.unsafeDeleteURL { }
        }
        do {
            try await client.delete(ImgBBUpload(url: imageURL,
                                                deleteURL: URL(string: "https://ibb.co/img/token")!), apiKey: "")
            XCTFail("Expected missing API key")
        } catch ImgBBError.missingAPIKey { }
    }

    func testImgBBDeleteReportsHTTPFailure() async throws {
        APIURLProtocol.handler = { _ in (403, Data()) }
        let client = ImgBBClient(session: session)
        do {
            try await client.delete(ImgBBUpload(url: URL(string: "https://i.ibb.co/img/photo.png")!,
                                                deleteURL: URL(string: "https://ibb.co/img/token")!), apiKey: "secret")
            XCTFail("Expected HTTP failure")
        } catch ImgBBError.server(let status) {
            XCTAssertEqual(status, 403)
        }
    }

    func testComposerMessageAppendsImageURLsInOrder() {
        let urls = ["https://i.ibb.co/second.png", "https://i.ibb.co/first.png"].map { URL(string: $0)! }
        XCTAssertEqual(ComposerMessage.text(" hello \n", imageURLs: urls),
                       "hello\nhttps://i.ibb.co/second.png\nhttps://i.ibb.co/first.png")
        XCTAssertEqual(ComposerMessage.text("  ", imageURLs: urls),
                       "https://i.ibb.co/second.png\nhttps://i.ibb.co/first.png")
    }

    private static func readBody(_ request: URLRequest) throws -> [String: Any] {
        let data = rawBody(request)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private static func rawBody(_ request: URLRequest) -> Data {
        let data: Data
        if let body = request.httpBody { data = body }
        else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                result.append(contentsOf: buffer.prefix(count))
            }
            data = result
        } else { data = Data() }
        return data
    }

    private static let profile = #"{"id":"PROFILE01","type":"User","screen_name":"alice","display_name":"Alice K","avatar":"https://chat.example.test/avatar.png","avatars":[],"archived":false,"invited_channels_count":0}"#
    private static let channel = #"{"id":"CHANNEL01","channel_name":"general","kind":"public_channel","archived":false,"description":"General chat","latest_message_id":87,"latest_message_published_at":"2026-09-22T10:05:00.123+09:00","messages_count":87}"#
    private static var membership: String { "{\"id\":\"MEMBERS01\",\"channel\":\(channel),\"authority\":\"member\",\"disable_notification\":false,\"notification_policy\":\"only_mentions\",\"read_state_tracking_policy\":\"keep_latest\",\"latest_read_message_id\":84,\"unread_count\":3,\"visible\":true,\"muted\":false,\"profile\":\(profile)}" }
    private static var message: String { "{\"id\":87,\"idempotent_key\":\"d341c706-d340-4c78-8723-19897291723c\",\"display_name\":\"Alice K\",\"avatar\":null,\"status\":\"active\",\"html_content\":\"<p><strong>Hello</strong>, kokoro.io</p>\",\"plaintext_content\":\"Hello, kokoro.io\",\"raw_content\":\"**Hello**, kokoro.io\",\"published_at\":\"2026-09-22T10:05:00+09:00\",\"nsfw\":false,\"channel\":\(channel),\"profile\":\(profile)}" }
}

private final class APIURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
