import Foundation

public struct HotwireMessageImages: Equatable, Sendable {
    public let channelID: String
    public let messageID: Int
    public let images: [EmbedImagePreview]

    public init(channelID: String, messageID: Int, images: [EmbedImagePreview]) {
        self.channelID = channelID
        self.messageID = messageID
        self.images = images
    }
}

/// Reads only the server's uploaded-image markup; it never renders HTML or loads its resources.
public enum HotwireImageParser {
    private static let maximumBytes = 4 * 1_024 * 1_024
    private static let maximumStreams = 256
    private static let maximumImages = 100

    public static func parse(_ html: String, baseURL: URL) -> [HotwireMessageImages] {
        guard !html.isEmpty, html.utf8.count <= maximumBytes,
              html.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              html.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { return [] }

        var remaining = html[...]
        var records: [HotwireMessageImages] = []
        var streamCount = 0
        while !remaining.isEmpty {
            remaining = remaining.drop(while: { $0.isWhitespace })
            if remaining.isEmpty { break }
            // HTML tidy removes unknown turbo-stream/template tags. Validate their small XML
            // envelope separately, then give only the template's HTML to the HTML parser.
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
            guard let document = try? XMLDocument(xmlString: content,
                                                  options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]),
                  let body = document.rootElement()?.elementChildren.first(where: { $0.name == "body" }) else { continue }
            for root in body.elementChildren where root.name == "div" && root.hasClass("talk") {
                guard let identifier = root.attribute(forName: "id")?.stringValue,
                      identifier.hasPrefix("message_"),
                      let messageID = Int(identifier.dropFirst("message_".count)), messageID > 0,
                      identifier == "message_\(messageID)",
                      let channelID = root.attribute(forName: "data-channel-hashid")?.stringValue,
                      !channelID.isEmpty, channelID.utf8.count <= 256,
                      channelID.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }),
                      (action == "append" && target == "messages") ||
                        (["replace", "update"].contains(action) && (target == identifier || target == "messages")) else { continue }
                let images = root.hasClass("message--deleted") ? [] : images(in: root, identifier: identifier, baseURL: baseURL)
                guard records.count < maximumStreams else { return [] }
                records.append(HotwireMessageImages(channelID: channelID, messageID: messageID, images: images))
            }
        }
        return records
    }

    private static func images(in root: XMLElement, identifier: String, baseURL: URL) -> [EmbedImagePreview] {
        // Match the actual message partial's path, not nested internal previews or filtered text.
        let contents = root.elementChildren.filter { $0.name == "div" && $0.hasClass("message") }
            .flatMap(\.elementChildren).filter { $0.name == "div" }
            .flatMap(\.elementChildren).filter { $0.name == "div" && $0.attribute(forName: "id")?.stringValue == "\(identifier)_content" }
        guard contents.count == 1, let content = contents.first,
              !content.elementChildren.contains(where: { $0.hasClass("deleted-text") }) else { return [] }
        let groups = content.elementChildren.filter { $0.name == "div" && $0.hasClass("embed-contents") }
            .flatMap(\.elementChildren).filter { $0.name == "div" && $0.hasClass("embed-uploaded-images") }
        guard groups.count == 1, let group = groups.first,
              group.elementChildren.count <= maximumImages else { return [] }
        var result: [EmbedImagePreview] = []
        for item in group.elementChildren {
            let restricted = item.name == "div" && item.hasClass("nsfw-media")
            let links = restricted ? item.elementChildren.filter { $0.name == "a" } : [item]
            guard !restricted || item.elementChildren.allSatisfy({
                $0.name == "a" || ($0.name == "svg" && $0.hasClass("nsfw-mark"))
            }) else { return [] }
            // A DOM item missing a usable image/URL pair invalidates the whole list. Compacting
            // it would map subsequent URLs to the wrong uploaded-image positions in JSON.
            guard links.count == 1, let link = links.first,
                  link.name == "a", link.hasClass("embed-uploaded-image-link"),
                  link.elementChildren.count == 1, let image = link.elementChildren.first,
                  image.name == "img", image.hasClass("embed-uploaded-image"),
                  let fullURL = safeURL(link.attribute(forName: "href")?.stringValue, baseURL: baseURL),
                  let thumbnailURL = safeURL(image.attribute(forName: "src")?.stringValue, baseURL: baseURL) else { return [] }
            result.append(EmbedImagePreview(id: "hotwire-\(result.count)", thumbnailURL: thumbnailURL,
                                           linkURL: fullURL, isRestricted: restricted))
        }
        return result
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
    var elementChildren: [XMLElement] { (children ?? []).compactMap { $0 as? XMLElement } }

    func hasClass(_ value: String) -> Bool {
        attribute(forName: "class")?.stringValue?.split(whereSeparator: \.isWhitespace).contains(Substring(value)) == true
    }
}
