# 配置文件

安装前编辑目录中的 [lnmp-debian.conf](../lnmp-debian.conf)，或安装后编辑 `/etc/lnmp-debian.conf`：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `WEB_ROOT` | `/home/wwwroot` | 新建虚拟主机的默认父目录 |
| `DEFAULT_WEB_ROOT` | `${WEB_ROOT}/default` | 未匹配域名时的默认站点目录 |
| `NGINX_LOG_DIR` | `/var/log/nginx` | Nginx 日志目录 |
| `MYSQL_DATA_DIR` | `/var/lib/mysql` | MySQL 数据目录 |
| `PHP_VERSION` | 空 | 留空则交互选择 APT 中可用版本 |
| `NGINX_VERSION` | 空 | 同上 |
| `MYSQL_VERSION` | 空 | 同上 |
| `NGINX_CHANNEL` | `stable` | nginx.org 通道：`stable` / `mainline`；安装时选源，升级时也可用命令参数覆盖 |

```sh
WEB_ROOT="/home/wwwroot"
DEFAULT_WEB_ROOT="/home/wwwroot/default"
NGINX_LOG_DIR="/var/log/nginx"
MYSQL_DATA_DIR="/var/lib/mysql"
PHP_VERSION=""
NGINX_VERSION=""
MYSQL_VERSION=""
NGINX_CHANNEL="stable"
```

## 版本变量规则

| 组件 | 版本来源 | 留空时 | 非留空时 |
| --- | --- | --- | --- |
| PHP | Debian APT | 交互选择，默认最新 | 作为菜单默认；已不在源中则警告并回退到可用版本 |
| Nginx | nginx.org APT | 交互选择，默认最新 | 作为菜单默认；已不在源中则警告并回退到可用版本 |
| MySQL | Oracle APT | 交互选择，默认最高 LTS | 作为菜单默认，须为菜单中的确切值，否则报错退出 |

- MySQL 不写死版本：安装器动态发现 Oracle 仓库全部 Server 组件，菜单标注 LTS / 创新版，默认选版本最高的 LTS。
- PHP / Nginx 的配置版本若因 APT 源更新而已不可用，安装器只警告并回退到当前可用版本，避免卸载后重装被旧版本号卡住。
- MySQL 版本涉及数据兼容性，配置值不在菜单中时仍报错退出。

## MySQL 数据目录迁移

| 项目 | 说明 |
| --- | --- |
| 触发条件 | 首次安装前设置非默认 `MYSQL_DATA_DIR` |
| 安装器动作 | 把 MySQL 初始化数据迁移到该目录 |
| 备份 | 保留 `/var/lib/mysql.lnmp-debian.orig` |
| 卸载后重装 | `mysql-community-server` 未安装且 `MYSQL_DATA_DIR` 已有数据时，提示输入 `clear` 全新安装或终止；自定义目录在装包成功后清空，默认 `/var/lib/mysql` 确认后立即清空；不做复用判断 |
| 已安装后更换 | 未安装 MySQL 包且该目录已有数据时会提示；选择清空后按新安装流程迁移，否则终止 |

## 路径速查

| 用途 | 路径 |
| --- | --- |
| Nginx 主配置 | `/etc/nginx/nginx.conf` |
| 站点配置 | `/etc/nginx/conf.d/<域名>.conf`，由 nginx.org 包的 `include /etc/nginx/conf.d/*.conf;` 自动加载 |
| 默认站点 | `/etc/nginx/conf.d/default.conf` |
| Nginx 复用片段 | `/etc/nginx/snippets/`（`enable-php.conf`、`enable-php-pathinfo.conf`、`pathinfo.conf`） |
| 伪静态规则 | `/etc/nginx/rewrite/<名称>.conf` |
| 通用配置片段 | `/etc/nginx/cache-static.conf`，需自行 `include cache-static.conf;` |
| FastCGI 参数 | 使用 nginx.org 包自带的 `/etc/nginx/fastcgi_params`，PHP 片段额外显式设置 `SCRIPT_FILENAME` |
| SSL 证书与私钥 | `/etc/nginx/ssl/<域名>/` |
| PHP-FPM 配置 | `/etc/php/<版本>/fpm` |
| MySQL 配置 | `/etc/mysql`（自定义数据目录时写入 `mysql.conf.d/zz-lnmp-debian.cnf`） |
| MySQL 数据 | `/var/lib/mysql`（默认），自定义时按 `MYSQL_DATA_DIR` |
| Nginx 日志 | `/var/log/nginx`（默认） |
| PHP-FPM socket | `/run/php/php<版本>-fpm.sock`，属主 `www:www`，权限 `0660` |

## 配置行为要点

| 主题 | 说明 |
| --- | --- |
| 配置路径策略 | 安装与升级均使用 nginx.org 官方包，配置也采用其原生布局：站点直接写入 `/etc/nginx/conf.d/`，不创建 `sites-available` / `sites-enabled`，也不修改 `nginx.conf` 的 include。不创建旧版 `/usr/local` 配置路径的兼容链接 |
| 访问日志 | 安装器在 `nginx.conf` 的 `http` 块中设置 `access_log off;`；默认站点及未显式配置访问日志的 vhost 不写日志，`lnmp vhost add` 中启用访问日志的站点在自己的 server 块写入独立 `access_log` 并覆盖该默认值 |
| 通用片段部署 | 项目 `conf/` 目录中的片段（目前为 `cache-static.conf`）复制到 `/etc/nginx/`，该文件不被 `nginx.conf` 自动加载；已有同名片段不覆盖 |
| FastCGI 兼容 | `enable-php.conf` / `enable-php-pathinfo.conf` 使用 nginx.org 包自带的 `fastcgi_params`，并显式写入 `fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;`，不依赖 Debian 包才有的 `fastcgi.conf` |
| 新 vhost | 自动 `include cache-static.conf;`，不再生成重复的静态文件 location 块；已有主机需自行添加该 include 并移除重叠的静态 location |
| 默认站点部署 | 从 [conf/default-site.conf](../conf/default-site.conf) 渲染到 `/etc/nginx/conf.d/default.conf`，按 `DEFAULT_WEB_ROOT` 设置根目录、`index.php` 和 PHP-FPM 处理；安装时直接覆盖已有文件（包括 nginx.org 包自带的原始默认站点），不做内容判断 |
| 卸载时的配置清理 | `uninstall.sh` 删除 `mysql.conf.d/zz-lnmp-debian.cnf` 及 AppArmor 中为独立磁盘数据目录追加的规则；`conf.d/default.conf` 不删除，因安装时本就直接覆盖。用户自建的 `conf.d/<域名>.conf`、网站文件、SSL 证书、日志、ACME 数据和 MySQL 数据目录/初始备份均保留 |
| Socket 约定 | Nginx 与 PHP-FPM 共用同一个版本化 socket；安装器写入 FPM pool 的 socket/属主/权限设置、关闭会覆盖属主/属组的 ACL 设置，并把 `nginx.conf` 的 worker 用户设为 `www`（nginx.org 包默认 `nginx`），匹配 `www:www` 的 socket；启动后检查 socket 属主 |

更完整的目录树见 [Debian LNMP 目录结构速查表](../nmp-path.md)。
