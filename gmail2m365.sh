#!/usr/bin/env bash
# Gmail (IMAP) -> Microsoft 365 (IMAP/XOAUTH2) relay.
#
# Usage:  gmail2m365.sh /etc/gmail2m365/<name>.conf
# Cron:   * * * * * root /usr/local/bin/gmail2m365.sh /etc/gmail2m365/<name>.conf >> /var/log/gmail2m365-<name>.log 2>&1
#
# One config file per destination mailbox. Each instance has its own lock, token
# file, cache, and log, so instances for different users may run concurrently.
set -euo pipefail

# ---- Microsoft 365 app registration (client credentials flow), shared by all instances ----
# /etc/gmail2m365/m365.conf must define TENANT_ID and CLIENT_ID; the client secret goes in
# CLIENT_SECRET_FILE (one line, chmod 600). See README.md for the Entra / Exchange Online setup.
M365_CONF="/etc/gmail2m365/m365.conf"
CLIENT_SECRET_FILE="/etc/gmail2m365/m365.secret"
TENANT_ID=""; CLIENT_ID=""
# shellcheck source=/dev/null
[ -r "$M365_CONF" ] && . "$M365_CONF"
[ -n "$TENANT_ID" ] && [ -n "$CLIENT_ID" ] && [ -r "$CLIENT_SECRET_FILE" ] \
  || { echo "$(date -Is) missing TENANT_ID/CLIENT_ID in $M365_CONF or unreadable $CLIENT_SECRET_FILE" >&2; exit 2; }

MAXAGE_DAYS=7          # only look at messages received in the last N days (both sides)
RUN_TIMEOUT=300        # hard wall-clock cap per imapsync run; a hung IMAP session must not block the queue
GMAIL_HOST="imaps://imap.gmail.com"

# ---- Per-instance config ----
CONF="${1:?usage: $0 /etc/gmail2m365/<name>.conf}"
NAME="$(basename "$CONF" .conf)"
# Config must define:
#   M365_USER="user@domain"                       destination mailbox
#   GMAIL_ACCOUNTS=( "addr@gmail.com:/etc/gmail2m365/gmail-<x>.pw" ... )
# Optional:
#   RETAIN_DAYS=0      0  = delete each message from Gmail INBOX right after it is copied (POP-style).
#                      N  = leave messages in Gmail INBOX for N days. The highest Gmail UID already
#                           handled is remembered per account, and later runs only look at newer UIDs,
#                           so deleting a message on Exchange does NOT re-copy it (Gmail UIDs only
#                           ever increase). Once a day, INBOX messages older than N days are expunged.
#   KUMA_PUSH_URL=""   Uptime Kuma push URL; hit after every successful run.
#   EXTRA_ARGS=( --dry )  extra imapsync flags, e.g. --dry or --justlogin for testing
M365_USER=""; GMAIL_ACCOUNTS=(); RETAIN_DAYS=0; KUMA_PUSH_URL=""; EXTRA_ARGS=()
# shellcheck source=/dev/null
. "$CONF"
[ -n "$M365_USER" ] && [ "${#GMAIL_ACCOUNTS[@]}" -gt 0 ] || { echo "$(date -Is) [$NAME] config incomplete" >&2; exit 2; }

STATE_DIR="/var/lib/gmail2m365/$NAME"
TOKEN_FILE="$STATE_DIR/m365.token"
mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"

# Only one instance per config at a time; a copy+expunge cycle must never overlap another.
exec 9>"$STATE_DIR/lock"
flock -n 9 || { echo "$(date -Is) [$NAME] previous run still active, skipping"; exit 0; }

log() { echo "$(date -Is) [$NAME] $*"; }

# Run an IMAP command against a Gmail folder with curl. Password never hits the command line.
gmail_cmd() {  # user pwfile folder command
  curl -sS --fail --url "${GMAIL_HOST}/$3" -K - -X "$4" <<<"user = \"$1:$(<"$2")\""
}

# ---- 1. Fresh access token (lifetime ~1h, so just mint one per run) ----
resp=$(curl -sS --fail-with-body -X POST \
  "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token" \
  --data-urlencode "client_id=${CLIENT_ID}" \
  --data-urlencode "client_secret=$(<"$CLIENT_SECRET_FILE")" \
  --data-urlencode "scope=https://outlook.office365.com/.default" \
  --data-urlencode "grant_type=client_credentials") || true
TOKEN=$(jq -r '.access_token // empty' <<<"$resp" 2>/dev/null || true)
[ -n "$TOKEN" ] || { log "token request failed: $(jq -r '.error_description // .' <<<"$resp" 2>/dev/null || echo "$resp")" >&2; exit 1; }
( umask 077; printf '%s\n' "$TOKEN" > "$TOKEN_FILE" )
trap 'rm -f "$TOKEN_FILE"' EXIT

# ---- 2. Copy INBOX Gmail -> Exchange ----
rc=0
for entry in "${GMAIL_ACCOUNTS[@]}"; do
  gmail_user="${entry%%:*}"
  gmail_pwfile="${entry#*:}"
  mode_args=( --delete1 --expunge1 )
  if [ "$RETAIN_DAYS" -gt 0 ]; then
    # Snapshot Gmail's UIDVALIDITY/UIDNEXT *before* syncing so mail arriving mid-run is not skipped.
    st=$(gmail_cmd "$gmail_user" "$gmail_pwfile" "" "STATUS INBOX (UIDVALIDITY UIDNEXT)" | tr -d '\r' || true)
    validity=$(sed -n 's/.*UIDVALIDITY \([0-9]*\).*/\1/p' <<<"$st")
    uidnext=$(sed -n 's/.*UIDNEXT \([0-9]*\).*/\1/p' <<<"$st")
    [ -n "$validity" ] && [ -n "$uidnext" ] || { log "could not read INBOX status for ${gmail_user}: $st" >&2; rc=1; continue; }
    statefile="$STATE_DIR/lastuid.${gmail_user}"
    last=0
    if [ -s "$statefile" ]; then
      read -r sv slast < "$statefile"
      if [ "$sv" = "$validity" ]; then last=$slast; else log "UIDVALIDITY changed for ${gmail_user} ($sv -> $validity); rescanning INBOX"; fi
    fi
    mode_args=()
    [ "$last" -gt 0 ] && mode_args=( --search1 "NOT UID 1:${last}" )
  fi
  log "syncing ${gmail_user} -> ${M365_USER} (retain=${RETAIN_DAYS}d${last:+, after uid $last})"
  timeout --kill-after=30 "$RUN_TIMEOUT" imapsync \
    --gmail1  --user1 "$gmail_user" --passfile1 "$gmail_pwfile" \
    --office2 --user2 "$M365_USER"  --oauthaccesstoken2 "$TOKEN_FILE" \
    --folder INBOX --maxage "$MAXAGE_DAYS" \
    --syncinternaldates \
    --useheader Message-Id \
    --regexflag 's/\$Phishing//g' --regexflag 's/\$NotPhishing//g' \
    "${mode_args[@]}" \
    --nofoldersizes --noreleasecheck --nolog \
    "${EXTRA_ARGS[@]}" \
    || { rc=$?; [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ] && log "imapsync killed after ${RUN_TIMEOUT}s (rc=$rc)"; }

  # Advance the high-water mark only after a real, successful run (never for --dry / --justlogin).
  if [ "$RETAIN_DAYS" -gt 0 ] && [ "$rc" -eq 0 ] && [[ " ${EXTRA_ARGS[*]} " != *" --dry "* ]] && [[ " ${EXTRA_ARGS[*]} " != *" --justlogin "* ]]; then
    ( umask 077; echo "$validity $((uidnext - 1))" > "$statefile" )
  fi

  # ---- 3. Retention: once a day, expunge INBOX messages older than RETAIN_DAYS ----
  if [ "$RETAIN_DAYS" -gt 0 ] && [ "$rc" -eq 0 ]; then
    stamp="$STATE_DIR/expire.${gmail_user}"
    if [ ! -e "$stamp" ] || [ "$(find "$stamp" -mmin +1440 2>/dev/null)" ]; then
      cutoff=$(date -u -d "-${RETAIN_DAYS} days" +%d-%b-%Y)
      uids=$(gmail_cmd "$gmail_user" "$gmail_pwfile" INBOX "UID SEARCH BEFORE $cutoff" \
             | tr -d '\r' | sed -n 's/^\* SEARCH *//p' | tr ' ' ',')
      if [ -n "$uids" ]; then
        gmail_cmd "$gmail_user" "$gmail_pwfile" INBOX "UID STORE $uids +FLAGS.SILENT (\\Deleted)" >/dev/null
        gmail_cmd "$gmail_user" "$gmail_pwfile" INBOX "EXPUNGE" >/dev/null
        log "expired $(tr ',' '\n' <<<"$uids" | wc -l) message(s) older than $cutoff from ${gmail_user} INBOX"
      else
        log "nothing older than $cutoff to expire from ${gmail_user} INBOX"
      fi
      touch "$stamp"
    fi
  fi
done

# ---- 4. Heartbeat ----
if [ "$rc" -eq 0 ] && [ -n "$KUMA_PUSH_URL" ]; then
  curl -sS -m 10 -o /dev/null "$KUMA_PUSH_URL" || log "kuma push failed"
fi
exit "$rc"
