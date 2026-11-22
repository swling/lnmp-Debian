# ACME 证书

## 证书签发与续签

证书签发入口有两组：`lnmp ssl add`（已有 vhost，HTTP-01）和 `lnmp vhost add` 中选择添加证书；`lnmp dnsssl` / `lnmp dns` / `lnmp onlyssl`（DNS-01，后两者现为同义词，均只签发证书）。支持 Let's Encrypt 和 ZeroSSL；证书与私钥位于 `/etc/nginx/ssl/<域名>/`。BuyPass 已停止申请服务，自备证书选项也已移除。

所有签发入口行为一致：**只负责签发/放置证书，不修改 vhost 配置或任何 Nginx conf，不自动 reload Nginx**；HTTP-01 也不会询问站点目录（webroot 从 vhost 的 `root` 读取，新建 vhost 则沿用创建时的目录）。命令结束后会打印证书与私钥路径，需要自行在 vhost 的 443 server 块中添加 `ssl_certificate` 与 `ssl_certificate_key`，确认配置后自行执行 `nginx -t && systemctl reload nginx`。

通过 ACME 签发证书时会启用 `lnmp-acme-renew.timer`，每天调用 `acme.sh --cron` 检查续签；证书更新后由签发时的 `--renew-hook` 执行 Nginx reload。
已有 ACME 证书的服务器可运行 `sudo lnmp ssl auto-renew` 一次启用定时检查。
DNS-01 使用 Debian 的 `acme.sh` 包，需预先设置对应 DNS 服务商要求的 API 环境变量。

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

查看 acme.sh 管理的证书（`--home /usr/local/acme.sh` 是程序目录；证书目录以 `--certhome /etc/nginx/ssl` 指定，证书在该目录下按域名原位生成，无需复制；配置与账户密钥仍在 acme.sh 默认配置目录）

```sh
/usr/bin/acme.sh --home /usr/local/acme.sh --certhome /etc/nginx/ssl --list
```

不带 `--certhome` 时 `acme.sh --list` 为空是预期行为：证书不在默认配置目录，需始终带上完整参数。续签 timer 已显式带 `--certhome`，自动续签不受影响。

## 验证续签链路

先看例行续签检查是否正常：

```sh
systemctl start lnmp-acme-renew.service
journalctl -u lnmp-acme-renew.service -n 50
```

日志中出现 `Renewing: '<域名>'` 与 `Skipping. Next renewal time is: ...`，表示证书能被定位、域名 conf 元数据完整，调度正常。未到续签期时跳过属正常。

若要验证完整链路（CA 交互、账户密钥、证书落盘、Nginx reload），可强制续签一次。**注意：这会真实签发新证书，消耗 CA 签发额度，并触发 renew-hook 执行 reload。**

```sh
/usr/bin/acme.sh --home /usr/local/acme.sh --certhome /etc/nginx/ssl --renew -d <域名> --force --debug 2
```

成功时输出包含证书写入 `/etc/nginx/ssl/<域名>/` 的路径提示，以及 `Running renew hook: 'systemctl reload nginx'`。其中 `'/home/wwwroot/default' does not contain 'dns'`、`The NOTIFY_HOOK is empty` 为无害提示，非错误。

## 参数解读
[link](https://github.com/acmesh-official/acme.sh/wiki/How-to-install#4-advanced-installation)

--home is a customized dir to install acme.sh in. By default, it installs into ~/.acme.sh
--config-home is a writable folder, acme.sh will write all the files(including cert/keys, configs) there. By default, it's in --home
--cert-home is a customized dir to save the certs you issue. By default, it's saved in --config-home.
--accountemail is the email used to register an account to Let's Encrypt, you will receive a renewal notice email here.
--accountkey is the file saving your account private key. By default, it's saved in --config-home.
--useragent is the user-agent header value used to send to Let's Encrypt.
--nocron install acme.sh without cronjob