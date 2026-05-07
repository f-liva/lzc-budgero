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
      --admin || echo "[entrypoint] admin create-user failed (user may already exist)"
  fi
fi

exec /app/budgero "$@"
