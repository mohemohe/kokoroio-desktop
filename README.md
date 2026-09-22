# Kokoro Desktop

[kokoro.io](https://kokoro.io) 用の SwiftUI 製 macOS クライアントです。左にチャンネル一覧、右にチャットタイムラインと入力欄を置いた、Slack 風の 2 ペイン構成です。

## 必要環境

- macOS 14 以降
- Xcode 16 以降（Swift 6 ツールチェーン。ソースは Swift 5 言語モード）
- 接続先の kokoro.io アカウントとアクセストークン

外部ライブラリのダウンロードは不要です。API モデル・HTTP 通信・Action Cable 接続をローカル Swift Package の `KokoroCore` に分離しています。

## ビルド・起動

リポジトリのルートで実行します。

```sh
./scripts/build-app.sh --run
```

生成先は `.build/xcode/Build/Products/Debug/KokoroDesktop.app` です。開発用の ad-hoc 署名でローカル起動できます。

Xcode からは `KokoroDesktop.xcodeproj` を開き、プロジェクト側の **KokoroDesktop** scheme と **My Mac** を選択して Run してください。コマンドを直接実行する場合は次のとおりです。

```sh
xcodebuild \
  -project KokoroDesktop.xcodeproj \
  -scheme KokoroDesktop \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/xcode \
  build
open .build/xcode/Build/Products/Debug/KokoroDesktop.app
```

Release ビルドは `CONFIGURATION=Release ./scripts/build-app.sh` で作成できます。GitHub Actions での Developer ID 署名・公証・配布手順は [リリース手順](docs/releasing.md) を参照してください。

システム通知には正規のアプリバンドルが必要なため、起動には上記の `.app` を使用します。

## GitHub Actions

- **Build and Test**: ブランチへの push、PR、手動実行でテストと Universal（Apple Silicon / Intel）ビルドを実行し、開発用の ZIP・DMG を artifact に保存します。署名用 Secrets は不要です。
- **Release**: `v1.2.3` などのタグを push すると、テスト、Developer ID 署名、Apple 公証、ZIP・DMG 作成を行い、GitHub Release の下書きに添付します。既存タグを指定した手動実行にも対応します。

最初に `awayuki-desktop` と同じ名前の署名用 Secrets 7 個を設定してください。設定内容・タグの形式・公開方法は [docs/releasing.md](docs/releasing.md) に記載しています。

## 接続

1. ブラウザで接続先の `/access_tokens`（例: `https://kokoro.io/access_tokens`）を開き、ユーザーのアクセストークンを作成します。
2. アプリのサインイン画面でサーバー URL とトークンを入力します。
3. システム通知を使う場合はアプリの通知設定から許可してください。macOS 側の「システム設定 → 通知 → Kokoro Desktop」でも変更できます。

認証情報は macOS の Keychain に保存され、次回起動時に復元されます。サインアウトすると保存した認証情報を削除します。HTTPS 接続が基本です。ローカル開発用に `http://localhost`、`http://127.0.0.1`、`http://[::1]` も受け付けます。App Sandbox の送信ネットワーク権限を有効にし、ATS の例外をローカルネットワークに限定しています。

開発用ad-hoc署名で再ビルドすると、KeychainへのアクセスにmacOS側の確認が必要になる場合があります。自動復元できない場合はログイン画面で案内します。配布時には安定したDeveloper ID署名を使用してください。

## 対応機能

- チャンネル一覧、チャンネル検索、未読件数と未読絞り込み
- `/` 区切りのチャンネル名を折りたたみ可能なツリーで表示（先頭の `/` は空欄の親階層）
- チャット表示、過去のメッセージ読み込み、メッセージ投稿
- 添付画像・解決済み画像の固定サイズサムネイル（180×140、横スクロール）と、URLのタイトル・説明・プレビュー画像
- チャンネルごとの入力中の下書き保持
- Action Cable による新着・更新の反映、切断時の再接続
- 表示中のチャンネルの既読反映
- macOS のシステム通知、通知からのチャンネル移動、通知音の設定

通知はアプリが起動し、サーバーと接続している間に受信した新着メッセージが対象です。自分の投稿や、アクティブなアプリで末尾を読んでいるチャンネルの投稿は通知しません。チャンネルの通知設定も考慮します。アプリ終了中のプッシュ通知には対応していません。

この版はチャンネル閲覧・チャット・通知に範囲を絞っています。ファイルアップロード、メッセージ編集・削除、チャンネル管理、複数アカウントの同時利用は未対応です。

メディア表示にはAPIの`embed_contents`を使用します。アップロード画像のURLを返さない旧サーバーでは、既存の認証済みWebSocket接続からWeb版のHotwire復帰処理（`ChatChannel#resume`）を呼び出し、URLが不足する投稿の添付画像を暫定的に補完します。HTMLは実行せず、チャンネル・投稿IDを照合して添付画像のURLだけを抽出します。APIがURLを返す場合は補完通信を行いません。Web版の復帰処理に対応しないサーバー、削除済みの画像などは「画像を読み込めません」と表示されます。補完通信が15秒で完了しない場合、その接続では再試行を止め、次の再接続時に再試行します。URLカードはサーバーが返す解決結果を表示し、`message_updated`による後からの解決結果も反映します。サムネイルやカードをクリックすると元の画像・ページを開きます。

## テスト

```sh
swift test
```

`KokoroCoreTests` では API リクエスト、JSON モデル、リアルタイムイベント処理などを検証します。実サーバーへの接続や macOS の通知配信は、アプリを起動して別途確認してください。

ローカルで実際のHTTP/WebSocket通信を試すためのfixtureも付属しています（Python 3、追加依存なし）。

```sh
python3 scripts/mock-server.py
```

サーバーURL `http://127.0.0.1:8765`、公開テスト用トークン `test-token` で接続できます。公開・非公開・DMと125件の履歴を用意しています。このサーバーはメモリ上のサンプルデータだけを使用します。

`python3 scripts/mock-server.py --channel-tree` で、`OS/Linux` と `OS/Linux/Ubuntu`、`/dev/null` などの階層表示を確認するサンプルも追加できます。公開・非公開チャンネルは階層化し、DMの名前はそのまま表示します。検索・未読絞り込み中は該当チャンネルの階層を展開し、解除すると通常表示の開閉状態に戻ります。

`python3 scripts/mock-server.py --legacy-images` は、画像URLのない旧APIとHotwire差分による補完を再現します。単一画像・複数画像・センシティブ画像・API解決済み画像・過去ログの画像を用意し、画像取得を含むHTTP/WebSocket通信をローカルで確認できます。

```sh
# 別ユーザーからの新着を発生させる
curl -X POST -H 'X-Access-Token: test-token' \
  -H 'Content-Type: application/json' \
  -d '{"channel_id":"CHAN00002","content":"通知のテスト"}' \
  http://127.0.0.1:8765/test/publish
# 接続を切り、自動再接続を確認する
curl -X POST -H 'X-Access-Token: test-token' http://127.0.0.1:8765/test/disconnect
```

2026-09-22にXcode 27でDebugビルドと32件の自動テストが成功しました。macOSアプリと上記fixtureで、接続、投稿、下書き復元、履歴読み込み、既読更新、新着受信、自動再接続を確認しています。通知はmacOSの配信ログで成功を確認していますが、画面共有による表示抑制があり、バナーの目視と通知クリックの実操作は未確認です。本番kokoro.ioへのアカウント接続は未検証です。

サーバーのREST APIは既読位置を更新しても`unread_count`をリセットしないため、既読位置以降の他者の投稿を取得して表示件数を再計算します。再接続時はRESTで確認済みの末尾まで履歴を補完し、既に読み込んだ過去ログを保持します。

## 構成

```text
Sources/KokoroCore/        API、データモデル、リアルタイム通信
Sources/KokoroDesktop/     SwiftUI 画面、状態管理、Keychain、通知
Tests/KokoroCoreTests/     通信・モデル・イベントのテスト
KokoroDesktop.xcodeproj/   macOS アプリのプロジェクトと共有 scheme
Resources/                Info.plist、entitlements、独自アイコン
scripts/                  ビルド・アイコン生成
```

API は `supermomonga/kokoro-io` のサーバー実装を参照しています。アプリアイコンはこのクライアント用の独自図案です。再生成はリポジトリのルートで次を実行してください。

```sh
swift scripts/generate-icon.swift
iconutil -c icns Resources/KokoroDesktop.iconset -o Resources/KokoroDesktop.icns
```
