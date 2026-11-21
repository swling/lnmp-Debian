# 手动升级

`upgrade.sh` 可从上游来源升级指定版本：

```sh
sudo ./upgrade.sh nginx [版本] [stable|mainline]
sudo ./upgrade.sh php [版本]
sudo ./upgrade.sh mysql [版本]
```

省略组件时会显示交互菜单；省略 Nginx/MySQL 版本时会显示 APT 可用版本并默认选最新。Nginx 使用 nginx.org 官方仓库（stable 默认，也可选 mainline），脚本会先检查配置、在当前用户主目录备份 `/etc/nginx`，然后展示 APT 变更计划。MySQL 使用安装器配置的 Oracle 官方 APT 仓库，并在升级前生成 `/root/mysql-backup-<时间>.sql.gz`。PHP 需要手动输入 php.net 上的完整版本号，从官网源码构建到独立版本目录，并切换 FPM 服务；为兼容当前 Debian PHP 扩展，只允许在已安装的 PHP 8.x 同一 major.minor 分支内升级。PHP 配置和 MySQL 数据备份写入 `/root`。

脚本要求确认 APT 计划或 PHP 源码切换计划；`--yes` 可跳过确认，但必须明确指定版本，例如 `sudo ./upgrade.sh --yes nginx 1.28.0 stable`、`sudo ./upgrade.sh --yes php 8.4.17`。这是绕过 Debian 版本节奏的高风险路径：PHP 切换会停用原 Debian FPM 单元并将 FPM 服务切到上游构建；系统 PHP CLI 仍由 Debian 包管理。请先备份并在维护窗口执行。PHP 构建依赖使用 Debian APT，但 PHP 本体来自 php.net；Nginx 官方仓库按当前 LNMP Debian 支持范围限定为 Debian trixie。

`lnmp vhost add` 的站点目录默认使用配置中的 `WEB_ROOT/<域名>`，也可在创建时输入其他绝对路径。伪静态规则恢复了旧版内置模板（如 `wordpress`、`discuzx`、`thinkphp`、`laravel`、`joomla` 等）；创建时可选规则模板，默认不启用。安装器只补齐缺少的模板，不覆盖 `/etc/nginx/rewrite/` 中已有的文件。自定义规则可放入该目录的 `<名称>.conf`，创建虚拟主机时选择名称即可；未存在的自定义名称会创建一个空模板供编辑。创建时也可选择 PHP Pathinfo 和 IPv6 监听。
