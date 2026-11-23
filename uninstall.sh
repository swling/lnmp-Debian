#!/usr/bin/env bash
# LNMP Debian 卸载脚本
# 卸载由 install.sh 安装的软件与管理组件；数据库与其他用户数据只警告、不处理。
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

SYSTEM_CONFIG=/etc/lnmp-debian.conf
STATE_DIR=/etc/lnmp-debian
NGINX_DIR=/etc/nginx
ACME_HOME=/usr/local/acme.sh
# 证书目录（--certhome）与 SSL 证书共用 /etc/nginx/ssl；
# ACME_HOME 仍是程序目录（--home），配置/账户密钥在 acme.sh 默认配置目录。
# 卸载时不处理这些 ACME 数据。
ACME_CERT_HOME="${NGINX_DIR}/ssl"
MYSQL_KEYRING=/usr/share/keyrings/mysql-apt.gpg
MYSQL_SOURCE=/etc/apt/sources.list.d/mysql.list
NGINX_KEYRING=/usr/share/keyrings/nginx-archive-keyring.gpg
NGINX_SOURCE=/etc/apt/sources.list.d/nginx.list
NGINX_PIN=/etc/apt/preferences.d/99nginx
AUTO_CONFIRM=0

usage() {
    cat <<'EOF'
Usage:
  ./uninstall.sh [--yes]

卸载 LNMP Debian 安装：
  - purge APT 安装的 nginx / PHP / MySQL / acme.sh 等软件包，并 autoremove 残留依赖
  - 停止并删除 lnmp 自带的 systemd 单元
  - 用 *.lnmp-debian.orig 还原被修改过的配置
  - 删除管理命令、LNMP 配置片段、LNMP 生成的配置、APT 仓库与状态目录

不会处理（仅打印警告，需你手动决定）：
  - MySQL 数据目录（可能在独立磁盘）与其备份
  - 网站文件、SSL 证书、access 日志、ACME 数据
  - /etc/nginx/conf.d/ 下全部虚拟主机配置（含 default.conf；安装时会被覆盖）

选项：
  -y, --yes   跳过确认直接执行
  -h, --help  显示帮助
EOF
}

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
info() { printf '  - %s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }

confirm() {
    if (( AUTO_CONFIRM )); then
        printf '  (--yes: 自动确认)\n'
        return 0
    fi
    local answer=""
    read -r -p "确认继续卸载？输入 yes 继续: " answer || true
    [[ "$answer" == yes ]] || fail "已取消。"
}

# ---- 参数 ----
while (( $# )); do
    case "$1" in
        -y|--yes) AUTO_CONFIRM=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "未知参数: $1（用 --help 查看用法）" ;;
    esac
done

(( EUID == 0 )) || fail "请以 root 身份运行。"
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == debian ]] || warn "当前系统不是 Debian，继续卸载但请自行核对路径。"
fi

# ---- 读取安装时的配置 ----
if [[ -r "$SYSTEM_CONFIG" ]]; then
    # shellcheck disable=SC1090
    . "$SYSTEM_CONFIG"
elif [[ -r "${SCRIPT_DIR}/lnmp-debian.conf" ]]; then
    # shellcheck disable=SC1091
    . "${SCRIPT_DIR}/lnmp-debian.conf"
fi
WEB_ROOT="${WEB_ROOT:-/home/wwwroot}"
DEFAULT_WEB_ROOT="${DEFAULT_WEB_ROOT:-${WEB_ROOT}/default}"
MYSQL_DATA_DIR="${MYSQL_DATA_DIR:-/var/lib/mysql}"
NGINX_LOG_DIR="${NGINX_LOG_DIR:-/var/log/nginx}"

# ---- 收集已安装的 PHP 版本与待 purge 的包 ----
declare -a PHP_VERSIONS=()
add_php_version() {
    local v=$1 existing
    [[ -n "$v" ]] || return 0
    for existing in "${PHP_VERSIONS[@]}"; do
        [[ "$existing" == "$v" ]] && return 0
    done
    PHP_VERSIONS+=("$v")
}
if [[ -r "${STATE_DIR}/php-version" ]]; then
    IFS= read -r v < "${STATE_DIR}/php-version" || true
    add_php_version "${v:-}"
fi
for d in /etc/php/*/fpm; do
    [[ -d "$d" ]] || continue
    v="${d#/etc/php/}"; v="${v%/fpm}"
    add_php_version "$v"
done

declare -a PURGE_PKGS=()
collect_prefix() {
    local prefix=$1 pkg
    while IFS= read -r pkg; do
        [[ -n "$pkg" ]] || continue
        PURGE_PKGS+=("$pkg")
    done < <(dpkg-query -W -f='${Package}\n' 2>/dev/null | awk -v p="$prefix" 'index($0,p)==1')
}
collect_prefix nginx
collect_prefix php
collect_prefix mysql-server
collect_prefix mysql-client
# mysql-server 只是元包，Oracle 实际安装的是 mysql-community-* 包，必须一并清除。
collect_prefix mysql-community-server
collect_prefix mysql-community-client
if dpkg-query -W -f='${Package}\n' acme.sh 2>/dev/null | grep -qx 'acme.sh'; then
    PURGE_PKGS+=(acme.sh)
fi
# 去重
declare -A _seen=()
declare -a UNIQ_PKGS=()
for p in "${PURGE_PKGS[@]}"; do
    [[ -n "$p" ]] || continue
    if [[ -z "${_seen[$p]:-}" ]]; then
        _seen[$p]=1
        UNIQ_PKGS+=("$p")
    fi
done
if (( ${#UNIQ_PKGS[@]} )); then
    PURGE_PKGS=("${UNIQ_PKGS[@]}")
else
    PURGE_PKGS=()
fi

# ---- 数据保留警告 ----
cat <<EOF
================================================================
LNMP Debian 卸载计划
----------------------------------------------------------------
将删除（软件与 LNMP 自身的配置）：
  - APT 包: ${PURGE_PKGS[*]:-（未检测到）}
  - systemd 单元: lnmp-acme-renew.timer / .service, lnmp-php-upstream.service
  - 管理命令: /usr/local/bin/lnmp, /usr/local/bin/addons.sh, /usr/bin/lnmp
  - 配置片段与状态: /etc/nginx/snippets, /etc/nginx/rewrite（仅内置模板）,
    /etc/nginx/cache-static.conf, /etc/lnmp-debian.conf, /etc/lnmp-debian/
  - 安装器生成的配置: /etc/mysql/mysql.conf.d/zz-lnmp-debian.cnf,
    AppArmor 中为数据目录追加的规则（conf.d/default.conf 不删除）
  - APT 仓库与密钥: MySQL / nginx.org
  - 还原 .lnmp-debian.orig 备份后删除备份文件

将保留（只警告，不处理，请自行决定）：
  - MySQL 数据目录: ${MYSQL_DATA_DIR}
  - MySQL 初始数据备份: /var/lib/mysql.lnmp-debian.orig
  - 网站文件: ${WEB_ROOT}
  - SSL 证书: ${NGINX_DIR}/ssl
  - 全部虚拟主机配置: ${NGINX_DIR}/conf.d/（含 default.conf）
  - 日志: ${NGINX_LOG_DIR}
  - ACME 程序目录: ${ACME_HOME}
  - ACME 证书目录（--certhome）: ${ACME_CERT_HOME}（与上面的 SSL 证书同目录）
================================================================
EOF
warn "不会备份数据库，也不会删除任何数据库文件/目录。"
warn "MySQL 包 purge 前会安全移除 /var/lib/mysql 软链本身（不触碰其指向的数据），以免包脚本误操作独立磁盘上的数据。"
confirm

# ---- 1. 停止服务 ----
step "停止 LNMP 与相关服务"
systemctl disable --now lnmp-acme-renew.timer >/dev/null 2>&1 || true
systemctl disable --now lnmp-php-upstream.service >/dev/null 2>&1 || true
for svc in nginx mysql; do
    systemctl stop "$svc" >/dev/null 2>&1 || true
done
for v in "${PHP_VERSIONS[@]}"; do
    systemctl stop "php${v}-fpm" >/dev/null 2>&1 || true
done
info "服务已停止（若存在）"

# ---- 2. 还原 .orig 备份 ----
step "还原被修改的配置（*.lnmp-debian.orig）"
restore_orig() {
    local orig=$1 dest=$2
    if [[ -f "$orig" ]]; then
        cp -p -- "$orig" "$dest" || { warn "还原失败: $orig -> $dest"; return 0; }
        rm -f -- "$orig"
        info "已还原: $dest"
    fi
}
restore_orig "${NGINX_DIR}/nginx.conf.lnmp-debian.orig" "${NGINX_DIR}/nginx.conf"
for v in "${PHP_VERSIONS[@]}"; do
    restore_orig "/etc/php/${v}/fpm/pool.d/www.conf.lnmp-debian.orig" \
                 "/etc/php/${v}/fpm/pool.d/www.conf"
done

# ---- 3. 管理命令 ----
step "处理管理命令"
for cmd in /usr/local/bin/lnmp /usr/bin/lnmp; do
    orig="${cmd}.lnmp-debian.orig"
    if [[ -f "$orig" ]]; then
        cp -p -- "$orig" "$cmd" 2>/dev/null || warn "还原原命令失败: $orig"
        rm -f -- "$orig"
        info "已还原原命令: $cmd"
    elif [[ -e "$cmd" || -L "$cmd" ]]; then
        rm -f -- "$cmd"
        info "已删除: $cmd"
    fi
done
if [[ -e /usr/local/bin/addons.sh || -L /usr/local/bin/addons.sh ]]; then
    rm -f -- /usr/local/bin/addons.sh
    info "已删除: /usr/local/bin/addons.sh"
fi
if [[ -e /usr/local/bin/addons.sh.lnmp-upgrade.orig ]]; then
    warn "存在升级备份 /usr/local/bin/addons.sh.lnmp-upgrade.orig，已保留。"
fi

# ---- 4. 删除 LNMP 配置片段与状态 ----
step "删除 LNMP 配置片段与状态文件"
for f in enable-php.conf enable-php-pathinfo.conf pathinfo.conf; do
    [[ -e "${NGINX_DIR}/snippets/${f}" || -L "${NGINX_DIR}/snippets/${f}" ]] && {
        rm -f -- "${NGINX_DIR}/snippets/${f}"
        info "已删除: ${NGINX_DIR}/snippets/${f}"
    }
done
if [[ -d "${NGINX_DIR}/snippets" ]] && [[ -z "$(find "${NGINX_DIR}/snippets" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    rmdir -- "${NGINX_DIR}/snippets" 2>/dev/null || true
fi
for tpl in drupal joomla laravel other wordpress none; do
    [[ -e "${NGINX_DIR}/rewrite/${tpl}.conf" ]] && {
        rm -f -- "${NGINX_DIR}/rewrite/${tpl}.conf"
        info "已删除内置规则: ${tpl}.conf"
    }
done
if [[ -d "${NGINX_DIR}/rewrite" ]]; then
    leftover="$(find "${NGINX_DIR}/rewrite" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)"
    if [[ -n "$leftover" ]]; then
        warn "${NGINX_DIR}/rewrite 中仍有自定义规则，已保留整个目录。"
    fi
fi
if [[ -e "${NGINX_DIR}/cache-static.conf" || -L "${NGINX_DIR}/cache-static.conf" ]]; then
    rm -f -- "${NGINX_DIR}/cache-static.conf"
    info "已删除: ${NGINX_DIR}/cache-static.conf"
fi
# 默认站点：安装时由模板无条件覆盖，卸载时无需删除，留给下次安装覆盖。
# 这样也避免误删用户后来改过的 default.conf。

# MySQL 自定义数据目录配置：安装器生成，内容仅 datadir 一行，直接移除。
mysql_lnmp_cnf=/etc/mysql/mysql.conf.d/zz-lnmp-debian.cnf
if [[ -f "$mysql_lnmp_cnf" ]]; then
    rm -f -- "$mysql_lnmp_cnf"
    info "已删除: $mysql_lnmp_cnf"
fi

# AppArmor：移除安装器为独立磁盘数据目录追加的规则，保留其他自定义规则。
# 与 install.sh 写入时一致：从数据目录的父目录逐级到根目录，每级 r/x 两行，
# 再加数据目录自身的 r 与 /** rwk 两行。
apparmor_local=/etc/apparmor.d/local/usr.sbin.mysqld
if [[ "$MYSQL_DATA_DIR" != /var/lib/mysql && -f "$apparmor_local" ]]; then
    rules_tmp="$(mktemp)"
    printf '%s\n' "${MYSQL_DATA_DIR}/ r," "${MYSQL_DATA_DIR}/** rwk," > "$rules_tmp"
    apparmor_parent="$(dirname "$MYSQL_DATA_DIR")"
    while [[ "$apparmor_parent" != / ]]; do
        printf '%s\n' "${apparmor_parent}/ r," "${apparmor_parent}/ x," >> "$rules_tmp"
        apparmor_parent="$(dirname "$apparmor_parent")"
    done
    filtered_tmp="$(mktemp)"
    awk 'NR==FNR { drop[$0]=1; next } !($0 in drop)' \
        "$rules_tmp" "$apparmor_local" > "$filtered_tmp"
    if ! cmp -s "$apparmor_local" "$filtered_tmp"; then
        chmod --reference="$apparmor_local" "$filtered_tmp"
        mv -- "$filtered_tmp" "$apparmor_local"
        [[ -s "$apparmor_local" ]] || rm -f -- "$apparmor_local"
        if command -v apparmor_parser >/dev/null 2>&1; then
            apparmor_parser -r /etc/apparmor.d/usr.sbin.mysqld >/dev/null 2>&1 ||
                warn "AppArmor 重新加载失败，请手动执行: apparmor_parser -r /etc/apparmor.d/usr.sbin.mysqld"
        fi
        info "已移除 AppArmor 中为 ${MYSQL_DATA_DIR} 追加的规则"
    fi
    rm -f -- "$rules_tmp" "$filtered_tmp"
fi

[[ -e "$SYSTEM_CONFIG" ]] && { rm -f -- "$SYSTEM_CONFIG"; info "已删除: $SYSTEM_CONFIG"; }
if [[ -d "$STATE_DIR" && ! -L "$STATE_DIR" ]]; then
    rm -rf -- "$STATE_DIR" && info "已删除: $STATE_DIR"
fi
for unit in lnmp-acme-renew.service lnmp-acme-renew.timer lnmp-php-upstream.service; do
    f="/etc/systemd/system/${unit}"
    [[ -e "$f" || -L "$f" ]] && { rm -f -- "$f"; info "已删除单元: $unit"; }
done
systemctl daemon-reload >/dev/null 2>&1 || true

# ---- 5. 保护数据库数据：仅移除软链，不动数据 ----
step "数据库安全处理（仅移除软链，不动数据）"
if [[ -L /var/lib/mysql ]]; then
    info "移除软链 /var/lib/mysql -> $(readlink /var/lib/mysql)"
    rm -f -- /var/lib/mysql
    info "数据目录 ${MYSQL_DATA_DIR} 未做任何改动"
else
    info "/var/lib/mysql 不是软链，未做改动"
fi
warn "MySQL 数据目录 ${MYSQL_DATA_DIR} 与备份 /var/lib/mysql.lnmp-debian.orig 均保留，请自行处理。"

# ---- 6. 删除 APT 仓库与密钥 ----
step "删除 APT 仓库与密钥"
for f in "$MYSQL_SOURCE" "$MYSQL_KEYRING" "$NGINX_SOURCE" "$NGINX_KEYRING" "$NGINX_PIN" \
         "${NGINX_SOURCE}.lnmp-debian.orig" "${NGINX_PIN}.lnmp-debian.orig"; do
    [[ -e "$f" || -L "$f" ]] && { rm -f -- "$f"; info "已删除: $f"; }
done
if (( ${#PURGE_PKGS[@]} )); then
    DEBIAN_FRONTEND=noninteractive apt-get purge -y "${PURGE_PKGS[@]}" || warn "apt-get purge 返回错误，请检查输出。"
    # 按 MySQL 官方卸载流程清理随服务器自动安装的依赖（如 mysql-community-libs/common）。
    DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y || warn "apt-get autoremove 返回错误，请检查输出。"
else
    info "未检测到需要 purge 的软件包"
fi
apt-get update >/dev/null 2>&1 || warn "apt-get update 失败，请手动执行。"

# ---- 7. 清理 PHP 上游构建产物 ----
step "清理 PHP 上游构建产物（如存在）"
for v in "${PHP_VERSIONS[@]}"; do
    ini="/etc/php/${v}/fpm/conf.d/00-lnmp-upstream-extension-dir.ini"
    [[ -f "$ini" ]] && { rm -f -- "$ini"; info "已删除: $ini"; }
done
for d in /usr/local/php-upstream-* /usr/local/src/lnmp-php-*; do
    [[ -d "$d" && ! -L "$d" ]] || continue
    warn "删除 PHP 源码构建产物: $d"
    rm -rf -- "$d"
done

# ---- 8. www 用户/组 ----
step "处理 www 用户/组"
if getent passwd www >/dev/null 2>&1; then
    if userdel www >/dev/null 2>&1; then
        info "已删除用户 www（网站文件 ${WEB_ROOT} 保留，其属主将显示为原 UID）"
    else
        warn "删除用户 www 失败（可能被占用），已保留。"
    fi
fi
if getent group www >/dev/null 2>&1; then
    groupdel www >/dev/null 2>&1 || warn "删除组 www 失败，已保留。"
fi

# ---- 完成 ----
systemctl daemon-reload >/dev/null 2>&1 || true
cat <<EOF

================================================================
卸载完成
----------------------------------------------------------------
已移除 LNMP 软件、管理命令、安装器生成的配置与 APT 仓库，并还原了
可被还原的 .lnmp-debian.orig 配置。/etc/nginx/conf.d/ 下所有配置（含
default.conf）均未处理，下次安装时 default.conf 会被直接覆盖。

以下数据未被处理，请自行确认：
  数据库数据:     ${MYSQL_DATA_DIR}
  数据库初始备份: /var/lib/mysql.lnmp-debian.orig
  网站文件:       ${WEB_ROOT}
  SSL 证书:       ${NGINX_DIR}/ssl
  站点配置:       ${NGINX_DIR}/conf.d/（含 default.conf）
  日志:           ${NGINX_LOG_DIR}
  ACME 程序目录:  ${ACME_HOME}
  ACME 证书目录:  ${ACME_CERT_HOME}（与 SSL 证书同目录）
  残留备份:       *.lnmp-debian.orig（如 /var/lib/mysql.lnmp-debian.orig）
================================================================
EOF
