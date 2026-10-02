import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if os(Windows)
import SwiftSoup
#endif

/// Parses inert HTML into the element/attribute tree used by Hotwire metadata readers.
enum HotwireHTMLParser {
    static func body(_ content: String) -> XMLElement? {
        #if os(Windows)
        // corelibs FoundationXML ignores documentTidyHTML. Parse without loading any
        // resources, then copy just the element/attribute data used by the rules below.
        guard let body = try? SwiftSoup.parseBodyFragment(content).body() else { return nil }
        func convert(_ element: SwiftSoup.Element, depth: Int) -> XMLElement? {
            guard depth < 256 else { return nil }
            let node = XMLElement(name: element.tagName())
            for name in ["id", "class", "data-channel-hashid", "data-hotwire-text", "href", "src"] {
                guard element.hasAttr(name), var value = try? element.attr(name) else { continue }
                if name == "href" || name == "src" {
                    // Match HTML tidy's URI attribute whitespace normalization.
                    value = value.replacingOccurrences(of: "\r\n", with: " ")
                        .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
                        .replacingOccurrences(of: "\t", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "%20")
                }
                if let attribute = XMLNode.attribute(withName: name, stringValue: value) as? XMLNode {
                    node.addAttribute(attribute)
                }
            }
            for child in element.children().array() {
                guard let converted = convert(child, depth: depth + 1) else { return nil }
                node.addChild(converted)
            }
            return node
        }
        return convert(body, depth: 0)
        #else
        guard let document = try? XMLDocument(xmlString: content,
                                              options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]) else { return nil }
        return document.rootElement()?.children?.compactMap { $0 as? XMLElement }.first(where: { $0.name == "body" })
        #endif
    }
}
