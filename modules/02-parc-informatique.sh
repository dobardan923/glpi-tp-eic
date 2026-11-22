#!/usr/bin/env bash
# GLPI TP EIC - 02 - Extension du parc / séance 11 (v2.0)
# GLPI 12 / AlmaLinux 10 / API legacy
# Creation seulement; aucun PUT/DELETE, aucun ticket, aucun changement du parc manuel.
# Les quatre ecarts sont volontairement presents a la creation, jamais reinjectes.
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
info(){ printf '[INFO] %s\n' "$*" >&2; }
ok(){ printf '[OK] %s\n' "$*" >&2; }
die(){ printf '[ERREUR] %s\n' "$*" >&2; exit 1; }
for cmd in curl jq mktemp; do command -v "$cmd" >/dev/null || die "Commande manquante : $cmd"; done
[[ "$GLPI_ENTITY_ID" =~ ^[0-9]+$ ]] || die 'GLPI_ENTITY_ID invalide'
CURL_OPTS=(--silent --show-error --connect-timeout 10 --max-time 90)
[[ "$CURL_INSECURE" == 1 ]] && CURL_OPTS+=(--insecure)
HEADERS=(-H 'Content-Type: application/json')
[[ -n "$GLPI_APP_TOKEN" ]] && HEADERS+=(-H "App-Token: $GLPI_APP_TOKEN")
api(){
  local method="$1" endpoint="$2" payload="${3-}" tmp status response
  tmp="$(mktemp)"
  local args=("${CURL_OPTS[@]}" "${HEADERS[@]}" -H "Session-Token: $SESSION_TOKEN" -X "$method" -o "$tmp" -w '%{http_code}')
  [[ -n "$payload" ]] && args+=(--data-binary "$payload")
  if ! status="$(curl "${args[@]}" "$API_URL/$endpoint")"; then rm -f "$tmp"; die "Communication API impossible : $endpoint"; fi
  response="$(cat "$tmp")"; rm -f "$tmp"
  case "$status" in 200|201|206) ;; *) die "HTTP $status $method $endpoint : $response" ;; esac
  jq -e . >/dev/null 2>&1 <<<"$response" || die "Réponse JSON invalide : $endpoint"
  if jq -e 'type=="array" and length>0 and (.[0]|type)=="string" and (.[0]|startswith("ERROR"))' >/dev/null <<<"$response"; then
    die "Erreur métier API : $response"
  fi
  printf '%s\n' "$response"
}
open_session(){
  local tmp status response
  tmp="$(mktemp)"
  if [[ -z "$GLPI_USER_TOKEN" && -z "$GLPI_PASSWORD" ]]; then
    read -r -s -p 'Mot de passe administrateur GLPI : ' GLPI_PASSWORD; printf '\n' >&2
  fi
  [[ -n "$GLPI_USER_TOKEN" || -n "$GLPI_PASSWORD" ]] || die 'Identifiants absents'
  local args=("${CURL_OPTS[@]}" "${HEADERS[@]}" -o "$tmp" -w '%{http_code}')
  if [[ -n "$GLPI_USER_TOKEN" ]]; then args+=(-H "Authorization: user_token $GLPI_USER_TOKEN"); else args+=(-u "$GLPI_LOGIN:$GLPI_PASSWORD"); fi
  if ! status="$(curl "${args[@]}" "$API_URL/initSession")"; then rm -f "$tmp"; die 'Connexion API impossible'; fi
  response="$(cat "$tmp")"; rm -f "$tmp"
  [[ "$status" == 200 ]] || die "Authentification GLPI refusée (HTTP $status) : $response"
  SESSION_TOKEN="$(jq -r '.session_token // empty' <<<"$response")"
  [[ -n "$SESSION_TOKEN" ]] || die 'Session-Token absent'
  ok 'Session GLPI ouverte'
}
close_session(){
  [[ -z "$SESSION_TOKEN" ]] && return 0
  curl "${CURL_OPTS[@]}" "${HEADERS[@]}" -H "Session-Token: $SESSION_TOKEN" "$API_URL/killSession" >/dev/null 2>&1 || true
}
# Lit tous les objets d'un type ; le Content-Range permet d'éviter un appel hors plage.
get_all(){
  local type="$1" start=0 end status tmp hdr result count range total page=0
  while (( page < 200 )); do
    end=$((start+49)); tmp="$(mktemp)"; hdr="$(mktemp)"
    if ! status="$(curl "${CURL_OPTS[@]}" "${HEADERS[@]}" -H "Session-Token: $SESSION_TOKEN" -D "$hdr" -o "$tmp" -w '%{http_code}' "$API_URL/$type?range=$start-$end")"; then
      rm -f "$tmp" "$hdr"; die "Lecture impossible : $type"
    fi
    result="$(cat "$tmp")"
    case "$status" in 200|206) ;; *) rm -f "$tmp" "$hdr"; die "Lecture $type HTTP $status : $result" ;; esac
    jq -e 'type=="array"' >/dev/null <<<"$result" || die "Format liste invalide : $type"
    count="$(jq 'length' <<<"$result")"
    range="$(tr -d '\r' <"$hdr" | grep -i '^Content-Range:' | tail -n 1 || true)"
    rm -f "$tmp" "$hdr"
    (( count > 0 )) || return 0
    jq -c '.[]' <<<"$result"
    start=$((start+count)); page=$((page+1))
    (( count == 50 )) || return 0
    if [[ "$range" =~ /([0-9]+)[[:space:]]*$ ]]; then
      total="${BASH_REMATCH[1]}"; (( start < total )) || return 0
    fi
  done
  die "Pagination excessive : $type"
}

# Le script utilise exclusivement les référentiels préparés par les élèves.
# Utilisation : bash 02-parc-informatique.sh --check  (lecture seule)
#               bash 02-parc-informatique.sh          (création après confirmation)
# URL/test : GLPI_URL=http://127.0.0.1/glpi bash ... --check
# Attention : API REST legacy à activer, droits lecture/création, curl et jq.

WORKDIR=""
cleanup(){
  close_session
  [[ -z "$WORKDIR" ]] || rm -rf -- "$WORKDIR"
}
trap cleanup EXIT

# Mise en cache par famille pour le précontrôle avant toute création.
snapshot(){
  local t="$1"
  get_all "$t" > "$WORKDIR/$t.jsonl" || die "Lecture impossible : $t"
  jq -s '.' "$WORKDIR/$t.jsonl" > "$WORKDIR/$t.json" || die "JSON invalide : $t"
}
reference(){
  local t="$1" n="$2" id
  id="$(jq -r --arg n "$n" '[.[]|select(.name==$n)] | if length>1 then error("Référentiel ambigu : "+$n) else .[0].id // empty end' "$WORKDIR/$t.json")" || die "Référentiel ambigu : $t/$n"
  [[ "$id" =~ ^[0-9]+$ ]] || die "Référentiel absent : $t / $n (terminer les exercices 3 et 4)"
  printf '%s\n' "$id"
}
location(){
  local n="$1" parent="$2" id
  id="$(jq -r --arg n "$n" --arg p "$parent" --arg e "$GLPI_ENTITY_ID" '[.[] | select(.name==$n and ((.locations_id // 0)|tostring)==$p and ((.entities_id // 0)|tostring)==$e)] | if length>1 then error("Lieu ambigu : "+$n) else .[0].id // empty end' "$WORKDIR/Location.json")" || die "Localisation ambiguë : $n"
  [[ "$id" =~ ^[0-9]+$ ]] || die "Lieu absent : $n (terminer exercice 2, vérifier GLPI_ENTITY_ID)"
  printf '%s\n' "$id"
}
create(){
  local t="$1" object="$2" response id payload
  payload="$(jq -nc --argjson input "$object" '{input:$input}')"
  response="$(api POST "$t" "$payload")" || die "Échec de création : $t (ne pas relancer avant vérification)"
  id="$(jq -r 'if type=="object" then .id // empty elif type=="array" then .[0].id // empty else empty end' <<<"$response")"
  [[ "$id" =~ ^[0-9]+$ ]] || die "Création non confirmée : $t / $response"
  printf '%s\n' "$id"
}
# Plan JSONL. canonical = nom correct, name = nom réellement injecté.
# reference_inventory = code attendu stable, inventory = valeur réellement injectée.
plan_asset(){
  local family="$1" canonical="$2" name="$3" loc="$4" kind="$5" manufacturer="$6" model="$7" state="$8" inventory="$9" target_inventory="${10}" typekey modelkey
  case "$family" in
    Computer) typekey=computertypes_id; modelkey=computermodels_id;;
    Monitor) typekey=monitortypes_id; modelkey=monitormodels_id;;
    Printer) typekey=printertypes_id; modelkey=printermodels_id;;
    NetworkEquipment) typekey=networkequipmenttypes_id; modelkey=networkequipmentmodels_id;;
    *) die "Famille non prévue : $family";;
  esac
  jq -nc --arg family "$family" --arg canonical "$canonical" --arg code "$target_inventory" --arg n "$name" --arg inventory "$inventory" --arg tk "$typekey" --arg mk "$modelkey" --argjson e "$GLPI_ENTITY_ID" --argjson l "$loc" --argjson t "$kind" --argjson ma "$manufacturer" --argjson mo "$model" --argjson st "$state" \
    '{family:$family,canonical:$canonical,reference_inventory:$code,input:({name:$n,otherserial:$inventory,entities_id:$e,locations_id:$l,manufacturers_id:$ma,states_id:$st,comment:"EIC TP - module 02 révisé - séance 11"} + {($tk):$t,($mk):$mo})}' >> "$WORKDIR/plan.jsonl"
}
# Une fiche initiale OU déjà corrigée doit être réutilisée, jamais recréée.
# Le contrôle du code couvre aussi les renommages conformes réalisés par les élèves.
match_asset(){
  local row="$1" family
  family="$(jq -r .family <<<"$row")"
  jq -c --argjson row "$row" --arg e "$GLPI_ENTITY_ID" '
    [.[] | select(((.entities_id // 0)|tostring)==$e and ((.is_deleted // 0)|tostring)!="1") | select(.name==$row.input.name or .name==$row.canonical or ((.otherserial // "")!="" and .otherserial==$row.reference_inventory))]
  ' "$WORKDIR/$family.json"
}
# Précontrôle de la présence des actifs manuels sans modifier les valeurs.
check_manual(){
  local family="$1" n="$2" count
  count="$(jq --arg n "$n" --arg e "$GLPI_ENTITY_ID" '[.[]|select(.name==$n and ((.entities_id // 0)|tostring)==$e and ((.is_deleted // 0)|tostring)!="1")]|length' "$WORKDIR/$family.json")"
  [[ "$count" == 1 ]] || die "Actif manuel absent ou ambigu : $family / $n (exercice 6)"
}
main(){
  local mode="${1:---apply}" t n pattern row matches count family payload id
  [[ "$#" -le 1 ]] || die 'Utilisation : module [--check|--apply]'
  [[ "$mode" == --apply || "$mode" == --check ]] || die 'Utilisation : module [--check|--apply]'
  WORKDIR="$(mktemp -d)"; : > "$WORKDIR/plan.jsonl"; : > "$WORKDIR/pending.jsonl"
  info 'Module 02 v2.0 : 48 actifs EIC supplémentaires, quatre écarts pédagogiques'
  open_session
  for t in Location Manufacturer ComputerType ComputerModel MonitorType MonitorModel PrinterType PrinterModel NetworkEquipmentType NetworkEquipmentModel State Computer Monitor Printer NetworkEquipment; do snapshot "$t"; done
  # Les élèves ont construit le socle ; ne pas l'écraser et ne pas l'importer à nouveau.
  for n in EIC-A32-PC01 EIC-A32-PC02 EIC-A32-PC07 EIC-A33-PC01 EIC-DIR-LAP01; do check_manual Computer "$n"; done
  for n in EIC-A32-MON01 EIC-A32-MON02 EIC-A32-MON07 EIC-STOCK-MON01; do check_manual Monitor "$n"; done
  check_manual Printer EIC-SEC-PRN01; check_manual NetworkEquipment EIC-TECH-SW01
  local eic aile a32 a33 a34 a36 stock tech sec
  eic="$(location EIC 0)"; aile="$(location 'Aile A' "$eic")"
  a32="$(location A32 "$aile")"; a33="$(location A33 "$aile")"; a34="$(location A34 "$aile")"; a36="$(location A36 "$aile")"
  stock="$(location 'Stock informatique' "$eic")"; tech="$(location 'Local technique' "$aile")"; sec="$(location 'Secrétariat' "$eic")"
  local pc lap mon prn sw dell hp lenovo brother cisco mdell mhp mlap mmon mprn msw active spare
  pc="$(reference ComputerType 'PC fixe')"; lap="$(reference ComputerType 'PC portable')"
  mon="$(reference MonitorType 'Écran bureautique')"; prn="$(reference PrinterType 'Imprimante laser')"; sw="$(reference NetworkEquipmentType 'Switch')"
  dell="$(reference Manufacturer Dell)"; hp="$(reference Manufacturer HP)"; lenovo="$(reference Manufacturer Lenovo)"; brother="$(reference Manufacturer Brother)"; cisco="$(reference Manufacturer Cisco)"
  mdell="$(reference ComputerModel 'OptiPlex 7010 SFF')"; mhp="$(reference ComputerModel 'ProDesk 400 G9 SFF')"; mlap="$(reference ComputerModel 'ThinkPad E14 Gen 5')"
  mmon="$(reference MonitorModel P2422H)"; mprn="$(reference PrinterModel HL-L5210DN)"; msw="$(reference NetworkEquipmentModel CBS250-24T-4G)"
  active="$(reference State 'En service')"; spare="$(reference State 'En stock')"
  local room loc i canonical name actual_loc actual_state maker model code actual_code prefix
  for room in A32 A33 A34 A36; do
    case "$room" in A32) loc="$a32";; A33) loc="$a33";; A34) loc="$a34";; A36) loc="$a36";; esac
    for i in {11..16}; do
      canonical="EIC-$room-PC$i"; name="$canonical"; code="EIC-INV-PC-$room-$i"; actual_code="$code"; actual_loc="$loc"; actual_state="$active"
      if (( i % 2 == 0 )); then maker="$hp"; model="$mhp"; else maker="$dell"; model="$mdell"; fi
      # Écarts introduits seulement lors de la création initiale.
      [[ "$canonical" != EIC-A32-PC11 ]] || actual_loc="$a33"
      [[ "$canonical" != EIC-A33-PC12 ]] || actual_code=""
      [[ "$canonical" != EIC-A34-PC13 ]] || name=EIC-A34-PCC13
      [[ "$canonical" != EIC-A36-PC14 ]] || actual_state="$spare"
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
  [[ "$(wc -l < "$WORKDIR/plan.jsonl" | tr -d '[:space:]')" == 48 ]] || die 'Le plan doit contenir exactement 48 actifs'
  # Nom/code attendu doit être unique dans le plan ; vérifier avant création.
  jq -es 'length==48 and (map(.canonical)|unique|length)==48 and (map(.reference_inventory)|unique|length)==48' "$WORKDIR/plan.jsonl" >/dev/null || die 'Plan invalide ou doublons internes'
  local existing=0 pending=0
  while IFS= read -r row; do
    n="$(jq -r .canonical <<<"$row")"; matches="$(match_asset "$row")"
    count="$(jq 'length' <<<"$matches")"
    (( count <= 1 )) || die "Rapprochement ambigu pour $n ; aucune création effectuée."
    if (( count == 1 )); then
      # Ne pas écraser une fiche portant le même nom mais un autre numéro non vide.
      jq -e --argjson r "$row" '.[0] | ((.otherserial // "")=="" or .otherserial==$r.reference_inventory) and (.name==$r.input.name or .name==$r.canonical or .otherserial==$r.reference_inventory)' <<<"$matches" >/dev/null || die "Conflit d'identification : $n ; contrôler la fiche."
      info "Conservé (déjà présent) : $n"; existing=$((existing+1))
    else
      printf '%s\n' "$row" >> "$WORKDIR/pending.jsonl"; pending=$((pending+1))
    fi
  done < "$WORKDIR/plan.jsonl"
  printf '\nPrécontrôle terminé : 48 actifs attendus ; %s présents ; %s à créer.\n' "$existing" "$pending"
  if [[ "$mode" == --check ]]; then ok 'Contrôle en lecture seule : aucune création.'; return 0; fi
  if (( pending == 0 )); then ok 'Aucun actif à créer. Les corrections des élèves sont conservées.'; return 0; fi
  if [[ "${GLPI_TP_CONFIRM:-}" != YES ]]; then
    [[ -t 0 ]] || die 'Confirmation requise : lancement interactif ou GLPI_TP_CONFIRM=YES après --check.'
    local answer
    read -r -p "Créer les $pending actifs dans cette instance pédagogique ? Saisir OUI : " answer
    [[ "$answer" == OUI ]] || die 'Annulé : aucune création.'
  fi
  while IFS= read -r row; do
    family="$(jq -r .family <<<"$row")"; payload="$(jq -c .input <<<"$row")"; n="$(jq -r .input.name <<<"$row")"
    id="$(create "$family" "$payload")" || die "Création interrompue : $n. Vérifier puis relancer --check."
    ok "$family créé : $n (ID $id)"
  done < "$WORKDIR/pending.jsonl"
  ok "Module terminé : $pending créations ; $existing fiches conservées. Aucun ticket injecté."
  info 'Avant les exercices : contrôler les quatre écarts et le nombre d’actifs dans GLPI.'
}
main "$@"
