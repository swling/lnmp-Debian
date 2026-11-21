# ACME 证书

## 证书签发与续签

`lnmp ssl add` 支持自备证书、Let's Encrypt、BuyPass 和 ZeroSSL；证书与私钥位于 `/etc/nginx/ssl/<域名>/`。通过 ACME 签发证书时会启用 `lnmp-acme-renew.timer`，每天调用 `acme.sh --cron` 检查续签；证书更新后执行 Nginx reload。已有 ACME 证书的服务器可运行 `sudo lnmp ssl auto-renew` 一次启用定时检查。DNS-01 使用 Debian 的 `acme.sh` 包，需预先设置对应 DNS 服务商要求的 API 环境变量。自备证书不由脚本续签。

## 检查续签定时任务

可在服务器上确认它是否已启用及下次运行时间

```sh
systemctl status lnmp-acme-renew.timer
systemctl list-timers lnmp-acme-renew.timer
```

查看运行记录：（日志由 systemd-journald 可调整总体大小，以自动清理）

```sh
journalctl -u lnmp-acme-renew.service
```

## 查看证书

查看 acme.sh 管理的证书（`--home /usr/local/acme.sh` 是程序目录；数据目录以 `--config-home /etc/nginx/ssl` 指定，证书在该目录下按域名原位生成，无需复制）

```sh
/usr/bin/acme.sh --home /usr/local/acme.sh --config-home /etc/nginx/ssl --list
```

[link](https://github.com/acmesh-official/acme.sh/wiki/How-to-install#4-advanced-installation)
