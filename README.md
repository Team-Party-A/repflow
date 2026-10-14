# RepFlow

RepFlow 是一个用 Apple Watch 自动计次的健身记录 App：开组前选好动作，组内由手表自动数次数，训练记录同步到 iPhone 和后端。

## 目录地图

```text
repflow/
├── apps/apple/   # Xcode 工程：iOS App 与 watchOS App 两个 target（SwiftUI）
├── backend/      # FastAPI 服务与测试（PostgreSQL）
├── web/          # Web 看板（如果做）
├── ml/           # 计次与识别算法、录制数据工具、训练脚本
├── deploy/       # docker compose、nginx 配置、部署脚本
├── docs/         # 正式文档：需求、设计、测试、部署
│   ├── adr/      # 架构决策记录（0001-<标题>.md）
│   └── assets/   # 文档截图与图片
├── .github/      # Issue 与 PR 模板、workflows
├── CONTRIBUTING.md  # 分支、提交、PR、Issue 规范
├── AGENTS.md        # 人和 agent 共用的工程规范
└── CLAUDE.md        # 只有一行 @AGENTS.md
```

参与开发前请先读 [CONTRIBUTING.md](CONTRIBUTING.md) 和 [AGENTS.md](AGENTS.md)。
