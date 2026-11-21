# 安装器备份文件（`.lnmp-debian.orig`）

安装器在改动系统已有的文件或目录前，会在**原路径旁**留一份后缀为 `.lnmp-debian.orig` 的备份，便于人工比对和恢复。备份路径与原件一一对应，即 `原路径 + .lnmp-debian.orig`。

这些备份只在安装时产生。文件备份使用 `cp -n`（目标已存在就不覆盖），因此重复运行安装不会改写首次快照；MySQL 数据目录一处例外，用 `mv` 改名（见下）。安装器**不读取、不回滚、不自动删除**这些备份。可能产生的情况分三类：

## 一、Debian 包配置文件（就地修改前备份）

| 备份路径 | 产生条件 | 安装器对原件的改动 |
| --- | --- | --- |
| `/etc/nginx/nginx.conf.lnmp-debian.orig` | `/etc/nginx/nginx.conf` 作为普通文件存在时 | 把 `user www-data;` 改为 `user www;` |
| `/etc/nginx/sites-available/default.lnmp-debian.orig` | 默认站点文件存在，且**不是**本安装器生成的（不含 `# Managed by LNMP Debian.` 标记），即 Debian 原始默认站点（含 `root /var/www/html;`） | 用 `conf/default-site.conf` 渲染后的内容整体替换 |
| `/etc/php/<版本>/fpm/pool.d/www.conf.lnmp-debian.orig` | 执行 PHP-FPM 配置时总会尝试（文件存在即备份） | 写入 `user`/`group` = `www`、socket = `/run/php/php<版本>-fpm.sock`、`listen.owner`/`listen.group` = `www`、`listen.mode` = `0660`，并注释掉 `listen.acl_users`/`listen.acl_groups` |

补充两点：

- 若 `sites-available/default` 是用户自定义内容（既无 Managed 标记，也不是 Debian 原始的 `root /var/www/html;`），安装器会**中止安装而不覆盖**，也不会产生备份；已由本安装器管理的默认站点（含 Managed 标记）会被重新生成，但不会再次备份。
- `/etc/php/<版本>/fpm/php-fpm.conf` 的 `pid` 设置也会被安装器改写，但该文件**不产生** `.lnmp-debian.orig` 备份。

## 二、MySQL 数据目录（迁移时改名）

| 备份路径 | 产生条件 | 说明 |
| --- | --- | --- |
| `/var/lib/mysql.lnmp-debian.orig` | `MYSQL_DATA_DIR` 设为非默认值，且 `/var/lib/mysql` 尚未指向该目录 | 先把 `/var/lib/mysql` 的内容复制到新目录，再把原目录**整个改名**为备份，最后在原位置建立指向新目录的软链 |

这是唯一用 `mv`（而非 `cp -n`）产生的备份，体积也最大；若备份路径已存在，安装器会中止以免覆盖。手动恢复时需先移除 `/var/lib/mysql` 软链，再把备份目录改回 `/var/lib/mysql`。

## 三、管理命令文件（防止覆盖同名文件）

| 备份路径 | 产生条件 |
| --- | --- |
| `/usr/local/bin/lnmp.lnmp-debian.orig` | 该路径是普通文件（非软链），或是软链但指向的不是本目录的 `lnmp` |
| `/usr/bin/lnmp.lnmp-debian.orig` | 该路径是普通文件（非软链），或是软链但指向的不是 `/usr/local/bin/lnmp` |

这两处防的是覆盖来路不明的同名文件：若已经是指向正确目标的软链，安装器直接重建软链，不产生备份。安装后 `/usr/local/bin/lnmp` 是脚本实体，`/usr/bin/lnmp` 指向它。
