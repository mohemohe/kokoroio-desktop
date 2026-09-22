import KokoroCore
import SwiftUI

/// Render the server's resolved metadata; remote HTML is never executed here.
struct MessageEmbedsView: View {
    let message: Message
    @State private var revealsSensitiveContent = false

    private var embeds: [EmbedContent] {
        message.embedContents.filter { message.expandEmbedContents || $0.isUploadedImage }
    }

    private var images: [EmbedImagePreview] { embeds.flatMap(\.imagePreviews) }
    private var unavailableImages: [EmbedContent] { embeds.filter(\.hasUnavailableImage) }
    private var cards: [EmbedContent] { embeds.filter { !$0.isImageOnly && !$0.isUploadedImage } }
    private var isSensitive: Bool {
        message.nsfw || embeds.contains(where: \.isRestricted) || images.contains(where: \.isRestricted)
    }

    var body: some View {
        if !message.isDeleted && !embeds.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if isSensitive && !revealsSensitiveContent {
                    Button {
                        revealsSensitiveContent = true
                    } label: {
                        Label("センシティブなメディアを表示", systemImage: "eye.slash")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                } else {
                    if !images.isEmpty || !unavailableImages.isEmpty {
                        imageStrip
                    }
                    // Position is not necessarily unique, so preserve every returned entry.
                    ForEach(Array(cards.enumerated()), id: \.offset) { _, embed in
                        EmbedLinkCard(embed: embed)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }

    private var imageStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(images.enumerated()), id: \.offset) { index, preview in
                    Link(destination: preview.linkURL) {
                        EmbedThumbnail(url: preview.thumbnailURL, width: 180, height: 140)
                            .overlay {
                                if preview.isVideo {
                                    Image(systemName: "play.circle.fill")
                                        .font(.system(size: 30))
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(preview.linkURL.absoluteString)
                    .accessibilityLabel("\(preview.isVideo ? "動画" : "画像") \(index + 1) / \(images.count)")
                }
                ForEach(Array(unavailableImages.enumerated()), id: \.offset) { _, _ in
                    EmbedThumbnail(url: nil, width: 180, height: 140)
                        .accessibilityLabel("画像を読み込めません")
                }
            }
            .padding(.bottom, 10)
        }
        .scrollIndicators(.visible)
        .frame(height: 154)
        .accessibilityLabel("添付画像")
    }
}

private struct EmbedLinkCard: View {
    let embed: EmbedContent

    var body: some View {
        Group {
            if let url = embed.linkURL {
                Link(destination: url) { content }
                    .buttonStyle(.plain)
                    .help(url.absoluteString)
            } else {
                content
            }
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 12) {
            if let url = embed.cardThumbnailURL {
                EmbedThumbnail(url: url, width: 120, height: 90)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: embed.cardTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let description = embed.cardDescription, !description.isEmpty {
                    Text(verbatim: description)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if let host = embed.linkURL?.host {
                    Text(verbatim: host)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

private struct EmbedThumbnail: View {
    let url: URL?
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        ZStack {
            Color.primary.opacity(0.045)
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else if phase.error != nil || url == nil {
                    VStack(spacing: 6) {
                        Image(systemName: "photo")
                            .font(.system(size: 22))
                        Text("画像を読み込めません")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.08)))
    }
}
