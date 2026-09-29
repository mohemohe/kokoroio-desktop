import Foundation
import WinAppSDK
import WinUI
import WindowsNative

@MainActor
enum WindowsTitleBar {
    static func configure(for window: Window) {
        // WinUI does not automatically use the executable's icon for its windows.
        // Resolve the embedded resource so packaged builds need no external ICO.
        var iconId: UInt64 = 0
        let result = KokoroGetApplicationIconId(&iconId)
        if result >= 0 {
            do { try window.appWindow.setIcon(IconId(value: iconId)) }
            catch { fputs("Could not set the window icon: \(error)\n", stderr) }
        } else {
            fputs("Could not load the application icon. HRESULT: \(String(UInt32(bitPattern: result), radix: 16))\n", stderr)
        }

        guard (try? AppWindowTitleBar.isCustomizationSupported()) == true else { return }
        // The SDK defaults to Legacy. Let Windows choose and update the native
        // caption and button colors using Settings > Colors > default app mode.
        window.appWindow.titleBar.preferredTheme = .useDefaultAppMode
    }
}
