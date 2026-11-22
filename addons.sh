#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -r /etc/lnmp-debian.conf ]]; then
    # shellcheck disable=SC1091
    . /etc/lnmp-debian.conf
elif [[ -r "${SCRIPT_DIR}/lnmp-debian.conf" ]]; then
    # shellcheck disable=SC1091
    . "${SCRIPT_DIR}/lnmp-debian.conf"
fi

SAVED_PHP_VERSION=
if [[ -r /etc/lnmp-debian/php-version ]]; then
    IFS= read -r SAVED_PHP_VERSION < /etc/lnmp-debian/php-version || true
fi

usage() {
    cat <<'EOF'
Usage:
  addons.sh
  addons.sh {install|uninstall} {memcached|opcache|redis|apcu|imagemagick|exif|fileinfo|ldap|bz2|sodium|imap|swoole}

Packages are installed from the configured APT repositories.
EOF
}

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

require_root() {
    [[ "$(id -u)" -eq 0 ]] || fail "Run this command as root."
}

is_supported_php_version() {
    local major
    [[ "$1" =~ ^([0-9]+)\.[0-9]+$ ]] || return 1
    major="${BASH_REMATCH[1]}"
    (( 10#$major >= 8 ))
}

detect_php_version() {
    local candidate path
    local -a installed_versions

    if is_supported_php_version "$SAVED_PHP_VERSION" &&
       [[ -d "/etc/php/${SAVED_PHP_VERSION}/fpm" ]]; then
        PHP_VERSION=$SAVED_PHP_VERSION
        return
    fi
    if is_supported_php_version "${PHP_VERSION:-}" &&
       [[ -d "/etc/php/${PHP_VERSION}/fpm" ]]; then
        return
    fi

    candidate="$(php -r 'echo PHP_MAJOR_VERSION, ".", PHP_MINOR_VERSION;' 2>/dev/null || true)"
    if is_supported_php_version "$candidate" && [[ -d "/etc/php/${candidate}/fpm" ]]; then
        PHP_VERSION=$candidate
        return
    fi

    installed_versions=()
    for path in /etc/php/*/fpm; do
        [[ -d "$path" ]] || continue
        candidate="${path#/etc/php/}"
        candidate="${candidate%/fpm}"
        is_supported_php_version "$candidate" && installed_versions+=("$candidate")
    done
    if ((${#installed_versions[@]} == 1)); then
        PHP_VERSION="${installed_versions[0]}"
        return
    fi
    if ((${#installed_versions[@]} > 1)) && [[ -t 0 ]]; then
        printf 'Installed PHP-FPM versions:\n'
        for candidate in "${!installed_versions[@]}"; do
            printf '  %d) PHP %s\n' "$((candidate + 1))" "${installed_versions[candidate]}"
        done
        read -r -p "Select PHP version: " candidate
        [[ "$candidate" =~ ^[0-9]+$ ]] &&
            (( candidate >= 1 && candidate <= ${#installed_versions[@]} )) ||
            fail "Invalid PHP version selection."
        PHP_VERSION="${installed_versions[candidate - 1]}"
        return
    fi
    fail "Could not identify an installed PHP-FPM version. Install php8.x-fpm or rerun the LNMP Debian installer."
}

require_php() {
    detect_php_version
    is_supported_php_version "$PHP_VERSION" ||
        fail "PHP-FPM version is unknown; install the LNMP Debian profile first."
}

package_available() {
    local candidate
    candidate="$(apt-cache policy "$1" | awk '/Candidate:/ {print $2; exit}')"
    [[ -n "$candidate" && "$candidate" != '(none)' ]]
}

prepare_addon() {
    local addon=$1
    ADDON_PACKAGES=()
    ADDON_SERVICES=()
    case "$addon" in
        memcached)
            ADDON_PACKAGES=(memcached "php${PHP_VERSION}-memcached")
            ADDON_SERVICES=(memcached)
            ;;
        opcache)
            # OPcache became part of the PHP core in 8.5; sury no longer ships
            # a separate php8.5-opcache (or later) package.
            if dpkg --compare-versions "$PHP_VERSION" ge 8.5; then
                printf 'OPcache is built into PHP %s and always available; no package is needed.\n' \
                    "$PHP_VERSION"
                ADDON_PACKAGES=()
            else
                ADDON_PACKAGES=("php${PHP_VERSION}-opcache")
            fi
            ;;
        redis)
            ADDON_PACKAGES=(redis-server "php${PHP_VERSION}-redis")
            ADDON_SERVICES=(redis-server)
            ;;
        apcu) ADDON_PACKAGES=("php${PHP_VERSION}-apcu") ;;
        imagemagick)
            ADDON_PACKAGES=(imagemagick "php${PHP_VERSION}-imagick")
            ;;
        ldap) ADDON_PACKAGES=("php${PHP_VERSION}-ldap") ;;
        bz2) ADDON_PACKAGES=("php${PHP_VERSION}-bz2") ;;
        imap) ADDON_PACKAGES=("php${PHP_VERSION}-imap") ;;
        swoole) ADDON_PACKAGES=("php${PHP_VERSION}-swoole") ;;
        exif|fileinfo|sodium)
            ADDON_PACKAGES=("php${PHP_VERSION}-common")
            ;;
        *) fail "Unsupported Debian addon: ${addon}" ;;
    esac
}

show_menu() {
    cat <<'EOF'
PHP extensions and services (Debian APT):
  1: Memcached server + PHP extension
  2: OPcache
  3: Redis server + PHP extension
  4: APCu
  5: ImageMagick + PHP extension
  6: Exif (provided by PHP common)
  7: Fileinfo (provided by PHP common)
  8: LDAP
  9: Bz2
 10: Sodium (provided by PHP common)
 11: Imap
 12: Swoole (only if available in configured APT repositories)
 13: Exit
EOF
}

restart_php() {
    local service
    if [[ -r /etc/lnmp-debian/php-upstream-service ]]; then
        IFS= read -r service < /etc/lnmp-debian/php-upstream-service || true
        [[ "$service" == lnmp-php-upstream ]] ||
            fail "Unknown PHP-FPM service configured in /etc/lnmp-debian/php-upstream-service."
    else
        service="php${PHP_VERSION}-fpm"
    fi
    if systemctl is-active --quiet "$service"; then
        systemctl restart "$service"
    fi
}

addon_action() {
    local action=$1 addon=$2 package
    local -a available_packages
    available_packages=()
    require_root
    require_php
    prepare_addon "$addon"
    ((${#ADDON_PACKAGES[@]} > 0)) || return

    if [[ "$action" == uninstall && "$addon" =~ ^(exif|fileinfo|sodium)$ ]]; then
        printf '%s is part of php%s-common and cannot be removed independently.\n' \
            "$addon" "$PHP_VERSION"
        return
    fi

    for package in "${ADDON_PACKAGES[@]}"; do
        if ! package_available "$package"; then
            fail "APT package ${package} is unavailable. This extension is not provided by the configured repositories."
        fi
        available_packages+=("$package")
    done

    if [[ "$action" == install ]]; then
        apt-get install -y "${available_packages[@]}"
        for package in "${ADDON_SERVICES[@]}"; do
            systemctl enable --now "$package"
        done
        restart_php
        printf '%s installed.\n' "$addon"
    else
        apt-get remove -y "${available_packages[@]}"
        restart_php
        printf '%s removed.\n' "$addon"
    fi
}

action="${1:-}"
addon="${2:-}"
if [[ -z "$action" ]]; then
    show_menu
    read -r -p "Select addon number: " choice
    case "$choice" in
        1) addon=memcached ;;
        2) addon=opcache ;;
        3) addon=redis ;;
        4) addon=apcu ;;
        5) addon=imagemagick ;;
        6) addon=exif ;;
        7) addon=fileinfo ;;
        8) addon=ldap ;;
        9) addon=bz2 ;;
        10) addon=sodium ;;
        11) addon=imap ;;
        12) addon=swoole ;;
        13|exit) exit 0 ;;
        *) fail "Invalid addon selection: ${choice}" ;;
    esac
    action=install
fi

case "$action" in
    install|uninstall)
        [[ -n "$addon" ]] || { usage >&2; exit 2; }
        addon="${addon,,}"
        addon_action "$action" "$addon"
        ;;
    --help|-h)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
