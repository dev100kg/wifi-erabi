# Release Flow

`Wi-Fiえらび` は GitHub Releases にインストーラを載せて配布します。

## いつもの流れ

1. `WiFiErabi.App/WiFiErabi.App.csproj` の `Version` を更新する
2. 変更を commit して `main` に push する
3. `v0.1.0` のようなタグを作って push する
4. GitHub Actions の `Release` ワークフローが走る
5. GitHub Releases にインストーラと portable zip が作られる

## タグの付け方

```powershell
git tag v0.1.0
git push origin v0.1.0
```

## 出力されるもの

- `WiFiErabi-Setup-v0.1.0.exe`
- `WiFiErabi-v0.1.0-portable.zip`

## 手動で試したいとき

GitHub Actions を使わずにローカルで作る場合は次です。

```powershell
powershell -File .\installer\Build-Installer.ps1
```

インストーラは `artifacts/installer` に出ます。
