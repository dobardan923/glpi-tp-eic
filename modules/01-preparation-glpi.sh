
#!/usr/bin/env bash
# =============================================================================
# GLPI TP EIC - MODULE 01
# Préparation du référentiel pédagogique
#
# Compatibilité : AlmaLinux / GLPI 12 / API REST legacy
# Dépôt : https://github.com/dobardan923/glpi-tp-eic
#
# Version : 1.2
#
# Corrections :
# - Pagination GLPI plus défensive
# - Arrêt sur page incomplète ou fin de résultats
# - Gestion des erreurs HTTP et JSON
# - Aucun message de création réussie sans ID valide
# - Pas de doublons volontaires
# - Aucune suppression ni réinitialisation des mots de passe existants
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

GLPI_ENTITY_ID="${GLPI_ENTITY_ID:-0}"
CURL_INSECURE="${CURL_INSECURE:-0}"

PAGE_SIZE=50
MAX_PAGES=200

SESSION_TOKEN=""

# =============================================================================
# AFFICHAGE
# =============================================================================

info() {
    printf '[INFO] %s\n' "$*" >&2
}

ok() {
    printf '[OK] %s\n' "$*" >&2
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

fail() {
    printf '[ERREUR] %s\n' "$*" >&2
    return 1
}

die() {
    fail "$*" || true
    exit 1
}

# =============================================================================
# PRÉREQUIS
# =============================================================================

check_requirements() {
    local cmd

    for cmd in curl jq mktemp; do
        command -v "$cmd" >/dev/null 2>&1 ||
            die "Commande manquante : $cmd"
    done

    [[ "$GLPI_ENTITY_ID" =~ ^[0-9]+$ ]] ||
        die "Identifiant d'entité invalide."

    ok "Prérequis vérifiés"
}

prepare_credentials() {
    if [[ -z "$GLPI_USER_TOKEN" && -z "$GLPI_PASSWORD" ]]; then
        read -r -s -p \
            "Mot de passe administrateur GLPI : " \
            GLPI_PASSWORD
        printf '\n' >&2
    fi

    if [[ -z "$TP_PASSWORD" ]]; then
        read -r -s -p \
            "Mot de passe initial des nouveaux comptes TP : " \
            TP_PASSWORD
        printf '\n' >&2
    fi

    [[ -n "$TP_PASSWORD" ]] ||
        die "Mot de passe pédagogique vide."
}

# =============================================================================
# HTTP
# =============================================================================

CURL_OPTS=(
    --silent
    --show-error
    --connect-timeout 10
    --max-time 90
)

if [[ "$CURL_INSECURE" == "1" ]]; then
    CURL_OPTS+=(--insecure)
fi

API_HEADERS=(
    -H "Content-Type: application/json"
)

if [[ -n "$GLPI_APP_TOKEN" ]]; then
    API_HEADERS+=(
        -H "App-Token: $GLPI_APP_TOKEN"
    )
fi

# Effectue une requête API et renvoie son JSON.
# Tous les autres messages passent par stderr.

api_request() {
    local method="$1"
    local endpoint="$2"
    local payload="${3-}"

    local tmp status response
    tmp="$(mktemp)"

    local options=(
        "${CURL_OPTS[@]}"
        "${API_HEADERS[@]}"
        -H "Session-Token: $SESSION_TOKEN"
        -X "$method"
        -o "$tmp"
        -w '%{http_code}'
    )

    if [[ -n "$payload" ]]; then
        options+=(--data-binary "$payload")
    fi

    if ! status="$(
        curl "${options[@]}" "${API_URL}/${endpoint}"
    )"; then
        rm -f "$tmp"
        fail "Connexion impossible : $method $endpoint"
        return 1
    fi

    response="$(cat "$tmp")"
    rm -f "$tmp"

    case "$status" in
        200|201|206)
            ;;
        *)
            fail "HTTP $status : $method $endpoint"
            printf '%s\n' "$response" >&2
            return 1
            ;;
    esac

    if ! jq -e . >/dev/null 2>&1 <<<"$response"; then
        fail "Réponse JSON invalide : $endpoint"
        return 1
    fi

    if jq -e '
        type == "array"
        and length > 0
        and (.[0] | type == "string")
        and (.[0] | startswith("ERROR"))
    ' >/dev/null 2>&1 <<<"$response"; then
        fail "Erreur métier GLPI : $response"
        return 1
    fi

    printf '%s\n' "$response"
}

# =============================================================================
# SESSION
# =============================================================================

open_session() {
    local tmp status response
    local auth=()

    info "Connexion à $API_URL"

    tmp="$(mktemp)"

    if [[ -n "$GLPI_USER_TOKEN" ]]; then
        auth+=(
            -H "Authorization: user_token $GLPI_USER_TOKEN"
        )
    else
        auth+=(
            -u "$GLPI_LOGIN:$GLPI_PASSWORD"
        )
    fi

    if ! status="$(
        curl "${CURL_OPTS[@]}" \
            "${API_HEADERS[@]}" \
            "${auth[@]}" \
            -o "$tmp" \
            -w '%{http_code}' \
            "$API_URL/initSession"
    )"; then
        rm -f "$tmp"
        die "Impossible de contacter l'API."
    fi

    response="$(cat "$tmp")"
    rm -f "$tmp"

    if [[ "$status" != "200" ]]; then
        die "Authentification refusée : HTTP $status : $response"
    fi

    SESSION_TOKEN="$(
        jq -r '.session_token // empty' <<<"$response"
    )"

    [[ -n "$SESSION_TOKEN" ]] ||
        die "GLPI n'a pas retourné de session_token."

    ok "Session GLPI ouverte"
}

close_session() {
    if [[ -n "$SESSION_TOKEN" ]]; then
        curl "${CURL_OPTS[@]}" \
            "${API_HEADERS[@]}" \
            -H "Session-Token: $SESSION_TOKEN" \
            "$API_URL/killSession" \
            >/dev/null 2>&1 || true
    fi
}

trap close_session EXIT

# =============================================================================
# LECTURE PAGINÉE
# =============================================================================

get_all() {
    local itemtype="$1"
    local offset=0
    local page_number=0
    local end status count total
    local page range_header

    local body_file headers_file

    while (( page_number < MAX_PAGES )); do
        end=$((offset + PAGE_SIZE - 1))

        body_file="$(mktemp)"
        headers_file="$(mktemp)"

        if ! status="$(
            curl "${CURL_OPTS[@]}" \
                "${API_HEADERS[@]}" \
                -H "Session-Token: $SESSION_TOKEN" \
                -D "$headers_file" \
                -o "$body_file" \
                -w '%{http_code}' \
                "$API_URL/$itemtype?range=$offset-$end"
        )"; then
            rm -f "$body_file" "$headers_file"
            fail "Lecture impossible : $itemtype"
            return 1
        fi

        page="$(cat "$body_file")"

        if [[ "$status" != "200" && "$status" != "206" ]]; then
            rm -f "$body_file" "$headers_file"
            fail "Lecture $itemtype : HTTP $status : $page"
            return 1
        fi

        if ! jq -e 'type == "array"' \
            >/dev/null 2>&1 <<<"$page"; then
            rm -f "$body_file" "$headers_file"
            fail "Format de réponse inattendu pour $itemtype"
            return 1
        fi

        count="$(jq 'length' <<<"$page")"

        range_header="$(
            tr -d '\r' <"$headers_file" |
                grep -i '^Content-Range:' |
                tail -n 1 || true
        )"

        rm -f "$body_file" "$headers_file"

        # Certaines installations peuvent retourner une
        # page vide lorsqu'on atteint les résultats disponibles.
        # On termine sans effectuer une nouvelle requête.
        if (( count == 0 )); then
            if (( offset > 0 )); then
                warn "$itemtype : fin de pagination à $offset"
            fi
            return 0
        fi

        # Chaque objet est émis sur une ligne JSON.
        jq -c '.[]' <<<"$page"

        offset=$((offset + count))
        page_number=$((page_number + 1))

        # Ne pas poursuivre après une page incomplète.
        # C'est la correction principale.
        if (( count < PAGE_SIZE )); then
            return 0
        fi

        # Exploiter le total annoncé par GLPI s'il existe.
        if [[ "$range_header" =~ /([0-9]+)[[:space:]]*$ ]]; then
            total="${BASH_REMATCH[1]}"

            if (( offset >= total )); then
                return 0
            fi
        fi
    done

    fail "Limite de pagination atteinte : $itemtype"
    return 1
}

# =============================================================================
# RECHERCHE
# =============================================================================

find_by_name() {
    local itemtype="$1"
    local name="$2"

    get_all "$itemtype" |
        jq -sr --arg name "$name" '
            [.[] | select(.name == $name)]
            | if length > 1 then
                error("Plusieurs objets portent le nom " + $name)
              else
                .[0].id // empty
              end
        '
}

find_child() {
    local itemtype="$1"
    local name="$2"
    local parent_field="$3"
    local parent_id="$4"

    get_all "$itemtype" |
        jq -sr \
            --arg name "$name" \
            --arg field "$parent_field" \
            --arg parent "$parent_id" '
            [
                .[]
                | select(
                    .name == $name
                    and (.[$field] | tostring) == $parent
                )
            ]
            | if length > 1 then
                error("Doublons hiérarchiques : " + $name)
              else
                .[0].id // empty
              end
        '
}

# =============================================================================
# CRÉATION D'OBJETS
# =============================================================================

create_object() {
    local itemtype="$1"
    local object="$2"
    local payload response id

    if ! jq -e 'type == "object"' \
        >/dev/null 2>&1 <<<"$object"; then
        fail "JSON invalide pour $itemtype"
        return 1
    fi

    payload="$(
        jq -nc --argjson input "$object" '{input:$input}'
    )" || return 1

    response="$(
        api_request POST "$itemtype" "$payload"
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
        fail "Aucun ID valide après création de $itemtype"
        printf '%s\n' "$response" >&2
        return 1
    fi

    printf '%s\n' "$id"
}

ensure_simple() {
    local itemtype="$1"
    local name="$2"
    local extra='{}'
    local id object

    if (( $# >= 3 )); then
        extra="$3"
    fi

    id="$(find_by_name "$itemtype" "$name")" ||
        return 1

    if [[ -n "$id" ]]; then
        ok "$itemtype : $name existe (ID $id)"
        printf '%s\n' "$id"
        return 0
    fi

    object="$(
        jq -nc \
            --arg name "$name" \
            --argjson extra "$extra" \
            '$extra + {name:$name}'
    )" || return 1

    id="$(create_object "$itemtype" "$object")" ||
        return 1

    ok "$itemtype : $name créé (ID $id)"
    printf '%s\n' "$id"
}

ensure_tree() {
    local itemtype="$1"
    local name="$2"
    local field="$3"
    local parent_id="$4"
    local extra='{}'
    local id object

    if (( $# >= 5 )); then
        extra="$5"
    fi

    id="$(
        find_child "$itemtype" "$name" "$field" "$parent_id"
    )" || return 1

    if [[ -n "$id" ]]; then
        ok "$itemtype : $name existe (ID $id)"
        printf '%s\n' "$id"
        return 0
    fi

    object="$(
        jq -nc \
            --arg name "$name" \
            --arg field "$field" \
            --argjson parent "$parent_id" \
            --argjson extra "$extra" '
            $extra + {
                name:$name,
                ($field):$parent
            }
        '
    )" || return 1

    id="$(create_object "$itemtype" "$object")" ||
        return 1

    ok "$itemtype : $name créé (ID $id)"
    printf '%s\n' "$id"
}

# =============================================================================
# PROFILS ET HABILITATIONS
# =============================================================================

get_profile_id() {
    local profile="$1"
    local id

    id="$(find_by_name Profile "$profile")" ||
        return 1

    if [[ -z "$id" ]]; then
        fail "Profil GLPI inexistant : $profile"
        return 1
    fi

    printf '%s\n' "$id"
}

ensure_profile() {
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
        ok "Habilitation $profile_name déjà présente"
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
    )" || return 1

    create_object Profile_User "$object" >/dev/null ||
        return 1

    ok "Habilitation $profile_name attribuée"
}

# =============================================================================
# UTILISATEURS
# =============================================================================

ensure_user_email() {
    local user_id="$1"
    local email="$2"
    local existing object

    existing="$(
        api_request GET "User/$user_id/UserEmail" |
            jq -r --arg email "$email" '
                [.[] | select(.email == $email)]
                | .[0].id // empty
            '
    )" || return 1

    if [[ -n "$existing" ]]; then
        ok "E-mail $email déjà présent"
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
    )" || return 1

    create_object UserEmail "$object" >/dev/null ||
        return 1

    ok "E-mail $email ajouté"
}

ensure_user() {
    local login="$1"
    local family="$2"
    local firstname="$3"
    local email="$4"
    local profile="$5"
    local id object

    id="$(find_by_name User "$login")" ||
        return 1

    if [[ -z "$id" ]]; then
        object="$(
            jq -nc \
                --arg login "$login" \
                --arg family "$family" \
                --arg firstname "$firstname" \
                --arg password "$TP_PASSWORD" '
                {
                    name:$login,
                    realname:$family,
                    firstname:$firstname,
                    password:$password,
                    password2:$password,
                    is_active:1,
                    authtype:1
                }
            '
        )" || return 1

        id="$(create_object User "$object")" ||
            return 1

        ok "Utilisateur $login créé (ID $id)"
    else
        ok "Utilisateur $login existe (ID $id)"
    fi

    ensure_user_email "$id" "$email" ||
        return 1

    ensure_profile "$id" "$profile" ||
        return 1
}

# =============================================================================
# 1 - UTILISATEURS
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

# =============================================================================
# 2 - LIEUX
# =============================================================================

prepare_locations() {
    info "2/9 - Lieux EIC"

    local eic aile_a room

    eic="$(ensure_tree Location EIC locations_id 0)" ||
        return 1

    aile_a="$(
        ensure_tree Location "Aile A" locations_id "$eic"
    )" || return 1

    for room in A32 A33 A34 A36 "Local technique"; do
        ensure_tree Location "$room" locations_id "$aile_a" \
            >/dev/null || return 1
    done

    for room in \
        "Secrétariat" \
        "Direction" \
        "Stock informatique"
    do
        ensure_tree Location "$room" locations_id "$eic" \
            >/dev/null || return 1
    done
}

# =============================================================================
# 3 - TYPES MATÉRIELS
# =============================================================================

prepare_types() {
    info "3/9 - Types de matériel"

    local name

    for name in "PC fixe" "PC portable" "Mini PC"; do
        ensure_simple ComputerType "$name" >/dev/null ||
            return 1
    done

    ensure_simple MonitorType "Écran" >/dev/null ||
        return 1

    ensure_simple PrinterType "Imprimante" >/dev/null ||
        return 1

    ensure_simple NetworkEquipmentType "Switch" >/dev/null ||
        return 1

    ensure_simple NetworkEquipmentType \
        "Point d'accès Wi-Fi" >/dev/null || return 1

    ensure_simple PeripheralType \
        "Vidéoprojecteur" >/dev/null || return 1
}

# =============================================================================
# 4 - FABRICANTS
# =============================================================================

prepare_manufacturers() {
    info "4/9 - Fabricants"

    local name

    for name in \
        Dell HP Lenovo Acer Brother Epson Cisco Ubiquiti Samsung
    do
        ensure_simple Manufacturer "$name" >/dev/null ||
            return 1
    done
}

# =============================================================================
# 5 - MODÈLES PC
# =============================================================================

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
        ensure_simple ComputerModel "$name" >/dev/null ||
            return 1
    done
}

# =============================================================================
# 6 - SYSTÈMES D'EXPLOITATION
# =============================================================================

prepare_os() {
    info "6/9 - Systèmes d'exploitation"

    local name

    for name in \
        "Microsoft Windows" \
        AlmaLinux \
        Ubuntu
    do
        ensure_simple OperatingSystem "$name" >/dev/null ||
            return 1
    done

    for name in \
        "Windows 10 Pro" \
        "Windows 11 Pro" \
        "Windows 11 Education" \
        "AlmaLinux 9" \
        "AlmaLinux 10" \
        "Ubuntu 24.04 LTS"
    do
        ensure_simple OperatingSystemVersion "$name" \
            >/dev/null || return 1
    done
}

# =============================================================================
# 7 - STATUTS
# =============================================================================

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
        ensure_simple State "$name" >/dev/null ||
            return 1
    done
}

# =============================================================================
# 8 - CATÉGORIES ITIL
# =============================================================================

ITIL_OPTIONS='{
    "is_helpdeskvisible":1,
    "is_incident":1,
    "is_request":1
}'

category_group() {
    local parent_name="$1"
    shift

    local parent_id name

    parent_id="$(
        ensure_tree \
            ITILCategory \
            "$parent_name" \
            itilcategories_id \
            0 \
            "$ITIL_OPTIONS"
    )" || return 1

    for name in "$@"; do
        ensure_tree \
            ITILCategory \
            "$name" \
            itilcategories_id \
            "$parent_id" \
            "$ITIL_OPTIONS" >/dev/null || return 1
    done
}

prepare_categories() {
    info "8/9 - Catégories ITIL"

    category_group "Matériel" \
        "PC fixe" \
        "PC portable" \
        "Écran" \
        "Clavier / souris" \
        "Périphérique USB" || return 1

    category_group "Réseau" \
        "Réseau filaire" \
        "Wi-Fi" \
        "Internet" \
        "VPN" \
        "DNS / DHCP" || return 1

    category_group "Logiciel" \
        "Bureautique" \
        "Navigateur" \
        "Logiciel métier" \
        "Installation" \
        "Mise à jour" \
        "Licence" || return 1

    category_group "Accès" \
        "Compte utilisateur" \
        "Mot de passe" \
        "MFA" \
        "Droits d'accès" \
        "Dossier partagé" || return 1

    category_group "Impression" \
        "Impossible d'imprimer" \
        "File d'attente" \
        "Pilote" \
        "Consommable" || return 1

    category_group "Demande de service" \
        "Installation" \
        "Matériel" \
        "Accès" \
        "Information" || return 1

    category_group "Autre" \
        "Demande non classée" || return 1
}

# =============================================================================
# 9 - SOURCES DE DEMANDES
# =============================================================================

prepare_sources() {
    info "9/9 - Sources de demandes"

    local name

    for name in \
        "Portail GLPI" \
        "Email" \
        "Téléphone" \
        "Intervention directe" \
        "Demande orale" \
        "Supervision"
    do
        ensure_simple RequestType "$name" >/dev/null ||
            return 1
    done
}

# =============================================================================
# PROGRAMME PRINCIPAL
# =============================================================================

main() {
    echo
    echo "======================================================"
    echo " GLPI TP EIC - MODULE 01 - VERSION 1.2"
    echo "======================================================"
    echo

    check_requirements
    prepare_credentials
    open_session

    info "Vérification des profils"

    local profile

    for profile in \
        Self-Service Technician Hotliner Supervisor Observer
    do
        get_profile_id "$profile" >/dev/null ||
            die "Profil requis introuvable : $profile"
    done

    ok "Tous les profils nécessaires existent"

    prepare_users || die "Échec de préparation des utilisateurs"
    prepare_locations || die "Échec de préparation des lieux"
    prepare_types || die "Échec de préparation des types matériels"
    prepare_manufacturers || die "Échec des fabricants"
    prepare_models || die "Échec des modèles"
    prepare_os || die "Échec des systèmes d'exploitation"
    prepare_states || die "Échec des statuts"
    prepare_categories || die "Échec des catégories ITIL"
    prepare_sources || die "Échec des sources de demandes"

    echo
    echo "======================================================"
    echo " MODULE 01 TERMINÉ"
    echo "======================================================"
    echo
    echo "Référentiel pédagogique préparé :"
    echo
    echo "  8 utilisateurs et leurs habilitations"
    echo "  10 lieux"
    echo "  8 types de matériel"
    echo "  9 fabricants"
    echo "  8 modèles d'ordinateurs"
    echo "  3 familles de systèmes d'exploitation"
    echo "  6 versions de systèmes"
    echo "  11 statuts matériels"
    echo "  37 catégories ITIL"
    echo "  6 sources de demande"
    echo
    echo "Aucune donnée existante n'a été supprimée."
    echo "Les mots de passe existants ont été conservés."
    echo
    echo "Prochain module : 02-parc-informatique.sh"
    echo "======================================================"
}

main "$@"
