import Combine
import Foundation
import KokoroCore
import UserNotifications

@MainActor
final class NotificationService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Keys.enabled) }
    }
    @Published var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: Keys.soundEnabled) }
    }
    @Published var target: DesktopNotificationTarget {
        didSet { defaults.set(target.rawValue, forKey: Keys.target) }
    }
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var lastError: String?

    var onOpenChannel: ((String) -> Void)?

    private let defaults: UserDefaults
    private let center: UNUserNotificationCenter
    private var scheduledIDs = Set<String>()
    private var scheduledOrder: [String] = []
    private var generation = 0

    private enum Keys {
        static let enabled = "notifications.enabled"
        static let soundEnabled = "notifications.soundEnabled"
        static let target = "notifications.target"
        static let badgeAuthorizationRequested = "notifications.badgeAuthorizationRequested"
    }

    init(defaults: UserDefaults = .standard, center: UNUserNotificationCenter = .current()) {
        self.defaults = defaults
        self.center = center
        defaults.register(defaults: [Keys.enabled: true, Keys.soundEnabled: true])
        enabled = defaults.bool(forKey: Keys.enabled)
        soundEnabled = defaults.bool(forKey: Keys.soundEnabled)
        target = DesktopNotificationTarget(rawValue: defaults.string(forKey: Keys.target) ?? "") ?? .mentionsAndDirectMessages
        super.init()
        center.delegate = self
        Task {
            let settings = await center.notificationSettings()
            authorizationStatus = settings.authorizationStatus
            if settings.badgeSetting == .enabled {
                defaults.set(true, forKey: Keys.badgeAuthorizationRequested)
            } else if isAuthorized && !defaults.bool(forKey: Keys.badgeAuthorizationRequested) {
                // Existing installations requested alerts and sounds, but never badges.
                await requestAuthorization()
            }
        }
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorized || authorizationStatus == .provisional
    }

    func refreshAuthorizationStatus() async {
        authorizationStatus = await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization() async {
        lastError = nil
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            defaults.set(true, forKey: Keys.badgeAuthorizationRequested)
        } catch {
            lastError = error.localizedDescription
        }
        await refreshAuthorizationStatus()
    }

    func resetSession() {
        generation += 1
        scheduledIDs.removeAll()
        scheduledOrder.removeAll()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    /// The chat store decides whether the message warrants a notification,
    /// including whether its conversation is already visible in the active app.
    func schedule(messageID: Int, channelID: String, channelName: String, sender: String, body: String) {
        guard enabled else { return }
        let identifier = "kokoro.message.\(channelID).\(messageID)"
        guard scheduledIDs.insert(identifier).inserted else { return }
        let sessionGeneration = generation

        Task {
            await refreshAuthorizationStatus()
            guard sessionGeneration == generation, enabled, isAuthorized else {
                scheduledIDs.remove(identifier)
                return
            }

            let content = UNMutableNotificationContent()
            content.title = channelName.hasPrefix("#") ? channelName : "#\(channelName)"
            content.subtitle = sender
            content.body = body.isEmpty ? "新しいメッセージ" : body
            content.sound = soundEnabled ? .default : nil
            content.userInfo = ["channelID": channelID, "messageID": messageID]

            do {
                try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
                guard sessionGeneration == generation else {
                    center.removeDeliveredNotifications(withIdentifiers: [identifier])
                    return
                }
                scheduledOrder.append(identifier)
                // Keep replay protection bounded for long-running sessions.
                if scheduledOrder.count > 1_000 {
                    scheduledIDs.remove(scheduledOrder.removeFirst())
                }
            } catch {
                scheduledIDs.remove(identifier)
                lastError = error.localizedDescription
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let channelID = response.notification.request.content.userInfo["channelID"] as? String else {
            return
        }
        await MainActor.run { onOpenChannel?(channelID) }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        await MainActor.run {
            guard enabled else { return [] }
            return soundEnabled ? [.banner, .list, .sound] : [.banner, .list]
        }
    }
}
