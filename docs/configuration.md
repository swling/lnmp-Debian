# 配置文件

安装前编辑目录中的 [lnmp-debian.conf](../lnmp-debian.conf)，或安装后编辑 `/etc/lnmp-debian.conf`：

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

默认网站目录为 `/home/wwwroot/default`。安装器直接从 [conf/default-site.conf](../conf/default-site.conf) 部署默认站点配置，并按 `DEFAULT_WEB_ROOT` 设置根目录、`index.php` 和 PHP-FPM 处理。Debian 原始默认配置会在旁边保留 `.lnmp-debian.orig` 备份；如果检测到自定义默认站点，安装器会停止并说明原因，不会覆盖。

每个虚拟主机的完整配置为 `/etc/nginx/sites-available/<域名>.conf`，并通过 `/etc/nginx/sites-enabled/<域名>.conf` 符号链接启用（链接指向 `../sites-available/<域名>.conf`）。默认站点的对应路径为 `/etc/nginx/sites-available/default` 与 `/etc/nginx/sites-enabled/default`。伪静态规则位于 `/etc/nginx/rewrite/<名称>.conf`，PHP 处理片段位于 `/etc/nginx/snippets/`（如 `enable-php.conf`、`enable-php-pathinfo.conf`、`pathinfo.conf`）；HTTPS 证书与私钥位于 `/etc/nginx/ssl/<域名>/`。

Socket 与运行约定：Nginx 和 PHP-FPM 使用同一个版本化 socket：`/run/php/php<版本>-fpm.sock`；socket 属主/属组应为 `www:www`，权限为 `0660`。安装器会显式写入 FPM pool 的 socket 设置并关闭会覆盖属主/属组的 ACL 设置，然后在启动服务后检查 socket。
