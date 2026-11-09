
#!/usr/bin/env bash
# =============================================================================
# GLPI TP EIC - Module 01 : Préparation initiale
#
# Environnement : AlmaLinux / GLPI 12
# API           : REST legacy (/apirest.php)
# Projet        : https://github.com/dobardan923/glpi-tp-eic
#
# Ce script :
#   1. Vérifie l'API GLPI
#   2. Crée ou vérifie les utilisateurs
#   3. Attribue les habilitations manquantes
#   4. Prépare les lieux de l'EIC
#   5. Prépare les types de matériel
#   6. Prépare les fabricants
#   7. Prépare les modèles d'ordinateurs
#   8. Prépare les OS et leurs versions
#   9. Prépare les statuts
#  10. Prépare les catégories ITIL
#  11. Prépare les sources de demandes
#
# Principes :
#   - Ne supprime aucun élément.
#   - Ne change aucun mot de passe existant.
#   - Ne crée pas volontairement de doublons.
#   - Ne modifie pas les objets existants.
#   - Arrête le traitement si l'API refuse une opération.
#
# Les tickets et les équipements seront ajoutés dans d'autres modules.
# =============================================================================

set -Eeuo pipefail
umask 077

# =============================================================================
# CONFIGURATION
# =============================================================================

GLPI_URL="${GLPI_URL:-http://127.0.0.1}"
GLPI_URL="${GLPI_URL%/}"

API_URL="${GLPI_URL}/apirest.php"

GLPI_LOGIN="${GLPI_LOGIN:-glpi}"
GLPI_PASSWORD="${GLPI_PASSWORD:-}"
GLPI_USER_TOKEN="${GLPI_USER_TOKEN:-}"
GLPI_APP_TOKEN="${GLPI_APP_TOKEN:-}"

TP_PASSWORD="${TP_PASSWORD:-}"

# Entité racine
GLPI_ENTITY_ID="${GLPI_ENTITY_ID:-0}"

# 1 uniquement si certificat auto-signé dans le laboratoire
CURL_INSECURE="${CURL_INSECURE:-0}"

# Taille de page utilisée pour les listes GLPI
PAGE_SIZE=50

# =============================================================================
# JOURNALISATION
# =============================================================================

info() {
    printf '[INFO] %s\n' "$*" >&2
}

success() {
    printf '[OK] %s\n' "$*" >&2
}

warning() {
    printf '[WARN] %s\n' "$*" >&2
}

error() {
    printf '[ERREUR] %s\n' "$*" >&2
}

fatal() {
    error "$*"
    exit 1
}

# =============================================================================
# PRÉREQUIS
# =============================================================================

check_requirements() {
    local command_name

    for command_name in curl jq mktemp; do
        command -v "$command_name" >/dev/null 2>&1 ||
            fatal "Commande manquante : $command_name"
    done

    [[ "$GLPI_ENTITY_ID" =~ ^[0-9]+$ ]] ||
        fatal "GLPI_ENTITY_ID doit être un entier."

    info "Prérequis vérifiés."
}

# =============================================================================
# PRÉPARATION DES IDENTIFIANTS
# =============================================================================

prepare_credentials() {
    if [[ -z "$GLPI_USER_TOKEN" && -z "$GLPI_PASSWORD" ]]; then
        read -r -s -p "Mot de passe administrateur GLPI : " GLPI_PASSWORD
        printf '\n' >&2
    fi

    if [[ -z "$GLPI_USER_TOKEN" && -z "$GLPI_PASSWORD" ]]; then
        fatal "Mot de passe GLPI absent."
    fi

    # Un mot de passe pédagogique est nécessaire uniquement
    # pour les utilisateurs qui n'existent pas encore.
    #
    # Il est demandé à chaque lancement mais n'est jamais
    # appliqué aux utilisateurs existants.
    if [[ -z "$TP_PASSWORD" ]]; then
        read -r -s -p "Mot de passe initial des NOUVEAUX comptes TP : " TP_PASSWORD
        printf '\n' >&2
    fi

    [[ -n "$TP_PASSWORD" ]] ||
        fatal "Le mot de passe pédagogique ne peut pas être vide."
}

# =============================================================================
# CONFIGURATION CURL
# =============================================================================

CURL_OPTIONS=(
    --silent
    --show-error
    --connect-timeout 10
    --max-time 90
)

if [[ "$CURL_INSECURE" == "1" ]]; then
    CURL_OPTIONS+=(--insecure)
fi

API_HEADERS=(
    -H "Content-Type: application/json"
)

if [[ -n "$GLPI_APP_TOKEN" ]]; then
    API_HEADERS+=(
        -H "App-Token: $GLPI_APP_TOKEN"
    )
fi

SESSION_TOKEN=""

# =============================================================================
# REQUÊTE HTTP CONTRÔLÉE
# =============================================================================

http_request() {
    local method="$1"
    local endpoint="$2"
    local payload="${3-}"

    local body_file
    local headers_file
    local status
    local response

    body_file="$(mktemp)"
    headers_file="$(mktemp)"

    local request_options=(
        "${CURL_OPTIONS[@]}"
        "${API_HEADERS[@]}"
        -X "$method"
        -D "$headers_file"
        -o "$body_file"
        -w '%{http_code}'
    )

    if [[ -n "$SESSION_TOKEN" ]]; then
        request_options+=(
            -H "Session-Token: $SESSION_TOKEN"
        )
    fi

    if [[ -n "$payload" ]]; then
        request_options+=(
            --data-binary "$payload"
        )
    fi

    if ! status="$(
        curl "${request_options[@]}" \
            "${API_URL}/${endpoint}"
    )"; then
        rm -f "$body_file" "$headers_file"
        error "Échec de communication : $method $endpoint"
        return 1
    fi

    response="$(cat "$body_file")"

    rm -f "$body_file" "$headers_file"

    case "$status" in
        200|201|206)
            ;;
        *)
            error "HTTP $status : $method $endpoint"
            error "Réponse GLPI : $response"
            return 1
            ;;
    esac

    if ! jq -e . >/dev/null 2>&1 <<<"$response"; then
        error "Réponse non JSON : $endpoint"
        return 1
    fi

    # GLPI peut retourner une erreur métier sous forme
    # d'un tableau JSON.
    if jq -e '
        type == "array"
        and length > 0
        and (.[0] | type == "string")
        and (.[0] | startswith("ERROR"))
    ' >/dev/null <<<"$response"; then
        error "Erreur API GLPI : $response"
        return 1
    fi

    printf '%s\n' "$response"
}

# =============================================================================
# SESSION GLPI
# =============================================================================

open_session() {
    local body_file status response

    info "Connexion à $API_URL"

    body_file="$(mktemp)"

    local authentication=()

    if [[ -n "$GLPI_USER_TOKEN" ]]; then
        authentication+=(
            -H "Authorization: user_token $GLPI_USER_TOKEN"
        )
    else
        authentication+=(
            -u "$GLPI_LOGIN:$GLPI_PASSWORD"
        )
    fi

    if ! status="$(
        curl "${CURL_OPTIONS[@]}" \
            "${API_HEADERS[@]}" \
            "${authentication[@]}" \
            -o "$body_file" \
            -w '%{http_code}' \
            "$API_URL/initSession"
    )"; then
        rm -f "$body_file"
        fatal "Impossible de contacter l'API."
    fi

    response="$(cat "$body_file")"
    rm -f "$body_file"

    if [[ "$status" != "200" ]]; then
        fatal "Connexion refusée (HTTP $status) : $response"
    fi

    SESSION_TOKEN="$(
        jq -r '.session_token // empty' <<<"$response"
    )"

    [[ -n "$SESSION_TOKEN" ]] ||
        fatal "GLPI n'a retourné aucun Session-Token."

    success "Session GLPI ouverte."
}

close_session() {
    if [[ -n "$SESSION_TOKEN" ]]; then
        curl "${CURL_OPTIONS[@]}" \
            "${API_HEADERS[@]}" \
            -H "Session-Token: $SESSION_TOKEN" \
            "$API_URL/killSession" \
            >/dev/null 2>&1 || true
    fi
}

trap close_session EXIT

# =============================================================================
# RECHERCHE DES OBJETS
# =============================================================================

# Pour les référentiels pédagogiques, les listes restent petites.
#
# Une pagination est conservée pour les utilisateurs et les
# habilitations, qui peuvent être plus nombreux.
#
# Pour les pages complètes, on regarde aussi le total déclaré
# dans Content-Range afin de ne pas envoyer une requête hors plage.

get_all() {
    local type="$1"
    local offset=0
    local end
    local body_file headers_file
    local status page count total range_header

    while :; do
        end=$((offset + PAGE_SIZE - 1))

        body_file="$(mktemp)"
        headers_file="$(mktemp)"

        if ! status="$(
            curl "${CURL_OPTIONS[@]}" \
                "${API_HEADERS[@]}" \
                -H "Session-Token: $SESSION_TOKEN" \
                -D "$headers_file" \
                -o "$body_file" \
                -w '%{http_code}' \
                "$API_URL/$type?range=$offset-$end"
        )"; then
            rm -f "$body_file" "$headers_file"
            error "Échec de lecture de $type"
            return 1
        fi

        page="$(cat "$body_file")"

        if [[ "$status" != "200" && "$status" != "206" ]]; then
            error "Lecture de $type : HTTP $status"
            error "$page"
            rm -f "$body_file" "$headers_file"
            return 1
        fi

        if ! jq -e 'type == "array"' \
            >/dev/null 2>&1 <<<"$page"; then
            error "Réponse inattendue pour $type : $page"
            rm -f "$body_file" "$headers_file"
            return 1
        fi

        jq -c '.[]' <<<"$page"

        count="$(jq 'length' <<<"$page")"

        range_header="$(
            tr -d '\r' <"$headers_file" |
                grep -i '^Content-Range:' |
                tail -n 1 || true
        )"

        rm -f "$body_file" "$headers_file"

        if [[ "$range_header" =~ /([0-9]+)[[:space:]]*$ ]]; then
            total="${BASH_REMATCH[1]}"

            offset=$((offset + count))

            (( offset >= total )) && break

        else
            # Absence de Content-Range : fonctionnement
            # de secours sur la taille des pages.
            (( count < PAGE_SIZE )) && break

            offset=$((offset + count))
        fi

        (( count > 0 )) ||
            fatal "Pagination bloquée pour $type."
    done
}

find_named_item() {
    local type="$1"
    local name="$2"

    local result
    result="$(
        get_all "$type" |
            jq -sr --arg name "$name" '
                [.[] | select(.name == $name)]
                | if length > 1 then
                    error("Nom non unique : " + $name)
                  else
                    .[0].id // empty
                  end
            '
    )" || return 1

    printf '%s\n' "$result"
}

find_child_item() {
    local type="$1"
    local name="$2"
    local parent_field="$3"
    local parent_id="$4"

    get_all "$type" |
        jq -sr \
            --arg name "$name" \
            --arg field "$parent_field" \
            --arg parent "$parent_id" '
            [
                .[]
                | select(
                    .name == $name
                    and ((.[$field] | tostring) == $parent)
                )
            ]
            | if length > 1 then
                error("Plusieurs objets identiques : " + $name)
              else
                .[0].id // empty
              end
        '
}

# =============================================================================
# CRÉATION DES OBJETS
# =============================================================================

create_object() {
    local type="$1"
    local object="$2"

    local payload response id

    jq -e 'type == "object"' \
        >/dev/null <<<"$object" ||
        fatal "Objet JSON invalide pour $type."

    payload="$(
        jq -nc \
            --argjson input "$object" \
            '{input:$input}'
    )" || return 1

    response="$(
        http_request POST "$type" "$payload"
    )" || return 1

    id="$(
        jq -r '
            if type == "object" then
                .id // empty
            elif type == "array" then
                .[0].id // empty
            else
                empty
            end
        ' <<<"$response"
    )"

    if [[ ! "$id" =~ ^[0-9]+$ ]]; then
        error "Création de $type sans identifiant valide."
        error "$response"
        return 1
    fi

    printf '%s\n' "$id"
}

# =============================================================================
# OBJET SIMPLE
# =============================================================================

ensure_simple() {
    local type="$1"
    local name="$2"

    # Ne pas utiliser ${3:-{}} :
    # cette expression peut produire du JSON invalide.
    local extra='{}'

    if (( $# >= 3 )); then
        extra="$3"
    fi

    local id object

    id="$(find_named_item "$type" "$name")" ||
        return 1

    if [[ -n "$id" ]]; then
        success "$type : $name existe (ID $id)"
        printf '%s\n' "$id"
        return 0
    fi

    object="$(
        jq -nc \
            --arg name "$name" \
            --argjson extra "$extra" \
            '$extra + {name:$name}'
    )" || return 1

    id="$(create_object "$type" "$object")" ||
        return 1

    success "$type : $name créé (ID $id)"
    printf '%s\n' "$id"
}

# =============================================================================
# OBJET HIÉRARCHIQUE
# =============================================================================

ensure_tree() {
    local type="$1"
    local name="$2"
    local parent_field="$3"
    local parent_id="$4"

    local extra='{}'

    if (( $# >= 5 )); then
        extra="$5"
    fi

    local id object

    id="$(
        find_child_item \
            "$type" \
            "$name" \
            "$parent_field" \
            "$parent_id"
    )" || return 1

    if [[ -n "$id" ]]; then
        success "$type : $name existe (ID $id)"
        printf '%s\n' "$id"
        return 0
    fi

    object="$(
        jq -nc \
            --arg name "$name" \
            --arg field "$parent_field" \
            --argjson parent "$parent_id" \
            --argjson extra "$extra" '
            $extra + {
                name:$name,
                ($field):$parent
            }
        '
    )" || return 1

    id="$(create_object "$type" "$object")" ||
        return 1

    success "$type : $name créé (ID $id)"
    printf '%s\n' "$id"
}

# =============================================================================
# UTILISATEURS ET HABILITATIONS
# =============================================================================

get_profile_id() {
    local profile="$1"
    local id

    id="$(find_named_item Profile "$profile")" ||
        return 1

    if [[ -z "$id" ]]; then
        error "Profil GLPI introuvable : $profile"
        return 1
    fi

    printf '%s\n' "$id"
}

ensure_profile_assignment() {
    local user_id="$1"
    local profile_name="$2"

    local profile_id existing object

    profile_id="$(get_profile_id "$profile_name")" ||
        return 1

    existing="$(
        get_all Profile_User |
            jq -sr \
                --arg uid "$user_id" \
                --arg pid "$profile_id" \
                --arg entity "$GLPI_ENTITY_ID" '
                [
                    .[]
                    | select(
                        (.users_id | tostring) == $uid
                        and (.profiles_id | tostring) == $pid
                        and (.entities_id | tostring) == $entity
                    )
                ][0].id // empty
            '
    )" || return 1

    if [[ -n "$existing" ]]; then
        success "Habilitation $profile_name déjà présente"
        return 0
    fi

    object="$(
        jq -nc \
            --argjson uid "$user_id" \
            --argjson pid "$profile_id" \
            --argjson entity "$GLPI_ENTITY_ID" '
            {
                users_id:$uid,
                profiles_id:$pid,
                entities_id:$entity,
                is_recursive:1
            }
        '
    )"

    create_object Profile_User "$object" >/dev/null ||
        return 1

    success "Habilitation $profile_name attribuée"
}

ensure_user_email() {
    local user_id="$1"
    local email="$2"

    local existing object

    # Lecture des adresses de cet utilisateur uniquement.
    existing="$(
        http_request GET "User/$user_id/UserEmail" |
            jq -r --arg email "$email" '
                [.[] | select(.email == $email)]
                | .[0].id // empty
            '
    )" || return 1

    if [[ -n "$existing" ]]; then
        success "E-mail $email déjà présent"
        return 0
    fi

    object="$(
        jq -nc \
            --argjson uid "$user_id" \
            --arg email "$email" '
            {
                users_id:$uid,
                email:$email,
                is_default:1
            }
        '
    )"

    create_object UserEmail "$object" >/dev/null ||
        return 1

    success "E-mail $email ajouté"
}

ensure_user() {
    local login="$1"
    local family_name="$2"
    local first_name="$3"
    local email="$4"
    local profile="$5"

    local id object

    id="$(find_named_item User "$login")" ||
        return 1

    if [[ -n "$id" ]]; then
        success "Utilisateur $login existe (ID $id)"
    else
        object="$(
            jq -nc \
                --arg login "$login" \
                --arg family "$family_name" \
                --arg first "$first_name" \
                --arg password "$TP_PASSWORD" '
                {
                    name:$login,
                    realname:$family,
                    firstname:$first,
                    password:$password,
                    password2:$password,
                    is_active:1,
                    authtype:1
                }
            '
        )"

        id="$(create_object User "$object")" ||
            return 1

        success "Utilisateur $login créé (ID $id)"
    fi

    ensure_user_email "$id" "$email" ||
        return 1

    ensure_profile_assignment "$id" "$profile" ||
        return 1
}

# =============================================================================
# MODULES DE DONNÉES
# =============================================================================

prepare_users() {
    info "1/9 - Utilisateurs et habilitations"

    ensure_user toto Dupont Thomas \
        toto@eic.local Self-Service

    ensure_user alice Martin Alice \
        alice@eic.local Self-Service

    ensure_user bob Lambert Bob \
        bob@eic.local Self-Service

    ensure_user tech1 Support Technicien1 \
        tech1@eic.local Technician

    ensure_user tech2 Support Technicien2 \
        tech2@eic.local Technician

    ensure_user hotline1 Support Hotline1 \
        hotline1@eic.local Hotliner

    ensure_user superviseur1 Support Superviseur1 \
        superviseur1@eic.local Supervisor

    ensure_user observateur1 Support Observateur1 \
        observateur1@eic.local Observer
}

prepare_locations() {
    info "2/9 - Lieux de l'EIC"

    local eic aile_a room

    eic="$(ensure_tree Location EIC locations_id 0)"

    aile_a="$(
        ensure_tree Location "Aile A" locations_id "$eic"
    )"

    for room in \
        A32 A33 A34 A36 "Local technique"
    do
        ensure_tree \
            Location "$room" locations_id "$aile_a" \
            >/dev/null
    done

    for room in \
        "Secrétariat" \
        "Direction" \
        "Stock informatique"
    do
        ensure_tree \
            Location "$room" locations_id "$eic" \
            >/dev/null
    done
}

prepare_types() {
    info "3/9 - Types de matériel"

    local name

    for name in \
        "PC fixe" \
        "PC portable" \
        "Mini PC"
    do
        ensure_simple ComputerType "$name" >/dev/null
    done

    ensure_simple MonitorType \
        "Écran" >/dev/null

    ensure_simple PrinterType \
        "Imprimante" >/dev/null

    ensure_simple NetworkEquipmentType \
        "Switch" >/dev/null

    ensure_simple NetworkEquipmentType \
        "Point d'accès Wi-Fi" >/dev/null

    ensure_simple PeripheralType \
        "Vidéoprojecteur" >/dev/null
}

prepare_manufacturers() {
    info "4/9 - Fabricants"

    local name

    for name in \
        Dell HP Lenovo Acer Brother Epson \
        Cisco Ubiquiti Samsung
    do
        ensure_simple Manufacturer "$name" >/dev/null
    done
}

prepare_models() {
    info "5/9 - Modèles d'ordinateurs"

    local name

    for name in \
        "OptiPlex 7010 SFF" \
        "Latitude 5450" \
        "ProDesk 400 G9 SFF" \
        "ProBook 450 G10" \
        "ThinkCentre M70s Gen 4" \
        "ThinkPad E14 Gen 5" \
        "Veriton X4710G" \
        "TravelMate P2"
    do
        ensure_simple ComputerModel "$name" >/dev/null
    done
}

prepare_operating_systems() {
    info "6/9 - Systèmes d'exploitation"

    local name

    for name in \
        "Microsoft Windows" \
        "AlmaLinux" \
        "Ubuntu"
    do
        ensure_simple OperatingSystem "$name" >/dev/null
    done

    for name in \
        "Windows 10 Pro" \
        "Windows 11 Pro" \
        "Windows 11 Education" \
        "AlmaLinux 9" \
        "AlmaLinux 10" \
        "Ubuntu 24.04 LTS"
    do
        ensure_simple OperatingSystemVersion "$name" >/dev/null
    done
}

prepare_states() {
    info "7/9 - Statuts matériels"

    local name

    for name in \
        "En stock" \
        "En préparation" \
        "En service" \
        "En prêt" \
        "En maintenance" \
        "En réparation" \
        "Défectueux" \
        "Retour garantie" \
        "Hors service" \
        "À recycler" \
        "Réformé"
    do
        ensure_simple State "$name" >/dev/null
    done
}

# =============================================================================
# CATÉGORIES ITIL
# =============================================================================

prepare_category_group() {
    local parent_name="$1"
    shift

    local parent_id name

    # Catégories accessibles au support et au portail.
    #
    # Selon la version de GLPI, d'autres paramètres
    # de visibilité peuvent également exister.
    local options='{
        "is_helpdeskvisible":1,
        "is_incident":1,
        "is_request":1
    }'

    parent_id="$(
        ensure_tree \
            ITILCategory \
            "$parent_name" \
            itilcategories_id \
            0 \
            "$options"
    )" || return 1

    for name in "$@"; do
        ensure_tree \
            ITILCategory \
            "$name" \
            itilcategories_id \
            "$parent_id" \
            "$options" \
            >/dev/null || return 1
    done
}

prepare_categories() {
    info "8/9 - Catégories ITIL"

    prepare_category_group "Matériel" \
        "PC fixe" \
        "PC portable" \
        "Écran" \
        "Clavier / souris" \
        "Périphérique USB"

    prepare_category_group "Réseau" \
        "Réseau filaire" \
        "Wi-Fi" \
        "Internet" \
        "VPN" \
        "DNS / DHCP"

    prepare_category_group "Logiciel" \
        "Bureautique" \
        "Navigateur" \
        "Logiciel métier" \
        "Installation" \
        "Mise à jour" \
        "Licence"

    prepare_category_group "Accès" \
        "Compte utilisateur" \
        "Mot de passe" \
        "MFA" \
        "Droits d'accès" \
        "Dossier partagé"

    prepare_category_group "Impression" \
        "Impossible d'imprimer" \
        "File d'attente" \
        "Pilote" \
        "Consommable"

    prepare_category_group "Demande de service" \
        "Installation" \
        "Matériel" \
        "Accès" \
        "Information"

    prepare_category_group "Autre" \
        "Demande non classée"
}

prepare_request_sources() {
    info "9/9 - Sources de demande"

    local name

    for name in \
        "Portail GLPI" \
        "Email" \
        "Téléphone" \
        "Intervention directe" \
        "Demande orale" \
        "Supervision"
    do
        ensure_simple RequestType "$name" >/dev/null
    done
}

# =============================================================================
# PROGRAMME PRINCIPAL
# =============================================================================

main() {
    echo
    echo "========================================================"
    echo " GLPI TP EIC - Module 01"
    echo " Préparation du référentiel pédagogique"
    echo "========================================================"
    echo

    check_requirements
    prepare_credentials
    open_session

    # On vérifie le compte et les profils avant de commencer.
    info "Vérification des profils nécessaires"

    local profile

    for profile in \
        Self-Service \
        Technician \
        Hotliner \
        Supervisor \
        Observer
    do
        get_profile_id "$profile" >/dev/null ||
            fatal "Profil requis indisponible : $profile"
    done

    success "Profils requis disponibles."

    echo

    prepare_users
    prepare_locations
    prepare_types
    prepare_manufacturers
    prepare_models
    prepare_operating_systems
    prepare_states
    prepare_categories
    prepare_request_sources

    echo
    echo "========================================================"
    echo " MODULE 01 TERMINÉ"
    echo "========================================================"
    echo
    echo "Référentiel traité :"
    echo
    echo "  - 8 utilisateurs et leurs habilitations"
    echo "  - 10 lieux"
    echo "  - 8 types de matériel"
    echo "  - 9 fabricants"
    echo "  - 8 modèles d'ordinateurs"
    echo "  - 3 familles de systèmes d'exploitation"
    echo "  - 6 versions de systèmes"
    echo "  - 11 statuts matériels"
    echo "  - 37 catégories ITIL (parents inclus)"
    echo "  - 6 sources de demande"
    echo
    echo "Les éléments préexistants ont été conservés."
    echo
    echo "Prochains modules :"
    echo "  02 - Parc informatique"
    echo "  03 - Tickets d'assistance"
    echo "  04 - Scénarios pédagogiques"
    echo
    echo "========================================================"
}

main "$@"
