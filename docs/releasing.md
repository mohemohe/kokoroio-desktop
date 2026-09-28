# GitHub Actions でのビルド・署名・リリース

macOS 15 以降で動く Universal アプリ（arm64 / x86_64）と Windows x64 アプリを同じ GitHub Release で配布します。
macOS は GitHub-hosted の `macos-26` runner と `/Applications/Xcode.app`、Windows は `windows-2022` runner と Swift 6.4 / MSVC x64 を使用します。

## 初回設定

このプロジェクトを GitHub リポジトリに push し、Actions を有効にしてください。全 workflow、`scripts/`、`Windows/Native`、`Windows/Distribution`、`Windows/projections.json`、`Package.swift`、Xcode プロジェクト、Sources、Resources、Tests を含むコミットが必要です。`.build`、`build`、`Windows/Generated` の生成物は不要です。WinRT バインディングは runner 上で生成します。

macOS の署名・公証用に、リポジトリの **Settings → Secrets and variables → Actions** に次の Repository secrets を登録します。名前は `awayuki-desktop` の workflow に揃えています。別リポジトリの Repository secrets は自動で引き継がれません。Organization secrets を使う場合も、このリポジトリへのアクセスを許可してください。Windows 版は未署名で、追加の Secrets は不要です。

| Secret | 内容 |
| --- | --- |
| `MACOS_CERTIFICATE` | 秘密鍵を含む Developer ID Application 証明書をエクスポートした `.p12` の Base64 |
| `MACOS_CERTIFICATE_PWD` | `.p12` のエクスポート時に設定したパスワード（空欄不可） |
| `MACOS_CERTIFICATE_NAME` | `Developer ID Application: 名前 (TEAMID)` 形式の完全な署名 ID |
| `KEYCHAIN_PWD` | runner 上に作る一時 keychain 用のパスワード |
| `NOTARIZATION_APPLE_ID` | 公証に使用する Apple Account のメールアドレス |
| `NOTARIZATION_TEAM_ID` | 証明書の Apple Developer Team ID |
| `NOTARIZATION_PASSWORD` | Apple Account で発行した App 用パスワード（通常のログインパスワードではありません） |

有効な Apple Developer Program の Developer ID Application 証明書を使います。Apple Development や Developer ID Installer 証明書ではありません。現在の entitlement は App Sandbox と送信ネットワークのみで、Provisioning Profile のインストールは行いません。

macOS で証明書を Base64 にしてクリップボードへコピーする例です。

```sh
base64 -i DeveloperIDApplication.p12 | pbcopy
```

証明書・秘密鍵・パスワードはリポジトリに追加しないでください。workflow は証明書を `$RUNNER_TEMP` に展開して一時 keychain に取り込み、公証用資格情報も同じ keychain に保存します。終了時は成功・失敗にかかわらず削除します。リリース用の `GITHUB_TOKEN` は Actions が自動発行するため、PAT の登録は不要です。リポジトリまたは Organization のポリシーで、release job の `contents: write` を許可してください。

## 通常のビルド

[Build and Test](../.github/workflows/ci.yml) はブランチへの push、PR、Actions 画面の **Run workflow** で実行できます。

1. `swift test` でテストを実行します。
2. `Release` 構成で arm64 / x86_64 の両方をビルドします。
3. ZIP、DMG、`SHA256SUMS.txt` を `KokoroDesktop-ci-<run number>` artifact に保存します（7 日間）。

この macOS artifact は開発確認用の ad-hoc 署名で、公証されません。

[Windows Build and Test](../.github/workflows/windows.yml) もブランチへの push、PR、手動実行で起動します。
共通の [Windows ビルド workflow](../.github/workflows/windows-build.yml) が MSVC x64 と Swift 6.4 を準備し、
WinRT バインディングの生成、自動テスト、Release ビルド、ZIP の作成・内容検証を行います。
ZIP と `SHA256SUMS.txt` は `KokoroDesktop-windows-ci-<run number>` artifact に 7 日間保存します。

両 OS とも CI のバージョンは `0.0.0`、ビルド番号は Actions の run number です。配布には次の Release workflow を使ってください。

## リリースを作る

workflow とリリーススクリプトを含むコミットにタグを付け、push します。

```sh
git tag v0.1.0
git push origin v0.1.0
```

[Release](../.github/workflows/release.yml) が起動し、タグ形式とコミットを確定して、同じコミットから macOS と Windows を並行ビルドします。

macOS の処理は次のとおりです。

1. タグのコミットをチェックアウトし、バージョン形式を検証してテストを実行します。
2. Developer ID 証明書と公証用資格情報を一時 keychain に取り込みます。必須 Secret が欠けている場合は失敗します。
3. Universal アプリを Hardened Runtime・App Sandbox 有効でビルドし、Developer ID 署名を検証します。Release ビルドでは `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` を設定し、両アーキテクチャにデバッグ用の `com.apple.security.get-task-allow` が有効になっていないことを公証前に確認します。
4. アプリを Apple に公証申請し、`Accepted` を確認してチケットを staple・検証します。
5. staple 済みアプリの ZIP と、アプリおよび Applications ショートカットを含む DMG を作ります。DMG も署名・公証・staple・検証します。
6. チェックサムを生成して `macos-release` artifact に保存します（14 日間）。

Windows は通常 CI と同じ workflow でテスト・Release ビルドを行い、バージョン付き ZIP とチェックサムを
`windows-release` artifact に保存します（14 日間）。Swift / Visual C++ ランタイム、WinRT DLL、リソース、
ライセンス、起動手順、`version.json` を同梱し、PDB やテスト用実行ファイルは除外します。
Windows App Runtime 1.7 x64 は利用者側でのインストールが必要です。リンクを ZIP 内の `README.md` に記載しています。
Windows 版は未署名のため、SmartScreen で発行元を確認できない旨が表示される場合があります。

両方のビルドが成功すると、Linux runner で各 artifact の SHA-256 を検証し、共通の `SHA256SUMS.txt` を作成します。
GitHub Release の**下書き**に、次の 4 ファイルと自動生成したリリースノートを添付します。どちらかのビルドが失敗した場合は下書きを作成しません。

```text
KokoroDesktop-0.1.0-universal.zip
KokoroDesktop-0.1.0-universal.dmg
KokoroDesktop-0.1.0-windows-x64.zip
SHA256SUMS.txt
```

GitHub の **Releases** で下書きの内容・添付ファイルを確認し、**Publish release** で公開してください。参考にした `awayuki-desktop` と同様、workflow は下書きまで作成します。実際の配布前にはダウンロードした各 OS のアプリを開き、macOS の Gatekeeper と Windows のランタイムを含めて起動を確認してください。

通常版は `v1.2.3`、プレリリースは `v1.2.3-rc.1` の形式を使います。`v1.2`、`latest`、`+metadata` 付きのタグは受け付けません。プレリリースは GitHub 上で prerelease として設定し、ファイル名には接尾辞を残します。macOS の `CFBundleShortVersionString` は数値部分の `1.2.3`、`CFBundleVersion` は run number になります。Windows の `version.json` には接尾辞を含むバージョンと run number を記録します。ビルド時の上書きなのでプロジェクトファイルの書き換えは不要です。

既存タグを再ビルドする場合は **Actions → Release → Run workflow** の `tag` に `v0.1.0` などを指定します。workflow を選択したブランチではなく、その**既存タグのコミット**をビルドします。手動実行には、workflow がデフォルトブランチにも存在する必要があります。再実行は同じタグのリリースを更新するため、公開済み版は新しいバージョンタグでリリースしてください。

コードやビルド設定を修正した場合、古いタグのジョブを **Re-run jobs** しても修正は反映されません。修正を含むコミットに新しいタグ（例: `v0.1.1`）を付けて push してください。

## ローカルで配布形式を検証する

署名用 Secrets を使わず、CI と同じ Universal ビルド・ZIP・DMG 作成を実行できます。

```sh
VERSION=0.1.0 BUILD_NUMBER=1 bash scripts/build-release.sh
cd build/release
shasum -a 256 -c SHA256SUMS.txt
```

生成先は `build/release`、DerivedData は `.build/release-xcode` です。`OUTPUT_DIR` と `DERIVED_DATA_PATH` で変更できます。配布署名までローカルで実行する場合は、証明書と公証資格情報を登録済みの keychain を用意し、`SIGN_IDENTITY`、`KEYCHAIN_PATH`、`NOTARY_PROFILE` を指定して `--signed` を渡します。署名・公証に失敗した場合はリリースを作りません。

Windows では PowerShell 7 で実行します（開発環境は [Windows 版](windows.md) を参照）。

```powershell
./scripts/build-windows.ps1 -Configuration release -Test
./scripts/package-windows.ps1 -Version 0.1.0 -BuildNumber 1
./scripts/test-windows-package.ps1 -Version 0.1.0
```

生成先は `build/windows/packages/0.1.0` です。検証スクリプトは ZIP の SHA-256、必須ランタイム・リソース・ライセンス、バージョン情報、開発用バイナリの混入を確認します。

## 参考資料

- [GitHub: macOS runner への証明書のインストール](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)
- [Apple: 公証 workflow のカスタマイズ](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [GitHub: macOS 26 runner のソフトウェア構成](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)
- [Swift: Windows へのインストール](https://www.swift.org/install/windows/)
- [GitHub: workflow の再利用](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows)
