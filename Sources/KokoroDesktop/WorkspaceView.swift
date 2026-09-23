import AppKit
import KokoroCore
import SwiftUI

enum KChatPalette {
    static let accent = Color(red: 0.43, green: 0.29, blue: 0.66)
}

struct WorkspaceView: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isSearchFocused: Bool

    private var contentAccent: Color {
        colorScheme == .dark ? Color(red: 0.77, green: 0.65, blue: 0.96) : KChatPalette.accent
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 220, idealWidth: 246, maxWidth: 310)
            conversation
                .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
                .ignoresSafeArea(.container, edges: .top)
        }
        .frame(minWidth: 760, minHeight: 560)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                TextField("チャンネルを検索", text: $store.channelSearch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .accessibilityLabel("チャンネルを検索")
                if !store.channelSearch.isEmpty {
                    Button { store.channelSearch = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("検索をクリア")
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 14)
            .padding(.top, 10)

            Toggle(isOn: $store.unreadOnly) {
                HStack(spacing: 9) {
                    Image(systemName: "tray")
                        .font(.system(size: 14))
                    Text("未読メッセージ")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    if store.totalUnreadCount > 0 {
                        unreadBadge(store.totalUnreadCount)
                    }
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .toggleStyle(.button)
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .accessibilityAddTraits(store.unreadOnly ? .isSelected : [])

            Divider()
                .padding(.horizontal, 20)
                .padding(.vertical, 17)

            ScrollViewReader { proxy in
                List(selection: Binding(
                    get: { store.selectedChannelID },
                    set: { if let id = $0 { store.selectChannel(id) } }
                )) {
                    ChannelSidebarSection(title: "チャンネル", channels: publicChannels, icon: "number")
                    ChannelSidebarSection(title: "プライベート", channels: privateChannels, icon: "lock.fill")
                    ChannelSidebarSection(title: "ダイレクトメッセージ", channels: directChannels, icon: "bubble.left")
                    if store.filteredChannels.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(store.unreadOnly ? "未読はありません" : "チャンネルが見つかりません")
                                .font(.system(size: 12, weight: .medium))
                            Text(store.unreadOnly ? "すべての会話を確認しました。" : "検索条件を変更してください。")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
                .task(id: store.selectedChannelID) {
                    guard let id = store.selectedChannelID else { return }
                    // Give the channel tree a layout pass to expand the selected row.
                    await Task.yield()
                    guard !Task.isCancelled, store.selectedChannelID == id,
                          store.filteredChannels.contains(where: { $0.id == id }) else { return }
                    proxy.scrollTo(id)
                }
            }
            .frame(maxHeight: .infinity)

            sidebarFooter
        }
        .background { SidebarMaterial().ignoresSafeArea() }
    }

    private var publicChannels: [Channel] {
        store.filteredChannels.filter { !$0.isDirectMessage && !isPrivate($0) }
    }

    private var privateChannels: [Channel] {
        store.filteredChannels.filter { !$0.isDirectMessage && isPrivate($0) }
    }

    private var directChannels: [Channel] {
        store.filteredChannels.filter(\.isDirectMessage)
    }

    private func isPrivate(_ channel: Channel) -> Bool {
        channel.kind.lowercased().contains("private")
    }

    private func unreadBadge(_ count: Int) -> some View {
        Text(count > 99 ? "99+" : String(count))
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 6) {
                Circle()
                    .fill(store.isConnected ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(store.connectionLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 10) {
                if let profile = store.profile {
                    ChatAvatar(profile: profile, size: 33)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text("@\(profile.screenName)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("設定")
                .accessibilityLabel("設定")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 17)
        .overlay(alignment: .top) { Divider() }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            if let channel = store.selectedChannel {
                channelHeader(channel)
                if let error = store.errorMessage { errorBanner(error) }
                ChatTimelineView(channel: channel)
                    .id(store.isShowingSearchResults ? "search" : "timeline")
                Divider().opacity(0.5)
                ComposerView()
            } else {
                if let error = store.errorMessage { errorBanner(error) }
                ContentUnavailableView {
                    Label("会話をはじめましょう", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("サイドバーからチャンネルを選択してください。")
                } actions: {
                    Button("チャンネルを再読み込み") { store.refresh() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func channelHeader(_ channel: Channel) -> some View {
        HStack(spacing: 12) {
            Image(systemName: channel.isDirectMessage ? "bubble.left" : isPrivate(channel) ? "lock" : "number")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(channel.name)
                    .font(.system(size: 16, weight: .bold))
                    .lineLimit(1)
                if !channel.description.isEmpty {
                    Text(channel.description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(channel.isDirectMessage ? "ダイレクトメッセージ" : isPrivate(channel) ? "プライベートチャンネル" : "パブリックチャンネル")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if store.isSearchOpen {
                channelSearchField
            } else {
                Button {
                    store.openSearch()
                    isSearchFocused = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("チャンネル内を検索")
                .accessibilityLabel("チャンネル内を検索")
            }
            Button {
                if store.isSearchOpen { store.closeSearch(); isSearchFocused = false }
                else { store.refresh() }
            } label: {
                Image(systemName: store.isSearchOpen ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 13))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(store.isSearchOpen ? "検索を閉じる" : "最新のメッセージを取得")
            .accessibilityLabel(store.isSearchOpen ? "検索を閉じる" : "最新のメッセージを取得")
        }
        .padding(.horizontal, 25)
        .padding(.vertical, 17)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var channelSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("このチャンネルのメッセージを検索", text: $store.searchQuery)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .onSubmit { store.searchSelectedChannel() }
                .accessibilityLabel("このチャンネルのメッセージを検索")
            Button("検索") { store.searchSelectedChannel() }
                .disabled(store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                .help("2文字以上入力してください。")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(minWidth: 150, idealWidth: 280, maxWidth: 360, minHeight: 30)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
            Text(error)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("再試行") { store.refresh() }
                .buttonStyle(.plain)
                .foregroundStyle(contentAccent)
            Button { store.clearError() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel("エラーを閉じる")
        }
        .font(.system(size: 11))
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
    }
}

/// Let AppKit render the sidebar material, including inactive-window and accessibility appearances.
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct ChatTimelineView: View {
    let channel: Channel
    @EnvironmentObject private var store: ChatStore
    @State private var earlierAnchor: Int?
    @State private var didInitialScroll = false
    @State private var bottomFrame = CGRect.null
    private let bottomAnchor = "timeline-bottom"
    private var displayedMessages: [Message] { store.displayedMessages }

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if store.isShowingSearchResults && store.isSearching {
                            ProgressView("検索中…")
                                .font(.system(size: 12))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 80)
                        } else if store.isShowingSearchResults, let error = store.searchError {
                            ContentUnavailableView {
                                Label("検索できませんでした", systemImage: "exclamationmark.magnifyingglass")
                            } description: {
                                Text(error)
                            } actions: {
                                Button("再試行") { store.searchSelectedChannel() }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 60)
                        } else if store.isShowingSearchResults && displayedMessages.isEmpty {
                            ContentUnavailableView.search
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 60)
                        } else if !store.isShowingSearchResults && store.isLoadingMessages && store.messages.isEmpty {
                            ProgressView("メッセージを読み込み中…")
                                .font(.system(size: 12))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 80)
                        } else {
                            if store.isShowingSearchResults {
                                Text("検索結果: \(displayedMessages.count) 件")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 26)
                                    .padding(.vertical, 14)
                            } else {
                                historyHeader
                            }
                            ForEach(Array(displayedMessages.enumerated()), id: \.element.id) { index, message in
                                if startsDay(at: index) { daySeparator(message.publishedAt) }
                                MessageRow(message: message, isGrouped: groupsWithPrevious(at: index))
                                    .id(message.id)
                            }
                        }
                        Color.clear
                            .frame(height: 15)
                            .id(bottomAnchor)
                            .background {
                                GeometryReader { bottom in
                                    Color.clear.preference(
                                        key: TimelineBottomPreference.self,
                                        value: bottom.frame(in: .global)
                                    )
                                }
                            }
                    }
                }
                .onPreferenceChange(TimelineBottomPreference.self) { bottom in
                    bottomFrame = bottom
                    if #unavailable(macOS 15), !store.isShowingSearchResults { updateBottomState(bottom, in: geometry.frame(in: .global)) }
                }
                .onChange(of: geometry.frame(in: .global)) { _, viewport in
                    if #unavailable(macOS 15), !store.isShowingSearchResults { updateBottomState(bottomFrame, in: viewport) }
                }
                .modifier(TimelineScrollTracking(isSearch: store.isShowingSearchResults) { atBottom in
                    guard !store.isShowingSearchResults else { return }
                    store.isAtBottom = atBottom
                    if atBottom { Task { await store.markSelectedChannelRead() } }
                })
                .onAppear {
                    if !store.isShowingSearchResults && !store.messages.isEmpty { scrollToLatest(proxy, animated: false) }
                }
                .onChange(of: store.selectedChannelID) { _, _ in
                    didInitialScroll = false
                    earlierAnchor = nil
                    store.isAtBottom = true
                }
                .onChange(of: store.displayedMessages.last?.id) { old, new in
                    guard !store.isShowingSearchResults, new != nil else { return }
                    let isOwnMessage = store.messages.last?.profile.id == store.profile?.id
                    if !didInitialScroll || old == nil || store.isAtBottom || isOwnMessage {
                        scrollToLatest(proxy, animated: didInitialScroll)
                    }
                }
                .onChange(of: store.isLoadingMore) { old, new in
                    if old && !new, let anchor = earlierAnchor {
                        earlierAnchor = nil
                        DispatchQueue.main.async {
                            proxy.scrollTo(anchor, anchor: .top)
                        }
                    }
                }
                .overlay(alignment: .bottom) {
                    if !store.isShowingSearchResults && !store.isAtBottom && !store.messages.isEmpty && !store.isLoadingMessages {
                        Button {
                            scrollToLatest(proxy, animated: true)
                        } label: {
                            Label("最新のメッセージ", systemImage: "arrow.down")
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 13)
                                .padding(.vertical, 8)
                                .background(.regularMaterial, in: Capsule())
                                .overlay(Capsule().strokeBorder(.primary.opacity(0.1)))
                                .shadow(color: .black.opacity(0.08), radius: 7, y: 2)
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 9)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var historyHeader: some View {
        if store.hasMoreMessages {
            Button {
                earlierAnchor = store.messages.first?.id
                store.loadOlderMessages()
            } label: {
                HStack(spacing: 7) {
                    if store.isLoadingMore {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up")
                    }
                    Text(store.isLoadingMore ? "読み込み中…" : "以前のメッセージを読み込む")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.plain)
            .disabled(store.isLoadingMore)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: channel.isDirectMessage ? "bubble.left.and.bubble.right" : "number")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(KChatPalette.accent)
                    .frame(width: 52, height: 52)
                    .background(KChatPalette.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                Text(channel.name)
                    .font(.system(size: 23, weight: .bold))
                Text(store.messages.isEmpty ? "最初のメッセージを送って、会話をはじめましょう。" : "このチャンネルの会話はここから始まります。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if !channel.description.isEmpty {
                    Text(channel.description)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 26)
            .padding(.top, 17)
            .padding(.bottom, 23)
        }
    }

    private func daySeparator(_ date: Date) -> some View {
        HStack(spacing: 12) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            Text(date, format: .dateTime.year().month().day().weekday())
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 12)
    }

    private func startsDay(at index: Int) -> Bool {
        index == 0 || !Calendar.current.isDate(displayedMessages[index - 1].publishedAt,
                                             inSameDayAs: displayedMessages[index].publishedAt)
    }

    private func groupsWithPrevious(at index: Int) -> Bool {
        guard index > 0, !startsDay(at: index) else { return false }
        let previous = displayedMessages[index - 1]
        let current = displayedMessages[index]
        guard !previous.isDeleted, !current.isDeleted else { return false }
        return previous.profile.id == current.profile.id
            && current.publishedAt.timeIntervalSince(previous.publishedAt) < 300
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy, animated: Bool) {
        didInitialScroll = true
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
            } else {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        }
    }

    private func updateBottomState(_ bottom: CGRect, in viewport: CGRect) {
        // Both rectangles use the window's coordinate space. The scroll content's
        // local coordinates do not include the scroll offset on macOS.
        // The spacer begins exactly after the newest message, so its first edge
        // being visible means the newest message is completely on screen.
        let atBottom = !bottom.isNull && viewport.height > 0
            && bottom.minY <= viewport.maxY + 2 && bottom.maxY >= viewport.minY
        if store.isAtBottom != atBottom { store.isAtBottom = atBottom }
        if atBottom { Task { await store.markSelectedChannelRead() } }
    }
}

private struct TimelineBottomPreference: PreferenceKey {
    static var defaultValue = CGRect.null
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

private struct TimelineScrollTracking: ViewModifier {
    let isSearch: Bool
    let changed: (Bool) -> Void
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.defaultScrollAnchor(isSearch ? .top : .bottom, for: .initialOffset)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 24
            } action: { _, atBottom in changed(atBottom) }
        } else {
            content.defaultScrollAnchor(isSearch ? .top : .bottom)
        }
    }
}
