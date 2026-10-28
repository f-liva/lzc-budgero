#!/bin/sh
set -e

JWT_FILE="${BUDGERO_JWT_FILE:-/data/jwt.secret}"
mkdir -p "$(dirname "$JWT_FILE")"

if [ ! -s "$JWT_FILE" ]; then
  od -An -tx1 -N32 /dev/urandom | tr -d ' \n' > "$JWT_FILE"
  chmod 600 "$JWT_FILE"
fi
export SELF_HOST_JWT_SECRET="$(cat "$JWT_FILE")"

# Skip header line, match exact username in first column. Avoids collision
# with header column names like "ADMIN" when --username is "admin".
user_exists() {
  /app/budgero admin list-users 2>/dev/null \
    | tail -n +2 | awk '{print $1}' | grep -qFx "$1"
}

# Da v1.19.x il server impone maiuscola+minuscola+cifra: una password random
# deve soddisfare la policy per costruzione, non per fortuna.
gen_password() {
  echo "Lzc$(od -An -tx1 -N12 /dev/urandom | tr -d ' \n')1"
}

if [ -n "${BUDGERO_ADMIN_USER:-}" ]; then
  if user_exists "$BUDGERO_ADMIN_USER"; then
    # L'utente c'è già: la sua password è quella che l'utente ha scelto nella
    # UI. Un reset ad ogni avvio la butterebbe via in silenzio — si fa solo
    # su richiesta esplicita.
    if [ "${BUDGERO_ADMIN_FORCE_RESET:-}" = "true" ] && [ -n "${BUDGERO_ADMIN_PASS:-}" ]; then
      echo "[entrypoint] BUDGERO_ADMIN_FORCE_RESET=true: resetting password for $BUDGERO_ADMIN_USER"
      /app/budgero admin reset-password \
        --username "$BUDGERO_ADMIN_USER" \
        --password "$BUDGERO_ADMIN_PASS" \
        || echo "[entrypoint] reset-password FAILED (password policy? needs upper+lower+digit)"
    else
      echo "[entrypoint] admin user $BUDGERO_ADMIN_USER already exists, leaving its password alone"
    fi
  else
    PASS="${BUDGERO_ADMIN_PASS:-}"
    PASS_FILE="/data/admin.pass"
    if [ -z "$PASS" ]; then
      # Nessuna password nel manifest: una random per install. Un default
      # fisso sarebbe lo stesso su ogni install dello store.
      PASS="$(gen_password)"
      ( umask 077; printf '%s\n' "$PASS" > "$PASS_FILE" )
      echo "[entrypoint] generated admin password, saved to $PASS_FILE"
      echo "[entrypoint] ADMIN PASSWORD: $PASS"
      echo "[entrypoint] ^ change it in the app, then delete $PASS_FILE"
    fi
    echo "[entrypoint] bootstrapping admin user: $BUDGERO_ADMIN_USER"
    /app/budgero admin create-user \
      --username "$BUDGERO_ADMIN_USER" \
      --password "$PASS" \
      --name "${BUDGERO_ADMIN_NAME:-Admin}" \
      --admin \
      || echo "[entrypoint] admin create-user FAILED"
  fi
fi

exec /app/budgero "$@"
