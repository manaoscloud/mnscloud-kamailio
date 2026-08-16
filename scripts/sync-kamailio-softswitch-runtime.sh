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
UAC_RELOAD_MAX_WAIT="${MNSCLOUD_KAMAILIO_UAC_RELOAD_MAX_WAIT:-180}"
UAC_DEFAULT_SOCKET="${MNSCLOUD_KAMAILIO_UAC_DEFAULT_SOCKET:-udp:0.0.0.0:5060}"
KAMAILIO_RUNTIME_USER="${MNSCLOUD_KAMAILIO_RUNTIME_USER:-kamailio}"
KAMAILIO_RUNTIME_GROUP="${MNSCLOUD_KAMAILIO_RUNTIME_GROUP:-kamailio}"
CURL_CONNECT_TIMEOUT="${MNSCLOUD_SOFTSWITCH_CURL_CONNECT_TIMEOUT:-5}"
CURL_MAX_TIME="${MNSCLOUD_SOFTSWITCH_CURL_MAX_TIME:-30}"
KAMCMD_TIMEOUT="${MNSCLOUD_SOFTSWITCH_KAMCMD_TIMEOUT:-10}"

read_value() { tr -d '[:space:]' < "$1"; }
private_ipv4() {
  ip -o -4 addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}' || true
}
if [[ "${UAC_DEFAULT_SOCKET}" == "udp:0.0.0.0:5060" || "${UAC_DEFAULT_SOCKET}" == "tcp:0.0.0.0:5060" ]]; then
  detected_private_ip="$(private_ipv4)"
  if [[ -z "${detected_private_ip}" ]]; then
    echo "Could not resolve local IPv4 for default UAC socket." >&2
    exit 1
  fi
  UAC_DEFAULT_SOCKET="${UAC_DEFAULT_SOCKET/0.0.0.0/${detected_private_ip}}"
fi
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
[[ "$UAC_DEFAULT_SOCKET" =~ ^(udp|tcp):[^[:space:]]+:[0-9]{1,5}$ ]] || {
  echo "MNSCLOUD_KAMAILIO_UAC_DEFAULT_SOCKET must be udp|tcp:host:port." >&2
  exit 1
}
for command in curl jq kamcmd timeout flock date; do command -v "$command" >/dev/null || { echo "$command is required" >&2; exit 1; }; done
kamcmd_call() {
  timeout --preserve-status "${KAMCMD_TIMEOUT}" kamcmd "$@"
}
kamcmd_call uac.reg_active 1 >/dev/null 2>&1 || true

api_base="$(read_value "$API_BASE_FILE")"
node_uuid="$(read_value "$NODE_UUID_FILE")"
api_token="$(read_value "$API_TOKEN_FILE")"
uac_owner="$KAMAILIO_RUNTIME_USER"
uac_group="$KAMAILIO_RUNTIME_GROUP"
if ! id -u "$uac_owner" >/dev/null 2>&1 || ! getent group "$uac_group" >/dev/null 2>&1; then
  uac_owner="root"
  uac_group="root"
fi
install -d -m 0750 "$(dirname "$STATE_FILE")"
state_payload='{"registrations":[]}'
[[ -r "$STATE_FILE" ]] && state_payload="$(cat "$STATE_FILE")"
previous_revision="$(jq -r '.revision // empty' <<<"$state_payload")"
response="$(mktemp)"
trap 'rm -f "$response"' EXIT

registration_is_active_or_in_progress() {
  local id="$1" result="" command_status=0 flag_value=""
  # The UAC RPC contract filters remote registrations by attribute and value.
  # Do not trust the local fingerprint cache when the running Kamailio process
  # has lost its in-memory registration table after a restart. A profile loaded
  # with flag 16 is only initialized; it is not enough to skip reg_register.
  result="$(kamcmd_call uac.reg_info l_uuid "$(rpc_string "$id")" 2>&1)" || command_status=$?
  [[ "$command_status" == 0 && -n "$result" ]] || return 1
  ! grep -Eqi '(^|[[:space:]])(error:[[:space:]]*)?404([[:space:]]|$)|record not found|not found|no such|does not exist' <<<"$result" || return 1
  flag_value="$(sed -n 's/.*flags:[[:space:]]*\([0-9][0-9]*\).*/\1/p' <<<"$result" | head -n1)"
  [[ "$flag_value" =~ ^[0-9]+$ ]] || return 1
  (( (flag_value & 14) != 0 ))
}

registration_fingerprint() {
  jq -cS '{registrationUUID, host, port, transport, outboundProxy, username, password, realm, fromDomain, registrationExpires}' \
    | sha256sum | awk '{print $1}'
}

sanitize_rpc_output() {
  tr '\n' ' ' |
    sed -E 's/[[:space:]]+/ /g; s/(auth_password|password|authorization|credential)[[:space:]]*:[[:space:]]*[^[:space:]}]+/\1: [redacted]/Ig; s/(auth_password|password|authorization|credential)[^[:space:]}]*/\1: [redacted]/Ig' |
    cut -c1-300
}

sanitize_runtime_log() {
  sed -E 's/(auth_password|password|authorization|credential)[[:space:]]*:[[:space:]]*[^[:space:]}]+/\1: [redacted]/Ig; s/(auth_password|password|authorization|credential)([^[:space:]]*)/\1: [redacted]/Ig' \
    | sed -E 's/[[:space:]]+/ /g' \
    | cut -c1-2000
}

normalize_registration_id() {
  tr -d '-' | tr '[:lower:]' '[:upper:]'
}

runtime_response_has_registration_id() {
  local id
  id="$(normalize_registration_id <<<"$1")"
  jq -e --arg id "$id" '
    .data.registrations[]?
    | (.registrationUUID // "" | gsub("-"; "") | ascii_upcase) == $id
  ' "$response" >/dev/null
}

dump_runtime_registration_ids() {
  local dump_output="" command_status=0
  dump_output="$(kamcmd_call uac.reg_dump 2>&1)" || command_status=$?
  if (( command_status != 0 )) && ! grep -Eqi 'not found|no such|does not exist|404|empty|no records' <<<"$dump_output"; then
    echo "uac.reg_dump failed; orphaned registration purge skipped: $(sanitize_rpc_output <<<"$dump_output")" >&2
    return 0
  fi
  if rpc_output_has_error <<<"$dump_output" && ! grep -Eqi 'not found|no such|does not exist|404|empty|no records' <<<"$dump_output"; then
    echo "uac.reg_dump returned an error; orphaned registration purge skipped: $(sanitize_rpc_output <<<"$dump_output")" >&2
    return 0
  fi
  sed -nE \
    -e 's/.*"l_uuid"[[:space:]]*:[[:space:]]*"s?:?([^"]+)".*/\1/p' \
    -e 's/.*(^|[[:space:]])l_uuid[[:space:]]*[:=]+[[:space:]]*s?:?([A-Za-z0-9._-]+).*/\2/p' \
    <<<"$dump_output" |
    normalize_registration_id |
    awk 'NF && !seen[$0]++'
}

purge_orphaned_runtime_registrations() {
  local id="" purged_count=0
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    if ! runtime_response_has_registration_id "$id"; then
      echo "Removing orphaned Kamailio UAC registration ${id} not present in runtime policy." >&2
      deactivate_existing_registration "$id"
      purged_count=$((purged_count + 1))
    fi
  done < <(dump_runtime_registration_ids)
  if (( purged_count > 0 )); then
    echo "Purged ${purged_count} orphaned Kamailio UAC registration(s) from runtime memory." >&2
  fi
}

recent_kamailio_log() {
  local printed=false
  if [[ -r /var/log/mnscloud/kamailio/kamailio.err.log ]]; then
    echo "managed stderr: $(tail -n 80 /var/log/mnscloud/kamailio/kamailio.err.log 2>/dev/null | sanitize_runtime_log || true)"
    printed=true
  fi
  if [[ -r /var/log/mnscloud/kamailio/kamailio.out.log ]]; then
    echo "managed stdout: $(tail -n 40 /var/log/mnscloud/kamailio/kamailio.out.log 2>/dev/null | sanitize_runtime_log || true)"
    printed=true
  fi
  if [[ "$printed" == false ]] && command -v journalctl >/dev/null; then
    journalctl -u kamailio --no-pager -n 80 2>/dev/null | sanitize_runtime_log || true
  fi
}

registration_diagnostic() {
  local id="$1" info="" command_status=0
  info="$(kamcmd_call uac.reg_info l_uuid "$(rpc_string "$id")" 2>&1)" || command_status=$?
  printf 'uac.reg_info(status=%s): %s' "$command_status" "$(sanitize_rpc_output <<<"$info")"
}

register_existing_registration() {
  local id="$1" register_output=""
  register_output="$(kamcmd_call uac.reg_register l_uuid "$(rpc_string "$id")" 2>&1)" || {
    echo "uac.reg_register failed for cached registration ${id}: $(sanitize_rpc_output <<<"$register_output")" >&2
    return 1
  }
  if rpc_output_has_error <<<"$register_output"; then
    echo "uac.reg_register returned an error for cached registration ${id}: $(sanitize_rpc_output <<<"$register_output")" >&2
    return 1
  fi
  registration_is_active_or_in_progress "$id"
}

remove_existing_registration() {
  local id="$1" remove_output="" command_status=0
  remove_output="$(kamcmd_call uac.reg_remove "$id" 2>&1)" || command_status=$?
  if (( command_status != 0 )) && ! grep -Eqi 'not found|no such|does not exist|404' <<<"$remove_output"; then
    echo "uac.reg_remove failed for cached registration ${id}: $(sanitize_rpc_output <<<"$remove_output")" >&2
    return 1
  fi
  if rpc_output_has_error <<<"$remove_output" && ! grep -Eqi 'not found|no such|does not exist|404' <<<"$remove_output"; then
    echo "uac.reg_remove returned an error for cached registration ${id}: $(sanitize_rpc_output <<<"$remove_output")" >&2
    return 1
  fi
}

unregister_existing_registration() {
  local id="$1" unregister_output="" command_status=0
  unregister_output="$(kamcmd_call uac.reg_unregister l_uuid "$(rpc_string "$id")" 2>&1)" || command_status=$?
  if (( command_status != 0 )); then
    if grep -Eqi 'unknown command|command not found|not found|no such|does not exist|404' <<<"$unregister_output"; then
      echo "uac.reg_unregister is unavailable or registration ${id} was not found; continuing with local removal: $(sanitize_rpc_output <<<"$unregister_output")" >&2
      return 0
    fi
    echo "uac.reg_unregister failed for registration ${id}: $(sanitize_rpc_output <<<"$unregister_output")" >&2
    return 1
  fi
  if rpc_output_has_error <<<"$unregister_output" && ! grep -Eqi 'not found|no such|does not exist|404' <<<"$unregister_output"; then
    echo "uac.reg_unregister returned an error for registration ${id}: $(sanitize_rpc_output <<<"$unregister_output")" >&2
    return 1
  fi
}

deactivate_existing_registration() {
  local id="$1"
  unregister_existing_registration "$id"
  remove_existing_registration "$id"
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
  local reload_output recent_log retry_after waited=false
  retry_after="$(reload_window_remaining_seconds)"
  if (( retry_after > 0 )); then
    if (( retry_after <= UAC_RELOAD_MAX_WAIT )); then
      echo "uac.reg_reload is inside the Kamailio UAC reload window; waiting ${retry_after}s before retry." >&2
      sleep "$((retry_after + 1))"
      waited=true
    else
      echo "uac.reg_reload temporarily deferred: Kamailio UAC reload window is still active; retry after ${retry_after}s." >&2
      return 75
    fi
  fi
  retry_after="$(reload_window_remaining_seconds)"
  if (( retry_after > 0 )); then
    echo "uac.reg_reload temporarily deferred: Kamailio UAC reload window is still active; retry after ${retry_after}s." >&2
    return 75
  fi
  reload_output="$(kamcmd_call uac.reg_reload 2>&1)" || {
    if reload_output_is_shift_throttle <<<"$reload_output"; then
      if [[ "$waited" == false && "$UAC_RELOAD_MIN_INTERVAL" =~ ^[0-9]+$ && "$UAC_RELOAD_MIN_INTERVAL" -le "$UAC_RELOAD_MAX_WAIT" ]]; then
        echo "uac.reg_reload was throttled by Kamailio; waiting ${UAC_RELOAD_MIN_INTERVAL}s before one retry." >&2
        sleep "$((UAC_RELOAD_MIN_INTERVAL + 1))"
        reload_output="$(kamcmd_call uac.reg_reload 2>&1)" || {
          echo "uac.reg_reload temporarily deferred: Kamailio rejected reload because the memory table was shifted recently; retry after ${UAC_RELOAD_MIN_INTERVAL}s." >&2
          return 75
        }
      else
      echo "uac.reg_reload temporarily deferred: Kamailio rejected reload because the memory table was shifted recently; retry after ${UAC_RELOAD_MIN_INTERVAL}s." >&2
      return 75
      fi
    else
      echo "uac.reg_reload failed: $(sanitize_rpc_output <<<"$reload_output")" >&2
      recent_log="$(recent_kamailio_log)"
      [[ -z "$recent_log" ]] || echo "recent kamailio log: ${recent_log}" >&2
      return 1
    fi
  }
  if rpc_output_has_error <<<"$reload_output"; then
    if reload_output_is_shift_throttle <<<"$reload_output"; then
      if [[ "$waited" == false && "$UAC_RELOAD_MIN_INTERVAL" =~ ^[0-9]+$ && "$UAC_RELOAD_MIN_INTERVAL" -le "$UAC_RELOAD_MAX_WAIT" ]]; then
        echo "uac.reg_reload was throttled by Kamailio; waiting ${UAC_RELOAD_MIN_INTERVAL}s before one retry." >&2
        sleep "$((UAC_RELOAD_MIN_INTERVAL + 1))"
        reload_output="$(kamcmd_call uac.reg_reload 2>&1)" || {
          echo "uac.reg_reload temporarily deferred: Kamailio rejected reload because the memory table was shifted recently; retry after ${UAC_RELOAD_MIN_INTERVAL}s." >&2
          return 75
        }
      else
      echo "uac.reg_reload temporarily deferred: Kamailio rejected reload because the memory table was shifted recently; retry after ${UAC_RELOAD_MIN_INTERVAL}s." >&2
      return 75
      fi
    fi
  fi
  if rpc_output_has_error <<<"$reload_output"; then
    echo "uac.reg_reload returned an error: $(sanitize_rpc_output <<<"$reload_output")" >&2
    recent_log="$(recent_kamailio_log)"
    [[ -z "$recent_log" ]] || echo "recent kamailio log: ${recent_log}" >&2
    return 1
  fi
  mark_reload_attempt
}

fetch_registrations() {
  local use_revision="${1:-true}" http_code
  local request_headers=(-H "Authorization: Bearer ${api_token}" -H 'X-Softswitch-Engine: kamailio' -H 'Content-Type: application/json')
  [[ "$use_revision" == true && -n "$previous_revision" ]] && request_headers+=(-H "If-None-Match: \"${previous_revision}\"")
  http_code="$(curl -sS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" -o "$response" -w '%{http_code}' -X POST "${api_base%/}/api/v1/softswitch/runtime/registrations?node_uuid=${node_uuid}&engine=kamailio" "${request_headers[@]}" --data '{"engine":"kamailio"}')"
  printf "%s" "$http_code"
}

# Always fetch the current registration policy. SIP trunk REGISTER state is an
# edge-control action, not just cached metadata: if Kamailio lost an in-memory
# UAC record or a previous reload failed, a stale 304 can prevent convergence.
http_code="$(fetch_registrations false)"
if [[ "$http_code" == 304 ]]; then
  missing_runtime_registration=false
  cached_registration_count="$(jq '.registrations | if type == "array" then length else 0 end' <<<"$state_payload")"
  cached_registration_id_count="$(jq '[.registrations[]?.registrationUUID // empty] | length' <<<"$state_payload")"
  if [[ "$cached_registration_count" == 0 || "$cached_registration_id_count" != "$cached_registration_count" ]]; then
    missing_runtime_registration=true
  fi
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    if ! registration_is_active_or_in_progress "$id"; then
      if ! register_existing_registration "$id"; then
        missing_runtime_registration=true
        break
      fi
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
  if ! runtime_response_has_registration_id "$id"; then
    deactivate_existing_registration "$id"
  fi
done < <(jq -r '.registrations[]?.registrationUUID // empty' <<<"$state_payload")
purge_orphaned_runtime_registrations

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
  socket="$UAC_DEFAULT_SOCKET"
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
  if [[ "$transport" == "tcp" && "$UAC_DEFAULT_SOCKET" == udp:* ]]; then
    socket="${UAC_DEFAULT_SOCKET/udp:/tcp:}"
  elif [[ "$transport" == "tls" ]]; then
    echo "runtime registration payload requests tls transport, but this Kamailio softswitch runtime has no TLS UAC socket configured" >&2
    exit 1
  fi
  if [[ -z "$proxy" || "$proxy" == "null" ]]; then
    proxy_scheme="sip"
    [[ "$transport" == "tls" ]] && proxy_scheme="sips"
    proxy="${proxy_scheme}:${host}:${port}"
  fi
  row_id=$((row_id + 1))
  printf '%s:%s:%s:%s:%s:%s:%s:%s:%s::%s:%s:0:0::%s\n' \
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
    "$expires" \
    "$(dbtext_escape "$socket")" >> "$next_uacreg"
  $first_registration || printf ',' >> "$next_state"
  first_registration=false
  jq -cn --arg registrationUUID "$id" --arg fingerprint "$fingerprint" '{registrationUUID:$registrationUUID, fingerprint:$fingerprint}' >> "$next_state"
done < <(jq -c '.data.registrations[]' "$response")
printf ']}' >> "$next_state"
install -d -m 0750 -o "$uac_owner" -g "$uac_group" "$UAC_DB_TEXT_DIR"
install -m 0640 -o "$uac_owner" -g "$uac_group" "$next_uacreg" "$UACREG_FILE"
install -d -m 0750 -o root -g root "$(dirname "$UAC_RELOAD_LOCK_FILE")"
while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  remove_existing_registration "$id"
done < <(jq -r '.registrations[]?.registrationUUID // empty' "$next_state")
reload_status=0
(
  flock -x 9
  reload_uac_registrations
) 9>"$UAC_RELOAD_LOCK_FILE" || reload_status=$?
if (( reload_status == 75 )); then
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    register_existing_registration "$id" || {
      echo "uac.reg_reload was temporarily deferred and cached registration ${id} could not be activated. $(registration_diagnostic "$id"). recent kamailio log: $(recent_kamailio_log)" >&2
      exit 75
    }
  done < <(jq -r '.registrations[]?.registrationUUID // empty' "$next_state")
elif (( reload_status != 0 )); then
  exit "$reload_status"
fi
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
  registration_is_active_or_in_progress "$id" || {
    echo "uac registration ${id} was not active or in progress after db_text reload/register. $(registration_diagnostic "$id"). recent kamailio log: $(recent_kamailio_log)" >&2
    exit 1
  }
done < <(jq -r '.registrations[]?.registrationUUID // empty' "$next_state")
install -m 0640 -o root -g root "$next_state" "$STATE_FILE"
chown root:root "$STATE_FILE"; chmod 0640 "$STATE_FILE"
echo "[sync-kamailio-softswitch-runtime] synchronized $(jq '.data.registrations | length' "$response") outbound registration(s)"
