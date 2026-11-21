# 安装

安装器会先显示 APT 仓库中可用的 PHP、Nginx 和 MySQL 版本供选择；默认选项是当前仓库中最新可用版本，MySQL 只列出 8+。无交互运行时使用默认版本。版本列表来自当前已配置的 APT 源，因此 Debian 官方源只能选择该 Debian 版本实际提供的 PHP/Nginx 版本。

以 root 身份执行：

```sh
cd lnmp-debian
./install.sh
```

Nginx、PHP、ACME 客户端及运行依赖由 Debian APT 安装。MySQL 使用 Oracle 官方 APT 仓库的 MySQL 8.4 LTS 包；当前仓库仅向 amd64 提供 Debian 13 构建。安装器使用 Oracle 2025 更新的仓库签名密钥，并校验其指纹，以避免过期密钥导致 APT 验签失败。脚本不会使用旧版 `Download_Mirror`，也不会自动卸载现有服务；检测到 MariaDB 或未迁移的 MySQL 数据时会停止安装。

安装前请备份数据。MySQL 安装可能需要在终端完成软件包配置。
