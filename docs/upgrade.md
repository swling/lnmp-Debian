# 手动升级

`upgrade.sh` 按组件从不同来源升级：

| 组件 | 升级来源 | 方式 |
| --- | --- | --- |
| Nginx | nginx.org 官方 APT 仓库（stable / mainline） | 配置仓库、校验签名、设置 Pin 优先级，`apt-get install nginx=<版本>` |
| MySQL | Oracle MySQL 8.4 LTS 官方 APT 仓库（由 `install.sh` 配置） | `apt-get install mysql-server=<版本>` |
| PHP | php.net 源码 | 下载 tarball 编译到独立目录，切换 FPM 服务 |

```sh
sudo ./upgrade.sh nginx [版本] [stable|mainline]
sudo ./upgrade.sh php [版本]
sudo ./upgrade.sh mysql [版本]
```

在交互终端下，省略组件时会显示交互菜单；省略 Nginx/MySQL 版本时会显示 APT 可用版本并默认选最新。脚本不会自动备份任何数据或配置，升级前请自行备份。交互运行时会先显示风险警告，必须输入 `yes` 才继续；非交互环境没有终端输入，必须显式指定组件和版本并加 `--yes`，否则脚本会在产生任何副作用（包括修改 APT 源）之前直接报错退出。Nginx 升级前会执行 `nginx -t`，安装完成后重启 Nginx 并确认服务处于 active 状态。

### 关于软件来源

- **PHP 没有官方 Linux APT 仓库**：php.net 只发布源码，Debian 的 `php8.x-*` 包是发行版自行打包、版本由 Debian 决定。要在发行版节奏之外升级到指定的上游补丁版本，只能从 php.net 源码构建，因此 PHP 保持源码编译路径，不改为添加 APT 仓库。
- **Nginx 安装与升级的来源不同**：`install.sh` 从 Debian APT 安装 Nginx；`upgrade.sh` 会新增 nginx.org 官方仓库，校验签名指纹并设置 Pin 优先级 900，实现从官方仓库升级。仓库地址按官方页面区分：stable 为 `https://nginx.org/packages/debian <代号> nginx`，mainline 为 `https://nginx.org/packages/mainline/debian <代号> nginx`（stable 路径**不带** `/stable` 段）。升级使用 `--force-confold` 保留现有配置，`sites-enabled` 等 LNMP 配置不会被覆盖，但两个源的编译模块和默认配置可能有差异，升级后请核对 `nginx -V` 和站点行为。Nginx 官方仓库按当前 LNMP Debian 支持范围限定为 Debian trixie。
- **MySQL 安装与升级使用同一来源**：均为 `install.sh` 配置的 Oracle 官方 APT 仓库，数据目录仍按独立磁盘约定由 `install.sh` 迁移。

### 升级流程与注意事项

PHP 需要手动输入 php.net 上的完整版本号（如 `8.4.17`），从官网源码构建到 `/usr/local/php-upstream-<版本>`，再切换 FPM 服务。为兼容当前 Debian PHP 扩展，只允许在已安装的 PHP 8.x 同一 major.minor 分支内升级，并要求上游构建的 PHP API 与 Debian 扩展目录一致。构建依赖（如 `build-essential`、各类 `-dev` 包）来自 Debian APT，但 PHP 本体来自 php.net。

脚本在交互环境下要求输入 `yes` 确认风险；`--yes` 可跳过该确认，但必须明确指定版本，非交互环境同样必须明确指定版本并使用 `--yes`，例如 `sudo ./upgrade.sh --yes nginx 1.28.0 stable`、`sudo ./upgrade.sh --yes php 8.4.17`。这是绕过 Debian 版本节奏的高风险路径：PHP 切换会停用原 Debian FPM 单元并将 FPM 服务切到上游构建；系统 PHP CLI 仍由 Debian 包管理。切换失败时脚本会尝试恢复原 FPM 服务与原标记。请在维护窗口执行，并确认自己已完成备份。

`lnmp vhost add` 的站点目录默认使用配置中的 `WEB_ROOT/<域名>`，也可在创建时输入其他绝对路径。伪静态规则恢复了旧版内置模板（如 `wordpress`、`discuzx`、`thinkphp`、`laravel`、`joomla` 等）；创建时可选规则模板，默认不启用。安装器只补齐缺少的模板，不覆盖 `/etc/nginx/rewrite/` 中已有的文件。自定义规则可放入该目录的 `<名称>.conf`，创建虚拟主机时选择名称即可；未存在的自定义名称会创建一个空模板供编辑。创建时也可选择 PHP Pathinfo 和 IPv6 监听。
