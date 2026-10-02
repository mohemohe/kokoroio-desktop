import Foundation
import KokoroWindowsState
import UWP
import WinUI
import WindowsFoundation

/// The same visual grouping as the macOS ComposerView: previews, editor and
/// icon toolbar share one card; the keyboard hint is outside the card.
@MainActor
final class WindowsComposerView {
    let editor = TextBox()
    let send = Button()
    let attach = Button()
    let emoji = Button()

    private let store: WindowsChatStore
    private let root = StackPanel()
    private let card = Border()
    private let contents = StackPanel()
    private let previewScroll = ScrollViewer()
    private let previews = StackPanel()
    private let previewDivider = Border()
    private let toolbar = Grid()
    private let tools = StackPanel()
    private let sendContent = Grid()
    private let sending = ProgressRing()
    private let sendGlyph = TextBlock()
    private let hint = TextBlock()
    private var events: [EventCleanup] = []
    private var previewEvents: [EventCleanup] = []
    private var previewControls: [FrameworkElement] = []
    private var previewImages: [Image] = []
    private var previewBitmaps: [BitmapImage] = []
    private var toolbarIcons: [TextBlock] = []
    private var previewSignature = ""
    private var colorSignature: Int?
    private var disposed = false

    var element: FrameworkElement { root }

    init(store: WindowsChatStore, onAddImages: @escaping () -> Void,
         onEmoji: @escaping (FrameworkElement) -> Void, onSend: @escaping () -> Void) {
        self.store = store
        root.spacing = 8
        root.margin = .init(left: 24, top: 10, right: 24, bottom: 16)
        card.cornerRadius = .init(topLeft: 10, topRight: 10, bottomRight: 10, bottomLeft: 10)
        card.borderThickness = thickness(1)
        card.child = contents
        root.children.append(card)

        previews.orientation = .horizontal
        previews.spacing = 8
        previews.margin = .init(left: 12, top: 8, right: 12, bottom: 8)
        previewScroll.height = 82
        previewScroll.horizontalScrollBarVisibility = .auto
        previewScroll.verticalScrollBarVisibility = .disabled
        previewScroll.content = previews
        previewDivider.height = 1
        contents.children.append(previewScroll)
        contents.children.append(previewDivider)

        editor.fontSize = 13
        editor.acceptsReturn = true
        editor.textWrapping = .wrap
        editor.minHeight = 38
        editor.maxHeight = 170
        editor.padding = .init(left: 15, top: 11, right: 15, bottom: 11)
        editor.borderThickness = thickness(0)
        editor.background = brush(0, 0, 0, alpha: 0)
        editor.cornerRadius = .init(topLeft: 10, topRight: 10, bottomRight: 0, bottomLeft: 0)
        editor.name = "MessageEditor"
        try? AutomationProperties.setName(editor, "メッセージ")
        try? ScrollViewer.setVerticalScrollBarVisibility(editor, .auto)
        contents.children.append(editor)

        let toolColumn = ColumnDefinition()
        toolColumn.width = .init(value: 1, gridUnitType: .star)
        let sendColumn = ColumnDefinition()
        sendColumn.width = .init(value: 1, gridUnitType: .auto)
        toolbar.columnDefinitions.append(toolColumn)
        toolbar.columnDefinitions.append(sendColumn)
        toolbar.margin = .init(left: 12, top: 0, right: 12, bottom: 9)
        tools.orientation = .horizontal
        tools.spacing = 10
        toolbarIcons.append(configureIcon(attach, glyph: "\u{E91B}", label: "画像を追加", size: 16))
        toolbarIcons.append(configureIcon(emoji, glyph: "\u{E899}", label: "絵文字を挿入", size: 16))
        tools.children.append(attach)
        tools.children.append(emoji)
        toolbar.children.append(tools)

        send.width = 30
        send.height = 28
        send.minWidth = 0
        send.minHeight = 0
        send.padding = thickness(0)
        send.borderThickness = thickness(0)
        send.cornerRadius = .init(topLeft: 7, topRight: 7, bottomRight: 7, bottomLeft: 7)
        sendGlyph.text = "\u{E74A}"
        sendGlyph.fontFamily = FontFamily("Segoe Fluent Icons")
        sendGlyph.fontSize = 13
        sendGlyph.fontWeight = .init(weight: 700)
        sendGlyph.horizontalAlignment = .center
        sendGlyph.verticalAlignment = .center
        sending.width = 16
        sending.height = 16
        sending.minWidth = 0
        sending.minHeight = 0
        sendContent.children.append(sendGlyph)
        sendContent.children.append(sending)
        send.content = sendContent
        try? ToolTipService.setToolTip(send, "メッセージを送信（Enter）")
        try? AutomationProperties.setName(send, "メッセージを送信")
        try? Grid.setColumn(send, 1)
        toolbar.children.append(send)
        contents.children.append(toolbar)

        hint.text = "Enterで送信 · Shift + Enterで改行"
        hint.fontSize = 10
        hint.horizontalAlignment = .right
        hint.opacity = 0.45
        root.children.append(hint)
        events.append(attach.click.addHandler { _, _ in onAddImages() })
        events.append(emoji.click.addHandler { [weak emoji] _, _ in
            if let emoji { onEmoji(emoji) }
        })
        events.append(send.click.addHandler { _, _ in onSend() })
        events.append(root.actualThemeChanged.addHandler { [weak self] _, _ in self?.refreshColors() })
        refresh()
    }

    func refresh() {
        guard !disposed else { return }
        editor.placeholderText = "\(store.selectedChannel?.name ?? "チャンネル") にメッセージを送信"
        editor.isEnabled = !store.isSending
        attach.isEnabled = !store.isSending && store.selectedChannel?.membership?.canPost == true
        attach.opacity = attach.isEnabled ? 0.7 : 0.35
        emoji.isEnabled = !store.isSending
        emoji.opacity = 0.7
        try? ToolTipService.setToolTip(attach, "画像を追加")
        send.isEnabled = store.canSend
        sendGlyph.visibility = store.isSending ? .collapsed : .visible
        sending.visibility = store.isSending ? .visible : .collapsed
        sending.isActive = store.isSending
        refreshColors()
        refreshPreviews()
    }

    func dispose() {
        guard !disposed else { return }
        disposed = true
        events.forEach { $0.dispose() }
        events.removeAll()
        clearPreviews()
        previewScroll.content = nil
        send.content = nil
        attach.content = nil
        emoji.content = nil
        toolbarIcons.removeAll()
        sendContent.children.clear()
        tools.children.clear()
        toolbar.children.clear()
        contents.children.clear()
        card.child = nil
        root.children.clear()
    }

    private func refreshColors() {
        let dark = root.actualTheme == .dark
        let signature = (dark ? 1 : 0) + (store.canSend ? 2 : 0)
        guard colorSignature != signature else { return }
        colorSignature = signature
        let foreground: UInt8 = dark ? 255 : 0
        card.background = brush(dark ? 32 : 255, dark ? 32 : 255, dark ? 32 : 255)
        card.borderBrush = brush(foreground, foreground, foreground, alpha: 41)
        previewDivider.background = brush(foreground, foreground, foreground, alpha: 28)
        send.background = store.canSend ? brush(110, 74, 168) : brush(foreground, foreground, foreground, alpha: 15)
        sendGlyph.foreground = store.canSend ? brush(255, 255, 255) : brush(foreground, foreground, foreground, alpha: 140)
        sending.foreground = brush(foreground, foreground, foreground, alpha: 140)
    }

    private func refreshPreviews() {
        let images = store.composerImages
        previewScroll.visibility = images.isEmpty ? .collapsed : .visible
        previewDivider.visibility = images.isEmpty ? .collapsed : .visible
        let signature = "\(store.selectedChannelID ?? ""): \(store.isSending) " + images.map {
            "\($0.id):\($0.localURL):\($0.isUploading):\($0.error ?? "")"
        }.joined(separator: "|")
        guard signature != previewSignature else { return }
        previewSignature = signature
        clearPreviews()
        for image in images {
            let thumbnail = Grid()
            thumbnail.width = 76
            thumbnail.height = 64
            let frame = Border()
            frame.cornerRadius = .init(topLeft: 6, topRight: 6, bottomRight: 6, bottomLeft: 6)
            frame.background = brush(128, 128, 128, alpha: 20)
            let preview = Image()
            preview.width = 76
            preview.height = 64
            preview.stretch = .uniformToFill
            let bitmap = BitmapImage()
            bitmap.autoPlay = false
            bitmap.decodePixelWidth = 152
            bitmap.uriSource = Uri(image.localURL.absoluteString)
            preview.source = bitmap
            frame.child = preview
            thumbnail.children.append(frame)
            previewControls.append(contentsOf: [thumbnail, frame, preview])
            previewImages.append(preview)
            previewBitmaps.append(bitmap)
            if image.isUploading {
                let overlay = Border()
                overlay.background = brush(0, 0, 0, alpha: 77)
                overlay.cornerRadius = frame.cornerRadius
                let spinner = ProgressRing()
                spinner.width = 18
                spinner.height = 18
                spinner.minWidth = 0
                spinner.minHeight = 0
                spinner.foreground = brush(255, 255, 255)
                spinner.isActive = true
                overlay.child = spinner
                thumbnail.children.append(overlay)
                previewControls.append(contentsOf: [overlay, spinner])
            } else if image.error != nil {
                let badge = Border()
                badge.width = 26
                badge.height = 26
                badge.background = brush(220, 50, 47)
                badge.cornerRadius = .init(topLeft: 13, topRight: 13, bottomRight: 13, bottomLeft: 13)
                badge.horizontalAlignment = .center
                badge.verticalAlignment = .center
                let warning = TextBlock()
                warning.text = "\u{E7BA}"
                warning.fontFamily = FontFamily("Segoe Fluent Icons")
                warning.fontSize = 16
                warning.foreground = brush(255, 255, 255)
                warning.horizontalAlignment = .center
                warning.verticalAlignment = .center
                badge.child = warning
                thumbnail.children.append(badge)
                previewControls.append(contentsOf: [badge, warning])
            }
            let remove = Button()
            previewControls.append(configureIcon(remove, glyph: "\u{E711}", label: "画像を削除", size: 9))
            remove.width = 18
            remove.height = 18
            remove.margin = thickness(3)
            remove.cornerRadius = .init(topLeft: 9, topRight: 9, bottomRight: 9, bottomLeft: 9)
            remove.background = brush(0, 0, 0, alpha: 179)
            remove.foreground = brush(255, 255, 255)
            remove.horizontalAlignment = .right
            remove.verticalAlignment = .top
            remove.isEnabled = !store.isSending
            try? AutomationProperties.setName(remove, "\(image.fileName) を削除")
            previewEvents.append(remove.click.addHandler { [weak self] _, _ in self?.store.removeImage(image.id) })
            thumbnail.children.append(remove)
            previewControls.append(remove)
            try? ToolTipService.setToolTip(thumbnail, image.error ?? image.fileName)
            previews.children.append(thumbnail)
        }
    }

    private func clearPreviews() {
        previewEvents.forEach { $0.dispose() }
        previewEvents.removeAll()
        previewImages.forEach { $0.source = nil }
        previews.children.clear()
        previewControls.compactMap { $0 as? Border }.forEach { $0.child = nil }
        previewControls.compactMap { $0 as? Panel }.forEach { $0.children.clear() }
        previewControls.compactMap { $0 as? ContentControl }.forEach { $0.content = nil }
        previewImages.removeAll()
        previewBitmaps.removeAll()
        previewControls.removeAll()
    }

    private func configureIcon(_ button: Button, glyph: String, label: String, size: Double) -> TextBlock {
        let icon = TextBlock()
        icon.text = glyph
        icon.fontFamily = FontFamily("Segoe Fluent Icons")
        icon.fontSize = size
        button.content = icon
        button.width = 28
        button.height = 28
        button.minWidth = 0
        button.minHeight = 0
        button.padding = thickness(0)
        button.borderThickness = thickness(0)
        button.background = brush(0, 0, 0, alpha: 0)
        try? ToolTipService.setToolTip(button, label)
        try? AutomationProperties.setName(button, label)
        return icon
    }

    private func thickness(_ value: Double) -> Thickness {
        .init(left: value, top: value, right: value, bottom: value)
    }

    private func brush(_ red: UInt8, _ green: UInt8, _ blue: UInt8, alpha: UInt8 = 255) -> SolidColorBrush {
        SolidColorBrush(.init(a: alpha, r: red, g: green, b: blue))
    }
}
