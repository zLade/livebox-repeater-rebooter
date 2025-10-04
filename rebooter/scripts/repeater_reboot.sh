#!/usr/bin/env bash
# Repeater Rebooter (config-driven) — support BASIC_GET / FORM_POST / RAW_CURL
# Lit /app/server/config.json et journalise dans $LOG_FILE (défaut: /app/logs/rebooter.log)

set -euo pipefail

CONFIG_JSON=${1:-}
if [[ -z "${CONFIG_JSON}" || ! -f "${CONFIG_JSON}" ]]; then
  echo "Usage: $0 /path/to/config.json" >&2
  exit 1
fi

# ---------- Helpers ----------
JQ(){ jq -r "$1" "$CONFIG_JSON"; }                # .field extraction
timestamp(){ date '+%Y-%m-%d %H:%M:%S'; }
LOG_FILE=${LOG_FILE:-"/app/logs/rebooter.log"}
log(){ printf "%s | %s\n" "$(timestamp)" "$*" | tee -a "$LOG_FILE"; }

# Exécution robuste pour les one-liners (strip CR et eval entre guillemets)
raw_eval(){
  local cmd="$1"
  [[ -z "${cmd}" ]] && return 0
  cmd="$(printf '%s' "$cmd" | sed 's/\r$//' | tr -d '\r')"
  eval "$cmd"
}

# Ping court
PING_COUNT=${PING_COUNT:-3}
ping_ok(){ ping -c "$PING_COUNT" -W 1 "$IP" >/dev/null 2>&1 || ping -c "$PING_COUNT" "$IP" >/dev/null 2>&1; }

# Attentes
WAIT_AFTER_TRIGGER=${WAIT_AFTER_TRIGGER:-90}   # attente juste après envoi du reboot
VERIFY_TIMEOUT=${VERIFY_TIMEOUT:-600}          # délai max de retour up
SLEEP_BETWEEN_PINGS=${SLEEP_BETWEEN_PINGS:-5}  # période entre pings pendant la vérification

# Espace de travail
COOKIE_JAR="$(mktemp)"
trap 'rm -f "$COOKIE_JAR" "$COOKIE_JAR.sah.json" "$COOKIE_JAR.ctx"' EXIT

# ---------- Lecture config ----------
IP="$(JQ '.ip')"
USER="$(JQ '.username')"
PASS="$(JQ '.password')"
METHOD="$(JQ '.method // "RAW_CURL"')"
ENDPOINT="$(JQ '.endpoint // ""')"

FORM_URL="$(JQ '.form.url // ""')"
FORM_PAYLOAD="$(JQ '.form.payload // ""')"
FORM_REBOOT_URL="$(JQ '.form.reboot_url // ""')"

RAW_LOGIN_CFG="$(JQ '.raw_curl_login // ""')"
RAW_REBOOT_CFG="$(JQ '.raw_curl_reboot // ""')"

# ---------- Utilitaires SAH (fallbacks et extraction contextID) ----------
write_ctx(){
  local cid=""
  if command -v jq >/dev/null 2>&1; then
    cid="$(jq -r '.data.contextID // empty' "$COOKIE_JAR.sah.json" 2>/dev/null || true)"
    [[ -z "$cid" ]] && cid="$(jq -r '.contextID // empty' "$COOKIE_JAR.sah.json" 2>/dev/null || true)"
  fi
  if [[ -z "$cid" && -s "$COOKIE_JAR.sah.json" ]]; then
    cid="$(sed -n 's/.*contextID\"\s*:\s*\"\([^\"]\+\)\".*/\1/p' "$COOKIE_JAR.sah.json" 2>/dev/null || true)"
  fi
  printf '%s' "$cid" > "$COOKIE_JAR.ctx"
  if [[ -n "$cid" ]]; then
    log "DEBUG: contextID length=$(printf '%s' "$cid" | wc -c | awk '{print $1}') head=$(printf '%s' "$cid" | cut -c1-8)…"
  else
    log "DEBUG: unable to extract contextID"
  fi
}

sah_login() {
  curl -s -k -c "$COOKIE_JAR" -b "$COOKIE_JAR" -X POST \
    -H 'Authorization: X-Sah-Login' \
    -H 'Accept: application/json' \
    -H 'Content-Type: application/x-sah-ws-4-call+json' \
    -H "Origin: http://$IP" \
    --data "{\"service\":\"sah.Device.Information\",\"method\":\"createContext\",\"parameters\":{\"applicationName\":\"webui\",\"username\":\"$USER\",\"password\":\"$PASS\"}}" \
    "http://$IP/ws" | tee "$COOKIE_JAR.sah.json" >/dev/null
  cp -f "$COOKIE_JAR.sah.json" /app/logs/last_login.json 2>/dev/null || true
  write_ctx
}

sah_reboot_auth_xctx(){
  local cid; cid="$(tr -d '\r\n' < "$COOKIE_JAR.ctx" 2>/dev/null || true)"
  [[ -z "$cid" ]] && return 1
  curl -s -k -c "$COOKIE_JAR" -b "$COOKIE_JAR" -X POST \
    -H "Authorization: X-Sah $cid" \
    -H "X-Context: $cid" \
    -H 'Content-Type: application/x-sah-ws-4-call+json' \
    -H "Origin: http://$IP" \
    --data '{"service":"NMC","method":"reboot","parameters":{"reason":"GUI_Reboot"}}' \
    "http://$IP/ws" | tee "$COOKIE_JAR.sah.json" >/dev/null
  cp -f "$COOKIE_JAR.sah.json" /app/logs/last_reboot.json 2>/dev/null || true
}

sah_reboot_xctx_only(){
  local cid; cid="$(tr -d '\r\n' < "$COOKIE_JAR.ctx" 2>/dev/null || true)"
  [[ -z "$cid" ]] && return 1
  curl -s -k -c "$COOKIE_JAR" -b "$COOKIE_JAR" -X POST \
    -H "X-Context: $cid" \
    -H 'Content-Type: application/x-sah-ws-4-call+json' \
    -H "Origin: http://$IP" \
    --data '{"service":"NMC","method":"reboot","parameters":{"reason":"GUI_Reboot"}}' \
    "http://$IP/ws" | tee "$COOKIE_JAR.sah.json" >/dev/null
  cp -f "$COOKIE_JAR.sah.json" /app/logs/last_reboot_alt.json 2>/dev/null || true
}

# ---------- Implémentations par méthode ----------
do_basic_get(){
  [[ -z "$ENDPOINT" || "$ENDPOINT" == "null" ]] && { log "ERROR: BASIC_GET requires .endpoint"; return 1; }
  curl -s -u "$USER:$PASS" "http://$IP$ENDPOINT" >/dev/null
}

do_form_post(){
  curl -s -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data "$FORM_PAYLOAD" "http://$IP$FORM_URL" >/dev/null
  curl -s -c "$COOKIE_JAR" -b "$COOKIE_JAR" "http://$IP$FORM_REBOOT_URL" >/dev/null
}

do_raw_curl(){
  # 1) Login depuis config si fourni
  if [[ -n "$RAW_LOGIN_CFG" ]]; then
    raw_eval "$RAW_LOGIN_CFG"
  else
    sah_login
  fi

  # Si pas de context, retente login SAH standard
  if [[ ! -s "$COOKIE_JAR.ctx" || -z "$(tr -d '\r\n' < "$COOKIE_JAR.ctx" 2>/dev/null || true)" ]]; then
    log "WARN: no contextID from config login; trying SAH fallback"
    sah_login
  fi

  # 2) Reboot via config si fourni, sinon SAH par défaut
  if [[ -n "$RAW_REBOOT_CFG" ]]; then
    raw_eval "$RAW_REBOOT_CFG" || true
  else
    sah_reboot_auth_xctx || true
    sah_reboot_xctx_only || true
  fi
}

# ---------- Exécution ----------
log "Checking $IP"
if ping_ok; then
  log "Repeater reachable before reboot."
else
  log "WARNING: not reachable before reboot (proceeding anyway)."
fi

# valeur par défaut si METHOD absent/vidé
[[ -z "$METHOD" || "$METHOD" == "null" ]] && METHOD="RAW_CURL"
log "Triggering reboot with METHOD=$METHOD"

case "$METHOD" in
  BASIC_GET)  do_basic_get ;;
  FORM_POST)  do_form_post ;;
  RAW_CURL)   do_raw_curl ;;
  *)          log "ERROR: unknown METHOD '$METHOD'"; exit 2 ;;
esac

log "Reboot command sent. Waiting ${WAIT_AFTER_TRIGGER}s..."
sleep "$WAIT_AFTER_TRIGGER"

log "Verifying it comes back (timeout ${VERIFY_TIMEOUT}s)"
start="$(date +%s)"
while true; do
  if ping_ok; then
    log "✅ Repeater back online."
    break
  fi
  now="$(date +%s)"
  if (( now - start > VERIFY_TIMEOUT )); then
    log "❌ Timeout waiting device to return."
    exit 3
  fi
  sleep "$SLEEP_BETWEEN_PINGS"
  log "...still waiting"
done

log "Done."
