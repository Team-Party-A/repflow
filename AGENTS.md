# AGENTS.md

本文件是人和 agent 共用的工程规范，也是唯一的规范来源。Codex 直接读取本文件；Claude Code 通过根目录 `CLAUDE.md` 中的 `@AGENTS.md` 加载本文件。不要在 `CLAUDE.md` 里另写规则。

总原则：「做什么」和「接口长什么样」由人决定，agent 只在边界内负责「怎么实现」。谁合并的代码谁负责，每个人都要能解释自己合并进来的每一段代码。

## 1. 项目简介与模块地图

RepFlow 是一个用 Apple Watch 自动计次的健身记录 App：开组前选好动作，组内由手表自动数次数，训练记录同步到 iPhone 和后端。

| 目录 | 模块 | 内容 |
| --- | --- | --- |
| `apps/apple/` | watch、ios | Xcode 工程：iOS App 与 watchOS App 两个 target |
| `backend/` | backend | FastAPI 服务与测试 |
| `web/` | web | Web 看板（如果做） |
| `ml/` | ml | 计次与识别算法、录制数据工具、训练脚本 |
| `deploy/` | deploy | docker compose、nginx 配置、部署脚本 |
| `docs/` | docs | 正式文档；ADR 放 `docs/adr/`，截图放 `docs/assets/` |

模块目录下可以再放一份模块级 `AGENTS.md`（同时配一个只有 `@AGENTS.md` 的 `CLAUDE.md`），只写该模块特有的规则。

## 2. 技术栈与命令

> 第 8 周前不写业务代码，下表的命令在各模块搭好工程后由模块负责人填写确认。标「待定」的项目不得由 agent 自行决定。

| 模块 | 技术栈 | 构建 | 测试 | 格式化 / lint |
| --- | --- | --- | --- | --- |
| watch、ios | SwiftUI（iOS + watchOS）；部署目标 iOS 17.2、watchOS 10.0 | `xcodebuild build`（scheme 待定） | `xcodebuild test`（XCTest、XCUITest） | SwiftFormat 或 SwiftLint（二选一，待定） |
| backend | FastAPI + PostgreSQL | `docker build --target runtime -t repflow-api:local backend`（仓库根目录） | `uv run --locked pytest --cov=app`（backend 内，需测试库） | `uv run --locked ruff format`、`uv run --locked ruff check` |
| ml | Python | — | `pytest` | `ruff format`、`ruff check` |
| web | 待定 | 待定 | Cypress | ESLint + Prettier |
| deploy | docker compose + nginx | Backend CI 构建并发布镜像 | `API_IMAGE=… TEST_IMAGE=… sh deploy/check.sh`（仓库根目录） | — |

系统支持范围：工程的 Deployment Target 为 iOS 17.2、watchOS 10.0（Xcode 只能填到次版本号）；兼容验证基线为 iOS 17.2.1、watchOS 10.0 真机，最低版本验收在基线真机上做。

## 3. 编码规范

### 3.1 命名

- Swift：类型用 `UpperCamelCase`，变量和函数用 `lowerCamelCase`；Python：函数和变量用 `snake_case`，类用 `PascalCase`，常量用 `UPPER_SNAKE_CASE`。
- 名字说清用途，不用缩写和单字母（循环下标除外）。
- 术语与 `docs/` 中的术语表一致（「组」「次」「动作」「训练」）。

```swift
struct WorkoutSet {
    let exercise: Exercise
    var repCount: Int
}
```

```python
MAX_REPS_PER_SET = 100

def count_reps(samples: list[AccelSample]) -> int: ...
```

### 3.2 错误处理

- 只在真会失败的边界处理错误：网络、IO、解析、外部输入。内部纯函数不包。
- 错误信息要具体，包含关键变量；不吞异常，不写空的 `catch` / `except`。

```swift
do {
    try await api.upload(session)
} catch {
    logger.error("upload session failed: id=\(session.id), error=\(error)")
    throw SyncError.uploadFailed(sessionID: session.id)
}
```

```python
from fastapi import HTTPException

session = db.get(WorkoutSession, session_id)
if session is None:
    raise HTTPException(status_code=404, detail=f"session {session_id} not found")
```

### 3.3 日志

- 不用 `print`。Swift 用 `os.Logger`，Python 用标准库 `logging`。
- 生产环境不输出 debug 级日志；日志里不出现密钥、token、密码。

```swift
import os
private let logger = Logger(subsystem: "repflow", category: "sync")
logger.info("sync finished: uploaded=\(count)")
```

```python
import logging
logger = logging.getLogger(__name__)
logger.info("sync finished: uploaded=%d", count)
```

### 3.4 注释

- 注释解释「为什么」和不明显的决策，不复述代码在做什么。
- 不留注释掉的代码和死代码。

```python
# 手表加速度计在 50 Hz 下抖动明显，先做 5 点滑动平均再找峰值
smoothed = moving_average(samples, window=5)
```

## 4. 分支与提交规范

与 [CONTRIBUTING.md](CONTRIBUTING.md) 一致，摘要如下：

- 从 `dev` 拉出 `feature/<模块>-<简述>` 或 `bugfix/<简述>`，完成后经 PR 合回 `dev`。
- 提交信息：`<type>(<scope>): <subject>`，例如 `feat(watch): 新增基于峰值的计次`。
  - type：`feat`、`fix`、`refactor`、`docs`、`style`、`test`、`perf`、`ci`、`chore`
  - scope：`watch`、`ios`、`backend`、`web`、`ml`、`deploy`、`docs`
  - subject、PR 描述和文档以中文为主；代码标识符、命令和专有名词保持原文。
- PR 标题必须符合上面的提交信息格式：`dev` 和 `main` 只允许 squash 合并，squash commit 默认用 PR 标题。
- 一个提交只做一件事；一个 PR 只对应一个 Issue，diff 尽量不超过 400 行。

## 5. 接口契约

以下文件是各模块之间的契约，**agent 不得擅自修改**。改契约必须走 PR，并经所有受影响模块的负责人批准。

| 契约 | 位置 | 状态 |
| --- | --- | --- |
| 后端 API | `docs/api/openapi.yaml` | 第 8 周前写好并冻结 |
| 传感器录制数据格式 | `docs/data/01-sensor-recording-format.md` | 第 8 周冻结 |

客户端按契约实现；后端还没完成时，客户端先连 mock server。

## 6. 禁止事项

- 不改其他模块的代码。
- 不提交密钥、`.env`、签名证书；只提交 `.env.example`。
- 不擅自新增依赖；确需新增，停下来写进 PR 的「待决问题」，由人决定。
- 不删除、不跳过已有测试。
- 不推送到 `dev` 和 `main`。
- 不做大规模重构、不删除文件，除非人已在 Issue 或对话中明确确认。
- 不索取、不使用生产服务器的 SSH 权限和服务器上的 `.env`。

## 7. 实现原则

1. **选最简单的可行实现。** Issue 没要求的，不引入抽象层，也不新增依赖。
2. **遇到以下情况，停下来，写进 PR 描述的「待决问题」，不自行拍板：**
   - 需要改接口契约
   - 需要新增依赖
   - 需要改目录结构或 CI 配置
   - 需求有歧义
3. **Issue 操作有边界。**
   - **新建**：可以新建 Issue。必须选模板（功能、Bug、任务），填好标签、Milestone 和验收标准；正文末尾写「由 <Claude Code / Codex> 起草，会话：<会话名>」。一次会话要建超过 3 个时，先把清单给人确认再建。别人模块的问题可以建 Issue 并 @ 该模块负责人，但不改他的代码。
   - **开工**：agent 新建的 Issue，要等负责人确认验收标准、拖到 Todo 之后，才能开始实现。
   - **修复**：从 `dev` 拉 `feature/*` 或 `bugfix/*` 分支，实现并写测试，推送该分支，开 PR 并写 `Closes #N`。不合并 PR。
   - **关闭**：做完的 Issue 只能靠合入 PR 时的 `Closes #N` 自动关闭，不手动关。手动关闭只限三种情况：重复、无法复现、已不需要。关闭前必须评论写明原因（重复的附上原 Issue 链接），并 @ 负责人。
   - **看板**：不改 Status 字段。新建进 Backlog、关闭进 Done，都由 Project 的内置工作流自动完成。
   - 收工前在 Issue 下写一条进度评论。

## 8. 单个任务的工作流

1. 人在 Issue 里写清目标和验收标准；也可以由 agent 起草，负责人确认验收标准后才开工（见第 7 条第 3 点）。
2. 从 `dev` 拉出 feature 分支。
3. agent 根据 Issue 和相关文件实现，同时写单元测试。
4. 作者逐段读懂代码，在本地跑通测试和格式化；看不懂的地方让 agent 解释。
5. 按规范提交，开 PR（人或 agent 都可以开），填写模板（包括 AI 参与说明）。
6. 另一名成员审查，批准由人点。
7. CI 通过后由人以 squash 方式合入，Issue 经 `Closes #N` 自动关闭，分支自动删除。

第 6 步「另一名成员审查」只有一个例外：Wiki [团队章程](https://github.com/Team-Party-A/repflow/wiki/团队章程)「组长职责」一节的紧急通道，组长可以经 PR 绕过审查合入（仍不能直推或强推），适用条件和事后要求以章程为准。工程规范以本文件为准，团队分工和组长权限以章程为准。agent 不得使用紧急通道，也不得以它为由合并 PR。

## 9. 交付前必须跑通的检查

交付任务（提交或开 PR）前，在改动涉及的模块里跑通以下检查，并把结果写进 PR 的「怎么测的及结果」：

| 模块 | 检查命令 |
| --- | --- |
| backend | `uv run --locked ruff format --check . && uv run --locked ruff check . && uv run --locked pytest --cov=app`（uv 0.13.5，需测试库；完整容器命令见 [部署说明](docs/deployment.md)） |
| ml | `ruff format --check . && ruff check . && pytest` |
| watch、ios | SwiftFormat / SwiftLint 检查（待定） + `xcodebuild test`（scheme 与 destination 待定） |
| web | ESLint + Prettier 检查 + 构建（命令待定） |
| deploy | `docker compose config --quiet`（指定配置和环境变量，见 [部署说明](docs/deployment.md)）及 `sh deploy/check.sh` |

任何一项失败都不能交付；不能为了通过检查而删除或跳过测试。
