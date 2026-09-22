import KokoroCore
import SwiftUI

struct ChannelSidebarSection: View {
    let title: String
    let channels: [Channel]
    let icon: String

    @EnvironmentObject private var store: ChatStore
    @State private var collapsedGroups: Set<ChannelTreeNode.ID> = []
    @State private var filteredCollapsedGroups: Set<ChannelTreeNode.ID> = []

    private var isFiltering: Bool { !store.channelSearch.isEmpty || store.unreadOnly }

    var body: some View {
        Group {
            if !channels.isEmpty {
                Section {
                    ChannelTreeRows(
                        nodes: ChannelTree.build(channels),
                        icon: icon,
                        collapsedGroups: isFiltering ? $filteredCollapsedGroups : $collapsedGroups
                    )
                } header: {
                    HStack {
                        Text(title)
                        Spacer()
                        Text("\(channels.count)")
                    }
                }
            }
        }
        .onChange(of: store.channelSearch) { _, _ in filteredCollapsedGroups.removeAll() }
        .onChange(of: store.unreadOnly) { _, _ in filteredCollapsedGroups.removeAll() }
        .onChange(of: store.selectedChannelID, initial: true) { _, _ in revealSelectedChannel() }
    }

    private func revealSelectedChannel() {
        guard let channel = channels.first(where: { $0.id == store.selectedChannelID }),
              !channel.isDirectMessage else { return }
        let components = channel.name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for depth in 1..<components.count {
            let id = ChannelTreeNode.ID.group(Array(components.prefix(depth)))
            collapsedGroups.remove(id)
            filteredCollapsedGroups.remove(id)
        }
    }
}

private struct ChannelTreeRows: View {
    let nodes: [ChannelTreeNode]
    let icon: String
    @Binding var collapsedGroups: Set<ChannelTreeNode.ID>

    var body: some View {
        ForEach(nodes) { node in
            if let channel = node.channel {
                HStack(spacing: 9) {
                    Image(systemName: icon)
                        .font(.system(size: channel.isDirectMessage ? 12 : 13, weight: .medium))
                        .frame(width: 16)
                    Text(node.name)
                        .font(.system(size: 12, weight: channel.unreadCount > 0 ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if channel.unreadCount > 0 { ChannelUnreadBadge(count: channel.unreadCount) }
                }
                .padding(.vertical, 4)
                .tag(channel.id)
                .help(channel.name)
                .accessibilityLabel(channel.name + unreadDescription(channel.unreadCount))
            } else {
                DisclosureGroup(isExpanded: expansion(for: node.id)) {
                    ChannelTreeRows(nodes: node.children, icon: icon, collapsedGroups: $collapsedGroups)
                } label: {
                    let unread = unreadCount(in: node)
                    HStack {
                        // Keep empty path components visually blank, including a leading slash.
                        Text(node.name)
                            .font(.system(size: 12, weight: unread > 0 ? .semibold : .regular))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if unread > 0 { ChannelUnreadBadge(count: unread) }
                    }
                    .frame(minHeight: 16)
                    .padding(.vertical, 4)
                    .accessibilityLabel((node.name.isEmpty ? "名前のないグループ" : node.name) + unreadDescription(unread))
                }
            }
        }
    }

    private func expansion(for id: ChannelTreeNode.ID) -> Binding<Bool> {
        Binding(
            get: { !collapsedGroups.contains(id) },
            set: { expanded in
                if expanded { collapsedGroups.remove(id) }
                else { collapsedGroups.insert(id) }
            }
        )
    }

    private func unreadCount(in node: ChannelTreeNode) -> Int {
        node.channel?.unreadCount ?? node.children.reduce(0) { $0 + unreadCount(in: $1) }
    }

    private func unreadDescription(_ count: Int) -> String {
        count > 0 ? "、未読\(count)件" : ""
    }
}

private struct ChannelUnreadBadge: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : String(count))
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}
