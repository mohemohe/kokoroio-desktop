# Windows 版

Windows 版は Swift と WinUI 3 のネイティブアプリです。
アプリアイコンは macOS 版と共通の `Resources/KokoroDesktop.iconset` を使用します。
`build-windows.ps1` が 16 / 32 / 64 / 128 / 256 px の画像から ICO を生成し、Windows SDK の
リソースコンパイラーで EXE に埋め込むため、エクスプローラーやショートカットにも同じアイコンが表示されます。
メイン画面・設定画面も EXE 内のアイコンを `AppWindow.SetIcon` で設定するため、タイトルバーに同じアイコンが表示されます。
メイン画面・設定画面のタイトルバーは Windows の「個人用設定 → 色 → 既定のアプリ モード」のライト／ダークに追従します。
Windows App SDK 1.7 の `AppWindowTitleBar.PreferredTheme = UseDefaultAppMode` を使い、色の選択と設定変更への追従は OS に任せています。
[thebrowsercompany/swift-winrt](https://github.com/thebrowsercompany/swift-winrt) で
Windows SDK / Windows App SDK のメタデータから Swift バインディングを生成します。
アーカイブ済みの `swift-winui` パッケージには依存しません。

## 配布版の起動

GitHub Releases の `KokoroDesktop-<version>-windows-x64.zip` をダウンロードし、すべてのファイルを同じフォルダーへ展開して `KokoroDesktop.exe` を起動します。
Windows App Runtime 1.7 x64 が必要です。Swift と Visual Studio は不要です。
ZIP 内の `README.md` にランタイムのインストール先、`version.json` にバージョンとビルド番号を記載しています。
Windows 版は未署名です。SmartScreen が発行元を確認できない旨を表示する場合があります。

## 開発に必要な環境

- Windows 10 1809 以降 / Windows 11、x64
- Swift for Windows 6.4
- Visual Studio 2022 の「C++ によるデスクトップ開発」と Windows SDK
- PowerShell 7（`pwsh`）
- 実行時: [Windows App Runtime 1.7 x64](https://aka.ms/windowsappsdk/1.7/1.7.250909003/windowsappruntimeinstall-x64.exe)

生成器は NuGet の `TheBrowserCompany.SwiftWinRT 0.6.0`、
Windows App SDK は `1.7.250909003` に固定しています。
バージョンと生成対象は `Windows/projections.json` にあります。
Windows App SDK 1.7 は旧バージョンです。新しい SDK への更新は、生成器との互換性を確認してから行ってください。

## ビルドと起動

リポジトリ直下の PowerShell 7 で実行します。初回は NuGet から生成器とメタデータを取得します。

```powershell
./scripts/build-windows.ps1 -Test -Run
```

`build/windows/debug/KokoroDesktop.exe` が生成されます。
Visual Studio の開発環境とユーザーインストールの Swift はスクリプトが検出します。
生成済みのバインディングを再利用する場合は `-SkipGenerate` を付けてください。

```powershell
./scripts/build-windows.ps1 -Configuration release -Test
```

起動中のアプリとは別の出力先に更新版を作る場合は `-OutputName preview` を指定します。
この場合の出力先は `build/windows/preview` です。`-OutputName` を省略した場合は
`debug` または `release` が出力先になります。

```powershell
./scripts/build-windows.ps1 -OutputName preview -Test
./scripts/test-windows-smoke.ps1 -OutputName preview -Python 'C:/path/to/python.exe'
```

配布用 ZIP は次のスクリプトで生成・検証します。

```powershell
./scripts/package-windows.ps1 -Version 0.1.0 -BuildNumber 1
./scripts/test-windows-package.ps1 -Version 0.1.0
```

生成先は `build/windows/packages/0.1.0` です。Swift / Visual C++ ランタイム、生成した WinRT DLL、
リソース、ライセンス、起動手順、バージョン情報を含み、PDB とテスト用実行ファイルは除外します。
`-OutputName preview` を渡すと `build/windows/preview` を梱包します。EXE 単体では動きません。

GitHub Actions の通常 CI とタグによる Release は共通の `windows-build.yml` を使い、
`windows-2022` で Swift 6.4、MSVC x64、生成バインディング、自動テスト、Release ビルド、梱包・検証を実行します。
配布の手順は [リリース手順](releasing.md) を参照してください。

## 画面と操作

画面構成の基準は macOS 版の SwiftUI 実装です。対応するソース、配置、表示条件と検証項目は
[Windows UI と macOS UI の対応表](windows-ui-parity.md) にまとめています。
Windows のコントロール、フォント、同義のアイコンを使用し、OS 名や資格情報の保存先は Windows に合わせています。

| 場所 | 構成と操作 |
| --- | --- |
| ログイン | サーバー URL、アクセストークン、ブラウザでのトークン発行、接続ボタン。接続情報は Windows 資格情報マネージャーに保存し、次回起動時に復元 |
| サイドバー上部 | チャンネル名検索と検索クリア、未読メッセージの切り替えと未読総数 |
| チャンネル一覧 | 「ピン留め」「チャンネル」「プライベート」「ダイレクトメッセージ」の順に件数付きで表示。ピン留めセクションは空でも表示し、他の空セクションは非表示。スラッシュ区切りの階層を開閉可能 |
| ピン留め | チャンネル行内のピンアイコンから操作。ホバー中またはピン留め済みの行に表示。サーバー・アカウントごとに保存し、同じチャンネルが複数のセクションにあっても選択表示は一つ |
| サイドバー下部 | 接続状態のドットと表示、その下にアバター、表示名、アカウント名、設定アイコン |
| ヘッダー | 左側にチャンネルの種類・名前・説明、右側に検索と更新。検索中はヘッダー内の検索欄に切り替わり、更新アイコンが検索を閉じるアイコンに変化。検索語は 2 文字以上 |
| タイムライン | アバター・表示名・時刻・本文と日付区切り。同じ送信者による同じ日の 5 分未満の連続投稿はまとめて表示。以前のメッセージの読み込みはスクロール領域の最上部にあり、取得後も読んでいた位置を維持 |
| 最新へ移動 | 通常の履歴を読んでいて最下部から離れたときに「最新のメッセージ」をタイムライン下中央に重ねて表示 |
| 投稿欄 | 一つのカード内に画像プレビュー、入力欄、画像・絵文字・送信アイコン。カード外の下にキー操作のヒント。チャンネルごとに下書きを保持し、文字数カウンターは表示しない |
| 設定 | 「通知」「接続」の順。システム通知の切り替え、通知対象、通知音、OS の通知許可状態、サーバー・アカウント、ログアウト |

投稿欄では Enter で送信、Shift + Enter で改行します。日本語 IME の変換中と変換確定直後の Enter を
送信として扱わない判定を入れています。送信上限は 4,000 文字です。

投稿時刻は Windows のタイムゾーン設定に従って24時間表記で表示します。日付区切りと連続投稿の
グループ化も同じローカル日付を使います。日本語 Windows では Swift の `TimeZone.current` が
GMT になる場合があるため、Windows API で投稿日時ごとの時差を取得し、夏時間も反映します。

絵文字ボタンは、macOS の文字パレットに対応する Windows の OS 絵文字パネルを開きます。
入力欄にフォーカスを戻してカーソル位置へ挿入します。Windows + . でも開けます。
独自の絵文字一覧は使用しません。

通知は設定画面で変更します。通知対象は「メンションとダイレクトメッセージ」または
「全てのメッセージ」で、通知を無効にすると対象と通知音の操作も無効になります。
自分の投稿、ミュートしたチャンネル、アクティブなアプリで末尾を読んでいる会話は通知しません。
通知から対象チャンネルへ移動できます。アプリの起動中に動作し、終了中のプッシュ通知には対応しません。

Action Cable による新着・更新・再接続と定期的な REST 同期を行い、
アクティブなウィンドウで末尾を表示しているチャンネルの既読位置を更新します。
接続先には macOS 版と同じ HTTPS / localhost HTTP の制約を適用します。

## 本文と画像の表示

本文はネイティブの書式付きテキストとして表示し、選択・コピーできます。
`swift-markdown` の解析結果から、見出し、太字・斜体・取り消し線、引用、リスト、
チェックリスト、インラインコード・コードブロック、表、リンクを描画します。
チャンネル・ユーザー参照と絵文字ショートコードも表示に反映します。
メッセージのコンテキストメニューから本文全体をコピーできます。

Markdown 内の画像記法はリンクとして表示し、画像プレビューはメディア表示にまとめます。
サムネイルをクリックするとブラウザで元画像を開きます。embed はサーバーが返す
タイトル・説明・画像をネイティブのカードで表示し、HTML は実行しません。
画像 URL のない旧サーバーでは、認証済み WebSocket から得る Hotwire 差分を解析して添付画像を補完します。
Windows の WebSocket は OS 標準の WinHTTP を使用し、受信待ちには完了通知を使用します。
分割されたフレームは UTF-8 の文字境界に関係なく組み立ててから JSON を解析します。
受信バッファの上限は 8 MiB とし、再接続時に破棄します。
センシティブな画像・embed は「センシティブなメディアを表示」を押すまで読み込まず、
削除済みメッセージの添付画像は読み込みません。アバターを取得できない場合はイニシャルを表示します。
画像の取得には kokoro.io のアクセストークンを付けません。
アバター・添付画像・投稿欄のプレビューは縮小デコードし、アニメーションは自動再生しません。
添付画像の元ファイルは従来どおりリンクから開けます。

## 画像アップロード

ログイン後、投稿欄の画像アイコンからファイルを選択すると、接続中の kokoro.io サーバーの
`POST /api/v1/image_uploads` にアップロードします。ログイン中のアクセストークンを使い、追加の API キーは必要ありません。
添付画像は投稿欄のカード上部に並び、アップロード中はスピナー、失敗時は警告アイコンを表示します。
すべてのアップロードが完了すると、本文が空でも送信できます。本文の上限は 4,000 文字です。

送信時はアップロード応答の `signed_id` をプレビュー順の `image_signed_ids` として渡し、本文へ画像 URL を追加しません。
送信に失敗した場合は本文と添付を保持し、同じ内容での再送には同じ冪等キーを使います。
画像を外すと進行中のアップロードをキャンセルして下書きから除外します。不要な未添付画像はサーバーが自動削除します。
ログアウトやアカウント切り替えでは下書きと添付を破棄し、以前のアップロード結果を反映しません。

## ローカルの動作確認

Python 3 が使える環境で、ビルド後に次を実行します。

```powershell
./scripts/test-windows-smoke.ps1
# Python のパスを指定する場合
./scripts/test-windows-smoke.ps1 -Python 'C:/path/to/python.exe'
# チャンネルが一つもない場合
./scripts/test-windows-smoke.ps1 -EmptyChannels -Python 'C:/path/to/python.exe'
```

このスクリプトは `127.0.0.1:8765` に fixture サーバーを起動し、実際の WinUI アプリで
接続、履歴、投稿、チャンネル切り替え、下書き、再ログイン、リアルタイム接続、
ピン留め、検索、設定、履歴ボタン、Windows 通知登録を確認します。
通常の fixture は `--channel-tree --legacy-images --split-image-responses` で起動し、
複数の TCP 書き込みに分けた Hotwire 応答の復元、ローカルのアバター・画像・embed の取得、
認証情報を付けずに画像を取得すること、センシティブ／削除済み画像を自動で取得しないことも検証します。
`-EmptyChannels` では未選択の案内、投稿欄の非表示、エラー表示を確認します。
保存された認証情報を読み書きせず、公開テスト用トークン `test-token` を使用し、
終了時に自分で起動した fixture を停止します。

画面画像と実際のコントロール構造・座標を `.build/windows/ui-snapshots/` に BMP / JSON で保存します。
通常画面、ヘッダー内検索、3,600 文字の下書き、設定の通知オン・オフについては
`WindowsUIAudit` が配置・ラベル・操作状態を検証します。
画像添付のアップロード中・完了・除外後・失敗、860 × 600 の最小サイズ、
サイドバーの絞り込み、明暗テーマの設定・タイムラインも検証します。
添付の検証には通信しない専用サービスを注入し、本番へのアップロードは行いません。
通知スイッチが設定にあり、サイドバーにはないこと、設定に接続インジケーターがないこと、
長い下書きでも文字数カウンターがないことも監査対象です。
ログは `.build/windows/` に保存します。

2026-09-28 に Windows / Swift 6.4 で Debug ビルド、110 件の自動テスト、
通常・チャンネルなしの WinUI smoke test と画像リクエスト検証の成功を確認しました。
生成した画面画像も参照し、設定の選択欄やログアウトボタンが表示領域に収まることを確認しています。
ネイティブの最小サイズ制約、添付プレビュー、明暗テーマの文字色も確認済みです。
この記録は公式アップロードへの移行前の結果です。2026-10-03 の移行後の Windows ビルド・WinUI smoke は未確認です。

自動監査だけでは、OS コントロール内部の表示やすべての入力操作は検証できません。
本番サーバーへの接続、実際の公式メディアアップロード、Windows の通知バナー・クリック、
OS 絵文字パネルでの挿入、日本語 IME の変換確定と Enter / Shift + Enter の組み合わせ、
macOS 側の再ビルドは別途確認が必要です。smoke の絵文字挿入確認はアプリ内の挿入処理が対象で、
OS 全体へキーを送る検証は行いません。
詳しい UI 検証の範囲は [対応表](windows-ui-parity.md) を参照してください。

手動で確認する場合は `python scripts/mock-server.py --channel-tree --legacy-images` を起動し、
アプリから同じ URL とトークンを入力してください。

## 実装

- `Sources/KokoroCore`: macOS と共通の通信・モデル。Windows では FoundationNetworking / FoundationXML を使用。HTML の解析は FoundationXML の機能差を補うため SwiftSoup 2.13.9 を使用
- `Sources/KokoroWindowsState`: UI 非依存の状態管理と通信競合の防止
- `Sources/KokoroWindows`: WinUI の画面、Markdown 描画、通知、実行時 UI 監査と起動処理
- `Windows/Native`: App Runtime の bootstrap、Windows メッセージループ、資格情報マネージャー、画像選択、OS 絵文字パネルとウィンドウ操作
- `Windows/WebSocket`: WinHTTP の非同期 WebSocket と、送受信・キャンセルの完了待機
- `Windows/Generated`: 自動生成した各 DLL の Swift パッケージ（Git 管理対象外）

WinRT パッケージは DLL ごとに分離し、SwiftPM の product 依存でリンクします。
これにより、同じ型の重複リンクと Windows の DLL エクスポート数上限を避けます。
WinUI と Swift の非同期処理が同じ UI スレッドで動くよう、Windows メッセージループと
Foundation RunLoop の両方を処理します。
Swift 6.4 の libdispatch が公開するキュー通知イベントと Windows メッセージをまとめて待ち、
10ms ごとの定期ポーリングを避けます。Foundation の次のタイマー期限も考慮し、他の
RunLoop ソースのために待機の上限を 1 秒とします。将来のランタイムで通知イベントが
取得できない場合は従来の 10ms 待機に戻ります。

## CPU 使用率の検証

```powershell
./scripts/build-windows.ps1 -SkipGenerate -OutputName cpu-fix -Test
./scripts/test-windows-smoke.ps1 -OutputName cpu-fix -Performance -Python 'C:/path/to/python.exe'
# リアルタイム通信を除いた同じ画面との比較
./scripts/test-windows-smoke.ps1 -OutputName cpu-fix -Performance -NoRealtime -Python 'C:/path/to/python.exe'
```

ローカル fixture に接続し、安定待ち 3 秒の後、5 秒間のプロセス CPU 時間・UI スレッド CPU 時間・
メインループ回数を測ります。CPU は論理コア数で割らず、1 コアを 100% とする値です。
20% 以上の待機 CPU、5 秒間に 100 回以上のループ、Swift Task の大幅な起床遅延を失敗にします。
併せて、同じ状態の再描画、新着追加・履歴追加で既存行を保持すること、サーバー切断からの再接続、
日本語・絵文字を含む WebSocket 継続フレームの受信を検証します。

2026-09-29 の調査では、修正前の待機 CPU は約 84%、メインループは 5 秒に 323 回でした。
描画とメインループのみの修正後は 8 回まで減りましたが、CPU は約 67% 残り、
同じ画面でリアルタイム通信を無効にすると約 0.3% になりました。
この切り分けから Windows の FoundationNetworking WebSocket 経路を WinHTTP に置き換えました。
置き換え後は同じ Debug ビルド・ローカル fixture で CPU 0.0%（5 秒の計測精度内）、
UI スレッド CPU 0.0%、メインループ 6 回となり、性能の回帰検証も成功しました。
119 件の自動テスト、通常・チャンネルなしの WinUI smoke test、画像取得の検証も成功しています。
REST 通信と macOS の WebSocket 実装は従来どおりです。

タイムラインは変更された行と日付区切りだけを挿入・削除し、全行の付け直しを避けます。
見出しとサイドバーは表示に使う値が変わったときに更新します。
実環境の値はメッセージ数、画像、OS、ビルド構成で変わるため、本番サーバーでの計測とは区別してください。

待機処理の参照: [Swift libdispatch のキュー実装](https://github.com/swiftlang/swift-corelibs-libdispatch/blob/swift-6.4-RELEASE/src/queue.c)、
[WinHTTP の並行処理・キャンセル規則](https://learn.microsoft.com/en-us/windows/win32/winhttp/concurrency-in-winhttp)。
