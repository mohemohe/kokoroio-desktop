import AppKit
import KokoroCore
import SwiftUI

struct ComposerView: View {
    @EnvironmentObject private var store: ChatStore
    @State private var editorHeight: CGFloat = ChatTextEditor.minimumHeight
    @State private var emojiPickerRequest = 0

    private let characterLimit = 4_000

    private var characterCount: Int { store.draft.unicodeScalars.count }

    private var canSend: Bool {
        !store.isSending && !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && characterCount <= characterLimit && store.selectedChannelID != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
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
