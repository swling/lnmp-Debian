# LNMP Debian

此目录提供面向 Debian 13 及以上版本的精简安装器和 `lnmp` 管理命令。

## 安装

安装器会先显示 APT 仓库中可用的 PHP、Nginx 和 MySQL 版本供选择；默认选项是当前仓库中最新可用版本，MySQL 只列出 8+。无交互运行时使用默认版本。版本列表来自当前已配置的 APT 源，因此 Debian 官方源只能选择该 Debian 版本实际提供的 PHP/Nginx 版本。

以 root 身份执行：

```sh
cd lnmp-Debian
./install.sh
```

Nginx、PHP、ACME 客户端及运行依赖由 Debian APT 安装。MySQL 使用 Oracle 官方 APT 仓库的 MySQL 8.4 LTS 包；当前仓库仅向 amd64 提供 Debian 13 构建。安装器使用 Oracle 2025 更新的仓库签名密钥，并校验其指纹，以避免过期密钥导致 APT 验签失败。脚本不会使用旧版 `Download_Mirror`，也不会自动卸载现有服务。检测到已有自定义 LNMP 路径时会停止，以免覆盖现有配置或数据。

安装前请备份数据。MySQL 安装可能需要在终端完成软件包配置。

## 配置文件

安装前编辑目录中的 [lnmp-debian.conf](./lnmp-debian.conf)，或安装后编辑 `/etc/lnmp-debian.conf`：

```sh
WEB_ROOT="/home/wwwroot"
DEFAULT_WEB_ROOT="/home/wwwroot/default"
NGINX_LOG_DIR="/home/wwwlogs"
MYSQL_DATA_DIR="/var/lib/mysql"
PHP_VERSION=""
NGINX_VERSION=""
MYSQL_VERSION=""
```

`WEB_ROOT` 是新建虚拟主机的默认父目录；`DEFAULT_WEB_ROOT` 是未匹配域名时的默认站点目录；`MYSQL_DATA_DIR` 是 MySQL 数据目录。版本变量留空时安装器交互选择 APT 中可用的版本；也可设为版本选择菜单列出的确切值。首次安装前设置非默认 `MYSQL_DATA_DIR` 时，安装器会把 MySQL 初始化数据迁移到该目录，并保留 `/var/lib/mysql.lnmp-debian.orig` 备份。已安装后更换数据目录需先按 MySQL 的数据迁移流程操作，安装器会拒绝覆盖已有兼容路径。

## 兼容路径

Debian 软件包保留其原生配置、程序和数据位置，并创建旧路径兼容链接：

| 旧路径 | Debian 路径 |
| --- | --- |
| `/usr/local/nginx/conf` | `/etc/nginx` |
| `/usr/local/nginx/sbin/nginx` | `/usr/sbin/nginx` |
| `/usr/local/php/etc` | `/etc/php/<版本>/fpm` |
| `/usr/local/php/bin/php` | `/usr/bin/php` |
| `/usr/local/mysql/var` | `MYSQL_DATA_DIR`（默认 `/var/lib/mysql`） |
| `/etc/my.cnf` | `/etc/mysql/conf.d/lnmp-legacy.cnf` |
| SSL 证书 | `/usr/local/nginx/conf/ssl/` |

默认网站目录为 `/home/wwwroot/default`。安装器直接从 [conf/default-site.conf](./conf/default-site.conf) 部署默认站点配置，并按 `DEFAULT_WEB_ROOT` 设置根目录、`index.php` 和 PHP-FPM 处理。Debian 原始默认配置会在旁边保留 `.lnmp-debian.orig` 备份；如果检测到自定义默认站点，安装器会停止并说明原因，不会覆盖。

虚拟主机配置保留在 `/usr/local/nginx/conf/vhost/`，启用 PHP 的配置保留在 `/usr/local/nginx/conf/enable-php.conf`。Nginx 和 PHP-FPM 使用同一个版本化 socket：`/run/php/php<版本>-fpm.sock`；socket 属主/属组应为 `www:www`，权限为 `0660`。安装器会显式写入 FPM pool 的 socket 设置并关闭会覆盖属主/属组的 ACL 设置，然后在启动服务后检查 socket。

## 管理命令

```sh
lnmp {start|stop|restart|reload|kill|status}
lnmp {nginx|mysql|mariadb|php-fpm} {start|stop|restart|reload|kill|status}
lnmp vhost {add|list|del}
lnmp database {add|list|edit|del}
lnmp addons {install|uninstall} <addon>
lnmp ssl add
lnmp dnsssl {ali|cf|dp|he|gd|aws|namecheap|namesilo}
lnmp onlyssl {ali|cf|dp|he|gd|aws|namecheap|namesilo}
```

修改管理脚本后，可用同步脚本更新系统中的默认 `lnmp` 命令：

```sh
sudo ./sync-lnmp.sh
```

默认同步本目录的 `lnmp` 文件；也可指定另一个脚本，例如 `sudo ./sync-lnmp.sh /path/to/lnmp.sh`。同步前会检查 Bash 语法，并更新 `/usr/local/bin/lnmp`；`/usr/bin/lnmp` 保持为指向它的链接。

`lnmp ssl add` 支持自备证书、Let's Encrypt、BuyPass 和 ZeroSSL；证书与私钥使用旧版目录和命名规则。DNS-01 使用 Debian 的 `acme.sh` 包，需预先设置对应 DNS 服务商要求的 API 环境变量。管理命令不会自动删除网站文件。

`kill` 命令映射为 systemd 的正常停止操作，不会对服务进程发送不可恢复的强制终止信号。

`lnmp status` 会逐项显示 Nginx、MySQL 和 PHP-FPM 的 active/inactive 状态，不输出整机 systemd 状态详情。

## 手动升级

`upgrade.sh` 可从上游来源升级指定版本：

```sh
sudo ./upgrade.sh nginx [版本] [stable|mainline]
sudo ./upgrade.sh php [版本]
sudo ./upgrade.sh mysql [版本]
```

省略组件时会显示交互菜单；省略 Nginx/MySQL 版本时会显示 APT 可用版本并默认选最新。Nginx 使用 nginx.org 官方仓库（stable 默认，也可选 mainline），脚本会先检查配置、在当前用户主目录备份 `/etc/nginx`，然后展示 APT 变更计划。MySQL 使用安装器配置的 Oracle 官方 APT 仓库，并在升级前生成 `/root/mysql-backup-<时间>.sql.gz`。PHP 需要手动输入 php.net 上的完整版本号，从官网源码构建到独立版本目录，并切换 FPM 服务；为兼容当前 Debian PHP 扩展，只允许在已安装的 PHP 8.x 同一 major.minor 分支内升级。PHP 配置和 MySQL 数据备份写入 `/root`。

脚本要求确认 APT 计划或 PHP 源码切换计划；`--yes` 可跳过确认，但必须明确指定版本，例如 `sudo ./upgrade.sh --yes nginx 1.28.0 stable`、`sudo ./upgrade.sh --yes php 8.4.17`。这是绕过 Debian 版本节奏的高风险路径：PHP 切换会停用原 Debian FPM 单元，并将 LNMP 的 `/usr/local/php/bin/php` 和 FPM 服务切到上游构建；系统 `/usr/bin/php` 仍由 Debian 包管理。请先备份并在维护窗口执行。PHP 构建依赖使用 Debian APT，但 PHP 本体来自 php.net；Nginx 官方仓库按当前 LNMP Debian 支持范围限定为 Debian trixie。

`lnmp vhost add` 的站点目录默认使用配置中的 `WEB_ROOT/<域名>`，也可在创建时输入其他绝对路径。伪静态规则恢复了旧版内置模板（如 `wordpress`、`discuzx`、`thinkphp`、`laravel`、`joomla` 等）；创建时可选规则模板，默认不启用。安装器只补齐缺少的模板，不覆盖 `/usr/local/nginx/conf/rewrite/` 中已有的文件。自定义规则可放入该目录的 `<名称>.conf`，创建虚拟主机时选择名称即可；未存在的自定义名称会创建一个空模板供编辑。创建时也可选择 PHP Pathinfo 和 IPv6 监听。

## PHP 扩展

```sh
./addons.sh
./addons.sh install redis
./addons.sh uninstall redis
```

也可使用 `lnmp addons install <名称>` / `lnmp addons uninstall <名称>`。APT 扩展包括 `memcached`、`opcache`、`redis`、`apcu`、`imagemagick`、`exif`、`fileinfo`、`ldap`、`bz2`、`sodium`、`imap` 和 `swoole`（仅在已配置仓库提供时可安装）。Exif、Fileinfo、Sodium 已由 Debian 的 PHP common 包提供，不能单独卸载。

eAccelerator 和 XCache 已不适用于现代 PHP；ionCube、SourceGuardian 等需要独立闭源 Loader，Debian 官方 APT 不提供，因此此版不从第三方下载或安装这些组件。多 PHP 版本、Apache 和 Pure-FTPd 也不在精简版范围内。
