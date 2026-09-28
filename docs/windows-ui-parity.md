# Windows UI と macOS UI の対応表

この表は macOS の実装を Windows UI の基準として読み取ったものです。検証基準を記載しており、表の存在だけでは動作確認済みを意味しません。変更後のソース、実行中のコントロール構造、画面画像を合わせて確認します。

基準となるソース:

- [KokoroDesktopApp.swift](../Sources/KokoroDesktop/KokoroDesktopApp.swift): メインウィンドウ、ログイン、設定フォーム
- [WorkspaceView.swift](../Sources/KokoroDesktop/WorkspaceView.swift): サイドバー、ヘッダー、タイムライン、検索、空状態
- [ChannelSidebarSection.swift](../Sources/KokoroDesktop/ChannelSidebarSection.swift): セクション、階層、未読数、ピン留め操作
- [ComposerView.swift](../Sources/KokoroDesktop/ComposerView.swift): 入力欄、画像プレビュー、操作ボタン、キーボード操作
- [MessageRow.swift](../Sources/KokoroDesktop/MessageRow.swift) / [MessageEmbedsView.swift](../Sources/KokoroDesktop/MessageEmbedsView.swift): メッセージとメディア

**ユーザーの明示指示を優先する点:** macOS の現在の `ComposerView` には 3,500 文字を超えた場合だけカウンターを表示するコードがありますが、Windows には文字数カウンターを表示しません。通常の下書きだけでなく、3,600 文字の下書きでも非表示を確認します。4,000 文字の送信上限そのものは維持します。

## 画面構成

| 対象 | macOS に基づく要件 | Windows の確認箇所 | 必要な検証 |
| --- | --- | --- | --- |
| ウィンドウ | 初期サイズ 1160 × 780、最小 860 × 600。タイトル `kokoro.io` | `WorkspaceWindow.show` | 起動画像と実際のサイズ |
| ログイン | 接続見出し、説明、サーバー URL、トークン、保管先の説明、ブラウザで発行、接続ボタンの順。保存チェックボックスを追加しない | `WorkspaceWindow.buildLogin` | `login.bmp`、空トークン時の無効化 |
| サイドバー幅 | 初期 246、最小 220、最大 310。境界をドラッグして変更できる | `WorkspaceWindow.buildWorkspace` | 初期画像と最小・最大幅での表示 |
| サイドバー上部 | アプリ名の大見出しを置かず、チャンネル検索から開始。検索の外側余白は左右 14、上 10。検索クリアは入力中のみ | `WindowsSidebarView` | 通常・検索中の画面 |
| 未読行 | トレイアイコン、`未読メッセージ`、未読総数。チェックボックスの `未読のみ` という別構成にしない | `WindowsSidebarView` | 構造監査、未読フィルターの切り替え |
| セクション | 順序は `ピン留め` → `チャンネル` → `プライベート` → `ダイレクトメッセージ`。ピン留めは空でも見せる。他の空セクションは隠す。各見出し右に件数 | `WindowsSidebarView`、`WindowsChatStore.channelSections` | 空・通常・フィルター結果、件数の確認 |
| チャンネル行 | 階層の開閉、種類アイコン、未読バッジ。ピン操作は行内にあり、ホバー中またはピン済みで見える。ヘッダーにピンボタンを追加しない | `WindowsSidebarView` | ピンの追加・解除、グループの開閉、選択位置 |
| 選択行 | ピン留め側と通常側に同じチャンネルがあっても、選択表示は 1 行だけ。選択チャンネルの親グループを開く | `WindowsSidebarView` | smoke の選択行数と画面 |
| サイドバー下部 | 接続ドットと接続状態、その下にアバター 33、表示名、`@screenName`、右側に設定アイコン。左右 20、上下 17。システム通知スイッチを置かない | `WindowsSidebarView` | `validateWorkspace` と画面 |
| ヘッダー | 左に種類アイコン 20、チャンネル名 16 太字と説明 11。説明が空なら種類名。右に検索と更新の 30 × 30 アイコン。左右 25、上下 17 | `WorkspaceWindow.buildWorkspace` | `validateWorkspace`、通常画面 |
| チャンネル検索 | 検索欄はヘッダー内で検索アイコンと置き換わる。更新アイコンは閉じるアイコンに変わる。別の検索行を増やさない。欄は理想幅 280、150〜360、高さ 30、2 文字未満の検索ボタンは無効 | `WorkspaceWindow` | `validateWorkspace(searchOpen: true)`、検索画面、1 文字と 2 文字で確認 |
| エラー | 通常時のヘッダー下に接続状態やステータス行を常設しない。エラーがあるときだけ再試行・閉じる付きバナーを出す | `WorkspaceWindow.render` | 正常時とエラー時の画面 |
| 会話未選択 | 会話を始める案内、サイドバー選択の説明、再読み込みボタン。ヘッダーと投稿欄は隠す | `WorkspaceWindow` | チャンネル未選択状態 |
| 履歴読み込み | タイムライン最上部の `以前のメッセージを読み込む`。読み込み中は表示・無効状態を変える。読み込み後は読んでいた位置を保持 | `WorkspaceWindow.loadOlder` | 最上部まで移動、読み込み前後の位置、`history.bmp` |
| 最新へ移動 | `最新のメッセージ` をタイムライン下中央に重ねる。通常の履歴を読んでいて最下部から離れているときだけ。検索中・初回読み込み中には出さない | `WorkspaceWindow.updateTimelineActions` | 最下部・過去・検索の 3 状態 |
| メッセージ | 通常行はアバター 38、表示名 13、隣に時刻 11、本文 13。余白は左右 26、通常上下 9、連続行上下 3。同一送信者・日付内・5 分未満の連続行をまとめる | `TimelineMessageView`、`WorkspaceWindow` | 通常行、連続行、日付区切り、削除済み投稿の画面 |
| 画像・埋め込み | アバター、本文の書式、画像、リンク等の埋め込みを表示。センシティブなメディアは操作前に要求しない | `TimelineMessageView`、`TimelineMarkdownView` | 画像入り fixture、表示制限前後、Markdown fixture |

## 投稿欄

| 対象 | 要件 | 必要な検証 |
| --- | --- | --- |
| 全体 | 外側は左右 24、上 10、下 16。半径 10 の一つのカード内にプレビュー、入力欄、操作列をまとめる | `validateComposer` と画面 |
| プレビュー | 添付がある場合だけカード上部に高さ 82 の横スクロール列。画像 76 × 64、間隔 8、余白左右 12・上下 8。下に区切り線 | 画像を追加した状態の画面と `validateComposer` |
| 画像操作 | 削除ボタンは 18 × 18 の右上オーバーレイ。アップロード・削除中はスピナー、失敗時は警告アイコン。ファイル名や状態文を別の可視行に並べない | アップロード中・完了・失敗・削除中の画面 |
| エディター | プレースホルダーは `<チャンネル名> にメッセージを送信`。13 ポイント、最小高さ 38、最大 170。複数行で伸び、上限以降はスクロールする | 通常・複数行・3,600 文字で `validateComposer` |
| 操作列 | カード内下段に画像、絵文字、余白、上矢印の送信ボタン。画像・絵文字 28 × 28、送信 30 × 28。画像・絵文字の間隔 10。文字ラベルのボタンにしない | `validateComposer` と画面 |
| 状態 | API キーなし、送信中、チャンネルなしでは画像追加を無効化。送信中はエディターと絵文字を無効化。送信可能性は入力・画像アップロード状態・上限に従う | キーなし、送信可能、送信中の監査 |
| カウンター | ユーザー指定に従い文字数カウンターは常時非表示 | 3,600 文字でも `validateComposer` が成功 |
| ヒント | カード外の下側、右揃えで `Enterで送信 · Shift + Enterで改行` を 10 ポイントで表示 | `validateComposer` |
| キー入力 | Enter で送信、Shift+Enter で改行。日本語 IME 変換確定の Enter では送信しない | 実際のキーボードと日本語 IME で確認 |
| 絵文字 | macOS の OS 文字パレットに対応して Windows の OS 絵文字パネルを利用。入力位置に挿入する | エディター内にカーソルを置いた実操作で確認。自動 smoke は OS 全体へキーを送らない |

## 設定

設定フォームの順序は `通知` → `画像アップロード` → `接続`、大きさは 480 × 470 です。

| セクション | 行と表示条件 | 必要な検証 |
| --- | --- | --- |
| 通知 | `システム通知を表示` スイッチ、`通知の対象` 選択、`通知音を鳴らす` スイッチ。通知無効時は対象と音を無効化 | `validateSettings` を通知オン・オフ双方で実行 |
| 通知許可 | 許可済みなら許可状態。未許可なら許可操作とシステム設定へのリンク。ミュート・表示中・自身の投稿を除く説明と、エラー発生時だけエラー文 | 許可済み・未許可の各状態 |
| 画像アップロード | `ImgBB の API キー` のセキュア入力、保存先と使い方の説明。変更時に保存し、独立した保存ボタンを増やさない。エラー時だけエラー文 | `validateSettings`、保存と再表示 |
| 接続 | サーバー、ログイン中のみアカウントとログアウト。WebSocket の接続中・接続済みインジケーターを入れない | `validateSettings`、未ログイン時の条件 |

Windows 固有の変更は OS 名、資格情報マネージャー名、システム設定へのリンク、OS 絵文字パネル、Windows のコントロール／フォント／同義のアイコンです。これらを理由にコントロールの配置、行の追加、表示条件を変えません。

## 実行時監査の使い方と範囲

[`WindowsUIAudit.swift`](../Sources/KokoroWindows/WindowsUIAudit.swift) は、実際に生成・配置された `Panel.children`、`Border.child`、`ContentControl.content` をたどります。非表示の祖先を持つ子は対象外です。種類、表示文、プレースホルダー、アクセシビリティ名、有効状態、フォントサイズ、親子関係とネイティブの座標を記録します。`TextBox.text` と `PasswordBox.password` は読み取りません。

`inspect(element:)` の結果に対し、`validateWorkspace`、`validateComposer`、`validateSettings` が違反の配列を返します。通常画面・ヘッダー検索中・長い下書き・設定オン／オフを別々に実行してください。`save(_:to:)` で fixture の監査記録を JSON に保存できます。

監査に成功しても、OS テンプレート内部の見た目、クリッピング、画像の読み込み結果、絵文字パネル、IME、ホバーの見た目までは証明しません。smoke が生成する `.build/windows/ui-snapshots` の画面画像を確認し、操作が必要な項目は別途実行します。macOS の実装を読んだこと、Windows のコードがビルドできること、一般的な状態テストの成功だけを UI 一致の証拠にはしません。

## 2026-09-28 の検証結果

Windows / Swift 6.4 のビルド、110 件の状態・通信テスト、通常およびチャンネルなしのネイティブ WinUI smoke が成功しました。画面の配置監査に加え、以下の実描画を確認しています。

| 検証 | `.build/windows/ui-snapshots/` の記録 |
| --- | --- |
| ログイン、通常画面、履歴、検索、DM | `login`、`workspace`、`history`、`search`、`direct-message` |
| 文字数カウンター非表示と投稿欄 | `long-draft`（3,600 文字） |
| 添付画像の状態と 76 × 64 の表示枠 | `attachment-uploading`、`attachment-ready`、`attachment-deleting`、`attachment-failed` |
| 通知オン・オフと設定の全項目 | `settings`、`settings-disabled`、`settings-light` |
| サイドバーの絞り込み | `sidebar-filter-empty`、`sidebar-unread` |
| 明暗テーマ、エラー、未選択の案内 | `workspace-light`、`workspace-error`、`workspace-light-error`、`empty-workspace`、`empty-error` |
| 最小サイズの配置 | `minimum-size`（860 × 600）。実 HWND の `WM_GETMINMAXINFO` も同サイズと一致 |

各記録には BMP とコントロール監査 JSON があります。画像添付の状態は専用の通信しないサービスで再現し、本番 ImgBB への送信・削除は行っていません。画像リクエストでは認証情報の非送信、センシティブ／削除済み画像の自動取得抑止も検証しています。

OS 絵文字パネルの実操作、日本語 IME と Enter / Shift + Enter、実通知の表示・クリック、本番 ImgBB、macOS 上の再ビルドは、この Windows smoke の検証範囲外です。フォント・OS コントロール・ウィンドウ装飾は Windows の描画であり、ピクセル単位の一致を主張するものではありません。
