#!/usr/bin/env bash
# GLPI TP EIC - 02 - Parc informatique autonome + rattrapage (v4.0)
# GLPI 12 / AlmaLinux 10 / API REST legacy (apirest.php)
# Ne depend d'aucun TP precedent : cree les referentiels manquants.
# Gere 11 actifs de rattrapage + 48 actifs complementaires et 4 anomalies.
# Relance sans reinjection des fiches existantes (ni PUT, ni DELETE).
# Usage : bash 02-parc-informatique.sh --check
#         bash 02-parc-informatique.sh --apply
set -Eeuo pipefail
umask 077

GLPI_URL="${GLPI_URL:-http://127.0.0.1}"
GLPI_URL="${GLPI_URL%/}"
API_URL="${GLPI_URL}/apirest.php"
GLPI_LOGIN="${GLPI_LOGIN:-glpi}"
GLPI_PASSWORD="${GLPI_PASSWORD:-}"
GLPI_USER_TOKEN="${GLPI_USER_TOKEN:-}"
GLPI_APP_TOKEN="${GLPI_APP_TOKEN:-}"
GLPI_ENTITY_ID="${GLPI_ENTITY_ID:-0}"
CURL_INSECURE="${CURL_INSECURE:-0}"
SESSION_TOKEN=""
WORKDIR=""

info() { printf '[INFO] %s\n' "$*" >&2; }
ok()   { printf '[OK] %s\n' "$*" >&2; }
warn() { printf '[ATTENTION] %s\n' "$*" >&2; }
die()  { printf '[ERREUR] %s\n' "$*" >&2; exit 1; }

for cmd in curl jq mktemp; do
  command -v "$cmd" >/dev/null 2>&1 || die "Commande manquante : $cmd"
done
[[ "$GLPI_ENTITY_ID" =~ ^[0-9]+$ ]] || die 'GLPI_ENTITY_ID invalide'

CURL_OPTS=(--silent --show-error --connect-timeout 10 --max-time 90)
[[ "$CURL_INSECURE" == 1 ]] && CURL_OPTS+=(--insecure)
HEADERS=(-H 'Content-Type: application/json')
[[ -n "$GLPI_APP_TOKEN" ]] && HEADERS+=(-H "App-Token: $GLPI_APP_TOKEN")

api() {
  local method="$1" endpoint="$2" payload="${3-}" tmp status response
  tmp="$(mktemp)"
  local args=("${CURL_OPTS[@]}" "${HEADERS[@]}" -H "Session-Token: $SESSION_TOKEN"
              -X "$method" -o "$tmp" -w '%{http_code}')
  [[ -n "$payload" ]] && args+=(--data-binary "$payload")
  if ! status="$(curl "${args[@]}" "$API_URL/$endpoint")"; then
    rm -f "$tmp"
    die "Communication API impossible : $endpoint"
  fi
  response="$(cat "$tmp")"; rm -f "$tmp"
  case "$status" in
    200|201|206) ;;
    *) die "HTTP $status ($method $endpoint) : $response" ;;
  esac
  jq -e . >/dev/null 2>&1 <<<"$response" || die "JSON invalide : $endpoint"
  if jq -e 'type == "array" and length > 0 and (.[0] | type) == "string" and (.[0] | startswith("ERROR"))' >/dev/null <<<"$response"; then
    die "Erreur GLPI : $response"
  fi
  printf '%s\n' "$response"
}

open_session() {
  local tmp status response
  tmp="$(mktemp)"
  if [[ -z "$GLPI_USER_TOKEN" && -z "$GLPI_PASSWORD" ]]; then
    read -r -s -p 'Mot de passe administrateur GLPI : ' GLPI_PASSWORD
    printf '\n' >&2
  fi
  [[ -n "$GLPI_USER_TOKEN" || -n "$GLPI_PASSWORD" ]] || die 'Identifiants GLPI absents'
  local args=("${CURL_OPTS[@]}" "${HEADERS[@]}" -o "$tmp" -w '%{http_code}')
  if [[ -n "$GLPI_USER_TOKEN" ]]; then
    args+=(-H "Authorization: user_token $GLPI_USER_TOKEN")
  else
    args+=(-u "$GLPI_LOGIN:$GLPI_PASSWORD")
  fi
  if ! status="$(curl "${args[@]}" "$API_URL/initSession")"; then
    rm -f "$tmp"
    die 'Connexion a l’API impossible'
  fi
  response="$(cat "$tmp")"; rm -f "$tmp"
  [[ "$status" == 200 ]] || die "Authentification refusee (HTTP $status) : $response"
  SESSION_TOKEN="$(jq -r '.session_token // empty' <<<"$response")"
  [[ -n "$SESSION_TOKEN" ]] || die 'Jeton de session absent'
  ok 'Session GLPI ouverte'
  # Cet endpoint peut repondre HTTP 200 sans contenu JSON.
  local entity_tmp entity_status entity_payload
  entity_tmp="$(mktemp)"
  entity_payload="$(jq -nc --argjson e "$GLPI_ENTITY_ID" '{entities_id:$e,is_recursive:false}')"
  if ! entity_status="$(curl "${CURL_OPTS[@]}" "${HEADERS[@]}" -H "Session-Token: $SESSION_TOKEN" \
       -X POST --data-binary "$entity_payload" -o "$entity_tmp" -w '%{http_code}' \
       "$API_URL/changeActiveEntities")"; then
    rm -f "$entity_tmp"
    die "Changement d'entite GLPI impossible"
  fi
  if [[ "$entity_status" != 200 ]]; then
    local entity_error
    entity_error="$(cat "$entity_tmp")"; rm -f "$entity_tmp"
    die "Entite $GLPI_ENTITY_ID inaccessible (HTTP $entity_status) : $entity_error"
  fi
  rm -f "$entity_tmp"
  ok "Entite active : $GLPI_ENTITY_ID"
}

close_session() {
  [[ -n "$SESSION_TOKEN" ]] || return 0
  curl "${CURL_OPTS[@]}" "${HEADERS[@]}" -H "Session-Token: $SESSION_TOKEN" \
    "$API_URL/killSession" >/dev/null 2>&1 || true
}

cleanup() {
  close_session
  [[ -z "$WORKDIR" ]] || rm -rf -- "$WORKDIR"
}
trap cleanup EXIT

# Lister tous les objets visibles du type demande (pagination legacy).
get_all() {
  local type="$1" start=0 end status tmp hdr result count range total page=0
  while (( page < 200 )); do
    end=$((start + 49))
    tmp="$(mktemp)"; hdr="$(mktemp)"
    if ! status="$(curl "${CURL_OPTS[@]}" "${HEADERS[@]}" \
        -H "Session-Token: $SESSION_TOKEN" -D "$hdr" -o "$tmp" \
        -w '%{http_code}' "$API_URL/$type?range=$start-$end")"; then
      rm -f "$tmp" "$hdr"
      die "Lecture impossible : $type"
    fi
    result="$(cat "$tmp")"
    case "$status" in
      200|206) ;;
      *) rm -f "$tmp" "$hdr"; die "Lecture $type HTTP $status : $result" ;;
    esac
    jq -e 'type == "array"' >/dev/null 2>&1 <<<"$result" || die "Liste JSON invalide : $type"
    count="$(jq 'length' <<<"$result")"
    range="$(tr -d '\r' < "$hdr" | grep -i '^Content-Range:' | tail -n 1 || true)"
    rm -f "$tmp" "$hdr"
    (( count > 0 )) || return 0
    jq -c '.[]' <<<"$result"
    start=$((start + count)); page=$((page + 1))
    if [[ "$range" =~ /([0-9]+)[[:space:]]*$ ]]; then
      total="${BASH_REMATCH[1]}"
      (( start < total )) || return 0
    else
      (( count == 50 )) || return 0
    fi
  done
  die "Pagination excessive : $type"
}

snapshot() {
  local type="$1"
  get_all "$type" > "$WORKDIR/$type.jsonl"
  jq -s '.' "$WORKDIR/$type.jsonl" > "$WORKDIR/$type.json" || die "Cache invalide : $type"
}

cache_add() {
  local type="$1" object="$2" tmp
  tmp="$(mktemp)"
  jq --argjson obj "$object" '. + [$obj]' "$WORKDIR/$type.json" > "$tmp" \
    || die "Mise a jour cache impossible : $type"
  mv -f "$tmp" "$WORKDIR/$type.json"
}

create() {
  local type="$1" object="$2" response id payload
  payload="$(jq -nc --argjson data "$object" '{input:$data}')"
  response="$(api POST "$type" "$payload")" || die "Creation interrompue : $type"
  id="$(jq -r 'if type == "object" then (.id // empty)
                 elif type == "array" then (.[0].id // empty)
                 else empty end' <<<"$response")"
  [[ "$id" =~ ^[0-9]+$ ]] || die "Creation non confirmee : $type / $response"
  printf '%s\n' "$id"
}

# Referentiels : reutiliser un nom existant OU le creer, sans jamais le modifier.
ensure_reference() {
  local type="$1" name="$2" ids count id obj
  ids="$(jq -c --arg n "$name" '[.[] | select(.name == $n and ((.is_deleted // 0)|tostring) != "1") | .id] | sort' "$WORKDIR/$type.json")"
  count="$(jq 'length' <<<"$ids")"
  if (( count > 0 )); then
    id="$(jq -r '.[0]' <<<"$ids")"
    (( count == 1 )) || warn "$type / $name : $count occurrences, reutilisation de l'ID $id"
    printf '%s\n' "$id"
    return 0
  fi
  obj="$(jq -nc --arg n "$name" '{name:$n,comment:"Cree par EIC TP module 02"}')"
  id="$(create "$type" "$obj")"
  cache_add "$type" "$(jq -nc --argjson id "$id" --arg n "$name" '{id:$id,name:$n}')"
  ok "Referentiel cree : $type / $name (ID $id)"
  printf '%s\n' "$id"
}

# Lieux hierarchiques : nom + parent + entite, pas seulement le nom.
ensure_location() {
  local name="$1" parent="$2" ids count id obj
  ids="$(jq -c --arg n "$name" --argjson p "$parent" --argjson e "$GLPI_ENTITY_ID" \
    '[.[] | select(.name == $n and ((.locations_id // 0)|tonumber) == $p
      and ((.entities_id // 0)|tonumber) == $e and ((.is_deleted // 0)|tostring) != "1") | .id] | sort' \
    "$WORKDIR/Location.json")"
  count="$(jq 'length' <<<"$ids")"
  if (( count > 0 )); then
    id="$(jq -r '.[0]' <<<"$ids")"
    (( count == 1 )) || warn "Lieu $name (parent $parent) : $count occurrences ; ID $id conserve"
    printf '%s\n' "$id"
    return 0
  fi
  obj="$(jq -nc --arg n "$name" --argjson p "$parent" --argjson e "$GLPI_ENTITY_ID" \
    '{name:$n,locations_id:$p,entities_id:$e,comment:"Cree par EIC TP module 02"}')"
  id="$(create Location "$obj")"
  cache_add Location "$(jq -nc --argjson id "$id" --arg n "$name" --argjson p "$parent" --argjson e "$GLPI_ENTITY_ID" \
    '{id:$id,name:$n,locations_id:$p,entities_id:$e}')"
  ok "Lieu cree : $name (parent $parent, ID $id)"
  printf '%s\n' "$id"
}

# Ces variables sont a zero pour generer un plan en lecture seule (--check).
# Elles sont remplacees par les IDs des referentiels apres creation (--apply).
eic=0 aile=0 a32=0 a33=0 a34=0 a36=0 stock=0 tech=0 sec=0 direction=0
pc=0 lap=0 mon=0 prn=0 sw=0
dell=0 hp=0 lenovo=0 brother=0 cisco=0
mdell=0 mhp=0 mlap=0 mmon=0 mprn=0 msw=0
active=0 spare=0

ensure_prerequisites() {
  info 'Creation/reutilisation des lieux et referentiels necessaires...'
  eic="$(ensure_location EIC 0)"
  aile="$(ensure_location 'Aile A' "$eic")"
  a32="$(ensure_location A32 "$aile")"
  a33="$(ensure_location A33 "$aile")"
  a34="$(ensure_location A34 "$aile")"
  a36="$(ensure_location A36 "$aile")"
  stock="$(ensure_location 'Stock informatique' "$eic")"
  tech="$(ensure_location 'Local technique' "$aile")"
  sec="$(ensure_location 'Secrétariat' "$eic")"
  direction="$(ensure_location Direction "$eic")"

  pc="$(ensure_reference ComputerType 'PC fixe')"
  lap="$(ensure_reference ComputerType 'PC portable')"
  mon="$(ensure_reference MonitorType 'Écran bureautique')"
  prn="$(ensure_reference PrinterType 'Imprimante laser')"
  sw="$(ensure_reference NetworkEquipmentType Switch)"

  dell="$(ensure_reference Manufacturer Dell)"
  hp="$(ensure_reference Manufacturer HP)"
  lenovo="$(ensure_reference Manufacturer Lenovo)"
  brother="$(ensure_reference Manufacturer Brother)"
  cisco="$(ensure_reference Manufacturer Cisco)"

  mdell="$(ensure_reference ComputerModel 'OptiPlex 7010 SFF')"
  mhp="$(ensure_reference ComputerModel 'ProDesk 400 G9 SFF')"
  mlap="$(ensure_reference ComputerModel 'ThinkPad E14 Gen 5')"
  mmon="$(ensure_reference MonitorModel P2422H)"
  mprn="$(ensure_reference PrinterModel HL-L5210DN)"
  msw="$(ensure_reference NetworkEquipmentModel CBS250-24T-4G)"

  active="$(ensure_reference State 'En service')"
  spare="$(ensure_reference State 'En stock')"
}

CURRENT_GROUP=manuel

# canonical : nom correct pedagogique ; input.name : nom effectivement injecte.
# reference_inventory : code attendu, meme si l'exercice impose un code vide.
plan_asset() {
  local family="$1" canonical="$2" name="$3" loc="$4" kind="$5"
  local manufacturer="$6" model="$7" state="$8" inventory="$9"
  local target_inventory="${10}" typekey modelkey
  case "$family" in
    Computer)         typekey=computertypes_id;        modelkey=computermodels_id ;;
    Monitor)          typekey=monitortypes_id;         modelkey=monitormodels_id ;;
    Printer)          typekey=printertypes_id;         modelkey=printermodels_id ;;
    NetworkEquipment) typekey=networkequipmenttypes_id; modelkey=networkequipmentmodels_id ;;
    *) die "Famille inconnue : $family" ;;
  esac
  jq -nc --arg group "$CURRENT_GROUP" --arg family "$family" --arg canonical "$canonical" --arg expected "$target_inventory" \
    --arg marker "EIC02:$canonical" --arg n "$name" --arg inventory "$inventory" --arg tk "$typekey" --arg mk "$modelkey" \
    --argjson e "$GLPI_ENTITY_ID" --argjson l "$loc" --argjson t "$kind" \
    --argjson ma "$manufacturer" --argjson mo "$model" --argjson st "$state" \
    '{group:$group,family:$family,canonical:$canonical,reference_inventory:$expected,marker:$marker,
      input:({name:$n,otherserial:$inventory,entities_id:$e,locations_id:$l,
        manufacturers_id:$ma,states_id:$st,
        comment:("EIC TP - module 02 ["+$marker+"]")} + {($tk):$t,($mk):$mo})}' \
    >> "$WORKDIR/plan.jsonl"
}

build_plan() {
  local room loc i canonical name actual_loc actual_state maker model code actual_code
  : > "$WORKDIR/plan.jsonl"
  CURRENT_GROUP=manuel
  # Exercice 6 : 11 actifs manuels a creer uniquement s'ils manquent.
  plan_asset Computer EIC-A32-PC01 EIC-A32-PC01 "$a32" "$pc" "$dell" "$mdell" "$active" EIC-INV-PC-A32-01 EIC-INV-PC-A32-01
  plan_asset Computer EIC-A32-PC02 EIC-A32-PC02 "$a32" "$pc" "$hp" "$mhp" "$active" EIC-INV-PC-A32-02 EIC-INV-PC-A32-02
  plan_asset Computer EIC-A32-PC07 EIC-A32-PC07 "$a32" "$pc" "$dell" "$mdell" "$active" EIC-INV-PC-A32-07 EIC-INV-PC-A32-07
  plan_asset Computer EIC-A33-PC01 EIC-A33-PC01 "$a33" "$pc" "$hp" "$mhp" "$active" EIC-INV-PC-A33-01 EIC-INV-PC-A33-01
  plan_asset Computer EIC-DIR-LAP01 EIC-DIR-LAP01 "$direction" "$lap" "$lenovo" "$mlap" "$active" EIC-INV-LAP-DIR-01 EIC-INV-LAP-DIR-01
  plan_asset Monitor EIC-A32-MON01 EIC-A32-MON01 "$a32" "$mon" "$dell" "$mmon" "$active" EIC-INV-MON-A32-01 EIC-INV-MON-A32-01
  plan_asset Monitor EIC-A32-MON02 EIC-A32-MON02 "$a32" "$mon" "$dell" "$mmon" "$active" EIC-INV-MON-A32-02 EIC-INV-MON-A32-02
  plan_asset Monitor EIC-A32-MON07 EIC-A32-MON07 "$a32" "$mon" "$dell" "$mmon" "$active" EIC-INV-MON-A32-07 EIC-INV-MON-A32-07
  plan_asset Monitor EIC-STOCK-MON01 EIC-STOCK-MON01 "$stock" "$mon" "$dell" "$mmon" "$spare" EIC-INV-MON-STOCK-01 EIC-INV-MON-STOCK-01
  plan_asset Printer EIC-SEC-PRN01 EIC-SEC-PRN01 "$sec" "$prn" "$brother" "$mprn" "$active" EIC-INV-PRN-SEC-01 EIC-INV-PRN-SEC-01
  plan_asset NetworkEquipment EIC-TECH-SW01 EIC-TECH-SW01 "$tech" "$sw" "$cisco" "$msw" "$active" EIC-INV-SW-TECH-01 EIC-INV-SW-TECH-01

  CURRENT_GROUP=supplement
  for room in A32 A33 A34 A36; do
    case "$room" in
      A32) loc="$a32" ;; A33) loc="$a33" ;; A34) loc="$a34" ;; A36) loc="$a36" ;;
    esac
    for i in {11..16}; do
      canonical="EIC-$room-PC$i"
      name="$canonical"
      code="EIC-INV-PC-$room-$i"
      actual_code="$code"; actual_loc="$loc"; actual_state="$active"
      if (( i % 2 == 0 )); then maker="$hp"; model="$mhp"; else maker="$dell"; model="$mdell"; fi
      # Quatre anomalies volontaires pour l'exercice de diagnostic de parc.
      [[ "$canonical" != EIC-A32-PC11 ]] || actual_loc="$a33"       # mauvais lieu
      [[ "$canonical" != EIC-A33-PC12 ]] || actual_code=""          # inventaire absent
      [[ "$canonical" != EIC-A34-PC13 ]] || name=EIC-A34-PCC13     # erreur de nom
      [[ "$canonical" != EIC-A36-PC14 ]] || actual_state="$spare" # statut incorrect
      plan_asset Computer "$canonical" "$name" "$actual_loc" "$pc" "$maker" "$model" "$actual_state" "$actual_code" "$code"
    done
    for i in {11..13}; do
      canonical="EIC-$room-MON$i"; code="EIC-INV-MON-$room-$i"
      plan_asset Monitor "$canonical" "$canonical" "$loc" "$mon" "$dell" "$mmon" "$active" "$code" "$code"
    done
  done
  for room in A34 STOCK; do
    if [[ "$room" == A34 ]]; then loc="$a34"; actual_state="$active"; else loc="$stock"; actual_state="$spare"; fi
    for i in {11..14}; do
      canonical="EIC-$room-LAP$i"; code="EIC-INV-LAP-$room-$i"
      plan_asset Computer "$canonical" "$canonical" "$loc" "$lap" "$lenovo" "$mlap" "$actual_state" "$code" "$code"
    done
  done
  for i in 11 12; do
    canonical="EIC-SEC-PRN$i"; code="EIC-INV-PRN-SEC-$i"
    plan_asset Printer "$canonical" "$canonical" "$sec" "$prn" "$brother" "$mprn" "$active" "$code" "$code"
    canonical="EIC-TECH-SW$i"; code="EIC-INV-SW-TECH-$i"
    plan_asset NetworkEquipment "$canonical" "$canonical" "$tech" "$sw" "$cisco" "$msw" "$active" "$code" "$code"
  done
  [[ "$(wc -l < "$WORKDIR/plan.jsonl" | tr -d '[:space:]')" == 59 ]] \
    || die 'Le plan doit comporter 59 actifs (11+48)'
  jq -es 'length==59 and (map(select(.group=="manuel"))|length)==11 and
          (map(select(.group=="supplement"))|length)==48 and
          (map(.canonical)|unique|length)==59 and
          (map(.reference_inventory)|unique|length)==59' "$WORKDIR/plan.jsonl" >/dev/null \
    || die 'Plan invalide : doublons ou elements manquants'
}

match_asset() {
  local row="$1" family
  family="$(jq -r '.family' <<<"$row")"
  jq -c --argjson row "$row" --argjson e "$GLPI_ENTITY_ID" '
    [.[] | select(((.entities_id // 0)|tonumber) == $e and
                  ((.is_deleted // 0)|tostring) != "1")
         | select(.name == $row.input.name or .name == $row.canonical or
                  ((.otherserial // "") != "" and .otherserial == $row.reference_inventory) or
                  ((.comment // "") | contains("["+$row.marker+"]"))) ]
  ' "$WORKDIR/$family.json"
}

# Analyse complete avant toute ecriture : aucune fiche manuelle requise.
preflight() {
  local row n matches count
  : > "$WORKDIR/pending.jsonl"
  existing=0; pending=0; manual_existing=0; manual_pending=0; extra_existing=0; extra_pending=0
  while IFS= read -r row; do
    n="$(jq -r '.canonical' <<<"$row")"
    matches="$(match_asset "$row")"
    count="$(jq 'length' <<<"$matches")"
    (( count <= 1 )) || die "Actif ambigu : $n. Plusieurs fiches portent son nom/code. Aucune ecriture effectuee."
    if (( count == 1 )); then
      # Ne pas effacer ni corriger les saisies des eleves.
      existing=$((existing + 1))
      if [[ "$(jq -r .group <<<"$row")" == manuel ]]; then
        manual_existing=$((manual_existing + 1))
      else
        extra_existing=$((extra_existing + 1))
      fi
    else
      if [[ "$(jq -r .group <<<"$row")" == manuel ]]; then
        manual_pending=$((manual_pending + 1))
      else
        extra_pending=$((extra_pending + 1))
      fi
      printf '%s\n' "$row" >> "$WORKDIR/pending.jsonl"
      pending=$((pending + 1))
    fi
  done < "$WORKDIR/plan.jsonl"
  printf '\nRattrapage (11) : %d presents ; %d a creer.\n' "$manual_existing" "$manual_pending"
  printf 'Complement (48) : %d presents ; %d a creer.\n' "$extra_existing" "$extra_pending"
  printf 'TOTAL (59)    : %d presents ; %d a creer.\n' "$existing" "$pending"
}

main() {
  local mode="${1:---apply}" type row family payload name id
  [[ "$#" -le 1 && ( "$mode" == --check || "$mode" == --apply ) ]] \
    || die 'Usage : script [--check|--apply]'
  WORKDIR="$(mktemp -d)"
  info 'Module 02 v4.0 : 11 actifs de rattrapage + 48 actifs avec 4 anomalies'
  open_session

  for type in Location Manufacturer ComputerType ComputerModel MonitorType MonitorModel \
              PrinterType PrinterModel NetworkEquipmentType NetworkEquipmentModel \
              State Computer Monitor Printer NetworkEquipment; do
    snapshot "$type"
  done

  # Plan avec referentiels fictifs (ID 0) pour verifier sans rien creer.
  build_plan
  preflight
  if [[ "$mode" == --check ]]; then
    info 'Les lieux, types, fabricants, modeles et statuts absents seront crees par --apply.'
    ok 'Verification terminee : aucun changement.'
    return 0
  fi
  if (( pending == 0 )); then
    ok 'Aucun nouvel equipement necessaire. Donnees existantes conservees.'
    return 0
  fi

  if [[ "${GLPI_TP_CONFIRM:-}" != YES ]]; then
    [[ -t 0 ]] || die 'Confirmation necessaire : lancement interactif ou GLPI_TP_CONFIRM=YES.'
    local answer
    read -r -p "Autoriser la creation des referentiels manquants et des $pending actifs ? Saisir OUI : " answer
    [[ "$answer" == OUI ]] || die 'Operation annulee : aucune creation.'
  fi

  ensure_prerequisites
  build_plan   # Reconstruire avec les vrais identifiants GLPI.
  preflight    # Verifier une seconde fois avant les creations de materiels.

  while IFS= read -r row; do
    family="$(jq -r '.family' <<<"$row")"
    payload="$(jq -c '.input' <<<"$row")"
    name="$(jq -r '.input.name' <<<"$row")"
    id="$(create "$family" "$payload")" || die "Creation interrompue : $name"
    ok "$family cree : $name (ID $id)"
  done < "$WORKDIR/pending.jsonl"
  ok "Module termine : $pending actifs crees ; $existing actifs deja presents preserves."
  info 'Les anomalies corrigees par les eleves restent corrigees lors des relances.'
}

main "$@"
