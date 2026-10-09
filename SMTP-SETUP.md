# SMTP Setup — authentik (192.168.1.49)

## What was changed (2026-10-09)

The following block lives in the **gitignored `.env`** in `~/Documents/identity-stack/`
(`.gitignore:2:.env`; `git status` stays clean — nothing committed):

```
AUTHENTIK_EMAIL__HOST=smtp-mail.outlook.com
AUTHENTIK_EMAIL__PORT=587
AUTHENTIK_EMAIL__USERNAME=bel-g-stylas@hotmail.com
AUTHENTIK_EMAIL__PASSWORD=<set — real password, not shown>
AUTHENTIK_EMAIL__USE_TLS=true
AUTHENTIK_EMAIL__FROM=bel-g-stylas@hotmail.com
```

`docker-compose.yaml` was NOT touched directly by the password step (zero-touch
constraint held); the approved one-time compose edit (interpolating the 6 vars into
the `environment:` blocks of both `authentik-server` and `authentik-worker`) was done
in cycle 2.

## Status: app password SET (2026-10-09) — test email STILL FAILED (535 5.7.3 — SMTP AUTH likely disabled for the mailbox)

1. **Password set** (2026-10-09): the `AUTHENTIK_EMAIL__PASSWORD` line was replaced with
   the real password, then (this cycle) with the 16-char Microsoft **app password**
   (same sed procedure, masked: `AUTHENTIK_EMAIL__PASSWORD=<set>`; `.env` perms 600;
   verified byte-identical inside the container via hash comparison).
2. **Config active**: after `docker compose up -d authentik-server`, all 6 vars reach
   the container: `docker exec authentik-server env | grep -c AUTHENTIK_EMAIL` → 6.
3. **Test email FAILED** — `ak sendtestemail bel-g-stylas@hotmail.com` returns:

```
smtplib.SMTPAuthenticationError: (535, b'5.7.3 Authentication unsuccessful
[ZR0P278CA0054.CHEP278.PROD.OUTLOOK.COM 2026-10-09T09:15:06.501Z 08DF24177F9C534D]')
```

Microsoft rejected the basic-auth login for `smtp-mail.outlook.com:587` (STARTTLS).
For personal outlook.com/hotmail.com accounts Microsoft **disables SMTP basic auth by
default** — the account password alone will not work. Fix (requires the user):

- The **app password was created and swapped in** (2026-10-09, this cycle) — still
  rejected with 535 5.7.3. When even a valid app password is refused, the mailbox has
  **SMTP AUTH disabled** at the account level. Remaining fix (requires the user):
  sign in at **account.live.com/Deceive** (or Outlook web → Settings → Mail →
  Sync email → POP and IMAP) and turn **SMTP AUTH ON** for the mailbox, then re-test.

**Password reset & alerts are therefore NOT live yet** — authentik config is correct,
the app password is in place and reaches the container, but Microsoft still refuses the
credential. Re-test (this exact command) after SMTP AUTH is enabled:

```
docker exec authentik-server ak sendtestemail bel-g-stylas@hotmail.com
```

## Password-reset prerequisites (verified 2026-10-09)

- This instance currently has **no `default-password-reset` flow and no Email stage**
  (`EmailStage.objects.count()` → 0). The stock blueprint instance
  `Default - Password reset flow` (`default/flow-password-reset.yaml`) is absent — only
  `Default - Password change flow` exists.
- Before password reset works, enable that stock blueprint (admin UI →
  **Customization → Blueprints**, or re-create the instance pointing at
  `default/flow-password-reset.yaml`). The stock password-reset email stage uses
  **global settings**, so it picks up the `.env` SMTP config automatically.

## Regression status after the change (all green)

- `docker compose config` → VALID
- sso.ghoulhub.uk → HTTP 302 (healthy)
- Estate: 39/39 containers Up (0 not-up)
- comfyui → 302 redirect to sso authorize endpoint (forward-auth intact)
- Session duration: `default-authentication-login days=30` (unchanged)
- open-webui direct login (admin user, <redacted>) → HTTP 200 + token
- identity repo: `git status -sb` → clean (`main...origin/main`, .env gitignored)
- SMTP-SETUP.md left untracked (not committed)
