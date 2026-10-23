# ADR 0002：后端骨架的构建、发布与部署

状态：后端负责人已逐项确认，待本 PR 非作者审查。日期：2026-10-23。
负责人：@hulaoyagg；审查：@shooterli；关联 [#33](https://github.com/Team-Party-A/repflow/issues/33)。

## 1. 背景

先证明部署链路可用，为中期演示提供检查数据库的 `/health`。业务表及业务接口在客户端需求、契约对齐后设计。Python、FastAPI、数据库访问与认证选型沿用 [ADR 0001](0001-backend-stack.md)。

## 2. 可选方案与决定

| 事项 | 本次决定及取舍 |
| --- | --- |
| 安装来源 | Docker 官方 apt 仓库，固定软件包版本；需要维护额外软件源并主动安排升级。 |
| Docker 权限 | Rootless＋用户级 systemd＋linger，降低守护进程权限；需要 uidmap、用户服务及 Rootless 网络支持。 |
| 对外入口 | HTTP 8080 演示健康检查，保留系统低端口限制；登录和客户端联调前落实 HTTPS。 |
| 镜像基底 | Debian 13 Trixie，API 用 slim；接受较大的基础镜像，优先兼顾原生扩展预编译包兼容性。slim 没有完整编译工具链，新增依赖需验证。 |
| 构建位置 | CI 构建，服务器拉取；节省服务器构建资源，增加镜像仓库和发布流程维护。 |
| 镜像可见性 | 私有 GHCR；服务器需维护只读拉取凭据。CI 在发布前后核实包可见性，权限或网络错误直接失败。 |
| 发布时机 | 仅合入 dev/main 后发布；PR 阶段没有候选镜像，服务器部署验收在合入后补充。 |
| 架构 | amd64、arm64 原生构建及测试，覆盖服务器与 Apple Silicon；需要维护两套 CI 结果。 |
| Docker Hub 备用 | CI 把官方固定摘要的 PostgreSQL/nginx 同步到私有 GHCR，负责人已在本次评审后确认；多维护两个包和双架构同步，服务器可手工切换到已验证的 GHCR 摘要。默认官方源保持不变。 |

## 3. 固定版本与初始参数

- Engine、CLI、rootless-extras：29.9.2；containerd.io：2.4.2（Ubuntu 软件包修订 3）；Compose：5.6.1；Buildx：0.38.1。
- 镜像：Python 3.14.9-slim-trixie、PostgreSQL 18.6-trixie、nginx 1.30.6-trixie、uv 0.13.5，均记录多架构清单摘要。
- 开发工具：ruff 0.17.2、pytest 9.1.1、pytest-asyncio 1.4.0、HTTPX 0.28.1、pytest-cov 7.1.0；进入开发依赖组和 uv.lock。
- 一个 Uvicorn worker，SQLAlchemy 连接池大小 2、max_overflow 0，健康检查超时预算 3 秒。这些是骨架起点，不是业务吞吐量结论。
- CI 使用 Ubuntu 24.04 amd64/arm64 托管 runner，记录其预装 Docker 版本；Compose、Buildx 与项目运行环境固定。目标 Ubuntu 26.04 Rootless 环境单独验收。

## 4. 后果与维护

软件包固定后通过 PR、测试安排升级；Docker 软件包设置 apt hold，系统辅助包沿用 Ubuntu 维护。镜像摘要固定意味着基础系统补丁也需更新摘要、重建与测试。

CI 仅在发布任务授予 packages:write，使用短期 GITHUB_TOKEN。服务器由负责人交互配置 classic PAT 的 read:packages 权限；原生 Docker 登录凭据可从配置中还原，应限制配置目录及文件权限，并维护到期、更换和撤销。凭据不进入镜像或仓库。

发布镜像带完整提交号，实际部署按不可变摘要，并记录相配的代码、配置版本。回退保留数据库卷。Rootless 默认端口转发不能直接作为真实客户端 IP 审计依据，后续限流或审计需求需重新验证。

备用同步复用现有 Docker CLI、已固定的 Buildx/Compose 和 Python 标准库，不新增工具依赖；CI 宿主 Docker 继续使用 runner 预装版本并记录。官方源版本、摘要只从主 Compose 读取，不重建上游镜像；逐架构核对配置摘要（其中包含文件系统层的未压缩摘要），再生成包含 amd64、arm64 的 GHCR 索引。新索引摘要单独记录，不能把 Docker Hub 索引摘要直接填成 GHCR 摘要。备用同步仅在 dev/main 推送检查通过后执行，与 API 发布任务独立；失败会明确标红，不能把尚未成功的同步当作可用备用源。

本次数据库仅用于空库健康检查，Alembic 迁移仅在独立测试 schema 验证。业务接入时再设计表结构、应用及迁移账号权限、备份恢复和密码校验并发参数。

操作与验收见[部署说明](../deployment.md)。
