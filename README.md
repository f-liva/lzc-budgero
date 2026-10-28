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

`copy-image` va lanciato dalla **lzc-cli di Windows**: il login allo
appstore vive in quella, non in quella di WSL. Da WSL serve il path assoluto,
`powershell.exe` non è nel PATH:

```bash
/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile \
  -Command "lzc-cli appstore copy-image fliva/lzc-budgero:1.0.18"
```

### 3. Aggiorna `image:` in `budgero-lzc/lzc-manifest.yml`

Sostituisci con il digest `registry.lazycat.cloud/...` restituito. Lo store
rifiuta un `image:` che non punti a quel registry; per il solo deploy privato
`docker.io/...` basta.

### 4. Bump `version:` in `budgero-lzc/package.yml`

Dal layout LPK v2 i campi statici (`package`, `version`, `name`,
`description`, `author`, `homepage`, `locales`) stanno in `package.yml`, non
nel manifest. Senza bump l'install può silenziosamente non fare nulla.

### 5. Build `.lpk`

```bash
cd budgero-lzc/
./install.sh
```

**Per il proprio box, non per lo store**, usare `./install-local.sh`: il
manifest versionato è generico (deve poter andare sullo store, quindi non
contiene il dominio o il DDNS di nessuno), e lo script inietta i valori di
`local.env` nella sola copia che viene pacchettata — build, backup del
volume, install e verifica in un colpo.

```bash
cp local.env.example local.env   # gitignored, riempire
./install-local.sh
```

Il manifest versionato viene ripristinato da un `trap EXIT`, anche se il
build fallisce. Le due iniezioni sono verificate con un `grep` subito dopo il
`sed`: un `SELF_HOST_PUBLIC_IP` non iniettato lascerebbe il bank-sync spento
**in silenzio**, che è esattamente come si perde mezza giornata.

### 6. Install sul NAS via lpk-manager (SSH)

`lzc-cli app install` da WSL fallisce con `ENETUNREACH` (rete Lazycat, IPv6).
La strada che funziona è `lpk-manager` sul NAS via SSH — la chiave è già
installata per `root@192.168.8.115`:

```bash
scp cloud.lazycat.app.budgero-v1.0.18.lpk root@192.168.8.115:/tmp/
ssh root@192.168.8.115 '/lzcsys/bin/lpk-manager install /tmp/cloud.lazycat.app.budgero-v1.0.18.lpk'
ssh root@192.168.8.115 '/lzcsys/bin/lpk-manager start cloud.lazycat.app.budgero'
```

Alternativa (install da PowerShell, se il NAS non è sulla LAN):

```powershell
cp cloud.lazycat.app.budgero-v1.0.18.lpk /mnt/c/Users/fede9/Desktop/
lzc-cli app install C:\Users\fede9\Desktop\cloud.lazycat.app.budgero-v1.0.18.lpk
```

### 7. Backup PRIMA di ogni upgrade che attraversa la v1.19.0

La v1.19.0 migra il DB in avanti e **senza ritorno**: dopo l'update i device
non possono tornare alla 1.18 se non ripristinando un backup del volume.

```bash
ssh root@192.168.8.115 '/lzcsys/bin/lpk-manager stop cloud.lazycat.app.budgero'
ssh root@192.168.8.115 'mkdir -p /lzcsys/var/backups && tar czf /lzcsys/var/backups/budgero-data-$(date +%Y%m%d-%H%M%S).tar.gz \
  -C /lzcsys/data/appvar/cloud.lazycat.app.budgero data'
```

`/lzcsys/var` sopravvive al reboot, `/` no (vedi `/AGENTS.md` sul NAS). Il
container non ha `sqlite3`, quindi si ferma l'app e si copia il volume —
niente `.backup` a caldo. Dopo l'update va **ricaricata la web-app su ogni
device**: una versione vecchia si ferma con "Update required".

## Configurazione

| Env var | Default | Note |
|---|---|---|
| `DB_PATH` | `/data/budgero.db` | Path SQLite (persistente) |
| `PORT` | `3001` | Listen port interno |
| `SELF_HOSTABLE` | `true` | Richiesto da Budgero in self-host |
| `SELF_HOST_JWT_TTL_HOURS` | `720` | Sessione 30 giorni |
| `BUDGERO_ADMIN_USER` | `admin` | Username admin bootstrap |
| `BUDGERO_ADMIN_PASS` | (unset) | Se vuota, l'entrypoint genera una random e la scrive in `/data/admin.pass` + nei log |
| `BUDGERO_ADMIN_FORCE_RESET` | (unset) | `true` resetta la password dell'utente esistente ad ogni avvio |
| `BUDGERO_ADMIN_NAME` | `Admin` | Display name |
| `CURRENCYLAYER_API_KEY` | (unset) | Opzionale, abilita multi-currency |
| `SELF_HOST_JWT_SECRET` | auto da `/data/jwt.secret` | Non settare manualmente |
| `WEBSOCKET_ALLOWED_ORIGINS` | `https://${LAZYCAT_APP_DOMAIN}` | Il server fa `CheckOrigin` sull'upgrade WS: un origin mancante = app "Offline". Aggiungere in coda, separati da virgola, eventuali domini propri (tunnel, reverse proxy) |
| `SELF_HOST_PUBLIC_IP` | (unset) | Solo per il bank-sync (Enable Banking): IP pubblico o hostname DDNS. Vuota = bank-sync non funzionante, resto ok |

Le variabili `LAZYCAT_*` sono iniettate dal box: `LAZYCAT_APP_DOMAIN` è il
dominio di questa app (es. `budgero.chronos.heiyu.space`),
`LAZYCAT_BOX_DOMAIN` quello del box. Mai inchiodare un dominio nel manifest —
romperebbe ogni altro box.

## Limitazioni note

### Doppio login (Lazycat OIDC + Budgero)

Budgero non supporta header SSO (`X-Remote-User`, `X-Forwarded-User`, OIDC trusted-proxy). Confermato ispezionando il binario. L'utente vede:

1. Login Lazycat (OIDC del NAS)
2. Login Budgero (username/password locale)

Workaround attuale: bootstrap admin via env vars al primo avvio. Niente da fare se non aspettare che upstream supporti header auth.

### Policy password da v1.19.x

Il server rifiuta una password senza maiuscola, minuscola e cifra:

```
Error: failed to reset password: password must contain uppercase, lowercase, and digit
```

Il vecchio default `changeme-on-first-login` cadeva esattamente lì. Due
conseguenze, entrambe sanate nell'entrypoint:

- su un'install **pulita** `create-user` fallisce e l'app resta senza admin;
- su un'install **esistente** il reset ad ogni avvio fallisce in silenzio
  (`|| echo`), mascherando il fatto che la password nel manifest non è mai
  stata quella in uso.

Ora l'entrypoint non tocca la password di un utente che esiste già (serve
`BUDGERO_ADMIN_FORCE_RESET=true`), e al bootstrap genera una random conforme
per costruzione se `BUDGERO_ADMIN_PASS` è vuota. I test stanno in
`docker/tests/entrypoint.test.sh`:

```bash
bash docker/tests/entrypoint.test.sh
```

### Il wrapper non patcha upstream

Budgero è **AGPL-3.0**, sorgente su
[tombadilo-bombadilo/budgero](https://github.com/tombadilo-bombadilo/budgero)
(era closed-source alle prime versioni di questo wrapper, da cui la vecchia
nota qui). Il wrapper resta deliberatamente sottile:

- aggiunge l'entrypoint (JWT, bootstrap admin)
- inietta env vars
- gestisce la persistenza

Non patcha il binario: una modifica al comportamento va come PR upstream — le
#43 (`SELF_HOST_PUBLIC_IP`) e #44 (currency `XXX` PayPal/SimpleFIN) sono
state mergiate così, e il fork custom che prima serviva è sparito. Ad ogni
release upstream → re-build dell'immagine wrapper.

### Tag upstream pinnato, non per digest

Il `Dockerfile` pinna un tag esplicito (`FROM budgero/budgero:v1.19.5`), mai
`:latest` — un upgrade implicito ha già rotto i push (pre-v2) e il sync WS
(`CheckOrigin` in v1.12.x). Il tag resta comunque mutabile a monte: per
riproducibilità totale servirebbe `@sha256:...`.

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
│   ├── Dockerfile          # FROM budgero/budgero:<tag pinnato> + entrypoint
│   ├── entrypoint.sh       # JWT + admin bootstrap idempotente
│   └── tests/
│       └── entrypoint.test.sh  # self-check dei rami admin (bash, no framework)
├── budgero-lzc/
│   ├── package.yml         # campi statici del pacchetto (LPK v2)
│   ├── lzc-manifest.yml    # manifest LCMD (routes, services, env)
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
- **Budgero**: AGPL-3.0, sorgente su
  [tombadilo-bombadilo/budgero](https://github.com/tombadilo-bombadilo/budgero).
  Self-host gratuito, feature set completo, nessuna license key. L'immagine
  che questo wrapper ridistribuisce non è modificata: ci si aggiunge solo un
  entrypoint, quindi non scatta l'obbligo AGPL di pubblicare un sorgente
  modificato — e il codice del wrapper è comunque pubblico qui.
