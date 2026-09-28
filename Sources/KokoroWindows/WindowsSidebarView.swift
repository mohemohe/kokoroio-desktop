import Foundation
import KokoroCore
import KokoroWindowsState
import UWP
import WinUI
import WindowsFoundation

@MainActor
final class WindowsSidebarView {
    private struct RowID: Equatable { let channelID: String; let pinned: Bool }
    private struct GroupID: Hashable { let section: String; let node: ChannelTreeNode.ID }
    private let store: WindowsChatStore
    private let onSelect: (String) -> Void
    private let root = Grid(), list = StackPanel(), footer = Grid()
    private let search = TextBox(), clearSearch = Button(), unread = ToggleButton()
    private let unreadBadge = Border(), unreadCount = TextBlock()
    private let connectionDot = TextBlock(), connection = TextBlock()
    private let accountName = TextBlock(), accountHandle = TextBlock(), avatarHost = Grid()
    private var selectedRow: RowID?
    private var collapsed: Set<GroupID> = [], filteredCollapsed: Set<GroupID> = []
    private var rowEvents: [EventCleanup] = [], events: [EventCleanup] = [], avatarEvents: [EventCleanup] = []
    private var rowElements: [FrameworkElement] = [], staticElements: [FrameworkElement] = []
    private var staticLabels: [TextBlock] = [], rowLabels: [TextBlock] = []
    private var trayEdges: [Border] = []
    private var buildingRows = false
    private var renderedTheme: ElementTheme?
    private var primaryForeground: SolidColorBrush?
    private var avatarImage: Image?, avatarInitials: TextBlock?
    private var avatarBitmap: BitmapImage?
    private var renderedChannels: [Channel] = []
    private var renderedPins: Set<String> = []
    private var renderedSelection: String?
    private var renderedFilter = ""
    private var renderedUnreadOnly = false
    private var renderedProfile: Profile?
    private var updating = false
    private var needsRows = true
    private var selectedElement: FrameworkElement?
    private(set) var visibleSectionTitles: [String] = []
    private(set) var visibleChannelIDs: [String] = []
    private(set) var selectedVisibleRowCount = 0
    var displayedConnectionLabel: String { connection.text }
    var element: FrameworkElement { root }
    var channelSearch: String {
        get { search.text }
        set { search.text = newValue }
    }
    var unreadOnly: Bool {
        get { unread.isChecked == true }
        set { unread.isChecked = newValue }
    }
    private var isFiltering: Bool { !search.text.isEmpty || unreadOnly }

    init(store: WindowsChatStore, onSelect: @escaping (String) -> Void, onSettings: @escaping () -> Void) {
        self.store = store
        self.onSelect = onSelect
        staticLabels = [unreadCount, connection, accountName, accountHandle]
        root.background = brush(15)
        for unit in [GridUnitType.auto, .auto, .auto, .star, .auto] {
            let row = RowDefinition(); row.height = .init(value: 1, gridUnitType: unit); root.rowDefinitions.append(row)
        }
        let searchGrid = Grid()
        columns(searchGrid, [.auto, .star, .auto])
        let searchIcon = glyph("\u{E721}", size: 12)
        searchIcon.margin = .init(left: 0, top: 0, right: 7, bottom: 0)
        searchGrid.children.append(searchIcon)
        search.placeholderText = "チャンネルを検索"
        try? AutomationProperties.setName(search, "チャンネルを検索")
        search.fontSize = 12
        search.minHeight = 18
        search.minWidth = 0
        search.padding = inset(0)
        search.borderThickness = inset(0)
        search.background = brush(0)
        try? Grid.setColumn(search, 1)
        searchGrid.children.append(search)
        configureButton(clearSearch)
        clearSearch.content = glyph("\u{E711}", size: 10)
        clearSearch.width = 18
        clearSearch.height = 18
        try? ToolTipService.setToolTip(clearSearch, "検索をクリア")
        try? AutomationProperties.setName(clearSearch, "検索をクリア")
        try? Grid.setColumn(clearSearch, 2)
        searchGrid.children.append(clearSearch)
        let searchFrame = Border()
        searchFrame.cornerRadius = corners(7)
        searchFrame.background = brush(20)
        searchFrame.padding = .init(left: 10, top: 9, right: 10, bottom: 9)
        searchFrame.margin = .init(left: 14, top: 10, right: 14, bottom: 0)
        searchFrame.child = searchGrid
        root.children.append(searchFrame)

        let unreadContents = Grid()
        columns(unreadContents, [.auto, .star, .auto])
        let tray = trayIcon()
        tray.margin = .init(left: 0, top: 0, right: 9, bottom: 0)
        unreadContents.children.append(tray)
        let unreadLabel = label("未読メッセージ", size: 12, weight: 500)
        try? Grid.setColumn(unreadLabel, 1); unreadContents.children.append(unreadLabel)
        unreadCount.fontSize = 10; unreadCount.fontWeight = .init(weight: 700)
        styleBadge(unreadBadge, text: unreadCount)
        try? Grid.setColumn(unreadBadge, 2); unreadContents.children.append(unreadBadge)
        unread.content = unreadContents
        try? AutomationProperties.setName(unread, "未読メッセージ")
        unread.horizontalAlignment = .stretch
        unread.horizontalContentAlignment = .stretch
        unread.padding = .init(left: 10, top: 9, right: 10, bottom: 9)
        unread.margin = .init(left: 14, top: 12, right: 14, bottom: 0)
        unread.minHeight = 0
        unread.borderThickness = inset(0)
        unread.background = brush(0)
        try? Grid.setRow(unread, 1); root.children.append(unread)
        let divider = Border(); divider.height = 1; divider.background = brush(35)
        divider.margin = .init(left: 20, top: 17, right: 20, bottom: 17)
        try? Grid.setRow(divider, 2); root.children.append(divider)

        list.spacing = 0
        list.margin = .init(left: 14, top: 0, right: 14, bottom: 0)
        let scroll = ScrollViewer()
        scroll.content = list
        scroll.verticalScrollBarVisibility = .hidden
        scroll.horizontalScrollBarVisibility = .disabled
        try? Grid.setRow(scroll, 3); root.children.append(scroll)
        buildFooter(onSettings: onSettings)
        try? Grid.setRow(footer, 4); root.children.append(footer)

        events.append(search.textChanged.addHandler { [weak self] _, _ in
            guard let self, !updating else { return }
            filteredCollapsed.removeAll()
            needsRows = true
            refresh()
        })
        events.append(clearSearch.click.addHandler { [weak self] _, _ in
            self?.search.text = ""
            _ = try? self?.search.focus(.programmatic)
        })
        events.append(search.gotFocus.addHandler { [weak self] _, _ in self?.refresh() })
        events.append(search.lostFocus.addHandler { [weak self] _, _ in self?.refresh() })
        let updateUnread: RoutedEventHandler = { [weak self] _, _ in
            guard let self, !updating else { return }
            filteredCollapsed.removeAll(); needsRows = true; refresh()
        }
        events.append(unread.checked.addHandler(updateUnread))
        events.append(unread.unchecked.addHandler(updateUnread))
        events.append(root.actualThemeChanged.addHandler { [weak self] _, _ in self?.refreshThemeColors() })
        events.append(root.loaded.addHandler { [weak self] _, _ in self?.refreshThemeColors(force: true) })
        refresh()
    }

    func refresh() {
        guard !updating else { return }
        updating = true
        defer { updating = false }
        refreshThemeColors()
        // A focused native TextBox provides its own clear button.
        clearSearch.visibility = search.text.isEmpty || search.focusState != .unfocused ? .collapsed : .visible
        let total = store.channels.reduce(0) { $0 + $1.unreadCount }
        unreadCount.text = total > 99 ? "99+" : String(total)
        unreadBadge.visibility = total > 0 ? .visible : .collapsed
        connection.text = store.connectionLabel
        connectionDot.foreground = SolidColorBrush(store.connectionLabel == "接続済み"
            ? .init(a: 255, r: 57, g: 166, b: 77) : .init(a: 255, r: 230, g: 145, b: 40))
        if renderedProfile != store.profile {
            renderedProfile = store.profile
            accountName.text = store.profile?.displayName ?? ""
            accountHandle.text = store.profile.map { "@" + $0.screenName } ?? ""
            updateAvatar()
        }
        let selectionChanged = renderedSelection != store.selectedChannelID
        let channelListChanged = renderedChannels.map(\.id) != store.channels.map(\.id)
        guard needsRows || renderedChannels != store.channels || renderedPins != store.pinnedChannelIDs ||
            selectionChanged || renderedFilter != search.text || renderedUnreadOnly != unreadOnly else { return }
        if selectionChanged || channelListChanged { revealSelectedChannel() }
        renderedChannels = store.channels; renderedPins = store.pinnedChannelIDs
        renderedSelection = store.selectedChannelID; renderedFilter = search.text; renderedUnreadOnly = unreadOnly
        needsRows = false
        rowEvents.forEach { $0.dispose() }; rowEvents.removeAll(); rowElements.removeAll()
        list.children.clear()
        rowLabels.removeAll()
        buildingRows = true
        defer { buildingRows = false }
        visibleSectionTitles = []; visibleChannelIDs = []; selectedVisibleRowCount = 0
        selectedElement = nil
        let channels = store.channels.filter {
            (!unreadOnly || $0.unreadCount > 0) && (search.text.isEmpty || $0.name.localizedCaseInsensitiveContains(search.text))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        addSection("ピン留め", id: "pinned", channels: channels.filter { store.isPinned($0.id) }, alwaysVisible: true)
        addSection("チャンネル", id: "public", channels: channels.filter { !$0.isDirectMessage && !isPrivate($0) })
        addSection("プライベート", id: "private", channels: channels.filter { !$0.isDirectMessage && isPrivate($0) })
        addSection("ダイレクトメッセージ", id: "direct", channels: channels.filter(\.isDirectMessage))
        if channels.isEmpty {
            let empty = StackPanel(); empty.spacing = 6; empty.margin = .init(left: 8, top: 14, right: 8, bottom: 0)
            empty.children.append(label(unreadOnly ? "未読はありません" : "チャンネルが見つかりません", size: 12, weight: 500))
            let hint = label(unreadOnly ? "すべての会話を確認しました。" : "検索条件を変更してください。", size: 11)
            hint.opacity = 0.65; empty.children.append(hint); list.children.append(empty)
        }
        if selectionChanged, let selectedElement {
            Task { @MainActor [weak selectedElement] in
                await Task.yield()
                try? selectedElement?.startBringIntoView()
            }
        }
    }

    func dispose() {
        rowEvents.forEach { $0.dispose() }; rowEvents.removeAll()
        events.forEach { $0.dispose() }; events.removeAll()
        avatarEvents.forEach { $0.dispose() }; avatarEvents.removeAll()
        rowElements.removeAll(); staticElements.removeAll()
        staticLabels.removeAll(); rowLabels.removeAll(); trayEdges.removeAll()
        avatarImage = nil; avatarInitials = nil
        avatarBitmap = nil
    }

    private func addSection(_ title: String, id: String, channels: [Channel], alwaysVisible: Bool = false) {
        guard !channels.isEmpty || alwaysVisible else { return }
        visibleSectionTitles.append(title)
        let heading = Grid(); columns(heading, [.star, .auto])
        heading.margin = .init(left: 8, top: visibleSectionTitles.count == 1 ? 0 : 16, right: 8, bottom: 6)
        let name = label(title, size: 11, weight: 600); name.opacity = 0.6; heading.children.append(name)
        let count = label(String(channels.count), size: 11); count.opacity = 0.6
        try? Grid.setColumn(count, 1); heading.children.append(count); list.children.append(heading)
        if channels.isEmpty {
            let empty = label("ピン留めされたチャンネルはありません", size: 11)
            empty.opacity = 0.6; empty.textWrapping = .wrap
            empty.margin = .init(left: 8, top: 4, right: 8, bottom: 4); list.children.append(empty)
        }
        addNodes(ChannelTree.build(channels), section: id, depth: 0)
    }

    private func addNodes(_ nodes: [ChannelTreeNode], section: String, depth: Int) {
        for node in nodes {
            if let channel = node.channel { addChannel(channel, name: node.name, section: section, depth: depth); continue }
            let id = GroupID(section: section, node: node.id)
            let folded = (isFiltering ? filteredCollapsed : collapsed).contains(id)
            let button = Button(); configureButton(button)
            rowElements.append(button)
            button.horizontalAlignment = .stretch; button.horizontalContentAlignment = .stretch
            button.padding = .init(left: Double(8 + depth * 16), top: 4, right: 8, bottom: 4)
            let content = Grid(); columns(content, [.auto, .star, .auto])
            let chevron = glyph(folded ? "\u{E76C}" : "\u{E70D}", size: 9); chevron.width = 16
            chevron.margin = .init(left: 0, top: 0, right: 9, bottom: 0); content.children.append(chevron)
            let count = unreadTotal(node)
            let name = label(node.name, size: 12, weight: count > 0 ? 600 : 400)
            name.textTrimming = .characterEllipsis; try? Grid.setColumn(name, 1); content.children.append(name)
            if count > 0 { let badge = makeBadge(count); try? Grid.setColumn(badge, 2); content.children.append(badge) }
            button.content = content
            rowEvents.append(button.click.addHandler { [weak self] _, _ in
                guard let self else { return }
                if isFiltering { if !filteredCollapsed.insert(id).inserted { filteredCollapsed.remove(id) } }
                else if !collapsed.insert(id).inserted { collapsed.remove(id) }
                needsRows = true; refresh()
            })
            list.children.append(button)
            if !folded { addNodes(node.children, section: section, depth: depth + 1) }
        }
    }

    private func addChannel(_ channel: Channel, name: String, section: String, depth: Int) {
        visibleChannelIDs.append(channel.id)
        let rowID = RowID(channelID: channel.id, pinned: section == "pinned")
        let current: RowID? = store.selectedChannelID.map { id in
            if let selectedRow, selectedRow.channelID == id, !selectedRow.pinned || store.isPinned(id) { return selectedRow }
            return RowID(channelID: id, pinned: store.isPinned(id))
        }
        let isSelected = current == rowID
        let row = Grid(); columns(row, [.star, .auto])
        rowElements.append(row)
        row.cornerRadius = corners(5)
        if isSelected {
            row.background = SolidColorBrush(.init(a: 38, r: 110, g: 74, b: 168))
            selectedVisibleRowCount += 1; selectedElement = row
        }
        let select = Button(); configureButton(select)
        rowElements.append(select)
        select.horizontalAlignment = .stretch; select.horizontalContentAlignment = .stretch
        select.padding = .init(left: Double(8 + depth * 16), top: 4, right: 4, bottom: 4)
        let content = Grid(); columns(content, [.auto, .star, .auto])
        let type = channel.isDirectMessage ? glyph("\u{E8F2}", size: 12) : isPrivate(channel) ? glyph("\u{E72E}", size: 13) : label("#", size: 13, weight: 500)
        type.width = 16; type.margin = .init(left: 0, top: 0, right: 9, bottom: 0); content.children.append(type)
        let nameLabel = label(name, size: 12, weight: channel.unreadCount > 0 ? 600 : 400)
        nameLabel.textTrimming = .characterEllipsis
        try? Grid.setColumn(nameLabel, 1); content.children.append(nameLabel)
        if channel.unreadCount > 0 {
            let badge = makeBadge(channel.unreadCount); badge.margin = .init(left: 4, top: 0, right: 0, bottom: 0)
            try? Grid.setColumn(badge, 2); content.children.append(badge)
        }
        select.content = content
        try? ToolTipService.setToolTip(select, channel.name)
        try? AutomationProperties.setName(select, channel.name + (channel.unreadCount > 0 ? "、未読\(channel.unreadCount)件" : ""))
        rowEvents.append(select.click.addHandler { [weak self] _, _ in
            guard let self else { return }
            selectedRow = rowID; needsRows = true; onSelect(channel.id); refresh()
        })
        row.children.append(select)
        let pin = Button(); configureButton(pin)
        rowElements.append(pin)
        pin.content = glyph("\u{E718}", size: 12)
        pin.width = 20; pin.height = 20
        pin.margin = .init(left: 0, top: 0, right: 8, bottom: 0)
        pin.verticalAlignment = .center
        let pinned = store.isPinned(channel.id)
        pin.opacity = pinned ? 1 : 0; pin.isHitTestVisible = pinned
        try? ToolTipService.setToolTip(pin, pinned ? "ピン留めを解除" : "ピン留め")
        try? AutomationProperties.setName(pin, channel.name + (pinned ? "のピン留めを解除" : "をピン留め"))
        try? Grid.setColumn(pin, 1); row.children.append(pin)
        rowEvents.append(pin.click.addHandler { [weak self] _, _ in self?.store.togglePin(channel.id) })
        rowEvents.append(row.pointerEntered.addHandler { [weak pin] _, _ in pin?.opacity = 1; pin?.isHitTestVisible = true })
        rowEvents.append(row.pointerExited.addHandler { [weak pin] _, _ in pin?.opacity = pinned ? 1 : 0; pin?.isHitTestVisible = pinned })
        list.children.append(row)
    }

    private func revealSelectedChannel() {
        guard let channel = store.selectedChannel, !channel.isDirectMessage else { return }
        let components = channel.name.components(separatedBy: "/")
        guard components.count > 1 else { return }
        for depth in 1..<components.count {
            let node = ChannelTreeNode.ID.group(Array(components.prefix(depth)))
            for section in ["pinned", "public", "private", "direct"] {
                let group = GroupID(section: section, node: node)
                collapsed.remove(group); filteredCollapsed.remove(group)
            }
        }
    }

    private func buildFooter(onSettings: @escaping () -> Void) {
        let container = StackPanel()
        container.spacing = 13
        container.margin = .init(left: 20, top: 17, right: 20, bottom: 17)
        let state = StackPanel(); state.orientation = .horizontal; state.spacing = 6
        connectionDot.text = "●"; connectionDot.fontSize = 7; connectionDot.verticalAlignment = .center
        connection.fontSize = 10; connection.opacity = 0.6
        state.children.append(connectionDot); state.children.append(connection); container.children.append(state)
        let account = Grid(); columns(account, [.auto, .star, .auto])
        avatarHost.width = 33; avatarHost.height = 33
        avatarHost.margin = .init(left: 0, top: 0, right: 10, bottom: 0); account.children.append(avatarHost)
        let names = StackPanel(); names.spacing = 2; names.verticalAlignment = .center
        accountName.fontSize = 12; accountName.fontWeight = .init(weight: 600); accountName.textTrimming = .characterEllipsis
        accountHandle.fontSize = 10; accountHandle.opacity = 0.6; accountHandle.textTrimming = .characterEllipsis
        names.children.append(accountName); names.children.append(accountHandle)
        try? Grid.setColumn(names, 1); account.children.append(names)
        let settings = Button(); configureButton(settings); settings.content = glyph("\u{E713}", size: 15)
        staticElements.append(settings)
        settings.width = 24; settings.height = 24; settings.verticalAlignment = .center
        try? ToolTipService.setToolTip(settings, "設定")
        try? AutomationProperties.setName(settings, "設定")
        events.append(settings.click.addHandler { _, _ in onSettings() })
        try? Grid.setColumn(settings, 2); account.children.append(settings)
        container.children.append(account)
        footer.children.append(container)
        let line = Border(); line.height = 1; line.verticalAlignment = .top; line.background = brush(35)
        footer.children.append(line)
    }

    private func updateAvatar() {
        avatarEvents.forEach { $0.dispose() }; avatarEvents.removeAll()
        avatarHost.children.clear(); avatarBitmap = nil; avatarImage = nil; avatarInitials = nil
        guard let profile = store.profile else { return }
        avatarHost.cornerRadius = corners(33 * 0.24)
        avatarHost.background = SolidColorBrush(avatarColor(profile, saturation: 0.18, brightness: 0.9))
        let initials = label(profile.initials, size: 33 * 0.35, weight: 600, followsTheme: false)
        avatarInitials = initials
        initials.foreground = SolidColorBrush(avatarColor(profile, saturation: 0.48, brightness: 0.43))
        initials.horizontalAlignment = .center; initials.verticalAlignment = .center; avatarHost.children.append(initials)
        guard let url = profile.avatar, ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return }
        let image = Image(); image.width = 33; image.height = 33; image.stretch = .uniformToFill; image.opacity = 0
        avatarImage = image
        avatarHost.children.append(image)
        let bitmap = BitmapImage(); bitmap.decodePixelWidth = 66; avatarBitmap = bitmap
        avatarEvents.append(bitmap.imageOpened.addHandler { [weak image, weak initials] _, _ in image?.opacity = 1; initials?.visibility = .collapsed })
        image.source = bitmap; bitmap.uriSource = Uri(url.absoluteString)
    }

    private func avatarColor(_ profile: Profile, saturation: Double, brightness: Double) -> UWP.Color {
        let degrees = profile.screenName.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % 360 }
        let hue = Double(degrees) / 60, chroma = brightness * saturation
        let secondary = chroma * (1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1)), offset = brightness - chroma
        let rgb: (Double, Double, Double)
        switch Int(hue) {
        case 0: rgb = (chroma, secondary, 0)
        case 1: rgb = (secondary, chroma, 0)
        case 2: rgb = (0, chroma, secondary)
        case 3: rgb = (0, secondary, chroma)
        case 4: rgb = (secondary, 0, chroma)
        default: rgb = (chroma, 0, secondary)
        }
        return .init(a: 255, r: UInt8((rgb.0 + offset) * 255), g: UInt8((rgb.1 + offset) * 255), b: UInt8((rgb.2 + offset) * 255))
    }

    private func isPrivate(_ channel: Channel) -> Bool { channel.kind.lowercased().contains("private") }
    private func unreadTotal(_ node: ChannelTreeNode) -> Int { node.channel?.unreadCount ?? node.children.reduce(0) { $0 + unreadTotal($1) } }
    private func columns(_ grid: Grid, _ units: [GridUnitType]) {
        for unit in units { let column = ColumnDefinition(); column.width = .init(value: 1, gridUnitType: unit); grid.columnDefinitions.append(column) }
    }
    private func label(_ text: String, size: Double, weight: UInt16 = 400, followsTheme: Bool = true) -> TextBlock {
        let value = TextBlock(); value.text = text; value.fontSize = size; value.fontWeight = .init(weight: weight); value.verticalAlignment = .center
        if followsTheme {
            value.foreground = foreground()
            if buildingRows { rowLabels.append(value) } else { staticLabels.append(value) }
        }
        return value
    }
    private func glyph(_ value: String, size: Double) -> TextBlock {
        let text = label(value, size: size); text.fontFamily = FontFamily("Segoe Fluent Icons"); text.opacity = 0.65; return text
    }
    private func trayIcon() -> Grid {
        // WinUI's document and mail glyphs describe different objects from SF tray.
        let tray = Grid(); tray.width = 14; tray.height = 14; tray.verticalAlignment = .center
        func outline(x: Double, y: Double, width: Double, height: Double,
                     thickness: Thickness, radius: Double = 0) {
            let edge = Border(); edge.width = width; edge.height = height
            edge.horizontalAlignment = .left; edge.verticalAlignment = .top
            edge.margin = .init(left: x, top: y, right: 0, bottom: 0)
            edge.borderBrush = foreground(alpha: 166); edge.borderThickness = thickness; edge.cornerRadius = corners(radius)
            tray.children.append(edge)
            trayEdges.append(edge)
        }
        outline(x: 0, y: 4, width: 14, height: 8, thickness: .init(left: 1, top: 0, right: 1, bottom: 1), radius: 1.5)
        outline(x: 0, y: 4, width: 4.5, height: 1, thickness: .init(left: 0, top: 1, right: 0, bottom: 0))
        outline(x: 9.5, y: 4, width: 4.5, height: 1, thickness: .init(left: 0, top: 1, right: 0, bottom: 0))
        outline(x: 4, y: 4, width: 6, height: 3, thickness: .init(left: 1, top: 0, right: 1, bottom: 1), radius: 1)
        outline(x: 2, y: 1, width: 10, height: 3, thickness: .init(left: 1, top: 1, right: 1, bottom: 0), radius: 1)
        return tray
    }
    private func foreground(alpha: UInt8 = 255) -> SolidColorBrush {
        if alpha == 255, let primaryForeground { return primaryForeground }
        let component: UInt8 = root.actualTheme == .dark ? 255 : 0
        let brush = SolidColorBrush(.init(a: alpha, r: component, g: component, b: component))
        if alpha == 255 { primaryForeground = brush }
        return brush
    }
    private func refreshThemeColors(force: Bool = false) {
        guard force || renderedTheme != root.actualTheme else { return }
        renderedTheme = root.actualTheme
        primaryForeground = nil
        let primary = foreground()
        for text in staticLabels + rowLabels { text.foreground = primary }
        let secondary = foreground(alpha: 166)
        for edge in trayEdges { edge.borderBrush = secondary }
    }
    private func configureButton(_ button: Button) {
        button.padding = inset(0); button.minHeight = 0; button.minWidth = 0; button.borderThickness = inset(0); button.background = brush(0)
    }
    private func makeBadge(_ count: Int) -> Border {
        let badge = Border(), text = label(count > 99 ? "99+" : String(count), size: 10, weight: 700)
        styleBadge(badge, text: text); return badge
    }
    private func styleBadge(_ badge: Border, text: TextBlock) {
        badge.background = brush(22); badge.cornerRadius = corners(9)
        badge.padding = .init(left: 6, top: 2, right: 6, bottom: 2); badge.child = text; badge.verticalAlignment = .center
    }
    private func brush(_ alpha: UInt8) -> SolidColorBrush { SolidColorBrush(.init(a: alpha, r: 128, g: 128, b: 128)) }
    private func inset(_ value: Double) -> Thickness { .init(left: value, top: value, right: value, bottom: value) }
    private func corners(_ value: Double) -> CornerRadius { .init(topLeft: value, topRight: value, bottomRight: value, bottomLeft: value) }
}
