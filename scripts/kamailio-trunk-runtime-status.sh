#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# == 2 && "$1" == --input && -r "$2" && -f "$2" ]] || { echo 'Usage: kamailio-trunk-runtime-status.sh --input <json>' >&2; exit 64; }
command -v jq >/dev/null && command -v kamcmd >/dev/null || { echo 'jq and kamcmd are required.' >&2; exit 69; }
input="$2"; count="$(jq -er '.trunks | if type == "array" then length else error("trunks") end' "$input")"
(( count >= 1 && count <= 500 )) || { echo 'Trunk request must contain 1..500 trunks.' >&2; exit 65; }
out="$(mktemp)"; trap 'rm -f "$out"' EXIT
while IFS= read -r trunk; do
  uuid="$(jq -er '.trunkUUID // empty' <<<"$trunk")"; name="$(jq -er '.name // empty' <<<"$trunk")"; mode="$(jq -er '.authenticationMode // empty' <<<"$trunk")"
  [[ "$uuid" =~ ^[A-Za-z0-9-]{1,64}$ && "$name" =~ ^[A-Za-z0-9._-]{1,100}$ && "$mode" =~ ^(register|ip_acl|none)$ ]] || { echo 'Invalid trunk diagnostic target.' >&2; exit 65; }
  status='not_applicable'; detail='Registration is not configured.'; runtime_error=''
  if [[ "$mode" == register ]]; then
    # The synchronizer registers UAC entries by registrationUUID (the trunk UUID), never by
    # the human-facing trunk name.  The UUID is Agent-supplied and validated above.
    result=''; command_status=0
    result="$(timeout 5 kamcmd uac.reg_info "$uuid" 2>&1)" || command_status=$?
    if grep -Eqi 'registered|state[=: ]+ok' <<<"$result"; then status=registered; detail='Kamailio registration is active.'
    elif grep -Eqi 'registering|trying' <<<"$result"; then status=registering; detail='Kamailio is registering the trunk.'
    elif grep -Eqi 'not found|no such|does not exist|not registered' <<<"$result"; then
      status=not_registered; detail='Kamailio has no active trunk registration.'
      runtime_error="$(tr '\n' ' ' <<<"$result" | sed -E 's/[[:space:]]+/ /g; s/(password|authorization|credential)[^ ]*/[redacted]/Ig' | cut -c1-300)"
    else
      status=unknown; detail='Kamailio could not determine the trunk registration state.'
      runtime_error="$(tr '\n' ' ' <<<"$result" | sed -E 's/[[:space:]]+/ /g' | cut -c1-300)"
      [[ -n "$runtime_error" ]] || runtime_error="kamcmd exited with status ${command_status}."
    fi
  fi
  jq -n --arg trunkUUID "$uuid" --arg name "$name" --arg registrationStatus "$status" --arg detail "$detail" --arg runtimeError "$runtime_error" '{trunkUUID:$trunkUUID,name:$name,registrationStatus:$registrationStatus,detail:$detail,runtimeError:(if $runtimeError=="" then null else $runtimeError end)}' >>"$out"
done < <(jq -c '.trunks[]' "$input")
jq -s --arg observedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{observedAt:$observedAt,trunks:.}' "$out"
