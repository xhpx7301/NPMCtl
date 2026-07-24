# NPMCtl

`NPMCtl` 是运行在 Linux 宿主机上的交互式 Nginx Proxy Manager Docker 管理工具。它创建并管理官方 NPM 镜像、持久化数据、证书和 Compose 配置；不修改 NPM 面板内的 Proxy Hosts、证书或用户数据。

## 特性

| 能力 | 说明 |
| --- | --- |
| Docker 部署 | 使用 `jc21/nginx-proxy-manager:latest` 创建 Nginx Proxy Manager。默认采用官方 bridge 网络、SQLite 数据库与 80、81、443 端口映射。 |
| 网络模式切换 | 可在默认 `bridge` 与 Linux `network_mode: host` 之间切换，并在更改前备份 Compose 配置。 |
| 原生后端支持 | host 模式下，NPM 可直接代理监听在宿主机 `127.0.0.1` 的服务。 |
| 日常维护 | 查看容器状态、日志、端口监听，更新管理脚本，以及备份 NPM 的 SQLite 数据和 Let's Encrypt 证书。 |
| 配置保护 | 切换网络模式会备份旧 Compose 和 NPMCtl 配置；卸载容器默认保留 NPM 数据。 |

## 支持环境

| 项目 | 要求 |
| --- | --- |
| 操作系统 | 使用 systemd 的 Debian/Ubuntu 或 Fedora/RHEL。 |
| 权限 | root，或具有 `sudo` 权限的交互式终端。 |
| Docker | Docker Engine 与 Docker Compose v2。NPMCtl 可在 apt/dnf 系统上协助安装。 |
| 网络 | 域名 DNS 指向服务器；公网通常需要放行 TCP 80 与 443。管理面板 81 应限制访问来源。 |

`network_mode: host` 仅适用于 Linux Docker。NPMCtl 不适用于 Docker Desktop 的 Windows/macOS host 网络语义。

## 安装

发布到 GitHub 后，将下列占位符替换为实际的 raw 安装脚本地址：

```bash
curl -fsSL <INSTALL_SCRIPT_URL> | bash
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

NPM 启动后，面板地址为 `http://服务器IP:81`。初始凭据和首次登录流程以 Nginx Proxy Manager 上游项目的当前文档为准。

生产环境中只需对外放行 80 与 443；应以防火墙、私有网络或额外认证限制 81 管理端口。变更前请先通过菜单创建备份，并将部署文件与数据目录纳入服务器备份策略。
