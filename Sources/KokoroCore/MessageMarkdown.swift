import EmojiData
import Foundation

/// Markdown adapted to chat: preserve line breaks and leave media previews to the embed view.
public enum MessageMarkdown {
    public static func attributedString(for source: String) -> AttributedString {
        let protected = protectReferences(in: source)
        let parsed = (try? AttributedString(
            markdown: protected.source,
            options: .init(interpretedSyntax: .full)
        )) ?? AttributedString(protected.source)

        var result = AttributedString()
        for run in parsed.runs {
            var text = String(parsed[run.range].characters)
            var attributes = run.attributes
            if var intent = attributes.inlinePresentationIntent, intent.contains(.softBreak) {
                // Foundation represents a soft break as a space, so change both its text and intent.
                text = "\n"
                intent.remove(.softBreak)
                intent.insert(.lineBreak)
                attributes.inlinePresentationIntent = intent
            }

            if let imageURL = attributes.imageURL {
                // Textual loads imageURL attributes automatically. Keep a link here so that the
                // existing embed view remains responsible for expansion and sensitive-media gates.
                attributes.imageURL = nil
                if attributes.link == nil { attributes.link = imageURL }
                if text == "\u{FFFC}" || text.isEmpty { text = imageURL.absoluteString }
            }

            let isCode = attributes.inlinePresentationIntent?.contains(.code) == true
                || attributes.presentationIntent?.components.contains(where: {
                    if case .codeBlock = $0.kind { return true }
                    return false
                }) == true
            for reference in protected.references {
                text = text.replacingOccurrences(
                    of: reference.token,
                    with: isCode ? reference.original : reference.label
                )
            }
            if !isCode {
                text = replaceEmojiShortcodes(in: text)
            }
            result.append(AttributedString(text, attributes: attributes))
        }
        return result
    }

    private static let emojiShortcode = try! NSRegularExpression(
        pattern: ":[A-Za-z0-9_+\\-]+:(?::skin-tone-[1-6]:)?"
    )

    private static func replaceEmojiShortcodes(in text: String) -> String {
        // EmojiData's bulk replacement measures NSRange with Character count. Use UTF-16 ranges
        // so a shortcode still matches after existing emoji or other multi-unit characters.
        let matches = emojiShortcode.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }

        let result = NSMutableString(string: text)
        for match in matches.reversed() {
            let shortcode = (text as NSString).substring(with: match.range)
            if let emoji = EmojiData.character(fromShortCode: shortcode) {
                result.replaceCharacters(in: match.range, with: emoji)
            }
        }
        return result as String
    }

    private struct Reference {
        let token: String
        let original: String
        let label: String
    }

    private static func protectReferences(in source: String) -> (source: String, references: [Reference]) {
        guard let expression = try? NSRegularExpression(pattern: "<([@#])[A-Za-z0-9_-]+\\|([^<>\\r\\n]+)>") else {
            return (source, [])
        }
        let matches = expression.matches(in: source, range: NSRange(source.startIndex..., in: source))
        guard !matches.isEmpty else { return (source, []) }

        // Parse placeholders rather than reference names: Markdown punctuation in a name is
        // always literal, including a pipe inside a table cell or a leading heading marker.
        var tokenPrefix = "KOKOROREFERENCE"
        while source.contains(tokenPrefix) { tokenPrefix += "X" }
        let input = source as NSString
        let output = NSMutableString(string: source)
        var references: [Reference] = []
        for (index, match) in matches.enumerated().reversed() {
            let token = "\(tokenPrefix)\(index)END"
            references.append(Reference(
                token: token,
                original: input.substring(with: match.range),
                label: input.substring(with: match.range(at: 1)) + input.substring(with: match.range(at: 2))
            ))
            output.replaceCharacters(in: match.range, with: token)
        }
        return (output as String, references)
    }
}
