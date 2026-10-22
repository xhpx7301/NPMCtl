# NPMCtl

`NPMCtl` 是运行在 Linux 宿主机上的交互式 Nginx Proxy Manager Docker 管理工具。它创建并管理官方 NPM 镜像、持久化数据、证书和 Compose 配置；不修改 NPM 面板内的 Proxy Hosts、证书或用户数据。

## 特性

| 能力 | 说明 |
| --- | --- |
| Docker 部署 | 使用 `jc21/nginx-proxy-manager:latest` 创建 Nginx Proxy Manager。默认采用官方 bridge 网络、SQLite 数据库与 80、81、443 端口映射。 |
| 网络模式切换 | 可在默认 `bridge` 与 Linux `network_mode: host` 之间切换，并在更改前备份 Compose 配置。 |
| 网关设置 | 查看 NPM 当前 Docker 网络与网关、将任意容器服务加入或移出 Docker 网络，并查看本机 TCP 服务监听地址。 |
| 本机服务监听助手 | 迁移自 CaddyCtl 的完整监听助手：扫描宿主机 TCP 监听、识别监听范围/进程/PID/systemd，关联 Docker 发布端口与容器内部监听，检测 NPM 网关连通性，并支持 Kopia 接管、systemd 服务详情、监听地址备份修改、自动恢复和上一次回滚。 |
| 原生后端支持 | host 模式下，NPM 可直接代理监听在宿主机 `127.0.0.1` 的服务。 |
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

在 bridge 模式下，优先让 NPM 与应用容器共享 Docker 网络，然后将 NPM 上游填写为 `Compose服务名:容器内部端口`。不要为了让 NPM 访问而把应用端口直接暴露到公网。

### 网关设置

主菜单的“网关设置”可以查看 NPM 容器当前连接的 Docker 网络、网络驱动、网关地址、容器 IP，以及每个网络中的其他容器和 IP；同时会单独显示 Docker 系统内置的 `bridge` 网络（通常网关为 `172.17.0.1`），并标明 NPM 是否加入。注意 `npmctl_default` 这类 Compose 默认网络与系统内置 `bridge` 是两个不同网络。也可以选择任意容器服务，将其加入已有 Docker 网络或从已加入的网络中移除，或查看与本机服务端口监听助手相同的完整 TCP 监听表。网络连接调整会即时作用于当前容器；Compose 重建容器后可能丢失，需在对应 Compose 配置中声明。移除容器唯一的 bridge 网络会使其失去该网络上的通信能力。Docker 网关属于网络本身，不能单独修改；删除网络本身前，请先确认没有其他容器依赖它。

### 本机服务端口监听助手

主菜单的“本机服务端口监听助手”已完整迁移 CaddyCtl 的相关能力：显示本机 TCP 监听表（包含监听范围、进程/PID、systemd 服务、Docker 发布端口与对应容器实际端口），查看全部运行中容器的内部监听，识别 NPM 容器及 Docker 网关，验证 NPM 到宿主机服务的连通性，并提供 Docker 容器端口映射、共享网络和 bridge 网关中转建议。端口发布兼容选项同时列出 NPM 已连接网络的网关和 Docker 系统默认 `bridge` 网络网关（按 Docker 实际配置读取，常见为 `172.17.0.1`），可将 Compose 发布地址绑定到选定网关；选择系统默认 bridge 时，请确认 NPM 容器能够访问该地址。对于 systemd 管理的原生服务，助手可以查看服务定义和配置文件，自动备份并替换监听地址，重启后验证，失败时自动恢复；同时保留上一次修改的手动回滚入口。Kopia `server start` 进程支持专用监听地址修改；脱离 systemd 的 Kopia 进程还可以保留原参数接管为 NPMCtl 管理的 systemd 服务。监听地址修改会影响服务可达范围，请先确认防火墙和访问来源。

## 文件位置

| 内容 | 默认位置 |
| --- | --- |
| Compose 配置 | `/opt/npmctl/compose.yml` |
| 网络模式配置 | `/opt/npmctl/.env` |
| NPM 数据（SQLite） | `/opt/npmctl/data` |
| Let's Encrypt 证书 | `/opt/npmctl/letsencrypt` |
| NPMCtl 备份 | `/var/backups/npmctl` |
| NPMCtl 主脚本 | `/usr/local/lib/npmctl/npmctl.sh` |
| `npmctl` 命令入口 | `/usr/local/bin/npmctl` |

## 首次登录与安全

NPM 启动后，面板地址为 `http://服务器IP:81`。当前版本首次启动会显示“创建管理员账户”页面，填写姓名、邮箱和新密码即可；NPMCtl 会在首次部署成功后显示此提示，不存在应由脚本展示的固定默认账号或密码。

NPM 的用户、权限、邮箱和密码应在其管理面板中维护。NPMCtl 不读取或修改 SQLite 数据库内的用户记录，也不保存或显示密码。

## 卸载

菜单“卸载 NPM、Docker 或 NPMCtl”提供四种范围：仅删除 NPM 容器、仅删除 NPMCtl 管理入口、完全卸载 NPM 与 NPMCtl，或完全卸载 Docker 与 Compose。Docker 完全卸载需要输入 `y` 确认，直接回车或输入 `n` 会取消；确认后会停止并删除本机所有 Docker 容器、镜像、卷和网络，卸载 Engine/Compose 软件包并删除 Docker 运行时数据目录。NPMCtl 管理入口和 `/opt/npmctl` 中的数据不会被该选项删除。

生产环境中只需对外放行 80 与 443；应以防火墙、私有网络或额外认证限制 81 管理端口。变更前请先通过菜单创建备份，并将部署文件与数据目录纳入服务器备份策略。
