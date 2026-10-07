#!/bin/sh
# Consistent backup of the Authentik Postgres database.
#
# WHY THIS EXISTS INSTEAD OF BACKING UP THE DATA DIRECTORY
# -------------------------------------------------------
# Kopia's Tier 1 policy copies /source, which includes identity-stack/data/
# postgres. That is NOT a valid backup of a running database: Postgres is
# appending to its WAL and rewriting pages while Kopia reads them, so the copy
# can capture a torn page and fail recovery on restore. It also looks like a
# perfectly good backup right up until the day you need it.
#
# pg_dump takes a consistent snapshot through the server, so this is the only
# copy worth trusting. The raw directory is added to the Kopia ignore list in
# ../backup-stack/bootstrap.sh for exactly that reason.
#
# This matters more than it used to: Authentik is now the single point of
# failure for SSO on every app (Grafana, OpenWebUI, embrace, Jellyseerr, Pip),
# so losing this database means losing human access to the whole homelab.
#
# Output goes to ./backups/ on the host, which Kopia's Tier 1 policy DOES
# copy. Each file is pg_dump custom format (-Fc): compressed, and restorable
# with pg_restore.
#
# Usage:
#   docker compose run --rm db-backup            # loop forever (normal)
#   docker compose run --rm db-backup --once     # take one dump and exit
#
set -eu

: "${PGHOST:?PGHOST is required}"
: "${PGDATABASE:?PGDATABASE is required}"
: "${PGUSER:?PGUSER is required}"
: "${PGPASSWORD:?PGPASSWORD is required}"

BACKUP_AT="${BACKUP_AT:-02:47}"
BACKUP_KEEP_DAYS="${BACKUP_KEEP_DAYS:-14}"
BACKUP_DIR="${BACKUP_DIR:-/backups}"
ONCE="${1:-}"

log() { echo "[db-backup $(date '+%F %T %Z')] $*"; }

# Strip leading zeros so "02" becomes 2 and arithmetic does not read it as
# octal. POSIX sh has no $((10#n)) base prefix -- that is a bashism and busybox
# ash rejects it outright -- so this is the portable equivalent.
#
# This is not a hypothetical tidy-up. `date +%H` returns "08" between 08:00 and
# 08:59, and arithmetic treats a leading zero as octal, so `$(date +%H) * 3600`
# dies with "arithmetic syntax error" for a full hour every single day. The same
# applies to %M and %S whenever they land on 08 or 09.
strip_zeroes() {
  v=$(printf '%s' "$1" | sed 's/^0*//')
  [ -n "$v" ] || v=0
  printf '%s' "$v"
}

mkdir -p "$BACKUP_DIR"

# Print the epoch seconds of the next BACKUP_AT occurrence, in local time.
#
# Deliberately pure arithmetic on today's local midnight rather than
# `date -d "..."`: this is Alpine/busybox, where GNU-style date parsing is not
# available, and a silently-failing date parse would turn this into a loop that
# dumps once and then never again. The log line prints the resolved time so a
# wrong schedule is visible rather than invisible.
seconds_until_next_run() {
  now=$(date +%s)
  h=$(strip_zeroes "$(date +%H)")
  m=$(strip_zeroes "$(date +%M)")
  s=$(strip_zeroes "$(date +%S)")
  midnight=$((now - h * 3600 - m * 60 - s))
  hh=$(strip_zeroes "${BACKUP_AT%%:*}")
  mm=$(strip_zeroes "${BACKUP_AT##*:}")
  target=$((midnight + hh * 3600 + mm * 60))
  if [ "$target" -le "$now" ]; then
    target=$((target + 86400))
  fi
  echo $((target - now))
}

take_dump() {
  stamp=$(date '+%Y%m%d-%H%M%S')
  out="$BACKUP_DIR/authentik-$stamp.dump"
  tmp="$out.partial"

  # --no-owner/--no-acl so a restore does not need the original role to exist.
  # --clean so the dump does not depend on objects that were dropped earlier in
  # the source database.
  if ! pg_dump --format=custom --compress=6 --no-owner --no-acl --clean \
       --file="$tmp" ; then
    log "pg_dump FAILED; leaving no partial file"
    rm -f "$tmp"
    return 1
  fi

  # A zero-byte or truncated file is worse than no file, because it looks like a
  # backup. Verify the archive is readable before publishing it under its final
  # name, and write to .partial until then so a crash mid-dump cannot be
  # mistaken for a good one.
  if [ ! -s "$tmp" ] || ! pg_restore --list "$tmp" >/dev/null 2>&1; then
    log "dump produced an unreadable archive; discarding"
    rm -f "$tmp"
    return 1
  fi

  mv "$tmp" "$out"
  size=$(du -h "$out" | cut -f1)
  log "wrote $out ($size)"

  # Retention. Only files this script creates are considered.
  find "$BACKUP_DIR" -maxdepth 1 -name 'authentik-*.dump' -type f \
    -mtime "+$BACKUP_KEEP_DAYS" -print -delete | sed 's/^/[db-backup] pruned /'
}

log "PGHOST=$PGHOST PGDATABASE=$PGDATABASE schedule=$BACKUP_AT local keep=$BACKUP_KEEP_DAYS day(s)"

until pg_isready -q; do
  log "postgres not ready yet, waiting"
  sleep 5
done
log "postgres is ready"

if [ "$ONCE" = "--once" ]; then
  take_dump
  exit $?
fi

while :; do
  wait_secs=$(seconds_until_next_run)
  log "next dump in ${wait_secs}s (local now $(date '+%F %T %Z'))"
  sleep "$wait_secs"
  take_dump || log "dump failed this run; will retry at the next scheduled time"
done
