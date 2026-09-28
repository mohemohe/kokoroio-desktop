import Foundation
import UWP
import WinUI
@_spi(WinRTInternal) import WindowsFoundation

/// Runtime inspection of the app-owned controls, including native layout bounds.
/// This intentionally excludes WinUI template internals. Screenshots remain the
/// evidence for clipping, typography, colors and OS-rendered control appearances.
@MainActor
enum WindowsUIAudit {
    struct Bounds: Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        var right: Double { x + width }
        var bottom: Double { y + height }
        var midY: Double { y + height / 2 }
    }

    struct Node: Codable {
        let id: Int
        let parent: Int?
        let kind: String
        let name: String
        let automationName: String
        let toolTip: String
        let text: String?
        let placeholder: String?
        let bounds: Bounds?
        let enabled: Bool?
        let fontSize: Double?
        let fontWeight: UInt16?

        var actionLabel: String { automationName.isEmpty ? toolTip : automationName }
    }

    struct Snapshot: Codable {
        let nodes: [Node]
        let inspectionFailures: [String]

        func matching(_ text: String) -> [Node] { nodes.filter { $0.text == text } }
        func actions(_ label: String) -> [Node] {
            nodes.filter { ["Button", "HyperlinkButton", "ToggleButton"].contains($0.kind) && $0.actionLabel == label }
        }
        func isDescendant(_ node: Node, of ancestor: Node) -> Bool {
            var parent = node.parent
            while let id = parent {
                if id == ancestor.id { return true }
                parent = nodes[id].parent
            }
            return false
        }
        func ancestor(of node: Node, kind: String) -> Node? {
            var parent = node.parent
            while let id = parent {
                if nodes[id].kind == kind { return nodes[id] }
                parent = nodes[id].parent
            }
            return nil
        }
    }

    static func inspect(element: FrameworkElement) -> Snapshot {
        var nodes: [Node] = []
        var failures: [String] = []
        do { try element.updateLayout() }
        catch { failures.append("Layout update failed: \(error)") }

        func walk(_ current: UIElement, parent: Int?) {
            // A collapsed or transparent ancestor hides the complete subtree.
            guard current.visibility == .visible, current.opacity > 0 else { return }
            let id = nodes.count
            let framework = current as? FrameworkElement
            var bounds: Bounds?
            if let framework {
                do {
                    let transform = try framework.transformToVisual(element)
                    if let point = try transform?.transformPoint(.init(x: 0, y: 0)),
                       point.x.isFinite, point.y.isFinite,
                       framework.actualWidth.isFinite, framework.actualHeight.isFinite {
                        bounds = .init(x: Double(point.x), y: Double(point.y),
                                       width: framework.actualWidth, height: framework.actualHeight)
                    } else {
                        failures.append("Layout bounds are unavailable for \(kind(of: current)).")
                    }
                } catch { failures.append("Cannot locate \(kind(of: current)): \(error)") }
            }
            let control = current as? Control
            let label = current as? TextBlock
            // Never inspect TextBox.text or PasswordBox.password: login drafts,
            // messages and API keys are not required to audit UI composition.
            let text = label?.text ?? unboxString((current as? ContentControl)?.content)
            let placeholder = (current as? TextBox)?.placeholderText ?? (current as? PasswordBox)?.placeholderText
            nodes.append(.init(id: id, parent: parent, kind: kind(of: current),
                name: framework?.name ?? "", automationName: (try? AutomationProperties.getName(current)) ?? "",
                toolTip: unboxString(try? ToolTipService.getToolTip(current)) ?? "",
                text: text, placeholder: placeholder, bounds: bounds, enabled: control?.isEnabled,
                fontSize: label?.fontSize ?? control?.fontSize,
                fontWeight: label?.fontWeight.weight ?? control?.fontWeight.weight))

            if let panel = current as? Panel {
                for index in 0..<panel.children.count {
                    if let child = panel.children[index] { walk(child, parent: id) }
                }
            } else if let border = current as? Border {
                if let child = border.child { walk(child, parent: id) }
            } else if let content = current as? ContentControl, let child = content.content as? UIElement {
                walk(child, parent: id)
            }
        }
        walk(element, parent: nil)
        return .init(nodes: nodes, inspectionFailures: failures)
    }

    static func save(_ snapshot: Snapshot, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    /// Call with a signed-in fixture after its layout pass, then again with the
    /// header's search field open. Returns independently actionable violations.
    static func validateWorkspace(_ snapshot: Snapshot, channelName: String,
                                  connectionLabel: String, searchOpen: Bool) -> [String] {
        var failures = snapshot.inspectionFailures
        func expect(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
        expect(!snapshot.nodes.contains { $0.kind == "ToggleSwitch" }, "Workspace must not contain a system-notification switch.")
        expect(!snapshot.nodes.contains { $0.text?.contains("システム通知") == true }, "System-notification controls belong only in Settings.")
        expect(snapshot.matching("ログアウト").isEmpty, "Logout must appear only in Settings.")
        expect(snapshot.matching("Kokoro Desktop").isEmpty, "Sidebar must start with search, without an app-title heading.")
        let channelSearch = snapshot.nodes.first { $0.kind == "TextBox" && $0.placeholder == "チャンネルを検索" }
        expect(channelSearch != nil, "Sidebar channel search is missing.")
        expect(snapshot.matching("未読メッセージ").count == 1, "Sidebar needs the unread-message row.")
        expect(snapshot.matching("ピン留め").count == 1, "Pinned section must remain visible, including when empty.")
        let connection = snapshot.matching(connectionLabel)
        expect(connection.count == 1, "Connection status must have exactly one workspace location.")
        if let status = connection.first?.bounds, let search = channelSearch?.bounds,
           let root = snapshot.nodes.first?.bounds {
            expect(status.x < search.x + 310 && status.y > root.height * 0.6, "Connection status must be in the sidebar footer.")
        }
        let title = snapshot.matching(channelName).first { $0.fontSize == 16 && $0.fontWeight == 700 }
        expect(title != nil, "Header channel title must use the macOS 16-point bold hierarchy.")
        let searchField = snapshot.nodes.first { $0.kind == "TextBox" && $0.placeholder == "このチャンネルのメッセージを検索" }
        let action = searchOpen ? snapshot.actions("検索を閉じる").first : snapshot.actions("最新のメッセージを取得").first
        expect(action != nil, "Header right action must be \(searchOpen ? "close search" : "refresh").")
        expect(searchOpen ? searchField != nil : searchField == nil, "Channel search visibility does not match its open state.")
        expect(searchOpen ? snapshot.actions("チャンネル内を検索").isEmpty : snapshot.actions("チャンネル内を検索").count == 1,
               "Inline search must replace its magnifying-glass button.")
        if let titleBounds = title?.bounds, let actionBounds = action?.bounds {
            expect(actionBounds.x > titleBounds.x && abs(actionBounds.midY - titleBounds.midY) < 35,
                   "Refresh/close belongs to the right of the title in the same header.")
            expect(!snapshot.nodes.contains { node in
                guard node.kind == "Button", node.actionLabel.contains("ピン留め"), let bounds = node.bounds else { return false }
                return bounds.x > titleBounds.x && abs(bounds.midY - titleBounds.midY) < 35
            }, "Pin actions belong to sidebar rows, not the conversation header.")
        }
        if let field = searchField?.bounds, let titleBounds = title?.bounds, let actionBounds = action?.bounds {
            expect(field.x > titleBounds.x && field.right <= actionBounds.x + 1 && abs(field.midY - titleBounds.midY) < 35,
                   "Channel search must occupy the header, not a separate row.")
        }
        return failures
    }

    static func validateComposer(_ snapshot: Snapshot, channelName: String,
                                 hasImageKey: Bool, canSend: Bool, isSending: Bool = false) -> [String] {
        var failures = snapshot.inspectionFailures
        func expect(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
        guard let editor = snapshot.nodes.first(where: { $0.kind == "TextBox" && $0.automationName == "メッセージ" }) else {
            return ["Composer editor is missing."]
        }
        expect(editor.placeholder == channelName + " にメッセージを送信", "Composer placeholder must name the selected channel.")
        expect(editor.fontSize == 13, "Composer editor must use 13-point text.")
        expect(editor.enabled == !isSending, "Composer editor must be disabled during sending.")
        if let bounds = editor.bounds { expect(bounds.height >= 37 && bounds.height <= 171, "Composer editor must grow between 38 and 170 points.") }
        guard let card = snapshot.ancestor(of: editor, kind: "Border") else { return failures + ["Composer editor needs a shared card border."] }
        let descendants = snapshot.nodes.filter { snapshot.isDescendant($0, of: card) }
        let counter = descendants.contains { node in
            guard let text = node.text else { return false }
            return text.range(of: #"^\s*\d+\s*/\s*4[,]?000\s*$"#, options: .regularExpression) != nil
        }
        expect(!counter, "Character counter must remain absent, including near the limit.")
        let image = snapshot.actions("画像を追加").first
        let emoji = snapshot.actions("絵文字を挿入").first
        let send = snapshot.actions("メッセージを送信").first
        expect(image != nil && emoji != nil && send != nil, "Composer requires image, emoji and send icon buttons.")
        for action in [image, emoji, send].compactMap({ $0 }) {
            expect(snapshot.isDescendant(action, of: card), "Composer icon \(action.actionLabel) must be inside the editor card.")
            expect(action.text == nil, "Composer actions must use icons instead of visible text buttons.")
        }
        expect(image?.enabled == (hasImageKey && !isSending), "Image action must be disabled without an API key or during sending.")
        expect(emoji?.enabled == !isSending, "Emoji action must be disabled during sending.")
        expect(send?.enabled == canSend, "Send action does not reflect draft eligibility.")
        if let image = image?.bounds, let emoji = emoji?.bounds, let send = send?.bounds, let editor = editor.bounds {
            expect(image.x < emoji.x && emoji.right < send.x, "Composer toolbar order must be image, emoji, spacer, send.")
            expect(abs(image.midY - send.midY) < 2 && image.y >= editor.bottom - 1, "Composer toolbar must form one row below the editor.")
            expect(abs(image.width - 28) < 1 && abs(image.height - 28) < 1, "Image icon target must be 28 by 28 points.")
            expect(abs(send.width - 30) < 1 && abs(send.height - 28) < 1, "Send target must be 30 by 28 points.")
        }
        let hint = snapshot.matching("Enterで送信 · Shift + Enterで改行")
        expect(hint.count == 1 && hint.first?.fontSize == 10, "Composer requires exactly one 10-point keyboard hint.")
        if let hint = hint.first, let hintBounds = hint.bounds, let cardBounds = card.bounds {
            expect(!snapshot.isDescendant(hint, of: card) && hintBounds.y >= cardBounds.bottom,
                   "Keyboard hint belongs below the composer card.")
            expect(abs(hintBounds.right - cardBounds.right) < 2, "Keyboard hint must align to the card's right edge.")
        }
        for preview in descendants.filter({ $0.kind == "Image" }) {
            // UniformToFill preserves the bitmap aspect ratio and can report a
            // larger Image extent. The enclosing rounded Border defines the
            // visible, cropped thumbnail, just like macOS scaledToFill + frame.
            guard let frame = snapshot.ancestor(of: preview, kind: "Border"), frame.id != card.id,
                  let bounds = frame.bounds, let editor = editor.bounds else {
                failures.append("Attachment preview must have a measurable frame inside the composer card.")
                continue
            }
            expect(abs(bounds.width - 76) < 1 && abs(bounds.height - 64) < 1 && bounds.y < editor.y,
                   "Attachment preview frames must be 76 by 64 points above the editor inside the card.")
            if let container = snapshot.ancestor(of: frame, kind: "Grid")?.bounds {
                expect(abs(container.width - 76) < 1 && abs(container.height - 64) < 1,
                       "Attachment preview and its overlay controls must share a 76 by 64 point container.")
            }
        }
        return failures
    }

    static func validateSettings(_ snapshot: Snapshot, signedIn: Bool, notificationsEnabled: Bool) -> [String] {
        var failures = snapshot.inspectionFailures
        func expect(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
        let headings = snapshot.nodes.filter { $0.kind == "TextBlock" && $0.fontSize == 13 && $0.fontWeight == 600 }
        expect(headings.compactMap(\.text) == ["通知", "画像アップロード", "接続"], "Settings must contain exactly three ordered sections: notifications, image upload, connection.")
        for text in ["接続済み", "接続中…", "再接続中…", "未接続"] {
            expect(snapshot.matching(text).isEmpty, "Settings must not show realtime connection status (\(text)).")
        }
        let toggles = snapshot.nodes.filter { $0.kind == "ToggleSwitch" }
        expect(toggles.count == 2, "Settings requires notification and sound switches.")
        expect(snapshot.matching("システム通知を表示").count == 1, "System-notification label must match macOS.")
        expect(snapshot.matching("通知の対象").count == 1, "Notification target row is missing.")
        expect(snapshot.matching("通知音を鳴らす").count == 1, "Notification sound row is missing.")
        let targets = snapshot.nodes.filter { $0.kind == "ComboBox" }
        expect(targets.count == 1 && targets.first?.enabled == notificationsEnabled, "Notification target must follow notification-switch availability.")
        if toggles.count == 2 { expect(toggles[1].enabled == notificationsEnabled, "Notification sound must follow notification-switch availability.") }
        let keys = snapshot.nodes.filter { $0.kind == "PasswordBox" }
        expect(keys.count == 1 && keys.first?.placeholder == "ImgBB の API キー", "Image-upload settings requires one secure ImgBB key field.")
        expect(!snapshot.nodes.contains { $0.kind == "Button" && ($0.text?.contains("保存") == true) }, "ImgBB key must persist edits without a separate Save button.")
        expect(snapshot.matching("サーバー").count == 1, "Connection section must show the server.")
        expect(snapshot.matching("アカウント").count == (signedIn ? 1 : 0), "Account row must follow signed-in state.")
        expect(snapshot.matching("ログアウト").count == (signedIn ? 1 : 0), "Logout must follow signed-in state.")
        if headings.count == 3, let uploadY = headings[1].bounds?.y, let connectionY = headings[2].bounds?.y,
           let keyY = keys.first?.bounds?.y {
            expect(keyY > uploadY && keyY < connectionY, "ImgBB key must be inside the image-upload section.")
            expect(toggles.allSatisfy { ($0.bounds?.y ?? .infinity) < uploadY }, "Notification switches must remain in the notification section.")
        }
        if let size = snapshot.nodes.first?.bounds {
            expect(abs(size.width - 480) < 2 && abs(size.height - 470) < 2, "Settings content must retain the macOS 480 by 470 point size.")
        }
        return failures
    }

    private static func kind(of element: UIElement) -> String {
        switch element {
        case is PasswordBox: return "PasswordBox"
        case is TextBox: return "TextBox"
        case is TextBlock: return "TextBlock"
        case is ToggleSwitch: return "ToggleSwitch"
        case is CheckBox: return "CheckBox"
        case is ToggleButton: return "ToggleButton"
        case is ComboBox: return "ComboBox"
        case is HyperlinkButton: return "HyperlinkButton"
        case is Button: return "Button"
        case is ProgressRing: return "ProgressRing"
        case is Image: return "Image"
        case is ScrollViewer: return "ScrollViewer"
        case is Grid: return "Grid"
        case is StackPanel: return "StackPanel"
        case is Border: return "Border"
        case is Thumb: return "Thumb"
        default: return String(describing: type(of: element))
        }
    }

    private static func unboxString(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let property = value as? any IPropertyValue, property.type == .string {
            return try? property.getString()
        }
        // WinUI can return Content and ToolTip as an IInspectable containing a
        // Windows.Foundation.PropertyValue. This projection does not unbox it
        // automatically, and its public IPropertyValueBridge.from initializer
        // is unimplemented. Query the generated ABI interface directly instead.
        guard let inspectable = (value as? IInspectable) ?? (value as? IWinRTObject)?.thisPtr else { return nil }
        do {
            let property: __ABI_Windows_Foundation.IPropertyValue = try inspectable.QueryInterface()
            guard try property.get_Type() == .string else { return nil }
            return try property.GetString()
        } catch { return nil }
    }
}
