# 后端骨架部署与验收

关联 #33，选型及维护影响见 [ADR 0002](adr/0002-backend-deployment.md)。
入口为 HTTP 8080 的 `/health`，nginx → api → db；业务接口和业务表后续按契约实现。服务器地址在个人 SSH 配置中管理，本文及 Issue/PR 只记录脱敏结果。

## 1. 本地与 CI 检查

在仓库根目录运行，复用已有 Docker。项目要求 uv 0.13.5；已有其他版本时可运行 `uv tool run --from uv==0.13.5 uv sync --project backend --locked`，后续 uv 命令也可使用同样前缀，隔离运行固定版本。

```sh
set -eu
docker build --target test -t repflow-tests:local backend
docker build --target runtime -t repflow-api:local backend
API_IMAGE=repflow-api:local TEST_IMAGE=repflow-tests:local sh deploy/check.sh
python3 -m unittest discover -s deploy -p 'test_*.py' -v
```

check.sh 创建独立临时 Compose 项目、内部测试库和假密码，执行 ruff、pytest、覆盖率、真实数据库连接、故障恢复、API 更换 IP、数据卷保留检查，退出时删除该临时项目及其卷。它显式隔离部署用 `.env`，不针对现有部署运行。

CI 用 Ubuntu 24.04 两种原生架构执行相同检查；`install-ci-tools.sh` 只用于可丢弃 CI runner，从官方发布资产安装固定插件并核验 SHA-256。

CI 还执行 `python3 deploy/mirror_images.py`，核对主 Compose 中的官方固定摘要及本地镜像架构；默认模式不发布、不读取 GHCR 凭据。只有 dev/main 的 push 允许 `--publish` 或 `--manifest`，PR 事件不会同步镜像。

## 2. 首次服务器准备

以下服务器命令由负责人本人执行；agent 准备命令与文档、协助分析脱敏结果，不连接生产服务器或读取服务器上的真实 `.env`、拉取凭据。以具有 sudo 的普通 SSH 用户操作。安装脚本目前限定 Ubuntu 26.04 amd64；已有活跃的系统 Docker/containerd 服务时停止，需先由负责人审查。

```sh
git clone --branch dev https://github.com/Team-Party-A/repflow.git "$HOME/repflow"
cd "$HOME/repflow"
sh deploy/install-rootless-docker.sh
docker --context rootless info --format 'Engine={{.ServerVersion}} Security={{json .SecurityOptions}}'
loginctl show-user "$(id -un)" -p Linger
```

安装包含官方 apt 源、固定版本 Docker 六个软件包、uidmap 等系统辅助包、用户服务与 linger；系统级 Docker/containerd 单元屏蔽，项目使用用户级 rootless context。退出 SSH、重新登录后再验证服务仍在运行。更新固定软件包需评审版本、解除对应 apt hold、指定版本安装并重新 hold；部署记录包含实际包版本。

## 3. 合入后发布与私有镜像拉取

PR 只构建测试。人合入 dev/main 后，Backend 工作流在两种架构检查成功后发布私有 `ghcr.io/team-party-a/repflow-api`，标签为 `sha-完整提交号`，最后汇总多架构清单。Manifest 任务摘要给出 `API_IMAGE=...@sha256:...`。

独立的 Backup mirror 两种架构任务同步官方 PostgreSQL/nginx，Backup mirror index 汇总已验证的双架构索引，并输出 `POSTGRES_IMAGE`、`NGINX_IMAGE` 的 GHCR 摘要和对应官方来源。两个备用包分别为 `repflow-postgres`、`repflow-nginx`，也必须保持 private、授权本仓库工作流访问。备用任务失败不阻断独立的 API 发布任务，但工作流会报错，首次真实发布仍须验收。

若组织策略阻止包创建或工作流访问，负责人协调组长授予该仓库包发布权限。包保持 private，继承源仓库访问权限；发布前后可见性检查必须通过。

负责人在 GitHub 官方 token 页面创建 classic PAT，仅选择 read:packages 并设置到期日；在服务器交互登录，密码提示中输入 PAT：

```sh
docker login ghcr.io --username YOUR_GITHUB_USERNAME
chmod 700 "$HOME/.docker"
chmod 600 "$HOME/.docker/config.json"
umask 077
cp -n deploy/.env.example deploy/.env
chmod 600 deploy/.env
```

用编辑器填写新 `.env` 的数据库密码和上述 API_IMAGE 摘要。PAT、实际密码均由人配置，不发送到聊天或提交到 Git。Docker 原生配置保存的是可还原凭据；凭据到期或撤销后需重新登录才能拉取新版本，已有运行容器继续运行。CI 使用临时 GITHUB_TOKEN，服务器使用单独的只读凭据。

## 4. 启动、更新与日志

在仓库根目录操作。生产 API_IMAGE 使用工作流给出的摘要；记录代码提交、镜像摘要及配置版本。云安全组需允许 TCP 8080，api/db 不映射宿主端口。

```sh
set -eu
docker compose --env-file deploy/.env -f deploy/compose.yaml config --quiet
docker compose --env-file deploy/.env -f deploy/compose.yaml pull
docker compose --env-file deploy/.env -f deploy/compose.yaml up -d --wait --wait-timeout 120
curl --fail --silent --show-error http://127.0.0.1:8080/health
docker compose --env-file deploy/.env -f deploy/compose.yaml logs --tail 100 api nginx db
```

配置检查使用 `--quiet`，避免将展开后的密码输出到终端或日志。正常健康检查返回 `200 {"status":"ok"}`；数据库失败或超时返回 `503 {"status":"unavailable"}`，响应不缓存。nginx 仅转发 `/health`。

更新时先获取已发布提交及相配配置，再更新 `.env` 中的 API_IMAGE 为新摘要，重复配置检查、pull 和 up。PostgreSQL 18 数据卷挂载 `/var/lib/postgresql`，跨容器保留；删除卷会丢失集群。回退使用上次已验证的提交、配置及 API_IMAGE，保留数据库卷与当前数据库密码。数据库引擎升级另行安排，业务表迁移不能代替引擎升级。

负责人在服务器私有目录 `$HOME/.local/state/repflow/` 维护部署记录，目录权限 700，记录不含密码或 PAT。每次验收成功后更新以下两行；配置版本需能找到对应的 Compose、nginx 配置和人工维护的环境配置版本，回退前核对数据库密码仍匹配原卷。

| 角色 | 代码完整提交号 | API_IMAGE 摘要 | 配置版本 | 验收时间及结果 |
| --- | --- | --- | --- | --- |
| 当前 | 首次部署时填写 | 首次部署时填写 | 首次部署时填写 | 待验收 |
| 上一版 | 首次部署暂无 | 首次部署暂无 | 首次部署暂无 | 暂无 |

### Docker Hub 不可达时使用 GHCR 备用

先确认 Backup mirror index 任务成功，由负责人把任务摘要给出的 `POSTGRES_IMAGE`、`NGINX_IMAGE` 填入真实 `.env`。同步沿用主 Compose 中的版本和官方来源摘要，不重建镜像；GHCR 索引摘要可能与官方索引不同，必须使用任务实际输出，不能自行替换镜像域名后沿用旧摘要。

```sh
set -eu
docker compose --env-file deploy/.env -f deploy/compose.yaml -f deploy/compose.ghcr.yaml config --quiet
docker compose --env-file deploy/.env -f deploy/compose.yaml -f deploy/compose.ghcr.yaml pull
docker compose --env-file deploy/.env -f deploy/compose.yaml -f deploy/compose.ghcr.yaml up -d --wait --wait-timeout 120
curl --fail --silent --show-error http://127.0.0.1:8080/health
```

切换后，启动、更新、日志及回退都沿用这两个 `-f` 参数，并在部署记录中保存三个镜像摘要及是否启用备用配置。项目名、网络和数据库卷不变；不删除卷。恢复官方源时先拉取主 Compose 的官方镜像，再不带备用配置执行 up。此方案仍依赖 CI 能从 Docker Hub 拉取源镜像，实际同步、服务器只读凭据拉取及备用三服务启动须在合入后验证。

## 5. 交付验收记录

- PR 阶段附两种架构 CI 链接、格式检查/pytest/覆盖率结果及 Compose 恢复检查结果。
- 合入后附 GHCR 发布运行、提交号和摘要；服务器地址、配置和凭据均省略。
- 核实两个备用包为 private、两种架构内容核对成功，记录实际 GHCR 摘要；实际使用备用配置时，再补服务器拉取及三服务健康检查结果。
- 服务器验证外网 GET /health 为 200、其他入口为 404，只有 nginx 映射 8080。
- 退出 SSH 后重连，以及 `systemctl --user restart docker` 后，确认三个服务恢复、健康检查成功且数据库卷保留。
- 记录部署、更新、回退的实际结果；尚未执行的项目写明待验收。骨架 PR 使用 `Refs #33`，合入后保留任务开放；部署验收完成后，由后续验收 PR 使用 `Closes #33` 完成闭环。

本次未部署业务接口；HTTPS 在登录及客户端联调前落实。当前空库角色用于骨架验证，实际数据接入前补业务权限、备份恢复及资源参数验证。
