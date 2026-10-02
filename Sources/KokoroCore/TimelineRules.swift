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

    /// Refreshing channel metadata cannot acknowledge messages in this client.
    /// Keep locally observed unread until the visible channel's read request succeeds.
    public static func reconcileUnreadState(in channel: Channel, previous: Channel?, cachedMessages: [Message], currentProfileID: String?) -> Channel {
        var result = channel
        if let previous = previous?.membership, previous.id == channel.membership?.id {
            if previous.latestReadMessageID > (channel.membership?.latestReadMessageID ?? 0) {
                result.membership?.latestReadMessageID = previous.latestReadMessageID
                result.membership?.unreadCount = cachedMessages.filter {
                    $0.id > previous.latestReadMessageID && $0.profile.id != currentProfileID
                }.count
            }
            if previous.unreadCount > 0 {
                let unreadCount = max(previous.unreadCount, result.unreadCount)
                result.membership?.latestReadMessageID = previous.latestReadMessageID
                result.membership?.unreadCount = unreadCount
                return result
            }
        }
        if let latest = channel.latestMessageID, (result.membership?.latestReadMessageID ?? 0) >= latest {
            result.membership?.unreadCount = 0
        }
        return result
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
