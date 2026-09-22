import AppKit
import KokoroCore
import SwiftUI

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
                    Text(markdownBody)
                        .font(.system(size: 13))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .tint(KChatPalette.accent)
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

    private var markdownBody: AttributedString {
        let displayText = displayMarkdown
        return (try? AttributedString(
            markdown: displayText,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(displayText)
    }

    private var displayMarkdown: String {
        let source = message.rawContent.isEmpty ? message.text : message.rawContent
        guard let expression = try? NSRegularExpression(pattern: "<([@#])[A-Za-z0-9_-]+\\|([^<>\\r\\n]+)>") else {
            return source
        }
        let result = NSMutableString(string: source)
        let matches = expression.matches(in: source, range: NSRange(source.startIndex..., in: source))
        for match in matches.reversed() {
            let prefix = (source as NSString).substring(with: match.range(at: 1))
            let label = (source as NSString).substring(with: match.range(at: 2))
            // Reference names are literal text, even when they contain Markdown punctuation.
            let escapedLabel = label.reduce(into: "") { output, character in
                if "\\`*_[]<>".contains(character) { output.append("\\") }
                output.append(character)
            }
            result.replaceCharacters(in: match.range, with: prefix + escapedLabel)
        }
        return result as String
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
