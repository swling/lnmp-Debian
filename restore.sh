#!/usr/bin/env bash
# restore.sh - 从 backup.sh 归档还原 LNMP 配置；可用 --php-version 指定目标 PHP 版本。
set -Eeuo pipefail

PROG=${0##*/}
ARCHIVE=""
TARGET_PHP=""
DRY_RUN=0
YES=0
LIST_ONLY=0

usage() {
    cat <<EOF
Usage: $PROG -a <归档.tar.gz> [options]

Options:
  -a, --archive FILE      备份归档（必需）
  -p, --php-version VER   目标 PHP 版本，如 8.4（默认：归档记录的版本）
  -n, --dry-run           只列出计划写入的路径，不修改系统
  -l, --list              只列出归档内容与元信息，不修改系统
  -y, --yes               跳过交互确认
  -h, --help              显示帮助

说明：
  - 还原前会把将被覆盖的文件备份到 /home/backup/lnmp-restore-backup-<时间戳>/。
  - 若目标版本与备份时不同，脚本改写以下版本相关字段：
      php<版本>-fpm（socket/服务名）、/etc/php/<版本>/、php-upstream-<版本>、
      PHP_VERSION="..."、/etc/lnmp-debian/php-version 的内容。
  - 网站文件与数据库数据不在备份中，需另行处理。
  - PHP 扩展 ABI 目录（如 /usr/lib/php/20240924）无法按版本号推断，
    若升级 PHP 主版本，请人工核对扩展配置。
EOF
}

log()  { printf '%s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

require_root() {
    [[ "$(id -u)" -eq 0 ]] || fail "请以 root 运行本脚本。"
}

# sed 正则侧转义（版本字符串含点号）
escape_pattern() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//./\\.}
    s=${s//#/\\#}
    printf '%s' "$s"
}

# sed 替换侧转义
escape_replacement() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//&/\\&}
    s=${s//#/\\#}
    printf '%s' "$s"
}

while (($#)); do
    case "$1" in
        -a|--archive)
            [[ $# -ge 2 ]] || fail "选项 $1 缺少参数。"
            ARCHIVE=$2; shift 2 ;;
        -p|--php-version)
            [[ $# -ge 2 ]] || fail "选项 $1 缺少参数。"
            TARGET_PHP=$2; shift 2 ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        -l|--list) LIST_ONLY=1; shift ;;
        -y|--yes) YES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "未知参数: $1" ;;
    esac
done

[[ -n "$ARCHIVE" ]] || { usage >&2; fail "必须用 -a/--archive 指定备份归档。"; }
[[ -f "$ARCHIVE" ]] || fail "归档文件不存在: $ARCHIVE"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

if ! tar -xzf "$ARCHIVE" -C "$STAGE" 2>/dev/null; then
    fail "无法解包归档（请用本工具配套的 backup.sh 生成）: $ARCHIVE"
fi
[[ -f "$STAGE/manifest" ]] || fail "归档缺少 manifest，格式不正确。"

SOURCE_PHP="$(sed -n 's/^SOURCE_PHP_VERSION=//p' "$STAGE/manifest" | head -n1 || true)"
FORMAT="$(sed -n 's/^BACKUP_FORMAT=//p' "$STAGE/manifest" | head -n1 || true)"
[[ "$FORMAT" == "1" ]] || fail "不支持的备份格式: ${FORMAT:-未知}"

if (( LIST_ONLY )); then
    log "归档: $ARCHIVE"
    log "备份时间: $(sed -n 's/^BACKUP_TIME=//p' "$STAGE/manifest" | head -n1 || true)"
    log "来源主机: $(sed -n 's/^HOST=//p' "$STAGE/manifest" | head -n1 || true)"
    log "备份时 PHP 版本: ${SOURCE_PHP:-未知}"
    log "归档文件："
    (cd "$STAGE" && find config php -mindepth 1 -printf '  %y %p\n' 2>/dev/null | sort) || true
    exit 0
fi

require_root

target="${TARGET_PHP:-$SOURCE_PHP}"
[[ -n "$target" ]] || fail "归档未记录 PHP 版本，请用 --php-version 指定目标版本。"
[[ "$target" =~ ^[0-9]+\.[0-9]+$ ]] || fail "PHP 版本格式应为如 8.4 的数字: $target"

src="${SOURCE_PHP:-$target}"

if [[ "$src" != "$target" ]]; then
    src_p="$(escape_pattern "$src")"
    dst_r="$(escape_replacement "$target")"
    changed=0
    while IFS= read -r -d '' f; do
        [[ -L "$f" ]] && continue
        grep -Iq . "$f" 2>/dev/null || continue
        sed -i \
            -e "s/php${src_p}-fpm/php${dst_r}-fpm/g" \
            -e "s#/etc/php/${src_p}/#/etc/php/${dst_r}/#g" \
            -e "s/php-upstream-${src_p}/php-upstream-${dst_r}/g" \
            -e "s/PHP_VERSION=\"${src_p}\"/PHP_VERSION=\"${dst_r}\"/g" \
            "$f" || true
        ((changed+=1))
    done < <(find "$STAGE/config" "$STAGE/php" -type f -print0 2>/dev/null)
    log "已将版本相关字段从 PHP ${src} 改写为 ${target}（处理 ${changed} 个文件）。"

    state_file="$STAGE/config/etc/lnmp-debian/php-version"
    if [[ -f "$state_file" && ! -L "$state_file" ]]; then
        printf '%s\n' "$target" > "$state_file"
        log "已更新状态文件 /etc/lnmp-debian/php-version。"
    fi
    warn "PHP 扩展 ABI 目录无法自动推断；若目标 PHP 版本不同，请人工核对 /etc/php/${target}/fpm/conf.d 下的扩展配置。"
else
    log "目标 PHP 版本与备份一致（${target}），无需改写版本字段。"
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
RESTORE_BACKUP_DIR="/home/backup/lnmp-restore-backup-$STAMP"

# install_tree <源目录> <目标根目录> <说明> <plan|apply>
install_tree() {
    local src_root=$1 dest_root=$2 label=$3 mode=$4
    [[ -d "$src_root" ]] || return 0
    local rel entry dest parent
    # 先建目录，保证父目录先于子项
    while IFS= read -r -d '' entry; do
        rel="${entry#"$src_root"/}"
        dest="${dest_root%/}/$rel"
        if [[ "$mode" == "plan" ]]; then
            printf '  [mkdir ] %s\n' "$dest"
        else
            mkdir -p -- "$dest"
        fi
    done < <(find "$src_root" -mindepth 1 -type d -print0)

    while IFS= read -r -d '' entry; do
        rel="${entry#"$src_root"/}"
        dest="${dest_root%/}/$rel"
        if [[ -e "$dest" || -L "$dest" ]]; then
            if [[ "$mode" == "plan" ]]; then
                printf '  [替换 ] %s （原文件将备份）\n' "$dest"
            else
                parent="$(dirname "$RESTORE_BACKUP_DIR/$rel")"
                mkdir -p -- "$parent"
                cp -a -- "$dest" "$RESTORE_BACKUP_DIR/$rel"
                rm -rf -- "$dest"
                mkdir -p -- "$(dirname "$dest")"
                cp -a -- "$entry" "$dest"
            fi
        elif [[ "$mode" == "plan" ]]; then
            printf '  [新建 ] %s\n' "$dest"
        else
            mkdir -p -- "$(dirname "$dest")"
            cp -a -- "$entry" "$dest"
        fi
    done < <(find "$src_root" -mindepth 1 ! -type d -print0)
    log "${label}：${mode} 完成。"
}

log "归档 PHP 版本: ${src:-未知}  ->  还原目标版本: $target"
log "归档: $ARCHIVE"
log "计划写入的路径："
install_tree "$STAGE/config" "/" "配置/证书/ACME" plan
install_tree "$STAGE/php/fpm" "/etc/php/$target/fpm" "PHP-FPM 配置" plan

if (( DRY_RUN )); then
    log "[dry-run] 未修改系统。"
    exit 0
fi

log "被覆盖的现有文件将备份到: $RESTORE_BACKUP_DIR"
if (( ! YES )); then
    answer=""
    read -r -p "确认按以上清单还原？输入 yes 继续: " answer || true
    [[ "$answer" == "yes" ]] || { log "已取消。"; exit 0; }
fi

install_tree "$STAGE/config" "/" "配置/证书/ACME" apply
install_tree "$STAGE/php/fpm" "/etc/php/$target/fpm" "PHP-FPM 配置" apply

log "还原完成。建议随后执行："
log "  nginx -t && systemctl reload nginx"
log "  systemctl status php${target}-fpm   # 或对应的 lnmp-php-upstream.service"
log "  systemctl status lnmp-acme-renew.timer"
