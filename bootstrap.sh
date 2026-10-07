#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# bootstrap.sh — generate identity-stack secrets, then start the stack.
#
# Safe to re-run: secrets that already exist are left exactly as they are.
# That matters more than it looks. AUTHENTIK_SECRET_KEY is read on every boot,
# so regenerating it would invalidate live sessions, and PG_PASS is baked into
# an already-initialised Postgres volume — rotating it there just locks
# Authentik out of its own database.
#
# Usage:  ./bootstrap.sh            generate what is missing, then start
#         ./bootstrap.sh --secrets  generate only, do not start
# ---------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")"

START=true
[[ "${1:-}" == "--secrets" ]] && START=false

info() { printf '==> %s\n' "$*"; }
ok()   { printf '  ok  %s\n' "$*"; }
warn() { printf '  !!  %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# set_env_value <KEY> <VALUE>
# Rewrites KEY=VALUE in place, or appends it when absent. Leaves every other
# line, and the ordering, untouched.
set_env_value() {
  local key=$1 value=$2
  if grep -qE "^${key}=" .env; then
    sed -i "s|^${key}=.*|${key}=${value}|" .env
  else
    printf '%s=%s\n' "$key" "$value" >>.env
  fi
}

# env_value <KEY> — current value, quotes stripped.
env_value() { grep -m1 -E "^$1=" .env | cut -d= -f2- | tr -d '"'; }

# is_set <KEY>
is_set() { local v; v=$(env_value "$1"); [[ -n "$v" ]]; }

# ---------------------------------------------------------------------------
# 1. .env
# ---------------------------------------------------------------------------
info "Preparing .env"
if [[ ! -f .env ]]; then
  [[ -f .env.example ]] || die ".env.example missing"
  cp .env.example .env
  ok "created .env from .env.example"
else
  ok ".env already present"
fi
# Holds the database password and the token signing key.
chmod 600 .env

# ---------------------------------------------------------------------------
# 2. Recovery listener address
# ---------------------------------------------------------------------------
# Authentik's recovery listener is published on this host's Tailscale IP. The
# value belongs to the *host*, not to this repo, which is why ../bootstrap.sh
# owns it and why nothing here hardcodes a 100.x address.
info "Checking recovery listener address"
if ! is_set TAILSCALE_IP; then
  info "TAILSCALE_IP is unset — running ../bootstrap.sh"
  [[ -x ../bootstrap.sh ]] || die "../bootstrap.sh not found or not executable"
  ../bootstrap.sh >/dev/null || die "../bootstrap.sh failed"
fi
is_set TAILSCALE_IP || die "TAILSCALE_IP still unset after ../bootstrap.sh"
ok "recovery listener on 127.0.0.1 and $(env_value TAILSCALE_IP)"

# ---------------------------------------------------------------------------
# 3. Secrets
# ---------------------------------------------------------------------------
info "Checking secrets"
if is_set PG_PASS; then
  ok "PG_PASS present"
else
  # PostgreSQL rejects passwords over 99 characters; 36 random bytes -> 48.
  set_env_value PG_PASS "$(openssl rand -base64 36 | tr -d '\n')"
  ok "generated PG_PASS"
fi

if is_set AUTHENTIK_SECRET_KEY; then
  ok "AUTHENTIK_SECRET_KEY present"
else
  set_env_value AUTHENTIK_SECRET_KEY "$(openssl rand -base64 60 | tr -d '\n')"
  ok "generated AUTHENTIK_SECRET_KEY"
fi

if is_set AUTHENTIK_BOOTSTRAP_TOKEN; then
  ok "AUTHENTIK_BOOTSTRAP_TOKEN present"
else
  set_env_value AUTHENTIK_BOOTSTRAP_TOKEN "$(openssl rand -hex 64)"
  ok "generated AUTHENTIK_BOOTSTRAP_TOKEN"
fi

# OAuth client secrets consumed by blueprints/apps/*.yaml via !Env. Generated
# here rather than committed so no credential lives in git, and generated on
# every host so a migrated server gets a fresh one rather than inheriting a
# secret that may already be public. Never rotated once written — see the
# mirror_secret note below for why a rotation breaks OIDC in a confusing way.
for s in GRAFANA_OAUTH_SECRET OPENWEBUI_OAUTH_SECRET EMBRACE_OAUTH_SECRET; do
  if is_set "$s"; then
    ok "${s} present"
  else
    set_env_value "$s" "$(openssl rand -hex 32)"
    ok "generated ${s}"
  fi
done

# Temporary passwords for the two family accounts created by blueprints/users.yaml
# and injected with !Env. Generated only if missing — regenerating would silently
# reset somebody's password on the next bootstrap run. They are deliberately NOT
# derived from their old OpenWebUI passwords, which were weak; once OpenWebUI is
# on OIDC with local login disabled those old hashes stop mattering anyway.
for u in MARINA_TEMP_PASSWORD MONCEF_TEMP_PASSWORD; do
  if is_set "$u"; then
    ok "${u} present"
  else
    set_env_value "$u" "$(openssl rand -base64 24 | tr -d '\n')"
    ok "generated ${u}"
  fi
done

# --- OAuth client secrets, mirrored into each app stack's own .env -----------
# Compose cannot read across stack directories, so a value consumed by two
# stacks has to be written to two files; this keeps them from drifting.
# Copying rather than sharing is deliberate — see the .env.example note in this
# stack. Neither secret is ever rotated once written: a new value would be
# copied out here, but the running app would keep the old one until someone
# remembered to restart it, and the OIDC callback would fail with an
# "invalid_client" that looks like an Authentik fault rather than a stale copy.
mirror_secret() {
  local key="$1" target_env="$2" stack_label="$3"
  if [[ -f "$target_env" ]]; then
    if grep -q "^${key}=" "$target_env" \
      && [[ "$(env_value "$key")" == "$(grep "^${key}=" "$target_env" | cut -d= -f2-)" ]]; then
      ok "${key} already in sync with ${stack_label}"
    else
      local tmp="${target_env}.tmp.$$"
      grep -v "^${key}=" "$target_env" >"$tmp"
      printf '%s=%s\n' "$key" "$(env_value "$key")" >>"$tmp"
      chmod 600 "$tmp"
      mv "$tmp" "$target_env"
      ok "synced ${key} into ${stack_label}/.env"
    fi
  else
    warn "${stack_label}/.env not found — copy ${key} there yourself"
  fi
}

mirror_secret GRAFANA_OAUTH_SECRET  "../monitoring-stack/.env" "monitoring-stack"
mirror_secret OPENWEBUI_OAUTH_SECRET "../ai-stack/.env"        "ai-stack"
# The couples app lives outside the stack layout, under ai-project/, and has no
# .env of its own yet — the first run creates it from the sibling .env.example.
mirror_secret EMBRACE_OAUTH_SECRET    "../ai-project/intimacy-connection/.env" "intimacy-connection"

# The admin credentials are left blank on purpose. Generating a password the
# operator never sees is worse than not generating one, so these must be typed.
if ! is_set AUTHENTIK_BOOTSTRAP_EMAIL; then
  die "set AUTHENTIK_BOOTSTRAP_EMAIL in .env (your address — this becomes the akadmin login)"
fi
ok "AUTHENTIK_BOOTSTRAP_EMAIL set"
if ! is_set AUTHENTIK_BOOTSTRAP_PASSWORD; then
  die "set AUTHENTIK_BOOTSTRAP_PASSWORD in .env (akadmin's password — no default exists)"
fi
ok "AUTHENTIK_BOOTSTRAP_PASSWORD set"

# Guard the one limit that bites silently.
(( $(wc -c <<<"$(env_value PG_PASS)") <= 99 )) || die "PG_PASS exceeds PostgreSQL's 99-character limit"

# ---------------------------------------------------------------------------
# 4. Directories
# ---------------------------------------------------------------------------
info "Creating data directories"
mkdir -p data/postgres data/authentik data/certs data/media data/templates
ok "data/ ready"

# ---------------------------------------------------------------------------
# 5. Validate and start
# ---------------------------------------------------------------------------
info "Validating compose"
# Resolves and checks every variable, including the ports mapping that must
# fail closed if TAILSCALE_IP went missing.
docker compose config --quiet || die "compose config is invalid"
ok "compose config valid"

if $START; then
  info "Starting authentik"
  docker compose up -d
  cat <<EOF

  Starting. First boot runs database migrations and takes a few minutes.

  Recovery listener (not reachable from the internet):
    http://127.0.0.1:9000              from this host
    http://$(env_value TAILSCALE_IP):9000        from any device on your tailnet

  Watch for healthy:
    docker compose ps

  Then finish setup in the UI: create a user, and enrol a TOTP authenticator
  under User settings -> Devices. MFA is mandatory — an account with a password
  and no second factor defeats the point of having an IdP.
EOF
else
  info "Secrets ready. Start with: docker compose up -d"
fi