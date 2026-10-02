import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct HotwireMessageEmbeds: Equatable, Sendable {
    /// Content-only replacements have no channel identity; callers must correlate them with a known message.
    public let channelID: String?
    public let messageID: Int
    public let cards: [HotwireLinkCard]

    public init(channelID: String?, messageID: Int, cards: [HotwireLinkCard]) {
        self.channelID = channelID
        self.messageID = messageID
        self.cards = cards
    }
}

public struct HotwireLinkCard: Equatable, Sendable {
    public let url: URL
    public let title: String?
    public let description: String?
    public let thumbnailURL: URL?
    public let thumbnailIsAuthor: Bool
    public let isRestricted: Bool

    public init(url: URL, title: String?, description: String?, thumbnailURL: URL?,
                thumbnailIsAuthor: Bool, isRestricted: Bool) {
        self.url = url
        self.title = title
        self.description = description
        self.thumbnailURL = thumbnailURL
        self.thumbnailIsAuthor = thumbnailIsAuthor
        self.isRestricted = isRestricted
    }
}

/// Reads server-generated link metadata without rendering HTML or loading any resources.
public enum HotwireEmbedParser {
    private static let maximumBytes = 4 * 1_024 * 1_024
    private static let maximumStreams = 256
    private static let maximumCards = 100

    public static func parse(_ html: String, baseURL: URL) -> [HotwireMessageEmbeds] {
        guard !html.isEmpty, html.utf8.count <= maximumBytes,
              html.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              html.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { return [] }

        var remaining = html[...]
        var records: [HotwireMessageEmbeds] = []
        var streamCount = 0
        while !remaining.isEmpty {
            remaining = remaining.drop(while: { $0.isWhitespace })
            if remaining.isEmpty { break }
            // Tidy removes the custom stream/template elements, so validate that envelope first.
            guard streamCount < maximumStreams,
                  remaining.hasPrefix("<turbo-stream"),
                  let headerEnd = remaining.firstIndex(of: ">"),
                  let streamEnd = remaining.range(of: "</turbo-stream>", range: remaining.index(after: headerEnd)..<remaining.endIndex),
                  let header = try? XMLDocument(xmlString: String(remaining[..<headerEnd]) + "/>",
                                                options: [.nodeLoadExternalEntitiesNever]),
                  let stream = header.rootElement(), stream.name == "turbo-stream" else { return [] }
            streamCount += 1
            let inner = remaining[remaining.index(after: headerEnd)..<streamEnd.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            remaining = remaining[streamEnd.upperBound...]
            guard let action = stream.attribute(forName: "action")?.stringValue,
                  ["append", "replace", "update"].contains(action),
                  let target = stream.attribute(forName: "target")?.stringValue,
                  inner.hasPrefix("<template>"), inner.hasSuffix("</template>") else { continue }
            let content = String(inner.dropFirst("<template>".count).dropLast("</template>".count))
            guard let fragment = prepare(content),
                  let body = HotwireHTMLParser.body(fragment.html) else { continue }

            if ["replace", "update"].contains(action),
               let messageID = messageID(from: target, suffix: "_content") {
                // A content replacement lacks channel metadata. Require exactly its advertised root.
                guard fragment.rootCount == 1, !fragment.hasRootText,
                      body.embedElementChildren.count == 1, let root = body.embedElementChildren.first,
                      root.name == "div", root.attribute(forName: "id")?.stringValue == target,
                      !root.embedHasClass("talk") else { continue }
                guard records.count < maximumStreams else { return [] }
                records.append(HotwireMessageEmbeds(channelID: nil, messageID: messageID,
                                                    cards: cards(in: root, sourceTexts: fragment.sourceTexts, baseURL: baseURL)))
                continue
            }

            for root in body.embedElementChildren where root.name == "div" && root.embedHasClass("talk") {
                guard let identifier = root.attribute(forName: "id")?.stringValue,
                      let messageID = messageID(from: identifier),
                      let channelID = root.attribute(forName: "data-channel-hashid")?.stringValue,
                      !channelID.isEmpty, channelID.utf8.count <= 256,
                      channelID.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }),
                      (action == "append" && target == "messages") ||
                        (["replace", "update"].contains(action) && (target == identifier || target == "messages")) else { continue }
                let contents = root.embedElementChildren.filter { $0.name == "div" && $0.embedHasClass("message") }
                    .flatMap(\.embedElementChildren).filter { $0.name == "div" }
                    .flatMap(\.embedElementChildren).filter { $0.name == "div" && $0.attribute(forName: "id")?.stringValue == "\(identifier)_content" }
                let previews = !root.embedHasClass("message--deleted") && contents.count == 1
                    ? cards(in: contents[0], sourceTexts: fragment.sourceTexts, baseURL: baseURL) : []
                guard records.count < maximumStreams else { return [] }
                // Even an image-only or unexpanded message counts toward a resume page.
                records.append(HotwireMessageEmbeds(channelID: channelID, messageID: messageID, cards: previews))
            }
        }
        return records
    }

    private static func messageID(from identifier: String, suffix: String = "") -> Int? {
        guard identifier.hasPrefix("message_"), identifier.hasSuffix(suffix) else { return nil }
        let digits = identifier.dropFirst("message_".count).dropLast(suffix.count)
        guard let id = Int(digits), id > 0, identifier == "message_\(id)\(suffix)" else { return nil }
        return id
    }

    private static func cards(in content: XMLElement, sourceTexts: [String: String], baseURL: URL) -> [HotwireLinkCard] {
        guard !content.embedElementChildren.contains(where: { $0.embedHasClass("deleted-text") }) else { return [] }
        // Only the server's direct metadata partial belongs to this message, never quoted previews.
        let mixedContents = content.embedElementChildren.filter { $0.name == "div" && $0.embedHasClass("embed-contents") }
            .flatMap(\.embedElementChildren).filter { $0.name == "div" && $0.embedHasClass("embed-mixedcontent") }
        guard mixedContents.count <= maximumCards else { return [] }
        return mixedContents.compactMap { mixed in
            let metadata = mixed.embedElementChildren.filter { $0.name == "div" && $0.embedHasClass("embed-mixed-meta") }
            guard metadata.count == 1, let meta = metadata.first else { return nil }
            let information = meta.embedElementChildren.filter { $0.name == "div" && $0.embedHasClass("embed-mixed-info") }
            guard information.count == 1, let info = information.first else { return nil }
            let titles = info.embedElementChildren.filter { $0.name == "div" && $0.embedHasClass("embed-mixed-title") }
                .flatMap(\.embedElementChildren).filter { $0.name == "a" }
            let thumbnails = meta.embedElementChildren.filter { $0.name == "div" && $0.embedHasClass("embed-mixed-thumb") }
                .flatMap(\.embedElementChildren).filter { $0.name == "div" && $0.embedHasClass("embed-thumbnail") }
                .flatMap(\.embedElementChildren).filter { $0.name == "a" }
            guard titles.count <= 1, thumbnails.count <= 1 else { return nil }
            let titleLink = titles.first
            let thumbnailLink = thumbnails.first
            let linkValue = (titleLink ?? thumbnailLink)?.attribute(forName: "href")?.stringValue
            guard let url = safeURL(linkValue, baseURL: baseURL) else { return nil }
            let title = titleLink?.embedElementChildren.first(where: { $0.name == "strong" })
                .flatMap { decodedText(in: $0, sourceTexts: sourceTexts) }
            let descriptions = info.embedElementChildren.filter { $0.name == "div" && $0.embedHasClass("embed-mixed-desc") }
                .flatMap(\.embedElementChildren).filter { $0.name == "p" }
            let decodedDescriptions = descriptions.compactMap { decodedText(in: $0, sourceTexts: sourceTexts) }
            let description = !descriptions.isEmpty && decodedDescriptions.count == descriptions.count
                ? decodedDescriptions.joined(separator: "\n\n") : nil
            let images = thumbnailLink?.embedElementChildren.filter { $0.name == "img" } ?? []
            let image = images.count == 1 ? images.first : nil
            return HotwireLinkCard(url: url, title: nonempty(title), description: nonempty(description),
                                   thumbnailURL: safeURL(image?.attribute(forName: "src")?.stringValue, baseURL: baseURL),
                                   thumbnailIsAuthor: image?.embedHasClass("meta-thumb-author") == true,
                                   isRestricted: mixed.embedContainsClass("nsfw-media"))
        }
    }

    private struct PreparedFragment {
        let html: String
        let sourceTexts: [String: String]
        let rootCount: Int
        let hasRootText: Bool
    }

    private struct HTMLTag {
        let name: String
        let nameEnd: String.Index
        let end: String.Index
        let closing: Bool
        let selfClosing: Bool
    }

    /// macOS HTML Tidy normalizes paragraph whitespace and removes empty siblings. Keep
    /// the original escaped Rails text, and validate the original roots before that repair.
    private static func prepare(_ html: String) -> PreparedFragment? {
        let voidTags: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]
        let rawTextTags: Set<String> = ["script", "style", "textarea", "title"]
        let nonce = UUID().uuidString
        var cursor = html.startIndex
        var stack: [String] = []
        var result = ""
        var texts: [String: String] = [:]
        var roots = 0
        var rootText = false
        while cursor < html.endIndex {
            guard html[cursor] == "<" else {
                let end = html[cursor...].firstIndex(of: "<") ?? html.endIndex
                let text = html[cursor..<end]
                if stack.isEmpty && !text.allSatisfy(\.isWhitespace) { rootText = true }
                result += text
                cursor = end
                continue
            }
            if html[cursor...].hasPrefix("<!--") {
                guard let end = html.range(of: "-->", range: cursor..<html.endIndex)?.upperBound else { return nil }
                result += html[cursor..<end]
                cursor = end
                continue
            }
            guard let tag = scanTag(in: html, at: cursor) else { return nil }
            if tag.closing {
                guard stack.last == tag.name else { return nil }
                stack.removeLast()
                result += html[cursor..<tag.end]
                cursor = tag.end
                continue
            }
            if stack.isEmpty { roots += 1 }
            if ["p", "strong"].contains(tag.name), !tag.selfClosing,
               let next = html[tag.end...].firstIndex(of: "<"),
               let close = scanTag(in: html, at: next), close.closing, close.name == tag.name {
                let key = "\(nonce)-\(texts.count)"
                texts[key] = String(html[tag.end..<next])
                result += html[cursor..<tag.nameEnd]
                result += " data-hotwire-text=\"\(key)\""
                result += html[tag.nameEnd..<tag.end]
                result += "<span>\(key)</span>"
                result += html[next..<close.end]
                cursor = close.end
                continue
            }
            if rawTextTags.contains(tag.name), !tag.selfClosing {
                guard let closeStart = html.range(of: "</\(tag.name)", options: .caseInsensitive,
                                                 range: tag.end..<html.endIndex)?.lowerBound,
                      let close = scanTag(in: html, at: closeStart), close.closing, close.name == tag.name else { return nil }
                result += html[cursor..<close.end]
                cursor = close.end
                continue
            }
            result += html[cursor..<tag.end]
            if !tag.selfClosing && !voidTags.contains(tag.name) {
                guard stack.count < 256 else { return nil }
                stack.append(tag.name)
            }
            cursor = tag.end
        }
        guard stack.isEmpty else { return nil }
        return PreparedFragment(html: result, sourceTexts: texts, rootCount: roots, hasRootText: rootText)
    }

    private static func scanTag(in html: String, at start: String.Index) -> HTMLTag? {
        var cursor = html.index(after: start)
        guard cursor < html.endIndex else { return nil }
        let closing = html[cursor] == "/"
        if closing { cursor = html.index(after: cursor) }
        let nameStart = cursor
        while cursor < html.endIndex, html[cursor].unicodeScalars.allSatisfy({
            (65...90).contains($0.value) || (97...122).contains($0.value) ||
                (48...57).contains($0.value) || [45, 58, 95].contains($0.value)
        }) { cursor = html.index(after: cursor) }
        guard cursor > nameStart else { return nil }
        let nameEnd = cursor
        let name = html[nameStart..<nameEnd].lowercased()
        var quote: Character?
        while cursor < html.endIndex {
            let character = html[cursor]
            if let active = quote {
                if character == active { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                let headerTail = html[nameEnd..<cursor].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !closing || headerTail.isEmpty else { return nil }
                return HTMLTag(name: name, nameEnd: nameEnd, end: html.index(after: cursor),
                               closing: closing, selfClosing: headerTail.hasSuffix("/"))
            }
            cursor = html.index(after: cursor)
        }
        return nil
    }

    private static func decodedText(in element: XMLElement, sourceTexts: [String: String]) -> String? {
        guard let key = element.attribute(forName: "data-hotwire-text")?.stringValue,
              let escaped = sourceTexts[key],
              let document = try? XMLDocument(xmlString: "<text>\(escaped.replacingOccurrences(of: "\r", with: "&#13;"))</text>",
                                             options: [.nodePreserveWhitespace, .nodeLoadExternalEntitiesNever]) else { return nil }
        return document.rootElement()?.stringValue
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private static func safeURL(_ value: String?, baseURL: URL) -> URL? {
        guard let value, !value.isEmpty, value.utf8.count <= 16_384,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.rangeOfCharacter(from: .controlCharacters.union(.whitespacesAndNewlines)) == nil,
              let url = URL(string: value, relativeTo: baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }
}

private extension XMLElement {
    var embedElementChildren: [XMLElement] { (children ?? []).compactMap { $0 as? XMLElement } }

    func embedHasClass(_ value: String) -> Bool {
        attribute(forName: "class")?.stringValue?.split(whereSeparator: \.isWhitespace).contains(Substring(value)) == true
    }

    func embedContainsClass(_ value: String) -> Bool {
        var pending = [self]
        while let element = pending.popLast() {
            if element.embedHasClass(value) { return true }
            pending.append(contentsOf: element.embedElementChildren)
        }
        return false
    }
}
