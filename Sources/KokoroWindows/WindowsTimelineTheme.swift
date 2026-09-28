import UWP
import WinUI
import WindowsFoundation

/// Timeline controls retain native wrappers across ScrollViewer reparenting.
/// Their own ActualTheme can remain stale, so the owning window passes its
/// authoritative theme explicitly. Child Loaded/theme events must not overwrite it.
@MainActor
final class WindowsTimelineTheme {
    private(set) var current: ElementTheme = .light
    private var updates: [(ElementTheme) -> Void] = []

    func apply(_ theme: ElementTheme) {
        let value: ElementTheme = theme == .dark ? .dark : .light
        guard value != current else { return }
        current = value
        updates.forEach { $0(current) }
    }

    func dispose() { updates.removeAll() }

    static func primary(_ theme: ElementTheme, alpha: UInt8 = 255) -> SolidColorBrush {
        let value: UInt8 = theme == .dark ? 244 : 28
        return SolidColorBrush(.init(a: alpha, r: value, g: value, b: value))
    }

    static func accent(_ theme: ElementTheme) -> SolidColorBrush {
        let color: UWP.Color = theme == .dark
            ? .init(a: 255, r: 196, g: 166, b: 245)
            : .init(a: 255, r: 110, g: 74, b: 168)
        return SolidColorBrush(color)
    }

    func bind<Element: FrameworkElement>(_ element: Element, apply: @escaping (Element, ElementTheme) -> Void) {
        let update: (ElementTheme) -> Void = { [weak element] theme in
            guard let element else { return }
            apply(element, theme)
        }
        updates.append(update)
        update(current)
    }

    func bindText(_ text: TextBlock) {
        bind(text) { control, theme in
            control.foreground = Self.primary(theme)
            Self.updateLinks(control.inlines, theme: theme)
        }
    }

    private static func updateLinks(_ collection: InlineCollection, theme: ElementTheme) {
        for value in collection {
            guard let inline = value else { continue }
            if let link = inline as? Hyperlink { link.foreground = accent(theme) }
            if let span = inline as? Span { updateLinks(span.inlines, theme: theme) }
        }
    }
}
