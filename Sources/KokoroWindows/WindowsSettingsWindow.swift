import Foundation
import KokoroCore
import KokoroWindowsState
import UWP
import WinUI
import WindowsFoundation

/// Keep the same grouped form and conditional rows as macOS SettingsView.
@MainActor
final class WindowsSettingsWindow {
    private let window = Window()
    private let store: WindowsChatStore
    private let notificationService: WindowsNotificationService
    private let scroll = ScrollViewer()
    private let notifications = ToggleSwitch(), sound = ToggleSwitch()
    private let target = ComboBox()
    private let key = PasswordBox()
    private let notificationError = TextBlock(), keyError = TextBlock()
    private let authorization = TextBlock()
    private let permissionActions = StackPanel()
    private let serverValue = TextBlock(), accountValue = TextBlock()
    private var primaryLabels: [TextBlock] = []
    private var primaryControls: [Control] = []
    private var links: [HyperlinkButton] = []
    private var renderedTheme: ElementTheme?
    private var accountRow: FrameworkElement!
    private let signOut = Button()
    private var updating = false
    private var closed = false

    var captureSurface: FrameworkElement { scroll }

    init(store: WindowsChatStore, notificationService: WindowsNotificationService,
         onClose: @escaping () -> Void, onSignOut: @escaping () -> Void,
         onNotificationsEnabled: @escaping () -> Void) {
        self.store = store
        self.notificationService = notificationService
        primaryControls = [notifications, sound, target, key]
        window.title = "設定"
        WindowsTitleBar.configure(for: window)

        let form = StackPanel()
        form.spacing = 12
        form.margin = .init(left: 16, top: 16, right: 16, bottom: 16)
        form.horizontalAlignment = .stretch
        form.verticalAlignment = .top

        let notificationSection = section("通知", in: form)
        configureSwitch(notifications)
        notificationSection.children.append(row("システム通知を表示", control: notifications))
        target.items.append("メンションとダイレクトメッセージ")
        target.items.append("全てのメッセージ")
        target.fontSize = 12
        target.width = 252
        target.minHeight = 28
        target.horizontalContentAlignment = .left
        target.padding = .init(left: 8, top: 3, right: 26, bottom: 3)
        target.horizontalAlignment = .right
        notificationSection.children.append(row("通知の対象", control: target))
        configureSwitch(sound)
        notificationSection.children.append(row("通知音を鳴らす", control: sound))

        authorization.text = "✓ Windows の通知は許可されています"
        authorization.fontSize = 12
        authorization.foreground = SolidColorBrush(.init(a: 255, r: 38, g: 134, b: 63))
        notificationSection.children.append(authorization)
        permissionActions.spacing = 4
        let authorize = Button()
        authorize.content = "Windows の通知を許可する"
        authorize.fontSize = 12
        authorize.minHeight = 26
        primaryControls.append(authorize)
        authorize.click.addHandler { [weak self] _, _ in
            onNotificationsEnabled()
            self?.refresh()
        }
        permissionActions.children.append(authorize)
        let systemSettings = HyperlinkButton()
        systemSettings.content = "システム設定を開く"
        systemSettings.navigateUri = WindowsFoundation.Uri("ms-settings:notifications")
        systemSettings.fontSize = 12
        systemSettings.padding = .init(left: 0, top: 2, right: 0, bottom: 2)
        systemSettings.horizontalAlignment = .left
        links.append(systemSettings)
        permissionActions.children.append(systemSettings)
        notificationSection.children.append(permissionActions)
        notificationSection.children.append(caption("ミュート中のチャンネル、表示中の会話、自分の投稿は通知しません。アプリの起動中に動作します。"))
        configureError(notificationError)
        notificationSection.children.append(notificationError)

        let imageSection = section("画像アップロード", in: form)
        key.placeholderText = "ImgBB の API キー"
        try? AutomationProperties.setName(key, "ImgBB の API キー")
        key.password = store.imgBBAPIKey
        key.fontSize = 13
        key.minHeight = 28
        key.padding = .init(left: 8, top: 4, right: 8, bottom: 4)
        imageSection.children.append(key)
        imageSection.children.append(caption("API キーは Windows の資格情報マネージャーに保存されます。入力すると投稿欄から画像を追加できます。"))
        configureError(keyError)
        imageSection.children.append(keyError)

        let connectionSection = section("接続", in: form)
        configureValue(serverValue)
        configureValue(accountValue)
        connectionSection.children.append(row("サーバー", control: serverValue))
        accountRow = row("アカウント", control: accountValue)
        connectionSection.children.append(accountRow)
        signOut.content = "ログアウト"
        signOut.foreground = SolidColorBrush(.init(a: 255, r: 196, g: 43, b: 36))
        signOut.minHeight = 28
        signOut.fontSize = 13
        signOut.click.addHandler { _, _ in onSignOut() }
        connectionSection.children.append(signOut)

        scroll.content = form
        scroll.horizontalScrollBarVisibility = .disabled
        scroll.verticalScrollBarVisibility = .auto
        window.content = scroll

        notifications.toggled.addHandler { [weak self] _, _ in
            guard let self, !updating else { return }
            store.notificationsEnabled = notifications.isOn
            if notifications.isOn { onNotificationsEnabled() }
            refresh()
        }
        target.selectionChanged.addHandler { [weak self] _, _ in
            guard let self, !updating else { return }
            store.notificationTarget = target.selectedIndex == 1 ? .allMessages : .mentionsAndDirectMessages
        }
        sound.toggled.addHandler { [weak self] _, _ in
            guard let self, !updating else { return }
            store.notificationSoundEnabled = sound.isOn
        }
        // The macOS secure field persists each edit and has no separate Save action.
        key.passwordChanged.addHandler { [weak self] _, _ in
            guard let self, !updating else { return }
            do {
                try WindowsImgBBKeyStore.save(key.password)
                store.updateImgBBAPIKey(key.password)
                setError(nil, on: keyError)
            } catch { setError(error.localizedDescription, on: keyError) }
        }
        window.activated.addHandler { [weak self] _, _ in self?.refresh() }
        scroll.actualThemeChanged.addHandler { [weak self] _, _ in self?.refreshThemeColors() }
        window.closed.addHandler { [weak self] _, _ in self?.closed = true; onClose() }
        refresh()
    }

    func refresh() {
        updating = true
        defer { updating = false }
        notifications.isOn = store.notificationsEnabled
        target.selectedIndex = store.notificationTarget == .allMessages ? 1 : 0
        target.isEnabled = store.notificationsEnabled
        sound.isOn = store.notificationSoundEnabled
        sound.isEnabled = store.notificationsEnabled
        authorization.visibility = notificationService.areNotificationsAllowed ? .visible : .collapsed
        permissionActions.visibility = notificationService.areNotificationsAllowed ? .collapsed : .visible
        setError(notificationService.lastError, on: notificationError)
        serverValue.text = store.serverAddress
        accountValue.text = store.profile.map { "@" + $0.screenName } ?? ""
        accountRow.visibility = store.profile == nil ? .collapsed : .visible
        signOut.visibility = store.profile == nil ? .collapsed : .visible
        refreshThemeColors()
    }

    func show() {
        try? window.activate()
        let scale = scroll.xamlRoot?.rasterizationScale ?? 1
        try? window.appWindow.resizeClient(.init(width: Int32(480 * scale), height: Int32(470 * scale)))
    }

    func close() { if !closed { try? window.close() } }

    private func section(_ title: String, in form: StackPanel) -> StackPanel {
        let group = StackPanel()
        group.spacing = 5
        let heading = TextBlock()
        heading.text = title
        heading.fontSize = 13
        heading.fontWeight = .init(weight: 600)
        heading.margin = .init(left: 8, top: 0, right: 0, bottom: 0)
        primaryLabels.append(heading)
        group.children.append(heading)
        let contents = StackPanel()
        contents.spacing = 6
        let frame = Border()
        frame.padding = .init(left: 12, top: 8, right: 12, bottom: 8)
        frame.cornerRadius = .init(topLeft: 8, topRight: 8, bottomRight: 8, bottomLeft: 8)
        frame.background = SolidColorBrush(.init(a: 12, r: 128, g: 128, b: 128))
        frame.borderBrush = SolidColorBrush(.init(a: 28, r: 128, g: 128, b: 128))
        frame.borderThickness = .init(left: 1, top: 1, right: 1, bottom: 1)
        frame.child = contents
        group.children.append(frame)
        form.children.append(group)
        return contents
    }

    private func row(_ title: String, control: FrameworkElement) -> Grid {
        let grid = Grid()
        let labelColumn = ColumnDefinition()
        labelColumn.width = .init(value: 1, gridUnitType: .star)
        grid.columnDefinitions.append(labelColumn)
        let controlColumn = ColumnDefinition()
        controlColumn.width = .init(value: 1, gridUnitType: .auto)
        grid.columnDefinitions.append(controlColumn)
        let label = TextBlock()
        label.text = title
        label.fontSize = 13
        label.verticalAlignment = .center
        label.margin = .init(left: 0, top: 0, right: 10, bottom: 0)
        primaryLabels.append(label)
        control.verticalAlignment = .center
        control.horizontalAlignment = .right
        if control is Control { try? AutomationProperties.setName(control, title) }
        try? Grid.setColumn(control, 1)
        grid.children.append(label)
        grid.children.append(control)
        return grid
    }

    private func configureSwitch(_ toggle: ToggleSwitch) {
        // WinUI otherwise adds 10 points above and below the 20-point switch.
        // Compact rows keep the complete grouped form inside the macOS 470-point layout.
        _ = toggle.resources.insert("ToggleSwitchPreContentMargin", Double(2))
        _ = toggle.resources.insert("ToggleSwitchPostContentMargin", Double(2))
        toggle.onContent = ""
        toggle.offContent = ""
        toggle.minWidth = 40
        toggle.minHeight = 20
        toggle.padding = .init(left: 0, top: 0, right: 0, bottom: 0)
    }

    private func configureValue(_ text: TextBlock) {
        primaryLabels.append(text)
        text.fontSize = 13
        text.opacity = 0.7
        text.textWrapping = .wrap
        text.maxWidth = 290
        text.textAlignment = .right
        text.isTextSelectionEnabled = true
    }

    private func caption(_ value: String) -> TextBlock {
        let text = TextBlock()
        text.text = value
        text.fontSize = 11
        text.opacity = 0.7
        text.textWrapping = .wrap
        primaryLabels.append(text)
        return text
    }

    private func configureError(_ text: TextBlock) {
        text.fontSize = 12
        text.foreground = SolidColorBrush(.init(a: 255, r: 196, g: 43, b: 36))
        text.textWrapping = .wrap
        text.visibility = .collapsed
    }

    private func setError(_ value: String?, on text: TextBlock) {
        text.text = value ?? ""
        text.visibility = value == nil ? .collapsed : .visible
    }

    private func refreshThemeColors() {
        let theme = scroll.actualTheme
        guard renderedTheme != theme else { return }
        renderedTheme = theme
        let dark = theme == .dark
        let foreground: UInt8 = dark ? 255 : 0
        let background: UInt8 = dark ? 32 : 255
        let primary = SolidColorBrush(.init(a: 255, r: foreground, g: foreground, b: foreground))
        scroll.background = SolidColorBrush(.init(a: 255, r: background, g: background, b: background))
        scroll.foreground = primary
        // ScrollViewer is a ContentControl; explicitly recolor content text when
        // its requested theme changes instead of inheriting the app's old brush.
        primaryLabels.forEach { $0.foreground = primary }
        primaryControls.forEach { $0.foreground = primary }
        authorization.foreground = SolidColorBrush(dark
            ? .init(a: 255, r: 48, g: 209, b: 88) : .init(a: 255, r: 38, g: 134, b: 63))
        let destructive = SolidColorBrush(dark
            ? .init(a: 255, r: 255, g: 69, b: 58) : .init(a: 255, r: 196, g: 43, b: 36))
        signOut.foreground = destructive
        notificationError.foreground = destructive
        keyError.foreground = destructive
        let link = SolidColorBrush(dark
            ? .init(a: 255, r: 196, g: 166, b: 245) : .init(a: 255, r: 110, g: 74, b: 168))
        links.forEach { $0.foreground = link }
    }
}
