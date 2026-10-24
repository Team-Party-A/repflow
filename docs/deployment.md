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

check.sh 创建独立临时 Compose 项目、内部测试库和假密码，执行 ruff、pytest、覆盖率、真实数据库连接、暂停超时与故障恢复、API 更换 IP、数据卷保留检查。配置测试只修改临时 nginx 副本：拒绝非法候选配置、重建后观察新增响应头、回退重建后确认响应头消失。退出时删除该临时项目及其卷。它显式隔离部署用 `.env`，不针对现有部署运行。

CI 用 Ubuntu 24.04 两种原生架构执行相同检查；`install-ci-tools.sh` 只用于可丢弃 CI runner，从官方发布资产安装固定插件并核验 SHA-256。

CI 还执行 `python3 deploy/mirror_images.py`，核对主 Compose 中的官方固定摘要及本地镜像架构；默认模式不发布、不读取 GHCR 凭据。只有 dev/main 的 push 允许 `--publish` 或 `--manifest`，PR 事件不会同步镜像。

## 2. 首次服务器准备

以下服务器命令可由负责人执行，或由负责人明确授权的 agent 在指定服务器与任务范围内通过 SSH 执行；同一任务的已有授权持续有效，无需逐条重复确认。agent 可以在服务器直接生成服务密码并安全落盘配置，不回显明文，不读取或传播已有真实 `.env`、SSH 私钥和拉取凭据内容；个人账号登录或授权确需交互时再由负责人操作。部署工具正常使用配置，不将配置内容输出到日志或聊天。以具有 sudo 的普通 SSH 用户操作。安装脚本目前限定 Ubuntu 26.04 amd64；已有活跃的系统 Docker/containerd 服务时停止，需先由负责人审查。

SSH 授权范围在对应 Issue 留下记录。删除数据卷、修改防火墙或云安全组、sshd、sudoers 等操作须有针对该操作的明确授权，不能仅依据任务级 SSH 授权执行；已取得的具体授权不重复询问。

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

新 `.env` 可由负责人填写，或由已授权 agent 在服务器生成随机数据库密码并安全落盘，同时填入上述 API_IMAGE 摘要；创建时拒绝覆盖已有配置，权限为 600，不回显密码。PAT 在个人账号授权需要本人交互时由负责人配置，凭据不发送到聊天或提交到 Git。Docker 原生配置保存的是可还原凭据，目录权限应为 700、文件为 600；凭据到期或撤销后需重新登录才能拉取新版本，已有运行容器继续运行。CI 使用临时 GITHUB_TOKEN，服务器使用单独的只读凭据。

## 4. 启动、更新与日志

在仓库根目录操作。生产 API_IMAGE 使用工作流给出的摘要；记录代码提交、镜像摘要及配置版本。云安全组需允许 TCP 8080，api/db 不映射宿主端口。

```sh
set -eu
docker compose --env-file deploy/.env -f deploy/compose.yaml config --quiet
docker compose --env-file deploy/.env -f deploy/compose.yaml pull
docker compose --env-file deploy/.env -f deploy/compose.yaml run --rm --no-deps nginx nginx -t
docker compose --env-file deploy/.env -f deploy/compose.yaml up -d --wait --wait-timeout 120 db api
docker compose --env-file deploy/.env -f deploy/compose.yaml up -d --no-deps --force-recreate --wait --wait-timeout 120 nginx
curl --fail --silent --show-error http://127.0.0.1:8080/health
docker compose --env-file deploy/.env -f deploy/compose.yaml logs --tail 100 api nginx db
```

配置检查使用 `--quiet`，避免将展开后的密码输出到终端或日志。正常健康检查返回 `200 {"status":"ok"}`；数据库失败或超时返回 `503 {"status":"unavailable"}`，响应不缓存。nginx 仅转发 `/health`。

首次启动、更新及回退都执行上面的完整顺序。`config --quiet` 只检查 Compose；`run --rm --no-deps nginx nginx -t` 用新临时容器挂载磁盘上的候选配置，校验语法及引用文件，不占用现有入口端口。任何检查失败都停止，不执行后续 up。不要只用现有容器内的 `nginx -t` 检查候选文件：单文件 bind mount 可能仍指向被替换前的旧文件。

更新时先获取已发布提交及相配配置，再更新 `.env` 中的 API_IMAGE 为新摘要，执行上述顺序。回退时先恢复上次已验证提交的 Compose、nginx 配置和镜像摘要，再执行相同顺序。无论镜像或服务定义有没有变化，都显式重建 nginx，使它重新挂载并读取当前文件；入口会短暂中断。只 pull/up 或看到 `/health` 返回 200，不能证明新代理配置已加载。依据 [Compose 重建参数](https://docs.docker.com/reference/cli/docker/compose/up/)及 [nginx 配置检查说明](https://nginx.org/en/docs/switches.html)。

PostgreSQL 18 数据卷挂载 `/var/lib/postgresql`，跨容器保留；更新及回退保留数据库卷与当前数据库密码，删除卷会丢失集群。数据库引擎升级另行安排，业务表迁移不能代替引擎升级。

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
docker compose --env-file deploy/.env -f deploy/compose.yaml -f deploy/compose.ghcr.yaml run --rm --no-deps nginx nginx -t
docker compose --env-file deploy/.env -f deploy/compose.yaml -f deploy/compose.ghcr.yaml up -d --wait --wait-timeout 120 db api
docker compose --env-file deploy/.env -f deploy/compose.yaml -f deploy/compose.ghcr.yaml up -d --no-deps --force-recreate --wait --wait-timeout 120 nginx
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

## 6. 部署与修复验收结果

#43 的首次上线完成后，补充真实数据库暂停测试发现旧 API 在约 5 秒返回 504。该问题已由 #53 修复；当前部署使用已合入提交 `6ac6a944520c9bebd446dd90588fb6a5436d9591`，镜像来自对应 [dev 发布](https://github.com/Team-Party-A/repflow/actions/runs/40108125811)。发布的 8 个任务全部成功；amd64、arm64 均通过 ruff、14 项 pytest（语句／分支覆盖率 100%）和完整 Compose 检查，包含真实暂停数据库的 503 超时回归、故障恢复、API 换址、持久卷保留及 nginx 配置预检、更新与回退。API 和两个备用包的双架构发布、索引及发布时的 private 检查均通过。

服务器使用已验证的 GHCR 备用配置，三个镜像均完成拉取并核对为 linux/amd64；API 的 OCI revision 与上述完整提交一致：

| 服务 | GHCR 镜像 | 索引 SHA-256 |
| --- | --- | --- |
| api | `ghcr.io/team-party-a/repflow-api` | `24fe12de07c694f55cad3238ad6028088c0af2269f3b5e4dca92fa46a3766a23` |
| db | `ghcr.io/team-party-a/repflow-postgres` | `0b0844b1f07661520c0a86054babe09708700c607f0b727ea8b375ea456f3798` |
| nginx | `ghcr.io/team-party-a/repflow-nginx` | `b5fc535518439dde758b576c1370d6fb4b6b6f89895350c8224e48348e596dce` |

- Ubuntu 26.04 x86_64；Docker 29.9.2、Compose 5.6.1、Buildx 0.38.1、containerd.io 2.4.2（包修订 3）；Rootless 用户服务 active/enabled，Linger=yes。
- `.env` 权限为 600，拉取凭据目录／文件权限为 700／600；主 Compose、GHCR 备用配置和 nginx 候选配置检查通过。更新只替换非敏感的 API_IMAGE 字段，其余设置及数据库密码原样保留，不回显配置或凭据。
- nginx、api、db 正常运行，api/db healthy，只有 nginx 发布宿主 8080；外网 `/health` 返回 `200 {"status":"ok"}`，其他路径返回 404。
- 真实暂停 PostgreSQL 后，已有连接、重复请求及 API 冷启动三个场景均在约 3 秒返回 `503 {"status":"unavailable"}`，并带 `Cache-Control: no-store`；恢复数据库后回到 200。数据库停止与恢复场景也通过。具体实测耗时记录在 #33。
- 重建 api/db 后 nginx 可继续访问；退出 SSH 后重新连接，以及重启用户级 Docker 后，三个服务均恢复。数据库集群标识及持久卷与更新前一致，业务库 public schema 表数量仍为 0。
- 临时 SSH 下载转发、本机回环代理及服务器临时代理服务、Docker 代理环境变量均已撤除；撤除后重启 Docker，外网健康检查通过，服务运行不依赖本机。镜像来源、版本和摘要未改变。
- 当前及上一版记录保存在服务器私有目录 `$HOME/.local/state/repflow/deployment.json`，目录／文件权限为 700／600；配置文件摘要与验收结果一并记录。当前配置版本为 `release-6ac6a94-config-v2`。

| 角色 | 代码提交 | API 索引摘要 | 验收状态 |
| --- | --- | --- | --- |
| 当前 | `6ac6a944520c9bebd446dd90588fb6a5436d9591` | `24fe12de07c694f55cad3238ad6028088c0af2269f3b5e4dca92fa46a3766a23` | 本节部署与故障恢复检查通过 |
| 上一版 | `e935600b5c282a84bfae2e088f3e1e563f53ace9` | `16cb26cd73762af9014380b0af1afa0219fd2879c388bb383b208594293bcde0` | 正常链路通过，暂停数据库超时未通过；不能视为已全面验收的回退版本 |

本次执行了真实版本更新，未执行生产版本回退；nginx 配置回退已在双架构 CI 验证。后续更新或回退按第 4 节保留现有数据库卷和密码，并重新验证；不要仅因上一版镜像仍在缓存中就认为其所有故障场景已通过。

后端健康检查的构建、测试、私有镜像发布、部署和恢复链路已验收；#33 由验收 PR 经人工审查合入后关闭。业务表与业务接口另按客户端需求及 API 契约推进，HTTPS 在登录及客户端联调前完成。服务器地址和敏感配置不进入仓库、Issue 或 PR。
