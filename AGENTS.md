# リポジトリ作業ガイド

## 概要と構成

kokoro.io のデスクトップクライアント。Swift 6 ツールチェーン、Swift 5 言語モードを使用する。
macOS は SwiftUI、Windows は swift-winrt で生成した WinUI 3 バインディングを使用する。

- `Sources/KokoroCore/`: 両 OS で共有する API、モデル、リアルタイム通信、Hotwire 解析。
- `Sources/KokoroDesktop/`: macOS の UI と OS 連携。
- `Sources/KokoroWindows/`: Windows の UI と OS 連携。
- `Sources/KokoroWindowsState/`: Windows のチャット状態管理。
- `Tests/`: 共通処理と Windows 状態管理のテスト。
- `Windows/Native/`、`Windows/WebSocket/`: Windows ネイティブ連携。
- `Windows/projections.json`: WinRT 生成器・SDK のバージョンと生成対象。
- `scripts/`: ビルド、生成、配布、検証用スクリプト。

仕様・操作は `README.md`、Windows の詳細は `docs/windows.md`、UI の対応関係は
`docs/windows-ui-parity.md`、配布手順は `docs/releasing.md` を参照する。

## Windows 互換性と HTML 解析

- **Windows でコンパイルされる新規・変更コードに、`XMLDocument`／`XMLElement` の直接利用を追加しない。**
  macOS の Foundation API が Windows でも同じように使えると仮定しない。
- Windows の HTML 解析には SwiftSoup を使う。Hotwire の HTML 解析は既存の
  `HotwireHTMLParser.body(_:)` を再利用し、OS ごとの処理を各呼び出し元に複製しない。
- 特に `XMLDocument` の `.documentTidyHTML` に依存した HTML 解析を Windows に持ち込まない。
  import の追加だけで HTML 解析の互換性が確保できたと判断しない。
- 技術上の注意: `XMLDocument`／`XMLElement` 自体が Windows で全面的に利用不能なのではなく、
  `FoundationXML` の明示的な import が必要で、HTML 補正機能も macOS と異なる。
  既存の Hotwire 実装には XML エンベロープ・文字参照の解析や内部ツリーとしての利用が残っている。
  これは新たな直接依存を追加してよいという意味ではない。
- サーバーから受け取る HTML は実行せず、解析時に外部リソースを取得しない。
  入力サイズ・深さの制限、外部エンティティの拒否、URL と投稿・チャンネル ID の検証を維持する。
- テキストの改行・空白・文字参照、画像の順序、リンクカードの抽出結果を保持する。
  関連変更は `HotwireEmbedParserTests` と `HotwireImageParserTests` の両方で確認する。

## ビルドと検証

コマンドはリポジトリのルートで実行する。共有コードの変更は両 OS への影響を確認し、
実行できなかった OS の検証は未実施と明記する。

macOS:

```sh
swift test --scratch-path .build/ci-tests --parallel
./scripts/build-app.sh
```

Windows（PowerShell 7、Swift 6.4、MSVC x64、Windows SDK）:

```powershell
./scripts/build-windows.ps1 -Configuration release -Test
./scripts/package-windows.ps1 -Version 0.0.0 -BuildNumber 1
./scripts/test-windows-package.ps1 -Version 0.0.0
```

既存バインディングを再利用する場合はビルドに `-SkipGenerate` を付けられる。
起動中のアプリと出力先を分ける場合は `-OutputName preview` を指定し、梱包時にも同じ値を渡す。
通常の Windows CI と Release は `.github/workflows/windows-build.yml` を共有する。

## 変更時の注意

- `Package.swift` の OS 別依存関係を維持する。macOS 専用 API を共有コードへ無条件に追加しない。
- `Windows/Generated/`、`.build/`、`build/` は生成物。直接修正・コミットしない。
  バインディングの変更は `Windows/projections.json` と `scripts/generate-winrt.ps1` で行う。
- Windows ビルドはプラットフォーム間で異なる依存グラフを使う。
  スクリプトが復元する `Package.resolved` に、意図しない Windows 側の解決結果を残さない。
- 既存のユーザー変更を保持し、修正範囲を依頼内容に絞る。
