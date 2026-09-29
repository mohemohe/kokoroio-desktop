import Foundation
import FoundationNetworking
import KokoroCore
import KokoroWindowsState
import UWP
import WinUI
import WindowsFoundation
import WindowsNative

@MainActor
final class WorkspaceWindow {
    private let window = Window()
    private let store: WindowsChatStore
    private let smokeImages: WindowsSmokeImageService?
    private let notifications = WindowsNotificationService()
    private let status = TextBlock(), title = TextBlock(), subtitle = TextBlock(), channelGlyph = TextBlock()
    private let server = TextBox(), messageSearch = TextBox()
    private let token = PasswordBox()
    private let login = Button(), more = Button(), latest = Button(), searchButton = Button(), refreshButton = Button(), submitSearch = Button()
    private let tokenLink = HyperlinkButton()
    private let loginLabel = TextBlock(), historyLabel = TextBlock()
    private let loginSpinner = ProgressRing(), historySpinner = ProgressRing()
    private let timeline = StackPanel(), history = StackPanel(), intro = StackPanel(), timelineHeading = StackPanel()
    private let searchPanel = Grid(), header = Grid(), errorBanner = Grid(), conversation = Grid()
    private let loginError = Grid()
    private let scroll = ScrollViewer()
    private var sidebar: WindowsSidebarView?
    private var settings: WindowsSettingsWindow?
    private lazy var composerView = WindowsComposerView(store: store, onAddImages: { [weak self] in self?.addImages() },
        onEmoji: { [weak self] _ in self?.showEmojiPicker() }, onSend: { [weak self] in Task { await self?.store.send() } })
    private var composer: TextBox { composerView.editor }
    private var signedInLayout = false, rendering = false
    private var composing = false, searchComposing = false
    private var compositionEndedAt = Date.distantPast, searchCompositionEndedAt = Date.distantPast
    private var renderedChannel: String?
    private var renderedMessages: [Message] = []
    private var renderedSearch = false, renderedSearchOpen = false
    private var timelineGeneration = UUID()
    private var pendingNotificationChannel: String?
    private var refreshTask: Task<Void, Never>?
    private var messageRows: [TimelineMessageView] = []
    private var timelineElements: [FrameworkElement] = []
    private var daySeparators: [Int: (date: Date, element: FrameworkElement)] = [:]
    private var timelineMutationCount = 0
    private struct HeadingState: Equatable {
        let channelID: String?, name: String?, description: String?
        let direct: Bool, hasMore: Bool, loading: Bool, searching: Bool, search: Bool, empty: Bool
        let error: String?
        let resultCount: Int?
    }
    private var headingState: HeadingState?
    private var refreshIconSearchState: Bool?
    private var parents: [Panel] = []
    private var contentParents: [ContentControl] = []
    private var emptyConversation: FrameworkElement?
    private var channelOnlyParts: [FrameworkElement] = []
    private(set) var isClosed = false

    init() {
        if CommandLine.arguments.contains("--smoke-test") {
            let images = WindowsSmokeImageService()
            smokeImages = images
            store = WindowsChatStore(usesRealtime: !CommandLine.arguments.contains("--smoke-no-realtime"),
                defaults: UserDefaults(suiteName: "KokoroDesktop.smoke.\(UUID())")!, imageService: images)
        } else {
            smokeImages = nil
            store = WindowsChatStore()
        }
    }

    func show() throws {
        window.title = "kokoro.io"
        WindowsTitleBar.configure(for: window)
        window.closed.addHandler { [weak self] _, _ in self?.isClosed = true; self?.settings?.close() }
        window.activated.addHandler { [weak self] _, args in
            guard let self else { return }; store.isActive = args?.windowActivationState != .deactivated
            Task { await self.store.markRead() }
        }
        store.onChange = { [weak self] in self?.render() }
        store.onNotify = { [weak self] message, channel in
            guard let self else { return }
            do { try notifications.show(channelID: channel.id, channelName: channel.name,
                sender: message.displayName.isEmpty ? message.profile.displayName : message.displayName,
                body: message.text, soundEnabled: store.notificationSoundEnabled) }
            catch { store.reportError(error.localizedDescription) }
        }
        buildLogin(); try window.activate()
        try WindowsPlatformServices.setMinimumWindowSize(width: 860, height: 600)
        let scale = (window.content as? FrameworkElement)?.xamlRoot?.rasterizationScale ?? 1
        try window.appWindow.resizeClient(.init(width: Int32(1160 * scale), height: Int32(780 * scale)))
        if CommandLine.arguments.contains("--smoke-test") {
            Task { await runSmokeTest() }
            Task { try? await Task.sleep(for: .seconds(90)); if !isClosed { fputs("Windows smoke test timed out\n", stderr); exit(2) } }
            return
        }
        registerNotifications()
        do { store.updateImgBBAPIKey(try WindowsImgBBKeyStore.load() ?? "") }
        catch { store.reportError(error.localizedDescription) }
        Task { [weak self] in
            guard let self else { return }
            do { if let saved = try WindowsCredentialStore.load() { server.text = saved.server; await store.signIn(server: saved.server, token: saved.token) } }
            catch { store.reportError(error.localizedDescription) }
        }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled { do { try await Task.sleep(for: .seconds(60)) } catch { return }; await self?.store.refresh() }
        }
    }
    func shutdown() {
        refreshTask?.cancel(); settings?.close(); sidebar?.dispose(); composerView.dispose(); messageRows.forEach { $0.dispose() }
        store.onChange = nil; store.onNotify = nil; store.signOut(); notifications.shutdown()
    }
    private func registerNotifications() {
        do {
            try notifications.register { [weak self] channel in
                guard let self else { return }; try? window.activate()
                if store.profile == nil { pendingNotificationChannel = channel }
                else { Task { await self.store.selectChannel(channel) } }
            }
        } catch { store.reportError(error.localizedDescription) }
    }
    private func connect() {
        guard !token.password.isEmpty, !store.isSigningIn else { return }
        let credential = WindowsCredential(server: server.text, token: token.password)
        Task {
            if await self.store.signIn(server: credential.server, token: credential.token) {
                self.token.password = ""
                do { try WindowsCredentialStore.save(credential) } catch { self.store.reportError(error.localizedDescription) }
            }
        }
    }
    private func buildLogin() {
        let host = Grid(); host.minWidth = 860; host.minHeight = 600; configureSurface(host)
        let panel = StackPanel(); panel.width = 352; panel.spacing = 22; panel.horizontalAlignment = .center; panel.verticalAlignment = .center
        let heading = text("kokoro.io に接続", size: 22); heading.fontWeight = .init(weight: 700); panel.children.append(heading)
        let detail = text("kokoro.io のアクセストークンでログインします。", size: 13); detail.opacity = 0.7; panel.children.append(detail)
        let serverGroup = StackPanel(); serverGroup.spacing = 8; serverGroup.children.append(text("サーバーURL", size: 13))
        server.placeholderText = "https://kokoro.io"; if server.text.isEmpty { server.text = "https://kokoro.io" }
        serverGroup.children.append(server); panel.children.append(serverGroup)
        let tokenGroup = StackPanel(); tokenGroup.spacing = 8; tokenGroup.children.append(text("アクセストークン", size: 13))
        token.placeholderText = "アクセストークンを貼り付け"; tokenGroup.children.append(token)
        let caption = text("ユーザーのアクセストークンを使います。トークンは Windows 資格情報マネージャーに保存されます。", size: 11)
        caption.opacity = 0.7; tokenGroup.children.append(caption); panel.children.append(tokenGroup)
        tokenLink.content = "ブラウザでトークンを発行 ↗"; tokenLink.padding = inset(0); tokenLink.horizontalAlignment = .left
        updateTokenLink(); panel.children.append(tokenLink)
        status.textWrapping = .wrap; status.fontSize = 13; status.visibility = .collapsed
        status.foreground = SolidColorBrush(.init(a: 255, r: 196, g: 43, b: 36))
        columns(loginError, [-1, nil]); loginError.columnSpacing = 8; loginError.visibility = .collapsed
        let warning = icon("\u{E783}", size: 13); warning.foreground = status.foreground; loginError.children.append(warning)
        try? Grid.setColumn(status, 1); loginError.children.append(status); panel.children.append(loginError)
        if login.content == nil {
            let content = StackPanel(); content.orientation = .horizontal; content.spacing = 7
            loginSpinner.width = 16; loginSpinner.height = 16; loginSpinner.visibility = .collapsed
            content.children.append(loginSpinner); loginLabel.text = "接続する"; content.children.append(loginLabel); login.content = content
        }
        login.horizontalAlignment = .stretch; login.isEnabled = !token.password.isEmpty
        login.background = SolidColorBrush(.init(a: 255, r: 92, g: 59, b: 115)); login.foreground = SolidColorBrush(.init(a: 255, r: 255, g: 255, b: 255)); panel.children.append(login)
        host.children.append(panel); window.content = host; parents = [host, panel, serverGroup, tokenGroup, loginError]
        if login.tag == nil {
            login.tag = "configured"; login.click.addHandler { [weak self] _, _ in self?.connect() }
            token.passwordChanged.addHandler { [weak self] _, _ in guard let self else { return }; login.isEnabled = !store.isSigningIn && !token.password.isEmpty }
            token.keyDown.addHandler { [weak self] _, args in if args?.key == .enter { self?.connect() } }
            server.textChanged.addHandler { [weak self] _, _ in self?.updateTokenLink() }
        }
    }
    private func updateTokenLink() { tokenLink.navigateUri = (try? APIClient.validatedServerURL(server.text)).map { Uri($0.appendingPathComponent("access_tokens").absoluteString) } }

    private func buildWorkspace() {
        let root = Grid(); root.minWidth = 860; root.minHeight = 600; configureSurface(root); columns(root, [246, 1, nil])
        root.previewKeyDown.addHandler { [weak self] _, args in
            guard let self, let args, args.key == .r, WindowsPlatformServices.isControlPressed,
                  !composing, !searchComposing, !WindowsPlatformServices.isIMEComposing else { return }
            args.handled = true; Task { await self.store.refresh() }
        }
        let sidebarWidth = root.columnDefinitions[0]!
        sidebarWidth.minWidth = 220; sidebarWidth.maxWidth = 310
        sidebar = WindowsSidebarView(store: store, onSelect: { [weak self] id in Task { await self?.store.selectChannel(id) } }, onSettings: { [weak self] in self?.showSettings() })
        root.children.append(sidebar!.element)
        let splitter = Thumb(); splitter.width = 5; splitter.background = SolidColorBrush(.init(a: 20, r: 128, g: 128, b: 128))
        splitter.horizontalAlignment = .center; try? Grid.setColumn(splitter, 1); root.children.append(splitter)
        splitter.dragDelta.addHandler { _, args in guard let args else { return }; sidebarWidth.width = .init(value: min(310, max(220, sidebarWidth.actualWidth + args.horizontalChange)), gridUnitType: .pixel) }
        addRows(conversation, [.auto, .auto, .star, .auto, .auto]); configureSurface(conversation)
        columns(header, [nil, -1]); header.padding = .init(left: 25, top: 17, right: 25, bottom: 17)
        let channelInfo = Grid(); columns(channelInfo, [-1, nil]); channelInfo.columnSpacing = 12
        channelGlyph.fontSize = 20; channelGlyph.verticalAlignment = .center; channelGlyph.opacity = 0.65; channelInfo.children.append(channelGlyph)
        let labels = StackPanel(); labels.spacing = 4; title.fontSize = 16; title.fontWeight = .init(weight: 700); title.maxLines = 1; title.textTrimming = .characterEllipsis
        subtitle.fontSize = 11; subtitle.maxLines = 1; subtitle.textTrimming = .characterEllipsis; subtitle.opacity = 0.65
        labels.children.append(title); labels.children.append(subtitle); try? Grid.setColumn(labels, 1); channelInfo.children.append(labels); header.children.append(channelInfo)
        let actions = StackPanel(); actions.orientation = .horizontal; actions.spacing = 8; actions.margin = .init(left: 8, top: 0, right: 0, bottom: 0)
        configureIconButton(searchButton, glyph: "\u{E721}", label: "チャンネル内を検索"); actions.children.append(searchButton)
        columns(searchPanel, [-1, nil, -1]); searchPanel.columnSpacing = 8; searchPanel.width = 280; searchPanel.minWidth = 150; searchPanel.maxWidth = 360
        searchPanel.background = SolidColorBrush(.init(a: 18, r: 128, g: 128, b: 128)); searchPanel.cornerRadius = corners(7); searchPanel.padding = .init(left: 10, top: 0, right: 10, bottom: 0)
        let searchGlyph = icon("\u{E721}", size: 12); searchGlyph.verticalAlignment = .center; searchPanel.children.append(searchGlyph)
        messageSearch.placeholderText = "このチャンネルのメッセージを検索"; messageSearch.fontSize = 12; messageSearch.minWidth = 0; messageSearch.minHeight = 30
        messageSearch.borderThickness = inset(0); messageSearch.background = SolidColorBrush(.init(a: 0, r: 0, g: 0, b: 0)); messageSearch.padding = .init(left: 0, top: 5, right: 0, bottom: 5)
        try? Grid.setColumn(messageSearch, 1); searchPanel.children.append(messageSearch)
        submitSearch.content = "検索"; submitSearch.fontSize = 12; submitSearch.minHeight = 24; submitSearch.padding = .init(left: 7, top: 2, right: 7, bottom: 2)
        try? Grid.setColumn(submitSearch, 2); searchPanel.children.append(submitSearch); actions.children.append(searchPanel)
        configureIconButton(refreshButton, glyph: "\u{E72C}", label: "最新のメッセージを取得"); actions.children.append(refreshButton)
        try? Grid.setColumn(actions, 1); header.children.append(actions); place(header, in: conversation, row: 0)
        header.borderThickness = .init(left: 0, top: 0, right: 0, bottom: 1)
        header.borderBrush = SolidColorBrush(.init(a: 24, r: 128, g: 128, b: 128))
        columns(errorBanner, [-1, nil, -1, -1]); errorBanner.columnSpacing = 8; errorBanner.padding = .init(left: 24, top: 10, right: 24, bottom: 10)
        errorBanner.background = SolidColorBrush(.init(a: 20, r: 255, g: 140, b: 0)); errorBanner.children.append(icon("\u{E783}", size: 12))
        status.fontSize = 11; status.visibility = .visible; status.isTextSelectionEnabled = true; try? Grid.setColumn(status, 1); errorBanner.children.append(status)
        func updateErrorColor() {
            let value: UInt8 = errorBanner.actualTheme == .dark ? 255 : 0
            status.foreground = SolidColorBrush(.init(a: 255, r: value, g: value, b: value))
        }
        updateErrorColor()
        if errorBanner.tag == nil {
            errorBanner.tag = "configured"
            errorBanner.actualThemeChanged.addHandler { [weak self] _, _ in
                guard let self else { return }
                let value: UInt8 = errorBanner.actualTheme == .dark ? 255 : 0
                status.foreground = SolidColorBrush(.init(a: 255, r: value, g: value, b: value))
            }
        }
        let retry = button("再試行") { [weak self] in Task { await self?.store.refresh() } }; retry.fontSize = 11; try? Grid.setColumn(retry, 2); errorBanner.children.append(retry)
        retry.background = SolidColorBrush(.init(a: 0, r: 0, g: 0, b: 0)); retry.borderThickness = inset(0)
        retry.foreground = SolidColorBrush(.init(a: 255, r: 110, g: 74, b: 168)); retry.padding = inset(0)
        let closeError = Button(); configureIconButton(closeError, glyph: "\u{E711}", label: "エラーを閉じる")
        closeError.click.addHandler { [weak self] _, _ in self?.store.clearError() }; try? Grid.setColumn(closeError, 3); errorBanner.children.append(closeError); place(errorBanner, in: conversation, row: 1)
        for child in errorBanner.children { (child as? FrameworkElement)?.verticalAlignment = .center }
        let timelineArea = Grid(); timeline.spacing = 0; history.spacing = 0
        more.horizontalAlignment = .stretch; more.fontSize = 11; more.borderThickness = inset(0); more.background = SolidColorBrush(.init(a: 0, r: 0, g: 0, b: 0)); more.padding = .init(left: 0, top: 14, right: 0, bottom: 14)
        if more.content == nil {
            let content = StackPanel(); content.orientation = .horizontal; content.spacing = 7
            historySpinner.width = 14; historySpinner.height = 14; historySpinner.visibility = .collapsed
            historyLabel.fontSize = 11; content.children.append(historySpinner); content.children.append(historyLabel); more.content = content
        }
        history.children.append(more); history.children.append(intro); history.children.append(timelineHeading); history.children.append(timeline)
        let bottomSpace = Border(); bottomSpace.height = 15; history.children.append(bottomSpace); scroll.content = history; timelineArea.children.append(scroll)
        latest.content = "↓ 最新のメッセージ"; latest.fontSize = 11; latest.cornerRadius = corners(18); latest.padding = .init(left: 13, top: 8, right: 13, bottom: 8)
        latest.horizontalAlignment = .center; latest.verticalAlignment = .bottom; latest.margin = .init(left: 0, top: 0, right: 0, bottom: 9); timelineArea.children.append(latest)
        let composerDivider = line()
        place(timelineArea, in: conversation, row: 2); place(composerDivider, in: conversation, row: 3); place(composerView.element, in: conversation, row: 4)
        channelOnlyParts = [header, timelineArea, composerDivider, composerView.element]
        try? Grid.setColumn(conversation, 2); root.children.append(conversation)
        let empty = StackPanel(); empty.spacing = 10; empty.horizontalAlignment = .center; empty.verticalAlignment = .center
        empty.children.append(icon("\u{E8F2}", size: 32)); empty.children.append(text("会話をはじめましょう", size: 20)); empty.children.append(text("サイドバーからチャンネルを選択してください。", size: 13))
        empty.children.append(button("チャンネルを再読み込み") { [weak self] in Task { await self?.store.refresh() } })
        for child in empty.children { (child as? FrameworkElement)?.horizontalAlignment = .center }
        place(empty, in: conversation, row: 2); emptyConversation = empty; window.content = root
        parents = [root, conversation, header, channelInfo, labels, actions, searchPanel, errorBanner, timelineArea, history]; contentParents = [scroll]; configureEvents()
    }

    private func configureEvents() {
        guard composer.tag == nil else { return }; composer.tag = "configured"
        composer.textChanged.addHandler { [weak self] _, _ in guard let self, !rendering else { return }; store.draft = composer.text; composerView.refresh() }
        composer.textCompositionStarted.addHandler { [weak self] _, _ in self?.composing = true }
        composer.textCompositionEnded.addHandler { [weak self] _, _ in self?.composing = false; self?.compositionEndedAt = Date() }
        composer.keyUp.addHandler { [weak self] _, args in if args?.key == .enter { self?.compositionEndedAt = .distantPast } }
        composer.previewKeyDown.addHandler { [weak self] _, args in
            guard let self, let args, args.key == .enter, !WindowsPlatformServices.isShiftPressed,
                !composing, !WindowsPlatformServices.isIMEComposing, Date().timeIntervalSince(compositionEndedAt) > 0.1 else { return }
            args.handled = true; if store.canSend { Task { await self.store.send() } }
        }
        latest.click.addHandler { [weak self] _, _ in self?.scrollToBottom() }
        more.click.addHandler { [weak self] _, _ in Task { await self?.loadOlder() } }
        searchButton.click.addHandler { [weak self] _, _ in self?.store.openSearch(); _ = try? self?.messageSearch.focus(.programmatic) }
        refreshButton.click.addHandler { [weak self] _, _ in guard let self else { return }; if store.isSearchOpen { store.closeSearch() } else { Task { await self.store.refresh() } } }
        submitSearch.click.addHandler { [weak self] _, _ in Task { await self?.store.searchSelectedChannel() } }
        messageSearch.textChanged.addHandler { [weak self] _, _ in guard let self, !rendering else { return }; store.searchQuery = messageSearch.text; render() }
        messageSearch.previewKeyDown.addHandler { [weak self] _, args in
            guard let self, args?.key == .enter, !searchComposing, !WindowsPlatformServices.isIMEComposing,
                Date().timeIntervalSince(searchCompositionEndedAt) > 0.1 else { return }
            args?.handled = true; Task { await self.store.searchSelectedChannel() }
        }
        messageSearch.textCompositionStarted.addHandler { [weak self] _, _ in self?.searchComposing = true }
        messageSearch.textCompositionEnded.addHandler { [weak self] _, _ in self?.searchComposing = false; self?.searchCompositionEndedAt = Date() }
        messageSearch.keyUp.addHandler { [weak self] _, args in if args?.key == .enter { self?.searchCompositionEndedAt = .distantPast } }
        scroll.viewChanged.addHandler { [weak self] _, args in
            guard let self, !rendering else { return }
            if !store.isShowingSearchResults { store.isAtBottom = scroll.scrollableHeight - scroll.verticalOffset < 24 }
            updateTimelineActions(); if args?.isIntermediate != true { Task { await self.store.markRead() } }
        }
        try? AutomationProperties.setName(composer, "メッセージ")
        try? AutomationProperties.setName(messageSearch, "このチャンネルのメッセージを検索")
        header.sizeChanged.addHandler { [weak self] _, args in
            guard let self, let args else { return }; searchPanel.width = max(150, min(360, Double(args.newSize.width) * 0.32))
        }
    }
    private func loadOlder() async {
        let oldHeight = scroll.extentHeight, oldOffset = scroll.verticalOffset
        let channel = store.selectedChannelID, generation = timelineGeneration
        store.isAtBottom = false; await store.loadMessages(older: true)
        guard channel == store.selectedChannelID, generation == timelineGeneration, !store.isShowingSearchResults, !store.isAtBottom else { return }
        try? history.updateLayout(); _ = try? scroll.changeView(nil, max(0, oldOffset + scroll.extentHeight - oldHeight), nil, true); updateTimelineActions()
    }
    private func render() {
        guard !isClosed, !rendering else { return }; rendering = true; defer { rendering = false }
        if renderedChannel != store.selectedChannelID || renderedSearch != store.isShowingSearchResults || renderedSearchOpen != store.isSearchOpen { timelineGeneration = UUID() }
        renderedSearchOpen = store.isSearchOpen
        let signedIn = store.profile != nil
        if signedIn != signedInLayout {
            headingState = nil; refreshIconSearchState = nil
            window.content = nil; contentParents.forEach { $0.content = nil }; contentParents = []
            parents.forEach { $0.children.clear() }; parents = []; sidebar?.dispose(); sidebar = nil; signedInLayout = signedIn
            if signedIn { buildWorkspace() }
            else {
                renderedChannel = nil; renderedMessages = []; renderedSearch = false
                messageRows.forEach { $0.dispose() }; messageRows = []; timeline.children.clear()
                timelineElements = []; daySeparators = [:]; composer.text = ""; buildLogin()
            }
        }
        login.isEnabled = !store.isSigningIn && !token.password.isEmpty; loginLabel.text = store.isSigningIn ? "接続中…" : "接続する"
        loginSpinner.isActive = store.isSigningIn; loginSpinner.visibility = store.isSigningIn ? .visible : .collapsed
        status.text = store.error ?? ""; status.visibility = store.error == nil ? .collapsed : .visible
        loginError.visibility = store.error == nil ? .collapsed : .visible
        guard signedIn else { return }
        if let channel = pendingNotificationChannel { pendingNotificationChannel = nil; Task { await self.store.selectChannel(channel) } }
        sidebar?.refresh(); settings?.refresh()
        let channel = store.selectedChannel
        channelOnlyParts.forEach { $0.visibility = channel == nil ? .collapsed : .visible }
        emptyConversation?.visibility = channel == nil ? .visible : .collapsed
        title.text = channel?.name ?? ""
        subtitle.text = channel.map { $0.description.isEmpty ? ($0.isDirectMessage ? "ダイレクトメッセージ" : $0.kind.lowercased().contains("private") ? "プライベートチャンネル" : "パブリックチャンネル") : $0.description } ?? ""
        channelGlyph.fontFamily = channel?.isDirectMessage == true || channel?.kind.lowercased().contains("private") == true ? FontFamily("Segoe Fluent Icons") : FontFamily("Segoe UI")
        channelGlyph.text = channel?.isDirectMessage == true ? "\u{E8F2}" : channel?.kind.lowercased().contains("private") == true ? "\u{E72E}" : "#"
        searchPanel.visibility = store.isSearchOpen ? .visible : .collapsed; searchButton.visibility = store.isSearchOpen ? .collapsed : .visible
        if messageSearch.text != store.searchQuery { messageSearch.text = store.searchQuery }
        submitSearch.isEnabled = store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 && !store.isSearching
        if refreshIconSearchState != store.isSearchOpen {
            refreshIconSearchState = store.isSearchOpen
            configureIconButton(refreshButton, glyph: store.isSearchOpen ? "\u{E711}" : "\u{E72C}", label: store.isSearchOpen ? "検索を閉じる" : "最新のメッセージを取得")
        }
        errorBanner.visibility = store.error == nil ? .collapsed : .visible
        more.isEnabled = store.hasMore && !store.isLoading; historyLabel.text = store.isLoading ? "読み込み中…" : "↑ 以前のメッセージを読み込む"
        historySpinner.isActive = store.isLoading; historySpinner.visibility = store.isLoading ? .visible : .collapsed
        if composer.text != store.draft { composer.text = store.draft }; composerView.refresh(); renderTimelineHeading()
        let messages = store.displayedMessages
        if renderedChannel != store.selectedChannelID || renderedMessages != messages || renderedSearch != store.isShowingSearchResults {
            let changedChannel = renderedChannel != store.selectedChannelID, changedSearch = renderedSearch != store.isShowingSearchResults
            let follow = !store.isShowingSearchResults && (changedChannel || changedSearch || store.isAtBottom || messages.last?.profile.id == store.profile?.id)
            var reusable: [Int: (Message, TimelineMessageView)] = [:]
            for (message, row) in zip(renderedMessages, messageRows) { reusable[message.id] = (message, row) }
            renderedChannel = store.selectedChannelID; renderedMessages = messages; renderedSearch = store.isShowingSearchResults; messageRows = []
            var elements: [FrameworkElement] = []
            var separators: [Int: (date: Date, element: FrameworkElement)] = [:]
            for (index, message) in messages.enumerated() {
                let startsDay = index == 0 || !WindowsTimelineDate(messages[index - 1].publishedAt).isSameDay(as: WindowsTimelineDate(message.publishedAt))
                let grouped = index > 0 && !startsDay && !message.isDeleted && !messages[index - 1].isDeleted && messages[index - 1].profile.id == message.profile.id && message.publishedAt.timeIntervalSince(messages[index - 1].publishedAt) < 300
                if startsDay {
                    let existing = daySeparators[message.id]
                    let separator = existing?.date == message.publishedAt ? existing!.element : daySeparator(message.publishedAt)
                    separators[message.id] = (message.publishedAt, separator); elements.append(separator)
                }
                let row: TimelineMessageView, existing = reusable.removeValue(forKey: message.id)
                if let existing, existing.0 == message, existing.1.isGrouped == grouped { row = existing.1 }
                else {
                    existing?.1.dispose(); row = TimelineMessageView(message: message, isGrouped: grouped) { [weak self] in guard let self, store.isAtBottom, !store.isShowingSearchResults else { return }; scrollToBottom() }
                }
                messageRows.append(row); elements.append(row.element)
            }
            reconcileTimeline(elements)
            daySeparators = separators
            reusable.values.forEach { $0.1.dispose() }
            if follow { scrollToBottom() } else if changedSearch { _ = try? scroll.changeView(nil, 0, nil, true) }
        }
        applyWorkspaceTheme(); updateTimelineActions(); if store.isAtBottom && !store.isSearchOpen { Task { await store.markRead() } }
    }
    /// Preserve attached controls and their layout/selection when a message is
    /// appended or updated. Clearing the collection reloads every native row.
    private func reconcileTimeline(_ elements: [FrameworkElement]) {
        let retained = Set(elements.map(ObjectIdentifier.init))
        for index in timelineElements.indices.reversed() where !retained.contains(ObjectIdentifier(timelineElements[index])) {
            timeline.children.removeAt(UInt32(index)); timelineElements.remove(at: index)
            timelineMutationCount += 1
        }
        for (index, element) in elements.enumerated() {
            if index < timelineElements.count, timelineElements[index] === element { continue }
            if let previous = timelineElements[index...].firstIndex(where: { $0 === element }) {
                // Native move preserves the control itself, including its selection.
                try? timeline.children.move(UInt32(previous), UInt32(index))
                timelineElements.remove(at: previous); timelineElements.insert(element, at: index)
            } else {
                timeline.children.insertAt(UInt32(index), element); timelineElements.insert(element, at: index)
            }
            timelineMutationCount += 1
        }
    }
    private func renderTimelineHeading() {
        let channel = store.selectedChannel
        let next = HeadingState(channelID: channel?.id, name: channel?.name, description: channel?.description,
            direct: channel?.isDirectMessage == true, hasMore: store.hasMore, loading: store.isLoading,
            searching: store.isSearching, search: store.isShowingSearchResults, empty: store.messages.isEmpty,
            error: store.searchError, resultCount: store.searchResults?.count)
        guard headingState != next else { return }
        headingState = next
        intro.children.clear(); timelineHeading.children.clear()
        intro.visibility = !store.isShowingSearchResults && !store.hasMore && !(store.isLoading && store.messages.isEmpty) ? .visible : .collapsed
        intro.spacing = 10; intro.margin = .init(left: 26, top: 17, right: 26, bottom: 23)
        if let channel = store.selectedChannel, intro.visibility == .visible {
            let emblem = channel.isDirectMessage ? icon("\u{E8F2}", size: 25) : text("#", size: 25)
            emblem.horizontalAlignment = .center; emblem.verticalAlignment = .center; emblem.foreground = SolidColorBrush(.init(a: 255, r: 110, g: 74, b: 168))
            let emblemBox = Grid(); emblemBox.width = 52; emblemBox.height = 52; emblemBox.horizontalAlignment = .left; emblemBox.cornerRadius = corners(14)
            emblemBox.background = SolidColorBrush(.init(a: 23, r: 110, g: 74, b: 168)); emblemBox.children.append(emblem); intro.children.append(emblemBox)
            let name = text(channel.name, size: 23); name.fontWeight = .init(weight: 700); intro.children.append(name)
            let introText = text(store.messages.isEmpty ? "最初のメッセージを送って、会話をはじめましょう。" : "このチャンネルの会話はここから始まります。", size: 12); introText.opacity = 0.65; intro.children.append(introText)
            if !channel.description.isEmpty { let description = text(channel.description, size: 12); description.opacity = 0.65; description.isTextSelectionEnabled = true; intro.children.append(description) }
        }
        timeline.visibility = .visible; timelineHeading.margin = inset(0)
        if store.isSearching || (store.isLoading && store.messages.isEmpty && !store.isShowingSearchResults) {
            timeline.visibility = .collapsed; let progress = ProgressRing(); progress.isActive = true; progress.width = 24; progress.height = 24; progress.horizontalAlignment = .center
            timelineHeading.children.append(progress); timelineHeading.children.append(text(store.isSearching ? "検索中…" : "メッセージを読み込み中…", size: 12)); timelineHeading.margin = .init(left: 26, top: 80, right: 26, bottom: 80)
        } else if store.isShowingSearchResults, let error = store.searchError {
            timelineHeading.children.append(icon("\u{E721}", size: 32))
            timelineHeading.children.append(text("検索できませんでした", size: 18)); timelineHeading.children.append(text(error, size: 12)); timelineHeading.children.append(button("再試行") { [weak self] in Task { await self?.store.searchSelectedChannel() } }); timelineHeading.margin = .init(left: 26, top: 60, right: 26, bottom: 60)
        } else if store.isShowingSearchResults {
            if store.displayedMessages.isEmpty { timelineHeading.children.append(icon("\u{E721}", size: 32)) }
            timelineHeading.children.append(text(store.displayedMessages.isEmpty ? "検索結果がありません" : "検索結果: \(store.displayedMessages.count) 件", size: store.displayedMessages.isEmpty ? 18 : 11)); timelineHeading.margin = .init(left: 26, top: store.displayedMessages.isEmpty ? 60 : 14, right: 26, bottom: store.displayedMessages.isEmpty ? 60 : 14)
        }
        if store.isSearching || (store.isShowingSearchResults && (store.searchError != nil || store.displayedMessages.isEmpty)) || (store.isLoading && store.messages.isEmpty) {
            timelineHeading.spacing = 10
            for child in timelineHeading.children { (child as? FrameworkElement)?.horizontalAlignment = .center; (child as? TextBlock)?.textAlignment = .center }
        } else { timelineHeading.spacing = 0 }
    }
    private func daySeparator(_ date: Date) -> FrameworkElement {
        let grid = Grid(); columns(grid, [nil, -1, nil]); grid.columnSpacing = 12; grid.margin = .init(left: 26, top: 12, right: 26, bottom: 12)
        let left = line(); left.verticalAlignment = .center; grid.children.append(left)
        let label = text(WindowsTimelineDate(date).dayText, size: 10); label.opacity = 0.65
        let capsule = Border(); capsule.cornerRadius = corners(16); capsule.borderThickness = inset(1); capsule.borderBrush = SolidColorBrush(.init(a: 25, r: 128, g: 128, b: 128)); capsule.padding = .init(left: 10, top: 5, right: 10, bottom: 5); capsule.child = label
        try? Grid.setColumn(capsule, 1); grid.children.append(capsule)
        let right = line(); right.verticalAlignment = .center; try? Grid.setColumn(right, 2); grid.children.append(right); return grid
    }
    private func updateTimelineActions() {
        // Part of scroll content: only visible in the viewport at the start of history.
        more.visibility = !store.isShowingSearchResults && store.hasMore ? .visible : .collapsed
        latest.visibility = !store.isShowingSearchResults && !store.isAtBottom && !store.messages.isEmpty && !store.isLoading ? .visible : .collapsed
    }
    private func scrollToBottom() {
        guard !store.isShowingSearchResults else { return }; timelineGeneration = UUID(); try? history.updateLayout()
        _ = try? scroll.changeView(nil, scroll.scrollableHeight, nil, true); store.isAtBottom = true; latest.visibility = .collapsed; Task { await store.markRead() }
    }
    private func addImages() {
        guard store.hasImgBBAPIKey else { return }
        do { store.addImages(try WindowsPlatformServices.pickImages()) } catch { store.reportError("画像を選択できませんでした: " + error.localizedDescription) }
    }
    private func showEmojiPicker() {
        guard !store.isSending else { return }; _ = try? composer.focus(.programmatic)
        do { try WindowsPlatformServices.openEmojiPicker() } catch { store.reportError(error.localizedDescription) }
    }
    private func insertEmoji(_ emoji: String) {
        let current = composer.text as NSString, start = min(max(0, Int(composer.selectionStart)), (composer.text as NSString).length)
        let length = min(max(0, Int(composer.selectionLength)), current.length - start)
        composer.text = current.replacingCharacters(in: NSRange(location: start, length: length), with: emoji)
        try? composer.select(Int32(start + (emoji as NSString).length), 0); store.draft = composer.text; composerView.refresh()
    }
    private func showSettings() {
        if let settings { settings.show(); return }
        settings = WindowsSettingsWindow(store: store, notificationService: notifications, onClose: { [weak self] in self?.settings = nil }, onSignOut: { [weak self] in
            guard let self else { return }
            do { try WindowsCredentialStore.delete(); Task { try? await self.notifications.clear() }; settings?.close(); store.signOut() }
            catch { store.reportError(error.localizedDescription) }
        }, onNotificationsEnabled: { [weak self] in self?.registerNotifications() }); settings?.show()
    }

    private func runSmokeTest() async {
        func check(_ condition: Bool, _ message: String) { if !condition { fputs("Windows smoke test failed: \(message)\n", stderr); exit(2) } }
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/windows/ui-snapshots")
        func snapshot(_ name: String, element: FrameworkElement? = nil) async {
            do {
                // TextChanged and theme/template updates are queued by XAML.
                try await Task.sleep(for: .milliseconds(150))
                let surface = element ?? window.content as! FrameworkElement
                try await WindowsUISnapshot.capture(surface, to: output.appendingPathComponent(name + ".bmp"))
                let audit = WindowsUIAudit.inspect(element: surface)
                try WindowsUIAudit.save(audit, to: output.appendingPathComponent(name + ".json"))
                var failures: [String] = []
                if ["search", "long-draft", "minimum-size"].contains(name) || name.hasPrefix("workspace") || name.hasPrefix("attachment-") {
                    failures += WindowsUIAudit.validateWorkspace(audit, channelName: store.selectedChannel!.name, connectionLabel: store.connectionLabel, searchOpen: store.isSearchOpen)
                    failures += WindowsUIAudit.validateComposer(audit, channelName: store.selectedChannel!.name, hasImageKey: store.hasImgBBAPIKey, canSend: store.canSend)
                } else if name.hasPrefix("settings") {
                    failures += WindowsUIAudit.validateSettings(audit, signedIn: true, notificationsEnabled: store.notificationsEnabled)
                }
                if !failures.isEmpty { fputs(failures.joined(separator: "\n") + "\n", stderr) }
                check(failures.isEmpty, name + " UI composition")
            }
            catch { fputs("UI snapshot failed: \(error)\n", stderr); exit(2) }
        }
        await snapshot("login")
        do {
            let minimum = try WindowsPlatformServices.minimumClientSize()
            check(minimum.width == 860 && minimum.height == 600, "native minimum window size")
        } catch { check(false, "native minimum size: \(error)") }
        check(await store.signIn(server: "http://127.0.0.1:8765", token: "test-token"), "sign in")
        try? await Task.sleep(for: .milliseconds(300))
        if CommandLine.arguments.contains("--smoke-empty") {
            check(store.selectedChannel == nil && composerView.element.visibility == .collapsed, "empty conversation hides composer")
            await snapshot("empty-workspace")
            store.reportError("検証用の接続エラー。再試行してください。")
            check(errorBanner.visibility == .visible, "error visible without a selected channel")
            await snapshot("empty-error")
            store.signOut(); print("Windows empty-workspace smoke test passed"); try? window.close(); isClosed = true; return
        }
        check(!store.messages.isEmpty && messageRows.count == store.displayedMessages.count, "native timeline")
        if CommandLine.arguments.contains("--smoke-performance") {
            scrollToBottom()
            try? await Task.sleep(for: .seconds(3))
            let pumps = KokoroMessagePumpCount(), cpu = KokoroProcessCPUSeconds(), mainCPU = KokoroThreadCPUSeconds(), started = Date()
            try? await Task.sleep(for: .seconds(5))
            let duration = Date().timeIntervalSince(started)
            print("Windows idle: \(KokoroMessagePumpCount() - pumps) pumps / \(duration)s, CPU \((KokoroProcessCPUSeconds() - cpu) / duration * 100)% of one core")
            print("UI thread CPU: \((KokoroThreadCPUSeconds() - mainCPU) / duration * 100)% of one core")
            check(duration < 5.5, "Swift task wakes promptly from idle")
            check(KokoroMessagePumpCount() - pumps < 100, "idle loop waits instead of polling")
            check((KokoroProcessCPUSeconds() - cpu) / duration < 0.2, "idle CPU stays below 20% of one core")
            let mutations = timelineMutationCount
            for _ in 0..<20 { render() }
            check(timelineMutationCount == mutations, "unchanged timeline has no native mutations")
            let priorRows = messageRows
            store.draft = "Performance append"; await store.send()
            check(messageRows.count == priorRows.count + 1, "append adds one row")
            check(zip(priorRows, messageRows).allSatisfy { $0 === $1 }, "append retains all existing rows")
            check(timelineMutationCount - mutations <= 2, "append only inserts its row and optional date")
            let olderRows = messageRows, olderIDs = renderedMessages.map(\.id)
            await loadOlder()
            for (id, row) in zip(olderIDs.dropFirst(), olderRows.dropFirst()) {
                check(renderedMessages.firstIndex(where: { $0.id == id }).map { messageRows[$0] === row } == true,
                    "history prepend retains existing rows except changed grouping at boundary")
            }
            if !CommandLine.arguments.contains("--smoke-no-realtime") {
                check(store.connectionLabel == "接続済み", "native WebSocket connected")
                func post(_ path: String, body: [String: String] = [:]) async {
                    var request = URLRequest(url: URL(string: "http://127.0.0.1:8765/test/" + path)!)
                    request.httpMethod = "POST"
                    request.setValue("test-token", forHTTPHeaderField: "X-Access-Token")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
                    do { _ = try await URLSession.shared.data(for: request) }
                    catch { check(false, "fixture request: \(error)") }
                }
                await post("disconnect")
                try? await Task.sleep(for: .milliseconds(300))
                for _ in 0..<100 {
                    if store.connectionLabel == "接続済み" { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                check(store.connectionLabel == "接続済み", "native WebSocket reconnects")
                let marker = "分割された日本語と😀 " + UUID().uuidString
                await post("publish", body: ["channel_id": store.selectedChannelID!, "content": marker])
                for _ in 0..<100 {
                    if store.messages.contains(where: { $0.text == marker }) { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                check(store.messages.contains(where: { $0.text == marker }), "realtime UTF-8 message after reconnect")
            }
            print("Windows performance regression checks passed")
            store.signOut(); try? window.close(); isClosed = true; return
        }
        if let row = messageRows.first(where: { $0.renderedText.contains("リンク内画像") }) {
            check(row.hasRichText && row.isGrouped, "Markdown and adjacent author grouping")
            check(row.renderedText.contains("🎉") && row.renderedText.contains("🙏🏿") && row.renderedText.contains("@Hana"), "chat references and emoji shortcode rendering")
            check(row.renderedLinkDestinations == ["http://127.0.0.1:8765/test/preview/public"], "linked image destination")
        } else { check(false, "rich Markdown fixture rendered") }
        let plainLinks = TimelineMarkdownView(source: """
        本文 https://x.com/CommandCodeAI/status/2104229776210919460
        🎈 **https://example.test/bold** (http://example.test/path?q=1&b=2).
        https://example.test/wiki/Swift_(programming_language)。
        [https://example.test/label](https://example.test/destination)
        `https://example.test/code` <@USER|https://example.test/name>
        ```text
        https://example.test/code-block
        ```
        """)
        check(plainLinks.linkDestinations == [
            "https://x.com/CommandCodeAI/status/2104229776210919460",
            "https://example.test/bold", "http://example.test/path?q=1&b=2",
            "https://example.test/wiki/Swift_(programming_language)",
            "https://example.test/destination"
        ], "plain URLs become native links, preserving explicit links and excluding code and references")
        check(plainLinks.renderedText.contains("(http://example.test/path?q=1&b=2).")
              && plainLinks.renderedText.contains("Swift_(programming_language)。"),
              "link detection preserves surrounding punctuation")
        plainLinks.dispose()
        let first = store.selectedChannelID!
        store.togglePin(first); check(store.channelSections.first?.channels.contains { $0.id == first } == true, "pinned section")
        check(sidebar?.selectedVisibleRowCount == 1, "one sidebar selection including pinned duplicate")
        check(sidebar?.displayedConnectionLabel == store.connectionLabel, "sidebar connection indicator")
        check(!composerView.attach.isEnabled, "image disabled without API key")
        check(composer.placeholderText == store.selectedChannel!.name + " にメッセージを送信", "composer placeholder")
        scrollToBottom(); try? await Task.sleep(for: .milliseconds(300)); await snapshot("workspace")
        _ = try? scroll.changeView(nil, 0, nil, true); try? await Task.sleep(for: .milliseconds(100)); updateTimelineActions()
        check(latest.visibility == .visible, "latest overlay while reading history")
        check(more.visibility == .visible && scroll.verticalOffset < 1, "history action at top"); await snapshot("history")
        let initialCount = store.messages.count; await loadOlder(); check(store.messages.count > initialCount, "older history")
        store.openSearch(); store.searchQuery = "会話"; await store.searchSelectedChannel()
        check(store.searchResults != nil && store.searchError == nil, "channel search")
        check(searchButton.visibility == .collapsed && searchPanel.visibility == .visible, "inline header search")
        await snapshot("search"); store.closeSearch()
        for _ in 0..<100 {
            if let message = store.displayedMessages.first(where: { $0.id == 122 }),
               message.embedContents.allSatisfy({ !$0.hasUnavailableImage }) { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        check(store.displayedMessages.first { $0.id == 122 }?.embedContents.allSatisfy { !$0.hasUnavailableImage } == true,
              "legacy image metadata restored after search")
        composer.text = String(repeating: "あ", count: 3600); await snapshot("long-draft")
        composer.text = "test"; try? composer.select(4, 0); insertEmoji("😀"); check(store.draft == "test😀" && composer.selectionStart == 6, "emoji insertion")
        if let smokeImages {
            // The app's own captured fixture is also a local image-picker input.
            // All upload/deletion operations are held in the injected service.
            store.updateImgBBAPIKey("smoke-only-key")
            store.addImages([output.appendingPathComponent("workspace.bmp")])
            for _ in 0..<100 {
                if await smokeImages.pendingUploadCount > 0 { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            check(await smokeImages.pendingUploadCount == 1 && !store.canSend, "attachment uploading")
            await snapshot("attachment-uploading")
            check(await smokeImages.completeNext(), "complete fixture upload")
            try? await Task.sleep(for: .milliseconds(100))
            check(store.canSend && store.composerImages.first?.upload != nil, "attachment ready")
            await snapshot("attachment-ready")
            store.removeImage(store.composerImages[0].id)
            for _ in 0..<100 {
                if await smokeImages.pendingDeleteCount > 0 { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            check(await smokeImages.pendingDeleteCount == 1 && !store.canSend, "attachment deleting")
            await snapshot("attachment-deleting")
            check(await smokeImages.completeNextDelete(), "complete fixture deletion")
            try? await Task.sleep(for: .milliseconds(100))
            check(store.composerImages.isEmpty, "attachment removed")
            store.addImages([output.appendingPathComponent("workspace.bmp")])
            for _ in 0..<100 {
                if await smokeImages.pendingUploadCount > 0 { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            check(await smokeImages.failNext(), "fail fixture upload")
            try? await Task.sleep(for: .milliseconds(100))
            check(store.composerImages.first?.error != nil && !store.canSend, "attachment failure")
            await snapshot("attachment-failed")
            store.removeImage(store.composerImages[0].id)
            check(store.composerImages.isEmpty, "failed attachment removed")
            store.updateImgBBAPIKey("")
            await smokeImages.shutdown()
        }
        let scale = (window.content as? FrameworkElement)?.xamlRoot?.rasterizationScale ?? 1
        try? window.appWindow.resizeClient(.init(width: Int32(860 * scale), height: Int32(600 * scale)))
        try? await Task.sleep(for: .milliseconds(100)); await snapshot("minimum-size")
        try? window.appWindow.resizeClient(.init(width: Int32(1160 * scale), height: Int32(780 * scale)))
        registerNotifications(); check(notifications.isRegistered, "Windows notification registration")
        showSettings(); check(settings != nil, "settings window")
        try? await Task.sleep(for: .milliseconds(200))
        if let settings {
            await snapshot("settings", element: settings.captureSurface)
            store.notificationsEnabled = false; settings.refresh()
            await snapshot("settings-disabled", element: settings.captureSurface)
            settings.captureSurface.requestedTheme = .light
            await snapshot("settings-light", element: settings.captureSurface)
        }
        settings?.close()
        sidebar?.channelSearch = "存在しないチャンネル"; await snapshot("sidebar-filter-empty")
        check(sidebar?.visibleChannelIDs.isEmpty == true, "sidebar channel filter")
        sidebar?.channelSearch = ""
        sidebar?.unreadOnly = true; await snapshot("sidebar-unread")
        check(sidebar?.visibleChannelIDs.allSatisfy { id in store.channels.first { $0.id == id }!.unreadCount > 0 } == true, "sidebar unread filter")
        sidebar?.unreadOnly = false
        if let direct = store.channels.first(where: \.isDirectMessage) {
            await store.selectChannel(direct.id); await snapshot("direct-message")
            await store.selectChannel(first)
        }
        store.reportError("検証用の接続エラー。再試行してください。")
        await snapshot("workspace-error"); store.clearError()
        if let surface = window.content as? FrameworkElement {
            surface.requestedTheme = .light; await snapshot("workspace-light")
            store.reportError("検証用の接続エラー。再試行してください。")
            await snapshot("workspace-light-error"); store.clearError(); surface.requestedTheme = .default
        }
        store.draft = "Windows WinUI smoke test"; await store.send(); check(store.draft.isEmpty && store.error == nil, "send")
        store.draft = "preserved draft"
        if let other = store.channels.first(where: { $0.id != first }) { await store.selectChannel(other.id); await store.selectChannel(first); check(store.draft == "preserved draft", "channel drafts") }
        try? await Task.sleep(for: .seconds(1)); store.signOut()
        check(await store.signIn(server: "http://127.0.0.1:8765", token: "test-token"), "second sign in")
        try? await Task.sleep(for: .seconds(2)); check(store.connectionLabel == "接続済み", "realtime connection")
        registerNotifications(); check(notifications.isRegistered, "Windows notification registration")
        store.signOut(); print("Windows WinUI smoke test passed"); try? window.close(); isClosed = true
    }
    private func text(_ value: String, size: Double) -> TextBlock { let control = TextBlock(); control.text = value; control.fontSize = size; control.textWrapping = .wrap; return control }
    private func applyWorkspaceTheme() {
        guard signedInLayout, let surface = window.content as? FrameworkElement else { return }
        messageRows.forEach { $0.applyTheme(surface.actualTheme) }
    }
    private func configureSurface(_ grid: Grid) {
        func apply(_ grid: Grid) { let value: UInt8 = grid.actualTheme == .dark ? 32 : 255; grid.background = SolidColorBrush(.init(a: 255, r: value, g: value, b: value)) }
        apply(grid)
        if grid.tag == nil {
            grid.tag = "surface"
            grid.actualThemeChanged.addHandler { [weak self, weak grid] _, _ in
                if let grid { apply(grid) }; self?.applyWorkspaceTheme()
            }
        }
    }
    private func icon(_ value: String, size: Double) -> TextBlock { let control = text(value, size: size); control.fontFamily = FontFamily("Segoe Fluent Icons"); return control }
    private func configureIconButton(_ button: Button, glyph: String, label: String) {
        button.content = icon(glyph, size: 13); button.width = 30; button.height = 30; button.minWidth = 0; button.minHeight = 0; button.padding = inset(0)
        button.borderThickness = inset(0); button.background = SolidColorBrush(.init(a: 0, r: 0, g: 0, b: 0)); button.opacity = 0.7
        try? ToolTipService.setToolTip(button, label); try? AutomationProperties.setName(button, label)
    }
    private func button(_ value: String, action: @escaping () -> Void) -> Button { let control = Button(); control.content = value; control.click.addHandler { _, _ in action() }; return control }
    private func inset(_ value: Double) -> Thickness { .init(left: value, top: value, right: value, bottom: value) }
    private func corners(_ value: Double) -> CornerRadius { .init(topLeft: value, topRight: value, bottomRight: value, bottomLeft: value) }
    private func line() -> Border { let border = Border(); border.height = 1; border.background = SolidColorBrush(.init(a: 24, r: 128, g: 128, b: 128)); return border }
    private func addRows(_ grid: Grid, _ units: [GridUnitType]) { grid.rowDefinitions.clear(); for unit in units { let row = RowDefinition(); row.height = .init(value: 1, gridUnitType: unit); grid.rowDefinitions.append(row) } }
    private func columns(_ grid: Grid, _ widths: [Double?]) { grid.columnDefinitions.clear(); for width in widths { let column = ColumnDefinition(); column.width = .init(value: width == -1 ? 1 : width ?? 1, gridUnitType: width == -1 ? .auto : width == nil ? .star : .pixel); grid.columnDefinitions.append(column) } }
    private func place(_ element: FrameworkElement, in grid: Grid, row: Int32) { try? Grid.setRow(element, row); grid.children.append(element) }
}
