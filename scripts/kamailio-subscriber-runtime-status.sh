#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Usage: $0 --input <subscriber-request.json>" >&2
  exit 64
}

[[ $# -eq 2 && "$1" == "--input" ]] || usage
input_file="$2"
[[ -r "$input_file" && -f "$input_file" ]] || {
  echo "Subscriber diagnostic input is not a readable file." >&2
  exit 66
}
command -v jq >/dev/null 2>&1 || {
  echo "jq is required for subscriber diagnostics." >&2
  exit 69
}
command -v kamcmd >/dev/null 2>&1 || {
  echo "kamcmd is required for subscriber diagnostics." >&2
  exit 69
}

subscriber_count="$(jq -er '.subscribers | if type == "array" then length else error("subscribers must be an array") end' "$input_file")" || {
  echo "Invalid subscriber diagnostic request." >&2
  exit 65
}
(( subscriber_count >= 1 && subscriber_count <= 500 )) || {
  echo "Subscriber diagnostic request must contain between 1 and 500 subscribers." >&2
  exit 65
}

result_file="$(mktemp)"
trap 'rm -f "$result_file"' EXIT

lookup_registration() {
  local username="$1" domain="$2" username_lower candidate output command_status unexpected_output=""
  username_lower="$(tr '[:upper:]' '[:lower:]' <<<"$username")"
  for candidate in \
    "sip:${username}@${domain}" \
    "${username}@${domain}" \
    "${username}" \
    "sip:${username_lower}@${domain}" \
    "${username_lower}@${domain}" \
    "${username_lower}"; do
    output=""
    command_status=0
    output="$(timeout 5 kamcmd ul.lookup location "$candidate" 2>&1)" || command_status=$?
    if (( command_status == 0 )) && grep -qi 'Contact::' <<<"$output"; then
      printf '%s\n' "$output"
      return 0
    fi
    if (( command_status == 0 )) && ! grep -Eqi 'not found|no such user|404|not registered' <<<"$output"; then
      unexpected_output="$output"
    fi
  done
  if [[ -n "$unexpected_output" ]]; then
    printf '%s\n' "$unexpected_output"
    return 2
  fi
  printf '%s\n' "$output"
  return 1
}

while IFS= read -r subscriber; do
  subscriber_uuid="$(jq -er '.subscriberUUID // empty' <<<"$subscriber")"
  username="$(jq -er '.username // empty' <<<"$subscriber")"
  domain="$(jq -er '.domain // empty' <<<"$subscriber")"

  [[ "$subscriber_uuid" =~ ^[A-Za-z0-9-]{1,64}$ ]] || {
    echo "Invalid subscriber UUID in diagnostic request." >&2
    exit 65
  }
  [[ "$username" =~ ^[A-Za-z0-9._-]{1,128}$ ]] || {
    echo "Invalid subscriber username in diagnostic request." >&2
    exit 65
  }
  [[ "$domain" =~ ^[A-Za-z0-9.-]{1,253}$ ]] || {
    echo "Invalid subscriber domain in diagnostic request." >&2
    exit 65
  }

  registration_status="unknown"
  contact=""
  lookup_output=""
  lookup_status=0

  lookup_output="$(lookup_registration "$username" "$domain")" || lookup_status=$?
  if (( lookup_status == 0 )); then
    if grep -qi 'Contact::' <<<"$lookup_output"; then
      registration_status="registered"
      contact="$(sed -n 's/^[[:space:]]*Contact::[[:space:]]*//p' <<<"$lookup_output" | head -n 1)"
    else
      registration_status="not_registered"
    fi
  elif grep -Eqi 'not found|no such user|404|not registered' <<<"$lookup_output"; then
    registration_status="not_registered"
  fi

  jq -n \
    --arg subscriberUUID "$subscriber_uuid" \
    --arg username "$username" \
    --arg domain "$domain" \
    --arg registrationStatus "$registration_status" \
    --arg contact "$contact" \
    '{subscriberUUID: $subscriberUUID, username: $username, domain: $domain, registrationStatus: $registrationStatus, contact: (if $contact == "" then null else $contact end)}' \
    >>"$result_file"
done < <(jq -c '.subscribers[]' "$input_file")

jq -s --arg observedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{observedAt: $observedAt, subscribers: .}' "$result_file"
