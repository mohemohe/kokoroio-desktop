# GitHub Actions でのビルド・署名・リリース

macOS 14 以降で動く Universal アプリ（arm64 / x86_64）を配布します。ビルドには GitHub-hosted の `macos-26` runner と `/Applications/Xcode.app` を使用します。

## 初回設定

このプロジェクトを GitHub リポジトリに push し、Actions を有効にしてください。workflow、`scripts/build-release.sh`、Xcode プロジェクト、Sources、Resources、Tests を含むコミットが必要です。`.build` と `build` の生成物は不要です。

リポジトリの **Settings → Secrets and variables → Actions** に次の Repository secrets を登録します。名前は `awayuki-desktop` の workflow に揃えています。別リポジトリの Repository secrets は自動で引き継がれません。Organization secrets を使う場合も、このリポジトリへのアクセスを許可してください。

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

この artifact は開発確認用の ad-hoc 署名で、公証されません。バージョンは `0.0.0`、ビルド番号は Actions の run number です。配布には次の Release workflow を使ってください。

## リリースを作る

workflow とリリーススクリプトを含むコミットにタグを付け、push します。

```sh
git tag v0.1.0
git push origin v0.1.0
```

[Release](../.github/workflows/release.yml) が起動し、次を順番に実行します。

1. タグのコミットをチェックアウトし、バージョン形式を検証してテストを実行します。
2. Developer ID 証明書と公証用資格情報を一時 keychain に取り込みます。必須 Secret が欠けている場合は失敗します。
3. Universal アプリを Hardened Runtime・App Sandbox 有効でビルドし、Developer ID 署名を検証します。
4. アプリを Apple に公証申請し、`Accepted` を確認してチケットを staple・検証します。
5. staple 済みアプリの ZIP と、アプリおよび Applications ショートカットを含む DMG を作ります。DMG も署名・公証・staple・検証します。
6. チェックサムを生成して artifact に保存し（14 日間）、GitHub Release の**下書き**を作成します。

Release には次の 3 ファイルと自動生成したリリースノートを添付します。

```text
KokoroDesktop-0.1.0-universal.zip
KokoroDesktop-0.1.0-universal.dmg
SHA256SUMS.txt
```

GitHub の **Releases** で下書きの内容・添付ファイルを確認し、**Publish release** で公開してください。参考にした `awayuki-desktop` と同様、workflow は下書きまで作成します。実際の配布前にはダウンロードしたアプリを開き、Gatekeeper と起動を確認してください。

通常版は `v1.2.3`、プレリリースは `v1.2.3-rc.1` の形式を使います。`v1.2`、`latest`、`+metadata` 付きのタグは受け付けません。プレリリースは GitHub 上で prerelease として設定し、ファイル名には接尾辞を残します。`CFBundleShortVersionString` は数値部分の `1.2.3`、`CFBundleVersion` は run number になります。ビルド時の上書きなのでプロジェクトファイルの書き換えは不要です。

既存タグを再ビルドする場合は **Actions → Release → Run workflow** の `tag` に `v0.1.0` などを指定します。workflow を選択したブランチではなく、その**既存タグのコミット**をビルドします。手動実行には、workflow がデフォルトブランチにも存在する必要があります。再実行は同じタグのリリースを更新するため、公開済み版は新しいバージョンタグでリリースしてください。

## ローカルで配布形式を検証する

署名用 Secrets を使わず、CI と同じ Universal ビルド・ZIP・DMG 作成を実行できます。

```sh
VERSION=0.1.0 BUILD_NUMBER=1 bash scripts/build-release.sh
cd build/release
shasum -a 256 -c SHA256SUMS.txt
```

生成先は `build/release`、DerivedData は `.build/release-xcode` です。`OUTPUT_DIR` と `DERIVED_DATA_PATH` で変更できます。配布署名までローカルで実行する場合は、証明書と公証資格情報を登録済みの keychain を用意し、`SIGN_IDENTITY`、`KEYCHAIN_PATH`、`NOTARY_PROFILE` を指定して `--signed` を渡します。署名・公証に失敗した場合はリリースを作りません。

## 参考資料

- [GitHub: macOS runner への証明書のインストール](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)
- [Apple: 公証 workflow のカスタマイズ](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [GitHub: macOS 26 runner のソフトウェア構成](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)
