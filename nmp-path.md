## Debian LNMP 目录结构速查表

> 说明：标注 `[LNMP]` 的路径由本安装器/管理脚本创建或修改，其余为 Debian 包默认布局或自定义示例。
> 文中 `8.4` 仅作示例：PHP 版本由安装时从 APT 检测决定，实际路径中的版本号随之变化。
> 网站根目录、日志目录等可由 `/etc/lnmp-debian.conf` 覆盖，下表为默认值。

/
│
├── etc/                                  # 系统配置文件
│   │
│   ├── nginx/                            # Nginx 配置目录
│   │   ├── nginx.conf                    # [默认] Nginx 主配置文件
│   │   │
│   │   ├── conf.d/                       # [自定义] 全局配置片段
│   │   │   ├── gzip.conf                 # Gzip 压缩配置
│   │   │   ├── security.conf             # 安全相关配置
│   │   │   └── custom.conf               # 其他全局配置
│   │   │
│   │   ├── sites-available/              # [自定义] 虚拟主机配置存放目录
│   │   │   ├── example.com.conf          # 网站配置
│   │   │   └── default                   # 默认站点配置
│   │   │
│   │   ├── sites-enabled/                # 已启用的虚拟主机（lnmp 建软链）
│   │   │   ├── example.com.conf          # → ../sites-available/example.com.conf
│   │   │   └── default                   # → ../sites-available/default（安装器创建）
│   │   │
│   │   ├── snippets/                     # [LNMP] 可复用配置片段（install.sh 生成）
│   │   │   ├── enable-php.conf           # PHP FastCGI 片段（无 PATHINFO）
│   │   │   ├── enable-php-pathinfo.conf  # PHP FastCGI 片段（含 PATHINFO）
│   │   │   └── pathinfo.conf             # PATHINFO 重写规则
│   │   │
│   │   ├── rewrite/                      # [LNMP] 伪静态规则（install.sh / lnmp 生成）
│   │   │   ├── none.conf                 # 空规则（默认，预置）
│   │   │   ├── other.conf                # 空规则（自定义占位，预置）
│   │   │   └── <name>.conf               # 内置模板或自定义规则
│   │   │
│   │   ├── ssl/                          # [ACME] 同时作为 acme.sh 数据目录（--config-home）
│   │   │   ├── account.conf              # acme.sh 账户配置（签发时生成）
│   │   │   ├── ca/                       # acme.sh 的 CA/账户密钥（签发时生成）
│   │   │   └── <domain>/                 # 证书按域名在此原位生成，无需复制
│   │   │       ├── fullchain.cer         # 证书链
│   │   │       └── <domain>.key          # 私钥
│   │   │
│   │   ├── modules-available/            # 可用动态模块配置
│   │   └── modules-enabled/              # 已启用动态模块配置
│   │
│   │
│   ├── mysql/                            # MySQL 配置目录
│   │   ├── my.cnf                        # 主配置入口
│   │   ├── conf.d/                       # [自定义] 通用配置片段
│   │   │   └── custom.cnf                # 自定义客户端等配置
│   │   │
│   │   └── mysql.conf.d/                 # MySQL 服务端配置
│   │       ├── mysqld.cnf                # [默认] 服务端配置
│   │       ├── custom.cnf                # [自定义] 服务端参数
│   │       └── zz-lnmp-debian.cnf        # [LNMP] 仅自定义数据目录时写入
│   │
│   │
│   ├── php/                              # PHP 配置目录
│   │   └── 8.4/                          # PHP 8.4
│   │       │
│   │       ├── cli/                      # 命令行 PHP
│   │       │   ├── php.ini               # CLI 配置文件
│   │       │   └── conf.d/               # CLI 扩展配置（软链接）
│   │       │
│   │       ├── fpm/                      # PHP-FPM
│   │       │   ├── php.ini               # FPM 配置文件
│   │       │   ├── php-fpm.conf          # FPM 主配置
│   │       │   ├── pool.d/               # FPM 进程池配置
│   │       │   │   ├── www.conf          # [默认] 默认进程池
│   │       │   │   └── custom.conf       # [自定义] 进程池配置
│   │       │   └── conf.d/               # FPM 扩展配置（软链接）
│   │       │
│   │       ├── mods-available/           # PHP 扩展配置定义
│   │       │   ├── opcache.ini           # OPcache 配置
│   │       │   ├── redis.ini             # Redis 配置
│   │       │   └── ...
│   │       │
│   │       └── mods-enabled/             # 已启用的扩展配置（软链接）
│   │
│   │
│   ├── systemd/                          # systemd 服务配置
│   │   └── system/                       # 自定义服务配置及覆盖文件
│   │       ├── lnmp-acme-renew.timer     # [LNMP] 证书自动续期定时器（lnmp 创建）
│   │       ├── lnmp-acme-renew.service   # [LNMP] 续期服务（timer 触发）
│   │       └── lnmp-php-upstream.service # [LNMP] 自编译 PHP-FPM 服务（升级后）
│   │
│   ├── lnmp-debian.conf                  # [LNMP] 用户配置入口（被 lnmp 读取）
│   │
│   ├── lnmp-debian/                      # [LNMP] 内部状态目录
│   │   ├── php-version                   # 已安装 PHP 版本
│   │   ├── php-upstream-service          # 自定义 PHP 服务标记（升级后）
│   │   └── php-upstream-prefix           # 自定义 PHP 前缀（升级后）
│   │
│   └── logrotate.d/                      # 日志轮转配置
│       ├── nginx                         # Nginx 日志轮转
│       ├── mysql                         # MySQL 日志轮转（如有）
│       └── php8.4-fpm                    # PHP-FPM 日志轮转（如有）
│
│
├── usr/                                  # 系统软件及程序文件
│   │
│   ├── bin/                              # 普通用户命令
│   │   ├── php                           # PHP 默认命令
│   │   ├── php8.4                        # PHP CLI
│   │   ├── mysql                         # MySQL 客户端
│   │   └── lnmp                          # [LNMP] 指向 /usr/local/bin/lnmp 的软链
│   │
│   ├── sbin/                             # 系统管理程序
│   │   ├── nginx                         # Nginx 主程序
│   │   ├── mysqld                        # MySQL 服务端（实际位置视安装包而定）
│   │   └── php-fpm8.4                    # PHP-FPM
│   │
│   ├── lib/                              # 软件库文件
│   │   ├── php/                          # PHP 扩展模块
│   │   │   └── 20240924/                 # PHP 8.4 扩展 ABI 目录
│   │   │       ├── opcache.so
│   │   │       ├── redis.so
│   │   │       └── ...
│   │   │
│   │   └── systemd/                      # systemd 辅助文件
│   │
│   └── share/                            # 软件共享资源
│
│
├── var/                                  # 可变数据
│   │
│   ├── www/                              # 系统默认网站目录
│   │   └── html/
│   │
│   ├── lib/                              # 软件持久化数据
│   │   └── mysql/                        # MySQL 数据库文件（默认路径；自定义数据目录时此路径为软链）
│   │
│   ├── log/                              # 日志文件
│   │   ├── nginx/
│   │   │   ├── <domain>.log              # [LNMP] 各站点访问日志（lnmp 按域名创建）
│   │   │   ├── access.log                # 默认访问日志
│   │   │   └── error.log                 # 错误日志
│   │   │
│   │   ├── mysql/                        # MySQL 日志（视配置而定）
│   │   │
│   │   └── php8.4-fpm.log                # PHP-FPM 日志（如配置文件日志）
│   │
│   └── cache/                            # 软件缓存
│
│
├── run/                                  # 运行时文件（重启后重新生成）
│   │
│   ├── nginx.pid                         # Nginx PID
│   │
│   ├── mysqld/                           # MySQL 运行目录
│   │   └── mysqld.sock                   # MySQL Socket
│   │
│   └── php/                              # PHP-FPM 运行目录
│       ├── php-fpm.pid                   # PHP-FPM PID（install.sh 固定名称）
│       └── php8.4-fpm.sock               # PHP-FPM Socket（8.4 为示例，随版本变化）
│
│
├── home/                                 # 用户业务数据
│   │
│   ├── wwwroot/                          # [自定义] 网站根目录
│   │   ├── example.com/                  # 网站 A
│   │   └── example.net/                  # 网站 B
│   │
│   └── backup/                            # [自定义] 备份目录
│       ├── database/                     # 数据库备份
│       ├── website/                      # 网站备份
│       └── config/                       # 配置文件备份
│
│
└── usr/local/                            # 管理员自行安装的软件
    ├── bin/                              # [LNMP] 管理脚本
    │   ├── lnmp                          # LNMP 管理脚本（install.sh 安装）
    │   └── addons.sh                     # 扩展管理脚本（install.sh 安装）
    │
    ├── acme.sh/                          # [ACME] acme.sh 程序目录（--home）
    │
    ├── sbin/                             # 自定义系统管理程序
    │
    └── etc/                              # 自定义软件配置