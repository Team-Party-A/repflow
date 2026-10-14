> **草案 v0，待第 1 次组会表决**

# 贡献指南

本文件规定分支、提交信息、PR 与 Issue 的用法。人和 agent 都要遵守；agent 额外遵守 [AGENTS.md](AGENTS.md)。

## 1. 分支

| 分支 | 用途 | 规则 |
| --- | --- | --- |
| `main` | 稳定版本，对应每次阶段检查 | 受保护，只接受从 `release/*` 合入，合入即打 tag |
| `dev` | 日常集成（默认分支） | 受保护，只能经 PR 合入，CI 必须通过 |
| `feature/<模块>-<简述>` | 单个功能，如 `feature/watch-rep-counter` | 从 `dev` 拉出，完成后经 PR 合回 `dev` |
| `bugfix/<简述>` | 修复 bug | 从 `dev` 拉出，完成后经 PR 合回 `dev` |
| `release/vX.Y` | 阶段检查前冻结用 | 只修 bug，合入 `main` 和 `dev` |

- `<模块>` 取值与提交信息的 scope 一致：`watch`、`ios`、`backend`、`web`、`ml`、`deploy`、`docs`。
- `main` 和 `dev` 两个受保护分支都要开启：必须经过 PR、至少 1 名非作者批准、CI 通过、禁止强制推送。（保护规则在组会表决后配置。）
- 任何人都不直接向 `main` 或 `dev` 推送。

## 2. 提交信息

格式：

```text
<type>(<scope>): <subject>
```

示例：`feat(watch): add peak-based rep counter`

- **type**：`feat`、`fix`、`refactor`、`docs`、`style`、`test`、`perf`、`ci`、`chore`
- **scope**：`watch`、`ios`、`backend`、`web`、`ml`、`deploy`、`docs`
- **subject**：全组统一用一种语言（中文或英文，第 1 次组会决定），不混用。
- 原子化、频繁提交：一个提交只做一件事。

## 3. PR 与代码审查

- 一个 PR 对应一个 Issue，描述里写 `Closes #<编号>`。
- diff 尽量控制在 400 行以内（生成文件不算）。AI 一次生成的大块代码要拆开提交。
- 按 [PR 模板](.github/pull_request_template.md) 填写，以下各项必填：
  - 关联 Issue
  - 改了什么
  - 怎么测的及结果
  - 截图或录屏（涉及界面时）
  - **AI 参与说明**：用了哪个工具、会话名、哪些部分由 AI 生成、人工验证或改动了什么
  - 「完成的定义」勾选项
- 至少 1 名非作者成员批准后才能合入。可以用另一个 AI 工具出第二意见，但批准必须由人点。
- 审查人重点看：
  - 是否符合接口契约和本规范
  - 有没有测试
  - 有没有死代码和明文密钥
  - 作者能否解释清楚每一段代码

### 完成的定义

一个任务同时满足以下 6 条才算完成：

1. 关联了 Issue，PR 由至少 1 名非作者成员批准
2. CI 通过：格式检查、构建、单元测试
3. 新逻辑有单元测试，覆盖率没有下降
4. 相关文档已更新（API、设计、用户手册）
5. 已合入 `dev`，并在部署环境上跑通
6. Issue 已关闭，看板卡片移到 Done

## 4. Issue 与看板

- 任务一律建 Issue。微信里谈出的结论，回写到 Issue 才算数。
- Issue 模板分三种，新建时从模板选，不开空白 Issue：
  - **功能**（自动打 `type:feature`）
  - **Bug**（自动打 `type:bug`，必须写复现步骤）
  - **任务**（自动打 `type:task`）
- 标签：
  - `type:*`：`type:feature`、`type:bug`、`type:task`
  - `module:*`：`module:watch`、`module:ios`、`module:backend`、`module:web`、`module:ml`、`module:deploy`、`module:docs`
  - 优先级：`P0`（阻塞，立即处理）、`P1`（本迭代必须完成）、`P2`（有空再做）
- Milestone 对应迭代（迭代 0 到迭代 4）。
- Projects 看板分列：Backlog、Todo、In Progress、In Review、Done、Blocked。
- 每人每 2–3 天在自己的 Issue 或看板卡片上更新一次状态。
- 任务要延期，至少提前 24 小时在 Issue 里说明原因和新时间。
- 功能类 Issue 引用对应的需求编号（`REQ-xx`）。

## 5. 密钥

- `.env` 不入库，只提交 `.env.example`；CI 里的密钥放 GitHub Secrets；签名证书不入库。
- 录制的传感器数据和模型权重体积大，不直接提交，用 Git LFS 或网盘存放。
- 一旦有密钥被提交，立即更换该密钥，并通知组长。
