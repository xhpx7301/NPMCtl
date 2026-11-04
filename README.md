# NPMCtl

`NPMCtl` 是运行在 Linux 宿主机上的交互式 Nginx Proxy Manager Docker 管理工具。它创建并管理官方 NPM 镜像、持久化数据、证书和 Compose 配置。站点、证书和用户记录由 NPM 面板管理；启用 443 复用时，脚本会适配 HTTPS 模板与生成配置的监听端口，并在关闭时恢复。

## 特性

| 能力 | 说明 |
| --- | --- |
| Docker 部署 | 使用 `jc21/nginx-proxy-manager:latest` 创建 Nginx Proxy Manager。默认采用官方 bridge 网络、SQLite 数据库与 80、81、443 端口映射。 |
| 网络模式切换 | 可在默认 `bridge` 与 Linux `network_mode: host` 之间切换，并在更改前备份 Compose 配置。 |
| 网关设置 | 查看 NPM 当前 Docker 网络与网关、将任意容器服务加入或移出 Docker 网络，并查看本机 TCP 服务监听地址。 |
| 本机服务监听助手 | 迁移自 CaddyCtl 的完整监听助手：扫描宿主机 TCP 监听、识别监听范围/进程/PID/systemd，关联 Docker 发布端口与容器内部监听，检测 NPM 网关连通性，并支持 Kopia 接管、systemd 服务详情、监听地址备份修改、自动恢复和上一次回滚。 |
| 原生后端支持 | host 模式下，NPM 可直接代理监听在宿主机 `127.0.0.1` 的服务。 |
| 443 端口复用 | 菜单 `7` 管理多个 Reality SNI → Xray / Realm 映射，支持 bridge 与 host、保留映射关闭、重新启用、失败自动恢复；普通 HTTPS 网站和 HTTP 面板继续由 NPM 管理。 |
| 日常维护 | 查看容器状态、日志、端口监听，更新管理脚本，以及备份 NPM 的 SQLite 数据和 Let's Encrypt 证书。 |
| 配置保护 | 切换网络模式会备份旧 Compose 和 NPMCtl 配置；卸载容器默认保留 NPM 数据，完全卸载需确认。 |

## 支持环境

| 项目 | 要求 |
| --- | --- |
| 操作系统 | 使用 systemd 的 Debian/Ubuntu 或 Fedora/RHEL。 |
| 权限 | root，或具有 `sudo` 权限的交互式终端。 |
| Docker | Docker Engine 与 Docker Compose v2。NPMCtl 可在 apt/dnf 系统上协助安装。 |
| 网络 | 域名 DNS 指向服务器；公网通常需要放行 TCP 80 与 443。管理面板 81 应限制访问来源。 |

`network_mode: host` 仅适用于 Linux Docker。NPMCtl 不适用于 Docker Desktop 的 Windows/macOS host 网络语义。

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/xhpx7301/NPMCtl/main/install.sh | bash
```

也可以从已获取的源码目录执行：

```bash
chmod +x install.sh
./install.sh
```

若使用 Fork、私有镜像或自托管源，可通过 `NPMCTL_SOURCE_URL` 指定管理脚本下载地址：

```bash
export NPMCTL_SOURCE_URL="https://<HOST>/<PATH>/npmctl.sh"
./install.sh
```

安装器只安装 `npmctl` 菜单入口。Docker 与 Nginx Proxy Manager 会在菜单确认后安装或部署。

菜单 `4` 会检查 Docker Engine 和 `docker compose` 是否分别可用。Debian/Ubuntu 按当前 apt 源实际提供的候选包安装 Engine，并依次尝试 `docker-compose-plugin`、`docker-compose-v2` 和版本至少为 2 的 `docker-compose`（兼容 Debian 13 trixie）；不会把旧版 Python Compose v1 当作替代。如果候选包未提供可用的 `docker compose` 命令，会按 CPU 架构从 Docker Compose 官方 GitHub Release 下载插件及同一版本的 SHA-256 文件，校验成功并验证可运行后再安装，下载或校验失败会停止并说明原因。现有 apt 源没有 Engine 候选包时，会提示按 Docker 官方文档配置软件源后重试，不自动改写软件源。

已有 Docker Engine 时只补齐缺少的 Compose 插件；已正常运行的 Engine 不会因该操作主动重启。只有服务未运行时才尝试启动，最后同时检查 `docker info` 和 `docker compose version`。遇到旧版本的 `Unable to locate package docker-compose-plugin` 报错，可先选菜单 `1` 更新 NPMCtl，再选菜单 `4` 重试。

## 命令

| 命令或选项 | 作用 |
| --- | --- |
| `npmctl` | 打开交互式管理菜单。 |
| `npmctl --install` | 使用当前网络模式部署或更新 Nginx Proxy Manager。 |
| `npmctl --network bridge` | 切换为官方默认 bridge 网络模式并重建 NPM 容器。 |
| `npmctl --network host` | 切换为 Linux host 网络模式并重建 NPM 容器。 |
| `npmctl --install-manager` | 安装 `npmctl` 命令入口，主要由安装器调用。 |
| `npmctl --help` | 显示命令帮助。 |

## 网络模式

| 模式 | NPM Compose 行为 | 原生 `127.0.0.1` 后端 | 适用情况 |
| --- | --- | --- | --- |
| `bridge`（默认） | 使用 Docker 默认网络，发布 `80:80`、`81:81`、`443:443`。 | 无法直接访问。 | 官方默认方式；后端主要容器化时优先使用。 |
| `host` | 使用 `network_mode: host`，不设置 `ports:`。 | 可直接填写 `127.0.0.1:端口`。 | 后端多为宿主机原生服务，且无法调整其监听地址时使用。 |

切换模式会停止并重建 NPM 容器，但不会删除 `/opt/npmctl/data` 或 `/opt/npmctl/letsencrypt` 中的数据。请在维护窗口执行，并确认宿主机端口 80、81、443 没有被其他服务占用。

启用 443 复用后，切换网络模式或重新部署会保留映射与启用状态，检查 NPM 配置和管理 API 就绪后才报告成功；失败会尝试恢复原配置与原镜像。host 模式还需要回环 TCP 8443 供 NPM 内部 HTTPS 使用。

在 bridge 模式下，优先让 NPM 与应用容器共享 Docker 网络，然后将 NPM 上游填写为 `Compose服务名:容器内部端口`。不要为了让 NPM 访问而把应用端口直接暴露到公网。

### 网关设置

主菜单的“网关设置”可以查看 NPM 容器当前连接的 Docker 网络、网络驱动、网关地址、容器 IP，以及每个网络中的其他容器和 IP；同时会单独显示 Docker 系统内置的 `bridge` 网络（通常网关为 `172.17.0.1`），并标明 NPM 是否加入。注意 `npmctl_default` 这类 Compose 默认网络与系统内置 `bridge` 是两个不同网络。新增或移除服务时，菜单会先列出 Docker 共享网络，再让你选择该网络中的服务：可以把未加入的容器加入选定网络，也可以从选定网络的成员中移除服务。网络连接调整会即时作用于当前容器；Compose 重建容器后可能丢失，需在对应 Compose 配置中声明。移除 NPM 与网络的连接会影响它访问同网络服务。Docker 网关属于网络本身，不能单独修改；删除网络本身前，请先确认没有其他容器依赖它。

### 本机服务端口监听助手

本机 TCP 监听表按宿主机监听端口从小到大排列，相同端口保留原始顺序；支持 `ss` 与 `netstat` 两种检测方式。网关设置中的“本机 TCP 服务监听地址”同步使用此排序。

主菜单的“本机服务端口监听助手”已完整迁移 CaddyCtl 的相关能力：显示本机 TCP 监听表（包含监听范围、进程/PID、systemd 服务、Docker 发布端口与对应容器实际端口），查看全部运行中容器的内部监听，识别 NPM 容器及 Docker 网关，验证 NPM 到宿主机服务的连通性，并提供 Docker 容器端口映射、共享网络和 bridge 网关中转建议。端口发布兼容选项同时列出 NPM 已连接网络的网关和 Docker 系统默认 `bridge` 网络网关（按 Docker 实际配置读取，常见为 `172.17.0.1`），可将 Compose 发布地址绑定到选定网关；选择系统默认 bridge 时，请确认 NPM 容器能够访问该地址。对于 systemd 管理的原生服务，助手可以查看服务定义和配置文件，自动备份并替换监听地址，重启后验证，失败时自动恢复；通用文本配置保留上一次修改的手动回滚入口。Kopia `server start` 进程支持专用监听地址修改；脱离 systemd 的 Kopia 进程还可以保留原参数接管为 NPMCtl 管理的 systemd 服务。监听地址修改会影响服务可达范围，请先确认防火墙和访问来源。

3X-UI：在菜单 `2` 输入面板当前端口，助手识别由 `x-ui.service` 管理的 `x-ui` 进程后，使用其自带 `setting -getListen` / `-listenIP` 命令修改数据库中的 IPv4 监听地址。调用沿用服务的工作目录和环境（包括自定义 `XUI_DB_FOLDER`），先核对面板端口，避免误改订阅服务。设置或重启失败、新监听未在 15 秒内就绪时，通过 CLI 恢复原地址；恢复失败会明确提示检查服务日志。此入口只修改监听地址，保留端口号。

NPM 使用 bridge 时，选择“经 Docker 网关访问”，成功后在 NPM Proxy Host 中填写助手显示的网关 IP 和原面板端口；协议按面板实际 HTTP / HTTPS 设置，并保留原访问路径。助手不会自动修改 NPM 中已经填写的上游地址。CLI 不支持所需参数、无法读取当前 IPv4 地址或服务不是标准 `x-ui.service` 时，会停止修改。

## 文件位置

| 内容 | 默认位置 |
| --- | --- |
| Compose 配置 | `/opt/npmctl/compose.yml` |
| 网络模式配置 | `/opt/npmctl/.env` |
| 443 复用映射与启动适配脚本 | `/opt/npmctl/l4/`（映射为 `routes.tsv`） |
| NPM 数据（SQLite） | `/opt/npmctl/data` |
| Let's Encrypt 证书 | `/opt/npmctl/letsencrypt` |
| NPMCtl 备份 | `/var/backups/npmctl` |
| NPMCtl 主脚本 | `/usr/local/lib/npmctl/npmctl.sh` |
| `npmctl` 命令入口 | `/usr/local/bin/npmctl` |

## 443 端口复用（HTTPS 网站 / 面板 + Reality）

主菜单选择 `7`，添加一个或多个 Reality 映射，填写实际的 `serverName`、Xray / Realm 后端地址和端口，再选择“启用 / 校验并重新应用”。相同 SNI 只能映射到一个后端；Reality SNI 不能与已有 NPM 站点域名（包括匹配的通配符域名）重叠。后续在 NPM 新增站点时也应避开这些 SNI。

新增映射时，后端地址默认按受管理 NPM 容器的实际网络识别：host 使用 `127.0.0.1`，bridge 使用该容器唯一的 IPv4 网关（例如 `172.18.0.1`），回车接受，也可填写其他地址或容器服务名。多个网关或无法识别时留空并提示手动填写；容器不可用但已保存 host 模式时使用回环地址。编辑已有映射时保留原地址。此默认值是访问宿主机的建议地址，需确保 Xray / Realm 入站实际接受该地址的连接；3X-UI 面板监听设置与 Reality 入站监听分别配置。

HTTP 面板直接在 NPM 中添加 Proxy Host：填写面板域名、HTTP 后端地址和端口，申请或选择 SSL 证书。面板域名必须与 Reality SNI 不同，不需要在 NPMCtl 再配置面板映射。

```text
公网 TCP 443 → NPM 容器内 Nginx SNI 分流
                  ├─ reality-a.example → Xray / Realm 后端 A（原始 TLS）
                  ├─ reality-b.example → Xray / Realm 后端 B（原始 TLS）
                  └─ 其他域名 → 内部 HTTPS → NPM Proxy Hosts / HTTP 面板
```

bridge 模式仍发布 `443:443`，host 模式同样由 NPM 容器接管 443。启用时，容器启动适配脚本将镜像自带 HTTPS 模板和已有生成配置的监听改为 `127.0.0.1:8443` / `[::1]:8443`，并通过 NPM 官方 `custom/stream.conf` 扩展入口加载 SNI 分流。不需要额外运行 Caddy / HAProxy，也不改 SQLite 内的站点、证书或用户记录。新站点继续使用适配后的模板。

HTTPS 分支通过内部 PROXY protocol 传递真实客户端 IP，供 NPM 日志和 Access Lists 使用。Reality 分支会在内部中转时移除该头，Xray / Realm 无需启用 PROXY protocol；其后端看到的连接来源是 NPM，不是原始客户端 IP。原有自定义 Stream 配置会保留，但不能另外监听 TCP 443 或内部保留端口 8443；后端也不能填写这两个保留端口。

后端地址按 **NPM 容器的网络视角**填写：host 模式可填写宿主机 `127.0.0.1`；bridge 模式应使用 NPM 可达的 Docker 网关地址、内网地址或共享网络服务名，容器里的 `127.0.0.1` 只代表容器自身。可使用“网关设置”和“本机服务端口监听助手”检查后端可达性。

“关闭复用”会恢复原 HTTPS 监听并保留映射；可以直接重新启用。需要清空映射时，先关闭复用，再选择“删除已保存映射”。增删改已启用的映射、启停复用和切换网络模式都会重建容器，短暂中断现有连接；变更前会在 `/var/backups/npmctl/l4-*` 保存部署配置与 Nginx 配置，失败自动恢复。常规数据备份也包含 `l4` 目录。

启动时会检查官方镜像的 `ssl_preread`、HTTP Real IP 模块和 HTTPS 模板结构；不兼容的镜像会停止应用，并由管理脚本尝试恢复旧部署。证书继续使用 TCP 80 的 HTTP-01 或 DNS-01；此功能仅处理可读取 SNI 的 TCP TLS 连接，不包含 UDP / QUIC 或通用 SSH 协议识别。

## 开发验证

```bash
bash -n npmctl.sh
python3 -m unittest discover -s tests -v
docker pull jc21/nginx-proxy-manager:latest
python3 tests/integration_l4.py
```

集成验证使用临时数据目录和独立容器，bridge 端口随机绑定到本机回环地址；检查 HTTPS 真实 IP、多个 TLS 后端、重建容器、失败回滚、关闭和重新启用。宿主机相关端口空闲时还会验证 bridge → host → bridge 切换。

## 首次登录与安全

NPM 启动后，面板地址为 `http://服务器IP:81`。当前版本首次启动会显示“创建管理员账户”页面，填写姓名、邮箱和新密码即可；NPMCtl 会在首次部署成功后显示此提示，不存在应由脚本展示的固定默认账号或密码。

NPM 的用户、权限、邮箱和密码应在其管理面板中维护。NPMCtl 不读取或修改 SQLite 数据库内的用户记录，也不保存或显示密码。

## 卸载

菜单“卸载 NPM、Docker 或 NPMCtl”提供四种范围：仅删除 NPM 容器、仅删除 NPMCtl 管理入口、完全卸载 NPM 与 NPMCtl，或完全卸载 Docker 与 Compose。Docker 完全卸载需要输入 `y` 确认，直接回车或输入 `n` 会取消；确认后会停止并删除本机所有 Docker 容器、镜像、卷和网络，卸载 Engine/Compose 软件包并删除 Docker 运行时数据目录。NPMCtl 管理入口和 `/opt/npmctl` 中的数据不会被该选项删除。

生产环境中只需对外放行 80 与 443；应以防火墙、私有网络或额外认证限制 81 管理端口。变更前请先通过菜单创建备份，并将部署文件与数据目录纳入服务器备份策略。
