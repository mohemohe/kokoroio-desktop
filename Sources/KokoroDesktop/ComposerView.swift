import AppKit
import KokoroCore
import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @EnvironmentObject private var store: ChatStore
    @State private var editorHeight: CGFloat = ChatTextEditor.minimumHeight
    @State private var emojiPickerRequest = 0
    @State private var isImagePickerPresented = false

    private let characterLimit = 4_000

    private var characterCount: Int { store.composedDraft.unicodeScalars.count }

    private var canSend: Bool { store.canSendDraft }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                if !store.composerImages.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(store.composerImages) { image in
                                thumbnail(for: image)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .frame(height: 82)
                    Divider()
                }
                ZStack(alignment: .topLeading) {
                    if store.draft.isEmpty {
                        Text("\(store.selectedChannel?.name ?? "チャンネル") にメッセージを送信")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 16)
                            .padding(.top, 13)
                            .allowsHitTesting(false)
                    }
                    ChatTextEditor(
                        text: $store.draft,
                        height: $editorHeight,
                        isEnabled: !store.isSending,
                        channelID: store.selectedChannelID,
                        emojiPickerRequest: emojiPickerRequest,
                        onSubmit: { if canSend { store.sendMessage() } }
                    )
                    .frame(height: editorHeight)
                    .accessibilityLabel("メッセージ")
                }

                HStack(spacing: 10) {
                    Button { isImagePickerPresented = true } label: {
                        Image(systemName: "photo")
                            .font(.system(size: 16))
                            .foregroundStyle(store.hasImgBBAPIKey ? .secondary : .tertiary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.hasImgBBAPIKey || store.isSending || store.selectedChannelID == nil)
                    .help(store.hasImgBBAPIKey ? "画像を追加" : "設定で ImgBB の API キーを入力してください")
                    .accessibilityLabel("画像を追加")
                    Button {
                        emojiPickerRequest += 1
                    } label: {
                        Image(systemName: "face.smiling")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isSending)
                    .help("絵文字を挿入")
                    .accessibilityLabel("絵文字を挿入")
                    Spacer()
                    if characterCount > characterLimit - 500 {
                        Text("\(characterCount) / \(characterLimit)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(characterCount > characterLimit ? Color.red : .secondary)
                    }
                    Button {
                        store.sendMessage()
                    } label: {
                        Group {
                            if store.isSending {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 13, weight: .bold))
                            }
                        }
                        .frame(width: 30, height: 28)
                        .foregroundStyle(canSend ? .white : .secondary)
                        .background(canSend ? KChatPalette.accent : Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help("メッセージを送信（Enter）")
                    .accessibilityLabel("メッセージを送信")
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 9)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
            }

            HStack {
                Spacer()
                Text("Enterで送信 · Shift + Enterで改行")
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .fileImporter(isPresented: $isImagePickerPresented, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                Task { @MainActor in store.addImages(urls) }
            case .failure(let error):
                Task { @MainActor in store.errorMessage = "画像を選択できませんでした: \(error.localizedDescription)" }
            }
        }
    }

    private func thumbnail(for image: ComposerImage) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let preview = image.thumbnail {
                    Image(nsImage: preview)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 76, height: 64)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                if image.isUploading || image.isDeleting {
                    ZStack {
                        Color.black.opacity(0.3)
                        ProgressView().controlSize(.small).tint(.white)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                } else if image.error != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.red, in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .draggable(image.id.uuidString)
            .dropDestination(for: String.self) { items, _ in
                guard let source = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                store.moveImage(source, to: image.id)
                return true
            }

            Button {
                store.removeImage(image.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(.black.opacity(0.7), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(store.isSending || image.isDeleting)
            .padding(3)
            .help("画像を削除")
            .accessibilityLabel("\(image.fileName) を削除")
        }
        .help(image.error ?? image.fileName)
        .accessibilityElement(children: .contain)
    }

}

private struct ChatTextEditor: NSViewRepresentable {
    // One 16-point text line plus the 11-point top and bottom insets.
    static let minimumHeight: CGFloat = 38

    @Binding var text: String
    @Binding var height: CGFloat
    var isEnabled: Bool
    var channelID: String?
    var emojiPickerRequest: Int
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let editor = ComposerTextView(frame: .zero)
        editor.delegate = context.coordinator
        editor.isRichText = false
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 13)
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.textContainerInset = NSSize(width: 11, height: 11)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.minSize = NSSize(width: 0, height: Self.minimumHeight)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.onSubmit = onSubmit
        editor.string = text
        scrollView.documentView = editor
        context.coordinator.channelID = channelID
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let editor = scrollView.documentView as? ComposerTextView else { return }
        context.coordinator.parent = self
        editor.onSubmit = onSubmit
        editor.isEditable = isEnabled
        if editor.string != text && !editor.hasMarkedText() {
            editor.string = text
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        if context.coordinator.channelID != channelID {
            context.coordinator.channelID = channelID
            editor.undoManager?.removeAllActions()
            editor.scrollToBeginningOfDocument(nil)
        }
        context.coordinator.updateHeight(editor)
        if context.coordinator.emojiPickerRequest != emojiPickerRequest {
            context.coordinator.emojiPickerRequest = emojiPickerRequest
            guard isEnabled, let window = editor.window else { return }
            let selectedRanges = editor.selectedRanges
            if window.makeFirstResponder(editor) {
                editor.selectedRanges = selectedRanges
                NSApp.orderFrontCharacterPalette(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatTextEditor
        var channelID: String?
        var emojiPickerRequest: Int

        init(_ parent: ChatTextEditor) {
            self.parent = parent
            emojiPickerRequest = parent.emojiPickerRequest
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            updateHeight(editor)
        }

        func updateHeight(_ editor: NSTextView) {
            guard let layoutManager = editor.layoutManager, let container = editor.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let newHeight = max(ChatTextEditor.minimumHeight, min(170, layoutManager.usedRect(for: container).height + 22))
            guard abs(parent.height - newHeight) > 1 else { return }
            DispatchQueue.main.async { [weak self] in self?.parent.height = newHeight }
        }
    }
}

private final class ComposerTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn && !event.modifierFlags.contains(.shift)
            && !event.modifierFlags.contains(.option) && !hasMarkedText() {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }
}
