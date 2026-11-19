# 后端骨架部署与验收

关联 #33，选型及维护影响见 [ADR 0002](adr/0002-backend-deployment.md)。
第 1–6 节保留已上线骨架的操作与记录；#61 公网 IP HTTPS 方案和待验收项见第 7 节。
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

本节命令用于原 HTTP 骨架。启用第 7 节 HTTPS 后，更新时必须同时加载 TLS 配置；仅使用本节配置重建 nginx 会回退到 HTTP。日常 TLS 配置更新使用第 7 节的 `tls.py activate`。

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

## 7. 公网 IP HTTPS（#61，已试部署，通知与真机待验收）

采用现有 nginx＋Rootless Docker，使用 Certbot **5.9.0** 的 webroot HTTP-01 验证与 Let’s Encrypt `shortlived` IP 证书（当前有效期 160 小时）。80 只服务验证文件；公网 **HTTPS 8080** 映射到容器 443，提供 `/health` 和脱敏续期状态，不开放账号路由。客户端与监测地址必须显式带 `:8080`，原 HTTP 8080 被替换。证书通过 IP SAN 校验，不关闭 TLS 验证，不要求安装测试 CA 或设置 ATS 例外。[官方方案](https://letsencrypt.org/2026/03/11/shorter-certs-certbot/)、[证书配置](https://letsencrypt.org/docs/profiles/)。

- Certbot 官方索引：`certbot/certbot:v5.9.0@sha256:bc93cb710b413e6b456d622f9b0133b3e109c0a78c2ed9976af43d209b0a1805`；覆盖 amd64/arm64。nginx、PostgreSQL 和监测用 Python 镜像沿用现有固定版本及摘要。
- CI 备用同步增加私有 `repflow-certbot`，沿用来源／架构／摘要检查。发布后服务器使用实际 GHCR 摘要；升级需 PR 和双架构测试。
- `tls.py` 使用用户级文件锁，防止人工操作与定时器同时执行。证书目录在仓库外、权限 700，私钥不复制进仓库；nginx 只读挂载完整证书目录以跟踪续期后的符号链接。Certbot 不挂载 Docker socket。
- 定时器每日 UTC 00:00、12:00 检查，随机延迟不超过 30 分钟（北京时间 08:00、20:00）；`Persistent=true` 补执行停机期间错过的任务，沿用已启用的 linger。随机延迟统一由 systemd 提供，关闭 Certbot 内部的额外等待，避免占用命令超时预算。
- 更新后先校验证书链、IP 和余期，再执行 `nginx -t`、reload，并比较实际送出的证书指纹及 `/health`。失败保留待加载标记，下次重试；操作结果原子写入仅含 `ok/checked_at` 的状态文件。错误输出保存到服务器私有 `last-command.log`，不贴到 Issue/PR。

### 部署权限与前置条件

2026-10-29 只读预检：80/443 无监听，Rootless 低端口阈值为 1024、RootlessKit 无相应能力；UFW inactive。外部 80 拒绝连接、443 超时、8080 可达；ACME 正式／测试目录均返回 200，Docker Hub 超时。**这些结果尚不能证明 80/443 已被云安全组放行。**

负责人审阅代码后授权提前试部署，并明确允许下表中的 RootlessKit 权限调整、Docker 重启和 nginx 重建。已设置能力并重启 Docker，nginx/api/db 均恢复，镜像和数据卷挂载未变；公网 HTTP-01 与 Let’s Encrypt staging 签发通过。443 本机可达、外网超时，负责人无法管理云端规则，已确认改用现有可达的 **HTTPS 8080**，不修改云安全组。

| 操作 | 影响／确认点 |
| --- | --- |
| 核对公网 IPv4 和现有端口 | 已验证 TCP 80/8080 可达；保持 80 用于签发和续期。更换 IP 需重新签发并更新客户端与监测配置；未来改 443 需先由云管理员放行，再调整入口和监测端口。 |
| `sudo setcap cap_net_bind_service=ep /usr/bin/rootlesskit` | 仅给 RootlessKit 绑定低端口的能力；不修改全系统低端口阈值。Docker 软件包升级后需重新检查能力。[官方说明](https://docs.docker.com/engine/security/rootless/tips/#exposing-privileged-ports) |
| `systemctl --user restart docker` | 会中断当前 nginx/api/db，之后检查恢复；数据库卷不删除。 |
| nginx 引导、切换与回退 | 重建 nginx 以加载候选配置；引导签发期间健康检查可能暂停，失败可回退原 HTTP 8080 健康检查。 |
| 安装用户级 timer、启用 GitHub 监测 | 新建私有配置、定时器和仓库 Secret／Variable；不改数据库密码或表。 |

### 初始化与续期

常规部署在 PR 合入及上述操作确认后执行；本次提前试部署已有负责人明确授权。先取得 CI 的 `CERTBOT_IMAGE` 摘要。创建权限 600 的 `$HOME/.config/repflow/tls.env`，包含 `PUBLIC_IP`（实际公网 IPv4）、`TLS_STATE_DIR`（仓库外绝对路径，如 `$HOME/.local/state/repflow/tls` 展开后的路径）、`TLS_USE_GHCR=1`、`HTTPS_PORT=8080` 和 `CERTBOT_IMAGE`；现有 `deploy/.env` 原样保留。不要将私有配置内容发到聊天或 GitHub。

本次 Docker Hub 不可达、GHCR 备用包尚未发布，已从本机按上述官方摘要拉取 amd64 镜像，经 `docker save`、SSH 传输和服务器 `docker load` 导入。两端校验归档 SHA-256、镜像 ID 及架构，运行版本为 5.9.0；临时用导入的不可变镜像 ID 配置 `CERTBOT_IMAGE`。GHCR 发布后换回其固定摘要，无需更改证书目录。服务器当前运行审阅后的候选文件，合入后另做文件比对并更新部署记录。

在服务器仓库根目录操作，使用现有 Python 3 与 OpenSSL 系统工具：

```sh
set -a
. "$HOME/.config/repflow/tls.env"
set +a
python3 deploy/tls.py bootstrap
python3 deploy/tls.py staging    # 独立 staging 目录，不覆盖正式证书
python3 deploy/tls.py issue      # 签发正式证书并切换 HTTPS
python3 deploy/tls.py dry-run    # 真实 ACME 演练，并验证当前正式证书的加载
mkdir -p "$HOME/.config/systemd/user"
install -m 644 deploy/repflow-cert-renew.service deploy/repflow-cert-renew.timer "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
systemctl --user start repflow-cert-renew.service
systemctl --user enable --now repflow-cert-renew.timer
systemctl --user list-timers repflow-cert-renew.timer
```

`tls.py` 默认使用 `rootless` context、`repflow` 项目名和 `deploy/.env`；用户服务默认仓库路径为 `$HOME/repflow`。Certbot 自动读取私有配置，不回显；不依赖邮箱提醒。日常排查用 `systemctl --user status repflow-cert-renew.service` 与 `journalctl --user -u repflow-cert-renew.service`。更新 TLS 配置用 `python3 deploy/tls.py activate`：先在临时容器预检，再重建 nginx；人工再次续期用 `renew`。

### GitHub 失败提醒

新增 `HTTPS monitor` 工作流，固定 Python 3.14.9 镜像，每 6 小时从外部检查证书链／IP、至少 48 小时余期、`/health`，以及最近 26 小时内成功的续期状态。续期失败、加载失败、定时器停摆、服务不可达均使任务失败；无 SSH 或包写入权限。定时任务有排队延迟，不能当作即时告警。

**当前仅服务器自动续期已启用，GitHub 外部监测尚未启用，失败通知尚未验收。** 工作流合入默认分支后，按下述步骤配置并验证通知送达。

部署成功后把公网 IPv4 存入仓库 Secret `HTTPS_MONITOR_IP`，设置 Variables `HTTPS_MONITOR_PORT=8080`、`HTTPS_MONITOR_ENABLED=true`；默认关闭以避免未部署时误报。负责人启用 GitHub Actions 的邮件／站内失败通知，先手动正常运行，再用 `test_alert=true` 故意失败一次，确认本人收到通知。仅看到红灯不代表提醒已送达；修改 cron 或重新启用工作流可能改变通知接收人。[GitHub 通知说明](https://docs.github.com/en/actions/concepts/workflows-and-actions/notifications-for-workflow-runs)。

### 回退与验收

- 证书续期失败时不重建 nginx，已加载的证书继续服务；在其到期前修复并重试。配置回退恢复上一版 TLS 文件后执行 `activate`；先校验，失败不重建。不要换回已过期证书。
- 紧急退回骨架时先停用 timer／外部监测，再按第 4 节仅重建原 HTTP 8080 nginx；保留证书目录、数据库卷和密码。该入口只允许健康检查，不能承载登录。
- 本地测试生成一次性 CA／证书，覆盖信任链、IP 不匹配、余期不足、实际证书替换、失败／过时状态和加载重试；不申请公网证书。
- 本地复核（2026-11-01，已同步 dev `6648084`）：Python 3.14.9 下 34 项部署／TLS 测试通过；ruff（沿用后端规则，目标 Python 3.12）、Shell 语法、官方／GHCR Compose 配置、80／8080 映射、数据库隔离与卷挂载、定时器和监测工作流配置、密钥扫描通过。此前服务器 Python 3.14.4 下同样 34 项通过。
- 服务器实测：staging／正式签发成功；外网 HTTPS 8080 证书链和 IP 校验、TLS 1.2／1.3、`/health` 与续期状态通过。真实 ACME `dry-run`、部署钩子、nginx 加载及证书核对通过，用户级续期服务运行成功、每日两次 timer 已启用。
- 恢复实测：无效 nginx 配置被拦截，原 HTTPS 保持可用且失败状态可被监测脚本识别；恢复配置、回退 HTTP 8080 再切回 HTTPS、退出本次 SSH 后外网检查、Rootless Docker 重启恢复均通过。镜像、数据库卷挂载与证书保持不变；未执行整机重启或删除数据卷。
- `check.sh` 保留原有验收，并调用 `check_https_stack.py` 验证 HTTP-01、真实 nginx HTTPS、reload、nginx 重启和无效配置拒绝／回退；只使用独立临时项目和测试卷。本机空间紧张，最小容器停在 Created，重启 Docker Desktop 后仍启动超时，尚未确认根因。负责人同意暂缓本机镜像构建／完整 Compose 验收，本机结果记为环境受阻；测试不删除、不设跳过，完整验证由 CI 执行。
- 双架构验收（2026-11-01）：[PR #83 的 Backend CI](https://github.com/Team-Party-A/repflow/actions/runs/41267660112) 在代码提交 `7a5d558` 上通过；amd64／arm64 各通过 34 项部署／TLS 测试、56 项后端 pytest，pytest-cov 报告覆盖率 99%。镜像构建、数据库超时／恢复、API 换址、数据卷保留、nginx 配置更新／回退，以及完整 HTTPS 检查均通过；三个官方镜像的固定来源／架构核对通过。PR 不发布镜像或备用包。
- **仍待验收**：PR 审查合入和 GHCR 备用包发布；GitHub 通知送达。iOS 17.2.1 真机 `/health` 因设备问题经负责人确认暂缓，后续补验，不记为通过。GitHub 定时监测需工作流合入默认分支后启用；正式证书到期续期尚未发生，当前验证为 ACME 演练和加载流程。账号接口部署就绪后另补登录测试。

## 8. dev 自动部署与回退（#94）

合入后的 Backend 工作流为后端和部署改动构建两种架构并发布私有 GHCR 摘要。swe 的用户级定时器每 30 秒唤醒，空闲时约每两分钟查询公开的 dev 发布任务，用现有拉取权限按摘要下载镜像。候选就绪后最多做四次约 30 秒间隔的确认，再退回两分钟。GitHub runner 验证现有 HTTPS 8080 上的候选身份和 `/health`。HTTPS 8080 同时提供已约定的账号和训练路由，HTTP 80 继续服务 ACME 验证。

切换前核对 dev 提交、镜像 revision、线上 Alembic 版本和 Compose 文件，备份数据库并校验归档可读性。自动切换要求候选与线上使用相同的 Alembic 版本和 Compose 文件。迁移或 Compose 改动走人工变更窗口，确认回退边界后重新登记版本。

服务器先记录候选及原版本，再替换 API。若 TLS 配置有变，先验证配置再重建 nginx。GitHub 验证失败、取消或超时后，下一次定时检查恢复旧摘要和配置，并复查本机 HTTPS。中途重启后从记录继续恢复。数据库卷一直使用原卷，备份只用于人工恢复。公网状态只包含提交号、摘要、运行号、尝试号和阶段。`Confirm swe deployment or rollback` 等服务器确认；失败运行可由机器人在 #94 提醒负责人。

### 上线步骤

1. 审查合入后，在 swe 的 `~/repflow` 检出已审阅的配置提交（`git checkout --no-overwrite-ignore --detach <提交号>`）。按第 7 节执行 `tls.py activate` 预检并加载 nginx。验证公网 HTTPS `/health`、账号和训练路由，再登记实际运行的镜像与配置。
2. 由部署负责人安装用户级服务。初始化会确认旧版本健康，且 HTTPS 部署状态入口已可用。

   ```sh
   cd "$HOME/repflow"
   install -d -m 700 "$HOME/.local/lib/repflow" "$HOME/.config/systemd/user"
   install -m 600 deploy/auto_deploy.py deploy/release_probe.py deploy/https_probe.py \
     deploy/github_poll.py deploy/image_cache.py deploy/release_metrics.py "$HOME/.local/lib/repflow/"
   install -m 644 deploy/repflow-auto-deploy.service deploy/repflow-auto-deploy.timer "$HOME/.config/systemd/user/"
   systemd-run --user --wait --collect --pipe -p "EnvironmentFile=$HOME/.config/repflow/tls.env" \
     /usr/bin/python3 "$HOME/.local/lib/repflow/auto_deploy.py" --initialize
   systemctl --user daemon-reload
   systemctl --user enable --now repflow-auto-deploy.timer
   ```

3. 复用 `HTTPS_MONITOR_IP` 与 `HTTPS_MONITOR_PORT`，再设置 `SWE_AUTO_DEPLOY_ENABLED=true`。负责人接受机器人在 #94 提醒后，设置 `SWE_DEPLOY_NOTIFY=true` 并确认本人收到通知。两项开关默认关闭。用一次正常 dev 发布和一次负责人授权的失败演练验证，记录两个运行链接。失败演练可临时将 `SWE_DEPLOY_TEST_FAIL_COMMIT` 设为这次测试发布的完整提交号，确认回退后移除变量。

### 日常操作

- 用 `systemctl --user list-timers repflow-auto-deploy.timer` 检查定时器，用 `journalctl --user -u repflow-auto-deploy.service` 看阶段和结果。私有状态目录为 `~/.local/state/repflow/auto-deploy/`，其中 `releases.json` 记录当前、上一版和待验收版本，备份归档与命令日志也留在该目录。
- 用户服务执行 `~/.local/lib/repflow/` 中已安装的脚本。升级时先等 `pending` 为空、服务退出，停用 timer，再从已审阅提交提取并安装上述六个脚本和服务文件，执行 `daemon-reload` 后恢复 timer。生产 checkout 与 `releases.json` 由部署流程管理，工具升级通过 `git show <已审阅提交>:deploy/<文件>` 提取文件，避免提前改变已登记配置。
- 人工更新前先关闭 `SWE_AUTO_DEPLOY_ENABLED`，等待正在执行的发布结束，再停用 timer。手工执行第 4 节的 Compose 命令时，将 `~/.local/state/repflow/auto-deploy/image.env` 作为最后一个 `--env-file`，或显式提供已核对的 `API_IMAGE`。人工回退使用记录里的旧配置提交和摘要，复验 HTTPS。人工发布后归档旧 `releases.json`、重新执行初始化，再恢复 timer 和开关。

### 构建缓存与提速验收

- CI 使用已锁定的 Buildx 0.38.1、BuildKit 0.34.2 镜像摘要及官方构建 Action 7.4.0 提交 SHA。GHA v2 缓存按 test/runtime、amd64/arm64 分四个 scope，导出 `mode=max` 中间层。PR 和合入队列只导入，dev/main push 的检查任务导出，发布任务导入 runtime 缓存。每次仍执行完整检查，双架构通过后才发布。缓存导出失败单独标明，构建与测试失败仍阻止发布。
- swe 通过本地 Docker Engine 检查根摘要、本机平台内容完整性及 revision，完整命中时跳过 `pull`，之后继续做数据库版本检查、备份及校验、切换和健康验收。明确缺失或内容未完整时拉取，本地检查故障或身份不匹配时安全停止。
- 私有 `github-poll.json` 保存每小时滚动请求预算、限流退避和各端点 ETag，重启继续沿用。总额 48 次，其中 discovery 最多 36 次，余量供确认和切换前校验。失败、304 和重试都计数，响应限流头可进一步延后查询。runs 的 304 仍需独立检查 jobs，网络错误不会复用旧成功结果。到期回退先于额度检查执行；切换前无法重新确认时保留现网并记录失败，后续从新 CI 尝试重试。
- 私有 `metrics-<run>-<attempt>.json` 记录发现、下载、候选、登记或回退时间，以及下载前后的网络 RX/TX 增量。`docker_netns` 为 Docker 网络空间默认出口统计，`host` 为宿主回退，两者都包含背景流量与协议开销，不能称精确 GHCR 流量。另取等长空闲窗口作基线，缺失 blob 压缩量与线路实测值分列。
- 验收覆盖完整缓存但不同于现网的目标、只改业务代码、真实新依赖层。记录 CI 缓存导入导出字节与耗时、层摘要、API 次数及响应体字节，并分解构建发布、发现、下载、候选确认和整体耗时。热缓存至少测三轮。真实发布按合入到 Confirm 计时，重跑按本次启动计时。保留现网及回退缓存，使用独立 CI scope 建立冷构建基线。
- 下载仍有 240 秒边界，新的提速结果以实测确认。若新层仍超时，另行评审下载预算及其外层时限，既有完整缓存和轮询优化不会提高冷层网络吞吐率。
