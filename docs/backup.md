# 安装器备份文件（`.lnmp-debian.orig`）

安装器在改动系统已有的文件或目录前，会在**原路径旁**留一份后缀为 `.lnmp-debian.orig` 的备份，便于人工比对和恢复。备份路径与原件一一对应，即 `原路径 + .lnmp-debian.orig`。

这些备份只在安装时产生。备份使用 `cp -n`（目标已存在就不覆盖），因此重复运行安装不会改写首次快照。安装器**不读取、不回滚、不自动删除**这些备份。可能产生的情况分两类：

## 一、已有配置文件（就地修改前备份）

| 备份路径 | 产生条件 | 安装器对原件的改动 |
| --- | --- | --- |
| `/etc/nginx/nginx.conf.lnmp-debian.orig` | `/etc/nginx/nginx.conf` 作为普通文件存在时 | 把任意 `user ...;` 改为 `user www;`（缺失则补写），并把 http 层 `access_log` 改为 `off` |
| `/etc/php/<版本>/fpm/pool.d/www.conf.lnmp-debian.orig` | 执行 PHP-FPM 配置时总会尝试（文件存在即备份） | 写入 `user`/`group` = `www`、socket = `/run/php/php<版本>-fpm.sock`、`listen.owner`/`listen.group` = `www`、`listen.mode` = `0660`，并注释掉 `listen.acl_users`/`listen.acl_groups` |

补充两点：

- `/etc/nginx/conf.d/default.conf` 不产生 `.lnmp-debian.orig`：安装时直接从模板重新生成并覆盖，包括 nginx.org 包自带的原始默认站点。
- `/etc/php/<版本>/fpm/php-fpm.conf` 的 `pid` 设置也会被安装器改写，但该文件**不产生** `.lnmp-debian.orig` 备份。

## 二、管理命令文件（防止覆盖同名文件）

| 备份路径 | 产生条件 |
| --- | --- |
| `/usr/local/bin/lnmp.lnmp-debian.orig` | 该路径是普通文件（非软链），或是软链但指向的不是本目录的 `lnmp` |
| `/usr/bin/lnmp.lnmp-debian.orig` | 该路径是普通文件（非软链），或是软链但指向的不是 `/usr/local/bin/lnmp` |

这两处防的是覆盖来路不明的同名文件：若已经是指向正确目标的软链，安装器直接重建软链，不产生备份。安装后 `/usr/local/bin/lnmp` 是脚本实体，`/usr/bin/lnmp` 指向它。
