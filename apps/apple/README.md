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
| `Config/` | 签名配置：`Base.xcconfig` 入库；`Local.xcconfig` 不入库，由 `setup-signing.sh` 生成 |
| `.swift-format` | 格式化配置（4 空格缩进，行宽 100） |

工程用的是 Xcode 的同步文件夹：在上面这些目录里新建或删除 `.swift` 文件，Xcode 会自动加进对应 target，不用手动拖文件，`project.pbxproj` 也不会因此改动。

## 只跑模拟器

不需要任何签名配置。打开 `RepFlow.xcodeproj`：

- 选 scheme `RepFlow` + 任一 iPhone 模拟器 → Run，跑 iOS App
- 选 scheme `RepFlowWatch` + 任一 Apple Watch 模拟器 → Run，跑手表 App

## 配置签名（装真机前做一次）

1. Xcode → Settings → Apple Accounts，用自己的 Apple ID 登录。登录后显示「Personal Team」即可，这一页看不到 Team ID，不用找。
2. **关掉 Xcode**，在 `apps/apple/` 下运行（参数换成你自己的后缀，只用小写字母和数字）：

   ```bash
   sh Config/setup-signing.sh wensharre
   ```

   脚本从 Xcode 的登录信息里读出 Team ID，生成不入库的 `Config/Local.xcconfig`。每人的后缀必须不同，因为免费账号的 Bundle ID 不能和别人重复。脚本读不到 Team ID 时，照 `Config/Local.xcconfig.example` 手写一份也可以。
3. 重新打开 `RepFlow.xcodeproj`。Signing & Capabilities 页面应当直接显示你的 Personal Team，Bundle ID 带上你的后缀，没有报错。

**不要**在 Signing & Capabilities 页面里手动选 Team。手动选会把 Team ID 写进 `project.pbxproj`，这个文件是要提交的。如果已经选过，在 `apps/apple/` 下运行 `git checkout -- RepFlow.xcodeproj/project.pbxproj` 撤掉改动，再做第 2 步。

## 装到真机（iPhone + Apple Watch）

1. 用线把 iPhone 连到 Mac，iPhone 上弹出「要信任此电脑吗」时点信任。
2. 在 Xcode 的 Device Hub 里选中你的 iPhone，点 Pair 完成配对。旧版本 Xcode 里这个入口叫 Window → Devices and Simulators。
3. 配对后，iPhone 的「设置 → 隐私与安全性」最下面会出现「开发者模式」，打开它并按提示重启。手表要先和这台 iPhone 配对，然后在手表的「设置 → 隐私与安全性」里同样打开开发者模式。
4. 顶部选 scheme `RepFlow`，运行目标选你的 iPhone，点 Run。手表 App 打包在 iOS App 里：装好后在 iPhone 的 Watch App →「可用的 App」里安装 RepFlow。也可以选 scheme `RepFlowWatch`、运行目标选手表，直接 Run。
5. 第一次打开时，iPhone 会提示「不受信任的开发者」。到「设置 → 通用 → VPN 与设备管理」里信任你的 Apple ID。

免费账号签的包 7 天后过期，过期了重新 Run 一次就行。免费账号还有两个限制：一台设备上最多同时装 3 个自签名 App，每 7 天最多注册 10 个 Bundle ID。

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
