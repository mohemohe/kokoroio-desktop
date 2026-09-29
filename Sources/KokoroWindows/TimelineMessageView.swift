import Foundation
import KokoroCore
import UWP
import WinUI
import WindowsFoundation

/// A native message row. Server-provided HTML is never loaded or executed.
@MainActor
final class TimelineMessageView {
    private let root = Grid()
    private let body = StackPanel()
    private let media = StackPanel()
    private let theme = WindowsTimelineTheme()
    private let message: Message
    private let onLayoutChange: (() -> Void)?
    private var retainedElements: [FrameworkElement] = []
    private var bitmaps: [BitmapImage] = []
    private var imageControls: [Image] = []
    private var events: [EventCleanup] = []
    private var revealsSensitiveContent = false
    private var disposed = false
    private var isHovered = false
    private var markdown: TimelineMarkdownView?
    private var menu: MenuFlyout?
    private var copyItem: MenuFlyoutItem?

    let isGrouped: Bool

    var element: FrameworkElement { root }
    var renderedText: String { markdown?.renderedText ?? "このメッセージは削除されました" }
    var hasRichText: Bool { markdown?.hasRichText == true }
    var renderedLinkDestinations: [String] { markdown?.linkDestinations ?? [] }

    func applyTheme(_ value: ElementTheme) {
        guard !disposed else { return }
        theme.apply(value)
        markdown?.applyTheme(value)
    }

    init(message: Message, isGrouped: Bool = false, onLayoutChange: (() -> Void)? = nil) {
        self.message = message
        self.isGrouped = isGrouped
        self.onLayoutChange = onLayoutChange
        let avatarColumn = ColumnDefinition()
        avatarColumn.width = .init(value: 38, gridUnitType: .pixel)
        let bodyColumn = ColumnDefinition()
        bodyColumn.width = .init(value: 1, gridUnitType: .star)
        root.columnDefinitions.append(avatarColumn)
        root.columnDefinitions.append(bodyColumn)
        root.horizontalAlignment = .stretch
        root.padding = .init(left: 26, top: isGrouped ? 3 : 9, right: 26, bottom: isGrouped ? 3 : 9)
        root.background = SolidColorBrush(.init(a: 0, r: 128, g: 128, b: 128))
        theme.bind(root) { [weak self] control, value in
            control.background = WindowsTimelineTheme.primary(value, alpha: self?.isHovered == true ? 6 : 0)
        }
        body.spacing = 4
        body.margin = .init(left: 12, top: 0, right: 0, bottom: 0)
        try? Grid.setColumn(body, 1)
        root.children.append(body)
        retainedElements.append(body)

        let timestamp = label(message.publishedAt.formatted(.dateTime.hour().minute()), size: isGrouped ? 10 : 11)
        timestamp.opacity = isGrouped ? 0 : 0.65
        if isGrouped {
            timestamp.fontFamily = FontFamily("Consolas")
            timestamp.horizontalAlignment = .right
            timestamp.verticalAlignment = .top
            timestamp.margin = .init(left: 0, top: 3, right: 0, bottom: 0)
            root.children.append(timestamp)
        } else {
            let avatar = thumbnail(url: message.avatar ?? message.profile.avatar,
                                   width: 38, height: 38, avatarInitials: message.profile.initials)
            avatar.verticalAlignment = .top
            root.children.append(avatar)
            let heading = label(message.displayName, size: 13)
            heading.fontWeight = .init(weight: 600)
            heading.maxLines = 1
            heading.textTrimming = .characterEllipsis
            timestamp.verticalAlignment = .center
            let header = StackPanel()
            header.orientation = .horizontal
            header.spacing = 8
            header.children.append(heading)
            header.children.append(timestamp)
            retainedElements.append(header)
            body.children.append(header)
            events.append(body.sizeChanged.addHandler { [weak self, weak heading, weak timestamp] _, _ in
                guard let self, self.body.actualWidth > 0 else { return }
                heading?.maxWidth = max(40, self.body.actualWidth - (timestamp?.actualWidth ?? 50) - 8)
            })
        }
        events.append(root.pointerEntered.addHandler { [weak self, weak timestamp] _, _ in
            guard let self else { return }
            self.isHovered = true
            self.root.background = WindowsTimelineTheme.primary(self.theme.current, alpha: 6)
            if self.isGrouped { timestamp?.opacity = 0.5 }
        })
        events.append(root.pointerExited.addHandler { [weak self, weak timestamp] _, _ in
            guard let self else { return }
            self.isHovered = false
            self.root.background = WindowsTimelineTheme.primary(self.theme.current, alpha: 0)
            if self.isGrouped { timestamp?.opacity = 0 }
        })
        let context = MenuFlyout()
        let copy = MenuFlyoutItem()
        copy.text = "メッセージをコピー"
        copy.isEnabled = !message.isDeleted
        events.append(copy.click.addHandler { _, _ in
            guard !message.isDeleted else { return }
            let data = DataPackage()
            try? data.setText(message.text)
            try? Clipboard.setContent(data)
        })
        context.items.append(copy)
        root.contextFlyout = context
        menu = context
        copyItem = copy
        if message.isDeleted {
            let text = label("このメッセージは削除されました", size: 13)
            text.fontStyle = .italic
            text.opacity = 0.6
            body.children.append(text)
        } else {
            let content = TimelineMarkdownView(source: message.rawContent.isEmpty ? message.text : message.rawContent)
            markdown = content
            body.children.append(content.element)
        }
        guard !message.isDeleted else { return }

        media.spacing = 8
        media.margin = .init(left: 0, top: 4, right: 0, bottom: 0)
        body.children.append(media)
        retainedElements.append(media)
        renderMedia()
    }

    /// Called when the owning timeline replaces its rows.
    func dispose() {
        guard !disposed else { return }
        disposed = true
        theme.dispose()
        events.forEach { $0.dispose() }
        events.removeAll()
        imageControls.forEach { $0.source = nil }
        bitmaps.removeAll()
        markdown?.dispose()
        markdown = nil
        root.contextFlyout = nil
        menu?.items.clear()
        copyItem = nil
        menu = nil
    }

    private var embeds: [EmbedContent] {
        message.embedContents.filter { message.expandEmbedContents || $0.isUploadedImage }
    }

    private func renderMedia() {
        guard !disposed else { return }
        media.children.clear()
        let embeds = embeds
        media.visibility = embeds.isEmpty ? .collapsed : .visible
        let previews = embeds.flatMap(\.imagePreviews)
        let isSensitive = message.nsfw || embeds.contains(where: \.isRestricted)
            || previews.contains(where: \.isRestricted)

        // Do not even create a BitmapImage/URI for gated content before this click.
        if isSensitive && !revealsSensitiveContent && !embeds.isEmpty {
            let reveal = Button()
            reveal.content = "センシティブなメディアを表示"
            reveal.fontSize = 12
            reveal.horizontalAlignment = .left
            events.append(reveal.click.addHandler { [weak self] _, _ in
                guard let self, !self.disposed else { return }
                self.revealsSensitiveContent = true
                self.renderMedia()
                self.onLayoutChange?()
            })
            retainedElements.append(reveal)
            media.children.append(reveal)
            return
        }

        let unavailableImages = embeds.filter(\.hasUnavailableImage)
        if !previews.isEmpty || !unavailableImages.isEmpty {
            let images = StackPanel()
            images.orientation = .horizontal
            images.spacing = 8
            retainedElements.append(images)
            for preview in previews {
                let previewImage = thumbnail(url: preview.thumbnailURL, width: 180, height: 140)
                if preview.isVideo {
                    let video = label("▶", size: 30, themed: false)
                    video.horizontalAlignment = .center
                    video.verticalAlignment = .center
                    video.foreground = SolidColorBrush(.init(a: 255, r: 255, g: 255, b: 255))
                    let background = Border()
                    background.width = 44
                    background.height = 44
                    background.cornerRadius = corners(22)
                    background.background = SolidColorBrush(.init(a: 153, r: 0, g: 0, b: 0))
                    background.horizontalAlignment = .center
                    background.verticalAlignment = .center
                    background.child = video
                    retainedElements.append(background)
                    previewImage.children.append(background)
                }
                images.children.append(link(to: preview.linkURL, content: previewImage))
            }
            for _ in unavailableImages {
                images.children.append(thumbnail(url: nil, width: 180, height: 140))
            }
            let strip = ScrollViewer()
            strip.horizontalScrollBarVisibility = .auto
            strip.horizontalScrollMode = .enabled
            strip.verticalScrollBarVisibility = .disabled
            strip.verticalScrollMode = .disabled
            strip.height = 154
            strip.content = images
            retainedElements.append(strip)
            media.children.append(strip)
        }

        for embed in embeds where !embed.isImageOnly && !embed.isUploadedImage {
            media.children.append(card(embed))
        }

    }

    private func card(_ embed: EmbedContent) -> FrameworkElement {
        let layout = Grid()
        layout.horizontalAlignment = .stretch
        let content = StackPanel()
        content.spacing = 5
        retainedElements += [layout, content]
        let column = ColumnDefinition()
        column.width = .init(value: 1, gridUnitType: .star)
        if let url = Self.safeURL(embed.cardThumbnailURL) {
            let thumbnailColumn = ColumnDefinition()
            thumbnailColumn.width = .init(value: 132, gridUnitType: .pixel)
            layout.columnDefinitions.append(thumbnailColumn)
            let preview = thumbnail(url: url, width: 120, height: 90)
            preview.verticalAlignment = .top
            preview.horizontalAlignment = .left
            layout.children.append(preview)
            try? Grid.setColumn(content, 1)
        }
        layout.columnDefinitions.append(column)
        layout.children.append(content)

        let title = label(embed.cardTitle, size: 13)
        title.fontWeight = .init(weight: 600)
        title.maxLines = 2
        title.textTrimming = .characterEllipsis
        content.children.append(title)
        if let description = embed.cardDescription, !description.isEmpty {
            let summary = label(description, size: 12)
            summary.maxLines = 3
            summary.textTrimming = .characterEllipsis
            summary.opacity = 0.8
            content.children.append(summary)
        }
        if let host = embed.linkURL?.host {
            let source = label(host, size: 10)
            source.maxLines = 1
            source.opacity = 0.65
            content.children.append(source)
        }

        let border = Border()
        border.padding = inset(10)
        border.cornerRadius = corners(8)
        border.borderThickness = inset(1)
        theme.bind(border) { control, value in
            control.borderBrush = WindowsTimelineTheme.primary(value, alpha: 31)
            control.background = WindowsTimelineTheme.primary(value, alpha: 6)
        }
        border.child = layout
        retainedElements.append(border)
        return link(to: embed.linkURL, content: border, stretch: true)
    }

    private func thumbnail(url: URL?, width: Double, height: Double,
                           avatarInitials: String? = nil) -> Grid {
        let frame = Grid()
        frame.width = width
        frame.height = height
        frame.cornerRadius = corners(avatarInitials == nil ? 6 : width * 0.24)
        frame.background = SolidColorBrush(avatarInitials == nil
            ? .init(a: 12, r: 128, g: 128, b: 128)
            : avatarColor(saturation: 0.18, brightness: 0.9))
        if avatarInitials == nil {
            theme.bind(frame) { control, value in
                control.background = WindowsTimelineTheme.primary(value, alpha: 12)
            }
        }
        let validURL = Self.safeURL(url)
        let placeholder = label(avatarInitials ?? "画像を読み込めません", size: avatarInitials == nil ? 10 : 14,
                                themed: avatarInitials == nil)
        placeholder.horizontalAlignment = .center
        placeholder.verticalAlignment = .center
        placeholder.textAlignment = .center
        placeholder.margin = inset(4)
        placeholder.opacity = 0.7
        if avatarInitials != nil {
            placeholder.fontSize = width * 0.35
            placeholder.fontWeight = .init(weight: 600)
            placeholder.opacity = 1
            placeholder.foreground = SolidColorBrush(avatarColor(saturation: 0.48, brightness: 0.43))
        }
        frame.children.append(placeholder)
        retainedElements.append(frame)
        guard let validURL else { return frame }

        let progress: ProgressRing?
        if avatarInitials == nil {
            let spinner = ProgressRing()
            spinner.width = 20
            spinner.height = 20
            spinner.isActive = true
            spinner.horizontalAlignment = .center
            spinner.verticalAlignment = .center
            placeholder.visibility = .collapsed
            frame.children.append(spinner)
            retainedElements.append(spinner)
            progress = spinner
        } else {
            progress = nil
        }

        let image = Image()
        image.width = width
        image.height = height
        image.stretch = avatarInitials == nil ? .uniform : .uniformToFill
        image.opacity = 0
        frame.children.append(image)
        retainedElements.append(image)
        imageControls.append(image)
        let bitmap = BitmapImage()
        // Thumbnails (including offscreen avatars) must not keep decoding GIF
        // frames. The original animation remains available through its link.
        bitmap.autoPlay = false
        // Decode at thumbnail scale and reserve dimensions before loading, keeping scroll position stable.
        bitmap.decodePixelWidth = Int32(width * 2)
        bitmaps.append(bitmap)
        events.append(bitmap.imageOpened.addHandler { [weak image, weak placeholder, weak progress] _, _ in
            image?.opacity = 1
            placeholder?.visibility = .collapsed
            progress?.isActive = false
            progress?.visibility = .collapsed
        })
        events.append(bitmap.imageFailed.addHandler { [weak image, weak placeholder, weak progress] _, _ in
            image?.opacity = 0
            placeholder?.visibility = .visible
            progress?.isActive = false
            progress?.visibility = .collapsed
            if avatarInitials == nil { placeholder?.text = "画像を読み込めません" }
        })
        image.source = bitmap
        // WinUI fetches a public URI directly; Kokoro's authenticated API client/token is never used.
        bitmap.uriSource = Uri(validURL.absoluteString)
        return frame
    }

    private func link(to url: URL?, content: FrameworkElement, stretch: Bool = false) -> FrameworkElement {
        guard let url = Self.safeURL(url) else { return content }
        let control = HyperlinkButton()
        control.navigateUri = Uri(url.absoluteString)
        try? ToolTipService.setToolTip(control, url.absoluteString)
        control.content = content
        control.padding = inset(0)
        control.horizontalAlignment = stretch ? .stretch : .left
        control.horizontalContentAlignment = .stretch
        control.verticalContentAlignment = .stretch
        retainedElements.append(control)
        return control
    }

    private func label(_ value: String, size: Double, themed: Bool = true) -> TextBlock {
        let control = TextBlock()
        control.text = value
        control.fontSize = size
        control.textWrapping = .wrap
        if themed { theme.bindText(control) }
        retainedElements.append(control)
        return control
    }

    private static func safeURL(_ url: URL?) -> URL? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    private func avatarColor(saturation: Double, brightness: Double) -> UWP.Color {
        let degrees = message.profile.screenName.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % 360 }
        let hue = Double(degrees) / 60
        let chroma = brightness * saturation
        let secondary = chroma * (1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1))
        let offset = brightness - chroma
        let rgb: (Double, Double, Double)
        switch Int(hue) {
        case 0: rgb = (chroma, secondary, 0)
        case 1: rgb = (secondary, chroma, 0)
        case 2: rgb = (0, chroma, secondary)
        case 3: rgb = (0, secondary, chroma)
        case 4: rgb = (secondary, 0, chroma)
        default: rgb = (chroma, 0, secondary)
        }
        return .init(a: 255, r: UInt8((rgb.0 + offset) * 255),
                     g: UInt8((rgb.1 + offset) * 255), b: UInt8((rgb.2 + offset) * 255))
    }

    private func inset(_ value: Double) -> Thickness {
        .init(left: value, top: value, right: value, bottom: value)
    }

    private func corners(_ value: Double) -> CornerRadius {
        .init(topLeft: value, topRight: value, bottomRight: value, bottomLeft: value)
    }
}
