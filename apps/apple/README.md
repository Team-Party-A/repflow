# apps/apple

RepFlow 的 Xcode 工程：一个工程，两个 App target（iOS、watchOS），各带一个单元测试 target。

## 环境

- Xcode 27.1，全组统一。它自带 `swift-format`，不用另装工具。
- Xcode 27.1 只能装在 **Apple 芯片**的 Mac 上，而且 macOS 要 **Tahoe 26.6 或更新**。芯片和系统版本在「左上角苹果菜单 → 关于本机」里看。
- 部署目标：iOS 17.2、watchOS 10.0

### 装不了 Xcode 27.1 怎么办

| 你的 Mac | 做法 |
| --- | --- |
| Apple 芯片，macOS Tahoe 26.0 到 26.5 | 到「系统设置 → 通用 → 软件更新」升到最新的 26.x，再从 App Store 装 Xcode 27.1。首选这条路 |
| Apple 芯片，macOS Sequoia 15.x | 能升级到 Tahoe 26.6 或更新就先升级，升级前用时间机器备份。不想升或升不了，按下一行处理 |
| Intel 芯片，或者系统不能升级 | 装旧版 Xcode 26.x，按下面的限制使用 |

旧版 Xcode 按 macOS 版本选（完整对照见 [Apple 官网](https://developer.apple.com/xcode/system-requirements)）：

- macOS Tahoe 26.2 或更新：Xcode 26.6
- macOS Sequoia 15.6 或更新：Xcode 26.3

App Store 只提供最新版。旧版要到 <https://developer.apple.com/download/all> 用 Apple ID 登录，搜索版本号，下载 `.xip`，双击解压后把 Xcode 拖进「应用程序」。本工程用了 Xcode 16 才有的文件夹格式，Xcode 16 以下打不开。

用旧版 Xcode 有这些限制：

1. 写代码、跑模拟器、跑测试和格式检查都没问题。下文测试命令里的模拟器名称你本机可能没有，用 `xcrun simctl list devices available` 查出本机的名称再替换。在 PR 的「怎么测的及结果」里写明你用的 Xcode 版本和模拟器。
2. 真机不一定装得上。如果 iPhone 或手表的系统版本比这个 Xcode 支持的新（比如 Xcode 26.3 最高支持 iOS 26.2，手机已经是 iOS 27），Xcode 会提示不支持这台设备。遇到这种情况，请装了 27.1 的组员帮你装真机。
3. 打开工程后，如果 `git status` 显示 `RepFlow.xcodeproj/` 下有改动，那是旧版 Xcode 改写了工程文件，不要提交。在 `apps/apple/` 下运行 `git checkout -- RepFlow.xcodeproj` 撤掉。
4. 管理设备用菜单 Window → Devices and Simulators，旧版本没有 DeviceHub。

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
2. 打开 DeviceHub，选中你的 iPhone，点 Pair 完成配对。DeviceHub 是 Xcode 27 自带的独立 App，在 `Xcode.app/Contents/Applications/` 里，不用另外下载，用 Spotlight 搜「DeviceHub」就能打开。
3. 配对后，iPhone 的「设置 → 隐私与安全性」最下面会出现「开发者模式」，打开它并按提示重启。手表要先和这台 iPhone 配对，然后在手表的「设置 → 隐私与安全性」里同样打开开发者模式。
4. 顶部选 scheme `RepFlow`，运行目标选你的 iPhone，点 Run。手表 App 打包在 iOS App 里：装好后在 iPhone 的 Watch App →「可用的 App」里安装 RepFlow。也可以选 scheme `RepFlowWatch`、运行目标选手表，直接 Run。
5. 第一次打开时，iPhone 会提示「不受信任的开发者」。到「设置 → 通用 → VPN 与设备管理」里信任你的 Apple ID。

### 手表连不上或装不上时

- DeviceHub 里看不到手表，或者显示 Currently Unavailable：打开 Mac 的蓝牙，让 Mac、iPhone、手表连同一个 Wi‑Fi。校园网会隔离设备，连不上就让 iPhone 开热点，Mac 和手表都连这个热点。手表要解锁并放在旁边。手表被 Xcode 认到之后，「设置 → 隐私与安全性」里才会出现开发者模式。
- Xcode 显示构建成功，手表上却没有 App；或者经 iPhone 的 Watch App 安装时一直失败：改用命令行直接装到手表。在 `apps/apple/` 下运行：

  ```bash
  # 查手表的 UDID（Reality 一列为 physical 的 Apple Watch）
  xcrun devicectl list devices

  xcodebuild build -scheme RepFlowWatch -destination 'generic/platform=watchOS' -derivedDataPath build -allowProvisioningUpdates
  xcrun devicectl device install app --device <手表 UDID> build/Build/Products/Debug-watchos/RepFlowWatch.app
  # 启动前先解锁手表，否则报 Locked；也可以直接在手表的 App 列表里点开
  xcrun devicectl device process launch --device <手表 UDID> io.github.teampartya.repflow.<你的后缀>.watchkitapp
  ```

  `build/` 已在 `.gitignore` 里。工程暂时没有图标，RepFlow 在手表上显示为空白图标。

免费账号签的包 7 天后过期，过期了重新 Run 一次就行。免费账号还有两个限制：一台设备上最多同时装 3 个自签名 App，每 7 天最多注册 10 个 Bundle ID。

## 传感器录制与导出（#67）

录制入口用于给算法采集数据。一段录制保存一个格式 v1.0 的 JSON；使用
`CMDeviceMotion` 原始三轴加速度、角速度、重力和真实时间戳，不平滑、不补帧。
本版不记录可选的四元数。文件与正式训练记录分开保存，不上传后端。

### 安装与权限

按上文把本分支的 iPhone 和 Watch App 安装到一对已配对的真机，先打开手机 App。
Watch target 增加了 HealthKit entitlement、运动隐私说明及 `workout-processing`
后台模式。按组长在 [#67 中的确认](https://github.com/Team-Party-A/repflow/issues/67#issuecomment-6523446416)，
先使用自己的免费 Apple ID（Personal Team）和上述签名脚本安装，保留运动会话方案。
能否签名安装、授权并启动运动会话，以实际 Xcode 和真机结果为准；如失败，保存 Xcode
报错原文供负责人在 Issue 中反馈，再评估能够落腕持续采样的方案，不改为仅前台采样，
也不通过删除 entitlement 掩盖问题。
模拟器无法替代传感器、权限、落腕及 WatchConnectivity 真机验收。

手表第一次开始录制时，按系统提示允许运动权限。录制期间用
`HKWorkoutSession` 支持落腕运行，不读取已有健康记录，也不调用 workout builder
保存健康 App 训练。结束或放弃录制会结束运动会话。系统暂停/结束会话、传感器报错、
时间戳重复或倒序时，本次录制中断并提示重录，不把残缺数据冒充正常组。

### 录一组弯举

1. 采集前由团队分配匿名编号（例如 `p001`），确认私有数据存放位置、访问范围与保留期。
   不填写姓名、设备名、账号或其他身份信息。
2. 手表填写匿名编号，关闭「负样本」，选择「哑铃弯举」和 `50 Hz`；`25 Hz` 可用于对照。
3. 点「开始录制」，允许权限，等样本数增长。保持静止约 3 秒后点「开始本组」。
4. 完成一组完整弯举，回到起始姿态，再点「结束本组」。继续静止约 3 秒。
5. 点「停止并保存」。成功后自动排队发送到手机，手表仍保留原文件。
   选择「负样本」时，可录静止站立、走动或拿放器械，直接停止保存，无有效组边界。
6. 记录实际佩戴方式与过程异常，独立观察/复核真值。文件初始 `annotations=[]`，
   动作组的 `ground_truth_count=null`，不代表 0 次；负样本 `set=null`。
   本版不提供逐次标注界面；后续在电脑上按已冻结契约补标，不根据算法预测反填。

整段零点取首个有效运动样本；组边界与结束时间使用同一设备单调时间轴。
停止时间不会替换成最后样本时间，检查器的 `tail_gap_s` 会保留尾部停采间隔。
设备型号记录硬件型号代号，系统版本与佩戴腕/表冠方向取实际设备配置。
程序版本记录 App 版本和 build（本次 Watch build 为 `0.1.0(2)`）；以后变更采集逻辑应递增 build。

### 传到手机，再导出到 Mac

1. 等手机「录制文件」列表出现对应 UUID 的 `.json`。传输由系统调度，没有固定时延；
   不要求连接后端，也不要求登录。手机、手表保持配对，必要时打开两端 App。
2. 点文件的分享按钮，选 AirDrop，选择你的 Mac。也可用系统分享菜单存到「文件」。
3. 在 Mac 接收后，把 JSON 移到**仓库之外的私有目录**。不要把原始数据提交 Git、
   附在 PR 或粘贴到 AI 对话。
4. 在仓库根目录执行（替换成实际绝对路径）：

   ```sh
   python3 ml/inspect_recording.py "/你的私有目录/录制编号.json"
   ```

5. 检查退出码为 0；核对 `data_kind=recorded`、`sample_count`、`effective_hz`、
   `interval_max_s` 和 `tail_gap_s`，按采集过程判断是否有长缺口。格式通过不等于采样连续，
   更不等于已完成真值复核。只把**检查器的统计输出**贴到 PR，注明设备系统、
   抬腕/落腕情况与是否脱离 Xcode 调试。

发送失败或手机写入失败时，在手表「已保存在手表」列表点「发送到手机」重试。
同一 UUID 在传输队列中时不重复排队；手机重复收到相同内容不另存一份，内容不同则报错，
不覆盖原文件。「系统传输完成」不是手机持久化确认，必须以手机列表实际出现为准。
手表和手机的已保存文件在 App 重启后仍可找到，排除系统云备份；本版不自动删除原文件。
保存失败可点「重试保存」，保持同一 UUID、字节和结束时间；尚未保存的缓冲只在内存中，
不要强制退出、重启设备或卸载 App。采集会话中断时先放弃本次录制再重新开始。

### 验证

在 `apps/apple/` 执行 `sh check-recording-format.sh`：用实际 Swift 编码器分别生成
动作组、负样本两份临时 **synthetic** 数据，交给现有 Python 检查器；运行后删除临时文件。
预期均为 151 点、50 Hz、`duration_s=3.5`、`tail_gap_s=0.5`。该结果只验证格式互通。

单元测试覆盖真实时间间隔/轴符号保留、首样本零点、组边界、未确认真值的显式 null、
非法样本拒绝、重复文件与冲突、重启后列表及写入失败重试。仍须按下文运行两个 scheme 的 XCTest。
负责人还需在真机检查：权限拒绝与恢复、脱离调试器落腕录一组弯举、断连后重试发送、
手机重启后导出、AirDrop 到电脑并运行检查器；保留双端界面截图供 PR 审查。

本次交付顺序按组长确认执行：负责人本人读懂代码并运行检查后，先提交、推送分支；
真机弯举录制和检查器验证通过后再开正式 PR，并由本人填写人工验证说明，请非作者审查。
不提前开 Draft PR。真机验收通过后，#74 可使用该分支开始采集，不必等待合入。

实现依据：[Core Motion](https://developer.apple.com/documentation/coremotion/cmdevicemotion)、
[运动会话后台执行](https://developer.apple.com/documentation/healthkit/running-workout-sessions)、
[WatchConnectivity 文件传输](https://developer.apple.com/documentation/watchconnectivity/transferring-data-with-watch-connectivity)。

## 命令行检查

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

## 自动检查（Apple CI）

[`Apple` 工作流](../../.github/workflows/apple.yml) 在 PR、向 dev/main 推送且 Apple 工程或工作流变动时执行。依次检查严格格式、iOS App 与嵌入的 Watch App 构建、两个 scheme 的实际 XCTest；任一步失败都会让检查失败。

CI 使用官方 `xcode-27` runner，显式选择 Xcode **27.1（27A9275）**，测试设备固定为 **iPhone 17 / iOS 27.0** 与 **Apple Watch SE 3 (40mm) / watchOS 27.0**。版本或设备缺失时直接报错；先核对 runner 软件清单，再通过 PR 调整和复验，不切换到 runner 的默认 Xcode。环境依据 [GitHub 官方镜像说明](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)。

runner 目前仍属公开预览，底层镜像会滚动更新，容量或软件变化可能影响运行。CI 输出实际 Xcode、镜像版本和模拟器清单；测试统计见对应步骤日志。本机复现时，在上面的测试命令 destination 中追加 `,OS=27.0`，确保使用相同系统。

CI 关闭模拟器构建签名，不需要个人 Apple 账号、Team 或证书。这里只验证骨架在所列模拟器上的构建与测试；iOS 17.2.1、watchOS 10.0 的最低版本真机验收仍单独进行。骨架目前每端仅一项模块加载测试，后续业务开发需继续补测试。
