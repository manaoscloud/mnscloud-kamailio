#!/usr/bin/env bash
set -Eeuo pipefail

API_BASE_FILE="${MNSCLOUD_SOFTSWITCH_API_BASE_FILE:-/etc/mnscloud/softswitch/api.base}"
NODE_UUID_FILE="${MNSCLOUD_SOFTSWITCH_NODE_UUID_FILE:-/etc/mnscloud/softswitch/node.uuid}"
API_TOKEN_FILE="${MNSCLOUD_SOFTSWITCH_API_TOKEN_FILE:-/etc/mnscloud/softswitch/api.token}"
STATE_FILE="${MNSCLOUD_SOFTSWITCH_REGISTRATION_STATE_FILE:-/etc/mnscloud/softswitch/runtime/registrations.json}"
UAC_DB_TEXT_DIR="${MNSCLOUD_KAMAILIO_UAC_DB_TEXT_DIR:-/etc/mnscloud/softswitch/kamailio-db}"
UACREG_FILE="${UAC_DB_TEXT_DIR}/uacreg"
UAC_RELOAD_STAMP_FILE="${MNSCLOUD_KAMAILIO_UAC_RELOAD_STAMP_FILE:-/etc/mnscloud/softswitch/runtime/uac-reg-reload.last}"
UAC_RELOAD_LOCK_FILE="${MNSCLOUD_KAMAILIO_UAC_RELOAD_LOCK_FILE:-/run/mnscloud-softswitch-uac-reload.lock}"
UAC_RELOAD_MIN_INTERVAL="${MNSCLOUD_KAMAILIO_UAC_RELOAD_MIN_INTERVAL:-155}"
CURL_CONNECT_TIMEOUT="${MNSCLOUD_SOFTSWITCH_CURL_CONNECT_TIMEOUT:-5}"
CURL_MAX_TIME="${MNSCLOUD_SOFTSWITCH_CURL_MAX_TIME:-30}"
KAMCMD_TIMEOUT="${MNSCLOUD_SOFTSWITCH_KAMCMD_TIMEOUT:-10}"

read_value() { tr -d '[:space:]' < "$1"; }
rpc_string() { printf 's:%s' "$1"; }
dbtext_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  value="${value//:/\\:}"
  printf '%s' "$value"
}
for required in "$API_BASE_FILE" "$NODE_UUID_FILE" "$API_TOKEN_FILE"; do
  [[ -r "$required" ]] || { echo "missing required file: $required" >&2; exit 1; }
done
for command in curl jq kamcmd timeout flock date; do command -v "$command" >/dev/null || { echo "$command is required" >&2; exit 1; }; done
kamcmd_call() {
  timeout --preserve-status "${KAMCMD_TIMEOUT}" kamcmd "$@"
}
kamcmd_call uac.reg_active 1 >/dev/null 2>&1 || true

api_base="$(read_value "$API_BASE_FILE")"
node_uuid="$(read_value "$NODE_UUID_FILE")"
api_token="$(read_value "$API_TOKEN_FILE")"
install -d -m 0750 "$(dirname "$STATE_FILE")"
state_payload='{"registrations":[]}'
[[ -r "$STATE_FILE" ]] && state_payload="$(cat "$STATE_FILE")"
previous_revision="$(jq -r '.revision // empty' <<<"$state_payload")"
response="$(mktemp)"
trap 'rm -f "$response"' EXIT

registration_exists() {
  local id="$1" result="" command_status=0
  # The UAC RPC contract filters remote registrations by attribute and value.
  # Do not trust the local fingerprint cache when the running Kamailio process
  # has lost its in-memory registration table after a restart.
  result="$(kamcmd_call uac.reg_info l_uuid "$(rpc_string "$id")" 2>&1)" || command_status=$?
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

sanitize_runtime_log() {
  sed -E 's/(auth_password|password|authorization|credential)([^[:space:]]*)/[redacted]/Ig' \
    | sed -E 's/[[:space:]]+/ /g' \
    | cut -c1-2000
}

recent_kamailio_log() {
  command -v journalctl >/dev/null || return 0
  journalctl -u kamailio --no-pager -n 80 2>/dev/null | sanitize_runtime_log || true
}

rpc_output_has_error() {
  grep -Eqi '(^|[[:space:]])error:|invalid|failed|not found|no such|does not exist'
}

reload_output_is_shift_throttle() {
  grep -Eqi 'failed to shift records|shifting the memory table is not possible'
}

reload_window_remaining_seconds() {
  local now last elapsed
  now="$(date +%s)"
  last=0
  [[ -r "$UAC_RELOAD_STAMP_FILE" ]] && last="$(tr -cd '0-9' < "$UAC_RELOAD_STAMP_FILE" || true)"
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  elapsed=$((now - last))
  if (( last > 0 && elapsed >= 0 && elapsed < UAC_RELOAD_MIN_INTERVAL )); then
    printf '%s' "$((UAC_RELOAD_MIN_INTERVAL - elapsed))"
    return 0
  fi
  printf '0'
}

mark_reload_attempt() {
  install -d -m 0750 -o root -g root "$(dirname "$UAC_RELOAD_STAMP_FILE")"
  date +%s > "$UAC_RELOAD_STAMP_FILE"
  chown root:root "$UAC_RELOAD_STAMP_FILE"
  chmod 0640 "$UAC_RELOAD_STAMP_FILE"
}

reload_uac_registrations() {
  local reload_output recent_log retry_after
  retry_after="$(reload_window_remaining_seconds)"
  if (( retry_after > 0 )); then
    echo "uac.reg_reload temporarily deferred: Kamailio UAC reload window is still active; retry after ${retry_after}s." >&2
    return 75
  fi
  mark_reload_attempt
  reload_output="$(kamcmd_call uac.reg_reload 2>&1)" || {
    if reload_output_is_shift_throttle <<<"$reload_output"; then
      echo "uac.reg_reload temporarily deferred: Kamailio rejected reload because the memory table was shifted recently; retry after ${UAC_RELOAD_MIN_INTERVAL}s." >&2
      return 75
    else
      echo "uac.reg_reload failed: $(sanitize_rpc_output <<<"$reload_output")" >&2
      recent_log="$(recent_kamailio_log)"
      [[ -z "$recent_log" ]] || echo "recent kamailio log: ${recent_log}" >&2
      return 1
    fi
  }
  if rpc_output_has_error <<<"$reload_output"; then
    if reload_output_is_shift_throttle <<<"$reload_output"; then
      echo "uac.reg_reload temporarily deferred: Kamailio rejected reload because the memory table was shifted recently; retry after ${UAC_RELOAD_MIN_INTERVAL}s." >&2
      return 75
    fi
  fi
  if rpc_output_has_error <<<"$reload_output"; then
    echo "uac.reg_reload returned an error: $(sanitize_rpc_output <<<"$reload_output")" >&2
    recent_log="$(recent_kamailio_log)"
    [[ -z "$recent_log" ]] || echo "recent kamailio log: ${recent_log}" >&2
    return 1
  fi
}

fetch_registrations() {
  local use_revision="${1:-true}" http_code
  local request_headers=(-H "Authorization: Bearer ${api_token}" -H 'X-Softswitch-Engine: kamailio' -H 'Content-Type: application/json')
  [[ "$use_revision" == true && -n "$previous_revision" ]] && request_headers+=(-H "If-None-Match: \"${previous_revision}\"")
  http_code="$(curl -sS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" -o "$response" -w '%{http_code}' -X POST "${api_base%/}/api/v1/softswitch/runtime/registrations?node_uuid=${node_uuid}&engine=kamailio" "${request_headers[@]}" --data '{"engine":"kamailio"}')"
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
next_uacreg="$(mktemp)"
trap 'rm -f "$response" "$next_state" "$next_uacreg"' EXIT
printf '{"revision":%s,"registrations":[' "$(jq -c '.data.revision // null' "$response")" > "$next_state"
printf '%s\n' 'id(int,auto) l_uuid(str) l_username(str) l_domain(str) r_username(str) r_domain(str) realm(str) auth_username(str) auth_password(str) auth_ha1(str,null) auth_proxy(str) expires(int) flags(int) reg_delay(int) contact_addr(str,null) socket(str,null)' > "$next_uacreg"
first_registration=true
row_id=0
while IFS= read -r item; do
  id="$(jq -r '.registrationUUID' <<<"$item")"; username="$(jq -r '.username' <<<"$item")"; password="$(jq -r '.password' <<<"$item")"; host="$(jq -r '.host' <<<"$item")"
  add_output=""; register_output=""; proxy_scheme=""
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
  if [[ -z "$proxy" ]]; then
    proxy_scheme="sip"
    [[ "$transport" == "tls" ]] && proxy_scheme="sips"
    proxy="${proxy_scheme}:${host}:${port}"
  fi
  row_id=$((row_id + 1))
  printf '%s:%s:%s:%s:%s:%s:%s:%s:%s::%s:%s:0:0::\n' \
    "$row_id" \
    "$(dbtext_escape "$id")" \
    "$(dbtext_escape "$local_user")" \
    "$(dbtext_escape "$local_domain")" \
    "$(dbtext_escape "$username")" \
    "$(dbtext_escape "$host")" \
    "$(dbtext_escape "$realm")" \
    "$(dbtext_escape "$username")" \
    "$(dbtext_escape "$password")" \
    "$(dbtext_escape "$proxy")" \
    "$expires" >> "$next_uacreg"
  $first_registration || printf ',' >> "$next_state"
  first_registration=false
  jq -cn --arg registrationUUID "$id" --arg fingerprint "$fingerprint" '{registrationUUID:$registrationUUID, fingerprint:$fingerprint}' >> "$next_state"
done < <(jq -c '.data.registrations[]' "$response")
printf ']}' >> "$next_state"
install -d -m 0750 -o root -g root "$UAC_DB_TEXT_DIR"
install -m 0640 -o root -g root "$next_uacreg" "$UACREG_FILE"
install -d -m 0750 -o root -g root "$(dirname "$UAC_RELOAD_LOCK_FILE")"
(
  flock -x 9
  reload_uac_registrations
) 9>"$UAC_RELOAD_LOCK_FILE"
while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  register_output="$(kamcmd_call uac.reg_register l_uuid "$(rpc_string "$id")" 2>&1)" || {
    echo "uac.reg_register failed for registration ${id}: $(sanitize_rpc_output <<<"$register_output")" >&2
    exit 1
  }
  if rpc_output_has_error <<<"$register_output"; then
    echo "uac.reg_register returned an error for registration ${id}: $(sanitize_rpc_output <<<"$register_output")" >&2
    exit 1
  fi
  registration_exists "$id" || {
    echo "uac registration ${id} was not visible after db_text reload/register." >&2
    exit 1
  }
done < <(jq -r '.registrations[]?.registrationUUID // empty' "$next_state")
install -m 0640 -o root -g root "$next_state" "$STATE_FILE"
chown root:root "$STATE_FILE"; chmod 0640 "$STATE_FILE"
echo "[sync-kamailio-softswitch-runtime] synchronized $(jq '.data.registrations | length' "$response") outbound registration(s)"
