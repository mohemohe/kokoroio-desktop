import AppKit
import KokoroCore
import SwiftUI

@main
struct KokoroDesktopApp: App {
    @AppStorage(AppTypography.defaultsKey) private var fontScalePercent = AppTypography.defaultPercent
    @StateObject private var notifications: NotificationService
    @StateObject private var store: ChatStore

    init() {
        let notifications = NotificationService()
        _notifications = StateObject(wrappedValue: notifications)
        _store = StateObject(wrappedValue: ChatStore(notifications: notifications))
    }

    var body: some Scene {
        Window("kokoro.io", id: "main") {
            Group {
                if store.isSignedIn { WorkspaceView() }
                else { SignInView() }
            }
            .environmentObject(store)
            .environmentObject(notifications)
            .scaledFont(.body)
            .environment(\.appFontScale, AppTypography.scale(for: fontScalePercent))
            .frame(minWidth: 860, minHeight: 600)
            .task { await store.restoreSession() }
        }
        .defaultSize(width: 1160, height: 780)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("再読み込み") { store.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!store.isSignedIn)
            }
        }
        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(notifications)
                .scaledFont(.body)
                .environment(\.appFontScale, AppTypography.scale(for: fontScalePercent))
        }
    }
}

private struct SignInView: View {
    @EnvironmentObject private var store: ChatStore
    @State private var token = ""
    @Environment(\.openURL) private var openURL

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("kokoro.io に接続").scaledFont(.title2, weight: .bold)
                    Text("kokoro.io のアクセストークンでログインします。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("サーバーURL").scaledFont(.callout, weight: .medium)
                        TextField("https://kokoro.io", text: $store.serverURL)
                            .textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("アクセストークン").scaledFont(.callout, weight: .medium)
                        SecureField("アクセストークンを貼り付け", text: $token)
                            .textFieldStyle(.roundedBorder).onSubmit(connect)
                        Text("ユーザーのアクセストークンを使います。トークンはMacのKeychainに保存されます。")
                            .scaledFont(.caption1).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Button {
                        if let base = ChatStore.validatedServerURL(store.serverURL) { openURL(base.appendingPathComponent("access_tokens")) }
                    } label: {
                        Label("ブラウザでトークンを発行", systemImage: "arrow.up.right.square").scaledFont(.body)
                    }.buttonStyle(.link)
                    if let error = store.signInError {
                        Label(error, systemImage: "exclamationmark.circle").scaledFont(.callout).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button(action: connect) {
                        HStack { Spacer(); if store.isSigningIn { ProgressView().controlSize(.small) }; Text(store.isSigningIn ? "接続中…" : "接続する").scaledFont(.body); Spacer() }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .tint(Color(red: 0.36, green: 0.23, blue: 0.45))
                    .disabled(store.isSigningIn || token.isEmpty)
                }
                .padding(44).frame(width: 440)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
    }

    private func connect() {
        Task { await store.signIn(server: store.serverURL, token: token); if store.isSignedIn { token = "" } }
    }
}

private struct SettingsView: View {
    @AppStorage(AppTypography.defaultsKey) private var fontScalePercent = AppTypography.defaultPercent
    @Environment(\.appFontScale) private var fontScale
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var notifications: NotificationService
    @Environment(\.openURL) private var openURL
    var body: some View {
        Form {
            Section {
                LabeledContent("フォントサイズ") {
                    ScaledPicker(title: "フォントサイズ", selection: $fontScalePercent,
                                 options: AppTypography.percentages.map { ($0, "\($0)%") })
                }
                Text("サイドバー、チャットのヘッダー、名前、本文、投稿欄などの文字サイズを変更します。")
                    .scaledFont(.caption1).foregroundStyle(.secondary)
            } header: {
                Text("表示").scaledFont(.caption1)
            }
            Section {
                Toggle("システム通知を表示", isOn: $notifications.enabled)
                LabeledContent("通知の対象") {
                    ScaledPicker(title: "通知の対象", selection: $notifications.target, options: [
                        (.mentionsAndDirectMessages, "メンションとダイレクトメッセージ"),
                        (.allMessages, "全てのメッセージ")
                    ])
                    .disabled(!notifications.enabled)
                }
                Toggle("通知音を鳴らす", isOn: $notifications.soundEnabled)
                    .disabled(!notifications.enabled)
                if notifications.isAuthorized {
                    Label("macOSの通知は許可されています", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button { Task { await notifications.requestAuthorization() } } label: {
                        Text("macOSの通知を許可する").scaledFont(.body)
                    }
                    Button { openURL(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!) } label: {
                        Text("システム設定を開く").scaledFont(.body)
                    }
                }
                Text("ミュート中のチャンネル、表示中の会話、自分の投稿は通知しません。アプリの起動中に動作します。")
                    .scaledFont(.caption1).foregroundStyle(.secondary)
                if let error = notifications.lastError { Text(error).foregroundStyle(.red) }
            } header: {
                Text("通知").scaledFont(.caption1)
            }
            Section {
                LabeledContent("サーバー", value: store.serverURL)
                if let profile = store.profile { LabeledContent("アカウント", value: "@" + profile.screenName) }
                if store.isSignedIn {
                    Button(role: .destructive) { store.signOut() } label: {
                        Text("ログアウト").scaledFont(.body)
                    }
                }
            } header: {
                Text("接続").scaledFont(.caption1)
            }
        }
        .formStyle(.grouped).padding()
        .frame(width: 480 * max(1, min(fontScale, 1.5)), height: 560 * max(1, min(fontScale, 1.25)))
        .task { await notifications.refreshAuthorizationStatus() }
    }
}

#if DEBUG
#Preview("Settings · 100%") {
    SettingsPreview(scale: 1)
}

#Preview("Settings · 200%") {
    SettingsPreview(scale: 2)
}

private struct SettingsPreview: View {
    let scale: CGFloat
    private let notifications: NotificationService
    private let store: ChatStore

    init(scale: CGFloat) {
        self.scale = scale
        let notifications = NotificationService()
        self.notifications = notifications
        self.store = ChatStore(notifications: notifications)
    }

    var body: some View {
        SettingsView()
            .environmentObject(store)
            .environmentObject(notifications)
            .scaledFont(.body)
            .environment(\.appFontScale, scale)
    }
}
#endif
