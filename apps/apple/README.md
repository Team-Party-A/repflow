# apps/apple

RepFlow 的 Xcode 工程：一个工程，两个 App target（iOS、watchOS），各带一个单元测试 target。

## 环境

- Xcode 27.1（全组统一，自带 `swift-format`，不用另装工具）
- 部署目标：iOS 17.2、watchOS 10.0

## 目录

| 路径 | 内容 |
| --- | --- |
| `RepFlow/` | iOS App（target `RepFlow`） |
| `RepFlowWatch/` | watchOS App（target `RepFlowWatch`，构建 iOS App 时会一起打包进去） |
| `Shared/` | 两端共用的代码，同时编译进两个 target；数据模型等 #32、#34 冻结后再写 |
| `RepFlowTests/`、`RepFlowWatchTests/` | 两端的 XCTest 单元测试 |
| `Config/` | 签名配置：`Base.xcconfig` 入库，`Local.xcconfig` 不入库 |
| `.swift-format` | 格式化配置（4 空格缩进，行宽 100） |

工程用的是 Xcode 的同步文件夹：在上面这些目录里新建或删除 `.swift` 文件，Xcode 会自动加进对应 target，不用手动拖文件，`project.pbxproj` 也不会因此改动。

## 只跑模拟器

不需要任何签名配置。打开 `RepFlow.xcodeproj`：

- 选 scheme `RepFlow` + 任一 iPhone 模拟器 → Run，跑 iOS App
- 选 scheme `RepFlowWatch` + 任一 Apple Watch 模拟器 → Run，跑手表 App

## 配置签名（装真机前做一次）

1. Xcode → Settings → Accounts，用自己的 Apple ID 登录，记下个人 Team 的 ID（10 位字母数字）。
2. 复制模板并填写：

   ```bash
   cp Config/Local.xcconfig.example Config/Local.xcconfig
   ```

   - `DEVELOPMENT_TEAM`：上一步的 Team ID
   - `BUNDLE_ID_SUFFIX`：个人后缀，如 `.wensharre`。免费账号的 Bundle ID 不能和别人重复，所以每人都要加。

3. **不要**在 Xcode 的 Signing & Capabilities 页面里选 Team，那样会把你的 Team ID 写进 `project.pbxproj` 并被提交。签名只改 `Local.xcconfig`。

## 装到真机（iPhone + Apple Watch）

1. iPhone 用线连 Mac，在「设置 → 隐私与安全性 → 开发者模式」打开开发者模式并重启；手表已和这台 iPhone 配对，同样在手表的「设置 → 隐私与安全性」打开开发者模式。
2. Xcode → Window → Devices and Simulators，确认 iPhone 和手表都出现且没有报错（手表第一次连接要等它准备好调试）。
3. 选 scheme `RepFlow`，目标选你的 iPhone → Run。手表 App 被打包在 iOS App 里，装好后在手表上打开 Watch App →「可用的 App」里安装 RepFlow；也可以直接选 scheme `RepFlowWatch`、目标选手表 → Run。
4. 第一次打开时 iPhone 会提示「不受信任的开发者」：设置 → 通用 → VPN 与设备管理 → 信任你的 Apple ID。

免费账号签的包 7 天后过期，过期后重新 Run 一次即可。

## 命令行

在 `apps/apple/` 下执行：

```bash
# 构建（iOS App 连同手表 App）
xcodebuild build -scheme RepFlow -destination 'generic/platform=iOS Simulator'

# 测试
xcodebuild test -scheme RepFlow -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild test -scheme RepFlowWatch -destination 'platform=watchOS Simulator,name=Apple Watch SE 3 (40mm)'

# 格式检查 / 自动格式化
xcrun swift-format lint --strict --recursive .
xcrun swift-format format --in-place --recursive .
```

模拟器名称随 Xcode 版本变化，用 `xcrun simctl list devices available` 查本机有哪些。
