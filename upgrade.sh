#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
NGINX_KEY_URL=https://nginx.org/keys/nginx_signing.key
NGINX_KEYRING=/usr/share/keyrings/nginx-archive-keyring.gpg
NGINX_SOURCE=/etc/apt/sources.list.d/nginx.list
NGINX_PIN=/etc/apt/preferences.d/99nginx
PHP_REPO_URL=https://packages.sury.org/php
PHP_SOURCE=/etc/apt/sources.list.d/php.list
PHP_KEYRING=/usr/share/keyrings/debsuryorg-archive-keyring.gpg
PHP_PIN=/etc/apt/preferences.d/99sury-php
PHP_VERSION_STATE=/etc/lnmp-debian/php-version
PHP_UPSTREAM_MARKER=/etc/lnmp-debian/php-upstream-service
PHP_UPSTREAM_PREFIX_STATE=/etc/lnmp-debian/php-upstream-prefix
USE_SOURCE=0
AUTO_CONFIRM=0

usage() {
    cat <<'EOF'
Usage:
  upgrade.sh [--yes] [nginx [version] [stable|mainline]]
  upgrade.sh [--yes] php [--source] [version]
  upgrade.sh [--yes] mysql [version]

With no component, an interactive menu is shown. Nginx/MySQL versions may be
specified as upstream versions or full APT versions. PHP accepts a major.minor
branch (for example 8.5), a full patch version (8.5.13), or a full APT version.

Nginx versions come from nginx.org; MySQL versions come from Oracle's APT
repository configured by install.sh. PHP upgrades use the sury APT repository
and can cross major.minor branches. The legacy php.net source-build path is
still available with --source but only upgrades within the installed branch.

This script does not back up data or configuration; back up before upgrading.
Interactive upgrades require typing "yes" to accept the risk.

--yes skips that confirmation. An explicit version is required with
--yes or when there is no interactive terminal. Non-interactive upgrades
therefore require both an explicit version and --yes.
EOF
}

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

require_root() {
    [[ "$(id -u)" -eq 0 ]] || fail "Run this command as root (for example: sudo ./upgrade.sh)."
}

require_debian() {
    local major
    [[ -r /etc/os-release ]] || fail "This script requires Debian."
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == debian ]] || fail "Only Debian is supported."
    major="${VERSION_ID%%.*}"
    [[ "$major" =~ ^[0-9]+$ ]] && ((major >= 13)) ||
        fail "This script requires Debian 13 or later."
    [[ "${VERSION_CODENAME:-}" == trixie ]] ||
        fail "The nginx.org APT repository currently supports Debian trixie for this LNMP profile."
}

list_package_versions() {
    local package=$1 origin=${2:-}
    apt-cache madison "$1" |
        awk -F'|' -v origin="$origin" '
            {
                repository = tolower($3)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
                if ($2 != "" && (origin == "" || index(repository, tolower(origin)))) {
                    print $2
                }
            }' |
        sort -Vu
}

version_matches() {
    local available=$1 requested=$2 normalized
    [[ "$available" == "$requested" ]] && return 0
    normalized="${available#*:}"
    [[ "$normalized" == "$requested"-* ||
       "$normalized" == "$requested"~* ||
       "$normalized" == "$requested"+* ]]
}

resolve_package_version() {
    local package=$1 requested=$2 minimum_major=${3:-0} origin=${4:-}
    local version normalized major selected=
    local -a versions matches

    mapfile -t versions < <(list_package_versions "$package" "$origin")
    matches=()
    for version in "${versions[@]}"; do
        normalized="${version#*:}"
        major="${normalized%%.*}"
        [[ "$major" =~ ^[0-9]+$ ]] || continue
        (( major >= minimum_major )) || continue
        if [[ -z "$requested" ]] || version_matches "$version" "$requested"; then
            matches+=("$version")
        fi
    done
    ((${#matches[@]} > 0)) ||
        fail "No matching APT version for ${package}${requested:+ (${requested})} from ${origin:-configured repositories}. Available versions: ${versions[*]:-none}"

    if [[ -z "$requested" ]]; then
        selected="${matches[${#matches[@]}-1]}"
        if [[ -t 0 ]]; then
            printf 'Available versions for %s:\n' "$package" >&2
            printf '  %s\n' "${matches[@]}" >&2
            read -r -p "Version to install [${selected}]: " requested
            if [[ -n "$requested" ]]; then
                resolve_package_version "$package" "$requested" "$minimum_major" "$origin"
                return
            fi
        fi
        printf '%s' "$selected"
        return
    fi

    ((${#matches[@]} == 1)) ||
        fail "Version ${requested} is ambiguous for ${package}; use one of: ${matches[*]}"
    printf '%s' "${matches[0]}"
}

confirm_risk() {
    local component=$1 answer
    if ((AUTO_CONFIRM)); then
        return
    fi
    [[ -t 0 ]] || fail "Refusing to upgrade without an interactive confirmation (or pass --yes)."
    printf '\n================================================================\n' >&2
    printf 'WARNING: %s upgrade will modify this system.\n' "$component" >&2
    printf 'This script does NOT create backups. Back up your data and\n' >&2
    printf 'configuration yourself before proceeding.\n' >&2
    printf '\nTo accept the risk, type exactly:\n' >&2
    printf '\n            >>>  yes  <<<\n\n' >&2
    printf '================================================================\n' >&2
    read -r -p "Type yes to continue (anything else cancels): " answer
    [[ "$answer" == yes ]] || fail "Upgrade cancelled."
}

print_apt_plan() {
    local component=$1
    shift
    printf '\nAPT plan for %s:\n' "$component"
    apt-get -s install "$@"
}

print_source_plan() {
    local component=$1 version=$2 prefix=$3
    printf '\nUpstream source upgrade plan:\n  Component: %s\n  Version: %s\n  Prefix: %s\n' \
        "$component" "$version" "$prefix"
}

run_apt_install() {
    DEBIAN_FRONTEND=readline apt-get install -y \
        -o Dpkg::Options::=--force-confold "$@"
}

configure_nginx_repository() {
    local channel=$1 codename key_tmp keyring_tmp source_tmp pin_tmp fingerprint channel_url
    codename="${VERSION_CODENAME:-}"
    case "$channel" in
        stable) channel_url=https://nginx.org/packages/debian ;;
        mainline) channel_url=https://nginx.org/packages/mainline/debian ;;
        *) fail "Nginx channel must be stable or mainline." ;;
    esac
    if [[ -e "$NGINX_SOURCE" ]] &&
       ! grep -Fq 'https://nginx.org/packages/' "$NGINX_SOURCE"; then
        fail "Refusing to overwrite an unrelated APT source: $NGINX_SOURCE"
    fi
    if [[ -e "$NGINX_PIN" ]] &&
       ! grep -Fq 'Pin: origin nginx.org' "$NGINX_PIN"; then
        fail "Refusing to overwrite an unrelated APT preference: $NGINX_PIN"
    fi

    apt-get update
    apt-get install -y curl gnupg2 ca-certificates lsb-release debian-archive-keyring
    key_tmp="$(mktemp)"
    keyring_tmp="$(mktemp)"
    source_tmp="$(mktemp "${NGINX_SOURCE}.XXXXXX")"
    pin_tmp="$(mktemp "${NGINX_PIN}.XXXXXX")"
    trap 'rm -f "$key_tmp" "$keyring_tmp" "$source_tmp" "$pin_tmp"' RETURN

    curl --fail --silent --show-error --location "$NGINX_KEY_URL" -o "$key_tmp"
    fingerprint="$(gpg --show-keys --with-colons "$key_tmp" |
        awk -F: '$1 == "fpr" { print $10 }' |
        grep -Fx '573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62' || true)"
    [[ -n "$fingerprint" ]] || fail "Unexpected nginx.org signing key fingerprint."
    gpg --dearmor --yes --output "$keyring_tmp" "$key_tmp"
    install -m 0644 "$keyring_tmp" "$NGINX_KEYRING"

    printf 'deb [signed-by=%s] %s %s nginx\n' \
        "$NGINX_KEYRING" "$channel_url" "$codename" > "$source_tmp"
    printf 'Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n' \
        > "$pin_tmp"
    install -m 0644 "$source_tmp" "$NGINX_SOURCE"
    install -m 0644 "$pin_tmp" "$NGINX_PIN"
    rm -f "$key_tmp" "$keyring_tmp" "$source_tmp" "$pin_tmp"
    trap - RETURN
    apt-get update
}

upgrade_nginx() {
    local requested=$1 channel=$2 version current_version target_release
    [[ -x /usr/sbin/nginx ]] || fail "Nginx is not installed at /usr/sbin/nginx."
    confirm_risk "Nginx"
    printf 'Current Nginx version and build options:\n'
    /usr/sbin/nginx -V
    /usr/sbin/nginx -t

    configure_nginx_repository "$channel"
    version="$(resolve_package_version nginx "$requested" 0 nginx.org)"
    current_version="$(/usr/sbin/nginx -v 2>&1 | sed -E 's#.*nginx/([^ ]+).*#\1#')"
    target_release="${version#*:}"
    target_release="${target_release%%-*}"
    dpkg --compare-versions "$target_release" gt "$current_version" ||
        fail "Requested Nginx version ${target_release} is not newer than the installed ${current_version}."
    print_apt_plan nginx "nginx=${version}"
    run_apt_install "nginx=${version}"

    systemctl daemon-reload
    /usr/sbin/nginx -t
    systemctl restart nginx
    systemctl is-active --quiet nginx || fail "Nginx is not active after the upgrade."
    /usr/sbin/nginx -v
    printf 'Nginx upgraded to APT version %s.\n' "$version"
}

install_php_management_updates() {
    [[ -x "${SCRIPT_DIR}/sync-lnmp.sh" ]] ||
        fail "Management sync script not found: ${SCRIPT_DIR}/sync-lnmp.sh"
    [[ -f "${SCRIPT_DIR}/addons.sh" ]] ||
        fail "PHP addon manager not found: ${SCRIPT_DIR}/addons.sh"
    [[ ! -L /usr/local/bin/addons.sh ]] ||
        fail "Refusing to replace symlinked addon manager: /usr/local/bin/addons.sh"
    "${SCRIPT_DIR}/sync-lnmp.sh"
    if [[ -e /usr/local/bin/addons.sh && ! -e /usr/local/bin/addons.sh.lnmp-upgrade.orig ]]; then
        cp -p /usr/local/bin/addons.sh /usr/local/bin/addons.sh.lnmp-upgrade.orig
    fi
    install -m 0755 "${SCRIPT_DIR}/addons.sh" /usr/local/bin/addons.sh
}

configure_php_repository() {
    local codename architecture key_tmp source_tmp pin_tmp fingerprint

    codename="${VERSION_CODENAME:-}"
    architecture="$(dpkg --print-architecture)"
    [[ "$architecture" == amd64 || "$architecture" == arm64 || "$architecture" == armhf ]] ||
        fail "The sury PHP repository does not support this architecture: $architecture"
    [[ -n "$codename" ]] || fail "Could not determine Debian release codename."

    if [[ -e "$PHP_SOURCE" ]] &&
       ! grep -Fq 'packages.sury.org/php' "$PHP_SOURCE"; then
        fail "Refusing to overwrite an unrelated APT source: $PHP_SOURCE"
    fi
    if [[ -e "$PHP_PIN" ]] &&
       ! grep -Fq 'Pin: origin packages.sury.org' "$PHP_PIN"; then
        fail "Refusing to overwrite an unrelated APT preference: $PHP_PIN"
    fi

    apt-get update
    apt-get install -y curl gnupg ca-certificates
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
    install -d -m 0755 /usr/share/keyrings "$(dirname "$PHP_SOURCE")" "$(dirname "$PHP_PIN")"
    install -m 0644 "$key_tmp" "$PHP_KEYRING"

    printf 'deb [signed-by=%s] %s/ %s main\n' \
        "$PHP_KEYRING" "$PHP_REPO_URL" "$codename" > "$source_tmp"
    # sury and Debian ship identically named php8.x-* packages. Pin sury above
    # the Debian default but below 1000 so apt never downgrades.
    printf 'Package: *\nPin: origin packages.sury.org\nPin-Priority: 900\n' > "$pin_tmp"
    chmod 0644 "$source_tmp" "$pin_tmp"
    install -m 0644 "$source_tmp" "$PHP_SOURCE"
    install -m 0644 "$pin_tmp" "$PHP_PIN"
    rm -f "$key_tmp" "$source_tmp" "$pin_tmp"
    trap - RETURN
    apt-get update
    printf 'sury PHP APT repository configured.\n'
}

resolve_php_upgrade_version() {
    local requested=$1 choice branch candidate normalized index existing marker
    local -a branches versions matches

    mapfile -t branches < <(
        apt-cache pkgnames |
            grep -E '^php[0-9]+\.[0-9]+-fpm$' |
            sed -E 's/^php([0-9]+\.[0-9]+)-fpm$/\1/' |
            sort -Vu
    )
    ((${#branches[@]} > 0)) || fail "No PHP FPM packages are available from sury."

    if [[ -z "$requested" ]]; then
        printf '\nAvailable PHP branches from sury:\n' >&2
        for index in "${!branches[@]}"; do
            marker=
            [[ "$index" -eq $((${#branches[@]} - 1)) ]] && marker=' [default]'
            printf '  %d) %s%s\n' "$((index + 1))" "${branches[index]}" "$marker" >&2
        done
        read -r -p "Select branch [${branches[${#branches[@]} - 1]}]: " choice
        if [[ -z "$choice" ]]; then
            branch="${branches[${#branches[@]} - 1]}"
        elif [[ "$choice" =~ ^[0-9]+$ ]] &&
             (( choice >= 1 && choice <= ${#branches[@]} )); then
            branch="${branches[choice - 1]}"
        elif [[ " ${branches[*]} " == *" ${choice} "* ]]; then
            branch=$choice
        else
            fail "Invalid PHP branch selection: $choice"
        fi
    else
        [[ "$requested" =~ ^([0-9]+\.[0-9]+)(\.[0-9]+)?([-+~].*)?$ ]] ||
            fail "Invalid PHP version: ${requested}. Use a branch (8.5), a patch version (8.5.13), or a full APT version."
        branch="${BASH_REMATCH[1]}"
    fi

    local found=0
    for existing in "${branches[@]}"; do
        [[ "$existing" == "$branch" ]] && { found=1; break; }
    done
    (( found )) ||
        fail "PHP ${branch} is not available from sury. Available branches: ${branches[*]}"
    PHP_UPGRADE_BRANCH="$branch"

    mapfile -t versions < <(list_package_versions "php${branch}-fpm" packages.sury.org)
    ((${#versions[@]} > 0)) || fail "No sury APT versions for php${branch}-fpm."
    if [[ -z "$requested" || "$requested" == "$branch" ]]; then
        SELECTED_PHP_VERSION="${versions[${#versions[@]} - 1]}"
    else
        matches=()
        for candidate in "${versions[@]}"; do
            version_matches "$candidate" "$requested" && matches+=("$candidate")
        done
        ((${#matches[@]} > 0)) ||
            fail "No sury version matches ${requested}. Available: ${versions[*]}"
        ((${#matches[@]} == 1)) ||
            fail "Version ${requested} is ambiguous for php${branch}-fpm; use one of: ${matches[*]}"
        SELECTED_PHP_VERSION="${matches[0]}"
    fi
}

apply_php_fpm_pool_config() {
    local branch=$1 pool_conf fpm_conf
    pool_conf="/etc/php/${branch}/fpm/pool.d/www.conf"
    [[ -s "$pool_conf" ]] || fail "PHP-FPM pool configuration not found: $pool_conf"
    sed -i -E \
        -e 's/^[;[:space:]]*user[[:space:]]*=.*/user = www/' \
        -e 's/^[;[:space:]]*group[[:space:]]*=.*/group = www/' \
        -e "s#^[;[:space:]]*listen[[:space:]]*=.*#listen = /run/php/php${branch}-fpm.sock#" \
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
        printf 'listen = /run/php/php%s-fpm.sock\n' "$branch" >> "$pool_conf"
    grep -qE '^[[:space:]]*listen\.owner[[:space:]]*=' "$pool_conf" ||
        printf 'listen.owner = www\n' >> "$pool_conf"
    grep -qE '^[[:space:]]*listen\.group[[:space:]]*=' "$pool_conf" ||
        printf 'listen.group = www\n' >> "$pool_conf"
    grep -qE '^[[:space:]]*listen\.mode[[:space:]]*=' "$pool_conf" ||
        printf 'listen.mode = 0660\n' >> "$pool_conf"
    grep -qE '^[[:space:]]*listen\.acl_(users|groups)[[:space:]]*=' "$pool_conf" &&
        fail "Could not disable PHP-FPM socket ACL settings in ${pool_conf}."
    fpm_conf="/etc/php/${branch}/fpm/php-fpm.conf"
    if grep -qE '^[;[:space:]]*pid[[:space:]]*=' "$fpm_conf"; then
        sed -i -E 's#^[;[:space:]]*pid[[:space:]]*=.*#pid = /run/php/php-fpm.pid#' "$fpm_conf"
    else
        printf '\npid = /run/php/php-fpm.pid\n' >> "$fpm_conf"
    fi
}

upgrade_php_source() {
    local requested=$1 php_version php_branch current_version prefix build_root archive
    local extension_dir php_api php_ini marker_file service_file service_tmp socket socket_owner
    local old_service_tmp previous_prefix previous_service
    local old_service_was_active=0 old_service_was_enabled=0
    local make_jobs package
    confirm_risk "PHP (php.net source build)"
    if [[ -z "$requested" && -t 0 ]]; then
        read -r -p "PHP version from php.net (example: 8.4.17): " requested
    fi
    if [[ -r /etc/lnmp-debian/php-version ]]; then
        IFS= read -r php_version < /etc/lnmp-debian/php-version || true
    else
        php_version="$(php -r 'echo PHP_MAJOR_VERSION, ".", PHP_MINOR_VERSION;' 2>/dev/null || true)"
    fi
    [[ "$php_version" =~ ^8\.[0-9]+$ ]] ||
        fail "Could not determine a supported installed PHP 8.x-FPM version."
    [[ -d "/etc/php/${php_version}/fpm" ]] ||
        fail "PHP-FPM ${php_version} is not installed."
    [[ "$requested" =~ ^8\.[0-9]+\.[0-9]+$ ]] ||
        fail "Enter a full PHP version from php.net, such as 8.4.17."
    php_branch="${requested%.*}"
    [[ "$php_branch" == "$php_version" ]] ||
        fail "Source upgrades must stay on the installed PHP ${php_version} branch to preserve extension ABI compatibility."

    prefix="/usr/local/php-upstream-${requested}"
    [[ ! -e "$prefix" ]] || fail "PHP source prefix already exists: $prefix"
    build_root="/usr/local/src/lnmp-php-${requested}"
    [[ ! -e "$build_root" ]] || fail "PHP build directory already exists: $build_root"
    php_ini="/etc/php/${php_version}/fpm/php.ini"
    [[ -s "$php_ini" ]] || fail "PHP-FPM configuration file not found: $php_ini"
    marker_file=/etc/lnmp-debian/php-upstream-service
    previous_prefix=
    previous_service=
    if [[ -r "$marker_file" ]]; then
        IFS= read -r previous_service < "$marker_file" || true
        [[ "$previous_service" == lnmp-php-upstream ]] ||
            fail "Unknown PHP upstream service marker: $previous_service"
        if [[ -r /etc/lnmp-debian/php-upstream-prefix ]]; then
            IFS= read -r previous_prefix < /etc/lnmp-debian/php-upstream-prefix || true
        fi
        [[ -n "$previous_prefix" && -x "${previous_prefix}/bin/php" ]] ||
            fail "Previous upstream PHP binary is missing; refusing to replace the active runtime."
        current_version="$("${previous_prefix}/bin/php" -r 'echo PHP_VERSION;' 2>/dev/null || true)"
    else
        current_version="$(/usr/bin/php"${php_version}" -r 'echo PHP_VERSION;' 2>/dev/null || true)"
    fi
    [[ "$current_version" =~ ^8\.[0-9]+\.[0-9]+$ ]] ||
        fail "Could not determine the current PHP version."
    dpkg --compare-versions "$requested" gt "$current_version" ||
        fail "Requested PHP version ${requested} is not newer than the installed ${current_version}."
    print_source_plan "PHP source" "$requested" "$prefix"
    apt-get update
    apt-get install -y curl build-essential autoconf bison re2c pkg-config \
        libxml2-dev libsqlite3-dev libcurl4-openssl-dev libssl-dev libonig-dev \
        libzip-dev libicu-dev libjpeg-dev libpng-dev libwebp-dev libfreetype-dev \
        libreadline-dev libbz2-dev libxslt1-dev
    extension_dir="$(/usr/bin/php"${php_version}" -i |
        sed -n 's/^extension_dir => \([^ ]*\).*/\1/p' | head -n 1)"
    [[ "$extension_dir" == /usr/lib/php/* && -d "$extension_dir" ]] ||
        fail "Could not determine the Debian PHP extension directory."

    install -d -m 0755 /usr/local/src
    mkdir -m 0755 "$build_root"
    archive="${build_root}/php-${requested}.tar.gz"
    curl --fail --silent --show-error --location \
        "https://www.php.net/distributions/php-${requested}.tar.gz" -o "$archive"
    tar -xzf "$archive" -C "$build_root"
    cd "${build_root}/php-${requested}"
    ./configure \
        "--prefix=${prefix}" \
        "--with-config-file-path=/etc/php/${php_version}/fpm" \
        "--with-config-file-scan-dir=/etc/php/${php_version}/fpm/conf.d" \
        --enable-fpm --with-fpm-user=www --with-fpm-group=www \
        --enable-mysqlnd --with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd \
        --with-curl --with-openssl --with-zlib --enable-xml --enable-bcmath \
        --enable-mbstring --enable-intl --enable-opcache --with-zip \
        --with-gd --with-jpeg --with-freetype --with-webp --with-bz2 \
        --with-xsl --with-readline
    make_jobs="$(getconf _NPROCESSORS_ONLN)"
    make -j "$make_jobs"
    make install

    php_api="$("${prefix}/bin/php-config" --phpapi)"
    [[ "$php_api" =~ ^[0-9]+$ ]] ||
        fail "Could not determine the upstream PHP extension API."
    [[ "${extension_dir##*/}" == "$php_api" ]] ||
        fail "Upstream PHP extension API ${php_api} does not match the installed Debian extension directory ${extension_dir}; refusing to switch runtimes."
    install -d -m 0755 "/etc/php/${php_version}/fpm/conf.d"
    cat > "/etc/php/${php_version}/fpm/conf.d/00-lnmp-upstream-extension-dir.ini" <<EOF
extension_dir = ${extension_dir}
EOF
    for package in mysqli pdo_mysql curl gd mbstring intl zip bcmath; do
        "${prefix}/bin/php" -c "$php_ini" -m | grep -Eiq "^${package}$" ||
            fail "The PHP source build is missing the required ${package} module."
    done
    "${prefix}/bin/php" -c "$php_ini" -m | grep -Eiq '^xml$' ||
        fail "The PHP source build is missing the required xml module."
    "${prefix}/bin/php" -c "$php_ini" -m | grep -Eiq 'opcache' ||
        fail "The PHP source build is missing the required opcache module."
    "${prefix}/sbin/php-fpm" -t -y "/etc/php/${php_version}/fpm/php-fpm.conf"

    service_file=/etc/systemd/system/lnmp-php-upstream.service
    old_service_was_active=0
    if [[ -r "$marker_file" ]]; then
        IFS= read -r previous_service < "$marker_file" || true
        [[ "$previous_service" == lnmp-php-upstream ]] ||
            fail "Unknown PHP upstream service marker: $previous_service"
        [[ -s "$service_file" ]] || fail "PHP upstream systemd unit is missing: $service_file"
        if [[ -r /etc/lnmp-debian/php-upstream-prefix ]]; then
            IFS= read -r previous_prefix < /etc/lnmp-debian/php-upstream-prefix || true
        fi
        [[ -n "$previous_prefix" && -x "${previous_prefix}/sbin/php-fpm" ]] ||
            fail "Previous upstream PHP-FPM binary is missing; refusing to replace the active runtime."
        systemctl is-active --quiet "$previous_service" && old_service_was_active=1
        systemctl is-enabled --quiet "$previous_service" && old_service_was_enabled=1
    else
        systemctl is-active --quiet "php${php_version}-fpm" && old_service_was_active=1
        systemctl is-enabled --quiet "php${php_version}-fpm" && old_service_was_enabled=1
    fi
    service_tmp="$(mktemp "${service_file}.XXXXXX")"
    old_service_tmp="$(mktemp)"
    if [[ -n "$previous_service" ]]; then
        cp "$service_file" "$old_service_tmp"
    fi

    cat > "$service_tmp" <<EOF
[Unit]
Description=LNMP upstream PHP-FPM
After=network.target

[Service]
Type=simple
ExecStart=${prefix}/sbin/php-fpm --nodaemonize --fpm-config /etc/php/${php_version}/fpm/php-fpm.conf
ExecReload=/bin/kill -USR2 \$MAINPID
ExecStop=/bin/kill -QUIT \$MAINPID
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    install_php_management_updates
    install -m 0644 "$service_tmp" "$service_file"
    rm -f "$service_tmp"
    install -d -m 0755 /etc/lnmp-debian
    printf '%s\n' lnmp-php-upstream > "$marker_file"
    printf '%s\n' "$prefix" > /etc/lnmp-debian/php-upstream-prefix
    systemctl daemon-reload

    if [[ "$old_service_was_active" -eq 1 ]]; then
        if ! systemctl stop "${previous_service:-php${php_version}-fpm}"; then
            if [[ -n "$previous_service" ]]; then
                install -m 0644 "$old_service_tmp" "$service_file"
            else
                rm -f "$service_file"
            fi
            if [[ -n "$previous_service" ]]; then
                printf '%s\n' "$previous_service" > "$marker_file"
                printf '%s\n' "$previous_prefix" > /etc/lnmp-debian/php-upstream-prefix
            else
                rm -f "$marker_file" /etc/lnmp-debian/php-upstream-prefix
            fi
            systemctl daemon-reload
            systemctl start "${previous_service:-php${php_version}-fpm}" ||
                fail "Could not stop the old PHP-FPM service or restore it after failure."
            rm -f "$old_service_tmp"
            fail "Could not stop the current PHP-FPM service; the previous runtime was restored."
        fi
    fi
    if [[ -z "$previous_service" ]]; then
        systemctl disable "php${php_version}-fpm" || {
            rm -f "$marker_file" /etc/lnmp-debian/php-upstream-prefix "$service_file"
            systemctl daemon-reload
            if [[ "$old_service_was_enabled" -eq 1 ]]; then
                systemctl enable "php${php_version}-fpm"
            fi
            if [[ "$old_service_was_active" -eq 1 ]]; then
                systemctl start "php${php_version}-fpm"
            fi
            rm -f "$old_service_tmp"
            fail "Could not disable the Debian PHP-FPM service."
        }
    fi
    if ! systemctl enable --now lnmp-php-upstream.service; then
        if ! systemctl disable --now lnmp-php-upstream.service; then
            printf 'Warning: failed to stop the new PHP-FPM service during rollback.\n' >&2
        fi
        if [[ -n "$previous_service" ]]; then
            install -m 0644 "$old_service_tmp" "$service_file"
            printf '%s\n' "$previous_service" > "$marker_file"
            printf '%s\n' "$previous_prefix" > /etc/lnmp-debian/php-upstream-prefix
            if [[ "$old_service_was_enabled" -eq 1 ]]; then
                systemctl enable "$previous_service"
            else
                systemctl disable "$previous_service"
            fi
        else
            rm -f "$marker_file" /etc/lnmp-debian/php-upstream-prefix "$service_file"
        fi
        systemctl daemon-reload
        if [[ "$old_service_was_active" -eq 1 ]]; then
            if [[ -n "$previous_service" ]]; then
                systemctl start "$previous_service" ||
                    fail "The old upstream PHP-FPM service could not be restarted."
            else
                systemctl enable --now "php${php_version}-fpm" ||
                    fail "The Debian PHP-FPM service could not be restored."
            fi
        elif [[ -z "$previous_service" && "$old_service_was_enabled" -eq 1 ]]; then
            systemctl enable "php${php_version}-fpm" ||
                fail "The Debian PHP-FPM service could not be re-enabled."
        fi
        rm -f "$old_service_tmp"
        fail "Upstream PHP-FPM failed to start; the previous PHP runtime was restored."
    fi
    rm -f "$old_service_tmp"
    systemctl is-active --quiet lnmp-php-upstream.service ||
        fail "Upstream PHP-FPM is not active after the upgrade."
    socket="/run/php/php${php_version}-fpm.sock"
    [[ -S "$socket" ]] ||
        fail "Upstream PHP-FPM is active but did not create ${socket}."
    socket_owner="$(stat -c '%U:%G' "$socket")"
    [[ "$socket_owner" == www:www ]] ||
        fail "Upstream PHP-FPM socket is owned by ${socket_owner}; expected www:www so Nginx can connect."
    "${prefix}/bin/php" -v
    printf 'PHP-FPM upgraded from php.net to %s at %s.\n' "$requested" "$prefix"
}

upgrade_php_sury() {
    local requested=$1 branch version target_full current_version current_full
    local old_service= old_prefix= service_backup=
    local old_service_active=0 old_service_enabled=0
    local nginx_snippet socket socket_owner

    confirm_risk "PHP (sury APT)"

    if [[ -r "$PHP_VERSION_STATE" ]]; then
        IFS= read -r current_version < "$PHP_VERSION_STATE" || true
    else
        current_version="$(php -r 'echo PHP_MAJOR_VERSION, ".", PHP_MINOR_VERSION;' 2>/dev/null || true)"
    fi
    [[ "$current_version" =~ ^[0-9]+\.[0-9]+$ ]] ||
        fail "Could not determine the installed PHP branch."
    [[ -d "/etc/php/${current_version}/fpm" ]] ||
        fail "PHP-FPM ${current_version} is not installed."

    configure_php_repository
    resolve_php_upgrade_version "$requested"
    branch="$PHP_UPGRADE_BRANCH"
    version="$SELECTED_PHP_VERSION"
    target_full="${version#*:}"
    target_full="${target_full%%[-+~]*}"

    old_service="php${current_version}-fpm"
    if [[ -r "$PHP_UPSTREAM_MARKER" ]]; then
        IFS= read -r old_service < "$PHP_UPSTREAM_MARKER" || true
        [[ "$old_service" == lnmp-php-upstream ]] ||
            fail "Unknown PHP upstream service marker: $old_service"
        if [[ -r "$PHP_UPSTREAM_PREFIX_STATE" ]]; then
            IFS= read -r old_prefix < "$PHP_UPSTREAM_PREFIX_STATE" || true
        fi
    fi
    systemctl is-active --quiet "$old_service" && old_service_active=1
    systemctl is-enabled --quiet "$old_service" && old_service_enabled=1

    current_full="$(dpkg-query -W -f='${Version}' "php${current_version}-fpm" 2>/dev/null || true)"
    current_full="${current_full#*:}"
    current_full="${current_full%%[-+~]*}"
    if [[ -z "$current_full" && -n "$old_prefix" && -x "${old_prefix}/bin/php" ]]; then
        current_full="$("${old_prefix}/bin/php" -r 'echo PHP_VERSION;' 2>/dev/null || true)"
    fi
    [[ "$current_full" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
        fail "Could not determine the current PHP version."
    dpkg --compare-versions "$target_full" gt "$current_full" ||
        fail "Requested PHP ${target_full} is not newer than the installed ${current_full}."

    local -a php_packages=(
        "php${branch}-cli"
        "php${branch}-mysql"
        "php${branch}-curl"
        "php${branch}-gd"
        "php${branch}-mbstring"
        "php${branch}-xml"
        "php${branch}-zip"
        "php${branch}-bcmath"
        "php${branch}-intl"
    )
    # OPcache is part of the PHP core from 8.5 onward; sury has no separate package.
    if ! dpkg --compare-versions "$branch" ge 8.5; then
        php_packages+=("php${branch}-opcache")
    fi

    printf '\nPHP upgrade plan:\n  From: PHP %s (%s)\n  To:   PHP %s (php%s-fpm=%s)\n' \
        "$current_full" "$old_service" "$target_full" "$branch" "$version"
    printf '  Packages: %s\n' "${php_packages[*]}"
    print_apt_plan "PHP ${branch}" "php${branch}-fpm=${version}" "${php_packages[@]}"

    if [[ "$old_service" == lnmp-php-upstream ]]; then
        service_backup="$(mktemp)"
        cp -p /etc/systemd/system/lnmp-php-upstream.service "$service_backup"
    fi

    run_apt_install "php${branch}-fpm=${version}" "${php_packages[@]}"
    apply_php_fpm_pool_config "$branch"

    if (( old_service_active )); then
        systemctl stop "$old_service" ||
            fail "Could not stop the previous PHP-FPM service; no runtime switch was made."
    fi
    systemctl disable "$old_service" || true

    printf '%s\n' "$branch" > "$PHP_VERSION_STATE"
    for nginx_snippet in /etc/nginx/snippets/enable-php.conf \
                         /etc/nginx/snippets/enable-php-pathinfo.conf; do
        [[ -f "$nginx_snippet" ]] || continue
        sed -i -E "s#/run/php/php[0-9]+\.[0-9]+-fpm\.sock#/run/php/php${branch}-fpm.sock#g" \
            "$nginx_snippet"
    done

    systemctl daemon-reload
    # The new package may have already started PHP-FPM with its stock pool
    # configuration. Restart explicitly so the socket is recreated with the
    # www:www ownership that Nginx expects.
    if ! systemctl enable "php${branch}-fpm" ||
       ! systemctl restart "php${branch}-fpm"; then
        printf '%s\n' "$current_version" > "$PHP_VERSION_STATE"
        for nginx_snippet in /etc/nginx/snippets/enable-php.conf \
                             /etc/nginx/snippets/enable-php-pathinfo.conf; do
            [[ -f "$nginx_snippet" ]] || continue
            sed -i -E "s#/run/php/php${branch}-fpm\.sock#/run/php/php${current_version}-fpm.sock#g" \
                "$nginx_snippet"
        done
        if [[ "$old_service" == lnmp-php-upstream ]]; then
            install -m 0644 "$service_backup" /etc/systemd/system/lnmp-php-upstream.service
            printf '%s\n' lnmp-php-upstream > "$PHP_UPSTREAM_MARKER"
            [[ -z "$old_prefix" ]] ||
                printf '%s\n' "$old_prefix" > "$PHP_UPSTREAM_PREFIX_STATE"
        fi
        systemctl daemon-reload
        if (( old_service_enabled )); then
            systemctl enable "$old_service" || true
        else
            systemctl disable "$old_service" || true
        fi
        if (( old_service_active )); then
            systemctl start "$old_service" || true
        fi
        rm -f "$service_backup"
        fail "PHP-FPM ${branch} failed to start; the previous PHP runtime was restored."
    fi

    if [[ "$old_service" == lnmp-php-upstream ]]; then
        rm -f /etc/systemd/system/lnmp-php-upstream.service \
              "$PHP_UPSTREAM_MARKER" "$PHP_UPSTREAM_PREFIX_STATE"
        rm -f "$service_backup"
    fi
    install_php_management_updates

    systemctl is-active --quiet "php${branch}-fpm" ||
        fail "PHP-FPM ${branch} is not active after the upgrade."
    socket="/run/php/php${branch}-fpm.sock"
    [[ -S "$socket" ]] ||
        fail "PHP-FPM ${branch} is active but did not create ${socket}."
    socket_owner="$(stat -c '%U:%G' "$socket")"
    [[ "$socket_owner" == www:www ]] ||
        fail "PHP-FPM socket is owned by ${socket_owner}; expected www:www so Nginx can connect."
    /usr/bin/php"${branch}" -v
    /usr/sbin/nginx -t
    systemctl reload nginx ||
        fail "Nginx could not be reloaded after the PHP upgrade."
    printf 'PHP upgraded to %s via sury (service php%s-fpm).\n' "$target_full" "$branch"
    printf 'Note: third-party extensions installed via addons.sh need to be reinstalled for PHP %s.\n' "$branch"
}

upgrade_php() {
    if (( USE_SOURCE )); then
        upgrade_php_source "$1"
    else
        upgrade_php_sury "$1"
    fi
}

upgrade_mysql() {
    local requested=$1 version current_version target_release
    [[ -x /usr/bin/mysql ]] || fail "MySQL client not found at /usr/bin/mysql."
    confirm_risk "MySQL"
    grep -Fq 'repo.mysql.com/apt/debian' /etc/apt/sources.list.d/mysql.list ||
        fail "Oracle MySQL APT repository is not configured; run install.sh first."
    [[ -r /usr/share/keyrings/mysql-apt.gpg ]] ||
        fail "Oracle MySQL APT keyring is missing; run install.sh first."
    systemctl is-active --quiet mysql || fail "MySQL must be active before upgrading."

    apt-get update
    version="$(resolve_package_version mysql-server "$requested" 8 repo.mysql.com)"
    current_version="$(dpkg-query -W -f='${Version}' mysql-server 2>/dev/null || true)"
    target_release="${version#*:}"
    dpkg --compare-versions "$target_release" gt "$current_version" ||
        fail "Requested MySQL package version ${version} is not newer than the installed ${current_version:-unknown}."
    print_apt_plan MySQL "mysql-server=${version}"
    run_apt_install "mysql-server=${version}"
    systemctl daemon-reload
    systemctl restart mysql
    systemctl is-active --quiet mysql || fail "MySQL is not active after the upgrade."
    /usr/bin/mysql --version
    printf 'MySQL upgraded to APT version %s.\n' "$version"
}

show_menu() {
    cat <<'EOF'
Select a component to upgrade:
  1: Nginx (official nginx.org APT repository)
  2: PHP (sury APT repository; use --source for php.net source build)
  3: MySQL (configured Oracle APT repository)
  4: Exit
EOF
    read -r -p "Selection: " choice
    case "$choice" in
        1) COMPONENT=nginx ;;
        2) COMPONENT=php ;;
        3) COMPONENT=mysql ;;
        4) exit 0 ;;
        *) fail "Invalid selection: $choice" ;;
    esac
}

[[ "${1:-}" != --help && "${1:-}" != -h ]] || {
    usage
    exit 0
}

if [[ "${1:-}" == --yes ]]; then
    AUTO_CONFIRM=1
    shift
fi

if (($# == 0)); then
    [[ -t 0 ]] || fail "No component specified and no interactive terminal; pass a component and an explicit version."
    show_menu
    requested=
    channel=stable
else
    COMPONENT=$1
    shift
    case "$COMPONENT" in
        nginx)
            requested="${1:-}"
            if (($# > 0)); then
                shift
            fi
            channel="${1:-stable}"
            if (($# > 0)); then
                shift
            fi
            (($# == 0)) || { usage >&2; exit 2; }
            ;;
        php)
            if [[ "${1:-}" == --source ]]; then
                USE_SOURCE=1
                shift
            fi
            requested="${1:-}"
            if (($# > 0)); then
                shift
            fi
            (($# == 0)) || { usage >&2; exit 2; }
            channel=stable
            ;;
        mysql)
            requested="${1:-}"
            if (($# > 0)); then
                shift
            fi
            (($# == 0)) || { usage >&2; exit 2; }
            channel=stable
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
fi

if [[ -z "$requested" ]] && { ((AUTO_CONFIRM)) || [[ ! -t 0 ]]; }; then
    fail "A version must be specified explicitly when --yes is used or when there is no interactive terminal."
fi
if [[ ! -t 0 ]] && ! ((AUTO_CONFIRM)); then
    fail "Non-interactive upgrades require --yes; otherwise the script would change package sources before refusing to install."
fi

require_root
require_debian

case "$COMPONENT" in
    nginx) upgrade_nginx "$requested" "$channel" ;;
    php) upgrade_php "$requested" ;;
    mysql) upgrade_mysql "$requested" ;;
    *) usage >&2; exit 2 ;;
esac
