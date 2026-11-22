#!/usr/bin/env bash
set -Eeuo pipefail

API_URL="${GLPI_API_URL:-http://127.0.0.1/apirest.php}"
API_USER="${GLPI_API_USER:-glpi}"
LOCATION_PATH="EIC > Stock informatique"
LOCATION_NAME="Stock informatique"
STATUS_NAME="En stock"

trap 'echo "[ERREUR] Ligne $LINENO" >&2' ERR

need_cmd(){ command -v "$1" >/dev/null 2>&1 || { echo "Commande manquante : $1" >&2; exit 1; }; }
need_cmd curl; need_cmd jq

read -r -s -p "Mot de passe administrateur GLPI : " GLPI_PASS; echo

SESSION_JSON=$(curl -fsS -u "$API_USER:$GLPI_PASS" "$API_URL/initSession")
SESSION_TOKEN=$(printf '%s' "$SESSION_JSON" | jq -r '.session_token')
[[ -n "$SESSION_TOKEN" && "$SESSION_TOKEN" != "null" ]] || { echo "Session API impossible" >&2; exit 1; }

api_get(){ curl -fsS -H "Session-Token: $SESSION_TOKEN" "$API_URL/$1"; }
api_post(){ local endpoint="$1"; local payload="$2"; curl -fsS -H "Content-Type: application/json" -H "Session-Token: $SESSION_TOKEN" -d "$payload" "$API_URL/$endpoint"; }
find_id(){ local endpoint="$1" field="$2" value="$3"; api_get "$endpoint?range=0-9999" | jq -r --arg f "$field" --arg v "$value" '.[] | select(.[$f] == $v) | .id' | head -n1; }
ensure_simple(){
  local endpoint="$1" name="$2" extra_json="${3:-{}}" id
  id=$(find_id "$endpoint" name "$name" || true)
  if [[ -n "$id" ]]; then echo "[OK] $endpoint : $name existe (ID $id)"; return; fi
  payload=$(jq -cn --arg name "$name" --argjson extra "$extra_json" '{input:{name:$name}} * {input: (.input + $extra)}')
  id=$(api_post "$endpoint" "$payload" | jq -r '.id')
  echo "[OK] $endpoint : $name créé (ID $id)"
}

LOCATION_ID=$(find_id 'Location' 'completename' "$LOCATION_PATH" || true)
if [[ -z "$LOCATION_ID" ]]; then
  LOCATION_ID=$(find_id 'Location' 'name' "$LOCATION_NAME" || true)
fi
[[ -n "$LOCATION_ID" ]] || { echo "Lieu introuvable : $LOCATION_PATH" >&2; exit 1; }

STATE_ID=$(find_id 'State' 'name' "$STATUS_NAME" || true)
[[ -n "$STATE_ID" ]] || { echo "Statut introuvable : $STATUS_NAME" >&2; exit 1; }

# base dictionaries
for n in Dell HP Lenovo Acer Brother Cisco Ubiquiti Anker Logitech Samsung; do ensure_simple Manufacturer "$n"; done
for n in 'PC portable' 'PC fixe' 'Mini PC'; do ensure_simple ComputerType "$n"; done
for n in 'Écran' 'Station d’accueil' 'Clavier' 'Souris' 'Câble' 'Casque USB'; do ensure_simple PeripheralType "$n"; done
for n in 'Imprimante'; do ensure_simple PrinterType "$n"; done
for n in 'Switch'; do ensure_simple NetworkEquipmentType "$n"; done
for n in 'Windows 11 Pro' 'AlmaLinux 10' 'Ubuntu 24.04 LTS'; do ensure_simple OperatingSystemVersion "$n"; done

# create helper asset functions
ensure_computer(){
  local name="$1" model="$2" manufacturer="$3" comment="$4"
  local id=$(find_id 'Computer' 'name' "$name" || true)
  if [[ -n "$id" ]]; then echo "[OK] Computer : $name existe (ID $id)"; return; fi
  local man_id=$(find_id 'Manufacturer' 'name' "$manufacturer")
  payload=$(jq -cn --arg name "$name" --arg comments "$comment" --argjson locations_id "$LOCATION_ID" --argjson states_id "$STATE_ID" --argjson manufacturers_id "$man_id" '{input:{name:$name,comments:$comments,locations_id:$locations_id,states_id:$states_id,manufacturers_id:$manufacturers_id}}')
  id=$(api_post 'Computer' "$payload" | jq -r '.id')
  echo "[OK] Computer : $name créé (ID $id)"
}
ensure_monitor(){
  local name="$1" manufacturer="$2" comment="$3"
  local id=$(find_id 'Monitor' 'name' "$name" || true)
  if [[ -n "$id" ]]; then echo "[OK] Monitor : $name existe (ID $id)"; return; fi
  local man_id=$(find_id 'Manufacturer' 'name' "$manufacturer")
  payload=$(jq -cn --arg name "$name" --arg comments "$comment" --argjson locations_id "$LOCATION_ID" --argjson states_id "$STATE_ID" --argjson manufacturers_id "$man_id" '{input:{name:$name,comments:$comments,locations_id:$locations_id,states_id:$states_id,manufacturers_id:$manufacturers_id}}')
  id=$(api_post 'Monitor' "$payload" | jq -r '.id')
  echo "[OK] Monitor : $name créé (ID $id)"
}
ensure_peripheral(){
  local name="$1" manufacturer="$2" comment="$3"
  local id=$(find_id 'Peripheral' 'name' "$name" || true)
  if [[ -n "$id" ]]; then echo "[OK] Peripheral : $name existe (ID $id)"; return; fi
  local man_id=$(find_id 'Manufacturer' 'name' "$manufacturer")
  payload=$(jq -cn --arg name "$name" --arg comments "$comment" --argjson locations_id "$LOCATION_ID" --argjson states_id "$STATE_ID" --argjson manufacturers_id "$man_id" '{input:{name:$name,comments:$comments,locations_id:$locations_id,states_id:$states_id,manufacturers_id:$manufacturers_id}}')
  id=$(api_post 'Peripheral' "$payload" | jq -r '.id')
  echo "[OK] Peripheral : $name créé (ID $id)"
}
ensure_printer(){
  local name="$1" manufacturer="$2" comment="$3"
  local id=$(find_id 'Printer' 'name' "$name" || true)
  if [[ -n "$id" ]]; then echo "[OK] Printer : $name existe (ID $id)"; return; fi
  local man_id=$(find_id 'Manufacturer' 'name' "$manufacturer")
  payload=$(jq -cn --arg name "$name" --arg comments "$comment" --argjson locations_id "$LOCATION_ID" --argjson states_id "$STATE_ID" --argjson manufacturers_id "$man_id" '{input:{name:$name,comments:$comments,locations_id:$locations_id,states_id:$states_id,manufacturers_id:$manufacturers_id}}')
  id=$(api_post 'Printer' "$payload" | jq -r '.id')
  echo "[OK] Printer : $name créé (ID $id)"
}

ensure_computer 'REF-LAP-01' 'Portable de référence' 'Dell' 'Portable de référence pour tests d’atelier'
ensure_computer 'REF-PC-01' 'PC fixe de référence' 'HP' 'PC fixe de référence pour comparaison'
ensure_monitor 'REF-ECR-01' 'Dell' 'Écran de référence 24 pouces'
ensure_peripheral 'REF-DOCK-01' 'Anker' 'Station d’accueil de référence USB-C'
ensure_peripheral 'REF-CAB-HDMI-01' 'Anker' 'Câble HDMI de référence'
ensure_peripheral 'REF-CAB-USBC-01' 'Anker' 'Câble USB-C de référence'
ensure_peripheral 'STK-KBD-01' 'Logitech' 'Clavier de remplacement'
ensure_peripheral 'STK-MOU-01' 'Logitech' 'Souris de remplacement'
ensure_monitor 'STK-ECR-01' 'Samsung' 'Écran de remplacement'
ensure_peripheral 'STK-DOCK-01' 'Anker' 'Station d’accueil de remplacement temporaire'
ensure_computer 'STK-LAP-01' 'Portable de remplacement' 'Lenovo' 'Portable de remplacement temporaire'
ensure_printer 'REF-PRN-01' 'Brother' 'Imprimante de référence pour tests simples'

echo "[OK] Module 03 terminé"
curl -fsS -H "Session-Token: $SESSION_TOKEN" "$API_URL/killSession" >/dev/null || true
