import AppKit
import KokoroCore
import SwiftUI

@main
struct KokoroDesktopApp: App {
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
        }
    }
}

private struct SignInView: View {
    @EnvironmentObject private var store: ChatStore
    @State private var token = ""
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("kokoro.io に接続").font(.title2.bold())
            Text("kokoro.io のアクセストークンでログインします。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Text("サーバーURL").font(.callout.weight(.medium))
                TextField("https://kokoro.io", text: $store.serverURL)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("アクセストークン").font(.callout.weight(.medium))
                SecureField("アクセストークンを貼り付け", text: $token)
                    .textFieldStyle(.roundedBorder).onSubmit(connect)
                Text("ユーザーのアクセストークンを使います。トークンはMacのKeychainに保存されます。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button("ブラウザでトークンを発行", systemImage: "arrow.up.right.square") {
                if let base = ChatStore.validatedServerURL(store.serverURL) { openURL(base.appendingPathComponent("access_tokens")) }
            }.buttonStyle(.link)
            if let error = store.signInError {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: connect) {
                HStack { Spacer(); if store.isSigningIn { ProgressView().controlSize(.small) }; Text(store.isSigningIn ? "接続中…" : "接続する"); Spacer() }
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .tint(Color(red: 0.36, green: 0.23, blue: 0.45))
            .disabled(store.isSigningIn || token.isEmpty)
        }
        .padding(44).frame(width: 440)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func connect() {
        Task { await store.signIn(server: store.serverURL, token: token); if store.isSignedIn { token = "" } }
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var notifications: NotificationService
    @Environment(\.openURL) private var openURL
    var body: some View {
        Form {
            Section("通知") {
                Toggle("システム通知を表示", isOn: $notifications.enabled)
                Picker("通知の対象", selection: $notifications.target) {
                    Text("メンションとダイレクトメッセージ").tag(DesktopNotificationTarget.mentionsAndDirectMessages)
                    Text("全てのメッセージ").tag(DesktopNotificationTarget.allMessages)
                }
                .disabled(!notifications.enabled)
                Toggle("通知音を鳴らす", isOn: $notifications.soundEnabled)
                    .disabled(!notifications.enabled)
                if notifications.isAuthorized {
                    Label("macOSの通知は許可されています", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("macOSの通知を許可する") { Task { await notifications.requestAuthorization() } }
                    Button("システム設定を開く") { openURL(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!) }
                }
                Text("ミュート中のチャンネル、表示中の会話、自分の投稿は通知しません。アプリの起動中に動作します。")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = notifications.lastError { Text(error).foregroundStyle(.red) }
            }
            Section("画像アップロード") {
                SecureField("ImgBB の API キー", text: Binding(
                    get: { store.imgBBAPIKey },
                    set: { store.updateImgBBAPIKey($0) }
                ))
                .textFieldStyle(.roundedBorder)
                Text("API キーは Mac の Keychain に保存されます。入力すると投稿欄から画像を追加できます。")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = store.imgBBSettingsError { Text(error).foregroundStyle(.red) }
            }
            Section("接続") {
                LabeledContent("サーバー", value: store.serverURL)
                if let profile = store.profile { LabeledContent("アカウント", value: "@" + profile.screenName) }
                if store.isSignedIn {
                    Button("ログアウト", role: .destructive) { store.signOut() }
                }
            }
        }
        .formStyle(.grouped).padding().frame(width: 480, height: 470)
        .task { await notifications.refreshAuthorizationStatus() }
    }
}
