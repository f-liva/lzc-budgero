# lzc-budgero — Design Spec

**Date:** 2026-05-07
**Author:** Federico Liva
**Status:** Approved (pending implementation)

## Goal

Wrap [Budgero](https://budgero.app/) (manual-first, privacy-focused budgeting app) as a Lazycat NAS app (`.lpk`) installable via the LCMD client. Enable single-click install on Lazycat NAS with persistent storage and a working admin user out of the box.

## Constraints

- Budgero ships as closed-source single binary in Docker image `budgero/budgero:latest` (Go, ~133 MB). No GitHub source.
- No SSO / reverse-proxy header auth in Budgero. Local username+password+JWT only. Confirmed by binary inspection (no `X-Remote-User`, `X-Forwarded-User`, `OIDC`, `SSO` strings).
- Lazycat platform forces containers to run as root, ignoring image `USER` directive (carryover knowledge from `lzc-openfang`).
- WSL+Lazycat networking constraint: `lzc-cli app install` must be run from PowerShell on Windows; build can happen in WSL.

## Architecture

```
[user browser]
     │
     ▼ Lazycat client → cloud.lazycat OIDC reverse proxy
                              │
                              ▼ http://budgero.cloud.lazycat.app.budgero.lzcapp:3001
                        [container fliva/lzc-budgero]
                              │  entrypoint.sh
                              │   ├ ensure /data/jwt.secret (random 64-hex on first run)
                              │   ├ ensure admin user (idempotent, env-driven)
                              │   └ exec /app/budgero serve
                              ▼
                        SQLite /data/budgero.db
```

**Auth model:** Two login screens. Lazycat OIDC at proxy, Budgero local login at app. Inevitable until upstream adds trusted-proxy header support. Documented as a known limitation in README.

**Data persistence:** Single bind `/lzcapp/var/data` → `/data`. Holds `budgero.db` (SQLite) + `jwt.secret` (per-install random).

**Image strategy:** Custom wrapper `FROM budgero/budgero:latest`, built and pushed to Docker Hub as `fliva/lzc-budgero:vX.Y.Z`, then mirrored to Lazycat registry via `lzc-cli appstore copy-image` and pinned by digest in the manifest. Same pattern as `lzc-librefang`.

## Repo structure

```
lzc-budgero/
├── README.md
├── LICENSE                       # MIT (wrapper code only)
├── .gitignore                    # *.lpk, *.bak, dist artifacts
├── docker/
│   ├── Dockerfile                # wrapper image
│   └── entrypoint.sh             # JWT + admin bootstrap
├── budgero-lzc/
│   ├── lzc-manifest.yml
│   ├── lzc-build.yml
│   ├── icon.png                  # 144x144, sourced from budgero.app/logo_144.png
│   └── install.sh                # build .lpk, hint install command
└── docs/superpowers/specs/2026-05-07-lzc-budgero-design.md
```

No `content/defaults/`, no `config/`, no `hands/` — Budgero needs no on-disk config (env-only) and is not an AI agent.

## Components

### `docker/Dockerfile`

```dockerfile
FROM budgero/budgero:latest
USER root
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
CMD ["serve"]
```

### `docker/entrypoint.sh`

Idempotent. Generates a 64-hex JWT secret on first run and persists it. Creates the admin user only if env vars are set and the user doesn't already exist.

```sh
#!/bin/sh
set -e

JWT_FILE="${BUDGERO_JWT_FILE:-/data/jwt.secret}"
mkdir -p "$(dirname "$JWT_FILE")"

if [ ! -s "$JWT_FILE" ]; then
  od -An -tx1 -N32 /dev/urandom | tr -d ' \n' > "$JWT_FILE"
  chmod 600 "$JWT_FILE"
fi
export SELF_HOST_JWT_SECRET="$(cat "$JWT_FILE")"

if [ -n "${BUDGERO_ADMIN_USER:-}" ] && [ -n "${BUDGERO_ADMIN_PASS:-}" ]; then
  if ! /app/budgero admin list-users 2>/dev/null | grep -qi "$BUDGERO_ADMIN_USER"; then
    echo "[entrypoint] bootstrapping admin user: $BUDGERO_ADMIN_USER"
    /app/budgero admin create-user \
      --username "$BUDGERO_ADMIN_USER" \
      --password "$BUDGERO_ADMIN_PASS" \
      --name "${BUDGERO_ADMIN_NAME:-Admin}" \
      --admin || echo "[entrypoint] admin create-user failed (may already exist)"
  fi
fi

exec /app/budgero "$@"
```

### `budgero-lzc/lzc-manifest.yml`

```yaml
lzc-sdk-version: '0.1'
name: Budgero
package: cloud.lazycat.app.budgero
version: 1.0.0
description: Manual-first private budgeting (self-hosted). No bank connections.
homepage: https://budgero.app
author: Federico Liva
locales:
  en:
    name: Budgero
    description: Manual-first private budgeting (self-hosted). No bank connections.
  it:
    name: Budgero
    description: Budgeting privato manuale (self-hosted). Nessun collegamento bancario.
  zh:
    name: Budgero
    description: 手动优先的隐私预算应用（自托管）。无需连接银行账户。

application:
  routes:
    - /=http://budgero.cloud.lazycat.app.budgero.lzcapp:3001
  subdomain: budgero

services:
  budgero:
    image: registry.lazycat.cloud/u30562882/fliva/lzc-budgero:REPLACE_AT_BUILD
    binds:
      - /lzcapp/var/data:/data
    environment:
      - DB_PATH=/data/budgero.db
      - PORT=3001
      - SELF_HOSTABLE=true
      - SELF_HOST_JWT_TTL_HOURS=720
      - BUDGERO_ADMIN_USER=admin
      - BUDGERO_ADMIN_PASS=changeme-on-first-login
      - BUDGERO_ADMIN_NAME=Admin
      # - CURRENCYLAYER_API_KEY=  # optional, multi-currency support
```

The `REPLACE_AT_BUILD` placeholder is updated by hand (or by the install script) with the digest returned from `lzc-cli appstore copy-image` after each upstream rebuild.

### `budgero-lzc/lzc-build.yml`

```yaml
pkgout: ./
icon: icon.png
```

### `budgero-lzc/install.sh`

```sh
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== lzc-budgero: build .lpk ==="
cd "$SCRIPT_DIR"
lzc-cli project build

LPK=$(find . -maxdepth 1 -name "*.lpk" -type f | head -1)
echo
echo "Built: $LPK"
echo
echo "Install from PowerShell (WSL networking limitation):"
echo "  cp $LPK /mnt/c/Users/fede9/Desktop/"
echo "  lzc-cli app install C:\\Users\\fede9\\Desktop\\$(basename $LPK)"
echo
echo "Logs:    lzc-cli app log cloud.lazycat.app.budgero"
```

## Release flow (manual, per upstream version)

1. **Build wrapper image:**
   ```sh
   cd docker/
   docker build -t fliva/lzc-budgero:1.0.0 -t fliva/lzc-budgero:latest .
   docker push fliva/lzc-budgero:1.0.0
   docker push fliva/lzc-budgero:latest
   ```

2. **Mirror to Lazycat registry:**
   ```sh
   lzc-cli appstore copy-image fliva/lzc-budgero:1.0.0
   # outputs: registry.lazycat.cloud/u30562882/fliva/lzc-budgero@sha256:...
   ```

3. **Update `image:` line in `lzc-manifest.yml`** with the returned digest.

4. **Build the `.lpk`:**
   ```sh
   cd ../budgero-lzc/
   ./install.sh
   ```

5. **Install from PowerShell** (WSL→NAS networking workaround documented in README).

No CI/CD in the first cut. Releases are infrequent and tied to upstream Budgero updates.

## Configuration & env vars

| Variable | Default | Purpose |
|---|---|---|
| `DB_PATH` | `/data/budgero.db` | SQLite location (persistent) |
| `PORT` | `3001` | Internal listen port |
| `SELF_HOSTABLE` | `true` | Required by Budgero binary in self-host mode |
| `SELF_HOST_JWT_SECRET` | (set by entrypoint from `/data/jwt.secret`) | JWT signing secret |
| `SELF_HOST_JWT_TTL_HOURS` | `720` | 30-day session TTL |
| `BUDGERO_ADMIN_USER` | `admin` | Admin username for first-run bootstrap |
| `BUDGERO_ADMIN_PASS` | `changeme-on-first-login` | Edit before installing the `.lpk` |
| `BUDGERO_ADMIN_NAME` | `Admin` | Display name |
| `CURRENCYLAYER_API_KEY` | (unset) | Optional, enables multi-currency rates |

User must change `BUDGERO_ADMIN_PASS` in the manifest before building the `.lpk`. Documented prominently in README.

## Testing strategy

No automated tests — wrapper is YAML manifest + shell scripts. Manual smoke checklist post-install:

1. App icon visible in LCMD client.
2. Click → Lazycat OIDC → Budgero login screen renders (no 500/connection error).
3. Login with the configured admin credentials succeeds.
4. Create a test transaction; restart the app via `lzc-cli`; transaction persists.
5. `lzc-cli app log cloud.lazycat.app.budgero` shows no panic.
6. JWT secret in `/lzcapp/var/data/jwt.secret` is 64 hex chars, mode 600.

## Known limitations / out of scope

- **Double login** (Lazycat OIDC + Budgero local) until upstream supports trusted-proxy header auth.
- **Closed-source binary**: cannot patch upstream behavior, only wrap. Each upstream release requires re-building and re-mirroring our wrapper image.
- **No automated upstream tracking**: no Renovate / GitHub Actions in v1. Upgrades are manual and triggered when the maintainer notices a new Budgero release.
- **`latest` tag is mutable upstream**: we pin our wrapper to a specific Budgero digest by re-tagging during build (future improvement: pin `FROM budgero/budgero@sha256:...` in Dockerfile for full reproducibility).

## License

- Wrapper code (Dockerfile, entrypoint, manifest, scripts): MIT.
- Budgero binary inside the image: proprietary, redistributed under Budgero's self-host terms (free for self-host per the budgero.app landing page; no source available).

README clarifies the split.
