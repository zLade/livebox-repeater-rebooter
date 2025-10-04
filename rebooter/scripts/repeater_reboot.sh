#!/usr/bin/env bash
set -euo pipefail
CONFIG_JSON=${1:-}
if [[ -z "${CONFIG_JSON}" || ! -f "${CONFIG_JSON}" ]]; then echo "Config JSON not found: $CONFIG_JSON" >&2; exit 1; fi
JQ(){ jq -r "$1" "$CONFIG_JSON"; }

IP=$(JQ '.ip'); USER=$(JQ '.username'); PASS=$(JQ '.password')
LOG_FILE=${LOG_FILE:-"/app/logs/rebooter.log"}
PING_COUNT=${PING_COUNT:-3}; WAIT_AFTER_TRIGGER=${WAIT_AFTER_TRIGGER:-90}
VERIFY_TIMEOUT=${VERIFY_TIMEOUT:-600}; SLEEP_BETWEEN_PINGS=${SLEEP_BETWEEN_PINGS:-5}
COOKIE_JAR=$(mktemp); trap 'rm -f "$COOKIE_JAR" "$COOKIE_JAR.sah.json" "$COOKIE_JAR.ctx"' EXIT

timestamp(){ date '+%Y-%m-%d %H:%M:%S'; }
log(){ echo "$(timestamp) | $*" | tee -a "$LOG_FILE"; }
ping_ok(){ ping -c "$PING_COUNT" -W 1 "$IP" >/dev/null 2>&1; }
raw_exec(){ local cmd="$1"; [[ -z "$cmd" ]] && return 0; cmd=$(printf "%s" "$cmd" | sed 's/\r$//'); eval "$cmd"; }

trigger_reboot(){
  # 1) login (si fourni)
  raw_exec "$(JQ '.raw_curl_login // ""')"

  # 2) si pas de contexte, tentative SAH générique avec USER/PASS
  if [[ ! -s "$COOKIE_JAR.ctx" ]]; then
    curl -s -k -c "$COOKIE_JAR" -b "$COOKIE_JAR" -X POST \
      -H 'Authorization: X-Sah-Login' \
      -H 'Content-Type: application/x-sah-ws-4-call+json' \
      -H "Origin: http://$IP" \
      --data "{\"service\":\"sah.Device.Information\",\"method\":\"createContext\",\"parameters\":{\"applicationName\":\"webui\",\"username\":\"$USER\",\"password\":\"$PASS\"}}" \
      "http://$IP/ws" | tee "$COOKIE_JAR.sah.json" >/dev/null || true
    sed -n 's/.*contextID\"\s*:\s*\"\([^\"]\+\)\".*/\1/p' "$COOKIE_JAR.sah.json" | tr -d '\r\n' > "$COOKIE_JAR.ctx" || true
  fi

  # 3) reboot (si perso fourni)
  raw_exec "$(JQ '.raw_curl_reboot // ""')"

  # 4) fallback SAH reboot si toujours rien
  if [[ -s "$COOKIE_JAR.ctx" ]]; then
    CONTEXT_ID=$(tr -d '\r\n' < "$COOKIE_JAR.ctx")
    curl -s -k -c "$COOKIE_JAR" -b "$COOKIE_JAR" -X POST \
      -H "Authorization: X-Sah $CONTEXT_ID" \
      -H "X-Context: $CONTEXT_ID" \
      -H 'Content-Type: application/x-sah-ws-4-call+json' \
      -H "Origin: http://$IP" \
      --data '{"service":"NMC","method":"reboot","parameters":{"reason":"GUI_Reboot"}}' \
      "http://$IP/ws" >/dev/null || true
  else
    log "WARN: no contextID produced by login; reboot may have failed"
  fi
}

log "Checking $IP"
if ping_ok; then log "Repeater reachable before reboot."; else log "WARNING: not reachable before reboot"; fi
log "Triggering reboot (RAW_CURL)"
if trigger_reboot; then log "Reboot command sent. Waiting ${WAIT_AFTER_TRIGGER}s..."; else log "ERROR: reboot command failed"; exit 2; fi
sleep "$WAIT_AFTER_TRIGGER"

log "Verifying it comes back (timeout ${VERIFY_TIMEOUT}s)"
start=$(date +%s)
while true; do
  if ping_ok; then log "✅ Repeater back online."; break; fi
  now=$(date +%s); (( now - start > VERIFY_TIMEOUT )) && { log "❌ Timeout waiting device"; exit 3; }
  sleep "$SLEEP_BETWEEN_PINGS"; log "...still waiting"
done
log "Done."
