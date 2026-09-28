import WinAppSDK
import WinUI

@MainActor
enum WindowsTitleBar {
    static func followSystemTheme(for window: Window) {
        guard (try? AppWindowTitleBar.isCustomizationSupported()) == true else { return }
        // The SDK defaults to Legacy. Let Windows choose and update the native
        // caption and button colors using Settings > Colors > default app mode.
        window.appWindow.titleBar.preferredTheme = .useDefaultAppMode
    }
}
