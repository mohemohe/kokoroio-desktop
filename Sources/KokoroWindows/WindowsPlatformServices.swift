import Foundation
import WindowsNative

enum WindowsPlatformServices {
    struct Failure: LocalizedError {
        let code: UInt32
        var errorDescription: String? { "画像ファイルを選択できませんでした (\(code))。" }
    }

    /// Invoke synchronously from a UI event so the dialog belongs to the WinUI window.
    @MainActor
    static func pickImages() throws -> [URL] {
        var paths = [UInt16](repeating: 0, count: 65_536)
        var count: UInt32 = 0
        let result = KokoroPickImages(&paths, UInt32(paths.count), &count)
        if result == 1223 { return [] } // ERROR_CANCELLED
        guard result == 0 else { throw Failure(code: result) }
        let parts = paths.prefix(Int(count)).split(separator: 0).map { String(decoding: $0, as: UTF16.self) }
        guard let first = parts.first else { return [] }
        if parts.count == 1 { return [URL(fileURLWithPath: first)] }
        let directory = URL(fileURLWithPath: first, isDirectory: true)
        return parts.dropFirst().map { directory.appendingPathComponent($0) }
    }

    static var isShiftPressed: Bool { KokoroIsShiftPressed() != 0 }
    static var isControlPressed: Bool { KokoroIsControlPressed() != 0 }

    struct WindowSizingFailure: LocalizedError {
        let code: UInt32
        var errorDescription: String? { "ウィンドウの最小サイズを設定・確認できませんでした (\(code))。" }
    }

    /// Call immediately after activating the main window on its UI thread.
    @MainActor
    static func setMinimumWindowSize(width: Int32, height: Int32) throws {
        let result = KokoroSetMinimumWindowSize(width, height)
        guard result == 0 else { throw WindowSizingFailure(code: result) }
    }

    /// Reads the live WM_GETMINMAXINFO result without moving or resizing a window.
    @MainActor
    static func minimumClientSize() throws -> (width: Int32, height: Int32) {
        var width: Int32 = 0
        var height: Int32 = 0
        let result = KokoroGetMinimumClientSize(&width, &height)
        guard result == 0 else { throw WindowSizingFailure(code: result) }
        return (width, height)
    }

    struct EmojiPickerFailure: LocalizedError {
        let code: UInt32
        var errorDescription: String? {
            if code == 170 { return "修飾キーを離して、もう一度絵文字ボタンを押してください。" }
            return "絵文字パネルを開けませんでした (\(code))。メッセージ欄で Windows + . を押すこともできます。"
        }
    }

    /// Focus the composer before invoking this from its emoji-button action.
    @MainActor
    static func openEmojiPicker() throws {
        let result = KokoroShowEmojiPanel()
        guard result == 0 else { throw EmojiPickerFailure(code: result) }
    }

    /// Supplement TextBox composition events; TSF composition is tracked by the UI.
    static var isIMEComposing: Bool { KokoroIsIMEComposing() != 0 }
}
