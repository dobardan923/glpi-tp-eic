#!/usr/bin/env bash
# GLPI TP EIC - Installation GLPI 12.0.1 / AlmaLinux 10 / SELinux
# Apache + PHP-FPM + MariaDB + phpMyAdmin + Avahi + API REST legacy
# GitHub : dobardan923/glpi-tp-eic
# Lanceur glpi-tp installe automatiquement ; aucun TP execute.
# Execution : bash install-glpi12-alma10-selinux.sh
# N'execute PAS les modules pedagogiques automatiquement.
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

GLPI_VERSION="${GLPI_VERSION:-12.0.1}"
PMA_VERSION="${PMA_VERSION:-5.2.3}"
GLPI_HOSTNAME="${GLPI_HOSTNAME:-}"
GLPI_LANG="${GLPI_LANG:-fr_FR}"
INSTALL_DIR="${INSTALL_DIR:-/var/www/glpi}"
PMA_DIR="${PMA_DIR:-/usr/share/phpmyadmin}"
PMA_TMP_DIR="${PMA_TMP_DIR:-/var/lib/phpmyadmin/tmp}"
DB_NAME="${DB_NAME:-glpi}"
DB_USER="${DB_USER:-glpi}"
DB_PASS="${DB_PASS:-glpi}"
PMA_DBADMIN_USER="${PMA_DBADMIN_USER:-dbadmin}"
PMA_DBADMIN_PASS="${PMA_DBADMIN_PASS:-dbadmin}"
GITHUB_REPO="${GITHUB_REPO:-dobardan923/glpi-tp-eic}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
TP_DIR="${TP_DIR:-/opt/glpi-tp}"
TP_REPO_DIR="${TP_DIR}/repository"
TP_LAUNCHER="/usr/local/bin/glpi-tp"
# GLPI 12.0.1 : SHA-256 de l'archive de distribution, recoupe avec Fossies.
# GLPI ne publie pas de fichier .tgz.sha256 a l'URL supposee par l'ancienne version.
# Un checksum personnalise peut etre fourni pour validation explicite.
GLPI_SHA256="${GLPI_SHA256:-bf89a1be40ea76e4e7a6a5cea8fd24c9d822fab83e4e90519ff0c8d062f13291}"
PMA_SHA256="${PMA_SHA256:-}"

GLPI_ARCHIVE_URL="https://github.com/glpi-project/glpi/releases/download/${GLPI_VERSION}/glpi-${GLPI_VERSION}.tgz"
PMA_ARCHIVE_URL="https://files.phpmyadmin.net/phpMyAdmin/${PMA_VERSION}/phpMyAdmin-${PMA_VERSION}-all-languages.tar.gz"
CREDENTIAL_FILE=/root/glpi-install-credentials.txt
VHOST_FILE=/etc/httpd/conf.d/glpi.conf
PHP_FILE=/etc/php.d/99-glpi.ini
MARIADB_FILE=/etc/my.cnf.d/99-glpi.cnf
AVAHI_SERVICE=/etc/avahi/services/glpi.service
CRON_FILE=/etc/cron.d/glpi
TEMP_DIR=""

log() { printf '\n[GLPI] %s\n' "$*"; }
warn() { printf '\n[AVERTISSEMENT] %s\n' "$*" >&2; }
die() { printf '\n[ERREUR] %s\n' "$*" >&2; exit 1; }
cleanup() { [[ -z "$TEMP_DIR" ]] || rm -rf -- "$TEMP_DIR"; }
trap cleanup EXIT
trap 'die "Erreur a la ligne ${LINENO}."' ERR

[[ "$EUID" -eq 0 ]] || die "Execution root requise."
[[ -r /etc/os-release ]] || die "/etc/os-release absent."
# shellcheck source=/etc/os-release
source /etc/os-release
[[ "$ID" == almalinux && "${VERSION_ID%%.*}" == 10 ]] || die "AlmaLinux 10 requis."
[[ "$GLPI_VERSION" == 12.0.1 ]] || die "Version GLPI non validee par cet installateur."
[[ "$PMA_VERSION" == 5.2.3 ]] || die "Version phpMyAdmin non validee par cet installateur."
for ident in "$DB_NAME" "$DB_USER" "$PMA_DBADMIN_USER"; do
    [[ "$ident" =~ ^[A-Za-z0-9_]+$ ]] || die "Identifiant SQL incorrect : $ident"
done
for pass in "$DB_PASS" "$PMA_DBADMIN_PASS"; do
    [[ -n "$pass" && "$pass" != *"'"* && "$pass" != *'\'* ]] || die "Mot de passe SQL vide ou contient des caracteres SQL non geres."
done
[[ "$GITHUB_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "GITHUB_REPO incorrect."
[[ "$GITHUB_BRANCH" =~ ^[A-Za-z0-9._/-]+$ && "$GITHUB_BRANCH" != *..* ]] || die "GITHUB_BRANCH incorrect."
# Le lanceur GitHub cible ce depot et la branche main en dur.
[[ "$GITHUB_REPO" == dobardan923/glpi-tp-eic ]] || die "GITHUB_REPO doit correspondre au lanceur actuel."
[[ "$GITHUB_BRANCH" == main ]] || die "GITHUB_BRANCH doit etre main avec le lanceur actuel."
[[ "$TP_DIR" == /opt/glpi-tp ]] || die "TP_DIR doit etre /opt/glpi-tp avec le lanceur actuel."

# Le mode audit utilise le nom actuel et n'affiche aucune question.
if [[ "${1:-}" == '--check' && -z "$GLPI_HOSTNAME" ]]; then
    GLPI_HOSTNAME="$(hostname -s)"
fi

if [[ -z "$GLPI_HOSTNAME" ]]; then
    if [[ -t 0 ]]; then
        read -r -p 'Nom de la VM [glpi] : ' GLPI_HOSTNAME
        GLPI_HOSTNAME="${GLPI_HOSTNAME:-glpi}"
    else
        GLPI_HOSTNAME=glpi
    fi
fi
GLPI_HOSTNAME="${GLPI_HOSTNAME,,}"
[[ "$GLPI_HOSTNAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die "Nom de machine incorrect."
FQDN="${GLPI_HOSTNAME}.local"
TEMP_DIR="$(mktemp -d)"

# Verifier l'archive par SHA256 epingle ou fichier .sha256 publie.
# Refuser l'installation sans verification. Ne pas utiliser de mode insecure.
verify_archive() {
    local archive="$1" url="$2" pinned="$3" sha_file="$4"
    local actual expected
    actual="$(sha256sum "$archive" | awk '{print $1}')"
    if [[ -n "$pinned" ]]; then
        [[ "$pinned" =~ ^[A-Fa-f0-9]{64}$ ]] || die "SHA256 fourni invalide : $archive"
        expected="${pinned,,}"
    else
        log "Recuperation du checksum fournisseur : ${url}.sha256"
        curl --fail --location --retry 3 --silent --show-error \
            -o "$sha_file" "${url}.sha256" || \
            die "Checksum fournisseur indisponible pour $url. Renseigner GLPI_SHA256 ou PMA_SHA256 apres verification independante."
        # Formats supported: hex-only, 'hex  filename', 'SHA256(filename)=hex'.
        expected="$(grep -Eo '[0-9a-fA-F]{64}' "$sha_file" | head -n1 || true)"
        [[ -n "$expected" ]] || die "Fichier checksum fournisseur non reconnu : $sha_file"
        expected="${expected,,}"
    fi
    [[ "$actual" == "$expected" ]] || die "SHA256 invalide pour $archive : attendu $expected, obtenu $actual"
    log "Archive verifiee : $(basename "$archive")"
}

# =============================================================================
# BILAN TECHNIQUE : reutilisable apres l'installation via --check.
# Ne modifie ni la base de donnees, ni le pare-feu, ni SELinux.
# =============================================================================
check_installation() {
    local errors=0 service status response code context
    local php_required=(bcmath curl dom fileinfo gd intl libxml mbstring mysqli openssl session simplexml tokenizer xmlreader xmlwriter zlib)
    local ext
    check_ok() { printf '[OK] %s\n' "$*"; }
    check_ko() { printf '[ECHEC] %s\n' "$*" >&2; errors=$((errors + 1)); }

    printf '\n============================================================\n'
    printf ' CONTROLE COMPLET GLPI / AlmaLinux 10\n'
    printf '============================================================\n'

    for service in httpd php-fpm mariadb avahi-daemon crond firewalld; do
        if systemctl is-active --quiet "$service"; then
            check_ok "Service actif : $service"
        else
            check_ko "Service inactif : $service"
        fi
    done

    for bin in git wget vim jq curl; do
        if command -v "$bin" >/dev/null 2>&1; then
            check_ok "Commande presente : $bin"
        else
            check_ko "Commande manquante : $bin"
        fi
    done

    if [[ -f "$INSTALL_DIR/bin/console" && -f "$INSTALL_DIR/config/config_db.php" ]]; then
        check_ok "GLPI installe avec configuration SQL"
    else
        check_ko "GLPI ou configuration SQL introuvable"
    fi

    if [[ -f "$PMA_DIR/.installed-version" ]] &&
       [[ "$(cat "$PMA_DIR/.installed-version")" == "$PMA_VERSION" ]]; then
        check_ok "phpMyAdmin $PMA_VERSION installe"
    else
        check_ko "phpMyAdmin $PMA_VERSION absent ou version incorrecte"
    fi

    if mariadb -NBe 'SELECT 1;' >/dev/null 2>&1; then
        check_ok 'MariaDB repond localement'
    else
        check_ko 'MariaDB ne repond pas localement'
    fi

    if httpd -t >/dev/null 2>&1; then
        check_ok 'Configuration Apache valide'
    else
        check_ko 'Configuration Apache invalide'
    fi

    for ext in "${php_required[@]}"; do
        if php -m | tr '[:upper:]' '[:lower:]' | grep -qx "$ext"; then
            :
        else
            check_ko "Extension PHP absente : $ext"
        fi
    done
    check_ok 'Verification des extensions PHP terminee'

    if [[ -f "$INSTALL_DIR/bin/console" && -f "$INSTALL_DIR/config/config_db.php" ]]; then
        if (cd "$INSTALL_DIR" && runuser -u apache -- php bin/console system:check_requirements --no-interaction) >/dev/null 2>&1; then
            check_ok 'Prerequis GLPI valides par la console'
        else
            check_ko 'Prerequis GLPI non valides par la console'
        fi
    fi

    if command -v getenforce >/dev/null 2>&1; then
        status="$(getenforce)"
        if [[ "$status" == Enforcing ]]; then
            check_ok 'SELinux Enforcing'
        else
            check_ko "SELinux non Enforcing : $status"
        fi
        if [[ "$status" != Disabled ]]; then
            for dir in config files marketplace; do
                if [[ -d "$INSTALL_DIR/$dir" ]]; then
                    context="$(stat -c %C "$INSTALL_DIR/$dir")"
                    if [[ "$context" == *:httpd_sys_rw_content_t:* ]]; then
                        check_ok "Contexte SELinux RW : $dir"
                    else
                        check_ko "Contexte SELinux incorrect : $dir ($context)"
                    fi
                fi
            done
        fi
    fi

    if [[ -d "$TP_REPO_DIR/.git" ]]; then
        check_ok "Depot GitHub local present : $TP_REPO_DIR"
        if [[ "$(git -C "$TP_REPO_DIR" remote get-url origin 2>/dev/null || true)" == "https://github.com/${GITHUB_REPO}.git" ]]; then
            check_ok 'Origine GitHub conforme'
        else
            check_ko 'Origine GitHub incorrecte'
        fi
    else
        check_ko "Depot pedagogique absent : $TP_REPO_DIR"
    fi

    if [[ -f "$TP_LAUNCHER" ]] && bash -n "$TP_LAUNCHER"; then
        check_ok "Lanceur glpi-tp installe et syntaxe valide"
    else
        check_ko 'Lanceur glpi-tp absent ou syntaxe invalide'
    fi

    if [[ -f "$TP_REPO_DIR/modules/01-preparation-glpi.sh" ]] &&
       bash -n "$TP_REPO_DIR/modules/01-preparation-glpi.sh"; then
        check_ok 'Module 01 disponible et syntaxe Bash valide'
    else
        check_ko 'Module 01 absent ou syntaxe Bash invalide'
    fi

    # curl -o -w capte HTTP 400 sans l'interpreter comme echec de connexion.
    local tmp
    tmp="$(mktemp)"
    if code="$(curl --silent --show-error --connect-timeout 5 --max-time 15 \
            -o "$tmp" -w '%{http_code}' \
            'http://127.0.0.1/apirest.php/initSession')"; then
        response="$(cat "$tmp")"
        if [[ "$response" == *'API désactivée'* || "$response" == *'API desactivee'* ]]; then
            check_ko 'API REST legacy desactivee'
        elif [[ "$code" == 400 || "$code" == 401 || "$code" == 200 ]]; then
            check_ok "API legacy joignable, HTTP $code sans identifiants"
        else
            check_ko "API legacy reponse inhabituelle : HTTP $code $response"
        fi
    else
        check_ko 'Impossible de joindre API legacy en HTTP'
    fi
    rm -f "$tmp"

    tmp="$(mktemp)"
    if code="$(curl --silent --show-error --connect-timeout 5 --max-time 15 \
            -o "$tmp" -w '%{http_code}' \
            'http://127.0.0.1/phpmyadmin/')"; then
        case "$code" in
            200|301|302) check_ok "phpMyAdmin HTTP $code" ;;
            *) check_ko "phpMyAdmin HTTP $code" ;;
        esac
    else
        check_ko 'phpMyAdmin inaccessible par HTTP'
    fi
    rm -f "$tmp"

    printf '\n============================================================\n'
    if (( errors == 0 )); then
        printf '[OK] TOUS LES CONTROLES SONT PASSES\n'
        printf 'Le test sans identifiants ne verifie pas une session API authentifiee.\n'
        return 0
    fi
    printf '[ECHEC] %d controle(s) en erreur.\n' "$errors" >&2
    return 1
}

if [[ "${1:-}" == '--check' ]]; then
    check_installation
    exit $?
fi

log "Configuration du nom d'hote : $FQDN"
hostnamectl set-hostname "$GLPI_HOSTNAME"

log "Installation des paquets (dont git, wget, vim, jq)"
# Configuration des dépôts AlmaLinux : utiliser baseurl au lieu de mirrorlist
echo "[INFO] Configuration des dépôts AlmaLinux"

for repo in /etc/yum.repos.d/almalinux-*.repo; do
    [[ -f "$repo" ]] || continue

    # Sauvegarde du fichier original
    [[ -f "${repo}.bak" ]] || cp -p "$repo" "${repo}.bak"

    # Désactivation de mirrorlist et activation de baseurl
    sed -i \
        -e '/^[[:space:]]*mirrorlist=/s/^/#/' \
        -e '/^[[:space:]]*#[[:space:]]*baseurl=/s/^[[:space:]]*#[[:space:]]*//' \
        "$repo"
done

# Actualisation du cache DNF
dnf clean metadata
dnf makecache --refresh
dnf -y install \
    httpd mariadb-server \
    php php-cli php-fpm php-bcmath php-gd php-intl php-ldap \
    php-mbstring php-mysqlnd php-opcache php-pecl-zip php-process php-xml \
    curl wget git vim-enhanced jq ca-certificates tar gzip openssl \
    avahi avahi-tools firewalld cronie policycoreutils-python-utils

cat > "$PHP_FILE" <<'EOF'
memory_limit = 256M
max_execution_time = 300
max_input_vars = 5000
post_max_size = 64M
upload_max_filesize = 64M
session.cookie_httponly = On
session.cookie_samesite = Lax
date.timezone = Europe/Brussels
EOF

cat > "$MARIADB_FILE" <<'EOF'
[mariadb]
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
innodb_file_per_table=1
max_allowed_packet=64M
EOF

for service in firewalld mariadb php-fpm httpd avahi-daemon crond; do
    systemctl enable --now "$service"
done
systemctl restart mariadb
firewall-cmd --permanent --add-service=http >/dev/null
firewall-cmd --permanent --add-service=mdns >/dev/null
firewall-cmd --reload >/dev/null

mkdir -p /etc/avahi/services
cat > "$AVAHI_SERVICE" <<'EOF'
<?xml version="1.0" standalone="no"?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">GLPI sur %h</name>
  <service><type>_http._tcp</type><port>80</port><txt-record>path=/</txt-record></service>
</service-group>
EOF
systemctl restart avahi-daemon

log "Initialisation MariaDB"
mariadb -NBe 'SELECT 1' >/dev/null || die "MariaDB inaccessible."
TZ_COUNT="$(mariadb -NBe 'SELECT COUNT(*) FROM mysql.time_zone_name' || printf 0)"
if [[ "$TZ_COUNT" == 0 ]]; then
    mariadb-tzinfo-to-sql /usr/share/zoneinfo 2>/dev/null | mariadb mysql
fi

ALREADY_CONFIGURED=0
[[ ! -f "$INSTALL_DIR/config/config_db.php" ]] || ALREADY_CONFIGURED=1
if [[ "$ALREADY_CONFIGURED" == 0 ]]; then
    log "Preparation base GLPI"
    mariadb <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
GRANT SELECT ON mysql.time_zone_name TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
else
    warn "Installation GLPI existante : compte SQL applicatif conserve."
fi

log "Preparation compte MariaDB pour phpMyAdmin"
mariadb <<SQL
CREATE USER IF NOT EXISTS '${PMA_DBADMIN_USER}'@'localhost' IDENTIFIED BY '${PMA_DBADMIN_PASS}';
ALTER USER '${PMA_DBADMIN_USER}'@'localhost' IDENTIFIED BY '${PMA_DBADMIN_PASS}';
GRANT ALL PRIVILEGES ON *.* TO '${PMA_DBADMIN_USER}'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL

if [[ ! -f "$INSTALL_DIR/bin/console" ]]; then
    [[ ! -e "$INSTALL_DIR" ]] || die "$INSTALL_DIR existe, mais GLPI est incomplet. Refus d'ecrasement."
    log "Telechargement GLPI $GLPI_VERSION"
    archive="$TEMP_DIR/glpi-${GLPI_VERSION}.tgz"
    curl --fail --location --retry 3 --output "$archive" "$GLPI_ARCHIVE_URL"
    verify_archive "$archive" "$GLPI_ARCHIVE_URL" "$GLPI_SHA256" "$TEMP_DIR/glpi.sha256"
    tar -tzf "$archive" > "$TEMP_DIR/glpi-contents.txt"
    grep -qx 'glpi/bin/console' "$TEMP_DIR/glpi-contents.txt" || die "Archive GLPI sans console attendue."
    tar -xzf "$archive" -C /var/www
fi
[[ -f "$INSTALL_DIR/bin/console" ]] || die "Console GLPI absente."

if [[ ! -f "$PMA_DIR/.installed-version" ]]; then
    [[ ! -e "$PMA_DIR" ]] || die "$PMA_DIR existe deja sans marqueur de version."
    log "Telechargement phpMyAdmin $PMA_VERSION"
    archive="$TEMP_DIR/phpMyAdmin-${PMA_VERSION}-all-languages.tar.gz"
    curl --fail --location --retry 3 --output "$archive" "$PMA_ARCHIVE_URL"
    verify_archive "$archive" "$PMA_ARCHIVE_URL" "$PMA_SHA256" "$TEMP_DIR/pma.sha256"
    tar -xzf "$archive" -C "$TEMP_DIR"
    mv "$TEMP_DIR/phpMyAdmin-${PMA_VERSION}-all-languages" "$PMA_DIR"
    printf '%s\n' "$PMA_VERSION" > "$PMA_DIR/.installed-version"
else
    [[ "$(cat "$PMA_DIR/.installed-version")" == "$PMA_VERSION" ]] || die "Version phpMyAdmin differente."
fi

mkdir -p "$PMA_TMP_DIR"
PMA_SECRET="$(openssl rand -hex 24)"
cat > "$PMA_DIR/config.inc.php" <<EOF
<?php
\$cfg['blowfish_secret'] = '$PMA_SECRET';
\$i = 0;
++\$i;
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
\$cfg['Servers'][\$i]['host'] = 'localhost';
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;
\$cfg['TempDir'] = '$PMA_TMP_DIR';
EOF

log "Permissions applicatives"
chown -R root:apache "$INSTALL_DIR" "$PMA_DIR"
find "$INSTALL_DIR" "$PMA_DIR" -type d -exec chmod 750 {} +
find "$INSTALL_DIR" "$PMA_DIR" -type f -exec chmod 640 {} +
chmod 750 "$INSTALL_DIR/bin/console"
for dir in config files marketplace; do
    if [[ -d "$INSTALL_DIR/$dir" ]]; then
        chown -R apache:apache "$INSTALL_DIR/$dir"
        find "$INSTALL_DIR/$dir" -type d -exec chmod 770 {} +
        find "$INSTALL_DIR/$dir" -type f -exec chmod 660 {} +
    fi
done
chown apache:apache "$PMA_TMP_DIR"
chmod 770 "$PMA_TMP_DIR"

log "SELinux : conserver Enforcing et etiqueter les dossiers modifiables"
set_fcontext() {
    local regex="$1" type="$2"
    semanage fcontext -d "$regex" >/dev/null 2>&1 || true
    semanage fcontext -a -t "$type" "$regex"
}
set_fcontext "${INSTALL_DIR}(/.*)?" httpd_sys_content_t
set_fcontext "${PMA_DIR}(/.*)?" httpd_sys_content_t
for dir in config files marketplace; do
    [[ ! -d "$INSTALL_DIR/$dir" ]] || set_fcontext "${INSTALL_DIR}/${dir}(/.*)?" httpd_sys_rw_content_t
done
set_fcontext "${PMA_TMP_DIR}(/.*)?" httpd_sys_rw_content_t
restorecon -RF "$INSTALL_DIR" "$PMA_DIR" "$PMA_TMP_DIR" >/dev/null
setsebool -P httpd_can_network_connect on
setsebool -P httpd_can_network_connect_db on
if [[ "$(getenforce)" == Enforcing ]]; then
    for dir in config files marketplace; do
        [[ ! -d "$INSTALL_DIR/$dir" ]] || [[ "$(stat -c %C "$INSTALL_DIR/$dir")" == *:httpd_sys_rw_content_t:* ]] || die "Contexte SELinux non RW : $dir"
    done
fi

log "Configuration Apache"
cat > "$VHOST_FILE" <<EOF
<VirtualHost *:80>
    ServerName $FQDN
    ServerAlias $GLPI_HOSTNAME
    DocumentRoot $INSTALL_DIR/public
    DirectoryIndex index.php
    Alias /phpmyadmin $PMA_DIR

    <Directory $PMA_DIR>
        Options FollowSymLinks
        AllowOverride None
        DirectoryIndex index.php
        <RequireAny>
            Require local
            Require ip 10.0.0.0/8
            Require ip 172.16.0.0/12
            Require ip 192.168.0.0/16
        </RequireAny>
    </Directory>
    <Directory $PMA_DIR/setup>
        Require all denied
    </Directory>
    <Directory $PMA_DIR/libraries>
        Require all denied
    </Directory>
    <Directory $PMA_DIR/templates>
        Require all denied
    </Directory>
    <Directory $INSTALL_DIR/public>
        Options FollowSymLinks
        AllowOverride None
        Require all granted
        RewriteEngine On
        RewriteCond %{HTTP:Authorization} ^(.+)$
        RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
        RewriteCond %{REQUEST_FILENAME} !-f
        RewriteRule ^(.*)$ index.php [QSA,L]
    </Directory>
    ErrorLog /var/log/httpd/glpi-error.log
    CustomLog /var/log/httpd/glpi-access.log combined
</VirtualHost>
EOF
httpd -t
systemctl restart php-fpm httpd

log "Verification extensions PHP"
for ext in bcmath curl dom fileinfo gd intl libxml mbstring mysqli openssl session simplexml tokenizer xmlreader xmlwriter zlib; do
    php -m | tr '[:upper:]' '[:lower:]' | grep -qx "$ext" || die "Extension PHP manquante : $ext"
done

cd "$INSTALL_DIR"
runuser -u apache -- php bin/console system:check_requirements --no-interaction
if [[ ! -f "$INSTALL_DIR/config/config_db.php" ]]; then
    log "Installation de la base GLPI"
    runuser -u apache -- php bin/console database:install \
        --db-host=localhost --db-name="$DB_NAME" --db-user="$DB_USER" \
        --db-password="$DB_PASS" --default-language="$GLPI_LANG" \
        --no-telemetry --no-interaction
fi

log "Activation automatique API REST legacy"
# Execute en apache pour respecter les droits existants.
runuser -u apache -- php bin/console --no-interaction config:set enable_api 1
runuser -u apache -- php bin/console --no-interaction config:set enable_api_login_credentials 1

# Basic API availability check: no longer report 'API desactivee'.
API_RESULT="$(curl --silent --show-error http://127.0.0.1/apirest.php/initSession)" || die "API REST locale inaccessible."
[[ "$API_RESULT" != *'API désactivée'* ]] || die "API REST legacy demeure desactivee."
log "API legacy activee : authentification a verifier via le module 01."

cat > "$CRON_FILE" <<EOF
* * * * * apache /usr/bin/php $INSTALL_DIR/front/cron.php >/dev/null 2>&1
EOF
chmod 644 "$CRON_FILE"
systemctl restart crond
restorecon -RF "$INSTALL_DIR" "$PMA_DIR" "$PMA_TMP_DIR" >/dev/null

log "Installation du gestionnaire de TP depuis GitHub"
mkdir -p "$TP_DIR"
chmod 755 "$TP_DIR"

# Une seule copie du depot GitHub public, branche main.
# Aucun scenario ou module n'est execute pendant l'installation.
TP_ORIGIN="https://github.com/${GITHUB_REPO}.git"
if [[ ! -e "$TP_REPO_DIR" ]]; then
    git clone --branch "$GITHUB_BRANCH" --single-branch -- \
        "$TP_ORIGIN" "$TP_REPO_DIR"
elif [[ -d "$TP_REPO_DIR/.git" ]]; then
    actual_origin="$(git -C "$TP_REPO_DIR" remote get-url origin)"
    [[ "$actual_origin" == "$TP_ORIGIN" ]] || die "Origine Git inattendue : $actual_origin"
    [[ -z "$(git -C "$TP_REPO_DIR" status --porcelain)" ]] || \
        die "Le depot TP contient des modifications locales : mise a jour refusee."
    git -C "$TP_REPO_DIR" pull --ff-only origin "$GITHUB_BRANCH"
else
    die "Le chemin $TP_REPO_DIR existe mais n'est pas un depot Git."
fi

# Installer le lanceur versionne avec ce meme commit.
TP_LAUNCHER_SOURCE="$TP_REPO_DIR/glpi-tp.sh"
[[ -s "$TP_LAUNCHER_SOURCE" ]] || die "glpi-tp.sh introuvable dans le depot GitHub."
bash -n "$TP_LAUNCHER_SOURCE" || die "Syntaxe invalide dans glpi-tp.sh."

# Le lanceur publie actuellement par le professeur utilise cette
# racine locale et cette branche. Verifier leur coherence.
grep -Fq 'REPO_DIR="${BASE_DIR}/repository"' "$TP_LAUNCHER_SOURCE" || \
    die 'Chemin du depot inattendu dans le lanceur glpi-tp.sh.'
grep -Fq 'REPO_BRANCH="main"' "$TP_LAUNCHER_SOURCE" || \
    die 'La branche du lanceur glpi-tp.sh ne correspond pas a main.'
[[ "$GITHUB_BRANCH" == main ]] || die 'Le lanceur actuel ne prend en charge que main.'
[[ "$TP_DIR" == /opt/glpi-tp ]] || die 'Le lanceur actuel exige TP_DIR=/opt/glpi-tp.'
[[ "$GITHUB_REPO" == dobardan923/glpi-tp-eic ]] || die 'Le lanceur actuel exige le depot dobardan923/glpi-tp-eic.'
install -o root -g root -m 0755 "$TP_LAUNCHER_SOURCE" "$TP_LAUNCHER"

log "Lanceur installe : $TP_LAUNCHER"
log "Modules disponibles via GitHub main : glpi-tp list"
log "Aucun module n'a ete execute."

cat > "$CREDENTIAL_FILE" <<EOF
GLPI_URL=http://$FQDN/
PHPMYADMIN_URL=http://$FQDN/phpmyadmin/
GLPI_HOSTNAME=$GLPI_HOSTNAME
DB_HOST=localhost
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASS
PMA_DBADMIN_USER=$PMA_DBADMIN_USER
PMA_DBADMIN_PASSWORD=$PMA_DBADMIN_PASS
GITHUB_REPO=$GITHUB_REPO
EOF
chmod 600 "$CREDENTIAL_FILE"

log "Validation finale de tous les composants"
check_installation || die "Installation terminee avec un ou plusieurs controles en echec. Voir le bilan ci-dessus."

cat <<EOF

===================================================================
 GLPI $GLPI_VERSION / AlmaLinux 10 : installation terminee
===================================================================
 GLPI            : http://$FQDN/
 phpMyAdmin      : http://$FQDN/phpmyadmin/
 API REST legacy : activee
 Git, wget, vim  : installes
 Depot Git local : $TP_REPO_DIR
 Repository      : https://github.com/$GITHUB_REPO
 Configuration   : $CREDENTIAL_FILE (root seulement)

 Gestionnaire        : glpi-tp
 Mise a jour         : glpi-tp update
 Modules disponibles : glpi-tp list
 Executer le module 01 : glpi-tp run 01

 ATTENTION : les modules ne sont pas executes automatiquement.
 Changer les mots de passe par defaut GLPI et MariaDB avant usage hors labo.
===================================================================
EOF
