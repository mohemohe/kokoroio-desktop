import KokoroCore
import SwiftUI

enum SidebarChannelID: Hashable {
    case channel(String)
    case pinned(String)

    var channelID: String {
        switch self {
        case .channel(let id), .pinned(let id): id
        }
    }
}

struct PinnedChannelSidebarSection: View {
    @EnvironmentObject private var store: ChatStore

    var body: some View {
        ChannelSidebarSection(
            title: "ピン留め",
            channels: store.filteredPinnedChannels,
            isPinnedSection: true,
            emptyMessage: "ピン留めされたチャンネルはありません"
        )
    }
}

struct ChannelSidebarSection: View {
    let title: String
    let channels: [Channel]
    var icon: String? = nil
    var isPinnedSection = false
    var emptyMessage: String? = nil

    @EnvironmentObject private var store: ChatStore
    @State private var collapsedGroups: Set<ChannelTreeNode.ID> = []
    @State private var filteredCollapsedGroups: Set<ChannelTreeNode.ID> = []

    private var isFiltering: Bool { !store.channelSearch.isEmpty || store.unreadOnly }

    var body: some View {
        Group {
            if !channels.isEmpty || emptyMessage != nil {
                Section {
                    if channels.isEmpty, let emptyMessage {
                        Text(emptyMessage)
                            .scaledFont(size: 11)
                            .foregroundStyle(.secondary)
                    }
                    ChannelTreeRows(
                        nodes: ChannelTree.build(channels),
                        icon: icon,
                        isPinnedSection: isPinnedSection,
                        collapsedGroups: isFiltering ? $filteredCollapsedGroups : $collapsedGroups
                    )
                } header: {
                    HStack {
                        Text(title)
                        Spacer()
                        Text("\(channels.count)")
                    }
                    .scaledFont(.caption1)
                }
            }
        }
        .onChange(of: store.channelSearch) { _, _ in filteredCollapsedGroups.removeAll() }
        .onChange(of: store.unreadOnly) { _, _ in filteredCollapsedGroups.removeAll() }
        .onChange(of: store.selectedChannelID, initial: true) { _, _ in revealSelectedChannel() }
        .onChange(of: channels.map(\.id)) { _, _ in revealSelectedChannel() }
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
    let icon: String?
    let isPinnedSection: Bool
    @Binding var collapsedGroups: Set<ChannelTreeNode.ID>

    var body: some View {
        ForEach(nodes) { node in
            if let channel = node.channel {
                let rowID = isPinnedSection ? SidebarChannelID.pinned(channel.id) : .channel(channel.id)
                ChannelSidebarRow(channel: channel, name: node.name, icon: icon ?? channelIcon(channel))
                    .tag(rowID)
                    .id(rowID)
            } else {
                DisclosureGroup(isExpanded: expansion(for: node.id)) {
                    ChannelTreeRows(
                        nodes: node.children,
                        icon: icon,
                        isPinnedSection: isPinnedSection,
                        collapsedGroups: $collapsedGroups
                    )
                } label: {
                    let unread = unreadCount(in: node)
                    HStack {
                        // Keep empty path components visually blank, including a leading slash.
                        Text(node.name)
                            .scaledFont(size: 12, weight: unread > 0 ? .semibold : .regular)
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

    private func channelIcon(_ channel: Channel) -> String {
        channel.isDirectMessage ? "bubble.left" :
            channel.kind.lowercased().contains("private") ? "lock.fill" : "number"
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

private struct ChannelSidebarRow: View {
    let channel: Channel
    let name: String
    let icon: String

    @EnvironmentObject private var store: ChatStore
    @State private var isHovered = false

    private var isPinned: Bool { store.isChannelPinned(channel.id) }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: channel.isDirectMessage ? 12 : 13, weight: .medium))
                .frame(width: 16)
            Text(name)
                .scaledFont(size: 12, weight: channel.unreadCount > 0 ? .semibold : .regular)
                .lineLimit(1)
            Spacer(minLength: 4)
            if channel.unreadCount > 0 { ChannelUnreadBadge(count: channel.unreadCount) }
            Button {
                store.toggleChannelPin(channel.id)
            } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 12))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(isPinned ? "ピン留めを解除" : "ピン留め")
            .accessibilityLabel(channel.name + (isPinned ? "のピン留めを解除" : "をピン留め"))
            .opacity(isHovered || isPinned ? 1 : 0)
            .allowsHitTesting(isHovered || isPinned)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(channel.name)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(channel.name + (channel.unreadCount > 0 ? "、未読\(channel.unreadCount)件" : ""))
        .accessibilityAction(named: Text(isPinned ? "ピン留めを解除" : "ピン留め")) {
            store.toggleChannelPin(channel.id)
        }
    }
}

private struct ChannelUnreadBadge: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : String(count))
            .scaledFont(size: 10, weight: .bold, design: .rounded)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}
