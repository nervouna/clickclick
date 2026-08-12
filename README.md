# ClickClick

ClickClick（咔咔咔咔计数器）是一款 macOS 菜单栏输入计数器。它通过 CoreHID 按物理键盘设备统计按键次数，只在本地保存聚合数据。

## Privacy

- 不保存输入文本。
- 不保存按键顺序或精确时间戳。
- 不记录正在使用的应用或窗口。
- 不上传数据。

## Development

Requirements: macOS 26+, Xcode 26+, Apple Silicon.

```sh
xcodegen generate
xcodebuild -project ClickClick.xcodeproj -scheme ClickClick -destination 'platform=macOS' test
```
