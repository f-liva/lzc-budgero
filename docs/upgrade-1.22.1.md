# Upgrade budgero v1.21.5 -> v1.22.1 (lzc-budgero 1.0.21)

Analisi del 26/11/2026 su `git diff v1.21.5 v1.22.1` del checkout upstream (93 commit, 354 file).
Solo il server Go (`packages/server`) gira nel nostro container; il resto del diff e' client (web-app embedded nel binario).

## Server: cosa cambia

Cinque file in `packages/server`, nessuno strutturale:

- `internal/appmeta/version.txt`: `1.21.5` -> `1.22.1` (da cui `/api/v1/version/latest`).
- `internal/adapter/driving/http/handler/push.go`: solo testo dello spec Push API (`GetPushAPISpec`): accetta `v: 7` e il campo opzionale `time` (HH:MM) su `transactions.add`/`update` e sui transfer.
- `package.json`, `govulncheck-ignore.json`, `osv-scanner.toml`: metadati/CI.

**Migrazioni SQL del server (`internal/adapter/driven/sqlite/migrations/`): nessuna nuova.** L'ultima resta `00014_blob_mutation_version.sql` (quella che introduce `X-Mutation-Version`, gia' presente in v1.21.5). Il `budgero.db` sul NAS non viene modificato dallo schema all'avvio.

**Env var: nessuna nuova o cambiata** (`internal/config/config.go` non e' nel diff). Il blocco `environment:` del manifest resta valido.

**`/version/latest`**: handler invariato. Con `APP_VERSION` non impostata risponde `{"build_version":"1.22.1","latest_version":"1.22.1"}` (verificato in locale).

**`X-Mutation-Version` / header blob**: codice invariato (`blob_history.go`, `sync.go` non toccati). Verificato in locale: upload con `X-Mutation-Version: 42`, il GET successivo restituisce `X-Mutation-Version: 42`, `X-Database-Version`, `X-Database-Hash`, `X-Data-Format-Version`.

## Client: migrazioni che girano nel browser sul blob

Le migrazioni sono nel pacchetto `packages/core/src/database/migrations/` e vengono applicate dal client sul proprio SQLite locale, che poi carica il blob cifrato. Il server non le vede. Alla prima apertura con la nuova web-app, il DB del client passa da schema 80 a 82:

- `081-add-goal-timeframes.ts`: ricostruisce la tabella `goals` (copia, `DROP`, rename) per togliere l'unique su `CategoryID`; aggiunge `EffectiveFrom`/`EffectiveTo`, indice unico `idx_goals_category_effective_from`, trigger `goals_default_effective_from`. Ogni goal esistente diventa l'unico timeframe della categoria. **Non reversibile** (non esiste `down`, e un vecchio client non conosce la nuova tabella).
- `082-add-transaction-time.ts`: `ALTER TABLE transactions ADD COLUMN Time TEXT NULL` e `user_meta ADD COLUMN ShowTransactionTime BOOLEAN NOT NULL DEFAULT 0`. Additiva, ma anch'essa senza `down`.

## Formato mutazioni: 6 -> 7

`packages/runtime/src/sync-format.ts`: `MUTATION_FORMAT_VERSION` 7. Nuovi op code: `goals.setFrom`, `goals.endFrom`, `userPreferences.setShowTransactionTime`. Le mutazioni che usano goal timeframes, orario delle transazioni o i nuovi casi di split/transfer vengono marcate formato 7; un client piu' vecchio le rifiuta. Il formato resta il piu' basso possibile per ciascuna mutazione, quindi le mutazioni vecchie non cambiano.

Conseguenza per il client headless (`budgero-wt-headless`): va costruito contro v1.22.1 per leggere i blob/mutazioni formato 7 (il tag `headless-v1.22.1-2` lo e').

## Wrapper `docker/entrypoint.sh`

Ancora coerente con l'immagine v1.22.1, verificato sull'immagine costruita:

- binario `/app/budgero` presente (eseguibile, utente `budgero`);
- `serve` e' un sottocomando (`CMD ["serve"]`);
- `admin create-user` accetta `--username --password --name --admin`; `admin list-users` e `admin reset-password` usati dall'entrypoint esistono;
- `docker/tests/entrypoint.test.sh`: PASS.

## Rollback

**Il rollback del solo server a v1.21.5 e' sicuro**: nessuna migrazione SQL lato server, `budgero.db` resta compatibile.

**Il rollback dei dati dopo il primo uso della nuova web-app NON e' sicuro.** Appena un client v1.22 apre il budget, migra il proprio DB a schema 82 e, alla prima scrittura, carica un blob con schema 82 e mutazioni formato 7. La web-app v1.21.5 non sa leggere ne' le colonne (`goals` ricostruita, `Time`) ne' le mutazioni formato 7. Per tornare indietro serve ripristinare il blob salvato prima dell'upgrade (Step 4 del brief: `sqlite3 .backup` di `/lzcapp/var/data/budgero.db` e copia del blob corrente), perdendo tutto cio' che e' stato scritto dopo.

Quindi: backup datato prima dell'install, e fino a verifica completata niente scritture dalla web-app che non si accetti di perdere.

## Cosa NON e' stato fatto

- Nessun push su Docker Hub, nessun `copy-image`, nessuna install sul NAS.
- `budgero-lzc/lzc-manifest.yml` `image:` non toccata: dopo il go serve il tag del registry Lazycat da `copy-image`. Il commento del manifest che cita "v1.21.5" andra' aggiornato nello stesso commit.
- La migrazione 081/082 non e' stata eseguita su un blob reale: richiede la web-app nel browser. Il test locale ha coperto solo server, header e wrapper.
