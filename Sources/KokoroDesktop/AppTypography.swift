import AppKit
import SwiftUI

enum AppTypography {
    static let defaultsKey = "fontScalePercent"
    static let defaultPercent = 100
    static let percentages = [50, 66, 75, 80, 90, 100, 110, 120, 130, 140, 150, 166, 175, 200]

    static func scale(for percent: Int) -> CGFloat {
        CGFloat(percentages.contains(percent) ? percent : defaultPercent) / 100
    }
}

private struct AppFontScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var appFontScale: CGFloat {
        get { self[AppFontScaleKey.self] }
        set { self[AppFontScaleKey.self] = newValue }
    }
}

private struct ScaledFont: ViewModifier {
    @Environment(\.appFontScale) private var scale
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(size: size * scale, weight: weight, design: design))
    }
}

extension View {
    func scaledFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: design))
    }

    func scaledFont(_ style: NSFont.TextStyle, weight: Font.Weight = .regular) -> some View {
        scaledFont(size: NSFont.preferredFont(forTextStyle: style).pointSize, weight: weight)
    }
}

/// macOS's SwiftUI menu picker keeps its title at the system size, so use a native
/// popup whose selected value and menu items share the app's font scale.
struct ScaledPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    @Environment(\.appFontScale) private var scale

    var body: some View {
        FontSizedPicker(title: title, selection: $selection, options: options)
            .alignmentGuide(.firstTextBaseline) { dimensions in
                let font = NSFont.systemFont(ofSize: 13 * scale)
                return (dimensions.height + font.ascender + font.descender) / 2
            }
    }
}

private struct FontSizedPicker<Value: Hashable>: NSViewRepresentable {
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    @Environment(\.appFontScale) private var scale
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = FontSizedPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectValue(_:))
        button.setAccessibilityLabel(title)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        button.removeAllItems()
        button.addItems(withTitles: options.map(\.title))
        let font = NSFont.systemFont(ofSize: 13 * scale)
        button.font = font
        for item in button.itemArray {
            item.attributedTitle = NSAttributedString(string: item.title, attributes: [.font: font])
        }
        button.selectItem(at: options.firstIndex(where: { $0.value == selection }) ?? -1)
        button.isEnabled = isEnabled
        button.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    final class Coordinator: NSObject {
        var parent: FontSizedPicker
        init(_ parent: FontSizedPicker) { self.parent = parent }

        @objc func selectValue(_ sender: NSPopUpButton) {
            guard parent.options.indices.contains(sender.indexOfSelectedItem) else { return }
            parent.selection = parent.options[sender.indexOfSelectedItem].value
        }
    }
}

private final class FontSizedPopUpButton: NSPopUpButton {
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        if let font { size.height = max(size.height, ceil(font.ascender - font.descender) + 10) }
        return size
    }
}
