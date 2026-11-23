# 管理命令

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

`lnmp` 只管理 MySQL 服务，不创建、修改或删除数据库及数据库用户；数据库内容由应用部署流程管理。

`lnmp vhost add/list/del` 直接操作 `/etc/nginx/conf.d/<域名>.conf`，不使用 `sites-available` / `sites-enabled` 软链。

管理命令不会自动删除网站文件。

`kill` 命令映射为 systemd 的正常停止操作，不会对服务进程发送不可恢复的强制终止信号。

服务启动、停止、重启、重载前会先执行 `systemctl daemon-reload`，避免包升级后 unit 文件变化产生警告。

`lnmp status` 会逐项显示 Nginx、MySQL 和 PHP-FPM 的 active/inactive 状态，不输出整机 systemd 状态详情。
