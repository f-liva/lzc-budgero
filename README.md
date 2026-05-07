# lzc-budgero

[Budgero](https://budgero.app/) (manual-first, privacy-focused budgeting app) packaged as a [Lazycat NAS](https://lazycat.cloud) `.lpk` for the LCMD client.

## Architettura

```
[browser]
    ↓ Lazycat client (OIDC reverse proxy)
    ↓
[container fliva/lzc-budgero]
  entrypoint.sh
   ├─ /data/jwt.secret  (random 64-hex, generato al primo avvio)
   ├─ admin user        (bootstrap idempotente da env vars)
   └─ exec /app/budgero serve --port 3001
    ↓
SQLite /data/budgero.db
```

- **Reverse proxy:** Lazycat espone l'app sul subdomain `budgero` con OIDC integrato.
- **Persistenza:** unico bind `/lzcapp/var/data` → `/data` nel container. Contiene `budgero.db` (SQLite) e `jwt.secret`.
- **Auth:** doppio login. Lazycat OIDC + Budgero local login. Vedi sezione [Limitazioni note](#limitazioni-note).

## Prerequisiti

- Lazycat LCMD Microserver con client installato
- `lzc-cli` installato: `npm install -g @lazycatcloud/lzc-cli`
- `lzc-cli box add-public-key` eseguito
- Docker (per buildare la wrapper image)
- Account Docker Hub (push wrapper image)

## Build & release

### 1. Build wrapper image

```bash
cd docker/
docker build -t fliva/lzc-budgero:1.0.0 -t fliva/lzc-budgero:latest .
docker push fliva/lzc-budgero:1.0.0
docker push fliva/lzc-budgero:latest
```

### 2. Mirror su Lazycat registry

```bash
lzc-cli appstore copy-image fliva/lzc-budgero:1.0.0
# output: registry.lazycat.cloud/u30562882/fliva/lzc-budgero@sha256:DIGEST
```

### 3. Aggiorna `image:` in `budgero-lzc/lzc-manifest.yml`

Sostituisci `REPLACE_AT_BUILD` con il digest restituito.

### 4. Configura admin password (PRIMA del build .lpk)

In `budgero-lzc/lzc-manifest.yml` modifica:
```yaml
- BUDGERO_ADMIN_PASS=la-tua-password-sicura
```

### 5. Build `.lpk`

```bash
cd budgero-lzc/
./install.sh
```

### 6. Install da PowerShell (Windows)

`lzc-cli` da WSL non raggiunge il NAS (vedi `lzc-openfang` README). Install da Windows:

```powershell
cp cloud.lazycat.app.budgero-v1.0.0.lpk /mnt/c/Users/fede9/Desktop/
lzc-cli app install C:\Users\fede9\Desktop\cloud.lazycat.app.budgero-v1.0.0.lpk
```

## Configurazione

| Env var | Default | Note |
|---|---|---|
| `DB_PATH` | `/data/budgero.db` | Path SQLite (persistente) |
| `PORT` | `3001` | Listen port interno |
| `SELF_HOSTABLE` | `true` | Richiesto da Budgero in self-host |
| `SELF_HOST_JWT_TTL_HOURS` | `720` | Sessione 30 giorni |
| `BUDGERO_ADMIN_USER` | `admin` | Username admin bootstrap |
| `BUDGERO_ADMIN_PASS` | `changeme-on-first-login` | **CAMBIA prima dell'install** |
| `BUDGERO_ADMIN_NAME` | `Admin` | Display name |
| `CURRENCYLAYER_API_KEY` | (unset) | Opzionale, abilita multi-currency |
| `SELF_HOST_JWT_SECRET` | auto da `/data/jwt.secret` | Non settare manualmente |

## Limitazioni note

### Doppio login (Lazycat OIDC + Budgero)

Budgero non supporta header SSO (`X-Remote-User`, `X-Forwarded-User`, OIDC trusted-proxy). Confermato ispezionando il binario. L'utente vede:

1. Login Lazycat (OIDC del NAS)
2. Login Budgero (username/password locale)

Workaround attuale: bootstrap admin via env vars al primo avvio. Niente da fare se non aspettare che upstream supporti header auth.

### Closed-source binary

Budgero non ha repo pubblico. Il wrapper può solo:
- aggiungere entrypoint
- iniettare env vars
- gestire persistenza

Patch del comportamento upstream impossibili. Ad ogni release upstream → re-build wrapper image.

### `latest` mutabile upstream

`FROM budgero/budgero:latest` non è pinnato per digest. Future release v1.x: pin `FROM budgero/budgero@sha256:...` per riproducibilità totale.

## Comandi utili

```bash
# Logs
lzc-cli app log cloud.lazycat.app.budgero

# Status
lzc-cli app status cloud.lazycat.app.budgero

# Reset admin password (dentro il container, via lzc-cli devshell)
lzc-cli app devshell cloud.lazycat.app.budgero
/app/budgero admin reset-password --username admin

# Uninstall (DISTRUGGE i dati in /lzcapp/var/data)
lzc-cli app uninstall cloud.lazycat.app.budgero
```

## Struttura repo

```
lzc-budgero/
├── docker/
│   ├── Dockerfile          # FROM budgero/budgero:latest + entrypoint
│   └── entrypoint.sh       # JWT + admin bootstrap idempotente
├── budgero-lzc/
│   ├── lzc-manifest.yml    # manifest LCMD
│   ├── lzc-build.yml       # config build (pkgout, icon)
│   ├── icon.png            # 144×144 (da budgero.app/logo_144.png)
│   └── install.sh          # build .lpk + hint install
├── docs/superpowers/specs/
│   └── 2026-05-07-lzc-budgero-design.md
├── README.md
├── LICENSE                 # MIT (solo wrapper code)
└── .gitignore
```

## License

- **Wrapper code** (Dockerfile, entrypoint, manifest, scripts): MIT, vedi `LICENSE`.
- **Budgero binary**: proprietary, distribuito sotto i termini self-host di [budgero.app](https://budgero.app). Free per self-host, source non pubblico.
