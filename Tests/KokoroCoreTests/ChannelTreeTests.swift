import Foundation
import XCTest
@testable import KokoroCore

final class ChannelTreeTests: XCTestCase {
    func testEmptyInputProducesNoRows() {
        XCTAssertTrue(ChannelTree.build([]).isEmpty)
    }

    func testSharedPrefixesFormOneGroupAndPreserveInputOrder() {
        let tree = ChannelTree.build([
            channel("music", "Music"),
            channel("linux", "OS/Linux"),
            channel("windows", "OS/Windows"),
            channel("random", "Random"),
            channel("macos", "OS/macOS")
        ])

        XCTAssertEqual(tree.map(\.name), ["Music", "OS", "Random"])
        XCTAssertEqual(tree[1].children.map(\.name), ["Linux", "Windows", "macOS"])
        XCTAssertEqual(tree[1].id, .group(["OS"]))
        XCTAssertNil(tree[1].channel)
        XCTAssertEqual(leaves(tree).map(\.id), ["music", "linux", "windows", "macos", "random"])
    }

    func testLeadingSlashCreatesBlankRootGroup() {
        let tree = ChannelTree.build([
            channel("null", "/dev/null"),
            channel("random", "/dev/random"),
            channel("stderr", "/dev/stderr")
        ])

        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree[0].name, "")
        XCTAssertEqual(tree[0].id, .group([""]))
        XCTAssertNil(tree[0].channel)
        let dev = tree[0].children[0]
        XCTAssertEqual(dev.name, "dev")
        XCTAssertEqual(dev.id, .group(["", "dev"]))
        XCTAssertEqual(dev.children.map(\.name), ["null", "random", "stderr"])
    }

    func testRepeatedAndTrailingSlashesRetainEveryBlankComponent() {
        let source = channel("empty", "/dev//")
        let tree = ChannelTree.build([source])
        let blankRoot = tree[0]
        let dev = blankRoot.children[0]
        let blankGroup = dev.children[0]
        let blankChannel = blankGroup.children[0]

        XCTAssertEqual(blankRoot.id, .group([""]))
        XCTAssertEqual(dev.id, .group(["", "dev"]))
        XCTAssertEqual(blankGroup.id, .group(["", "dev", ""]))
        XCTAssertEqual(blankGroup.name, "")
        XCTAssertEqual(blankChannel.name, "")
        XCTAssertEqual(blankChannel.channel, source)
        XCTAssertTrue(blankChannel.children.isEmpty)
    }

    func testEmptyNameIsStillASelectableChannel() {
        let source = channel("blank", "")
        let tree = ChannelTree.build([source])

        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree[0].name, "")
        XCTAssertEqual(tree[0].id, .channel("blank"))
        XCTAssertEqual(tree[0].channel, source)
    }

    func testChannelAndGroupWithSameNameRemainSeparateRows() {
        let linux = channel("linux", "OS/Linux")
        let tree = ChannelTree.build([linux, channel("arch", "OS/Linux/Arch"), channel("debian", "OS/Linux/Debian")])
        let children = tree[0].children

        XCTAssertEqual(children.map(\.name), ["Linux", "Linux"])
        XCTAssertEqual(children[0].id, .channel("linux"))
        XCTAssertEqual(children[0].channel, linux)
        XCTAssertTrue(children[0].children.isEmpty)
        XCTAssertEqual(children[1].id, .group(["OS", "Linux"]))
        XCTAssertNil(children[1].channel)
        XCTAssertEqual(children[1].children.map(\.name), ["Arch", "Debian"])
    }

    func testChannelsWithDuplicateNamesKeepDistinctIdentities() {
        let first = channel("first", "times/alice")
        let second = channel("second", "times/alice")
        let children = ChannelTree.build([first, second])[0].children

        XCTAssertEqual(children.map(\.name), ["alice", "alice"])
        XCTAssertEqual(children.map(\.id), [.channel("first"), .channel("second")])
        XCTAssertEqual(children.compactMap(\.channel), [first, second])
    }

    func testGroupIdentitiesUseFullPathAndStayStableAfterFilteringAndReordering() {
        let first = channel("first", "/dev/stdout")
        let second = channel("second", "OS/dev/stdout")
        let third = channel("third", "/dev/stderr")
        let allNodes = descendants(ChannelTree.build([first, second, third]))
        let reorderedNodes = descendants(ChannelTree.build([third, second, first]))
        let filteredNodes = descendants(ChannelTree.build([first]))

        XCTAssertEqual(Set(allNodes.map(\.id)), Set(reorderedNodes.map(\.id)))
        XCTAssertEqual(Set(filteredNodes.map(\.id)), [.group([""]), .group(["", "dev"]), .channel("first")])
        XCTAssertTrue(Set(filteredNodes.map(\.id)).isSubset(of: Set(allNodes.map(\.id))))
        XCTAssertEqual(allNodes.filter { $0.name == "dev" }.map(\.id), [.group(["", "dev"]), .group(["OS", "dev"])])
    }

    func testLeafPreservesMembershipAndFullChannelData() {
        let source = Channel(id: "channel", channelName: "private/team", kind: "private_channel", archived: true,
                             description: "Team chat", latestMessageID: 42, latestMessagePublishedAt: Date(timeIntervalSince1970: 123),
                             messagesCount: 55, membership: MembershipDetails(id: "member", unreadCount: 7, muted: true))
        let leaf = ChannelTree.build([source])[0].children[0]

        XCTAssertEqual(leaf.name, "team")
        XCTAssertEqual(leaf.channel, source)
        XCTAssertEqual(leaf.channel?.name, "private/team")
        XCTAssertEqual(leaf.channel?.unreadCount, 7)
    }

    func testDirectMessageNamesAreNotSplit() {
        let source = Channel(id: "dm", channelName: "alice/bob", kind: "direct_message")
        let tree = ChannelTree.build([source])

        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree[0].name, "alice/bob")
        XCTAssertEqual(tree[0].channel, source)
        XCTAssertTrue(tree[0].children.isEmpty)
    }

    private func channel(_ id: String, _ name: String) -> Channel {
        Channel(id: id, channelName: name)
    }

    private func descendants(_ nodes: [ChannelTreeNode]) -> [ChannelTreeNode] {
        nodes.flatMap { [$0] + descendants($0.children) }
    }

    private func leaves(_ nodes: [ChannelTreeNode]) -> [Channel] {
        descendants(nodes).compactMap(\.channel)
    }
}
