import AppKit
import Combine
import KokoroCore

@MainActor
final class ChatStore: ObservableObject {
    @Published var channels: [Channel] = []
    @Published var selectedChannelID: String?
    @Published var messages: [Message] = []
    @Published var isLoadingMessages = false
    @Published var isLoadingMore = false
    @Published var hasMoreMessages = false
    @Published var isSending = false
    @Published var errorMessage: String?
    @Published var draft = ""
    @Published var channelSearch = ""
    @Published var profile: Profile?
    @Published var connectionLabel = "未接続"
    @Published var isConnected = false
    @Published var unreadOnly = false
    @Published var isAtBottom = true
    @Published var isSignedIn = false
    @Published var isSigningIn = false
    @Published var serverURL = "https://kokoro.io"
    @Published var signInError: String?

    let notifications: NotificationService
    private var client: APIClient?
    private let realtime = RealtimeClient()
    private var credential: Credential?
    private var sessionID = UUID()
    private var signInAttemptID = UUID()
    private var selectionID = UUID()
    private var drafts: [String: String] = [:]
    private var cache: [String: [Message]] = [:]
    private var confirmedTails: [String: Int] = [:]
    private var pendingSends: [String: (text: String, key: String)] = [:]
    private var seenEvents: Set<Int> = []
    private var eventRevision = 0
    private var messageRevisions: [Int: Int] = [:]
    private var readTasks: [String: Task<Void, Never>] = [:]
    private var activityObserver: NSObjectProtocol?
    private var refreshTask: Task<Void, Never>?
    private var imageFallback = UploadedImageFallback()
    private var imageFallbackTask: Task<Void, Never>?
    private var imageFallbackRequestID: UUID?

    init(notifications: NotificationService) {
        self.notifications = notifications
        notifications.onOpenChannel = { [weak self] id in
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
            self?.selectChannel(id)
        }
        realtime.onEvent = { [weak self] event in self?.receive(event) }
        realtime.onHTML = { [weak self] html in self?.receiveImageHTML(html) }
        realtime.onStateChange = { [weak self] state in self?.setConnectionState(state) }
        activityObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                await self?.markSelectedChannelRead()
                self?.refresh()
            }
        }
    }

    var selectedChannel: Channel? { channels.first { $0.id == selectedChannelID } }
    var filteredChannels: [Channel] {
        channels.filter { channel in
            (!unreadOnly || channel.unreadCount > 0) &&
            (channelSearch.isEmpty || channel.name.localizedCaseInsensitiveContains(channelSearch))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var totalUnreadCount: Int { channels.reduce(0) { $0 + $1.unreadCount } }

    func restoreSession() async {
        do {
            if let saved = try CredentialStore.load() {
                serverURL = saved.baseURL.absoluteString
                await signIn(server: serverURL, token: saved.token, persist: false)
            }
        } catch { signInError = error.localizedDescription }
    }

    func signIn(server: String, token: String, persist: Bool = true) async {
        guard !isSigningIn else { return }
        guard let url = Self.validatedServerURL(server), !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            signInError = "HTTPSのサーバーURLとアクセストークンを入力してください。ローカル開発ではHTTPも使えます。"
            return
        }
        isSigningIn = true
        let attempt = UUID()
        signInAttemptID = attempt
        signInError = nil
        defer { if signInAttemptID == attempt { isSigningIn = false } }
        let candidate = Credential(baseURL: url, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        let api = APIClient(baseURL: url, token: candidate.token)
        do {
            async let fetchedProfile = api.fetchProfile()
            async let fetchedChannels = api.fetchChannels()
            let (user, memberships) = try await (fetchedProfile, fetchedChannels)
            let counted = try await accurateUnreadCounts(memberships, api: api, profileID: user.id)
            guard signInAttemptID == attempt else { return }
            if persist { try CredentialStore.save(candidate) }
            resetSession()
            credential = candidate
            client = api
            profile = user
            serverURL = url.absoluteString
            channels = normalize(counted)
            isSignedIn = true
            realtime.connect(baseURL: url, accessToken: candidate.token, channelIDs: channels.map(\.id))
            if let first = channels.first { selectChannel(first.id) }
            await notifications.refreshAuthorizationStatus()
        } catch { if signInAttemptID == attempt { signInError = error.localizedDescription } }
    }

    static func validatedServerURL(_ input: String) -> URL? {
        try? APIClient.validatedServerURL(input)
    }

    func selectChannel(_ id: String) {
        guard channels.contains(where: { $0.id == id }) else { return }
        if let previous = selectedChannelID { drafts[previous] = draft }
        selectedChannelID = id
        draft = drafts[id] ?? ""
        selectionID = UUID()
        showCachedMessages(in: id)
        isAtBottom = true
        isLoadingMore = false
        let selection = selectionID
        let session = sessionID
        isLoadingMessages = messages.isEmpty
        Task { [weak self] in
            guard let self, let api = self.client else { return }
            do {
                let firstPageCount = try await self.synchronizeChannel(id, api: api, session: session)
                guard self.sessionID == session else { return }
                guard self.selectionID == selection else { return }
                self.showCachedMessages(in: id)
                self.hasMoreMessages = firstPageCount == 50
                self.isLoadingMessages = false
                await self.markSelectedChannelRead()
            } catch {
                guard self.sessionID == session, self.selectionID == selection else { return }
                self.isLoadingMessages = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func loadOlderMessages() {
        guard !isLoadingMore, !isLoadingMessages, hasMoreMessages, let api = client,
              let id = selectedChannelID, let first = messages.first else { return }
        isLoadingMore = true
        let selection = selectionID
        let session = sessionID
        let revision = eventRevision
        Task {
            do {
                let page = try await api.fetchMessages(channelID: id, before: first.id)
                guard self.sessionID == session else { return }
                self.mergeREST(page, channelID: id, startedAt: revision)
                guard self.selectionID == selection else { return }
                self.showCachedMessages(in: id)
                self.hasMoreMessages = page.count == 50
                self.isLoadingMore = false
            } catch {
                guard self.sessionID == session, self.selectionID == selection else { return }
                self.isLoadingMore = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func sendMessage() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.unicodeScalars.count <= 4000, !isSending, let channel = selectedChannel else { return }
        guard let api = client else { return }
        let pending = pendingSends[channel.id]
        let key = pending?.text == text ? pending!.key : UUID().uuidString.lowercased()
        pendingSends[channel.id] = (text, key)
        isSending = true
        let session = sessionID
        let originalDraft = draft
        let revision = eventRevision
        Task {
            do {
                let message = try await api.sendMessage(channelID: channel.id, text: text, idempotentKey: key)
                guard self.sessionID == session else { return }
                self.mergeREST([message], channelID: channel.id, startedAt: revision)
                self.pendingSends[channel.id] = nil
                if self.selectedChannelID == channel.id {
                    self.showCachedMessages(in: channel.id)
                    if self.draft == originalDraft { self.draft = ""; self.drafts[channel.id] = "" }
                    self.isAtBottom = true
                } else if self.drafts[channel.id] == originalDraft { self.drafts[channel.id] = "" }
                self.isSending = false
                await self.markSelectedChannelRead()
            } catch {
                guard self.sessionID == session else { return }
                self.isSending = false
                self.errorMessage = error.localizedDescription + " 入力内容は保持されています。同じ内容を再送すると重複投稿を防ぎます。"
            }
        }
    }

    func markSelectedChannelRead() async {
        guard NSApp.isActive, isAtBottom, let api = client, let channel = selectedChannel,
              let membership = channel.membership, let latest = messages.last?.id,
              latest > membership.latestReadMessageID, readTasks[channel.id] == nil else { return }
        let session = sessionID
        let task = Task { [weak self] in
            var succeeded = false
            do {
                _ = try await api.markRead(membershipID: membership.id, messageID: latest)
                guard let self, self.sessionID == session else { return }
                if let index = self.channels.firstIndex(where: { $0.id == channel.id }) {
                    self.channels[index].membership?.latestReadMessageID = latest
                    self.channels[index].membership?.unreadCount = (self.cache[channel.id] ?? []).filter { $0.id > latest && $0.profile.id != self.profile?.id }.count
                }
                succeeded = true
            } catch {
                // Reading never discards the timeline. A later activation retries this boundary.
            }
            guard let self, self.sessionID == session else { return }
            self.readTasks[channel.id] = nil
            if succeeded, self.selectedChannelID == channel.id, (self.messages.last?.id ?? 0) > latest {
                await self.markSelectedChannelRead()
            }
        }
        readTasks[channel.id] = task
        await task.value
    }

    func refresh() {
        guard isSignedIn, refreshTask == nil, let api = client else { return }
        if case .failed = realtime.state { realtime.reconnect() }
        let session = sessionID
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.sessionID == session { self.refreshTask = nil } }
            do {
                let memberships = try await api.fetchChannels()
                let updated = try await self.accurateUnreadCounts(memberships, api: api, profileID: self.profile?.id ?? "")
                guard self.sessionID == session else { return }
                self.channels = self.normalize(updated)
                if let pendingChannel = self.imageFallback.pendingChannelID,
                   !self.channels.contains(where: { $0.id == pendingChannel }) {
                    self.resetImageFallback()
                }
                self.realtime.updateSubscriptions(channelIDs: self.channels.map(\.id))
                if let id = self.selectedChannelID, self.channels.contains(where: { $0.id == id }) {
                    _ = try await self.synchronizeChannel(id, api: api, session: session)
                    guard self.sessionID == session else { return }
                    if self.selectedChannelID == id {
                        self.showCachedMessages(in: id)
                        await self.markSelectedChannelRead()
                    }
                } else if let first = self.channels.first { self.selectChannel(first.id) }
                else { self.selectedChannelID = nil; self.messages = [] }
            } catch {
                guard self.sessionID == session, !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Only REST-confirmed tails are boundaries: a newer socket event must not hide a gap.
    private func synchronizeChannel(_ id: String, api: APIClient, session: UUID) async throws -> Int {
        let boundary = confirmedTails[id]
        let revision = eventRevision
        var before: Int?
        var gathered: [Message] = []
        var firstPageCount = 0
        repeat {
            try Task.checkCancellation()
            let page = try await api.fetchMessages(channelID: id, before: before)
            guard sessionID == session else { throw CancellationError() }
            if before == nil { firstPageCount = page.count }
            gathered += page
            guard let minimum = page.map(\.id).min(), page.count == 50,
                  let boundary, minimum > boundary else { break }
            before = minimum
        } while true
        mergeREST(gathered, channelID: id, startedAt: revision)
        if let tail = gathered.map(\.id).max() { confirmedTails[id] = max(confirmedTails[id] ?? 0, tail) }
        return firstPageCount
    }

    private func mergeREST(_ incoming: [Message], channelID: String, startedAt revision: Int) {
        let eligible = incoming.filter { (messageRevisions[$0.id] ?? 0) <= revision }
        cache[channelID] = TimelineRules.merge(cache[channelID] ?? [], with: eligible)
    }

    private func showCachedMessages(in channelID: String) {
        messages = (cache[channelID] ?? []).map { imageFallback.applying(to: $0) }
        resolveMissingImages()
    }

    private func resolveMissingImages() {
        guard isConnected, imageFallbackTask == nil, let id = selectedChannelID,
              let request = imageFallback.nextRequest(in: cache[id] ?? []) else { return }
        let session = sessionID
        let requestID = UUID()
        imageFallbackRequestID = requestID
        imageFallbackTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.realtime.resumeMessages(channelID: request.channelID, afterID: request.afterID)
                try await Task.sleep(for: .seconds(15))
            } catch {
                if Task.isCancelled { return }
            }
            guard self.sessionID == session, self.imageFallbackRequestID == requestID else { return }
            self.imageFallback.failPendingRequest()
            self.imageFallbackTask = nil
            self.imageFallbackRequestID = nil
        }
    }

    private func receiveImageHTML(_ html: String) {
        guard let channelID = imageFallback.pendingChannelID, let baseURL = credential?.baseURL,
              channels.contains(where: { $0.id == channelID }) else { return }
        let records = HotwireImageParser.parse(html, baseURL: baseURL)
        guard imageFallback.accept(records, currentMessages: cache[channelID] ?? []) else { return }
        imageFallbackTask?.cancel()
        imageFallbackTask = nil
        imageFallbackRequestID = nil
        if let selectedChannelID { showCachedMessages(in: selectedChannelID) }
    }

    private func resetImageFallback() {
        imageFallbackTask?.cancel()
        imageFallbackTask = nil
        imageFallbackRequestID = nil
        imageFallback.reset()
    }

    /// The server's REST read endpoint does not reset unread_count. Count after its cursor.
    private func accurateUnreadCounts(_ incoming: [Channel], api: APIClient, profileID: String) async throws -> [Channel] {
        var output = incoming
        let pending = incoming.indices.filter { index in
            let channel = incoming[index]
            return channel.unreadCount > 0 && (channel.latestMessageID ?? 0) > (channel.membership?.latestReadMessageID ?? 0)
        }
        try await withThrowingTaskGroup(of: (Int, Int).self) { group in
            var iterator = pending.makeIterator()
            func add(_ index: Int) {
                let channel = incoming[index]
                group.addTask {
                    let count = try await api.fetchUnreadCount(channelID: channel.id, after: channel.membership?.latestReadMessageID ?? 0, excludingProfileID: profileID)
                    return (index, count)
                }
            }
            for _ in 0..<4 { if let index = iterator.next() { add(index) } }
            while let (index, count) = try await group.next() {
                output[index].membership?.unreadCount = count
                if let next = iterator.next() { add(next) }
            }
        }
        return output
    }

    private func receive(_ event: RealtimeEvent) {
        if event.name == "message_created" || event.name == "message_updated" {
            do {
                let message = try APIJSON.decoder().decode(Message.self, from: event.payload)
                let id = message.channel.id
                guard let index = channels.firstIndex(where: { $0.id == id }) else { refresh(); return }
                eventRevision += 1
                messageRevisions[message.id] = eventRevision
                imageFallback.invalidate(messageID: message.id)
                let known = cache[id]?.contains(where: { $0.id == message.id }) == true
                cache[id] = TimelineRules.merge(cache[id] ?? [], with: [message])
                if selectedChannelID == id { showCachedMessages(in: id) }
                channels[index].latestMessageID = max(channels[index].latestMessageID ?? 0, message.id)
                let isNew = event.name == "message_created" && !known && seenEvents.insert(message.id).inserted
                let isReading = selectedChannelID == id && isAtBottom && NSApp.isActive
                if isNew {
                    if message.profile.id != profile?.id && message.id > (channels[index].membership?.latestReadMessageID ?? 0) {
                        channels[index].membership?.unreadCount += 1
                    }
                    if TimelineRules.shouldNotify(message: message, channel: channels[index], currentProfileID: profile?.id, isReadingChannel: isReading) {
                        notifications.schedule(messageID: message.id, channelID: id, channelName: channels[index].name, sender: message.displayName, body: message.text)
                    }
                }
                if isReading { Task { await markSelectedChannelRead() } }
            } catch { errorMessage = "受信したメッセージを読み込めませんでした。再読み込みしてください。" }
        } else if ["channels_updated", "subscribed", "channel_archived", "channel_unarchived", "member_joined", "member_leaved", "authority_updated"].contains(event.name) {
            refresh()
        } else if event.name == "profile_updated" {
            if let updated = try? APIJSON.decoder().decode(Profile.self, from: event.payload), updated.id == profile?.id { profile = updated }
        }
    }

    private func normalize(_ incoming: [Channel]) -> [Channel] {
        incoming.filter { !$0.archived && $0.membership?.authority != "invited" }.map { channel in
            var result = channel
            if let previous = channels.first(where: { $0.id == channel.id })?.membership,
               previous.latestReadMessageID > (channel.membership?.latestReadMessageID ?? 0) {
                result.membership?.latestReadMessageID = previous.latestReadMessageID
                result.membership?.unreadCount = (cache[channel.id] ?? []).filter { $0.id > previous.latestReadMessageID && $0.profile.id != profile?.id }.count
            }
            if let latest = channel.latestMessageID, (result.membership?.latestReadMessageID ?? 0) >= latest { result.membership?.unreadCount = 0 }
            return result
        }
    }

    private func setConnectionState(_ state: RealtimeConnectionState) {
        isConnected = false
        if state != .connected { resetImageFallback() }
        switch state {
        case .connected: isConnected = true; connectionLabel = "接続済み"; refresh(); resolveMissingImages()
        case .connecting: connectionLabel = "接続中…"
        case .reconnecting: connectionLabel = "再接続中…"
        case .disconnected: connectionLabel = "オフライン"
        case .failed(let detail): connectionLabel = "接続できません"; errorMessage = detail
        }
    }

    func clearError() { errorMessage = nil }

    func signOut() {
        do { try CredentialStore.delete() }
        catch { errorMessage = error.localizedDescription; return }
        resetSession()
    }

    private func resetSession() {
        resetImageFallback()
        sessionID = UUID(); selectionID = UUID(); signInAttemptID = UUID(); isSigningIn = false
        realtime.disconnect()
        notifications.resetSession()
        refreshTask?.cancel(); refreshTask = nil
        readTasks.values.forEach { $0.cancel() }; readTasks = [:]
        client = nil; credential = nil; channels = []; messages = []; cache = [:]; drafts = [:]; confirmedTails = [:]
        pendingSends = [:]; seenEvents = []; messageRevisions = [:]; eventRevision = 0; profile = nil; selectedChannelID = nil
        draft = ""; channelSearch = ""; errorMessage = nil; unreadOnly = false
        isSignedIn = false; isSending = false; isLoadingMessages = false; isLoadingMore = false
    }
}
