#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MYSQL_KEYRING=/usr/share/keyrings/mysql-apt.gpg
MYSQL_SOURCE=/etc/apt/sources.list.d/mysql.list
MYSQL_REPO_URL=https://repo.mysql.com/apt/debian
MYSQL_COMPONENTS=
MYSQL_COMPONENT=
MYSQL_CODENAME=
MYSQL_ARCHITECTURE=
NGINX_KEY_URL=https://nginx.org/keys/nginx_signing.key
NGINX_KEYRING=/usr/share/keyrings/nginx-archive-keyring.gpg
NGINX_SOURCE=/etc/apt/sources.list.d/nginx.list
NGINX_PIN=/etc/apt/preferences.d/99nginx
NGINX_REPO_BASE=https://nginx.org/packages
PHP_REPO_URL=https://packages.sury.org/php
PHP_SOURCE=/etc/apt/sources.list.d/php.list
PHP_KEYRING=/usr/share/keyrings/debsuryorg-archive-keyring.gpg
PHP_PIN=/etc/apt/preferences.d/99sury-php
SYSTEM_CONFIG=/etc/lnmp-debian.conf

if [[ -r "$SYSTEM_CONFIG" ]]; then
    # shellcheck disable=SC1090
    . "$SYSTEM_CONFIG"
else
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/lnmp-debian.conf"
fi

WEB_ROOT="${WEB_ROOT:-/home/wwwroot}"
DEFAULT_WEB_ROOT="${DEFAULT_WEB_ROOT:-${WEB_ROOT}/default}"
NGINX_LOG_DIR="${NGINX_LOG_DIR:-/var/log/nginx}"
MYSQL_DATA_DIR="${MYSQL_DATA_DIR:-/var/lib/mysql}"
PHP_VERSION="${PHP_VERSION:-}"
NGINX_VERSION="${NGINX_VERSION:-}"
NGINX_CHANNEL="${NGINX_CHANNEL:-stable}"
MYSQL_VERSION="${MYSQL_VERSION:-}"
NGINX_CONFIG_DIR=/etc/nginx
NGINX_SNIPPET_DIR="${NGINX_CONFIG_DIR}/snippets"
REWRITE_DIR="${NGINX_CONFIG_DIR}/rewrite"
CLEAR_MYSQL_DATA=0

usage() {
    cat <<'EOF'
Usage: install.sh

Install the LNMP Debian profile on Debian 13 or later:
  Nginx: nginx.org official APT repository (stable or mainline channel)
  PHP: sury APT repository
  MySQL: Oracle MySQL APT repository (server components discovered dynamically)
  ACME client: Debian APT repository

Nginx and MySQL are installed from their official APT repositories, PHP from
sury. Installing from sury up front keeps PHP upgrades on the same source.
EOF
}

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

info() {
    printf '  - %s\n' "$*"
}

list_package_versions() {
    local package=$1 origin=${2:-}
    apt-cache madison "$package" |
        awk -F'|' -v origin="$origin" '
            {
                repository = tolower($3)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
                if ($2 != "" && (origin == "" || index(repository, tolower(origin))))
                    print $2
            }' |
        sort -Vu
}

select_package_version() {
    local label=$1 package=$2 configured=${3:-} minimum_major=${4:-0} origin=${5:-}
    local choice index default_index version major marker
    local -a versions available_versions
    mapfile -t available_versions < <(list_package_versions "$package" "$origin")
    versions=()
    for version in "${available_versions[@]}"; do
        major="${version#*:}"
        major="${major%%.*}"
        [[ "$major" =~ ^[0-9]+$ ]] || continue
        (( major >= minimum_major )) && versions+=("$version")
    done
    ((${#versions[@]} > 0)) || fail "No APT versions are available for ${package}."

    default_index=$((${#versions[@]} - 1))
    if [[ -n "$configured" ]]; then
        for index in "${!versions[@]}"; do
            if [[ "${versions[index]}" == "$configured" ]]; then
                default_index=$index
                break
            fi
        done
        # Fall back to an available version when the configured one is no longer in the repo.
        [[ "${versions[default_index]}" == "$configured" ]] ||
            warn "${label} version ${configured} is no longer available for ${package}; using ${versions[default_index]}."
    fi

    printf '\nAvailable %s versions (%s):\n' "$label" "$package"
    for index in "${!versions[@]}"; do
        marker=
        [[ "$index" -eq "$default_index" ]] && marker=' [default]'
        printf '  %d) %s%s\n' "$((index + 1))" "${versions[index]}" "$marker"
    done
    if [[ -t 0 ]]; then
        read -r -p "Select version [${versions[default_index]}]: " choice
    else
        choice=
    fi
    if [[ -z "$choice" ]]; then
        SELECTED_PACKAGE_VERSION="${versions[default_index]}"
    elif [[ "$choice" =~ ^[0-9]+$ ]] &&
         (( choice >= 1 && choice <= ${#versions[@]} )); then
        SELECTED_PACKAGE_VERSION="${versions[choice - 1]}"
    elif [[ " ${versions[*]} " == *" ${choice} "* ]]; then
        SELECTED_PACKAGE_VERSION=$choice
    else
        fail "Invalid ${label} version selection: ${choice}"
    fi
}

select_mysql_version() {
    local choice index candidate marker kind version source major
    local -a raw_lines versions sources is_lts

    # madison's third column carries the originating component, which is how
    # LTS and innovation releases are told apart and how the source is pinned.
    mapfile -t raw_lines < <(
        apt-cache madison mysql-server |
            awk -F'|' '{
                v = $2; s = $3;
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", v);
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", s);
                if (v != "") print v "\t" s
            }' |
            sort -t $'\t' -k1,1V -u
    )

    versions=()
    sources=()
    is_lts=()
    for candidate in "${raw_lines[@]}"; do
        version="${candidate%%$'\t'*}"
        source="${candidate#*$'\t'}"
        major="${version#*:}"
        major="${major%%.*}"
        [[ "$major" =~ ^[0-9]+$ ]] || continue
        (( major >= 8 )) || continue
        versions+=("$version")
        sources+=("$source")
        if [[ "$source" == *-lts* ]]; then
            is_lts+=(1)
        else
            is_lts+=(0)
        fi
    done
    ((${#versions[@]} > 0)) ||
        fail "No MySQL 8+ versions are available from the Oracle APT repository."

    # Versions are sorted ascending, so the last LTS entry is the newest LTS.
    # Fall back to the newest version when no LTS component is available.
    default_index=-1
    for index in "${!versions[@]}"; do
        (( is_lts[index] )) && default_index=$index
    done
    (( default_index >= 0 )) || default_index=$((${#versions[@]} - 1))

    if [[ -n "$MYSQL_VERSION" ]]; then
        for index in "${!versions[@]}"; do
            if [[ "${versions[index]}" == "$MYSQL_VERSION" ]]; then
                default_index=$index
                break
            fi
        done
        [[ "${versions[default_index]}" == "$MYSQL_VERSION" ]] ||
            fail "MySQL version ${MYSQL_VERSION} is not available from the Oracle APT repository."
    fi

    printf '\nAvailable MySQL versions:\n'
    for index in "${!versions[@]}"; do
        marker=
        [[ "$index" -eq "$default_index" ]] && marker=' [default]'
        kind=innovation
        (( is_lts[index] )) && kind=LTS
        printf '  %d) %s (%s)%s\n' "$((index + 1))" "${versions[index]}" "$kind" "$marker"
    done

    if [[ -t 0 ]]; then
        read -r -p "Select version [${versions[default_index]}]: " choice
    else
        choice=
    fi
    if [[ -z "$choice" ]]; then
        index=$default_index
    elif [[ "$choice" =~ ^[0-9]+$ ]] &&
         (( choice >= 1 && choice <= ${#versions[@]} )); then
        index=$((choice - 1))
    elif [[ " ${versions[*]} " == *" ${choice} "* ]]; then
        index=-1
        for candidate in "${!versions[@]}"; do
            if [[ "${versions[candidate]}" == "$choice" ]]; then
                index=$candidate
                break
            fi
        done
    else
        fail "Invalid MySQL version selection: ${choice}"
    fi

    MYSQL_VERSION="${versions[index]}"
    source="${sources[index]}"
    if [[ "$source" =~ (mysql-[a-zA-Z0-9][a-zA-Z0-9.-]*) ]]; then
        MYSQL_COMPONENT="${BASH_REMATCH[1]}"
    else
        fail "Could not determine the APT component for MySQL ${MYSQL_VERSION}."
    fi
}

finalize_mysql_repository() {
    [[ -n "$MYSQL_COMPONENT" ]] ||
        fail "No MySQL component was selected; refusing to configure the APT source."
    # A single component avoids mixing mysql-common / libmysqlclient versions
    # from different series while resolving the pinned mysql-server version.
    write_mysql_source "$MYSQL_COMPONENT"
    apt-get update
}

select_php_version() {
    local choice index default_index candidate marker php_major
    local -a versions
    local -a package_names
    local -a sury_versions
    mapfile -t package_names < <(
        apt-cache pkgnames |
            grep -E '^php[0-9]+\.[0-9]+-fpm$' |
            sed -E 's/^php([0-9]+\.[0-9]+)-fpm$/\1/' |
            sort -Vu
    )
    versions=()
    for candidate in "${package_names[@]}"; do
        php_major="${candidate%%.*}"
        [[ "$php_major" =~ ^[0-9]+$ ]] || continue
        # Skip older branches instead of aborting when the repo also offers PHP 7.x.
        (( php_major >= 8 )) || continue
        # Only offer branches that sury actually publishes; Debian-only branches
        # would otherwise be installed from Debian despite the sury pin.
        mapfile -t sury_versions < <(list_package_versions "php${candidate}-fpm" packages.sury.org)
        ((${#sury_versions[@]} > 0)) || continue
        versions+=("$candidate")
    done
    ((${#versions[@]} > 0)) || fail "No PHP 8+ FPM packages are available from sury."
    default_index=$((${#versions[@]} - 1))
    if [[ -n "$PHP_VERSION" ]]; then
        for index in "${!versions[@]}"; do
            if [[ "${versions[index]}" == "$PHP_VERSION" ]]; then
                default_index=$index
                break
            fi
        done
        # The configured branch may have been replaced on reinstall; warn and use an available one.
        [[ "${versions[default_index]}" == "$PHP_VERSION" ]] ||
            warn "Configured PHP ${PHP_VERSION} is not available from APT; using ${versions[default_index]}."
    fi

    printf '\nAvailable PHP versions:\n'
    for index in "${!versions[@]}"; do
        marker=
        [[ "$index" -eq "$default_index" ]] && marker=' [default]'
        printf '  %d) PHP %s%s\n' "$((index + 1))" "${versions[index]}" "$marker"
    done
    if [[ -t 0 ]]; then
        read -r -p "Select PHP version [${versions[default_index]}]: " choice
    else
        choice=
    fi
    if [[ -z "$choice" ]]; then
        PHP_VERSION="${versions[default_index]}"
    elif [[ "$choice" =~ ^[0-9]+$ ]] &&
         (( choice >= 1 && choice <= ${#versions[@]} )); then
        PHP_VERSION="${versions[choice - 1]}"
    elif [[ " ${versions[*]} " == *" ${choice} "* ]]; then
        PHP_VERSION=$choice
    else
        fail "Invalid PHP version selection: ${choice}"
    fi
}

discover_mysql_components() {
    local components
    components="$(
        curl --fail --silent --show-error --location \
            "${MYSQL_REPO_URL}/dists/${MYSQL_CODENAME}/Release" |
            awk -F': *' '$1 == "Components" { print $2; exit }' |
            tr ' ' '\n' |
            awk '
                /^mysql-/ &&
                !/^mysql-apt-config$/ &&
                !/^mysql-cluster-/ &&
                !/^mysql-tools/ &&
                !/-dbg$/ { print }
            ' |
            paste -sd' ' -
    )"
    [[ -n "$components" ]] ||
        fail "Could not discover MySQL server components from ${MYSQL_REPO_URL} for ${MYSQL_CODENAME}."
    printf '%s' "$components"
}

write_mysql_source() {
    local components=$1 source_tmp
    install -d -m 0755 "$(dirname "$MYSQL_SOURCE")"
    source_tmp="$(mktemp "${MYSQL_SOURCE}.XXXXXX")"
    printf 'deb [arch=%s signed-by=%s] %s/ %s %s\n' \
        "$MYSQL_ARCHITECTURE" "$MYSQL_KEYRING" "$MYSQL_REPO_URL" \
        "$MYSQL_CODENAME" "$components" > "$source_tmp"
    chmod 0644 "$source_tmp"
    mv "$source_tmp" "$MYSQL_SOURCE"
}

install_mysql_repository() {
    local key_tmp key_fingerprint
    MYSQL_CODENAME="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"
    MYSQL_ARCHITECTURE="$(dpkg --print-architecture)"
    [[ "$MYSQL_ARCHITECTURE" == amd64 ]] ||
        fail "Oracle MySQL's Debian 13 APT repository currently supports amd64 only (found: $MYSQL_ARCHITECTURE)."
    [[ -n "$MYSQL_CODENAME" ]] || fail "Could not determine Debian release codename."

    # Keep every server component enabled during discovery so the version menu
    # can offer all MySQL series the repository currently publishes.
    MYSQL_COMPONENTS="$(discover_mysql_components)"

    install -d -m 0755 /usr/share/keyrings
    key_tmp="$(mktemp)"
    trap 'rm -f "$key_tmp"' RETURN
    curl --fail --silent --show-error --location \
        https://repo.mysql.com/RPM-GPG-KEY-mysql-2025 -o "$key_tmp"
    key_fingerprint="$(gpg --show-keys --with-colons "$key_tmp" |
        awk -F: '$1 == "fpr" { print $10; exit }')"
    [[ "$key_fingerprint" == BCA43417C3B485DD128EC6D4B7B3B788A8D3785C ]] ||
        fail "Unexpected Oracle MySQL repository signing key fingerprint: ${key_fingerprint:-unreadable}"
    gpg --dearmor --yes --output "$MYSQL_KEYRING" "$key_tmp"
    chmod 0644 "$MYSQL_KEYRING"
    write_mysql_source "$MYSQL_COMPONENTS"
    printf 'Discovered MySQL components: %s\n' "$MYSQL_COMPONENTS"
    rm -f "$key_tmp"
    trap - RETURN
}

install_php_repository() {
    local codename architecture key_tmp source_tmp pin_tmp fingerprint

    codename="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"
    architecture="$(dpkg --print-architecture)"
    [[ "$architecture" == amd64 || "$architecture" == arm64 || "$architecture" == armhf ]] ||
        fail "The sury PHP repository does not support this architecture: ${architecture}"
    [[ -n "$codename" ]] || fail "Could not determine Debian release codename."

    # Leftover unrelated sources are backed up before overwriting, like the nginx source.
    if [[ -e "$PHP_SOURCE" ]] &&
       ! grep -Fq 'packages.sury.org/php' "$PHP_SOURCE"; then
        cp -p -- "$PHP_SOURCE" "${PHP_SOURCE}.lnmp-debian.orig" 2>/dev/null || true
        warn "Existing APT source ${PHP_SOURCE} is unrelated to sury; backed up and overwritten."
    fi
    if [[ -e "$PHP_PIN" ]] &&
       ! grep -Fq 'Pin: origin packages.sury.org' "$PHP_PIN"; then
        cp -p -- "$PHP_PIN" "${PHP_PIN}.lnmp-debian.orig" 2>/dev/null || true
        warn "Existing APT preference ${PHP_PIN} is unrelated to sury; backed up and overwritten."
    fi

    install -d -m 0755 /usr/share/keyrings "$(dirname "$PHP_SOURCE")" "$(dirname "$PHP_PIN")"
    key_tmp="$(mktemp)"
    source_tmp="$(mktemp "${PHP_SOURCE}.XXXXXX")"
    pin_tmp="$(mktemp "${PHP_PIN}.XXXXXX")"
    trap 'rm -f "$key_tmp" "$source_tmp" "$pin_tmp"' RETURN

    curl --fail --silent --show-error --location \
        "${PHP_REPO_URL}/apt.gpg" -o "$key_tmp"
    fingerprint="$(gpg --show-keys --with-colons "$key_tmp" |
        awk -F: '$1 == "fpr" { gsub(/ /, "", $10); print $10; exit }')"
    [[ "$fingerprint" == 15058500A0235D97F5D10063B188E2B695BD4743 ]] ||
        fail "Unexpected sury PHP repository signing key fingerprint: ${fingerprint:-unreadable}"
    install -m 0644 "$key_tmp" "$PHP_KEYRING"

    printf 'deb [signed-by=%s] %s/ %s main\n' \
        "$PHP_KEYRING" "$PHP_REPO_URL" "$codename" > "$source_tmp"
    # sury and Debian ship identically named php8.x-* packages. Pin sury above
    # the Debian default but below 1000 so apt never downgrades.
    printf 'Package: *\nPin: origin packages.sury.org\nPin-Priority: 900\n' > "$pin_tmp"
    chmod 0644 "$source_tmp" "$pin_tmp"
    mv "$source_tmp" "$PHP_SOURCE"
    mv "$pin_tmp" "$PHP_PIN"

    rm -f "$key_tmp" "$source_tmp" "$pin_tmp"
    trap - RETURN
    printf 'PHP APT source configured: %s %s main (sury)\n' "$PHP_REPO_URL" "$codename"
}

install_nginx_repository() {
    local codename channel_url key_tmp keyring_tmp source_tmp pin_tmp fingerprint

    [[ "$NGINX_CHANNEL" == stable || "$NGINX_CHANNEL" == mainline ]] ||
        fail "NGINX_CHANNEL must be stable or mainline (found: ${NGINX_CHANNEL})."
    codename="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"
    [[ -n "$codename" ]] || fail "Could not determine Debian release codename."
    case "$NGINX_CHANNEL" in
        stable) channel_url="${NGINX_REPO_BASE}/debian" ;;
        mainline) channel_url="${NGINX_REPO_BASE}/mainline/debian" ;;
    esac

    # Leftover APT source files no longer abort installation: back them up before overwriting.
    if [[ -e "$NGINX_SOURCE" ]] &&
       ! grep -Fq 'https://nginx.org/packages/' "$NGINX_SOURCE"; then
        cp -p -- "$NGINX_SOURCE" "${NGINX_SOURCE}.lnmp-debian.orig" 2>/dev/null || true
        warn "Existing APT source ${NGINX_SOURCE} is unrelated to nginx.org; backed up and overwritten."
    fi
    if [[ -e "$NGINX_PIN" ]] &&
       ! grep -Fq 'Pin: origin nginx.org' "$NGINX_PIN"; then
        cp -p -- "$NGINX_PIN" "${NGINX_PIN}.lnmp-debian.orig" 2>/dev/null || true
        warn "Existing APT preference ${NGINX_PIN} is unrelated to nginx.org; backed up and overwritten."
    fi

    install -d -m 0755 /usr/share/keyrings "$(dirname "$NGINX_SOURCE")" "$(dirname "$NGINX_PIN")"
    key_tmp="$(mktemp)"
    keyring_tmp="$(mktemp)"
    source_tmp="$(mktemp "${NGINX_SOURCE}.XXXXXX")"
    pin_tmp="$(mktemp "${NGINX_PIN}.XXXXXX")"
    trap 'rm -f "$key_tmp" "$keyring_tmp" "$source_tmp" "$pin_tmp"' RETURN

    curl --fail --silent --show-error --location "$NGINX_KEY_URL" -o "$key_tmp"
    fingerprint="$(gpg --show-keys --with-colons "$key_tmp" |
        awk -F: '$1 == "fpr" { print $10 }' |
        grep -Fx '573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62' || true)"
    [[ -n "$fingerprint" ]] ||
        fail "Unexpected nginx.org signing key fingerprint."
    gpg --dearmor --yes --output "$keyring_tmp" "$key_tmp"
    install -m 0644 "$keyring_tmp" "$NGINX_KEYRING"

    # The nginx.org package shares the Debian package name; keep the pin below
    # 1000 so apt never downgrades a newer installed version.
    printf 'deb [signed-by=%s] %s %s nginx\n' \
        "$NGINX_KEYRING" "$channel_url" "$codename" > "$source_tmp"
    printf 'Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n' \
        > "$pin_tmp"
    chmod 0644 "$source_tmp" "$pin_tmp"
    mv "$source_tmp" "$NGINX_SOURCE"
    mv "$pin_tmp" "$NGINX_PIN"

    rm -f "$key_tmp" "$keyring_tmp" "$source_tmp" "$pin_tmp"
    trap - RETURN
    printf 'Nginx APT source configured: %s %s (%s channel)\n' \
        "$channel_url" "$codename" "$NGINX_CHANNEL"
}

parse_arguments() {
    [[ "${1:-}" != --help && "${1:-}" != -h ]] || {
        usage
        exit 0
    }
    [[ $# -eq 0 ]] || {
        usage >&2
        exit 2
    }
}

validate_platform() {
    [[ "$(id -u)" -eq 0 ]] || fail "Run this installer as root."
    [[ -r /etc/os-release ]] || fail "This script requires Debian 13 or later."
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == debian ]] || fail "Only Debian 13 or later is supported."
    DEBIAN_MAJOR="${VERSION_ID%%.*}"
    [[ "$DEBIAN_MAJOR" =~ ^[0-9]+$ ]] &&
        (( DEBIAN_MAJOR >= 13 )) || fail "Only Debian 13 or later is supported."
    command -v apt-get >/dev/null || fail "apt-get is required."
}

directory_has_entries() {
    [[ -n "$(find "$1" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]
}

clear_mysql_data() {
    find "$MYSQL_DATA_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + ||
        fail "Could not clear MYSQL_DATA_DIR (${MYSQL_DATA_DIR})."
    info "Cleared MYSQL_DATA_DIR: ${MYSQL_DATA_DIR}"
}

confirm_clear_mysql_data() {
    local answer
    warn "MYSQL_DATA_DIR (${MYSQL_DATA_DIR}) already contains data."
    warn "Continuing will DELETE all existing data in that directory and install a fresh MySQL instance."
    read -r -p "Type 'clear' to delete the data and continue, or press Enter to abort: " answer || true
    [[ "$answer" == clear ]] || fail "Installation aborted; MYSQL_DATA_DIR was left unchanged."
    if [[ "$MYSQL_DATA_DIR" == /var/lib/mysql ]]; then
        # The package initializes the default directory, so it must be empty
        # before packages are installed.
        clear_mysql_data
    else
        # Delay the deletion until packages are installed, so a failed install
        # does not leave the machine with neither data nor a working stack.
        CLEAR_MYSQL_DATA=1
        info "Confirmed: MYSQL_DATA_DIR will be cleared after package installation."
    fi
}

clear_mysql_data_if_confirmed() {
    (( CLEAR_MYSQL_DATA )) || return 0
    clear_mysql_data
}

validate_configuration_and_existing_data() {
    local configured_path
    for configured_path in "$WEB_ROOT" "$DEFAULT_WEB_ROOT" "$NGINX_LOG_DIR" "$MYSQL_DATA_DIR"; do
        [[ "$configured_path" == /* && "$configured_path" =~ ^/[A-Za-z0-9_./-]+$ ]] ||
            fail "Configured paths must be absolute and contain only letters, digits, dot, underscore, slash, or hyphen: ${configured_path}"
        [[ "$configured_path" != *"/../"* && "$configured_path" != */.. ]] ||
            fail "Configured paths must not contain parent-directory segments: ${configured_path}"
    done
    [[ "$MYSQL_DATA_DIR" != / ]] || fail "MYSQL_DATA_DIR must not be the filesystem root."
    [[ "$MYSQL_DATA_DIR" != /var/lib/mysql/* && /var/lib/mysql != "$MYSQL_DATA_DIR"/* ]] ||
        fail "MYSQL_DATA_DIR must not be nested inside or above /var/lib/mysql."

    local mariadb_status mysql_community_status
    mariadb_status="$(dpkg-query -W -f='${db:Status-Status}' mariadb-server 2>/dev/null || true)"
    mysql_community_status="$(dpkg-query -W -f='${db:Status-Status}' mysql-community-server 2>/dev/null || true)"
    if [[ "$mariadb_status" == installed ]]; then
        fail "MariaDB is already installed. Back it up and remove or migrate it before installing MySQL."
    fi
    if [[ "$mysql_community_status" != installed ]] &&
       [[ -d "$MYSQL_DATA_DIR" ]] && directory_has_entries "$MYSQL_DATA_DIR"; then
        confirm_clear_mysql_data
    fi
}

prepare_package_sources() {
    if [[ ! -e "$SYSTEM_CONFIG" ]]; then
        install -m 0644 "$SCRIPT_DIR/lnmp-debian.conf" "$SYSTEM_CONFIG"
    fi

    # Leftover package sources no longer abort installation: install dependencies first,
    # then rebuild the sources and refresh indexes.
    apt-get update || warn "apt-get update failed; continuing to install source dependencies."
    apt-get install -y ca-certificates curl gnupg ||
        fail "Could not install ca-certificates / curl / gnupg; check APT sources and network."
    install_mysql_repository
    install_php_repository
    install_nginx_repository
    apt-get update || warn "apt-get update failed after configuring sources; version list may be incomplete."
}

select_install_versions() {
    select_php_version
    select_package_version "Nginx" nginx "$NGINX_VERSION" 0 nginx.org
    NGINX_VERSION="$SELECTED_PACKAGE_VERSION"
    select_mysql_version
    finalize_mysql_repository
}

confirm_install_versions() {
    printf '\nSelected versions:\n'
    printf 'Nginx version: %s\nPHP version:   %s\nMySQL version: %s\n' "$NGINX_VERSION" "$PHP_VERSION" "$MYSQL_VERSION"
    # Non-interactive runs cannot confirm; the version selectors already fell back to defaults.
    [[ -t 0 ]] || return 0
    if ! read -r -p "Press Enter to start installation, or Ctrl+C to abort: " answer; then
        fail "Installation aborted; no packages were installed."
    fi
    printf '\n'
}

install_packages() {
    local -a php_packages=(
        "php${PHP_VERSION}-cli"
        "php${PHP_VERSION}-fpm"
        "php${PHP_VERSION}-mysql"
        "php${PHP_VERSION}-curl"
        "php${PHP_VERSION}-gd"
        "php${PHP_VERSION}-mbstring"
        "php${PHP_VERSION}-xml"
        "php${PHP_VERSION}-zip"
        "php${PHP_VERSION}-bcmath"
        "php${PHP_VERSION}-intl"
    )
    # OPcache is part of the PHP core from 8.5 onward; sury has no separate package.
    if ! dpkg --compare-versions "$PHP_VERSION" ge 8.5; then
        php_packages+=("php${PHP_VERSION}-opcache")
    fi
    apt-get install -y "nginx=${NGINX_VERSION}" "${php_packages[@]}" \
        "mysql-server=${MYSQL_VERSION}" acme.sh

    PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"
    [[ -d "/etc/php/${PHP_VERSION}/fpm" ]] ||
        fail "PHP-FPM configuration for PHP ${PHP_VERSION} was not installed."
    install -d -m 0755 /etc/lnmp-debian
    printf '%s\n' "$PHP_VERSION" > /etc/lnmp-debian/php-version
}

configure_mysql_data_directory() {
    local apparmor_local apparmor_parent
    local mysql_current_real mysql_target_real
    mysql_current_real="$(readlink -f /var/lib/mysql 2>/dev/null || true)"
    mysql_target_real="$(readlink -f "$MYSQL_DATA_DIR" 2>/dev/null || true)"

    if [[ "$MYSQL_DATA_DIR" != /var/lib/mysql ]] &&
       [[ "$mysql_current_real" != "$mysql_target_real" ]]; then
        # Stop the server before changing what /var/lib/mysql points to.
        systemctl stop mysql || true
        mkdir -p "$MYSQL_DATA_DIR"
        if [[ -d /var/lib/mysql ]] && [[ ! -L /var/lib/mysql ]]; then
            cp -a /var/lib/mysql/. "$MYSQL_DATA_DIR"/
            chown -R mysql:mysql "$MYSQL_DATA_DIR"
            # The directory only holds data initialized by the package install.
            rm -rf -- /var/lib/mysql
        elif [[ -L /var/lib/mysql ]]; then
            fail "/var/lib/mysql already points to another directory; refusing to move database files."
        fi
        ln -s "$MYSQL_DATA_DIR" /var/lib/mysql
        mkdir -p /etc/mysql/mysql.conf.d
        cat > /etc/mysql/mysql.conf.d/zz-lnmp-debian.cnf <<EOF
[mysqld]
datadir = ${MYSQL_DATA_DIR}
EOF
        if [[ -f /etc/apparmor.d/usr.sbin.mysqld ]]; then
            apparmor_local=/etc/apparmor.d/local/usr.sbin.mysqld
            apparmor_parent="$(dirname "$MYSQL_DATA_DIR")"
            install -d -m 0755 /etc/apparmor.d/local
            if ! grep -Fq "${MYSQL_DATA_DIR}/** rwk," "$apparmor_local" 2>/dev/null; then
                while [[ "$apparmor_parent" != / ]]; do
                    printf '%s/ r,\n%s/ x,\n' "$apparmor_parent" "$apparmor_parent" \
                        >> "$apparmor_local"
                    apparmor_parent="$(dirname "$apparmor_parent")"
                done
                cat >> "$apparmor_local" <<EOF
${MYSQL_DATA_DIR}/ r,
${MYSQL_DATA_DIR}/** rwk,
EOF
            fi
            if command -v apparmor_parser >/dev/null; then
                apparmor_parser -r /etc/apparmor.d/usr.sbin.mysqld ||
                    warn "Failed to reload AppArmor; run manually: apparmor_parser -r /etc/apparmor.d/usr.sbin.mysqld"
            elif systemctl is-active --quiet apparmor; then
                fail "AppArmor is active but apparmor_parser is unavailable; cannot authorize MYSQL_DATA_DIR."
            fi
        fi
        chown mysql:mysql "$MYSQL_DATA_DIR"
        chmod 0750 "$MYSQL_DATA_DIR"
        systemctl start mysql
    fi
}

ensure_web_user() {
    if ! getent group www >/dev/null; then
        groupadd --system www
    fi
    if ! getent passwd www >/dev/null; then
        useradd --system --gid www --home-dir /home/wwwroot --no-create-home \
            --shell /usr/sbin/nologin www
    fi
}

prepare_nginx_layout() {
    mkdir -p "$NGINX_SNIPPET_DIR" "$REWRITE_DIR" \
        "${NGINX_CONFIG_DIR}/conf.d" \
        "${NGINX_CONFIG_DIR}/ssl" /run/php
    if [[ ! -d "$WEB_ROOT" ]]; then
        mkdir -p "$WEB_ROOT"
        chown www:www "$WEB_ROOT"
    fi
    if [[ ! -d "$DEFAULT_WEB_ROOT" ]]; then
        mkdir -p "$DEFAULT_WEB_ROOT"
        chown www:www "$DEFAULT_WEB_ROOT"
    fi
    if [[ "$NGINX_LOG_DIR" == /var/log/nginx ]]; then
        install -d -m 0755 "$NGINX_LOG_DIR"
    elif [[ ! -d "$NGINX_LOG_DIR" ]]; then
        mkdir -p "$NGINX_LOG_DIR"
        chown www:www "$NGINX_LOG_DIR"
    fi
}

disable_nginx_access_log() {
    local conf=$1 tmp http_line
    tmp="$(mktemp "${conf}.XXXXXX")"
    http_line="$(awk '/^[[:space:]]*http[[:space:]]*\{/ { print NR; exit }' "$conf")"
    [[ -n "$http_line" ]] || fail "Cannot find the http block in ${conf}; refusing to modify access_log."
    awk -v http_line="$http_line" '
        {
            in_http_line[NR] = in_http
            if ($0 ~ /^[[:space:]]*http[[:space:]]*\{/) {
                in_http = 1
                in_http_line[NR] = 1
            }
            if (in_http_line[NR] && $0 ~ /(#[[:space:]]*)?access_log[[:space:]]+[^;]+;/) found = 1
            lines[NR] = $0
            if ($0 ~ /^}/) in_http = 0
        }
        END {
            inserted = 0
            for (i = 1; i <= NR; i++) {
                line = lines[i]
                if (in_http_line[i]) {
                    sub(/(#[[:space:]]*)?access_log[[:space:]]+[^;]+;/, "access_log off;", line)
                }
                print line
                if (i == http_line && !found && !inserted) {
                    print "    access_log off;"
                    inserted = 1
                }
            }
        }
    ' "$conf" > "$tmp"
    chmod --reference="$conf" "$tmp"
    mv "$tmp" "$conf"
}

enable_nginx_gzip() {
    local conf=$1 tmp http_line
    # An active include may use either the prefix-relative or absolute path.
    grep -qE '^[[:space:]]*include[[:space:]]+([^;]*/)?gzip\.conf[[:space:]]*;' "$conf" &&
        return 0
    tmp="$(mktemp "${conf}.XXXXXX")"
    http_line="$(awk '/^[[:space:]]*http[[:space:]]*\{/ { print NR; exit }' "$conf")"
    [[ -n "$http_line" ]] || fail "Cannot find the http block in ${conf}; refusing to add the gzip include."
    awk -v http_line="$http_line" '
        { lines[NR] = $0 }
        END {
            for (i = 1; i <= NR; i++) {
                print lines[i]
                if (i == http_line) print "    include gzip.conf;"
            }
        }
    ' "$conf" > "$tmp"
    chmod --reference="$conf" "$tmp"
    mv "$tmp" "$conf"
}

install_shared_nginx_conf() {
    local source_dir=$1 target_dir=$2 source target name
    [[ -d "$source_dir" ]] || fail "Bundled Nginx config directory is missing: ${source_dir}"
    mkdir -p "$target_dir"
    for source in "$source_dir"/*.conf; do
        [[ -f "$source" ]] || continue
        name="${source##*/}"
        # default-site.conf is a site template, not a reusable top-level config.
        [[ "$name" == default-site.conf ]] && continue
        target="${target_dir}/${name}"
        if [[ ! -e "$target" && ! -L "$target" ]]; then
            install -m 0644 "$source" "$target"
        fi
    done
}

configure_nginx() {
    local rewrite_template rewrite_name rewrite_file
    if [[ ! -e "${NGINX_SNIPPET_DIR}/enable-php.conf" ]]; then
        cat > "${NGINX_SNIPPET_DIR}/enable-php.conf" <<EOF
location ~ [^/]\.php(/|$)
{
    try_files \$uri =404;
    fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
    fastcgi_index index.php;
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
}
EOF
    fi
    if [[ ! -e "${NGINX_SNIPPET_DIR}/enable-php-pathinfo.conf" ]]; then
        cat > "${NGINX_SNIPPET_DIR}/enable-php-pathinfo.conf" <<EOF
location ~ [^/]\.php(/|$)
{
    fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
    fastcgi_index index.php;
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    include snippets/pathinfo.conf;
}
EOF
    fi
    if [[ ! -e "${NGINX_SNIPPET_DIR}/pathinfo.conf" ]]; then
        cat > "${NGINX_SNIPPET_DIR}/pathinfo.conf" <<'EOF'
if (!-e $request_filename) {
    rewrite ^(.*)$ /index.php$1 last;
}
EOF
    fi
    [[ -d "$SCRIPT_DIR/rewrite" ]] ||
        fail "Bundled Nginx rewrite templates are missing: ${SCRIPT_DIR}/rewrite"
    for rewrite_template in "$SCRIPT_DIR"/rewrite/*.conf; do
        [[ -f "$rewrite_template" ]] || continue
        rewrite_name="${rewrite_template##*/}"
        if [[ ! -e "${REWRITE_DIR}/${rewrite_name}" && ! -L "${REWRITE_DIR}/${rewrite_name}" ]]; then
            install -m 0644 "$rewrite_template" "${REWRITE_DIR}/${rewrite_name}"
        fi
    done
    for rewrite_file in none other; do
        if [[ ! -e "${REWRITE_DIR}/${rewrite_file}.conf" &&
              ! -L "${REWRITE_DIR}/${rewrite_file}.conf" ]]; then
            : > "${REWRITE_DIR}/${rewrite_file}.conf"
        fi
    done
    # Deploy reusable snippets (e.g. cache-static.conf) so vhosts can include
    # them from a server block with: include cache-static.conf;
    install_shared_nginx_conf "$SCRIPT_DIR/conf" "$NGINX_CONFIG_DIR"
    local nginx_conf
    nginx_conf="${NGINX_CONFIG_DIR}/nginx.conf"
    if [[ -f "$nginx_conf" ]]; then
        cp -n "$nginx_conf" "${nginx_conf}.lnmp-debian.orig"
        # The nginx.org package ships "user nginx;", while the PHP-FPM socket
        # is owned by www:www. Set the worker user to www so Nginx can use it.
        if grep -qE '^[[:space:]]*user[[:space:]]+' "$nginx_conf"; then
            sed -i -E 's/^[[:space:]]*user[[:space:]]+[^;]+;/user www;/' "$nginx_conf"
        else
            sed -i '1i user www;' "$nginx_conf"
        fi
        # Disable the http-level access log by default. Virtual hosts with an
        # explicit access_log directive can still opt in to logging.
        disable_nginx_access_log "$nginx_conf"
        # Load the top-level gzip.conf from within the http block.
        enable_nginx_gzip "$nginx_conf"
    fi

    # nginx.org packages load conf.d/*.conf; the default site lives there too.
    local nginx_default_config nginx_default_template nginx_default_temp
    nginx_default_config="${NGINX_CONFIG_DIR}/conf.d/default.conf"
    nginx_default_template="$SCRIPT_DIR/conf/default-site.conf"
    [[ -s "$nginx_default_template" ]] ||
        fail "Default Nginx site template is missing: ${nginx_default_template}"
    nginx_default_temp="$(mktemp "${nginx_default_config}.XXXXXX")"
    sed "s#@DEFAULT_WEB_ROOT@#${DEFAULT_WEB_ROOT}#g" \
        "$nginx_default_template" > "$nginx_default_temp"
    chmod 0644 "$nginx_default_temp"
    mv "$nginx_default_temp" "$nginx_default_config"
}

configure_php_fpm() {
    local pool_conf fpm_conf
    pool_conf="/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf"
    cp -n "$pool_conf" "${pool_conf}.lnmp-debian.orig"
    sed -i -E \
        -e 's/^[;[:space:]]*user[[:space:]]*=.*/user = www/' \
        -e 's/^[;[:space:]]*group[[:space:]]*=.*/group = www/' \
        -e "s#^[;[:space:]]*listen[[:space:]]*=.*#listen = /run/php/php${PHP_VERSION}-fpm.sock#" \
        -e 's/^[;[:space:]]*listen.owner[[:space:]]*=.*/listen.owner = www/' \
        -e 's/^[;[:space:]]*listen.group[[:space:]]*=.*/listen.group = www/' \
        -e 's/^[;[:space:]]*listen.mode[[:space:]]*=.*/listen.mode = 0660/' \
        -e 's/^[[:space:]]*listen\.acl_(users|groups)[[:space:]]*=.*/; &/' \
        "$pool_conf"
    grep -qE '^[[:space:]]*user[[:space:]]*=' "$pool_conf" ||
        printf '\nuser = www\n' >> "$pool_conf"
    grep -qE '^[[:space:]]*group[[:space:]]*=' "$pool_conf" ||
        printf 'group = www\n' >> "$pool_conf"
    grep -qE '^[[:space:]]*listen[[:space:]]*=' "$pool_conf" ||
        printf 'listen = /run/php/php%s-fpm.sock\n' "$PHP_VERSION" >> "$pool_conf"
    grep -qE '^[[:space:]]*listen\.owner[[:space:]]*=' "$pool_conf" ||
        printf 'listen.owner = www\n' >> "$pool_conf"
    grep -qE '^[[:space:]]*listen\.group[[:space:]]*=' "$pool_conf" ||
        printf 'listen.group = www\n' >> "$pool_conf"
    grep -qE '^[[:space:]]*listen\.mode[[:space:]]*=' "$pool_conf" ||
        printf 'listen.mode = 0660\n' >> "$pool_conf"
    grep -qE '^[[:space:]]*listen\.acl_(users|groups)[[:space:]]*=' "$pool_conf" &&
        fail "Could not disable PHP-FPM socket ACL settings in ${pool_conf}."
    fpm_conf="/etc/php/${PHP_VERSION}/fpm/php-fpm.conf"
    if grep -qE '^[;[:space:]]*pid[[:space:]]*=' "$fpm_conf"; then
        sed -i -E 's#^[;[:space:]]*pid[[:space:]]*=.*#pid = /run/php/php-fpm.pid#' "$fpm_conf"
    else
        printf '\npid = /run/php/php-fpm.pid\n' >> "$fpm_conf"
    fi
}

install_management_commands() {
    if [[ -e /usr/local/bin/lnmp && ! -L /usr/local/bin/lnmp ]]; then
        cp -n /usr/local/bin/lnmp /usr/local/bin/lnmp.lnmp-debian.orig
    elif [[ -L /usr/local/bin/lnmp ]] &&
          [[ "$(readlink -f /usr/local/bin/lnmp)" != "$(readlink -f "$SCRIPT_DIR/lnmp")" ]]; then
        cp -n /usr/local/bin/lnmp /usr/local/bin/lnmp.lnmp-debian.orig
    fi
    install -m 0755 "$SCRIPT_DIR/lnmp" /usr/local/bin/lnmp
    install -m 0755 "$SCRIPT_DIR/addons.sh" /usr/local/bin/addons.sh
    if [[ -e /usr/bin/lnmp && ! -L /usr/bin/lnmp ]]; then
        cp -n /usr/bin/lnmp /usr/bin/lnmp.lnmp-debian.orig
    elif [[ -L /usr/bin/lnmp ]] &&
          [[ "$(readlink -f /usr/bin/lnmp)" != "$(readlink -f /usr/local/bin/lnmp)" ]]; then
        cp -n /usr/bin/lnmp /usr/bin/lnmp.lnmp-debian.orig
    fi
    ln -sfn /usr/local/bin/lnmp /usr/bin/lnmp
}

start_and_verify_services() {
    local php_fpm_socket php_fpm_socket_owner
    /usr/sbin/nginx -t
    systemctl daemon-reload
    systemctl enable --now nginx "$PHP_FPM_SERVICE" mysql
    systemctl restart "$PHP_FPM_SERVICE" ||
        fail "Could not restart PHP-FPM after applying its pool configuration."
    systemctl reload nginx || fail "Could not reload Nginx after applying the LNMP configuration."
    systemctl is-active --quiet nginx || fail "Nginx did not start."
    systemctl is-active --quiet "$PHP_FPM_SERVICE" || fail "PHP-FPM did not start."
    php_fpm_socket="/run/php/php${PHP_VERSION}-fpm.sock"
    [[ -S "$php_fpm_socket" ]] ||
        fail "PHP-FPM is active but did not create its configured socket: ${php_fpm_socket}"
    php_fpm_socket_owner="$(stat -c '%U:%G' "$php_fpm_socket")"
    [[ "$php_fpm_socket_owner" == www:www ]] ||
        fail "PHP-FPM socket is owned by ${php_fpm_socket_owner}; expected www:www so Nginx can connect."
    systemctl is-active --quiet mysql || fail "MySQL did not start."
}

print_summary() {
    printf '\nLNMP Debian installation completed.\n'
    printf 'Nginx config: /etc/nginx/nginx.conf\n'
    printf 'PHP config:   /etc/php/%s/fpm/php.ini\n' "$PHP_VERSION"
    printf 'Nginx version: %s\nPHP version:   %s\nMySQL version: %s\n' "$NGINX_VERSION" "$PHP_VERSION" "$MYSQL_VERSION"
    printf 'Default web:  %s\nMySQL data:   %s\n' "$DEFAULT_WEB_ROOT" "$MYSQL_DATA_DIR"
    printf 'Certificates: /etc/nginx/ssl/\n'
    printf 'Management:   lnmp {start|stop|reload|restart|status|vhost|ssl|dnsssl}\n'
}

main() {
    parse_arguments "$@"
    validate_platform
    validate_configuration_and_existing_data
    prepare_package_sources
    select_install_versions
    confirm_install_versions
    install_packages
    clear_mysql_data_if_confirmed
    configure_mysql_data_directory
    ensure_web_user
    prepare_nginx_layout
    configure_nginx
    configure_php_fpm
    install_management_commands
    start_and_verify_services
    print_summary
}

main "$@"
