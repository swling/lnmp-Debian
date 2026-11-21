#!/usr/bin/env bash
# backup.sh - 备份 LNMP Debian 的域名、证书、ACME 数据与自定义配置。
# 不备份网站文件与数据库数据（这两类通常由用户自行存放在独立磁盘）。
set -Eeuo pipefail

PROG=${0##*/}
OUTPUT_DIR=/home/backup
YES=0
DRY_RUN=0

usage() {
    cat <<EOF
Usage: $PROG [options]

备份内容：
  域名配置   /etc/nginx/sites-available, /etc/nginx/sites-enabled
  SSL 证书   /etc/nginx/ssl（含 acme.sh 数据：账户密钥、配置、各域名证书）
  ACME 程序  /usr/local/acme.sh（--home 程序目录）
  LNMP 配置  /etc/lnmp-debian.conf, /etc/lnmp-debian/
  Nginx 自定义片段 /etc/nginx/nginx.conf, conf.d, snippets, rewrite
  MySQL 配置   /etc/mysql 整个目录（my.cnf、conf.d/、mysql.conf.d/ 及自定义片段；不含数据库数据）
  PHP-FPM 配置     /etc/php/<当前版本>/fpm/（归档中去掉版本号，便于还原时指定版本）
  LNMP 相关 systemd 单元

不备份：网站文件（/home/wwwroot）、数据库数据（含自定义数据目录）、日志。

Options:
  -o, --output DIR   归档输出目录（默认: ${OUTPUT_DIR}）
  -n, --dry-run      只列出将要备份的路径，不实际打包
  -y, --yes          跳过交互确认
  -h, --help         显示帮助
EOF
}

log()  { printf '%s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

require_root() {
    [[ "$(id -u)" -eq 0 ]] || fail "请以 root 运行本脚本。"
}

detect_php_version() {
    local v=""
    if [[ -r /etc/lnmp-debian/php-version ]]; then
        IFS= read -r v < /etc/lnmp-debian/php-version || true
    fi
    if [[ -z "$v" ]]; then
        local d
        for d in /etc/php/*/fpm; do
            [[ -d "$d" ]] || continue
            v="${d#/etc/php/}"
            v="${v%/fpm}"
            break
        done
    fi
    if [[ -z "$v" ]] && command -v php >/dev/null 2>&1; then
        v="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"
    fi
    printf '%s' "$v"
}

while (($#)); do
    case "$1" in
        -o|--output)
            [[ $# -ge 2 ]] || fail "选项 $1 缺少参数。"
            OUTPUT_DIR=$2; shift 2 ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        -y|--yes) YES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "未知参数: $1" ;;
    esac
done

require_root

PHP_VERSION="$(detect_php_version)"
[[ -n "$PHP_VERSION" ]] || fail "无法检测 PHP 版本；请确认 PHP 已安装，或 /etc/lnmp-debian/php-version 存在。"

BACKUP_PATHS=(
    /etc/nginx/nginx.conf
    /etc/nginx/conf.d
    /etc/nginx/snippets
    /etc/nginx/rewrite
    /etc/nginx/ssl
    /etc/nginx/sites-available
    /etc/nginx/sites-enabled
    /etc/mysql
    /etc/lnmp-debian.conf
    /etc/lnmp-debian
    /usr/local/acme.sh
    /etc/systemd/system/lnmp-acme-renew.service
    /etc/systemd/system/lnmp-acme-renew.timer
    /etc/systemd/system/lnmp-php-upstream.service
)

PHP_FPM_DIR="/etc/php/${PHP_VERSION}/fpm"

log "PHP 版本（将记录到归档，供还原时替换）: $PHP_VERSION"
log "备份路径："
printf '  %s\n' "${BACKUP_PATHS[@]}"
printf '  %s\n' "$PHP_FPM_DIR  ->  归档内 php/fpm/（不含版本号）"
warn "网站文件与数据库数据未包含在备份中，请另行处理。"

if (( DRY_RUN )); then
    log "[dry-run] 未创建归档。"
    exit 0
fi

if (( ! YES )); then
    local_answer=""
    read -r -p "确认按以上清单创建备份？输入 yes 继续: " local_answer || true
    [[ "$local_answer" == "yes" ]] || { log "已取消。"; exit 0; }
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/config"

copied=0
for src in "${BACKUP_PATHS[@]}"; do
    if [[ ! -e "$src" && ! -L "$src" ]]; then
        warn "跳过不存在的路径: $src"
        continue
    fi
    rel="${src#/}"
    mkdir -p "$STAGE/config/$(dirname "$rel")"
    cp -a -- "$src" "$STAGE/config/$rel"
    ((copied+=1))
done

if [[ -d "$PHP_FPM_DIR" ]]; then
    mkdir -p "$STAGE/php/fpm"
    cp -a -- "$PHP_FPM_DIR/." "$STAGE/php/fpm/"
else
    warn "未找到 PHP-FPM 配置目录: $PHP_FPM_DIR"
fi

(( copied > 0 )) || fail "没有可备份的内容。"

{
    printf 'BACKUP_FORMAT=1\n'
    printf 'BACKUP_TIME=%s\n' "$(date -Is)"
    printf 'HOST=%s\n' "$(hostname 2>/dev/null || printf unknown)"
    printf 'SOURCE_PHP_VERSION=%s\n' "$PHP_VERSION"
} > "$STAGE/manifest"

mkdir -p "$OUTPUT_DIR"
archive="${OUTPUT_DIR%/}/lnmp-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
tar -czf "$archive" -C "$STAGE" manifest config php
chmod 0600 "$archive"   # 归档含 MySQL 账号信息、证书私钥、ACME 账户密钥

log "备份完成: $archive"
log "还原时示例: restore.sh --archive '$archive' --php-version <目标版本> --dry-run"
