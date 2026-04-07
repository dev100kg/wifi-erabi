# Wi-Fiえらび

近くにある Wi-Fi を見比べて、よさそうな接続先へ切り替えやすくする Windows アプリです。

今つながっている Wi-Fi を見ながら、

- 近くの Wi-Fi を一覧で確認する
- おすすめ順で見比べる
- そのまま接続先を切り替える

ことができます。

## できること

- 近くにある Wi-Fi を一覧表示する
- 今つながっている Wi-Fi を目立たせる
- 電波の強さや混雑度をもとに、おすすめ順に並べる
- 一覧から選んで接続する
- 接続後に自動で最新状態へ更新する

## フォルダ構成

- `WiFiErabi.App`: アプリ本体です
- `installer`: 配布用ファイルやインストーラを作るためのファイルです
- `legacy`: 試作で作った PowerShell 版です

## 開発用に起動する

`WiFiErabi.App` フォルダで次を実行します。

```powershell
dotnet run
```

ビルドだけ行う場合はこちらです。

```powershell
dotnet build
```

## 配布用ファイルを作る

ルートフォルダで次を実行します。

```powershell
powershell -File .\installer\Build-Publish.ps1
```

すると `artifacts/publish/win-x64` に配布用ファイルが出ます。

## インストーラを作る

Inno Setup 6 が入っていれば、次でインストーラまで作れます。

```powershell
powershell -File .\installer\Build-Installer.ps1
```

できあがるファイルは `artifacts/installer/WiFiErabi-Setup.exe` です。

インストーラ設定ファイルは `installer/WiFiErabi.iss` です。

## GitHub Releases で配布する

タグを `v0.1.0` のように切って push すると、GitHub Actions の `Release` ワークフローで

- インストーラ
- portable zip

を作って GitHub Releases に載せるようにしています。

詳しい手順は `RELEASE.md` にまとめています。

## うまく動かないとき

Wi-Fi 一覧が取れないときは、次を確認してください。

- 位置情報サービスが有効になっているか
- アプリを管理者として実行しているか

位置情報の設定画面は次で開けます。

```powershell
start ms-settings:privacy-location
```

## フォント

アプリ全体で `UDEV Gothic JPDOC` を使えるようにしてあります。
フォントファイルは `WiFiErabi.App/Fonts` に置いています。

## legacy について

PowerShell 版の試作は `legacy` に残しています。
比較や参照用で、今後の本命は `WiFiErabi.App` です。
