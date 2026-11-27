# fliva/budgero-headless

Headless Budgero client (spec `docs/superpowers/specs/2026-11-24-budgero-headless-client-design.md` §11).

- **Local** (fork branch not pushed): `bash docker/headless/build-local.sh [fork-worktree]` archives the
  worktree's committed `HEAD` into `docker/headless/src.tar` (gitignored) and builds `fliva/budgero-headless:dev`.
- **Clone** (production): `docker build --build-arg FORK_TAG=headless-v1.22.1-<n> -t fliva/budgero-headless:1.22.1-<n> docker/headless`
  clones `f-liva/budgero` at that tag. Then mirror it to the Lazycat registry and pin it in the manifest.
- The bundle carries the monorepo `package.json` version (must equal the server's `build_version`, else
  `version_mismatch`); the label `org.opencontainers.image.revision` carries the fork revision.
- Runtime: uid/gid 1001, `WORKDIR /app` (sql.js wasm under `/app/node_modules`), port 8787, supervisor
  `/app/entrypoint.sh` (busybox httpd serves `/healthz` 503 while the worker is down).
- Config and secrets live in `/lzcapp/var/headless` (bind mount, chowned 1001 by `provision.sh`; no `setup_script`, it would make lzcinit pid 1 and swallow TERM):
  `config.json`, and mode-600 `password`, `space.key`, `tokens`. Never baked into the image.
- Smoke: `docker run -d -p 18787:8787 -v <dir owned by 1001>:/lzcapp/var/headless fliva/budgero-headless:dev`
  then `curl localhost:18787/healthz` ⇒ `{"state":"not_configured",...}`; `docker stop` ⇒ exit 143.
