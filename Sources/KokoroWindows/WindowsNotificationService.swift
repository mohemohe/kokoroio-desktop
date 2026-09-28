import Foundation
import WinAppSDK
import WindowsFoundation

/// WinAppSDK registers unpackaged applications with Windows and delivers real toasts.
/// All UI activation is marshalled back from the COM callback to the main actor.
@MainActor
final class WindowsNotificationService {
    enum Failure: LocalizedError {
        case unsupported, notRegistered, disabled, notDelivered

        var errorDescription: String? {
            switch self {
            case .unsupported: return "この Windows 環境ではシステム通知を利用できません。"
            case .notRegistered: return "システム通知を初期化できませんでした。"
            case .disabled: return "Windows の設定で Kokoro Desktop の通知が無効になっています。"
            case .notDelivered: return "Windows に通知を送信できませんでした。"
            }
        }
    }

    private var manager: AppNotificationManager?
    private var invoked: EventCleanup?
    private var openChannel: ((String) -> Void)?
    private(set) var isRegistered = false
    private(set) var lastError: String?

    var areNotificationsAllowed: Bool { manager?.setting == .enabled }

    /// Register before any notification is sent. This does not display a toast.
    /// Register() creates the unpackaged app's COM activation registration/AUMID.
    func register(onOpenChannel: @escaping (String) -> Void) throws {
        lastError = nil
        openChannel = onOpenChannel
        guard !isRegistered else { return }
        guard try AppNotificationManager.isSupported() else { throw Failure.unsupported }
        let manager = AppNotificationManager.default!
        // Microsoft requires the handler to precede Register, so an existing process
        // receives notification clicks instead of launching another process.
        let event = manager.notificationInvoked.addHandler { [weak self] _, args in
            guard let argument = args?.argument,
                  let channelID = Self.channelID(from: argument) else { return }
            Task { @MainActor [weak self] in self?.openChannel?(channelID) }
        }
        do {
            try manager.register()
            self.manager = manager
            invoked = event
            isRegistered = true
        } catch {
            lastError = error.localizedDescription
            event.dispose()
            throw error
        }
    }

    func show(channelID: String, channelName: String, sender: String, body: String, soundEnabled: Bool = true) throws {
        guard isRegistered, let manager else { throw Failure.notRegistered }
        guard manager.setting == .enabled else { throw Failure.disabled }
        let notification = AppNotification(Self.payload(channelID: channelID, channelName: channelName, sender: sender, body: body, soundEnabled: soundEnabled))
        notification.group = "kokoro.chat"
        notification.expiresOnReboot = true
        notification.expiration = DateTime(universalTime: Int64((Date().timeIntervalSince1970 + 11_644_473_600 + 3_600) * 10_000_000))
        try manager.show(notification)
        guard notification.id != 0 else { throw Failure.notDelivered }
    }

    /// Remove message previews from Notification Center when signing out.
    func clear() async throws {
        guard let manager, isRegistered else { return }
        try await manager.removeAllAsync().get()
    }

    func shutdown() {
        if isRegistered { try? manager?.unregister() }
        invoked?.dispose()
        invoked = nil
        manager = nil
        openChannel = nil
        isRegistered = false
    }

    nonisolated static func payload(channelID: String, channelName: String, sender: String, body: String, soundEnabled: Bool = true) -> String {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "channel", value: channelID)]
        let argument = components.percentEncodedQuery ?? ""
        // Text and activation attributes originate from the server. Escape XML and
        // remove forbidden control scalars so malformed content cannot trap WinRT.
        return """
        <toast launch="\(xml(argument))"><visual><binding template="ToastGeneric"><text>\(xml(String(channelName.prefix(100))))</text><text>\(xml(String(sender.prefix(80)))): \(xml(String(body.prefix(360))))</text></binding></visual>\(soundEnabled ? "" : "<audio silent=\"true\"/>")</toast>
        """
    }

    nonisolated static func channelID(from argument: String) -> String? {
        guard let components = URLComponents(string: "kokoro://notification?\(argument)"),
              let value = components.queryItems?.first(where: { $0.name == "channel" })?.value,
              !value.isEmpty else { return nil }
        return value
    }

    nonisolated private static func xml(_ value: String) -> String {
        let allowed = value.unicodeScalars.filter {
            $0.value == 9 || $0.value == 10 || $0.value == 13 ||
            (0x20...0xD7FF).contains($0.value) || (0xE000...0xFFFD).contains($0.value) ||
            (0x10000...0x10FFFF).contains($0.value)
        }
        return String(String.UnicodeScalarView(allowed))
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
