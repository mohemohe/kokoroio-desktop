import Foundation

public struct ChannelTreeNode: Identifiable, Hashable, Sendable {
    public enum ID: Hashable, Sendable {
        case group([String])
        case channel(String)
    }

    public let id: ID
    public let name: String
    public let channel: Channel?
    public let children: [ChannelTreeNode]
}

public enum ChannelTree {
    /// Groups slash-separated names without changing the original channel data.
    /// Empty components remain blank rows, including the group before a leading slash.
    /// Siblings retain their first appearance in the supplied channel order.
    public static func build(_ channels: [Channel]) -> [ChannelTreeNode] {
        let root = Group(name: "")
        for channel in channels {
            let components = channel.isDirectMessage ? [channel.name] : channel.name.components(separatedBy: "/")
            var parent = root
            for name in components.dropLast() {
                parent = parent.group(named: name)
            }
            parent.entries.append(.channel(channel, name: components.last ?? ""))
        }
        return root.nodes(path: [])
    }

    private final class Group {
        enum Entry {
            case group(Group)
            case channel(Channel, name: String)
        }

        let name: String
        var entries: [Entry] = []
        private var groups: [String: Group] = [:]

        init(name: String) {
            self.name = name
        }

        func group(named name: String) -> Group {
            if let existing = groups[name] { return existing }
            let group = Group(name: name)
            groups[name] = group
            entries.append(.group(group))
            return group
        }

        func nodes(path: [String]) -> [ChannelTreeNode] {
            entries.map { entry in
                switch entry {
                case .group(let group):
                    let groupPath = path + [group.name]
                    return ChannelTreeNode(id: .group(groupPath), name: group.name, channel: nil, children: group.nodes(path: groupPath))
                case .channel(let channel, let name):
                    return ChannelTreeNode(id: .channel(channel.id), name: name, channel: channel, children: [])
                }
            }
        }
    }
}
