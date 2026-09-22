import AppKit
import KokoroCore
import SwiftUI
import Textual

struct MessageRow: View {
    let message: Message
    var isGrouped = false

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if isGrouped {
                Text(message.publishedAt, format: .dateTime.hour().minute())
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 38, alignment: .trailing)
                    .opacity(isHovered ? 1 : 0)
                    .padding(.top, 3)
                    .accessibilityHidden(true)
            } else {
                ChatAvatar(profile: message.profile, size: 38, avatarURL: message.avatar)
            }

            VStack(alignment: .leading, spacing: 4) {
                if !isGrouped {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(message.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(message.publishedAt, format: .dateTime.hour().minute())
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                if message.isDeleted {
                    Text("このメッセージは削除されました")
                        .font(.system(size: 13))
                        .italic()
                        .foregroundStyle(.secondary)
                } else {
                    StructuredText(markdownSource, parser: ChatMarkdownParser())
                        .font(.system(size: 13))
                        .lineSpacing(4)
                        .textual.textSelection(.enabled)
                        .textual.inlineStyle(InlineStyle.default.link(.foregroundColor(KChatPalette.accent)))
                        .textual.tableStyle(.overflow)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    MessageEmbedsView(message: message)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, isGrouped ? 3 : 9)
        .background(isHovered ? Color.primary.opacity(0.025) : .clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("メッセージをコピー", systemImage: "doc.on.doc") {
                guard !message.isDeleted else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
            }
            .disabled(message.isDeleted)
        }
        .accessibilityElement(children: .contain)
    }

    private var markdownSource: String {
        message.rawContent.isEmpty ? message.text : message.rawContent
    }
}

private struct ChatMarkdownParser: MarkupParser {
    func attributedString(for input: String) throws -> AttributedString {
        MessageMarkdown.attributedString(for: input)
    }
}

struct ChatAvatar: View {
    let profile: Profile
    var size: CGFloat = 36
    var avatarURL: URL?

    private var hue: Double {
        let value = profile.screenName.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % 360 }
        return Double(value) / 360
    }

    var body: some View {
        AsyncImage(url: avatarURL ?? profile.avatar) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Color(hue: hue, saturation: 0.18, brightness: 0.9)
                    Text(profile.initials)
                        .font(.system(size: size * 0.35, weight: .semibold))
                        .foregroundStyle(Color(hue: hue, saturation: 0.48, brightness: 0.43))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("Markdown message", traits: .fixedLayout(width: 640, height: 760)) {
    ScrollView {
        MessageRow(message: Message(
            id: 1,
            rawContent: """
            # Markdown の表示

            **太字**、*斜体*、~~取り消し線~~、[kokoro.io](https://kokoro.io)
            この行は単一改行で表示します。
            <#CHANNEL|開発 *チャンネル*> と <@USER|山田さん> への参照です。

            - 最初の項目
            - 二番目の項目
              - 入れ子の項目

            > 引用文です。
            > 複数行の引用も表示します。

            ```swift
            let message = "こんにちは、Markdown!"
            print(message)
            ```

            | 機能 | 状態 |
            | --- | --- |
            | 見出し・リスト | 表示できます |
            | コード・表 | 表示できます |
            """,
            channel: Channel(id: "CHANNEL", channelName: "開発"),
            profile: Profile(id: "USER", screenName: "yamada", displayName: "山田 太郎")
        ))
        .padding(.vertical, 12)
    }
    .background(Color(nsColor: .textBackgroundColor))
}
#endif
