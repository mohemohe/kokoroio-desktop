# Kokoro Desktop for Windows

## 起動方法

1. Windows 10 バージョン 1809 以降または Windows 11（x64）を使用してください。
2. [Windows App Runtime 1.7 (x64)](https://aka.ms/windowsappsdk/1.7/1.7.250909003/windowsappruntimeinstall-x64.exe) をインストールしてください。
3. ZIP の内容をすべて同じフォルダーへ展開し、`KokoroDesktop.exe` を起動してください。

Swift・Visual Studio のインストールは不要です。Swift ランタイム、Visual C++ ランタイム、
WinRT バインディング、リソースを同梱しているため、EXE だけを移動せずフォルダーごと保存してください。
この Windows 版は未署名です。Windows の SmartScreen などが発行元を確認できない旨を表示する場合があります。

ログイン画面にサーバー URL とアクセストークンを入力してください。
トークンは接続先の `/access_tokens`（例: <https://kokoro.io/access_tokens>）から発行できます。
接続情報は Windows 資格情報マネージャーに保存されます。

## 更新・バージョン確認

アプリを終了して、新しいバージョンの ZIP を別のフォルダーへ展開してください。
バージョンとビルド番号は `version.json`、依存ライブラリのライセンスは `licenses` にあります。
リリースページの `SHA256SUMS.txt` と、PowerShell の `Get-FileHash -Algorithm SHA256 <ZIPのパス>` で
表示されるハッシュを比較してダウンロードを検証できます。

操作方法・ソースコード: <https://github.com/mohemohe/kokoroio-desktop>
