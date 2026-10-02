import Foundation
import KokoroCore

public protocol WindowsChatService {
    func fetchProfile() async throws -> Profile
    func fetchChannels() async throws -> [Channel]
    func fetchMessages(channelID: String, before: Int?, after: Int?, limit: Int) async throws -> [Message]
    func fetchUnreadCount(channelID: String, after: Int, excludingProfileID: String) async throws -> Int
    func sendMessage(channelID: String, text: String, imageSignedIDs: [String], idempotentKey: String) async throws -> Message
    func markRead(membershipID: String, messageID: Int) async throws -> Membership
    func searchMessages(channelID: String, query: String) async throws -> [Message]
}
extension APIClient: WindowsChatService {}

public protocol WindowsImageService: Sendable {
    func uploadImage(data: Data, fileName: String, mimeType: String) async throws -> ImageUpload
}
extension APIClient: WindowsImageService {}

public struct WindowsComposerImage: Identifiable, Sendable {
    public let id: UUID
    public let fileName: String
    public let localURL: URL
    public fileprivate(set) var upload: ImageUpload?
    public fileprivate(set) var isUploading = true
    public fileprivate(set) var error: String?
}

public struct WindowsChannelSection: Identifiable {
    public let id: String
    public let title: String
    public let channels: [Channel]
}

/// UI independent state; every suspended operation is scoped to its account and channel.
@MainActor
public final class WindowsChatStore {
    public var onChange: (() -> Void)?
    public var onNotify: ((Message, Channel) -> Void)?
    public private(set) var channels: [Channel] = []
    public private(set) var messages: [Message] = []
    public private(set) var profile: Profile?
    public private(set) var selectedChannelID: String?
    public private(set) var isSigningIn = false
    public private(set) var isLoading = false
    public private(set) var isSending = false
    public private(set) var hasMore = false
    public private(set) var error: String?
    public private(set) var connectionLabel = "未接続"
    public var isActive = true
    public var isAtBottom = true
    public var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: "windows.notifications.enabled"); onChange?() }
    }
    public var notificationTarget: DesktopNotificationTarget {
        didSet { defaults.set(notificationTarget.rawValue, forKey: "windows.notifications.target"); onChange?() }
    }
    public var notificationSoundEnabled: Bool {
        didSet { defaults.set(notificationSoundEnabled, forKey: "windows.notifications.soundEnabled"); onChange?() }
    }
    public var serverAddress: String { serverURL?.absoluteString ?? "https://kokoro.io" }
    public private(set) var pinnedChannelIDs: Set<String> = []
    public private(set) var isSearchOpen = false
    public var searchQuery = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            searchRequestID = UUID(); isSearching = false; searchResults = nil; searchError = nil
        }
    }
    public private(set) var searchResults: [Message]?
    public private(set) var isSearching = false
    public private(set) var searchError: String?
    public var isShowingSearchResults: Bool { searchResults != nil }
    public var displayedMessages: [Message] { (searchResults ?? messages).map { imageFallback.applying(to: $0) } }
    public var composerImages: [WindowsComposerImage] { selectedChannelID.flatMap { imagesByChannel[$0] } ?? [] }
    public var composedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var imageSignedIDs: [String] { composerImages.compactMap { $0.upload?.signedID } }
    public var channelSections: [WindowsChannelSection] {
        let sorted = channels.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return [
            .init(id: "pinned", title: "ピン留め", channels: sorted.filter { isPinned($0.id) }),
            .init(id: "public", title: "チャンネル", channels: sorted.filter { $0.kind != "private_channel" && !$0.isDirectMessage }),
            .init(id: "private", title: "プライベート", channels: sorted.filter { $0.kind == "private_channel" }),
            .init(id: "direct", title: "ダイレクトメッセージ", channels: sorted.filter(\.isDirectMessage))
        ]
    }
    public var draft: String {
        get { selectedChannelID.flatMap { drafts[$0] } ?? "" }
        set { if let id = selectedChannelID { drafts[id] = newValue } }
    }
    public var selectedChannel: Channel? { channels.first { $0.id == selectedChannelID } }
    public var canSend: Bool {
        profile != nil && selectedChannel?.membership?.canPost == true && !isSending
        && (!composedDraft.isEmpty || !composerImages.isEmpty) && composedDraft.unicodeScalars.count <= 4000
        && composerImages.allSatisfy { !$0.isUploading && $0.error == nil && $0.upload != nil }
    }
    private let makeClient: (URL, String) -> any WindowsChatService
    private let usesRealtime: Bool
    private let defaults: UserDefaults
    private let imageServiceOverride: (any WindowsImageService)?
    private var imageService: (any WindowsImageService)?
    private var imageUploadTasks: [UUID: Task<Void, Never>] = [:]
    private let realtime = RealtimeClient()
    private var client: (any WindowsChatService)?
    private var serverURL: URL?
    private var pinsKey: String?
    private var sessionID = UUID()
    private var selectionID = UUID()
    private var drafts: [String: String] = [:]
    private var imagesByChannel: [String: [WindowsComposerImage]] = [:]
    private var searchRequestID = UUID()
    private var imageFallback = UploadedImageFallback()
    private var imageFallbackTask: Task<Void, Never>?
    private var imageFallbackRequestID: UUID?
    private var pendingSends: [String: (text: String, signedIDs: [String], key: String)] = [:]
    private var readCursors: [String: Int] = [:]
    private var readInFlight: Set<String> = []
    private var readFailures: [String: Date] = [:]
    private var revisions: [Int: Int] = [:]
    private var knownMessageIDs: Set<Int> = []
    private var revision = 0
    private var refreshInFlight = false

    public init(usesRealtime: Bool = true, defaults: UserDefaults = .standard,
                imageService: (any WindowsImageService)? = nil,
                makeClient: @escaping (URL, String) -> any WindowsChatService = { APIClient(baseURL: $0, token: $1) }) {
        self.makeClient = makeClient
        self.usesRealtime = usesRealtime
        self.defaults = defaults
        self.imageServiceOverride = imageService
        self.notificationsEnabled = defaults.object(forKey: "windows.notifications.enabled") as? Bool ?? true
        self.notificationSoundEnabled = defaults.object(forKey: "windows.notifications.soundEnabled") as? Bool ?? true
        self.notificationTarget = DesktopNotificationTarget(rawValue: defaults.string(forKey: "windows.notifications.target") ?? "") ?? .mentionsAndDirectMessages
        realtime.onEvent = { [weak self] in self?.receive($0) }
        realtime.onHTML = { [weak self] in self?.receiveImageHTML($0) }
        realtime.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .connected:
                self.connectionLabel = "接続済み"
                self.resetImageFallback()
                Task { await self.refresh() }
            case .connecting: self.connectionLabel = "接続中…"
            case .reconnecting: self.connectionLabel = "再接続中…"
            case .disconnected: self.connectionLabel = "未接続"
            case .failed(let message): self.connectionLabel = message
            }
            self.onChange?()
        }
    }

    @discardableResult
    public func signIn(server: String, token: String) async -> Bool {
        signOut()
        let session = sessionID
        isSigningIn = true
        onChange?()
        defer { if sessionID == session { isSigningIn = false; onChange?() } }
        do {
            let url = try APIClient.validatedServerURL(server)
            // Validate token before either HTTP or WebSocket sees it.
            _ = try ActionCableProtocol.request(baseURL: url, accessToken: token)
            let service = makeClient(url, token)
            let user = try await service.fetchProfile()
            let joined = try await service.fetchChannels()
            guard sessionID == session else { return false }
            client = service
            imageService = imageServiceOverride ?? APIClient(baseURL: url, token: token)
            serverURL = url
            profile = user
            pinsKey = "windows.pinnedChannels.\(url.absoluteString).\(user.id)"
            pinnedChannelIDs = Set(defaults.stringArray(forKey: pinsKey!) ?? [])
            channels = joined.filter { !$0.archived && $0.membership?.visible != false }
            connectionLabel = "接続済み"
            if usesRealtime {
                realtime.connect(baseURL: url, accessToken: token, channelIDs: channels.map(\.id))
            }
            if let first = channels.first { await selectChannel(first.id) }
            return sessionID == session
        } catch {
            if sessionID == session { self.error = error.localizedDescription }
            return false
        }
    }

    public func signOut() {
        sessionID = UUID()
        selectionID = UUID()
        realtime.disconnect()
        resetImageFallback()
        resetSearch()
        serverURL = nil; pinsKey = nil; pinnedChannelIDs = []
        imageUploadTasks.values.forEach { $0.cancel() }
        imageUploadTasks = [:]
        imageService = nil
        client = nil; profile = nil; channels = []; messages = []; selectedChannelID = nil
        drafts = [:]; imagesByChannel = [:]; pendingSends = [:]; readCursors = [:]; readInFlight = []
        readFailures = [:]
        revisions = [:]; knownMessageIDs = []; revision = 0; refreshInFlight = false
        isSigningIn = false; isLoading = false; isSending = false; hasMore = false
        error = nil; connectionLabel = "未接続"
        onChange?()
    }

    public func reportError(_ message: String) { error = message; onChange?() }
    public func clearError() { error = nil; onChange?() }

    public func isPinned(_ id: String) -> Bool { pinnedChannelIDs.contains(id) }

    public func togglePin(_ id: String) {
        guard let pinsKey, channels.contains(where: { $0.id == id }) else { return }
        if !pinnedChannelIDs.insert(id).inserted { pinnedChannelIDs.remove(id) }
        defaults.set(pinnedChannelIDs.sorted(), forKey: pinsKey)
        onChange?()
    }

    public func addImages(_ urls: [URL]) {
        guard let id = selectedChannelID, selectedChannel?.membership?.canPost == true,
              !isSending, imageService != nil else { return }
        for url in urls {
            guard url.isFileURL else { reportError(ImageUploadError.invalidImage.localizedDescription); continue }
            let image = WindowsComposerImage(id: UUID(), fileName: url.lastPathComponent, localURL: url)
            imagesByChannel[id, default: []].append(image)
            uploadImage(image.id, in: id)
        }
        onChange?()
    }

    public func retryImage(_ id: UUID) {
        guard !isSending, let channelID = selectedChannelID,
              let image = imagesByChannel[channelID]?.first(where: { $0.id == id }),
              !image.isUploading, image.error != nil else { return }
        updateImage(id, in: channelID) { $0.isUploading = true; $0.error = nil }
        uploadImage(id, in: channelID)
    }

    public func removeImage(_ id: UUID) {
        guard !isSending, let channelID = selectedChannelID else { return }
        imageUploadTasks.removeValue(forKey: id)?.cancel()
        imagesByChannel[channelID]?.removeAll { $0.id == id }
        // Unattached server uploads are automatically purged; there is no delete API.
        onChange?()
    }

    public func moveImage(_ id: UUID, to index: Int) {
        guard !isSending, let channelID = selectedChannelID,
              var images = imagesByChannel[channelID],
              let previous = images.firstIndex(where: { $0.id == id }),
              images.indices.contains(index), previous != index else { return }
        let image = images.remove(at: previous)
        images.insert(image, at: index)
        imagesByChannel[channelID] = images
        onChange?()
    }

    private func uploadImage(_ id: UUID, in channelID: String) {
        guard let image = imagesByChannel[channelID]?.first(where: { $0.id == id }),
              let service = imageService else { return }
        let session = sessionID
        imageUploadTasks[id] = Task { [weak self] in
            defer {
                if self?.sessionID == session { self?.imageUploadTasks[id] = nil }
            }
            do {
                let data = try await Task.detached(priority: .utility) {
                    let data = try Data(contentsOf: image.localURL)
                    guard !data.isEmpty else { throw ImageUploadError.invalidImage }
                    return data
                }.value
                let mime = Self.imageMIMEType(image.localURL.pathExtension)
                try Task.checkCancellation()
                guard self?.sessionID == session else { return }
                let upload = try await service.uploadImage(data: data, fileName: image.fileName, mimeType: mime)
                try Task.checkCancellation()
                guard let self, self.sessionID == session else { return }
                self.updateImage(id, in: channelID) { $0.upload = upload; $0.isUploading = false; $0.error = nil }
            } catch {
                guard !Task.isCancelled, let self, self.sessionID == session else { return }
                self.updateImage(id, in: channelID) { $0.isUploading = false; $0.error = error.localizedDescription }
            }
        }
    }

    private static func imageMIMEType(_ extensionName: String) -> String {
        switch extensionName.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "avif": return "image/avif"
        default: return "application/octet-stream"
        }
    }

    private func updateImage(_ id: UUID, in channelID: String, _ change: (inout WindowsComposerImage) -> Void) {
        guard let index = imagesByChannel[channelID]?.firstIndex(where: { $0.id == id }) else { return }
        change(&imagesByChannel[channelID]![index]); onChange?()
    }

    public func openSearch() { isSearchOpen = true; onChange?() }
    public func closeSearch() { resetSearch(); resetImageFallback(preservingResolvedImages: true); resolveMissingImages(); onChange?() }

    private func resetSearch() {
        searchRequestID = UUID(); searchQuery = ""; searchResults = nil
        searchError = nil; isSearching = false; isSearchOpen = false
    }

    public func searchSelectedChannel() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSearchOpen, let client, let id = selectedChannelID else { return }
        searchRequestID = UUID()
        let request = searchRequestID, session = sessionID, selection = selectionID, startedRevision = revision
        guard query.count >= 2 else {
            isSearching = false; searchResults = nil; searchError = "検索語は 2 文字以上で入力してください。"; onChange?(); return
        }
        resetImageFallback(preservingResolvedImages: true)
        isSearching = true; searchResults = []; searchError = nil; onChange?()
        defer { if request == searchRequestID && session == sessionID { isSearching = false; onChange?() } }
        do {
            let found = try await client.searchMessages(channelID: id, query: query)
            guard request == searchRequestID, session == sessionID, selection == selectionID, isSearchOpen else { return }
            let eligible = found.filter { $0.channel.id == id && !$0.isDeleted }
            searchResults = TimelineRules.merge([], with: eligible).map { message in
                guard (revisions[message.id] ?? 0) > startedRevision else { return message }
                return messages.first { $0.id == message.id } ?? message
            }.filter { !$0.isDeleted }
            knownMessageIDs.formUnion(eligible.map(\.id))
            resolveMissingImages()
        } catch {
            if request == searchRequestID && session == sessionID && selection == selectionID { searchError = error.localizedDescription }
        }
    }

    public func selectChannel(_ id: String) async {
        guard id != selectedChannelID, channels.contains(where: { $0.id == id }) else { return }
        resetSearch()
        resetImageFallback()
        selectedChannelID = id; selectionID = UUID(); messages = []; hasMore = false
        isLoading = false; isAtBottom = true; error = nil
        onChange?()
        await loadMessages()
    }

    public func loadMessages(older: Bool = false) async {
        guard let client, let id = selectedChannelID, !isLoading else { return }
        let session = sessionID, selection = selectionID, startedRevision = revision
        let before = older ? messages.first?.id : nil
        if older && before == nil { return }
        isLoading = true; error = nil; onChange?()
        defer { if session == sessionID && selection == selectionID { isLoading = false; onChange?() } }
        do {
            let page = try await client.fetchMessages(channelID: id, before: before, after: nil, limit: 50)
            guard session == sessionID, selection == selectionID else { return }
            merge(page, since: startedRevision)
            hasMore = page.count == 50
        } catch {
            if session == sessionID && selection == selectionID { self.error = error.localizedDescription }
        }
    }

    public func send() async {
        guard canSend, let client, let id = selectedChannelID else { return }
        let session = sessionID, text = composedDraft, draftSnapshot = draft, signedIDs = imageSignedIDs
        let sentImageIDs = Set(composerImages.map(\.id))
        let key = pendingSends[id].flatMap { $0.text == text && $0.signedIDs == signedIDs ? $0.key : nil } ?? UUID().uuidString.lowercased()
        pendingSends[id] = (text, signedIDs, key)
        isSending = true; error = nil; onChange?()
        defer { if session == sessionID { isSending = false; onChange?() } }
        do {
            let message = try await client.sendMessage(channelID: id, text: text, imageSignedIDs: signedIDs, idempotentKey: key)
            guard session == sessionID else { return }
            pendingSends[id] = nil
            if drafts[id] == draftSnapshot { drafts[id] = "" }
            imagesByChannel[id]?.removeAll { sentImageIDs.contains($0.id) }
            if selectedChannelID == id { merge([message], since: revision) }
        } catch {
            if session == sessionID { self.error = error.localizedDescription }
        }
    }

    public func refresh() async {
        guard let client, !refreshInFlight else { return }
        let session = sessionID, selection = selectionID, startedRevision = revision
        let id = selectedChannelID, tail = messages.last?.id
        refreshInFlight = true
        defer { if session == sessionID { refreshInFlight = false; onChange?() } }
        do {
            var joined = try await client.fetchChannels()
            guard session == sessionID else { return }
            // The server's unread_count is not reset by markRead. Recompute from its cursor.
            if let profile {
                for index in joined.indices {
                    let channel = joined[index]
                    let cursor = max(channel.membership?.latestReadMessageID ?? 0, readCursors[channel.id] ?? 0)
                    if cursor > 0 {
                        joined[index].membership?.unreadCount = try await client.fetchUnreadCount(
                            channelID: channel.id, after: cursor, excludingProfileID: profile.id)
                        guard session == sessionID else { return }
                    }
                }
            }
            channels = joined.filter { !$0.archived && $0.membership?.visible != false }
            realtime.updateSubscriptions(channelIDs: channels.map(\.id))
            guard selection == selectionID else { return }
            guard let id, channels.contains(where: { $0.id == id }) else {
                selectedChannelID = nil; messages = []; selectionID = UUID()
                isLoading = false; hasMore = false; resetSearch(); resetImageFallback()
                if let first = channels.first { await selectChannel(first.id) }
                return
            }
            var before: Int?
            repeat {
                let page = try await client.fetchMessages(channelID: id, before: before, after: tail, limit: 100)
                guard session == sessionID, selection == selectionID else { return }
                merge(page, since: startedRevision)
                guard tail != nil, page.count == 100, let minimum = page.map(\.id).min(),
                      before == nil || minimum < before! else { break }
                before = minimum
            } while true
            error = nil
        } catch {
            if session == sessionID { self.error = error.localizedDescription }
        }
    }

    public func markRead() async {
        guard isActive, isAtBottom, !isLoading, !isSearchOpen, let client, let channel = selectedChannel,
              let membership = channel.membership, let messageID = messages.last?.id,
              messageID > max(readCursors[channel.id] ?? 0, membership.latestReadMessageID),
              Date().timeIntervalSince(readFailures[channel.id] ?? .distantPast) > 15,
              !readInFlight.contains(channel.id) else { return }
        let session = sessionID
        readInFlight.insert(channel.id)
        defer { if session == sessionID { readInFlight.remove(channel.id) } }
        do {
            _ = try await client.markRead(membershipID: membership.id, messageID: messageID)
            guard session == sessionID else { return }
            readFailures[channel.id] = nil
            readCursors[channel.id] = max(readCursors[channel.id] ?? 0, messageID)
            if let index = channels.firstIndex(where: { $0.id == channel.id }) {
                channels[index].membership?.latestReadMessageID = messageID
                // Don't clear newer events received while the request was suspended.
                if (channels[index].latestMessageID ?? 0) <= messageID {
                    channels[index].membership?.unreadCount = 0
                }
            }
            onChange?()
        } catch {
            if session == sessionID {
                readFailures[channel.id] = Date()
                self.error = error.localizedDescription; onChange?()
            }
        }
    }

    public func receive(_ event: RealtimeEvent) {
        guard profile != nil else { return }
        if event.name == "message_created" || event.name == "message_updated",
           let message = try? APIJSON.decoder().decode(Message.self, from: event.payload) {
            guard let index = channels.firstIndex(where: { $0.id == message.channel.id }) else { return }
            let previouslySeen = !knownMessageIDs.insert(message.id).inserted
            revision += 1; revisions[message.id] = revision
            imageFallback.invalidate(messageID: message.id)
            if message.channel.id == selectedChannelID { messages = TimelineRules.merge(messages, with: [message]) }
            if let resultIndex = searchResults?.firstIndex(where: { $0.id == message.id }) {
                if message.isDeleted { searchResults?.remove(at: resultIndex) } else { searchResults?[resultIndex] = message }
            }
            channels[index].latestMessageID = max(channels[index].latestMessageID ?? 0, message.id)
            if event.name == "message_created", !previouslySeen, !message.isDeleted, message.profile.id != profile?.id,
               message.id > max(channels[index].membership?.latestReadMessageID ?? 0, readCursors[message.channel.id] ?? 0) {
                channels[index].membership?.unreadCount += 1
                notifyIfNeeded(message, in: channels[index])
            }
            resolveMissingImages()
            onChange?()
        } else if event.name.contains("channel") || event.name.contains("membership") {
            Task { await refresh() }
        }
    }

    private func merge(_ page: [Message], since startedRevision: Int) {
        // A response which started before an event must not overwrite that newer event.
        let currentIDs = Set(messages.map(\.id))
        let safe = page.filter { !currentIDs.contains($0.id) || (revisions[$0.id] ?? 0) <= startedRevision }
        messages = TimelineRules.merge(messages, with: safe)
        knownMessageIDs.formUnion(page.map(\.id))
        resolveMissingImages()
    }

    private func notifyIfNeeded(_ message: Message, in channel: Channel) {
        guard notificationsEnabled, let membership = channel.membership,
              membership.visible, !membership.disableNotification, !membership.muted else { return }
        let target: DesktopNotificationTarget
        switch membership.notificationPolicy {
        case "all_messages": target = notificationTarget
        case "only_mentions": target = .mentionsAndDirectMessages
        default: return
        }
        let isReading = isActive && isAtBottom && !isLoading && !isSearchOpen && selectedChannelID == channel.id
        guard TimelineRules.shouldNotify(message: message, channel: channel, currentProfileID: profile?.id,
                                         isReadingChannel: isReading, target: target) else { return }
        onNotify?(message, channel)
    }

    private func resolveMissingImages() {
        guard usesRealtime, connectionLabel == "接続済み", imageFallbackTask == nil,
              let request = imageFallback.nextRequest(in: searchResults ?? messages) else { return }
        let session = sessionID, requestID = UUID()
        imageFallbackRequestID = requestID
        imageFallbackTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.realtime.resumeMessages(channelID: request.channelID, afterID: request.afterID)
                try await Task.sleep(for: .seconds(15))
            } catch { if Task.isCancelled { return } }
            guard self.sessionID == session, self.imageFallbackRequestID == requestID else { return }
            self.imageFallback.failPendingRequest(); self.imageFallbackTask = nil; self.imageFallbackRequestID = nil
        }
    }

    private func receiveImageHTML(_ html: String) {
        guard let serverURL, imageFallback.pendingChannelID == selectedChannelID else { return }
        let records = HotwireImageParser.parse(html, baseURL: serverURL)
        guard imageFallback.accept(records, currentMessages: searchResults ?? messages) else { return }
        imageFallbackTask?.cancel(); imageFallbackTask = nil; imageFallbackRequestID = nil
        resolveMissingImages(); onChange?()
    }

    private func resetImageFallback(preservingResolvedImages: Bool = false) {
        imageFallbackTask?.cancel(); imageFallbackTask = nil; imageFallbackRequestID = nil
        if preservingResolvedImages { imageFallback.cancelPendingRequest() }
        else { imageFallback.reset() }
    }
}
