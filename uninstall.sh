#!/usr/bin/env bash
# LNMP Debian 卸载脚本
# 支持按 mysql / nginx / php 单独卸载，或整体卸载（all）。
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
MYSQL_LNMP_CNF=/etc/mysql/mysql.conf.d/zz-lnmp-debian.cnf
NGINX_KEYRING=/usr/share/keyrings/nginx-archive-keyring.gpg
NGINX_SOURCE=/etc/apt/sources.list.d/nginx.list
NGINX_PIN=/etc/apt/preferences.d/99nginx
PHP_KEYRING=/usr/share/keyrings/debsuryorg-archive-keyring.gpg
PHP_SOURCE=/etc/apt/sources.list.d/php.list
PHP_PIN=/etc/apt/preferences.d/99sury-php
AUTO_CONFIRM=0
COMPONENT=""

declare -a PURGE_PKGS=()
declare -a PHP_VERSIONS=()
declare -a REMOVE_ITEMS=()

usage() {
    cat <<'EOF'
Usage:
  ./uninstall.sh [--component=mysql|nginx|php|all] [--yes]

卸载 LNMP Debian 的指定组件：
  mysql  仅卸载 MySQL 软件包、APT 仓库与安装器生成的配置；数据目录保留
  nginx  仅卸载 Nginx 软件包、APT 仓库与 LNMP 配置片段；站点配置保留
  php    仅卸载 PHP 软件包、APT 仓库、FPM 配置与上游构建产物
  all    卸载全部组件与管理命令（交互选择时默认）

不会处理（仅打印警告，需你手动决定）：
  - MySQL 数据目录（可能在独立磁盘）与其备份
  - 网站文件、SSL 证书、access 日志、ACME 数据
  - /etc/nginx/conf.d/ 下全部虚拟主机配置（含 default.conf；安装时会被覆盖）

选项：
  -c, --component NAME  指定卸载目标：mysql / nginx / php / all
  -y, --yes             跳过确认；未指定 --component 时按 all 处理
  -h, --help            显示帮助

不带 --component 且交互运行时，会先询问卸载目标。
EOF
}

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
info() { printf '  - %s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }

select_component() {
    local answer=""
    [[ -n "$COMPONENT" ]] && return 0
    if (( AUTO_CONFIRM )); then
        COMPONENT=all
        info "--yes 未指定组件，按 all 处理"
        return 0
    fi

    cat <<'EOF'
请选择卸载目标：
  1) mysql  仅卸载 MySQL
  2) nginx  仅卸载 Nginx
  3) php    仅卸载 PHP
  4) all    卸载全部（默认）
EOF
    read -r -p "输入选项 [4]: " answer || true
    case "$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')" in
        1|mysql) COMPONENT=mysql ;;
        2|nginx) COMPONENT=nginx ;;
        3|php) COMPONENT=php ;;
        4|all|"") COMPONENT=all ;;
        *) fail "无效选择: $answer" ;;
    esac
}

confirm() {
    if (( AUTO_CONFIRM )); then
        printf '  (--yes: 自动确认)\n'
        return 0
    fi
    local answer=""
    read -r -p "确认卸载 ${COMPONENT} ? 输入 yes 继续: " answer || true
    [[ "$answer" == yes ]] || fail "已取消。"
}

remove_files() {
    local f
    for f in "$@"; do
        [[ -e "$f" || -L "$f" ]] && { rm -f -- "$f"; info "已删除: $f"; }
    done
}

restore_orig() {
    local orig=$1 dest=$2
    if [[ -f "$orig" ]]; then
        cp -p -- "$orig" "$dest" || { warn "还原失败: $orig -> $dest"; return 0; }
        rm -f -- "$orig"
        info "已还原: $dest"
    fi
}

# ---- 参数 ----
while (( $# )); do
    case "$1" in
        -y|--yes) AUTO_CONFIRM=1; shift ;;
        -c|--component)
            (( $# >= 2 )) || fail "--component 需要一个目标：mysql / nginx / php / all"
            COMPONENT=$2
            shift 2
            ;;
        --component=*) COMPONENT="${1#*=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "未知参数: $1（用 --help 查看用法）" ;;
    esac
done
case "$COMPONENT" in
    ""|mysql|nginx|php|all) ;;
    *) fail "无效的卸载目标: ${COMPONENT} (可选: mysql / nginx / php / all)" ;;
esac

(( EUID == 0 )) || fail "请以 root 身份运行。"
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == debian ]] || warn "当前系统不是 Debian，继续卸载但请自行核对路径。"
fi
select_component

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

# ---- 组件：收集待 purge 的软件包 ----
collect_prefix() {
    local prefix=$1 pkg
    while IFS= read -r pkg; do
        [[ -n "$pkg" ]] || continue
        PURGE_PKGS+=("$pkg")
    done < <(dpkg-query -W -f='${Package}\n' 2>/dev/null | awk -v p="$prefix" 'index($0,p)==1')
}

add_php_version() {
    local v=$1 existing
    [[ -n "$v" ]] || return 0
    for existing in "${PHP_VERSIONS[@]}"; do
        [[ "$existing" == "$v" ]] && return 0
    done
    PHP_VERSIONS+=("$v")
}

collect_mysql_packages() {
    collect_prefix mysql-server
    collect_prefix mysql-client
    # mysql-server 只是元包，Oracle 实际安装的是 mysql-community-* 包，必须一并清除。
    collect_prefix mysql-community-server
    collect_prefix mysql-community-client
}

collect_nginx_packages() {
    collect_prefix nginx
}

collect_php_packages() {
    local d v
    collect_prefix php
    if [[ -r "${STATE_DIR}/php-version" ]]; then
        IFS= read -r v < "${STATE_DIR}/php-version" || true
        add_php_version "${v:-}"
    fi
    for d in /etc/php/*/fpm; do
        [[ -d "$d" ]] || continue
        v="${d#/etc/php/}"; v="${v%/fpm}"
        add_php_version "$v"
    done
}

collect_acme_package() {
    if dpkg-query -W -f='${Package}\n' acme.sh 2>/dev/null | grep -qx 'acme.sh'; then
        PURGE_PKGS+=(acme.sh)
    fi
}

dedup_packages() {
    local p
    declare -A seen=()
    declare -a uniq=()
    for p in "${PURGE_PKGS[@]}"; do
        [[ -n "$p" ]] || continue
        if [[ -z "${seen[$p]:-}" ]]; then
            seen[$p]=1
            uniq+=("$p")
        fi
    done
    PURGE_PKGS=("${uniq[@]}")
}

collect_packages() {
    case "$COMPONENT" in
        mysql) collect_mysql_packages ;;
        nginx) collect_nginx_packages ;;
        php) collect_php_packages ;;
        all)
            collect_mysql_packages
            collect_nginx_packages
            collect_php_packages
            collect_acme_package
            ;;
    esac
    dedup_packages
}

# ---- 组件：生成卸载计划 ----
plan_mysql() {
    REMOVE_ITEMS+=(
        "MySQL 安装器生成的配置: ${MYSQL_LNMP_CNF}"
        "AppArmor 中为 ${MYSQL_DATA_DIR} 追加的规则"
        "软链 /var/lib/mysql（不触碰其指向的数据）"
        "APT 仓库与密钥: ${MYSQL_SOURCE}, ${MYSQL_KEYRING}"
    )
}

plan_nginx() {
    REMOVE_ITEMS+=(
        "还原 ${NGINX_DIR}/nginx.conf.lnmp-debian.orig"
        "LNMP 配置片段: snippets（内置）、rewrite（内置模板）、cache-static.conf、gzip.conf"
        "APT 仓库与密钥: ${NGINX_SOURCE}, ${NGINX_KEYRING}, ${NGINX_PIN}"
    )
}

plan_php() {
    REMOVE_ITEMS+=(
        "还原 /etc/php/*/fpm/pool.d/www.conf.lnmp-debian.orig"
        "systemd 单元: lnmp-php-upstream.service"
        "PHP 上游构建产物与状态文件"
        "APT 仓库与密钥: ${PHP_SOURCE}, ${PHP_KEYRING}, ${PHP_PIN}"
    )
}

plan_all_extra() {
    REMOVE_ITEMS+=(
        "acme.sh 与 lnmp-acme-renew.timer / .service"
        "管理命令: /usr/local/bin/lnmp, /usr/local/bin/addons.sh, /usr/bin/lnmp"
        "LNMP 配置与状态: ${SYSTEM_CONFIG}, ${STATE_DIR}"
        "www 用户/组"
    )
}

build_plan() {
    REMOVE_ITEMS=("APT 包: ${PURGE_PKGS[*]:-（未检测到）}")
    case "$COMPONENT" in
        mysql) plan_mysql ;;
        nginx) plan_nginx ;;
        php) plan_php ;;
        all)
            plan_mysql
            plan_nginx
            plan_php
            plan_all_extra
            ;;
    esac
}

print_plan() {
    local c kept_list=""
    cat <<EOF
================================================================
LNMP Debian 卸载计划 (目标: ${COMPONENT})
----------------------------------------------------------------
将删除（软件与 LNMP 自身的配置）：
EOF
    for c in "${REMOVE_ITEMS[@]}"; do
        printf '  - %s\n' "$c"
    done
    cat <<EOF

将保留（只警告，不处理，请自行决定）：
  - MySQL 数据目录: ${MYSQL_DATA_DIR}
  - 网站文件: ${WEB_ROOT}
  - SSL 证书: ${NGINX_DIR}/ssl
  - 全部虚拟主机配置: ${NGINX_DIR}/conf.d/（含 default.conf）
  - 日志: ${NGINX_LOG_DIR}
  - ACME 程序目录: ${ACME_HOME}
  - ACME 证书目录（--certhome）: ${ACME_CERT_HOME}（与上面的 SSL 证书同目录）
EOF
    case "$COMPONENT" in
        mysql) kept_list="Nginx、PHP" ;;
        nginx) kept_list="MySQL、PHP" ;;
        php) kept_list="MySQL、Nginx" ;;
    esac
    [[ -z "$kept_list" ]] ||
        printf '  - 未选择的组件: %s（管理命令与共享配置保留）\n' "$kept_list"
    cat <<'EOF'
================================================================
EOF
    warn "不会备份数据库，也不会删除任何数据库文件/目录。"
    confirm
}

# ---- 组件：MySQL ----
remove_apparmor_rules() {
    local apparmor_local=/etc/apparmor.d/local/usr.sbin.mysqld
    [[ "$MYSQL_DATA_DIR" != /var/lib/mysql && -f "$apparmor_local" ]] || return 0

    local rules_tmp filtered_tmp apparmor_parent
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
}

run_mysql() {
    step "卸载 MySQL"
    systemctl stop mysql >/dev/null 2>&1 || true

    if [[ -f "$MYSQL_LNMP_CNF" ]]; then
        rm -f -- "$MYSQL_LNMP_CNF"
        info "已删除: $MYSQL_LNMP_CNF"
    fi
    remove_apparmor_rules

    step "数据库安全处理（仅移除软链，不动数据）"
    if [[ -L /var/lib/mysql ]]; then
        info "移除软链 /var/lib/mysql -> $(readlink /var/lib/mysql)"
        rm -f -- /var/lib/mysql
        info "数据目录 ${MYSQL_DATA_DIR} 未做任何改动"
    else
        info "/var/lib/mysql 不是软链，未做改动"
    fi
    warn "MySQL 数据目录 ${MYSQL_DATA_DIR} 保留，请自行处理。"

    step "删除 MySQL APT 仓库与密钥"
    remove_files "$MYSQL_SOURCE" "$MYSQL_KEYRING"
}

# ---- 组件：Nginx ----
run_nginx() {
    local f tpl leftover
    step "卸载 Nginx"
    systemctl stop nginx >/dev/null 2>&1 || true
    restore_orig "${NGINX_DIR}/nginx.conf.lnmp-debian.orig" "${NGINX_DIR}/nginx.conf"

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
        [[ -z "$leftover" ]] || warn "${NGINX_DIR}/rewrite 中仍有自定义规则，已保留整个目录。"
    fi

    for f in cache-static.conf gzip.conf; do
        [[ -e "${NGINX_DIR}/${f}" || -L "${NGINX_DIR}/${f}" ]] && {
            rm -f -- "${NGINX_DIR}/${f}"
            info "已删除: ${NGINX_DIR}/${f}"
        }
    done
    # 默认站点：安装时由模板无条件覆盖，卸载时无需删除，留给下次安装覆盖。
    # 这样也避免误删用户后来改过的 default.conf。

    step "删除 Nginx APT 仓库与密钥"
    remove_files "$NGINX_SOURCE" "$NGINX_KEYRING" "$NGINX_PIN" \
                 "${NGINX_SOURCE}.lnmp-debian.orig" "${NGINX_PIN}.lnmp-debian.orig"
}

# ---- 组件：PHP ----
stop_php_services() {
    local v
    systemctl disable --now lnmp-php-upstream.service >/dev/null 2>&1 || true
    for v in "${PHP_VERSIONS[@]}"; do
        systemctl stop "php${v}-fpm" >/dev/null 2>&1 || true
    done
}

remove_php_state() {
    local f unit=/etc/systemd/system/lnmp-php-upstream.service
    for f in php-version php-upstream-service php-upstream-prefix; do
        if [[ -e "${STATE_DIR}/${f}" || -L "${STATE_DIR}/${f}" ]]; then
            rm -f -- "${STATE_DIR}/${f}"
            info "已删除: ${STATE_DIR}/${f}"
        fi
    done
    if [[ -d "$STATE_DIR" && ! -L "$STATE_DIR" ]] &&
       [[ -z "$(find "$STATE_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
        rmdir -- "$STATE_DIR" 2>/dev/null || true
    fi
    if [[ -e "$unit" || -L "$unit" ]]; then
        rm -f -- "$unit"
        info "已删除单元: lnmp-php-upstream.service"
    fi
}

clean_php_upstream_artifacts() {
    local v d ini
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
}

run_php() {
    local v
    step "卸载 PHP"
    stop_php_services
    for v in "${PHP_VERSIONS[@]}"; do
        restore_orig "/etc/php/${v}/fpm/pool.d/www.conf.lnmp-debian.orig" \
                     "/etc/php/${v}/fpm/pool.d/www.conf"
    done
    remove_php_state
    clean_php_upstream_artifacts

    step "删除 PHP (sury) APT 仓库与密钥"
    remove_files "$PHP_SOURCE" "$PHP_KEYRING" "$PHP_PIN" \
                 "${PHP_SOURCE}.lnmp-debian.orig" "${PHP_PIN}.lnmp-debian.orig"
}

# ---- all：管理组件 ----
stop_acme_timer() {
    step "停止 ACME 定时任务"
    systemctl disable --now lnmp-acme-renew.timer >/dev/null 2>&1 || true
}

run_all_extra() {
    local cmd orig unit f
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

    step "删除 LNMP 配置与状态"
    [[ -e "$SYSTEM_CONFIG" ]] && { rm -f -- "$SYSTEM_CONFIG"; info "已删除: $SYSTEM_CONFIG"; }
    if [[ -d "$STATE_DIR" && ! -L "$STATE_DIR" ]]; then
        rm -rf -- "$STATE_DIR" && info "已删除: $STATE_DIR"
    fi
    for unit in lnmp-acme-renew.service lnmp-acme-renew.timer lnmp-php-upstream.service; do
        f="/etc/systemd/system/${unit}"
        [[ -e "$f" || -L "$f" ]] && { rm -f -- "$f"; info "已删除单元: $unit"; }
    done

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
}

# ---- 统一处理软件包 ----
purge_selected_packages() {
    step "清理软件包与 APT 缓存"
    if (( ${#PURGE_PKGS[@]} )); then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y "${PURGE_PKGS[@]}" || warn "apt-get purge 返回错误，请检查输出。"
        # 按 MySQL 官方卸载流程清理随服务器自动安装的依赖（如 mysql-community-libs/common）。
        DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y || warn "apt-get autoremove 返回错误，请检查输出。"
    else
        info "未检测到需要 purge 的软件包"
    fi
    apt-get update >/dev/null 2>&1 || warn "apt-get update 失败，请手动执行。"
}

print_summary() {
    cat <<EOF

================================================================
卸载完成 (目标: ${COMPONENT})
----------------------------------------------------------------
EOF
    if [[ "$COMPONENT" == all ]]; then
        cat <<'EOF'
已移除 LNMP 软件、管理命令、安装器生成的配置与 APT 仓库，并还原了
可被还原的 .lnmp-debian.orig 配置。/etc/nginx/conf.d/ 下所有配置（含
default.conf）均未处理，下次安装时 default.conf 会被直接覆盖。
EOF
    else
        printf '已移除 %s 相关软件、配置与 APT 仓库；未选择的组件、管理命令和共享配置保持原样。\n' "$COMPONENT"
    fi
    cat <<EOF

以下数据未被处理，请自行确认：
  数据库数据:     ${MYSQL_DATA_DIR}
  网站文件:       ${WEB_ROOT}
  SSL 证书:       ${NGINX_DIR}/ssl
  站点配置:       ${NGINX_DIR}/conf.d/（含 default.conf）
  日志:           ${NGINX_LOG_DIR}
  ACME 程序目录:  ${ACME_HOME}
  ACME 证书目录:  ${ACME_CERT_HOME}（与 SSL 证书同目录）
  残留备份:       *.lnmp-debian.orig（如有）
================================================================
EOF
}

# ---- 主流程 ----
collect_packages
build_plan
print_plan

case "$COMPONENT" in
    mysql) run_mysql ;;
    nginx) run_nginx ;;
    php) run_php ;;
    all)
        stop_acme_timer
        run_mysql
        run_nginx
        run_php
        run_all_extra
        ;;
esac

purge_selected_packages
systemctl daemon-reload >/dev/null 2>&1 || true
print_summary
