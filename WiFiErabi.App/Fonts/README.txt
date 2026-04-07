UDEV Gothic JPDOC を埋め込む準備ができています。

手順:
1. UDEV Gothic JPDOC の .ttf または .otf をこのフォルダに置く
2. 配布時のために LICENSE / OFL もこのフォルダに置く
3. dotnet build または dotnet publish を実行する

App.xaml では次の優先順でフォントを使います:
- UDEV Gothic JPDOC
- BIZ UDPGothic
- Segoe UI

UDEV Gothic JPDOC が見つからない場合は、後ろのフォールバックフォントで表示されます。
