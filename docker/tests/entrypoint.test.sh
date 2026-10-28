#!/usr/bin/env bash
# Self-check dell'entrypoint: i tre rami admin + la policy password di v1.19.x.
# Esegue l'entrypoint vero con un /app/budgero finto. Nessun framework.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
ENTRYPOINT="$(cd .. && pwd)/entrypoint.sh"
fails=0

check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1: expected [$3], got [$2]"; fails=$((fails+1)); fi
}
contains() {
  case "$2" in *"$3"*) echo "  ok   $1";;
  *) echo "  FAIL $1: output lacks [$3]"; fails=$((fails+1));; esac
}
lacks() {
  case "$2" in *"$3"*) echo "  FAIL $1: output should lack [$3]"; fails=$((fails+1));;
  *) echo "  ok   $1";; esac
}

# $1 = utenti esistenti (newline-separated), resto = env assignments
run() {
  local FAKE_HEADER="${FAKE_HEADER:-}"
  local existing="$1"; shift
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/app" "$SANDBOX/data"
  printf '%s\n' "$existing" > "$SANDBOX/existing-users"
  printf '%s\n' "${FAKE_HEADER:-ADMIN NAME CREATED}" > "$SANDBOX/header"
  # Il finto budgero: list-users stampa un header + gli utenti; create-user e
  # reset-password applicano la policy del server reale e registrano la chiamata.
  cat > "$SANDBOX/app/budgero" <<'FAKE'
#!/bin/sh
SB="$(dirname "$(dirname "$0")")"
cmd="$1"; sub="$2"
log() { printf '%s\n' "$*" >> "$SB/calls"; }
policy_ok() {
  printf '%s' "$1" | grep -q '[A-Z]' || return 1
  printf '%s' "$1" | grep -q '[a-z]' || return 1
  printf '%s' "$1" | grep -q '[0-9]' || return 1
}
getpass() { while [ $# -gt 0 ]; do [ "$1" = "--password" ] && { printf '%s' "$2"; return; }; shift; done; }
case "$cmd $sub" in
  "admin list-users")
    cat "$SB/header"
    grep -v '^$' "$SB/existing-users" 2>/dev/null
    ;;
  "admin create-user"|"admin reset-password")
    p="$(getpass "$@")"
    if policy_ok "$p"; then log "$sub ok pass=$p"
    else log "$sub rejected"; echo "Error: failed to $sub: password must contain uppercase, lowercase, and digit" >&2; exit 1; fi
    ;;
  *) log "exec $*"; ;;
esac
FAKE
  chmod +x "$SANDBOX/app/budgero"
  # L'entrypoint invoca /app/budgero e /data per path assoluto: li rimappo con
  # una copia riscritta, l'unico modo senza chroot.
  sed -e "s#/app/budgero#$SANDBOX/app/budgero#g" -e "s#/data/#$SANDBOX/data/#g" "$ENTRYPOINT" > "$SANDBOX/entrypoint.sh"
  chmod +x "$SANDBOX/entrypoint.sh"
  OUT="$(env -i PATH="$PATH" BUDGERO_JWT_FILE="$SANDBOX/data/jwt.secret" "$@" "$SANDBOX/entrypoint.sh" serve 2>&1)"
  CALLS="$(cat "$SANDBOX/calls" 2>/dev/null)"
}

echo "1. install pulita, nessuna BUDGERO_ADMIN_PASS -> crea admin con random conforme"
run "" BUDGERO_ADMIN_USER=admin
contains "create-user accettato dalla policy" "$CALLS" "create-user ok"
lacks    "nessun rifiuto della policy"        "$CALLS" "rejected"
contains "password stampata nei log"          "$OUT"   "ADMIN PASSWORD:"
check    "admin.pass scritto"                 "$([ -s "$SANDBOX/data/admin.pass" ] && echo yes)" "yes"
check    "admin.pass non leggibile da altri"  "$(stat -c %a "$SANDBOX/data/admin.pass")" "600"

echo "2. utente già esistente -> NON tocca la password (il bug della 1.0.16)"
run "admin" BUDGERO_ADMIN_USER=admin BUDGERO_ADMIN_PASS=changeme-on-first-login
lacks    "nessun reset-password"              "$CALLS" "reset-password"
contains "lo dice"                            "$OUT"   "leaving its password alone"

echo "3. force reset esplicito -> resetta"
run "admin" BUDGERO_ADMIN_USER=admin BUDGERO_ADMIN_PASS=Valida1pass BUDGERO_ADMIN_FORCE_RESET=true
contains "reset-password chiamato"            "$CALLS" "reset-password ok"

echo "4. force reset con password non conforme -> fallisce ma non blocca l'avvio"
run "admin" BUDGERO_ADMIN_USER=admin BUDGERO_ADMIN_PASS=changeme-on-first-login BUDGERO_ADMIN_FORCE_RESET=true
contains "policy rifiuta"                     "$CALLS" "reset-password rejected"
contains "diagnosi nei log"                   "$OUT"   "password policy"
contains "l'avvio prosegue"                   "$CALLS" "exec serve"

echo "5. BUDGERO_ADMIN_PASS esplicita su install pulita -> usata, niente admin.pass"
run "" BUDGERO_ADMIN_USER=admin BUDGERO_ADMIN_PASS=Valida1pass
contains "create-user con la password data"   "$CALLS" "create-user ok pass=Valida1pass"
check    "nessun admin.pass"                  "$([ -e "$SANDBOX/data/admin.pass" ] && echo yes || echo no)" "no"

echo "6. header di list-users non confuso con un utente omonimo"
# Il binario reale intesta la prima colonna "ADMIN": senza tail -n +2 (o con
# un grep case-insensitive) l'header stesso passa per l'utente "admin" e il
# bootstrap viene saltato, lasciando l'install senza admin.
run "" BUDGERO_ADMIN_USER=admin
contains "crea admin malgrado l'header ADMIN" "$CALLS" "create-user ok"
lacks    "non crede che admin esista"          "$OUT"   "already exists"

FAKE_HEADER="USERNAME NAME" run "" BUDGERO_ADMIN_USER=admin
contains "idem con un header diverso"          "$CALLS" "create-user ok"

echo "7. jwt.secret generato una volta e stabile"
run "" BUDGERO_ADMIN_USER=admin
J1="$(cat "$SANDBOX/data/jwt.secret")"
check "jwt 64 hex" "$(printf '%s' "$J1" | grep -cE '^[0-9a-f]{64}$')" "1"

echo
[ "$fails" -eq 0 ] && { echo "PASS"; exit 0; } || { echo "FAIL: $fails"; exit 1; }
