import Foundation
import XCTest
@testable import KokoroCore

final class TimelineRulesTests: XCTestCase {
    private let currentProfileID = "MYPROF001"

    func testOverlappingNewestFirstPagesAndEventsPreserveLoadedHistoryInDisplayOrder() {
        let existing = [message(10), message(11), message(12), message(15)]
        let page = [message(16), message(15), message(14), message(13), message(12)]
        let merged = TimelineRules.merge(existing, with: page)
        XCTAssertEqual(merged.map(\.id), [10, 11, 12, 13, 14, 15, 16])
        XCTAssertEqual(TimelineRules.merge(merged, with: page), merged)
    }

    func testUpdatedMessageReplacesOriginalWithoutDuplicatingOrMovingItsPosition() {
        let original = message(22, content: "Before edit")
        var update = original
        update.rawContent = "After edit"
        update.plaintextContent = "After edit"
        let merged = TimelineRules.merge([message(21), original, message(23)], with: [update])
        XCTAssertEqual(merged.map(\.id), [21, 22, 23])
        XCTAssertEqual(merged[1].text, "After edit")
    }

    func testDeletionUpdateRetainsOneTombstoneBetweenSurroundingMessages() {
        let original = message(32, content: "Removed content")
        var deletion = original
        deletion.status = "deleted_by_publisher"
        deletion.rawContent = ""
        deletion.plaintextContent = ""
        let merged = TimelineRules.merge([message(31), original, message(33)], with: [deletion, deletion])
        XCTAssertEqual(merged.map(\.id), [31, 32, 33])
        XCTAssertTrue(merged[1].isDeleted)
        XCTAssertEqual(merged[1].text, "")
    }

    func testMergeHandlesDuplicateExistingIDsAndUsesLastIncomingUpdate() {
        let original = message(41, content: "First version")
        var update = original
        update.plaintextContent = "Latest version"
        let merged = TimelineRules.merge([original, original], with: [original, update])
        XCTAssertEqual(merged, [update])
    }

    func testRefreshKeepsUnreadInEveryUnacknowledgedChannelEvenWhenServerCursorAdvances() {
        let previous = (1...3).map { index -> Channel in
            var room = unreadChannel(count: index, cursor: 10, latest: 20)
            room.id = "CHANNEL0\(index)"
            room.membership?.id = "MEMBER00\(index)"
            return room
        }
        let refreshed = previous.map { room -> Channel in
            var incoming = room
            incoming.membership?.unreadCount = 0
            incoming.membership?.latestReadMessageID = 20
            return TimelineRules.reconcileUnreadState(in: incoming, previous: room, cachedMessages: [], currentProfileID: currentProfileID)
        }
        XCTAssertEqual(refreshed.map(\.unreadCount), [1, 2, 3])
        XCTAssertEqual(refreshed.map { $0.membership?.latestReadMessageID }, [10, 10, 10])
        XCTAssertEqual(refreshed.reduce(0) { $0 + $1.unreadCount }, 6)
    }

    func testRefreshKeepsUnreadArrivingWhileMembershipRequestIsInFlight() {
        let incoming = unreadChannel(count: 2, cursor: 10, latest: 20)
        let current = unreadChannel(count: 3, cursor: 10, latest: 21)
        let merged = TimelineRules.reconcileUnreadState(in: incoming, previous: current, cachedMessages: [message(21)], currentProfileID: currentProfileID)
        XCTAssertEqual(merged.unreadCount, 3)
        XCTAssertEqual(merged.membership?.latestReadMessageID, 10)
    }

    func testRefreshAcceptsAdditionalUnreadWithoutAcknowledgingExistingUnread() {
        let incoming = unreadChannel(count: 5, cursor: 10, latest: 25)
        let current = unreadChannel(count: 2, cursor: 10, latest: 20)
        let merged = TimelineRules.reconcileUnreadState(in: incoming, previous: current, cachedMessages: [], currentProfileID: currentProfileID)
        XCTAssertEqual(merged.unreadCount, 5)
    }

    func testRefreshAfterAcknowledgingOneChannelKeepsOtherChannelsUnread() {
        let acknowledged = unreadChannel(count: 0, cursor: 20, latest: 20)
        let stale = unreadChannel(count: 3, cursor: 10, latest: 20)
        let read = TimelineRules.reconcileUnreadState(in: stale, previous: acknowledged, cachedMessages: [message(20)], currentProfileID: currentProfileID)
        let untouched = TimelineRules.reconcileUnreadState(in: stale, previous: stale, cachedMessages: [], currentProfileID: currentProfileID)
        XCTAssertEqual(read.unreadCount, 0)
        XCTAssertEqual(read.membership?.latestReadMessageID, 20)
        XCTAssertEqual(untouched.unreadCount, 3)
    }

    func testStaleRefreshAfterAcknowledgementRetainsOnlyNewerMessagesFromOtherPeople() {
        let current = unreadChannel(count: 1, cursor: 20, latest: 22)
        let stale = unreadChannel(count: 5, cursor: 10, latest: 22)
        let merged = TimelineRules.reconcileUnreadState(in: stale, previous: current,
                                                      cachedMessages: [message(19), message(20), message(21), message(22, profileID: currentProfileID)],
                                                      currentProfileID: currentProfileID)
        XCTAssertEqual(merged.unreadCount, 1)
        XCTAssertEqual(merged.membership?.latestReadMessageID, 20)
    }

    func testInitialMembershipUsesServerReadBoundary() {
        let incoming = unreadChannel(count: 5, cursor: 20, latest: 20)
        let merged = TimelineRules.reconcileUnreadState(in: incoming, previous: nil, cachedMessages: [], currentProfileID: currentProfileID)
        XCTAssertEqual(merged.unreadCount, 0)
    }

    func testRejoinedChannelDoesNotReusePreviousMembershipUnread() {
        let previous = unreadChannel(count: 5, cursor: 10, latest: 20)
        var incoming = unreadChannel(count: 0, cursor: 20, latest: 20)
        incoming.membership?.id = "NEWMEMBER"
        let merged = TimelineRules.reconcileUnreadState(in: incoming, previous: previous, cachedMessages: [], currentProfileID: currentProfileID)
        XCTAssertEqual(merged.unreadCount, 0)
        XCTAssertEqual(merged.membership?.latestReadMessageID, 20)
    }

    func testOwnMessagesNeverNotifyIncludingDirectMessagesAndMentions() {
        let direct = channel(policy: "all_messages", direct: true)
        let own = message(50, content: "<@MYPROF001|alice>", profileID: currentProfileID, channel: direct)
        for target in DesktopNotificationTarget.allCases {
            XCTAssertFalse(shouldNotify(own, in: direct, target: target))
        }
    }

    func testActiveVisibleConversationSuppressesNotificationIncludingDirectMessages() {
        for direct in [false, true] {
            let room = channel(policy: "all_messages", direct: direct)
            for target in DesktopNotificationTarget.allCases {
                XCTAssertFalse(shouldNotify(message(51, channel: room), in: room, isReading: true, target: target))
            }
        }
    }

    func testMentionsAndDirectMessagesTargetMatchesRawProfileIDInsteadOfRenderedName() {
        let room = channel(policy: "all_messages")
        var mention = message(60, content: "Hello <@MYPROF001|old_screen_name>", channel: room)
        mention.plaintextContent = "Hello @old_screen_name"
        XCTAssertTrue(shouldNotify(mention, in: room))
        XCTAssertFalse(shouldNotify(message(59, channel: room), in: room))
        XCTAssertFalse(shouldNotify(message(61, content: "Hello @alice", channel: room), in: room))
        XCTAssertFalse(shouldNotify(message(62, content: "<@OTHER0001|alice>", channel: room), in: room))
        XCTAssertFalse(shouldNotify(message(63, content: "<@MYPROF001X|alice>", channel: room), in: room))
    }

    func testMalformedMentionDoesNotNotify() {
        let room = channel(policy: "all_messages")
        for content in ["<@MYPROF001|alice", "<@MYPROF001|>", "<@MYPROF001|not a username>"] {
            XCTAssertFalse(shouldNotify(message(64, content: content, channel: room), in: room), content)
        }
    }

    func testDirectMessageNotifiesForBothTargets() {
        let room = channel(policy: "nothing", direct: true)
        for target in DesktopNotificationTarget.allCases {
            XCTAssertTrue(shouldNotify(message(70, channel: room), in: room, target: target))
        }
    }

    func testAllMessagesTargetIncludesOrdinaryChannelMessagesRegardlessOfChannelPolicy() {
        for policy in ["only_mentions", "nothing", "all_messages"] {
            let room = channel(policy: policy)
            XCTAssertTrue(shouldNotify(message(70, channel: room), in: room, target: .allMessages))
        }
    }

    func testMuteSuppressesBothTargets() {
        for room in [channel(policy: "all_messages", muted: true), channel(policy: "only_mentions", muted: true), channel(policy: "nothing", direct: true, muted: true)] {
            for target in DesktopNotificationTarget.allCases {
                XCTAssertFalse(shouldNotify(message(71, content: "<@MYPROF001|alice>", channel: room), in: room, target: target))
            }
        }
    }

    func testMentionTargetIncludesMentionWhenChannelPolicyIsNothing() {
        let room = channel(policy: "nothing")
        XCTAssertTrue(shouldNotify(message(72, content: "<@MYPROF001|alice>", channel: room), in: room))
    }

    func testDeletedMessagesNeverNotify() {
        let room = channel(policy: "all_messages")
        for status in ["deleted_by_publisher", "deleted_by_another_member"] {
            var deleted = message(73, channel: room)
            deleted.status = status
            for target in DesktopNotificationTarget.allCases {
                XCTAssertFalse(shouldNotify(deleted, in: room, target: target))
            }
        }
    }

    private func shouldNotify(_ message: Message, in channel: Channel, isReading: Bool = false, target: DesktopNotificationTarget = .mentionsAndDirectMessages) -> Bool {
        TimelineRules.shouldNotify(message: message, channel: channel, currentProfileID: currentProfileID, isReadingChannel: isReading, target: target)
    }

    private func channel(policy: String = "all_messages", direct: Bool = false, muted: Bool = false) -> Channel {
        Channel(id: "CHANNEL01", channelName: "general", kind: direct ? "direct_message" : "public_channel", membership: MembershipDetails(id: "MEMBER001", notificationPolicy: policy, muted: muted))
    }

    private func unreadChannel(count: Int, cursor: Int, latest: Int) -> Channel {
        var room = channel()
        room.latestMessageID = latest
        room.membership?.latestReadMessageID = cursor
        room.membership?.unreadCount = count
        return room
    }

    private func message(_ id: Int, content: String = "Hello", profileID: String = "OTHER0001", channel: Channel? = nil) -> Message {
        Message(id: id, idempotentKey: "message-\(id)", plaintextContent: content, rawContent: content, publishedAt: Date(timeIntervalSince1970: Double(id)), channel: channel ?? self.channel(), profile: Profile(id: profileID, screenName: "alice", displayName: "Alice"))
    }
}
