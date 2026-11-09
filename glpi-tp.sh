
#!/usr/bin/env bash
# =============================================================================
# GLPI TP EIC - Gestionnaire des travaux pratiques
#
# Environnement : AlmaLinux 10 / GLPI 12
# Dépôt GitHub   : dobardan923/glpi-tp-eic
#
# Commandes :
#   glpi-tp              Menu interactif
#   glpi-tp update       Télécharger les nouveautés
#   glpi-tp list         Lister les TP disponibles
#   glpi-tp run 01       Exécuter le module 01
#   glpi-tp run NOM      Exécuter un module par son nom
#   glpi-tp status       Informations sur le dépôt
#
# Sécurité :
#   - Dépôt GitHub défini explicitement
#   - Mises à jour sans écraser les modifications locales
#   - Vérification de syntaxe Bash
#   - Confirmation avant toute exécution
#   - Aucun secret enregistré
#   - Aucun script exécuté durant une mise à jour
# =============================================================================

set -Eeuo pipefail
umask 027

VERSION="1.0"

REPO_URL="https://github.com/dobardan923/glpi-tp-eic.git"
REPO_BRANCH="main"

BASE_DIR="/opt/glpi-tp"
REPO_DIR="${BASE_DIR}/repository"

# =============================================================================
# AFFICHAGE
# =============================================================================

info() {
    printf '[INFO] %s\n' "$*"
}

ok() {
    printf '[OK] %s\n' "$*"
}

warn() {
    printf '[ATTENTION] %s\n' "$*" >&2
}

die() {
    printf '[ERREUR] %s\n' "$*" >&2
    exit 1
}

pause() {
    printf '\n'
    read -r -p "Appuyer sur Entrée pour continuer..." _
}

# =============================================================================
# CONTRÔLES
# =============================================================================

check_dependencies() {
    local cmd

    for cmd in git bash find; do
        command -v "$cmd" >/dev/null 2>&1 ||
            die "Commande manquante : $cmd"
    done
}

check_root() {
    if (( EUID != 0 )); then
        die "Exécuter cette commande en root."
    fi
}

check_repository() {
    [[ -d "${REPO_DIR}/.git" ]] ||
        die "Dépôt absent. Exécuter : glpi-tp update"

    local origin

    origin="$(git -C "$REPO_DIR" remote get-url origin)" ||
        die "Impossible d'identifier le dépôt Git."

    [[ "$origin" == "$REPO_URL" ]] ||
        die "Dépôt Git inattendu : $origin"
}

# =============================================================================
# MISE À JOUR
# =============================================================================

update_repository() {
    check_root
    check_dependencies

    mkdir -p "$BASE_DIR"

    echo
    info "Synchronisation des TP depuis GitHub"
    info "Source : $REPO_URL"
    echo

    if [[ ! -e "$REPO_DIR" ]]; then

        info "Premier téléchargement..."

        git clone \
            --branch "$REPO_BRANCH" \
            --single-branch \
            "$REPO_URL" \
            "$REPO_DIR"

        ok "Dépôt téléchargé."

    else

        check_repository

        # On refuse de mettre à jour un dépôt modifié
        # localement afin de ne pas écraser le travail.
        if [[ -n "$(
            git -C "$REPO_DIR" status --porcelain
        )" ]]; then
            die "Modifications locales détectées dans le dépôt."
        fi

        info "Recherche des nouvelles versions..."

        git -C "$REPO_DIR" pull \
            --ff-only \
            origin "$REPO_BRANCH"

        ok "Synchronisation terminée."
    fi

    local revision

    revision="$(
        git -C "$REPO_DIR" rev-parse --short HEAD
    )"

    echo
    ok "Version Git : $revision"
    info "Fichiers : $REPO_DIR"
    echo

    info "Les scripts téléchargés n'ont pas été exécutés."
}

# =============================================================================
# DÉCOUVERTE DES MODULES
# =============================================================================

# Les modules sont recherchés uniquement dans :
#   modules/
#   scenarios/
#
# Les scripts placés ailleurs ne sont pas exécutables
# avec ce lanceur.

get_scripts() {
    local directory

    for directory in \
        "$REPO_DIR/modules" \
        "$REPO_DIR/scenarios"
    do
        if [[ -d "$directory" ]]; then
            find "$directory" \
                -maxdepth 1 \
                -type f \
                -name '*.sh' \
                -print
        fi
    done | sort
}

# =============================================================================
# LISTE DES TP
# =============================================================================

list_modules() {
    check_repository

    local file
    local count=0
    local relative

    echo
    echo "===================================================="
    echo " TRAVAUX PRATIQUES DISPONIBLES"
    echo "===================================================="
    echo

    while IFS= read -r file; do
        [[ -n "$file" ]] || continue

        relative="${file#"$REPO_DIR"/}"

        printf '  %-40s\n' "$relative"

        count=$((count + 1))

    done < <(get_scripts)

    echo

    if (( count == 0 )); then
        warn "Aucun module disponible."
    else
        ok "$count script(s) disponible(s)."
    fi

    echo
}

# =============================================================================
# RECHERCHE D'UN MODULE
# =============================================================================

resolve_module() {
    local search="$1"
    local file
    local name
    local short_name

    local matches=()

    # Empêcher les chemins arbitraires, les options
    # et les caractères spéciaux.
    [[ "$search" =~ ^[a-zA-Z0-9_-]+(\.sh)?$ ]] ||
        die "Nom de module invalide."

    while IFS= read -r file; do
        [[ -n "$file" ]] || continue

        name="$(basename "$file")"
        short_name="${name%.sh}"

        if [[ "$search" == "$name" ]] ||
           [[ "$search" == "$short_name" ]] ||
           [[ "$short_name" == "$search"-* ]]; then

            matches+=("$file")
        fi

    done < <(get_scripts)

    if (( ${#matches[@]} == 0 )); then
        die "Module introuvable : $search"
    fi

    if (( ${#matches[@]} > 1 )); then
        warn "Plusieurs modules correspondent à : $search"

        printf '  %s\n' "${matches[@]}"
        exit 1
    fi

    printf '%s\n' "${matches[0]}"
}

# =============================================================================
# EXÉCUTION D'UN TP
# =============================================================================

run_module() {
    local name="$1"
    local script
    local answer

    check_root
    check_dependencies
    check_repository

    script="$(resolve_module "$name")"

    echo
    echo "===================================================="
    echo " EXECUTION D'UN TRAVAIL PRATIQUE"
    echo "===================================================="
    echo

    info "Module : ${script#"$REPO_DIR"/}"

    # Le script doit être syntaxiquement valide.
    if ! bash -n "$script"; then
        die "Erreur de syntaxe dans le module."
    fi

    ok "Syntaxe Bash valide."

    echo
    warn "Ce module peut modifier la base GLPI."
    warn "Exécuter uniquement les modules validés par le professeur."
    echo

    read -r -p "Confirmer l'exécution ? [o/N] : " answer

    case "$answer" in
        o|O|oui|OUI)
            ;;
        *)
            info "Exécution annulée."
            return 0
            ;;
    esac

    echo
    info "Démarrage du module..."
    echo

    if bash "$script"; then
        echo
        ok "Module terminé avec succès."
    else
        die "Le module a échoué."
    fi
}

# =============================================================================
# ÉTAT DU DÉPÔT
# =============================================================================

repository_status() {
    check_repository

    echo
    echo "===================================================="
    echo " ETAT DU DEPOT GLPI TP"
    echo "===================================================="
    echo

    printf 'Dépôt     : %s\n' "$REPO_URL"
    printf 'Répertoire: %s\n' "$REPO_DIR"

    printf 'Branche   : %s\n' "$(
        git -C "$REPO_DIR" branch --show-current
    )"

    printf 'Révision  : %s\n' "$(
        git -C "$REPO_DIR" rev-parse --short HEAD
    )"

    printf 'Date      : %s\n' "$(
        git -C "$REPO_DIR" log -1 --format=%ci
    )"

    printf 'Modules   : %s\n' "$(
        get_scripts | grep -c . || true
    )"

    echo
}

# =============================================================================
# MENU INTERACTIF
# =============================================================================

interactive_menu() {
    local choice
    local module
    local files=()
    local index

    while true; do

        echo
        echo "===================================================="
        echo " GLPI TP EIC - GESTIONNAIRE v$VERSION"
        echo "===================================================="
        echo
        echo "  1. Télécharger / mettre à jour les TP"
        echo "  2. Afficher les TP disponibles"
        echo "  3. Exécuter un TP"
        echo "  4. Informations sur le dépôt"
        echo "  0. Quitter"
        echo

        read -r -p "Votre choix : " choice

        case "$choice" in
            1)
                update_repository
                pause
                ;;

            2)
                list_modules
                pause
                ;;

            3)
                check_repository

                files=()

                while IFS= read -r module; do
                    [[ -n "$module" ]] || continue
                    files+=("$module")
                done < <(get_scripts)

                if (( ${#files[@]} == 0 )); then
                    warn "Aucun TP disponible."
                    pause
                    continue
                fi

                echo
                echo "Choisir un TP :"
                echo

                for index in "${!files[@]}"; do
                    printf '  %2d. %s\n' \
                        "$((index + 1))" \
                        "${files[$index]#"$REPO_DIR"/}"
                done

                echo
                read -r -p "Numéro du TP (0 = retour) : " choice

                if [[ "$choice" == "0" ]]; then
                    continue
                fi

                if [[ ! "$choice" =~ ^[0-9]+$ ]]; then
                    warn "Numéro invalide."
                    continue
                fi

                index=$((10#$choice - 1))

                if (( index < 0 || index >= ${#files[@]} )); then
                    warn "Numéro hors limites."
                    continue
                fi

                module="$(basename "${files[$index]}")"
                run_module "$module"

                pause
                ;;

            4)
                repository_status
                pause
                ;;

            0)
                echo "Fin du programme."
                return 0
                ;;

            *)
                warn "Choix invalide."
                ;;
        esac
    done
}

# =============================================================================
# AIDE
# =============================================================================

show_help() {
    cat <<EOF
GLPI TP EIC - Gestionnaire v${VERSION}

Utilisation :

  glpi-tp                  Menu interactif
  glpi-tp update           Télécharger ou actualiser les TP
  glpi-tp list             Afficher les modules
  glpi-tp run 01           Exécuter le module 01
  glpi-tp run NOM          Exécuter un module
  glpi-tp status           État du dépôt
  glpi-tp help             Afficher cette aide

Dépôt GitHub :
  ${REPO_URL}

Répertoire local :
  ${REPO_DIR}
EOF
}

# =============================================================================
# PROGRAMME PRINCIPAL
# =============================================================================

main() {
    case "${1:-menu}" in

        menu)
            interactive_menu
            ;;

        update)
            update_repository
            ;;

        list)
            list_modules
            ;;

        run)
            [[ $# -ge 2 ]] ||
                die "Indiquer le module : glpi-tp run 01"

            run_module "$2"
            ;;

        status)
            repository_status
            ;;

        help|-h|--help)
            show_help
            ;;

        *)
            die "Commande inconnue. Utiliser : glpi-tp help"
            ;;
    esac
}

main "$@"
