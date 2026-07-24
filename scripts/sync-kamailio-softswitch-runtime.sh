#!/usr/bin/env bash
set -Eeuo pipefail

API_BASE_FILE="${MNSCLOUD_SOFTSWITCH_API_BASE_FILE:-/etc/mnscloud/softswitch/api.base}"
NODE_UUID_FILE="${MNSCLOUD_SOFTSWITCH_NODE_UUID_FILE:-/etc/mnscloud/softswitch/node.uuid}"
API_TOKEN_FILE="${MNSCLOUD_SOFTSWITCH_API_TOKEN_FILE:-/etc/mnscloud/softswitch/api.token}"
STATE_FILE="${MNSCLOUD_SOFTSWITCH_REGISTRATION_STATE_FILE:-/etc/mnscloud/softswitch/runtime/registrations.json}"

read_value() { tr -d '[:space:]' < "$1"; }
for required in "$API_BASE_FILE" "$NODE_UUID_FILE" "$API_TOKEN_FILE"; do
  [[ -r "$required" ]] || { echo "missing required file: $required" >&2; exit 1; }
done
for command in curl jq kamcmd; do command -v "$command" >/dev/null || { echo "$command is required" >&2; exit 1; }; done

api_base="$(read_value "$API_BASE_FILE")"
node_uuid="$(read_value "$NODE_UUID_FILE")"
api_token="$(read_value "$API_TOKEN_FILE")"
install -d -m 0750 "$(dirname "$STATE_FILE")"
response="$(mktemp)"
trap 'rm -f "$response"' EXIT
http_code="$(curl -sS -o "$response" -w '%{http_code}' -X POST "${api_base%/}/api/v1/softswitch/runtime/registrations?node_uuid=${node_uuid}&engine=kamailio" -H "Authorization: Bearer ${api_token}" -H 'X-Softswitch-Engine: kamailio' -H 'Content-Type: application/json' --data '{"engine":"kamailio"}')"
[[ "$http_code" =~ ^2 ]] || { echo "runtime registration fetch failed: HTTP ${http_code}" >&2; exit 1; }
jq -e '.status == "success" and (.data.registrations | type == "array")' "$response" >/dev/null
state_payload='{"registrations":[]}'
[[ -r "$STATE_FILE" ]] && state_payload="$(cat "$STATE_FILE")"

registration_fingerprint() {
  jq -cS '{registrationUUID, host, port, transport, outboundProxy, username, password, realm, fromDomain, registrationExpires}' \
    | sha256sum | awk '{print $1}'
}

remove_registration() {
  local id="$1"
  kamcmd uac.reg_unregister "$id" >/dev/null 2>&1 || true
  kamcmd uac.reg_remove "$id" >/dev/null 2>&1 || true
}

while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  if ! jq -e --arg id "$id" '.data.registrations[] | select(.registrationUUID == $id)' "$response" >/dev/null; then
    remove_registration "$id"
  fi
done < <(jq -r '.registrations[]?.registrationUUID // empty' <<<"$state_payload")

next_state="$(mktemp)"
trap 'rm -f "$response" "$next_state"' EXIT
printf '{"registrations":[' > "$next_state"
first_registration=true
while IFS= read -r item; do
  id="$(jq -r '.registrationUUID' <<<"$item")"; username="$(jq -r '.username' <<<"$item")"; password="$(jq -r '.password' <<<"$item")"; host="$(jq -r '.host' <<<"$item")"
  port="$(jq -r '.port // 5060' <<<"$item")"
  transport="$(jq -r '.transport // "udp" | ascii_downcase' <<<"$item")"
  local_user="$username"
  local_domain="$(jq -r '.fromDomain // empty' <<<"$item")"
  [[ -n "$local_domain" && "$local_domain" != "null" ]] || local_domain="$host"
  realm="$(jq -r '.realm // empty' <<<"$item")"
  [[ -n "$realm" && "$realm" != "null" ]] || realm="$host"
  proxy="$(jq -r '.outboundProxy // empty' <<<"$item")"
  expires="$(jq -r '.registrationExpires // 3600' <<<"$item")"
  fingerprint="$(registration_fingerprint <<<"$item")"
  [[ "$id" != "null" && "$username" != "null" && "$password" != "null" && "$host" != "null" ]] || {
    echo "runtime registration payload contains required null values" >&2
    exit 1
  }
  [[ "$port" =~ ^[0-9]{1,5}$ && "$expires" =~ ^[0-9]+$ ]] || {
    echo "runtime registration payload contains invalid port or expiration" >&2
    exit 1
  }
  case "$transport" in udp|tcp|tls) ;; *) echo "runtime registration payload contains invalid transport" >&2; exit 1 ;; esac
  previous_fingerprint="$(jq -r --arg id "$id" '.registrations[]? | select(.registrationUUID == $id) | .fingerprint // empty' <<<"$state_payload")"
  if [[ "$fingerprint" != "$previous_fingerprint" ]]; then
    remove_registration "$id"
    [[ -n "$proxy" ]] || proxy="sip:${host}:${port};transport=${transport}"
    kamcmd uac.reg_add "$id" "$local_user" "$local_domain" "$username" "$host" "$realm" "$username" "$password" . "$proxy" "$expires" 0 0 . . >/dev/null
    kamcmd uac.reg_register "$id" >/dev/null
  fi
  $first_registration || printf ',' >> "$next_state"
  first_registration=false
  jq -cn --arg registrationUUID "$id" --arg fingerprint "$fingerprint" '{registrationUUID, fingerprint}' >> "$next_state"
done < <(jq -c '.data.registrations[]' "$response")
printf ']}' >> "$next_state"
install -m 0640 -o root -g root "$next_state" "$STATE_FILE"
chown root:root "$STATE_FILE"; chmod 0640 "$STATE_FILE"
echo "[sync-kamailio-softswitch-runtime] synchronized $(jq '.data.registrations | length' "$response") outbound registration(s)"
