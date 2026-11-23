# 安装

以 root 身份执行：

```sh
cd lnmp-debian
./install.sh
```

## 组件来源与版本选择

| 组件 | 安装来源 | 版本列表来源 | 默认选项 | 版本参数 |
| --- | --- | --- | --- | --- |
| Nginx | nginx.org 官方 APT 仓库 | 所选通道的官方仓库 | 最新可用版本 | `NGINX_VERSION`（须为菜单中的确切版本） |
| PHP | Debian 官方 APT 仓库 | Debian 仓库 | 最新可用版本 | `PHP_VERSION`（须为菜单中的确切值） |
| MySQL | Oracle 官方 APT 仓库 | 动态发现的 Server 组件 | 版本最高的 LTS | `MYSQL_VERSION`（须为菜单中的确切版本） |
| ACME 客户端 | Debian 官方 APT 仓库 | — | 随 Debian 仓库 | 不参与选择 |

| 场景 | 行为 |
| --- | --- |
| 交互终端 | 列出版本并提示选择，可输入序号或确切版本字符串；直接回车采用默认值 |
| 无交互终端 | 直接采用默认版本 |
| 配置文件指定了版本 | 作为菜单默认项；若不在菜单中则报错退出，**不会回退** |
| PHP 需要更新版本 | 安装时用 Debian 包（跟随 Debian）；之后用 [`upgrade.sh`](./upgrade.md) 切换到 sury 源升级 |

## 各来源说明

| 主题 | 说明 |
| --- | --- |
| Nginx 官方源 | 安装与升级同源。写入 nginx.org 签名密钥并校验指纹，Pin 优先级 900 让官方包优先于 Debian 同名包。`NGINX_CHANNEL=stable` → `https://nginx.org/packages/debian <代号> nginx`；`mainline` → `https://nginx.org/packages/mainline/debian <代号> nginx`（stable 路径**不带** `/stable` 段）。当前支持 Debian 13（trixie）。 |
| MySQL 为何用 Oracle 源 | Debian 官方仓库不含 Oracle MySQL，只有 MariaDB。 |
| MySQL 组件发现 | 从仓库 `Release` 文件的 `Components` 字段动态提取全部 Server 组件（排除 cluster / tools / apt-config），不做版本写死。当前提供 `mysql-8.4-lts`、`mysql-9.7-lts`、`mysql-innovation`，仅向 amd64 提供 Debian 13 构建。 |
| MySQL 选版流程 | 发现阶段临时启用全部组件展示所有可选版本 → 菜单标注 LTS / 创新版 → 选定后将源收敛到该版本所属**单个组件**再安装，避免不同系列的 `mysql-common`、`libmysqlclient` 等共享包版本混用。 |
| MySQL 签名与兼容 | 使用 Oracle 2025 更新的签名密钥并校验指纹，避免过期密钥导致验签失败；不使用旧版 `Download_Mirror`。 |
| 安装边界 | 不自动卸载现有服务；检测到 MariaDB 或未迁移的 MySQL 数据时停止安装。 |
| PHP / ACME / 依赖 | 由 Debian APT 安装，PHP 版本跟随 Debian 发行版。 |

## 安装前

- 备份数据。
- MySQL 安装可能需要在终端完成软件包配置。
