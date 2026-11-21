# PHP 扩展

```sh
./addons.sh
./addons.sh install redis
./addons.sh uninstall redis
```

也可使用 `lnmp addons install <名称>` / `lnmp addons uninstall <名称>`。APT 扩展包括 `memcached`、`opcache`、`redis`、`apcu`、`imagemagick`、`exif`、`fileinfo`、`ldap`、`bz2`、`sodium`、`imap` 和 `swoole`（仅在已配置仓库提供时可安装）。Exif、Fileinfo、Sodium 已由 Debian 的 PHP common 包提供，不能单独卸载。

eAccelerator 和 XCache 已不适用于现代 PHP；ionCube、SourceGuardian 等需要独立闭源 Loader，Debian 官方 APT 不提供，因此此版不从第三方下载或安装这些组件。多 PHP 版本、Apache 和 Pure-FTPd 也不在精简版范围内。
