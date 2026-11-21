# LNMP Debian

此目录提供面向 Debian 13 及以上版本的精简安装器和 `lnmp` 管理命令。

## 安装

安装器会先显示 APT 仓库中可用的 PHP、Nginx 和 MySQL 版本供选择；默认选项是当前仓库中最新可用版本，MySQL 只列出 8+。无交互运行时使用默认版本。版本列表来自当前已配置的 APT 源，因此 Debian 官方源只能选择该 Debian 版本实际提供的 PHP/Nginx 版本。

以 root 身份执行：

```sh
cd lnmp-debian
./install.sh
```

Nginx、PHP、ACME 客户端及运行依赖由 Debian APT 安装。MySQL 使用 Oracle 官方 APT 仓库的 MySQL 8.4 LTS 包；当前仓库仅向 amd64 提供 Debian 13 构建。安装器使用 Oracle 2025 更新的仓库签名密钥，并校验其指纹，以避免过期密钥导致 APT 验签失败。脚本不会使用旧版 `Download_Mirror`，也不会自动卸载现有服务；检测到 MariaDB 或未迁移的 MySQL 数据时会停止安装。

安装前请备份数据。MySQL 安装可能需要在终端完成软件包配置。

## 配置文件

安装前编辑目录中的 [lnmp-debian.conf](./lnmp-debian.conf)，或安装后编辑 `/etc/lnmp-debian.conf`：

```sh
WEB_ROOT="/home/wwwroot"
DEFAULT_WEB_ROOT="/home/wwwroot/default"
NGINX_LOG_DIR="/var/log/nginx"
MYSQL_DATA_DIR="/var/lib/mysql"
PHP_VERSION=""
NGINX_VERSION=""
MYSQL_VERSION=""
```

`WEB_ROOT` 是新建虚拟主机的默认父目录；`DEFAULT_WEB_ROOT` 是未匹配域名时的默认站点目录；`MYSQL_DATA_DIR` 是 MySQL 数据目录。版本变量留空时安装器交互选择 APT 中可用的版本；也可设为版本选择菜单列出的确切值。首次安装前设置非默认 `MYSQL_DATA_DIR` 时，安装器会把 MySQL 初始化数据迁移到该目录，并保留 `/var/lib/mysql.lnmp-debian.orig` 备份。已安装后更换数据目录需先按 MySQL 的数据迁移流程操作，安装器会拒绝覆盖已有数据。

## Debian 配置路径

安装器使用 Debian 软件包的原生配置和程序路径，不创建旧版 `/usr/local` 配置路径的兼容链接。Nginx 主配置位于 `/etc/nginx/nginx.conf`，虚拟主机使用 Debian 的 `sites-available` / `sites-enabled` 布局，PHP 和 rewrite 片段位于 `/etc/nginx/snippets` 与 `/etc/nginx/rewrite`，证书位于 `/etc/nginx/ssl`。PHP-FPM 配置位于 `/etc/php/<版本>/fpm`，MySQL 沿用 Debian 默认的 `/etc/mysql` 配置目录（仅当 `MYSQL_DATA_DIR` 设为非默认值时，安装器会写入 `/etc/mysql/mysql.conf.d/zz-lnmp-debian.cnf` 指定数据目录），默认数据目录为 `/var/lib/mysql`，Nginx 日志默认位于 `/var/log/nginx`。

默认网站目录为 `/home/wwwroot/default`。安装器直接从 [conf/default-site.conf](./conf/default-site.conf) 部署默认站点配置，并按 `DEFAULT_WEB_ROOT` 设置根目录、`index.php` 和 PHP-FPM 处理。Debian 原始默认配置会在旁边保留 `.lnmp-debian.orig` 备份；如果检测到自定义默认站点，安装器会停止并说明原因，不会覆盖。

每个虚拟主机的完整配置为 `/etc/nginx/sites-available/<域名>.conf`，并通过 `/etc/nginx/sites-enabled/<域名>.conf` 符号链接启用（链接指向 `../sites-available/<域名>.conf`）。默认站点的对应路径为 `/etc/nginx/sites-available/default` 与 `/etc/nginx/sites-enabled/default`。伪静态规则位于 `/etc/nginx/rewrite/<名称>.conf`，PHP 处理片段位于 `/etc/nginx/snippets/`（如 `enable-php.conf`、`enable-php-pathinfo.conf`、`pathinfo.conf`）；HTTPS 证书与私钥位于 `/etc/nginx/ssl/<域名>/`。

Socket 与运行约定：Nginx 和 PHP-FPM 使用同一个版本化 socket：`/run/php/php<版本>-fpm.sock`；socket 属主/属组应为 `www:www`，权限为 `0660`。安装器会显式写入 FPM pool 的 socket 设置并关闭会覆盖属主/属组的 ACL 设置，然后在启动服务后检查 socket。

## 安装器备份文件（`.lnmp-debian.orig`）

安装器在改动系统已有的文件或目录前，会在**原路径旁**留一份后缀为 `.lnmp-debian.orig` 的备份，便于人工比对和恢复。备份路径与原件一一对应，即 `原路径 + .lnmp-debian.orig`。

这些备份只在安装时产生。文件备份使用 `cp -n`（目标已存在就不覆盖），因此重复运行安装不会改写首次快照；MySQL 数据目录一处例外，用 `mv` 改名（见下）。安装器**不读取、不回滚、不自动删除**这些备份。可能产生的情况分三类：

### 一、Debian 包配置文件（就地修改前备份）

| 备份路径 | 产生条件 | 安装器对原件的改动 |
| --- | --- | --- |
| `/etc/nginx/nginx.conf.lnmp-debian.orig` | `/etc/nginx/nginx.conf` 作为普通文件存在时 | 把 `user www-data;` 改为 `user www;` |
| `/etc/nginx/sites-available/default.lnmp-debian.orig` | 默认站点文件存在，且**不是**本安装器生成的（不含 `# Managed by LNMP Debian.` 标记），即 Debian 原始默认站点（含 `root /var/www/html;`） | 用 `conf/default-site.conf` 渲染后的内容整体替换 |
| `/etc/php/<版本>/fpm/pool.d/www.conf.lnmp-debian.orig` | 执行 PHP-FPM 配置时总会尝试（文件存在即备份） | 写入 `user`/`group` = `www`、socket = `/run/php/php<版本>-fpm.sock`、`listen.owner`/`listen.group` = `www`、`listen.mode` = `0660`，并注释掉 `listen.acl_users`/`listen.acl_groups` |

补充两点：

- 若 `sites-available/default` 是用户自定义内容（既无 Managed 标记，也不是 Debian 原始的 `root /var/www/html;`），安装器会**中止安装而不覆盖**，也不会产生备份；已由本安装器管理的默认站点（含 Managed 标记）会被重新生成，但不会再次备份。
- `/etc/php/<版本>/fpm/php-fpm.conf` 的 `pid` 设置也会被安装器改写，但该文件**不产生** `.lnmp-debian.orig` 备份。

### 二、MySQL 数据目录（迁移时改名）

| 备份路径 | 产生条件 | 说明 |
| --- | --- | --- |
| `/var/lib/mysql.lnmp-debian.orig` | `MYSQL_DATA_DIR` 设为非默认值，且 `/var/lib/mysql` 尚未指向该目录 | 先把 `/var/lib/mysql` 的内容复制到新目录，再把原目录**整个改名**为备份，最后在原位置建立指向新目录的软链 |

这是唯一用 `mv`（而非 `cp -n`）产生的备份，体积也最大；若备份路径已存在，安装器会中止以免覆盖。手动恢复时需先移除 `/var/lib/mysql` 软链，再把备份目录改回 `/var/lib/mysql`。

### 三、管理命令文件（防止覆盖同名文件）

| 备份路径 | 产生条件 |
| --- | --- |
| `/usr/local/bin/lnmp.lnmp-debian.orig` | 该路径是普通文件（非软链），或是软链但指向的不是本目录的 `lnmp` |
| `/usr/bin/lnmp.lnmp-debian.orig` | 该路径是普通文件（非软链），或是软链但指向的不是 `/usr/local/bin/lnmp` |

这两处防的是覆盖来路不明的同名文件：若已经是指向正确目标的软链，安装器直接重建软链，不产生备份。安装后 `/usr/local/bin/lnmp` 是脚本实体，`/usr/bin/lnmp` 指向它。

## 管理命令

```sh
lnmp {start|stop|restart|reload|kill|status}
lnmp {nginx|mysql|mariadb|php-fpm} {start|stop|restart|reload|kill|status}
lnmp vhost {add|list|del}
lnmp addons {install|uninstall} <addon>
lnmp ssl {add|auto-renew}
lnmp dnsssl {ali|cf|dp|he|gd|aws|namecheap|namesilo}
lnmp onlyssl {ali|cf|dp|he|gd|aws|namecheap|namesilo}
```

修改管理脚本后，可用同步脚本更新系统中的默认 `lnmp` 命令：

```sh
sudo ./sync-lnmp.sh
```

默认同步本目录的 `lnmp` 文件；也可指定另一个脚本，例如 `sudo ./sync-lnmp.sh /path/to/lnmp.sh`。同步前会检查 Bash 语法，并更新 `/usr/local/bin/lnmp`；`/usr/bin/lnmp` 保持为指向它的链接。

`lnmp` 只管理 MySQL 服务，不创建、修改或删除数据库及数据库用户；数据库内容由应用部署流程管理。`lnmp ssl add` 支持自备证书、Let's Encrypt、BuyPass 和 ZeroSSL；证书与私钥位于 `/etc/nginx/ssl/<域名>/`。通过 ACME 签发证书时会启用 `lnmp-acme-renew.timer`，每天调用 `acme.sh --cron` 检查续签；证书更新后执行 Nginx reload。已有 ACME 证书的服务器可运行 `sudo lnmp ssl auto-renew` 一次启用定时检查。DNS-01 使用 Debian 的 `acme.sh` 包，需预先设置对应 DNS 服务商要求的 API 环境变量。自备证书不由脚本续签。管理命令不会自动删除网站文件。

可在服务器上确认它是否已启用及下次运行时间
`systemctl status lnmp-acme-renew.timer`
`systemctl list-timers lnmp-acme-renew.timer`
查看运行记录：（日志由 systemd-journald 可调整总体大小，以自动清理）
`journalctl -u lnmp-acme-renew.service`

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

脚本要求确认 APT 计划或 PHP 源码切换计划；`--yes` 可跳过确认，但必须明确指定版本，例如 `sudo ./upgrade.sh --yes nginx 1.28.0 stable`、`sudo ./upgrade.sh --yes php 8.4.17`。这是绕过 Debian 版本节奏的高风险路径：PHP 切换会停用原 Debian FPM 单元并将 FPM 服务切到上游构建；系统 PHP CLI 仍由 Debian 包管理。请先备份并在维护窗口执行。PHP 构建依赖使用 Debian APT，但 PHP 本体来自 php.net；Nginx 官方仓库按当前 LNMP Debian 支持范围限定为 Debian trixie。

`lnmp vhost add` 的站点目录默认使用配置中的 `WEB_ROOT/<域名>`，也可在创建时输入其他绝对路径。伪静态规则恢复了旧版内置模板（如 `wordpress`、`discuzx`、`thinkphp`、`laravel`、`joomla` 等）；创建时可选规则模板，默认不启用。安装器只补齐缺少的模板，不覆盖 `/etc/nginx/rewrite/` 中已有的文件。自定义规则可放入该目录的 `<名称>.conf`，创建虚拟主机时选择名称即可；未存在的自定义名称会创建一个空模板供编辑。创建时也可选择 PHP Pathinfo 和 IPv6 监听。

## PHP 扩展

```sh
./addons.sh
./addons.sh install redis
./addons.sh uninstall redis
```

也可使用 `lnmp addons install <名称>` / `lnmp addons uninstall <名称>`。APT 扩展包括 `memcached`、`opcache`、`redis`、`apcu`、`imagemagick`、`exif`、`fileinfo`、`ldap`、`bz2`、`sodium`、`imap` 和 `swoole`（仅在已配置仓库提供时可安装）。Exif、Fileinfo、Sodium 已由 Debian 的 PHP common 包提供，不能单独卸载。

eAccelerator 和 XCache 已不适用于现代 PHP；ionCube、SourceGuardian 等需要独立闭源 Loader，Debian 官方 APT 不提供，因此此版不从第三方下载或安装这些组件。多 PHP 版本、Apache 和 Pure-FTPd 也不在精简版范围内。
