#!/usr/bin/env bash

HOST="${1:-cloudflare.com}"
PUBLIC_IP="${2:-1.1.1.1}"
MTR_COUNT="${MTR_COUNT:-4}"

json() {
  printf '{"text":"%s","tooltip":"%s","class":"%s","alt":"%s"}\n' \
    "$1" "$2" "$3" "$4"
}

# 1. Basic NetworkManager state
if command -v nmcli >/dev/null 2>&1; then
  nm_state="$(nmcli -t -f CONNECTIVITY general status 2>/dev/null | cut -d: -f1)"

  case "$nm_state" in
    none)
      json "No network" "NetworkManager says there is no network connectivity." "critical" "down"
      exit 0
      ;;
    portal)
      json "Captive portal" "NetworkManager says you may be behind a captive portal." "warning" "portal"
      exit 0
      ;;
    limited)
      nm_note="NetworkManager reports limited connectivity. "
      ;;
    full)
      nm_note=""
      ;;
    *)
      nm_note="NetworkManager state: ${nm_state:-unknown}. "
      ;;
  esac
else
  nm_note=""
fi

# 2. Can we reach a raw public IP?
# If this fails, DNS is not the first problem.
if ! ping -n -c 1 -W 2 "$PUBLIC_IP" >/dev/null 2>&1; then
  gw="$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')"

  if [ -n "$gw" ] && ping -n -c 1 -W 2 "$gw" >/dev/null 2>&1; then
    json "Internet down" "${nm_note}Gateway $gw replies, but public IP $PUBLIC_IP does not." "critical" "wan-down"
  else
    json "Gateway down" "${nm_note}Default gateway ${gw:-unknown} is unreachable." "critical" "gateway-down"
  fi

  exit 0
fi

# 3. Resolve the target host.
# If public IP works but hostname resolution fails, call it DNS.
resolved_ip="$(getent ahostsv4 "$HOST" 2>/dev/null | awk '{print $1; exit}')"

if [ -z "$resolved_ip" ]; then
  resolver="$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf 2>/dev/null)"

  if [ -n "$resolver" ] && command -v dig >/dev/null 2>&1; then
    if ! dig @"$resolver" "$HOST" A +time=2 +tries=1 >/dev/null 2>&1; then
      json "DNS unreachable" "${nm_note}Raw IP works, but resolver $resolver did not answer for $HOST." "critical" "dns-down"
      exit 0
    fi
  fi

  json "DNS down" "${nm_note}Raw IP works, but $HOST cannot be resolved." "critical" "dns-down"
  exit 0
fi

# 4. Run mtr against the resolved IP.
# -n avoids reverse DNS, so DNS problems do not affect the route test.
if ! command -v mtr >/dev/null 2>&1; then
  json "Online" "${nm_note}$HOST resolves to $resolved_ip. mtr is not installed." "ok" "online"
  exit 0
fi

if ! mtr_out="$(mtr -n -r -c "$MTR_COUNT" --json "$resolved_ip" 2>/dev/null)"; then
  json "MTR failed" "${nm_note}$HOST resolves to $resolved_ip, but mtr failed." "warning" "mtr-failed"
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  json "Online" "${nm_note}$HOST resolves to $resolved_ip. mtr ran, but jq is not installed." "ok" "online"
  exit 0
fi

# Different mtr versions use different JSON keys.
# Common keys include "Loss%", "Loss", "LossPct", or "loss".
final_loss="$(
  printf '%s\n' "$mtr_out" |
    jq -r '
      .report.hubs[-1]
      | .["Loss%"] // .Loss // .LossPct // .loss // empty
    ' 2>/dev/null |
    tr -d '%'
)"

final_host="$(
  printf '%s\n' "$mtr_out" |
    jq -r '.report.hubs[-1].host // empty' 2>/dev/null
)"

if [ -z "$final_loss" ]; then
  json "Online" "${nm_note}$HOST resolves to $resolved_ip. mtr ran, but loss parsing failed." "ok" "online"
  exit 0
fi

loss_int="${final_loss%.*}"

# If loss_int is not numeric for some reason, fail gracefully.
if ! [[ "$loss_int" =~ ^[0-9]+$ ]]; then
  json "Online" "${nm_note}$HOST resolves to $resolved_ip. mtr ran, but returned unexpected loss value: $final_loss." "ok" "online"
  exit 0
fi

if [ "$loss_int" -ge 100 ]; then
  last_good="$(
    printf '%s\n' "$mtr_out" |
      jq -r '
        .report.hubs[]
        | select((.["Loss%"] // .Loss // .LossPct // .loss // 100) < 100)
        | "\(.count // .nr // "?") \(.host // "?")"
      ' 2>/dev/null |
      tail -n1
  )"

  if [ -n "$last_good" ]; then
    json "Host unreachable" "${nm_note}$HOST / $resolved_ip is unreachable. Last responding hop: $last_good." "critical" "host-down"
  else
    json "Route down" "${nm_note}$HOST / $resolved_ip is unreachable. No hops replied." "critical" "route-down"
  fi

  exit 0
fi

if [ "$loss_int" -ge 30 ]; then
  json "Packet loss ${loss_int}%" "${nm_note}$HOST / $resolved_ip has ${final_loss}% loss at destination ${final_host:-$resolved_ip}." "warning" "loss"
  exit 0
fi

json "Online" "${nm_note}$HOST / $resolved_ip reachable. Destination loss: ${final_loss}%." "ok" "online"
