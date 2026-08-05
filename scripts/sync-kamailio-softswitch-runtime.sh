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
state_payload='{"registrations":[]}'
[[ -r "$STATE_FILE" ]] && state_payload="$(cat "$STATE_FILE")"
previous_revision="$(jq -r '.revision // empty' <<<"$state_payload")"
response="$(mktemp)"
trap 'rm -f "$response"' EXIT

remove_registration() {
  local id="$1"
  kamcmd uac.reg_unregister l_uuid "$id" >/dev/null 2>&1 || true
  kamcmd uac.reg_remove "$id" >/dev/null 2>&1 || true
}

registration_exists() {
  local id="$1" result="" command_status=0
  # The UAC RPC contract filters remote registrations by attribute and value.
  # Do not trust the local fingerprint cache when the running Kamailio process
  # has lost its in-memory registration table after a restart.
  result="$(kamcmd uac.reg_info l_uuid "$id" 2>&1)" || command_status=$?
  [[ "$command_status" == 0 && -n "$result" ]] || return 1
  ! grep -Eqi '(^|[[:space:]])(error:[[:space:]]*)?404([[:space:]]|$)|record not found|not found|no such|does not exist' <<<"$result"
}

registration_fingerprint() {
  jq -cS '{registrationUUID, host, port, transport, outboundProxy, username, password, realm, fromDomain, registrationExpires}' \
    | sha256sum | awk '{print $1}'
}

sanitize_rpc_output() {
  tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/(password|authorization|credential)[^ ]*/[redacted]/Ig' | cut -c1-300
}

rpc_output_has_error() {
  grep -Eqi '(^|[[:space:]])error:|invalid|failed|not found|no such|does not exist'
}

fetch_registrations() {
  local use_revision="${1:-true}" http_code
  local request_headers=(-H "Authorization: Bearer ${api_token}" -H 'X-Softswitch-Engine: kamailio' -H 'Content-Type: application/json')
  [[ "$use_revision" == true && -n "$previous_revision" ]] && request_headers+=(-H "If-None-Match: \"${previous_revision}\"")
  http_code="$(curl -sS -o "$response" -w '%{http_code}' -X POST "${api_base%/}/api/v1/softswitch/runtime/registrations?node_uuid=${node_uuid}&engine=kamailio" "${request_headers[@]}" --data '{"engine":"kamailio"}')"
  printf "%s" "$http_code"
}

http_code="$(fetch_registrations true)"
if [[ "$http_code" == 304 ]]; then
  missing_runtime_registration=false
  cached_registration_count="$(jq '.registrations | if type == "array" then length else 0 end' <<<"$state_payload")"
  cached_registration_id_count="$(jq '[.registrations[]?.registrationUUID // empty] | length' <<<"$state_payload")"
  if [[ "$cached_registration_count" == 0 || "$cached_registration_id_count" != "$cached_registration_count" ]]; then
    missing_runtime_registration=true
  fi
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    if ! registration_exists "$id"; then
      missing_runtime_registration=true
      break
    fi
  done < <(jq -r '.registrations[]?.registrationUUID // empty' <<<"$state_payload")
  if [[ "$missing_runtime_registration" == false ]]; then
    echo '[sync-kamailio-softswitch-runtime] registration snapshot unchanged'
    exit 0
  fi
  http_code="$(fetch_registrations false)"
fi
[[ "$http_code" =~ ^2 ]] || { echo "runtime registration fetch failed: HTTP ${http_code}" >&2; exit 1; }
jq -e '.status == "success" and (.data.registrations | type == "array")' "$response" >/dev/null

while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  if ! jq -e --arg id "$id" '.data.registrations[] | select(.registrationUUID == $id)' "$response" >/dev/null; then
    remove_registration "$id"
  fi
done < <(jq -r '.registrations[]?.registrationUUID // empty' <<<"$state_payload")

next_state="$(mktemp)"
trap 'rm -f "$response" "$next_state"' EXIT
printf '{"revision":%s,"registrations":[' "$(jq -c '.data.revision // null' "$response")" > "$next_state"
first_registration=true
while IFS= read -r item; do
  id="$(jq -r '.registrationUUID' <<<"$item")"; username="$(jq -r '.username' <<<"$item")"; password="$(jq -r '.password' <<<"$item")"; host="$(jq -r '.host' <<<"$item")"
  add_output=""; refresh_output=""; register_output=""; proxy_scheme=""
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
  if [[ "$fingerprint" != "$previous_fingerprint" ]] || ! registration_exists "$id"; then
    remove_registration "$id"
    if [[ -z "$proxy" ]]; then
      proxy_scheme="sip"
      [[ "$transport" == "tls" ]] && proxy_scheme="sips"
      proxy="${proxy_scheme}:${host}:${port}"
    fi
    add_output="$(kamcmd uac.reg_add "$id" "$local_user" "$local_domain" "$username" "$host" "$realm" "$username" "$password" . "$proxy" "$expires" 0 0 . . 2>&1)" || {
      echo "uac.reg_add failed for registration ${id}: $(sanitize_rpc_output <<<"$add_output")" >&2
      exit 1
    }
    if rpc_output_has_error <<<"$add_output"; then
      echo "uac.reg_add returned an error for registration ${id}: $(sanitize_rpc_output <<<"$add_output")" >&2
      exit 1
    fi
    refresh_output="$(kamcmd uac.reg_refresh "$id" 2>&1)" || {
      echo "uac.reg_refresh failed for registration ${id}: $(sanitize_rpc_output <<<"$refresh_output")" >&2
      exit 1
    }
    if rpc_output_has_error <<<"$refresh_output"; then
      echo "uac.reg_refresh returned an error for registration ${id}: $(sanitize_rpc_output <<<"$refresh_output")" >&2
      exit 1
    fi
    register_output="$(kamcmd uac.reg_register l_uuid "$id" 2>&1)" || {
      echo "uac.reg_register failed for registration ${id}: $(sanitize_rpc_output <<<"$register_output")" >&2
      exit 1
    }
    if rpc_output_has_error <<<"$register_output"; then
      echo "uac.reg_register returned an error for registration ${id}: $(sanitize_rpc_output <<<"$register_output")" >&2
      exit 1
    fi
    registration_exists "$id" || {
      echo "uac registration ${id} was not visible after reg_add/register." >&2
      exit 1
    }
  fi
  $first_registration || printf ',' >> "$next_state"
  first_registration=false
  jq -cn --arg registrationUUID "$id" --arg fingerprint "$fingerprint" '{registrationUUID:$registrationUUID, fingerprint:$fingerprint}' >> "$next_state"
done < <(jq -c '.data.registrations[]' "$response")
printf ']}' >> "$next_state"
install -m 0640 -o root -g root "$next_state" "$STATE_FILE"
chown root:root "$STATE_FILE"; chmod 0640 "$STATE_FILE"
echo "[sync-kamailio-softswitch-runtime] synchronized $(jq '.data.registrations | length' "$response") outbound registration(s)"
