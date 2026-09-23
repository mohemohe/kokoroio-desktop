import Foundation

public enum DesktopNotificationTarget: String, CaseIterable, Sendable {
    case mentionsAndDirectMessages
    case allMessages
}

public enum TimelineRules {
    /// REST pages are newest first; the UI is oldest first. Events can overlap pages.
    public static func merge(_ existing: [Message], with incoming: [Message]) -> [Message] {
        var byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        for message in incoming { byID[message.id] = message }
        return byID.values.sorted { $0.id < $1.id }
    }

    public static func shouldNotify(message: Message, channel: Channel, currentProfileID: String?, isReadingChannel: Bool, target: DesktopNotificationTarget) -> Bool {
        guard message.status == "active", message.profile.id != currentProfileID, !isReadingChannel,
              channel.membership?.muted != true else { return false }
        switch target {
        case .allMessages: return true
        case .mentionsAndDirectMessages:
            if channel.isDirectMessage { return true }
            guard let currentProfileID else { return false }
            let pattern = "<@" + NSRegularExpression.escapedPattern(for: currentProfileID) + "\\|[a-z0-9_-]+>"
            return message.rawContent.range(of: pattern, options: .regularExpression) != nil
        }
    }
}
