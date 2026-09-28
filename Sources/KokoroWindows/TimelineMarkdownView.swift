import Foundation
import Markdown
import UWP
import WinUI
import WindowsFoundation

/// Native text layout for the same chat Markdown used by MessageRow on macOS.
/// Inline image syntax becomes a link; only TimelineMessageView fetches media,
/// after applying the message's sensitive-content gate.
@MainActor
final class TimelineMarkdownView {
    private let root = StackPanel()
    private let theme = WindowsTimelineTheme()
    private var controls: [FrameworkElement] = []
    private var inlines: [WinUI.Inline] = []
    private var references: [(token: String, original: String, label: String)] = []
    private(set) var renderedText = ""
    private(set) var hasRichText = false
    private(set) var linkDestinations: [String] = []

    var element: FrameworkElement { root }

    func applyTheme(_ value: ElementTheme) { theme.apply(value) }

    init(source: String) {
        root.spacing = 8
        root.horizontalAlignment = .stretch
        let protected = protectReferences(source)
        let document = Document(parsing: protected, options: [.disableSmartOpts])
        for child in document.children { root.children.append(block(child)) }
    }

    func dispose() {
        theme.dispose()
        root.children.clear()
        for control in controls {
            (control as? Panel)?.children.clear()
            (control as? Border)?.child = nil
            (control as? ScrollViewer)?.content = nil
            (control as? TextBlock)?.inlines.clear()
        }
        for inline in inlines { (inline as? Span)?.inlines.clear() }
        inlines.removeAll()
        controls.removeAll()
    }

    private func block(_ node: any Markup) -> FrameworkElement {
        if let code = node as? CodeBlock {
            hasRichText = true
            let text = textBlock()
            text.fontFamily = FontFamily("Consolas")
            text.textWrapping = .noWrap
            var codeText = restoreReferences(code.code, isCode: true)
            if codeText.hasSuffix("\n") { codeText.removeLast() }
            text.text = codeText
            renderedText += text.text + "\n"
            let scroll = ScrollViewer()
            scroll.horizontalScrollBarVisibility = .auto
            scroll.horizontalScrollMode = .enabled
            scroll.verticalScrollBarVisibility = .disabled
            scroll.verticalScrollMode = .disabled
            scroll.content = text
            controls.append(scroll)
            let border = Border()
            border.padding = inset(10)
            border.cornerRadius = .init(topLeft: 5, topRight: 5, bottomRight: 5, bottomLeft: 5)
            theme.bind(border) { control, value in
                control.background = WindowsTimelineTheme.primary(value, alpha: 14)
            }
            border.child = scroll
            controls.append(border)
            return border
        }
        if node is Markdown.BlockQuote {
            hasRichText = true
            let body = StackPanel()
            body.spacing = 8
            for child in node.children { body.children.append(block(child)) }
            controls.append(body)
            let border = Border()
            border.borderThickness = .init(left: 3, top: 0, right: 0, bottom: 0)
            theme.bind(border) { control, value in
                control.borderBrush = WindowsTimelineTheme.primary(value, alpha: 70)
            }
            border.padding = .init(left: 12, top: 2, right: 0, bottom: 2)
            border.child = body
            controls.append(border)
            return border
        }
        if node is UnorderedList || node is OrderedList {
            hasRichText = true
            let list = StackPanel()
            list.spacing = 4
            for (index, child) in node.children.enumerated() {
                let row = Grid()
                let markerColumn = ColumnDefinition()
                markerColumn.width = .init(value: 28, gridUnitType: .auto)
                let contentColumn = ColumnDefinition()
                contentColumn.width = .init(value: 1, gridUnitType: .star)
                row.columnDefinitions.append(markerColumn)
                row.columnDefinitions.append(contentColumn)
                let marker = textBlock()
                marker.minWidth = 22
                marker.margin = .init(left: 0, top: 0, right: 6, bottom: 0)
                if let item = child as? ListItem, let checkbox = item.checkbox {
                    marker.text = checkbox == .checked ? "☑" : "☐"
                } else if let ordered = node as? OrderedList {
                    marker.text = "\(Int(ordered.startIndex) + index)."
                } else {
                    marker.text = "•"
                }
                renderedText += marker.text + " "
                row.children.append(marker)
                let item = StackPanel()
                item.spacing = 4
                for body in child.children { item.children.append(block(body)) }
                try? Grid.setColumn(item, 1)
                row.children.append(item)
                controls += [row, item]
                list.children.append(row)
            }
            controls.append(list)
            return list
        }
        if let table = node as? Markdown.Table { return tableBlock(table) }
        if node is ThematicBreak {
            hasRichText = true
            let rule = Border()
            rule.height = 1
            theme.bind(rule) { control, value in
                control.background = WindowsTimelineTheme.primary(value, alpha: 40)
            }
            rule.margin = .init(left: 0, top: 5, right: 0, bottom: 5)
            controls.append(rule)
            return rule
        }
        let text = textBlock()
        if let heading = node as? Heading {
            hasRichText = true
            text.fontSize = [26.0, 22, 18, 16, 14, 13][max(0, min(heading.level - 1, 5))]
            text.fontWeight = .init(weight: 600)
        }
        if let html = node as? HTMLBlock {
            // Foundation's Markdown renderer treats unsupported HTML as text. Never execute it.
            appendText(html.rawHTML, to: text.inlines, style: .init())
        } else {
            for child in node.children { append(child, to: text.inlines, style: .init()) }
        }
        renderedText += "\n"
        return text
    }

    private func tableBlock(_ table: Markdown.Table) -> FrameworkElement {
        hasRichText = true
        let grid = Grid()
        // Table.Head directly contains cells; Table.Body contains rows.
        let rows: [(any Markup, Bool)] = [(table.head, true)] + table.body.children.map { ($0, false) }
        let columns = rows.map { $0.0.childCount }.max() ?? 0
        for _ in 0..<columns {
            let column = ColumnDefinition()
            column.width = .init(value: 1, gridUnitType: .auto)
            grid.columnDefinitions.append(column)
        }
        for (index, row) in rows.enumerated() {
            let definition = RowDefinition()
            definition.height = .init(value: 1, gridUnitType: .auto)
            grid.rowDefinitions.append(definition)
            for (column, cell) in row.0.children.enumerated() {
                let text = textBlock()
                text.textWrapping = .noWrap
                if column < table.columnAlignments.count {
                    switch table.columnAlignments[column] {
                    case .center: text.textAlignment = .center
                    case .right: text.textAlignment = .right
                    default: break
                    }
                }
                if row.1 { text.fontWeight = .init(weight: 600) }
                for child in cell.children { append(child, to: text.inlines, style: .init()) }
                renderedText += column == columns - 1 ? "\n" : " | "
                let border = Border()
                border.padding = .init(left: 10, top: 6, right: 10, bottom: 6)
                border.borderThickness = inset(0.5)
                let isHeader = row.1
                theme.bind(border) { control, value in
                    control.borderBrush = WindowsTimelineTheme.primary(value, alpha: 45)
                    if isHeader { control.background = WindowsTimelineTheme.primary(value, alpha: 10) }
                }
                border.child = text
                try? Grid.setRow(border, Int32(index))
                try? Grid.setColumn(border, Int32(column))
                grid.children.append(border)
                controls.append(border)
            }
        }
        let scroll = ScrollViewer()
        scroll.horizontalScrollBarVisibility = .auto
        scroll.horizontalScrollMode = .enabled
        scroll.verticalScrollBarVisibility = .disabled
        scroll.verticalScrollMode = .disabled
        scroll.content = grid
        controls += [grid, scroll]
        return scroll
    }

    private struct Style {
        var bold = false
        var italic = false
        var strike = false
        var code = false
        var insideLink = false
    }

    private func append(_ node: any Markup, to collection: InlineCollection, style: Style) {
        if let text = node as? Markdown.Text {
            appendLinkedText(text.string, to: collection, style: style)
            return
        }
        if node is SoftBreak || node is Markdown.LineBreak {
            appendText("\n", to: collection, style: style)
            return
        }
        if let code = node as? InlineCode {
            var updated = style
            updated.code = true
            hasRichText = true
            appendText(code.code, to: collection, style: updated)
            return
        }
        if let html = node as? InlineHTML {
            appendText(html.rawHTML, to: collection, style: style)
            return
        }
        let destination = (node as? Markdown.Link)?.destination ?? (node as? Markdown.Image)?.source
        // A linked image keeps the outer link's destination and never creates
        // nested native Hyperlinks (which XAML does not permit).
        if style.insideLink, let destination {
            for child in node.children { append(child, to: collection, style: style) }
            if node.childCount == 0 { appendText(destination, to: collection, style: style) }
            return
        }
        if let destination, let url = URL(string: destination),
           ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? ""),
           url.user == nil, url.password == nil {
            hasRichText = true
            let link = Hyperlink()
            link.navigateUri = Uri(url.absoluteString)
            linkDestinations.append(url.absoluteString)
            link.foreground = WindowsTimelineTheme.accent(theme.current)
            inlines.append(link)
            var linked = style
            linked.insideLink = true
            for child in node.children { append(child, to: link.inlines, style: linked) }
            if node.childCount == 0 { appendText(destination, to: link.inlines, style: linked) }
            collection.append(link)
            return
        }
        var updated = style
        if destination != nil { updated.insideLink = true }
        if node is Strong { updated.bold = true; hasRichText = true }
        if node is Emphasis { updated.italic = true; hasRichText = true }
        if node is Strikethrough { updated.strike = true; hasRichText = true }
        for child in node.children { append(child, to: collection, style: updated) }
    }

    private static let plainURL = try! NSRegularExpression(
        pattern: #"\bhttps?://[^\s<>"'「」『』（）【】、。！？]+"#,
        options: [.caseInsensitive]
    )

    private func appendLinkedText(_ value: String, to collection: InlineCollection, style: Style) {
        guard !style.code, !style.insideLink else {
            appendText(value, to: collection, style: style)
            return
        }
        // Detect URLs before restoring reference labels so names remain literal text.
        let input = value as NSString
        var offset = 0
        for match in Self.plainURL.matches(in: value, range: NSRange(location: 0, length: input.length)) {
            var destination = input.substring(with: match.range)
            // Sentence punctuation is not part of a pasted URL. Keep balanced brackets
            // in paths, such as Wikipedia's /wiki/Swift_(programming_language).
            while let last = destination.last {
                if ".,;:!?".contains(last) {
                    destination.removeLast()
                } else if let opening = [")": "(", "]": "[", "}": "{"][String(last)],
                          destination.filter({ String($0) == String(last) }).count
                            > destination.filter({ String($0) == opening }).count {
                    destination.removeLast()
                } else { break }
            }
            guard let url = URL(string: destination), let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil else { continue }
            if match.range.location > offset {
                appendText(input.substring(with: NSRange(location: offset, length: match.range.location - offset)),
                           to: collection, style: style)
            }
            let link = Hyperlink()
            link.navigateUri = Uri(url.absoluteString)
            link.foreground = WindowsTimelineTheme.accent(theme.current)
            inlines.append(link)
            linkDestinations.append(url.absoluteString)
            hasRichText = true
            var linked = style
            linked.insideLink = true
            appendText(destination, to: link.inlines, style: linked)
            collection.append(link)
            offset = match.range.location + (destination as NSString).length
        }
        if offset < input.length {
            appendText(input.substring(from: offset), to: collection, style: style)
        }
    }

    private func appendText(_ value: String, to collection: InlineCollection, style: Style) {
        var text = restoreReferences(value, isCode: style.code)
        if !style.code { text = replaceEmojiShortcodes(text) }
        let run = Run()
        run.text = text
        if style.bold { run.fontWeight = .init(weight: 600) }
        if style.italic { run.fontStyle = .italic }
        if style.strike { run.textDecorations = .strikethrough }
        if style.code { run.fontFamily = FontFamily("Consolas") }
        collection.append(run)
        inlines.append(run)
        renderedText += text
    }

    private func textBlock() -> TextBlock {
        let text = TextBlock()
        text.fontSize = 13
        text.textWrapping = .wrap
        text.lineHeight = 21
        text.isTextSelectionEnabled = true
        theme.bindText(text)
        controls.append(text)
        return text
    }

    private func protectReferences(_ source: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: "<([@#])[A-Za-z0-9_-]+\\|([^<>\\r\\n]+)>") else { return source }
        let matches = expression.matches(in: source, range: NSRange(source.startIndex..., in: source))
        var prefix = "KOKOROREFERENCE"
        while source.contains(prefix) { prefix += "X" }
        let input = source as NSString
        let output = NSMutableString(string: source)
        for (index, match) in matches.enumerated().reversed() {
            let token = "\(prefix)\(index)END"
            references.append((token: token, original: input.substring(with: match.range),
                               label: input.substring(with: match.range(at: 1)) + input.substring(with: match.range(at: 2))))
            output.replaceCharacters(in: match.range, with: token)
        }
        return output as String
    }

    private func restoreReferences(_ source: String, isCode: Bool) -> String {
        references.reduce(source) { $0.replacingOccurrences(of: $1.token, with: isCode ? $1.original : $1.label) }
    }

    private func replaceEmojiShortcodes(_ source: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: ":[A-Za-z0-9_+\\-]+:(?::skin-tone-[1-6]:)?") else { return source }
        let output = NSMutableString(string: source)
        for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            if let emoji = WindowsEmojiCatalog.character(fromShortCode: (source as NSString).substring(with: match.range)) {
                output.replaceCharacters(in: match.range, with: emoji)
            }
        }
        return output as String
    }

    private func inset(_ value: Double) -> Thickness {
        .init(left: value, top: value, right: value, bottom: value)
    }
}
