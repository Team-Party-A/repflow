# ADR 0001：后端技术栈与登录会话

状态：提案，后端负责人已逐项确认，待非作者审查。日期：2026-10-23。
负责人：hulaoya（@hulaoyagg）；审查：@wenshare71；关联 [#30](https://github.com/Team-Party-A/repflow/issues/30)。

## 1. 背景

D-04 已确定 FastAPI、PostgreSQL、Docker Compose 和 nginx；本 ADR 补齐后端动手前的工具、版本和认证方案，作为 [#32 接口契约](https://github.com/Team-Party-A/repflow/issues/32) 与 [#33 后端骨架](https://github.com/Team-Party-A/repflow/issues/33) 的输入。服务端选型由后端负责人决定，接口仍需与受影响模块共同评审。

当前业务是用户名、密码登录，以及手机向后端单向上传训练记录。手机先在本地保存，断网可以继续记录、查看和修改，恢复联网后上传；退出登录保留按账号隔离的记录。依据见 [iOS 需求](../requirements/01-ios.md)、[后端与同步需求](../requirements/03-backend.md)和[全局需求](../requirements/需求规格说明书.md)。

2026-10-22 经授权只读检查部署环境：Ubuntu 26.04 LTS、x86_64、2 vCPU、约 3.6 GiB 内存、约 79 GiB 可用磁盘，宿主 Python 为 3.14.4；未发现 Docker、uv、psql 或 nginx 命令。这些是当时的环境信息，不代表已安装或验证下列组合。项目 Python 可由 uv 和容器独立管理。

本次交付选型和推进计划。训练表结构随客户端需求及冻结后的契约设计；业务接口、服务器安装和 CI 实现在各自任务中推进。

## 2. 可选方案

| 事项 | 比较过的方案 | 本次取舍 |
| --- | --- | --- |
| Python | 3.14、3.13 | 选 3.14。仍在常规修复期；3.13 已进入安全维护期。新增库需核验 3.14 兼容性。 |
| 依赖管理 | uv；venv + pip | 选 uv，用清单和锁文件统一环境；需要学习 uv 命令，并维护锁文件。 |
| 数据库访问 | SQLAlchemy；直接写 SQL | 选 SQLAlchemy，统一模型、查询和事务工具；需要学习 Session 和事务边界。 |
| 执行方式 | 同步 Session；AsyncSession | 选 AsyncSession，以 async/await 组织数据库 I/O；接受异步调用、数据加载和测试的额外约束。当前没有本项目性能测量结论。 |
| PostgreSQL 驱动 | psycopg 3；asyncpg | 选 psycopg 3，应用使用异步连接，管理或迁移脚本也能复用同步连接。binary 安装项减少本地编译和客户端库安装工作。 |
| 表结构迁移 | Alembic；手写 SQL 并自行维护版本 | 选 Alembic，版本与执行顺序进入 Git；自动生成的脚本仍需人工审查。 |
| 密码哈希 | Argon2id + pwdlib；直接调用 argon2-cffi | 选 pwdlib，使用其校验和哈希更新接口；代价是增加一层轻量包装。 |
| 登录凭证 | 随机 token + 数据库会话；JWT + 撤销状态检查 | 选随机 token。单个后端且要求在线注销立即撤销，数据库会话更直接；每次认证需要查库。JWT 为满足同样的撤销要求，也需服务端状态及签名管理。 |
| PostgreSQL | 18.6；17.11 | 选 18.6。18 系列支持至 2030-11，17 系列至 2029-11。 |
| 运行服务器 | 直接运行 Uvicorn；Gunicorn + uvicorn-worker | 选 Uvicorn，配合 Compose 和 nginx；以后可配置多个 worker，具体数量通过测量确定。 |

版本维护依据：[Python 版本状态](https://devguide.python.org/versions/)、[PostgreSQL 支持周期](https://www.postgresql.org/support/versioning/)。JWT 的提前失效处理见 [OWASP REST Security](https://cheatsheetseries.owasp.org/cheatsheets/REST_Security_Cheat_Sheet.html#jwt)。

## 3. 决定

### 3.1 初始版本基准

| 组件 | 固定版本 / 安装项 | 用途 |
| --- | --- | --- |
| Python | [3.14.9](https://www.python.org/downloads/release/python-3149/) | 项目运行环境，采用常规 CPython 构建。 |
| uv | [0.13.5](https://github.com/astral-sh/uv/releases/tag/0.13.5) | 依赖解析、锁定和虚拟环境管理。 |
| FastAPI | [0.159.1](https://github.com/fastapi/fastapi/releases/tag/0.159.1) | API 路由和请求处理。 |
| Pydantic | [2.14.1](https://github.com/pydantic/pydantic/releases/tag/v2.14.1) | 按 v2 用法定义输入、输出模型。 |
| Uvicorn | [0.54.0](https://github.com/Kludex/uvicorn/releases/tag/0.54.0) | 运行异步 FastAPI 应用。 |
| SQLAlchemy | [sqlalchemy\[asyncio\] 2.1.6](https://pypi.org/project/SQLAlchemy/2.1.6/) | 异步引擎、Session、查询和事务。 |
| psycopg | [psycopg\[binary\] 3.3.6](https://pypi.org/project/psycopg/3.3.6/) | PostgreSQL 驱动。 |
| Alembic | [1.20.1](https://pypi.org/project/alembic/1.20.1/) | 表结构迁移。 |
| 密码哈希 | [pwdlib\[argon2\] 0.3.1](https://pypi.org/project/pwdlib/0.3.1/) + [argon2-cffi 25.1.0](https://pypi.org/project/argon2-cffi/25.1.0/) | Argon2id 哈希、校验及更新。 |
| PostgreSQL | [18.6](https://www.postgresql.org/docs/release/18.6/) | 业务数据和登录会话持久化。 |

上述版本由后端负责人确认，已核对官方发布信息；尚未完成组合安装、数据库连接或容器运行验证。#33 负责验证并落实锁文件；若组合验证失败，回到选型评审调整版本，不将本表当作测试通过记录。

### 3.2 版本与依赖管理

- 后端用 `pyproject.toml` 声明依赖，提交 `uv.lock`；Python 范围设为 `>=3.14,<3.15`，`.python-version` 固定 `3.14.9`，本地、CI 和 API 容器统一基准。
- 安装使用 `uv sync --locked`，按锁文件运行检查，例如 `uv run --locked pytest`；清单与锁文件不一致时应失败。`.venv` 不入库。
- FastAPI、Uvicorn 初始使用基础安装项。SQLAlchemy 的 `[asyncio]` 会引入必需的 greenlet；psycopg 的 `[binary]` 会引入匹配版本的预编译组件。传递依赖由 uv 解析并一起锁定，不手工维护第二套版本清单。
- 补丁及其他版本升级均通过 PR，核验锁文件变化并运行相关测试，再更新环境。Python、uv 和容器镜像使用明确版本；镜像具体标签与摘要在 #33 确认，避免部署时版本随 `latest` 变化。

uv 的锁文件及 `--locked` 行为见[官方说明](https://docs.astral.sh/uv/concepts/projects/sync/)。这些约定用于后端；只开发客户端的成员无需因此安装 Python 工具。

### 3.3 数据库访问与密码校验

应用使用 `create_async_engine`、`postgresql+psycopg` 和 `AsyncSession`。每个请求及并发任务使用独立 Session，显式组织事务与数据加载；同步数据库调用不能直接阻塞异步路由。连接池由 SQLAlchemy 统一管理，上限结合 worker 数量和服务器资源在 #33 验证。

Alembic 管理业务表结构的版本变更，可以复用 psycopg 的同步连接执行迁移。修改模型时提交对应迁移脚本，发布时执行已审查的迁移；字段改名等自动生成不可靠的操作必须人工核对。采用异步访问不意味着已经确定训练表结构。

密码使用 Argon2id，由 pwdlib 调用 argon2-cffi；数据库保存含盐及算法参数的哈希。哈希计算和校验交给线程池，避免阻塞异步事件循环；计算参数和并发用量在目标资源条件下实测，遵循 [OWASP 的参数建议](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html#argon2id)。以后升级算法或参数时，在用户成功登录后校验并更新旧哈希。

实现依据：[SQLAlchemy 异步 Session](https://docs.sqlalchemy.org/en/21/orm/extensions/asyncio.html)、[psycopg 的同步 / 异步支持](https://docs.sqlalchemy.org/en/21/dialects/postgresql.html#psycopg)、[Alembic 自动生成限制](https://alembic.sqlalchemy.org/en/latest/autogenerate.html)、[pwdlib 哈希更新](https://frankie567.github.io/pwdlib/guide/#verify-and-update-a-password)。

### 3.4 登录会话与退出行为

1. 每次成功登录生成新的随机 token，使用 Python 标准库 `secrets.token_urlsafe(32)`，随机量为 32 字节（256 位）。登录结果通过 HTTPS 将 token 交给手机。
2. PostgreSQL 只保存 token 的完整 SHA-256 摘要，以及账号归属、签发时间、到期时间和撤销状态。原始 token 不持久化到后端数据库或日志。随机高熵 token 使用快速摘要；用户密码仍使用 Argon2id。
3. token 从签发起固定有效 **365 × 24 小时**，不自动续期，也不因请求活跃而延长。到期判定由服务器执行，客户端时间不能延长会话。
4. 每个受保护请求校验会话存在、未撤销且未到期；数据归属来自已验证的会话，不能相信请求自行指定的账号。缺失、无效、已撤销或过期的 token 返回 HTTP `401`，携带 `WWW-Authenticate: Bearer`；统一错误正文在 #32 定义。
5. 在线注销仅撤销本次登录凭证。服务器提交撤销后才返回成功，此后旧 token 的新鉴权请求被拒绝；其他登录会话保持有效。
6. 手机离线或注销请求未成功时，允许本地退出：清除该账号 token、停止其上传、保留按账号隔离的训练记录。退出后本机不保留旧 token 用于补发撤销。服务端撤销未获确认时，旧凭证可能继续有效至原定到期日，最长为 365 天。
7. 断网本身不触发退出。原账号的本地训练可继续记录、查看和修改；token 过期影响后端访问，本地记录保留。重新登录同一账号后继续上传，不能把账号 A 的待同步记录作为 B 的数据上传。

token 生成、摘要存储与传递方式依据：[Python secrets](https://docs.python.org/3.14/library/secrets.html)、[OWASP 会话存储](https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html#server-side-session-token-storage)、[Bearer 传递与失效响应](https://www.rfc-editor.org/rfc/rfc6750.html)。

## 4. 后果

### 4.1 开发与维护成本

- 异步方案需要正确处理 await、Session 生命周期、事务及数据加载。选择异步是代码组织方式的决定，吞吐量和延迟仍需测量；增加 worker 也会增加内存与数据库连接用量。
- uv 多一个需要维护的工具，换取一致的安装结果；以后更换依赖管理工具，需要调整锁定、构建和检查命令。数据库访问库或驱动的更换也需要验证类型转换、事务和错误处理。
- psycopg binary 包自带客户端库。更新其内置库需要升级相应包并重建镜像；单独更新宿主库不能代替这一步，见[安装说明](https://www.psycopg.org/psycopg3/docs/basic/install.html#binary-installation)。
- 固定一年有效期减少重复登录，也延长未撤销凭证可被使用的时间。在线注销立即撤销当前会话；离线退出无法保证服务端已撤销，这是本次明确接受的取舍。
- PostgreSQL 同一大版本的补丁升级通常可保留数据目录；跨大版本升级需要备份及 `pg_upgrade` 或导出恢复等迁移安排。Alembic 的业务表迁移不能替代数据库引擎升级，见[官方升级说明](https://www.postgresql.org/docs/current/upgrading.html)。

### 4.2 对其他模块的影响

| 场景 / 模块 | 需要对齐的行为 |
| --- | --- |
| iOS 注册、登录 | 首次注册和登录需联网；成功响应提供 token、稳定的用户标识及到期信息，字段在 #32 冻结。客户端把 token 当作不透明凭证，账号信息从登录响应取得。 |
| iOS 保存与发送凭证 | token 存 Keychain；通过 HTTPS，在 `Authorization: Bearer <token>` 请求头发送；本机不保存密码，密码和 token 不进入日志。 |
| iOS 凭证失效 | 收到 `401` 后停止使用旧凭证重试，提示重新登录，并保留账号归属及本地待同步记录；网络失败单独处理。重新登录同一账号后继续同步。 |
| iOS 离线使用 | 已登录账号断网时继续本地训练；凭证到期也保留本地记录。主动退出回登录页，清除 token、保留记录；有待同步记录时沿用现有退出提示。 |
| watchOS | 手表经手机上传后端，不承担后端 token 管理。手机未登录时不确认接收手表的新记录，记录留在手表等待后续交接，沿用 #34 与现有需求。 |
| 其他客户端 | Python、数据库和驱动版本由后端维护；客户端遵守 HTTP 契约。后续 Web 认证交互随其需求评审，服务端仍按已验证账号检查数据权限。 |

后端选型不提高[全局需求](../requirements/需求规格说明书.md)约定的 iOS 17.2.1、watchOS 10.0 兼容验证门槛。#32 需由后端和 iOS 共同评审认证字段、状态码与退出行为，本 ADR 不直接修改接口契约。

### 4.3 推进计划与待验证事项

1. **#30**：以本 ADR 提交 PR，由非作者审查、人合入 `dev`；当前状态为提案，不代表已完成部署或团队审查。
2. **#32 / #34**：按本 ADR 对齐账号、Bearer 凭证、`401` 与注销行为；记录 UUID、revision、删除传播等以相应契约评审结果为准。训练业务表结构在客户端需求和契约明确后设计。
3. **#33**：先搭无业务接口的 FastAPI / PostgreSQL 骨架。验证锁文件安装、应用启动、异步数据库连接、Alembic 测试库迁移、Argon2id 哈希与校验；完成检查数据库的 `/health`、后端 CI、Compose + nginx 和部署说明。骨架健康检查可以先于训练业务表完成。
4. **账号与同步实现阶段**：验证登录、认证失效、单会话撤销、离线退出、跨账号隔离，以及重新登录后补传；使用可控制时间的测试覆盖 365 天边界，无需实际等待。业务实现按后续任务和已冻结契约进行。

待 #33 实测或确认：

- 版本组合能否在开发机和目标 Linux x86_64 环境安装、运行；greenlet 等传递依赖的准确版本及预编译包可用性，由锁文件记录。
- Docker Engine、Compose、nginx 的具体版本，以及镜像基底、标签和摘要：执行部署前逐项说明影响并确认；当前未完成安装。
- worker 数、数据库连接池上限、密码哈希参数与并发限制：结合 2 vCPU、约 3.6 GiB 内存和实际测量确定，不照搬默认并发数。
- `ruff`、`pytest` 及必要测试工具的版本与执行命令，在骨架 PR 中落实。检查遵循 AGENTS.md；本 ADR 不新增工作流或项目依赖文件。

这些待验证事项不改变已确认的选型；验证发现不兼容或需求变化时，通过后续 PR 更新 ADR 和相关契约。
