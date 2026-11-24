# 手动升级

`upgrade.sh` 按组件从不同来源升级：

| 组件 | 升级来源 | 方式 |
| --- | --- | --- |
| Nginx | nginx.org 官方 APT 仓库（stable / mainline） | 配置仓库、校验签名、设置 Pin 优先级，`apt-get install nginx=<版本>` |
| MySQL | Oracle MySQL 8.4 LTS 官方 APT 仓库（由 `install.sh` 配置） | `apt-get install mysql-server=<版本>` |
| PHP | sury 第三方 APT 仓库（默认）；php.net 源码（`--source`） | 配置 sury 仓库并用 `apt-get install php<分支>-fpm=<版本>` 升级，可跨 major.minor；源码路径编译到独立目录，仅限同一分支内 |

```sh
sudo ./upgrade.sh nginx [版本] [stable|mainline]
sudo ./upgrade.sh php [版本]
sudo ./upgrade.sh php --source [版本]   #  php.net 源码编译路径
sudo ./upgrade.sh mysql [版本]
```

在交互终端下，省略组件时会显示交互菜单；省略 Nginx/MySQL 版本时会显示 APT 可用版本并默认选最新；PHP 省略版本时会列出 sury 可用分支并默认选最新。脚本不会自动备份任何数据或配置，升级前请自行备份。交互运行时会先显示风险警告，必须输入 `yes` 才继续；非交互环境没有终端输入，必须显式指定组件和版本并加 `--yes`，否则脚本会在产生任何副作用（包括修改 APT 源）之前直接报错退出。Nginx 升级前会执行 `nginx -t`，安装完成后重启 Nginx 并确认服务处于 active 状态。

### 关于软件来源

- **PHP 没有官方 Linux APT 仓库**：php.net 只发布源码，Debian 的 `php8.x-*` 包由发行版打包、版本受 Debian 节奏限制。因此安装器与升级脚本均默认使用第三方仓库 **deb.sury.org**（并非 PHP 官方仓库），校验签名指纹后设置 Pin 优先级 900，以优先于 Debian 同名包，可跨 major.minor 分支升级。若坚持使用上游官方源码，可显式加 `--source` 走 php.net tarball 编译路径，该遗留路径仅限同一 major.minor 分支内升级。
- **Nginx 安装与升级同源**：`install.sh` 与 `upgrade.sh` 都使用 nginx.org 官方仓库，校验签名指纹并设置 Pin 优先级 900。仓库地址按官方页面区分：stable 为 `https://nginx.org/packages/debian <代号> nginx`，mainline 为 `https://nginx.org/packages/mainline/debian <代号> nginx`（stable 路径**不带** `/stable` 段）。配置也采用官方布局：站点直接写入 `/etc/nginx/conf.d/`，PHP 片段使用包自带的 `fastcgi_params` 并显式设置 `SCRIPT_FILENAME`，不修改 `nginx.conf` 的 include，也不创建 `sites-available` / `sites-enabled`。升级使用 `--force-confold` 保留现有配置，升级后请核对 `nginx -V` 和站点行为。Nginx 官方仓库按当前 LNMP Debian 支持范围限定为 Debian trixie。
- **MySQL 安装与升级使用同一来源**：均为 `install.sh` 配置的 Oracle 官方 APT 仓库，数据目录仍按独立磁盘约定由 `install.sh` 迁移。

### 升级流程与注意事项

PHP 默认走 sury：先配置仓库，再交互式列出可用分支（默认选最新）或接受 `8.5` / `8.5.13` / 完整 APT 版本等输入，安装 `php<分支>-fpm` 与 cli、mysql、curl、gd、mbstring、xml、zip、bcmath、intl 等扩展包（8.5 起 OPcache 已并入核心，不再单独安装）。安装后停止并禁用旧 FPM 服务，将 `/etc/nginx/snippets/enable-php*.conf` 中的 socket 路径改到 `php<分支>-fpm.sock`，启动新服务并校验 socket 属主为 `www:www`，最后 reload Nginx。若旧的运行时是 `--source` 编译的 `lnmp-php-upstream.service`，该单元会被移除；新服务启动失败时会恢复旧运行时。sury 分支的第三方扩展需用 `addons.sh` 重新安装。

`--source` 路径则从 php.net 下载 tarball，编译到 `/usr/local/php-upstream-<版本>` 并切换到 `lnmp-php-upstream.service`。该路径只允许在已安装的同一 major.minor 分支内升级，并要求上游构建的 PHP API 与 Debian 扩展目录一致；构建依赖来自 Debian APT，PHP 本体来自 php.net。

脚本在交互环境下要求输入 `yes` 确认风险；`--yes` 可跳过该确认，但必须明确指定版本，非交互环境同样必须明确指定版本并使用 `--yes`，例如 `sudo ./upgrade.sh --yes nginx 1.28.0 stable`、`sudo ./upgrade.sh --yes php 8.4.17`。升级会改动正在运行的服务，PHP 升级还会替换运行时，属于高风险操作，请在维护窗口执行，并确认自己已完成备份。sury 升级会替换 FPM 服务与 CLI 包，切换失败时脚本会尝试恢复原 FPM 服务；`--source` 则会停用原 Debian FPM 单元并将 FPM 服务切到上游构建，系统 PHP CLI 仍由 Debian 包管理，切换失败时会尝试恢复原 FPM 服务与原标记。

`lnmp vhost add` 的站点目录默认使用配置中的 `WEB_ROOT/<域名>`，也可在创建时输入其他绝对路径。伪静态规则恢复了旧版内置模板（如 `wordpress`、`discuzx`、`thinkphp`、`laravel`、`joomla` 等）；创建时可选规则模板，默认不启用。安装器只补齐缺少的模板，不覆盖 `/etc/nginx/rewrite/` 中已有的文件。自定义规则可放入该目录的 `<名称>.conf`，创建虚拟主机时选择名称即可；未存在的自定义名称会创建一个空模板供编辑。创建时也可选择 PHP Pathinfo 和 IPv6 监听。

### 升级后清理
php
以 8.3.x 为例
```sh
apt purge 'php8.3*'
apt autoremove --purge
apt clean
```
NGINX、MySQL
```sh
apt autoremove --purge
apt clean
```

###
Debian APT 包管理，最好建立一个明确的原则：
1. /usr/ 下由 APT 管理的程序和库，全部交给 APT 清理。
2. /etc/ 下的自定义配置，备份后再清理。
3. /var/lib/ 下的数据，必须确认用途后才能删除。
4. /var/log/ 下的历史日志，根据实际需要清理。
5. 不要直接对整个 /usr/lib、/etc 或 /var/lib 执行递归删除。