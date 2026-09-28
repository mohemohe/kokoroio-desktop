import Foundation
import XCTest
import KokoroCore
@testable import KokoroWindowsState

private final class FakeService: WindowsChatService {
    var user = Profile(id: "USER01", displayName: "Tester")
    var channels = [
        Channel(id: "CHAN01", channelName: "general", membership: .init(id: "MEM01")),
        Channel(id: "CHAN02", channelName: "random", membership: .init(id: "MEM02"))
    ]
    var sendKeys: [String] = []
    var failSend = false
    var pendingSend: CheckedContinuation<Message, Error>?
    var suspendSend = false
    var pendingFetch: CheckedContinuation<[Message], Error>?
    var suspendFetch = false
    var readIDs: [Int] = []
    var sentTexts: [String] = []
    var searchCalls: [(String, String)] = []
    var searchResults: [Message] = []
    var suspendSearch = false
    var failSearch = false
    var pendingSearches: [CheckedContinuation<[Message], Error>] = []
    func fetchProfile() async throws -> Profile { user }
    func fetchChannels() async throws -> [Channel] { channels }
    func fetchMessages(channelID: String, before: Int?, after: Int?, limit: Int) async throws -> [Message] {
        if suspendFetch { return try await withCheckedThrowingContinuation { pendingFetch = $0 } }
        return [message(id: 1, channel: channelID)]
    }
    func fetchUnreadCount(channelID: String, after: Int, excludingProfileID: String) async throws -> Int { 0 }
    func sendMessage(channelID: String, text: String, idempotentKey: String) async throws -> Message {
        sendKeys.append(idempotentKey)
        sentTexts.append(text)
        if failSend { throw APIError.invalidResponse }
        if suspendSend { return try await withCheckedThrowingContinuation { pendingSend = $0 } }
        return message(id: 2, channel: channelID, text: text)
    }
    func markRead(membershipID: String, messageID: Int) async throws -> Membership {
        readIDs.append(messageID)
        return Membership(channel: channels[0], details: .init(id: membershipID, latestReadMessageID: messageID))
    }
    func searchMessages(channelID: String, query: String) async throws -> [Message] {
        searchCalls.append((channelID, query))
        if failSearch { throw APIError.invalidResponse }
        if suspendSearch { return try await withCheckedThrowingContinuation { pendingSearches.append($0) } }
        return searchResults
    }
    func message(id: Int, channel: String = "CHAN01", text: String = "hello") -> Message {
        Message(id: id, rawContent: text, channel: channels.first { $0.id == channel }!, profile: user)
    }
}

private actor FakeImageService: WindowsImageService {
    var uploads: [(String, String)] = []
    var deletions: [(URL, String)] = []
    var suspendUpload = false
    var failUpload = false
    var failDelete = false
    var pendingUploads: [CheckedContinuation<ImgBBUpload, Error>] = []
    var uploadCount: Int { uploads.count }
    var pendingCount: Int { pendingUploads.count }
    var deletionCount: Int { deletions.count }
    func setSuspended(_ value: Bool) { suspendUpload = value }
    func setUploadFailure(_ value: Bool) { failUpload = value }
    func setDeleteFailure(_ value: Bool) { failDelete = value }
    func upload(data: Data, fileName: String, mimeType: String, apiKey: String) async throws -> ImgBBUpload {
        uploads.append((fileName, apiKey))
        if failUpload { throw ImgBBError.server(500) }
        if suspendUpload { return try await withCheckedThrowingContinuation { pendingUploads.append($0) } }
        return Self.result
    }
    func delete(_ upload: ImgBBUpload, apiKey: String) async throws {
        deletions.append((upload.url, apiKey))
        if failDelete { throw ImgBBError.server(500) }
    }
    func finishUpload() { pendingUploads.removeFirst().resume(returning: Self.result) }
    static let result = ImgBBUpload(url: URL(string: "https://i.ibb.co/test/image.png")!, deleteURL: URL(string: "https://ibb.co/image/delete")!)
}

final class WindowsChatStoreTests: XCTestCase {
    private var defaultsSuites: [String] = []
    private var temporaryImages: [URL] = []

    override func tearDown() {
        for suite in defaultsSuites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        for url in temporaryImages { try? FileManager.default.removeItem(at: url) }
        super.tearDown()
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "KokoroWindowsStateTests.\(UUID().uuidString)"
        defaultsSuites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    private func temporaryImage() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kokoro-test-\(UUID().uuidString).png")
        try Data([137, 80, 78, 71, 13, 10, 26, 10]).write(to: url)
        temporaryImages.append(url)
        return url
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () async -> Bool) async {
        for _ in 0..<3000 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for asynchronous state")
    }

    private func event(_ message: Message, name: String = "message_created") throws -> RealtimeEvent {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return RealtimeEvent(name: name, payload: try encoder.encode(message))
    }

    @MainActor
    private func connected(_ service: FakeService, defaults: UserDefaults? = nil,
                           imageService: any WindowsImageService = FakeImageService()) async -> WindowsChatStore {
        let store = WindowsChatStore(usesRealtime: false, defaults: defaults ?? isolatedDefaults(), imageService: imageService,
                                     makeClient: { _, _ in service })
        let success = await store.signIn(server: "http://localhost:8765", token: "test-token")
        XCTAssertTrue(success)
        return store
    }

    @MainActor
    func testChannelDraftsAndSignOut() async {
        let store = await connected(FakeService())
        store.draft = "first"
        await store.selectChannel("CHAN02")
        XCTAssertEqual(store.draft, "")
        store.draft = "second"
        await store.selectChannel("CHAN01")
        XCTAssertEqual(store.draft, "first")
        store.signOut()
        XCTAssertNil(store.profile)
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertEqual(store.draft, "")
    }

    @MainActor
    func testFailedSendKeepsDraftAndReusesIdempotencyKey() async {
        let service = FakeService(), store = await connected(service)
        store.draft = "retry me"; service.failSend = true
        await store.send()
        XCTAssertEqual(store.draft, "retry me")
        service.failSend = false
        await store.send()
        XCTAssertEqual(service.sendKeys.count, 2)
        XCTAssertEqual(service.sendKeys.first, service.sendKeys.last)
        XCTAssertEqual(store.draft, "")
        XCTAssertEqual(store.messages.count, 2)
    }

    @MainActor
    func testSendResponseDoesNotCrossChannelOrEraseNewDraft() async {
        let service = FakeService(), store = await connected(service)
        service.suspendSend = true; store.draft = "in flight"
        let sending = Task { await store.send() }
        while service.pendingSend == nil { await Task.yield() }
        store.draft = "new draft"
        await store.selectChannel("CHAN02")
        service.pendingSend?.resume(returning: service.message(id: 2))
        await sending.value
        XCTAssertTrue(store.messages.allSatisfy { $0.channel.id == "CHAN02" })
        await store.selectChannel("CHAN01")
        XCTAssertEqual(store.draft, "new draft")
    }

    @MainActor
    func testSignOutDiscardsSuspendedResponse() async {
        let service = FakeService(), store = await connected(service)
        service.suspendFetch = true
        let loading = Task { await store.selectChannel("CHAN02") }
        while service.pendingFetch == nil { await Task.yield() }
        store.signOut()
        service.pendingFetch?.resume(returning: [service.message(id: 3, channel: "CHAN02")])
        await loading.value
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertNil(store.selectedChannelID)
        XCTAssertFalse(store.isLoading)
    }

    @MainActor
    func testReadCursorRequiresActiveWindowAndTimelineBottom() async {
        let service = FakeService(), store = await connected(service)
        store.isActive = false
        await store.markRead()
        store.isActive = true; store.isAtBottom = false
        await store.markRead()
        XCTAssertTrue(service.readIDs.isEmpty)
        store.isAtBottom = true
        await store.markRead()
        await store.markRead()
        XCTAssertEqual(service.readIDs, [1])
    }

    @MainActor
    func testRealtimeUpdateWinsOverAnOlderHTTPResponse() async throws {
        let service = FakeService(), store = await connected(service)
        service.suspendFetch = true
        let loading = Task { await store.loadMessages() }
        while service.pendingFetch == nil { await Task.yield() }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let updated = service.message(id: 1, text: "updated over websocket")
        store.receive(RealtimeEvent(name: "message_updated", payload: try encoder.encode(updated)))
        service.pendingFetch?.resume(returning: [service.message(id: 1, text: "stale HTTP")])
        await loading.value
        XCTAssertEqual(store.messages.first?.rawContent, "updated over websocket")
        XCTAssertEqual(store.messages.count, 1)
    }

    @MainActor
    func testPinsPersistPerServerAndProfileAndSectionsKeepChannelKinds() async {
        let service = FakeService(), defaults = isolatedDefaults()
        service.channels.append(Channel(id: "PRIVATE", channelName: "secret", kind: "private_channel", membership: .init(id: "MEM03")))
        service.channels.append(Channel(id: "DIRECT", channelName: "friend", kind: "direct_message", membership: .init(id: "MEM04")))
        let store = await connected(service, defaults: defaults)
        store.togglePin("PRIVATE"); store.togglePin("UNKNOWN")
        XCTAssertEqual(store.pinnedChannelIDs, ["PRIVATE"])
        XCTAssertEqual(store.channelSections.map(\.title), ["ピン留め", "チャンネル", "プライベート", "ダイレクトメッセージ"])
        XCTAssertEqual(store.channelSections[0].channels.map(\.id), ["PRIVATE"])
        XCTAssertEqual(store.channelSections[1].channels.map(\.id), ["CHAN01", "CHAN02"])
        XCTAssertEqual(store.channelSections[2].channels.map(\.id), ["PRIVATE"])
        XCTAssertEqual(store.channelSections[3].channels.map(\.id), ["DIRECT"])
        store.signOut()
        XCTAssertTrue(store.pinnedChannelIDs.isEmpty)
        _ = await store.signIn(server: "http://localhost:8765", token: "test-token")
        XCTAssertTrue(store.isPinned("PRIVATE"))
        _ = await store.signIn(server: "http://localhost:9999", token: "test-token")
        XCTAssertTrue(store.pinnedChannelIDs.isEmpty)
        service.user = Profile(id: "USER02")
        _ = await store.signIn(server: "http://localhost:8765", token: "test-token")
        XCTAssertTrue(store.pinnedChannelIDs.isEmpty)
    }

    @MainActor
    func testImageUploadStaysWithItsChannelAndImageOnlyMessageCanSend() async throws {
        let service = FakeService(), images = FakeImageService()
        await images.setSuspended(true)
        let store = await connected(service, imageService: images)
        store.updateImgBBAPIKey(" key ")
        store.addImages([try temporaryImage()])
        XCTAssertFalse(store.canSend)
        await waitUntil { await images.pendingCount == 1 }
        await store.selectChannel("CHAN02")
        XCTAssertTrue(store.composerImages.isEmpty)
        await images.finishUpload()
        await store.selectChannel("CHAN01")
        await waitUntil { store.composerImages.first?.isUploading == false }
        XCTAssertTrue(store.canSend)
        XCTAssertEqual(store.composedDraft, FakeImageService.result.url.absoluteString)
        await store.send()
        XCTAssertEqual(service.sentTexts, [FakeImageService.result.url.absoluteString])
        XCTAssertTrue(store.composerImages.isEmpty)
        XCTAssertFalse(store.canSend)
        let uploads = await images.uploads
        XCTAssertEqual(uploads.first?.1, "key")
    }

    @MainActor
    func testFailedUploadBlocksSendAndRetriesWithUpdatedKey() async throws {
        let images = FakeImageService()
        await images.setUploadFailure(true)
        let store = await connected(FakeService(), imageService: images)
        store.updateImgBBAPIKey("wrong-key"); store.draft = "photo"
        store.addImages([try temporaryImage()])
        await waitUntil { store.composerImages.first?.error != nil }
        XCTAssertFalse(store.canSend)
        await images.setUploadFailure(false)
        store.updateImgBBAPIKey("correct-key")
        store.retryImage(store.composerImages[0].id)
        await waitUntil { store.composerImages.first?.upload != nil }
        XCTAssertTrue(store.canSend)
        XCTAssertNil(store.composerImages.first?.error)
        let uploads = await images.uploads
        XCTAssertEqual(uploads.map { $0.1 }, ["wrong-key", "correct-key"])
    }

    @MainActor
    func testRemovingPendingUploadDeletesAfterCompletionWithoutCrossingChannels() async throws {
        let images = FakeImageService()
        await images.setSuspended(true)
        let store = await connected(FakeService(), imageService: images)
        store.updateImgBBAPIKey("original-key")
        store.addImages([try temporaryImage()])
        await waitUntil { await images.pendingCount == 1 }
        store.removeImage(store.composerImages[0].id)
        await store.selectChannel("CHAN02")
        store.updateImgBBAPIKey("new-key")
        await images.finishUpload()
        await waitUntil { await images.deletionCount == 1 }
        await store.selectChannel("CHAN01")
        await waitUntil { store.composerImages.isEmpty }
        let deletions = await images.deletions
        XCTAssertEqual(deletions.first?.1, "original-key")
    }

    @MainActor
    func testLateUploadAfterSignOutIsCleanedUpWithoutRestoringDraft() async throws {
        let images = FakeImageService()
        await images.setSuspended(true)
        let store = await connected(FakeService(), imageService: images)
        store.updateImgBBAPIKey("key"); store.addImages([try temporaryImage()])
        await waitUntil { await images.pendingCount == 1 }
        store.signOut()
        await images.finishUpload()
        await waitUntil { await images.deletionCount == 1 }
        XCTAssertTrue(store.composerImages.isEmpty)
        XCTAssertNil(store.selectedChannelID)
    }

    @MainActor
    func testSignOutDuringSendDoesNotDeleteAnImageThatMayAlreadyBePosted() async throws {
        let service = FakeService(), images = FakeImageService(), store = await connected(service, imageService: images)
        store.updateImgBBAPIKey("key"); store.addImages([try temporaryImage()])
        await waitUntil { store.composerImages.first?.upload != nil }
        service.suspendSend = true
        let sending = Task { await store.send() }
        await waitUntil { service.pendingSend != nil }
        store.signOut()
        service.pendingSend?.resume(returning: service.message(id: 2, text: FakeImageService.result.url.absoluteString))
        await sending.value
        let deletions = await images.deletionCount
        XCTAssertEqual(deletions, 0)
        XCTAssertTrue(store.composerImages.isEmpty)
        XCTAssertTrue(store.messages.isEmpty)
    }

    @MainActor
    func testFailedImageDeletionCanBeRetried() async throws {
        let images = FakeImageService(), store = await connected(FakeService(), imageService: images)
        store.updateImgBBAPIKey("key"); store.addImages([try temporaryImage()])
        await waitUntil { store.composerImages.first?.upload != nil }
        let id = store.composerImages[0].id
        await images.setDeleteFailure(true)
        store.removeImage(id)
        await waitUntil { store.composerImages.first?.error != nil }
        XCTAssertFalse(store.canSend)
        await images.setDeleteFailure(false)
        store.retryImage(id)
        await waitUntil { store.composerImages.isEmpty }
        let deletions = await images.deletionCount
        XCTAssertEqual(deletions, 2)
    }

    @MainActor
    func testImageURLsCountAgainstMessageLimitAndFailedSendPreservesAttachment() async throws {
        let service = FakeService(), images = FakeImageService(), store = await connected(service, imageService: images)
        store.updateImgBBAPIKey("key"); store.addImages([try temporaryImage()])
        await waitUntil { store.composerImages.first?.upload != nil }
        store.draft = String(repeating: "a", count: 4000)
        XCTAssertFalse(store.canSend)
        store.draft = "with photo"; service.failSend = true
        await store.send()
        XCTAssertEqual(store.composerImages.count, 1)
        XCTAssertEqual(store.draft, "with photo")
        service.failSend = false
        await store.send()
        XCTAssertEqual(service.sendKeys[0], service.sendKeys[1])
        XCTAssertEqual(service.sentTexts[0], "with photo\n" + FakeImageService.result.url.absoluteString)
        XCTAssertTrue(store.composerImages.isEmpty)
    }

    @MainActor
    func testSearchIsScopedSortedAndDoesNotMarkTimelineRead() async {
        let service = FakeService(), store = await connected(service)
        service.searchResults = [service.message(id: 8), service.message(id: 3), service.message(id: 20, channel: "CHAN02")]
        store.openSearch()
        await store.markRead()
        XCTAssertTrue(service.readIDs.isEmpty, "Opening search must suspend automatic read receipts before submitting")
        store.searchQuery = " hello "
        await store.searchSelectedChannel()
        XCTAssertEqual(store.displayedMessages.map(\.id), [3, 8])
        XCTAssertEqual(store.messages.map(\.id), [1])
        XCTAssertEqual(service.searchCalls.first?.0, "CHAN01")
        XCTAssertEqual(service.searchCalls.first?.1, "hello")
        await store.markRead()
        XCTAssertTrue(service.readIDs.isEmpty)
        store.searchQuery = "edited query"
        XCTAssertNil(store.searchResults)
        await store.markRead()
        XCTAssertTrue(service.readIDs.isEmpty, "Editing search must not mark the restored timeline as read")
        store.closeSearch()
        XCTAssertEqual(store.displayedMessages.map(\.id), [1])
        await store.markRead()
        XCTAssertEqual(service.readIDs, [1])
    }

    @MainActor
    func testStaleSearchCannotReplaceNewQueryOrReopenAfterClose() async {
        let service = FakeService(), store = await connected(service)
        service.suspendSearch = true
        store.openSearch(); store.searchQuery = "first"
        let first = Task { await store.searchSelectedChannel() }
        await waitUntil { service.pendingSearches.count == 1 }
        store.searchQuery = "second"
        let second = Task { await store.searchSelectedChannel() }
        await waitUntil { service.pendingSearches.count == 2 }
        service.pendingSearches[1].resume(returning: [service.message(id: 9, text: "second")])
        await second.value
        service.pendingSearches[0].resume(returning: [service.message(id: 8, text: "first")])
        await first.value
        XCTAssertEqual(store.searchResults?.map(\.id), [9])
        store.searchQuery = "third"
        let third = Task { await store.searchSelectedChannel() }
        await waitUntil { service.pendingSearches.count == 3 }
        store.closeSearch()
        service.pendingSearches[2].resume(returning: [service.message(id: 10)])
        await third.value
        XCTAssertNil(store.searchResults)
        XCTAssertFalse(store.isSearching)
        XCTAssertFalse(store.isSearchOpen)
    }

    @MainActor
    func testSearchResponseIsDiscardedAfterChannelChangeOrSignOut() async {
        let service = FakeService(), store = await connected(service)
        service.suspendSearch = true
        store.openSearch(); store.searchQuery = "first"
        let search = Task { await store.searchSelectedChannel() }
        await waitUntil { service.pendingSearches.count == 1 }
        await store.selectChannel("CHAN02")
        service.pendingSearches[0].resume(returning: [service.message(id: 10)])
        await search.value
        XCTAssertFalse(store.isSearchOpen)
        XCTAssertNil(store.searchResults)
        XCTAssertTrue(store.displayedMessages.allSatisfy { $0.channel.id == "CHAN02" })
        store.openSearch(); store.searchQuery = "second"
        let searchAfter = Task { await store.searchSelectedChannel() }
        await waitUntil { service.pendingSearches.count == 2 }
        store.signOut()
        service.pendingSearches[1].resume(returning: [service.message(id: 11, channel: "CHAN02")])
        await searchAfter.value
        XCTAssertNil(store.searchResults)
        XCTAssertTrue(store.messages.isEmpty)
    }

    @MainActor
    func testSearchErrorsAndTooShortQueryAreVisibleAndRetryable() async {
        let service = FakeService(), store = await connected(service)
        store.openSearch(); store.searchQuery = "x"
        await store.searchSelectedChannel()
        XCTAssertTrue(service.searchCalls.isEmpty)
        XCTAssertNotNil(store.searchError)
        store.searchQuery = "test"; service.failSearch = true
        await store.searchSelectedChannel()
        XCTAssertNotNil(store.searchError)
        XCTAssertFalse(store.isSearching)
        service.failSearch = false
        await store.searchSelectedChannel()
        XCTAssertNil(store.searchError)
        XCTAssertEqual(store.searchResults, [])
    }

    @MainActor
    func testNotificationsRespectActiveReadingOwnMessagesDuplicatesAndTogglePersistence() async throws {
        let service = FakeService(), defaults = isolatedDefaults(), store = await connected(service, defaults: defaults)
        XCTAssertEqual(store.notificationTarget, .mentionsAndDirectMessages)
        XCTAssertTrue(store.notificationSoundEnabled)
        store.notificationTarget = .allMessages
        store.notificationSoundEnabled = false
        var notified: [Int] = []
        store.onNotify = { message, _ in notified.append(message.id) }
        func incoming(_ id: Int, channel: String = "CHAN01") -> Message {
            var message = service.message(id: id, channel: channel)
            message.profile = Profile(id: "OTHER", displayName: "Other")
            return message
        }
        store.receive(try event(incoming(2))) // Already reading.
        store.isActive = false
        store.receive(try event(incoming(3)))
        store.receive(try event(incoming(3)))
        store.receive(try event(incoming(4), name: "message_updated"))
        store.receive(try event(service.message(id: 5)))
        XCTAssertEqual(notified, [3])
        store.isActive = true; store.isAtBottom = false
        store.receive(try event(incoming(6)))
        store.isAtBottom = true
        store.receive(try event(incoming(7, channel: "CHAN02")))
        XCTAssertEqual(notified, [3, 6, 7])
        store.openSearch()
        store.receive(try event(incoming(8)))
        store.searchQuery = "editing query"
        store.receive(try event(incoming(9)))
        XCTAssertEqual(notified, [3, 6, 7, 8, 9], "An active search is not reading the selected timeline")
        store.closeSearch()
        store.receive(try event(incoming(10)))
        XCTAssertEqual(notified, [3, 6, 7, 8, 9])
        store.notificationsEnabled = false
        store.receive(try event(incoming(11, channel: "CHAN02")))
        XCTAssertEqual(notified, [3, 6, 7, 8, 9])
        let restored = await connected(service, defaults: defaults)
        XCTAssertFalse(restored.notificationsEnabled)
        XCTAssertEqual(restored.notificationTarget, .allMessages)
        XCTAssertFalse(restored.notificationSoundEnabled)
    }

    @MainActor
    func testNotificationMembershipPoliciesAndReadCursor() async throws {
        let service = FakeService()
        service.channels[0].membership?.notificationPolicy = "only_mentions"
        service.channels[0].membership?.latestReadMessageID = 4
        let store = await connected(service)
        store.isActive = false
        var notified: [Int] = []
        store.onNotify = { message, _ in notified.append(message.id) }
        func incoming(_ id: Int, mention: Bool = true) -> Message {
            var message = service.message(id: id, text: mention ? "<@USER01|tester> hello" : "ordinary")
            message.profile = Profile(id: "OTHER")
            return message
        }
        store.receive(try event(incoming(3)))
        store.receive(try event(incoming(5, mention: false)))
        store.receive(try event(incoming(6)))
        XCTAssertEqual(notified, [6])
        service.channels[0].membership?.disableNotification = true
        await store.refresh()
        store.receive(try event(incoming(7)))
        service.channels[0].membership?.disableNotification = false
        service.channels[0].membership?.muted = true
        await store.refresh()
        store.receive(try event(incoming(8)))
        service.channels[0].membership?.muted = false
        service.channels[0].membership?.notificationPolicy = "none"
        await store.refresh()
        store.receive(try event(incoming(9)))
        XCTAssertEqual(notified, [6])
    }
}
