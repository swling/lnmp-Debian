建议直接备份 Debian 的配置目录。下面的 PHP 路径版本号请替换成服务器实际安装版本；若未安装 Redis，可跳过 Redis 命令：

```sh
sudo install -d -m 700 /home/bf

sudo tar -czpf /home/bf/nginx-conf.tar.gz -C /etc/nginx
sudo tar -czpf /home/bf/php-conf.tar.gz -C /etc/php/8.4
sudo tar -czpf /home/bf/mysql-conf.tar.gz -C /etc/mysql
sudo tar -czpf /home/bf/mysql-conf.tar.gz -C /etc/mysql
```

恢复前先备份目标服务器当前配置，再从备份中**按需覆盖**，不要先删除配置目录：

```sh
sudo tar -xzpf /home/bf/nginx-conf.tar.gz -C /
sudo tar -xzpf /home/bf/php-conf.tar.gz -C /
sudo tar -xzpf /home/bf/mysql-conf.tar.gz -C /
```

恢复 Nginx 时，只取需要的公共配置；不同服务器的站点配置应单独核对，不要盲目覆盖。恢复后至少运行 `sudo nginx -t`，并检查对应版本的 PHP-FPM 配置及相关服务状态，再重载或重启服务。