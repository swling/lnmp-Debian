#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MYSQL_KEYRING=/usr/share/keyrings/mysql-apt.gpg
MYSQL_SOURCE=/etc/apt/sources.list.d/mysql.list
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
NGINX_LOG_DIR="${NGINX_LOG_DIR:-/home/wwwlogs}"
MYSQL_DATA_DIR="${MYSQL_DATA_DIR:-/var/lib/mysql}"
PHP_VERSION="${PHP_VERSION:-}"
NGINX_VERSION="${NGINX_VERSION:-}"
MYSQL_VERSION="${MYSQL_VERSION:-}"
REWRITE_DIR=/usr/local/nginx/conf/rewrite

usage() {
    cat <<'EOF'
Usage: install.sh

Install the LNMP Debian profile on Debian 13 or later:
  Nginx and PHP: Debian APT repositories
  MySQL: Oracle MySQL 8.4 LTS APT repository
  ACME client: Debian APT repository
EOF
}

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

list_package_versions() {
    apt-cache madison "$1" |
        awk -F'|' '{ gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); if ($2 != "") print $2 }' |
        sort -Vu
}

select_package_version() {
    local label=$1 package=$2 configured=${3:-} minimum_major=${4:-0}
    local choice index default_index version major marker
    local -a versions available_versions
    mapfile -t available_versions < <(list_package_versions "$package")
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
        [[ "${versions[default_index]}" == "$configured" ]] ||
            fail "${label} version ${configured} is not available for ${package}."
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

select_php_version() {
    local choice index default_index candidate marker
    local -a versions
    local -a package_names
    mapfile -t package_names < <(
        apt-cache pkgnames |
            grep -E '^php[0-9]+\.[0-9]+-fpm$' |
            sed -E 's/^php([0-9]+\.[0-9]+)-fpm$/\1/' |
            sort -Vu
    )
    versions=()
    for candidate in "${package_names[@]}"; do
        if apt-cache policy "php${candidate}-fpm" |
            awk '/Candidate:/ { found = ($2 != "(none)") } END { exit !found }'; then
            versions+=("$candidate")
        fi
    done
    ((${#versions[@]} > 0)) || fail "No PHP-FPM packages are available from the configured APT repositories."
    for index in "${!versions[@]}"; do
        [[ "${versions[index]%%.*}" -ge 8 ]] ||
            fail "APT offered PHP ${versions[index]}, but this profile requires PHP 8 or later."
    done
    default_index=$((${#versions[@]} - 1))
    if [[ -n "$PHP_VERSION" ]]; then
        for index in "${!versions[@]}"; do
            if [[ "${versions[index]}" == "$PHP_VERSION" ]]; then
                default_index=$index
                break
            fi
        done
        [[ "${versions[default_index]}" == "$PHP_VERSION" ]] ||
            fail "Configured PHP ${PHP_VERSION} is not available from APT."
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

link_compat_path() {
    local target=$1 link=$2 resolved_target resolved_link
    if [[ -L "$link" ]]; then
        resolved_target="$(readlink -f "$target" 2>/dev/null || true)"
        resolved_link="$(readlink -f "$link" 2>/dev/null || true)"
        [[ -n "$resolved_target" && "$resolved_link" == "$resolved_target" ]] ||
            fail "Compatibility path already points elsewhere: $link"
    elif [[ -e "$link" ]]; then
        fail "Refusing to replace existing path: $link"
    else
        ln -s "$target" "$link"
    fi
}

create_bin_link() {
    local target=$1 link=$2
    [[ -x "$target" ]] || return 0
    if [[ -L "$link" ]]; then
        [[ "$(readlink -f "$link")" == "$(readlink -f "$target")" ]] ||
            fail "Compatibility path already points elsewhere: $link"
    elif [[ -e "$link" ]]; then
        fail "Refusing to replace existing path: $link"
    else
        ln -s "$target" "$link"
    fi
}

check_compat_path() {
    local path=$1 expected=$2 actual
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        return
    fi
    [[ -L "$path" ]] || fail "Existing custom LNMP path detected ($path); migrate or back it up before installing."
    actual="$(readlink -f "$path" 2>/dev/null || true)"
    if [[ "$expected" == php-fpm ]]; then
        [[ "$actual" =~ ^/etc/php/[0-9]+\.[0-9]+/fpm$ ]] ||
            fail "Existing custom LNMP path detected ($path); migrate or back it up before installing."
    else
        [[ "$actual" == "$(readlink -f "$expected")" ]] ||
            fail "Existing custom LNMP path detected ($path); migrate or back it up before installing."
    fi
}

install_mysql_repository() {
    local codename architecture key_tmp key_fingerprint
    codename="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"
    architecture="$(dpkg --print-architecture)"
    [[ "$architecture" == amd64 ]] ||
        fail "Oracle MySQL's Debian 13 APT repository currently supports amd64 only (found: $architecture)."
    [[ -n "$codename" ]] || fail "Could not determine Debian release codename."

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
    printf 'deb [arch=%s signed-by=%s] https://repo.mysql.com/apt/debian/ %s mysql-8.4-lts\n' \
        "$architecture" "$MYSQL_KEYRING" "$codename" > "$MYSQL_SOURCE"
    rm -f "$key_tmp"
    trap - RETURN
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

    check_compat_path /usr/local/nginx/conf /etc/nginx
    check_compat_path /usr/local/php/etc php-fpm
    check_compat_path /usr/local/mysql/var "$MYSQL_DATA_DIR"

    local mariadb_status mysql_community_status
    mariadb_status="$(dpkg-query -W -f='${db:Status-Status}' mariadb-server 2>/dev/null || true)"
    mysql_community_status="$(dpkg-query -W -f='${db:Status-Status}' mysql-community-server 2>/dev/null || true)"
    if [[ "$mariadb_status" == installed ]]; then
        fail "MariaDB is already installed. Back it up and remove or migrate it before installing MySQL."
    fi
    if [[ -d /var/lib/mysql ]] &&
       find /var/lib/mysql -mindepth 1 -maxdepth 1 -print -quit | grep -q . &&
       [[ "$mysql_community_status" != installed ]]; then
        fail "Existing database files were found in /var/lib/mysql. Back them up and migrate them before installing."
    fi
    if [[ "$MYSQL_DATA_DIR" != /var/lib/mysql && -d "$MYSQL_DATA_DIR" ]] &&
       find "$MYSQL_DATA_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q . &&
       [[ "$(readlink -f /var/lib/mysql 2>/dev/null || true)" != \
          "$(readlink -f "$MYSQL_DATA_DIR" 2>/dev/null || true)" ]]; then
        fail "MYSQL_DATA_DIR (${MYSQL_DATA_DIR}) already contains data and is not the active MySQL data directory."
    fi
}

prepare_package_sources() {
    if [[ ! -e "$SYSTEM_CONFIG" ]]; then
        install -m 0644 "$SCRIPT_DIR/lnmp-debian.conf" "$SYSTEM_CONFIG"
    fi

    if [[ -f "$MYSQL_SOURCE" ]]; then
        command -v curl >/dev/null ||
            fail "A stale MySQL APT source exists but curl is missing; install curl, then rerun this script."
        command -v gpg >/dev/null ||
            fail "A stale MySQL APT source exists but gpg is missing; install gnupg, then rerun this script."
        install_mysql_repository
        apt-get update
    else
        apt-get update
        apt-get install -y ca-certificates curl gnupg
        install_mysql_repository
        apt-get update
    fi
}

select_install_versions() {
    select_php_version
    select_package_version "Nginx" nginx "$NGINX_VERSION"
    NGINX_VERSION="$SELECTED_PACKAGE_VERSION"
    select_package_version "MySQL 8+" mysql-server "$MYSQL_VERSION" 8
    MYSQL_VERSION="$SELECTED_PACKAGE_VERSION"
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
        "php${PHP_VERSION}-opcache"
    )
    apt-get install -y "nginx=${NGINX_VERSION}" "${php_packages[@]}" \
        "mysql-server=${MYSQL_VERSION}" acme.sh

    PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"
    [[ -d "/etc/php/${PHP_VERSION}/fpm" ]] ||
        fail "PHP-FPM configuration for PHP ${PHP_VERSION} was not installed."
    install -d -m 0755 /etc/lnmp-debian
    printf '%s\n' "$PHP_VERSION" > /etc/lnmp-debian/php-version
}

configure_mysql_data_directory() {
    if [[ "$MYSQL_DATA_DIR" != /var/lib/mysql ]] &&
       [[ "$(readlink -f /var/lib/mysql 2>/dev/null || true)" != \
          "$(readlink -f "$MYSQL_DATA_DIR" 2>/dev/null || true)" ]]; then
        local mysql_default_backup apparmor_local apparmor_parent
        mysql_default_backup=/var/lib/mysql.lnmp-debian.orig
        [[ ! -e "$mysql_default_backup" ]] ||
            fail "Database backup path already exists: ${mysql_default_backup}"
        systemctl stop mysql
        mkdir -p "$MYSQL_DATA_DIR"
        if [[ -d /var/lib/mysql ]] && [[ ! -L /var/lib/mysql ]]; then
            cp -a /var/lib/mysql/. "$MYSQL_DATA_DIR"/
            chown -R mysql:mysql "$MYSQL_DATA_DIR"
            mv /var/lib/mysql "$mysql_default_backup"
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
                apparmor_parser -r /etc/apparmor.d/usr.sbin.mysqld
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

create_compatibility_layout() {
    local binary
    mkdir -p /usr/local/nginx /usr/local/php/var /usr/local/mysql /run/php
    link_compat_path /etc/nginx /usr/local/nginx/conf
    link_compat_path "/etc/php/${PHP_VERSION}/fpm" /usr/local/php/etc
    link_compat_path /run/php /usr/local/php/var/run
    link_compat_path /var/log/nginx /usr/local/nginx/logs
    link_compat_path "$MYSQL_DATA_DIR" /usr/local/mysql/var
    mkdir -p /usr/local/nginx/sbin /usr/local/php/bin /usr/local/php/sbin \
        /usr/local/mysql/bin /usr/local/nginx/conf/vhost \
        "$REWRITE_DIR" /usr/local/nginx/conf/ssl /run/php
    if [[ ! -d "$WEB_ROOT" ]]; then
        mkdir -p "$WEB_ROOT"
        chown www:www "$WEB_ROOT"
    fi
    if [[ ! -d "$DEFAULT_WEB_ROOT" ]]; then
        mkdir -p "$DEFAULT_WEB_ROOT"
        chown www:www "$DEFAULT_WEB_ROOT"
    fi
    if [[ ! -d "$NGINX_LOG_DIR" ]]; then
        mkdir -p "$NGINX_LOG_DIR"
        chown www:www "$NGINX_LOG_DIR"
    fi

    create_bin_link /usr/sbin/nginx /usr/local/nginx/sbin/nginx
    create_bin_link "/usr/bin/php${PHP_VERSION}" /usr/local/php/bin/php
    create_bin_link "/usr/sbin/php-fpm${PHP_VERSION}" /usr/local/php/sbin/php-fpm
    for binary in mysql mysqldump mysqladmin mysqlcheck mysql_config mysqld mysqld_safe; do
        create_bin_link "/usr/bin/${binary}" "/usr/local/mysql/bin/${binary}"
    done

    if [[ ! -e /etc/my.cnf && ! -L /etc/my.cnf ]]; then
        : > /etc/mysql/conf.d/lnmp-legacy.cnf
        ln -s /etc/mysql/conf.d/lnmp-legacy.cnf /etc/my.cnf
    elif [[ "$(readlink -f /etc/my.cnf 2>/dev/null || true)" != /etc/mysql/my.cnf &&
            "$(readlink -f /etc/my.cnf 2>/dev/null || true)" != /etc/mysql/conf.d/lnmp-legacy.cnf ]]; then
        cat > /etc/mysql/conf.d/lnmp-legacy.cnf <<'EOF'
!include /etc/my.cnf
EOF
    fi
}

configure_nginx() {
    local rewrite_template rewrite_name rewrite_file
    if [[ ! -e /usr/local/nginx/conf/enable-php.conf ]]; then
        cat > /usr/local/nginx/conf/enable-php.conf <<EOF
location ~ [^/]\.php(/|$)
{
    try_files \$uri =404;
    fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
    fastcgi_index index.php;
    include fastcgi.conf;
}
EOF
    fi
    if [[ ! -e /usr/local/nginx/conf/enable-php-pathinfo.conf ]]; then
        cat > /usr/local/nginx/conf/enable-php-pathinfo.conf <<EOF
location ~ [^/]\.php(/|$)
{
    fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
    fastcgi_index index.php;
    include fastcgi.conf;
    include pathinfo.conf;
}
EOF
    fi
    if [[ ! -e "/usr/local/nginx/conf/enable-php${PHP_VERSION}.conf" ]]; then
        ln -s enable-php.conf "/usr/local/nginx/conf/enable-php${PHP_VERSION}.conf"
    fi
    if [[ ! -e "/usr/local/nginx/conf/enable-php${PHP_VERSION}-pathinfo.conf" ]]; then
        ln -s enable-php-pathinfo.conf \
            "/usr/local/nginx/conf/enable-php${PHP_VERSION}-pathinfo.conf"
    fi
    if [[ ! -e /usr/local/nginx/conf/pathinfo.conf ]]; then
        cat > /usr/local/nginx/conf/pathinfo.conf <<'EOF'
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
    if [[ ! -e /usr/local/nginx/conf/conf.d/lnmp-debian-vhosts.conf ]]; then
        cat > /usr/local/nginx/conf/conf.d/lnmp-debian-vhosts.conf <<'EOF'
include /usr/local/nginx/conf/vhost/*.conf;
EOF
    elif ! grep -Fq 'include /usr/local/nginx/conf/vhost/*.conf;' \
            /usr/local/nginx/conf/conf.d/lnmp-debian-vhosts.conf; then
        fail "Conflicting Nginx include file: /usr/local/nginx/conf/conf.d/lnmp-debian-vhosts.conf"
    fi

    local nginx_conf nginx_default_available nginx_default_enabled nginx_default_template nginx_default_temp
    nginx_conf=/etc/nginx/nginx.conf
    if [[ -f "$nginx_conf" ]]; then
        cp -n "$nginx_conf" "${nginx_conf}.lnmp-debian.orig"
        sed -i -E 's/^[[:space:]]*user[[:space:]]+www-data;/user www;/' "$nginx_conf"
    fi

    nginx_default_available=/etc/nginx/sites-available/default
    nginx_default_enabled=/etc/nginx/sites-enabled/default
    nginx_default_template="$SCRIPT_DIR/conf/default-site.conf"
    [[ -s "$nginx_default_template" ]] ||
        fail "Default Nginx site template is missing: ${nginx_default_template}"
    if [[ -L "$nginx_default_enabled" ]]; then
        [[ "$(readlink -f "$nginx_default_enabled")" == "$nginx_default_available" ]] ||
            fail "The enabled default site points elsewhere: ${nginx_default_enabled}"
    elif [[ -e "$nginx_default_enabled" ]]; then
        fail "A non-symlink default site already exists at ${nginx_default_enabled}."
    fi
    if [[ -f "$nginx_default_available" ]] &&
       ! grep -Fq '# Managed by LNMP Debian.' "$nginx_default_available" &&
       ! grep -Fq 'root /var/www/html;' "$nginx_default_available"; then
        fail "A customized Debian default site already exists at ${nginx_default_available}; refusing to replace it."
    fi
    if [[ -f "$nginx_default_available" ]] &&
       ! grep -Fq '# Managed by LNMP Debian.' "$nginx_default_available"; then
        cp -n "$nginx_default_available" "${nginx_default_available}.lnmp-debian.orig"
    fi
    nginx_default_temp="$(mktemp "${nginx_default_available}.XXXXXX")"
    sed "s#@DEFAULT_WEB_ROOT@#${DEFAULT_WEB_ROOT}#g" \
        "$nginx_default_template" > "$nginx_default_temp"
    chmod 0644 "$nginx_default_temp"
    mv "$nginx_default_temp" "$nginx_default_available"
    if [[ ! -L "$nginx_default_enabled" ]]; then
        ln -s ../sites-available/default "$nginx_default_enabled"
    fi
}

configure_php_fpm() {
    local pool_conf fpm_conf
    if [[ ! -e /etc/init.d/php-fpm ]]; then
        cat > /etc/init.d/php-fpm <<EOF
#!/bin/sh
exec /etc/init.d/${PHP_FPM_SERVICE} "\$@"
EOF
        chmod 0755 /etc/init.d/php-fpm
    fi

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
    nginx -t
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
    printf 'Nginx config: /usr/local/nginx/conf/nginx.conf -> /etc/nginx/nginx.conf\n'
    printf 'PHP config:   /usr/local/php/etc/php.ini -> /etc/php/%s/fpm/php.ini\n' "$PHP_VERSION"
    printf 'Nginx version: %s\nPHP version:   %s\nMySQL version: %s\n' "$NGINX_VERSION" "$PHP_VERSION" "$MYSQL_VERSION"
    printf 'Default web:  %s\nMySQL data:   %s\n' "$DEFAULT_WEB_ROOT" "$MYSQL_DATA_DIR"
    printf 'Certificates: /usr/local/nginx/conf/ssl/\n'
    printf 'Management:   lnmp {start|stop|reload|restart|status|vhost|database|ssl|dnsssl}\n'
}

main() {
    parse_arguments "$@"
    validate_platform
    validate_configuration_and_existing_data
    prepare_package_sources
    select_install_versions
    install_packages
    configure_mysql_data_directory
    ensure_web_user
    create_compatibility_layout
    configure_nginx
    configure_php_fpm
    install_management_commands
    start_and_verify_services
    print_summary
}

main "$@"
