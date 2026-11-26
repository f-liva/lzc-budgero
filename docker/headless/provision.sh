#!/bin/sh
# Provision the headless config and secrets on the NAS (M3 plan Task 3). Run it yourself, as root,
# in an interactive SSH session: the password and space.key are read without echo and never printed.
#   sh provision.sh --dir /lzcsys/data/appvar/cloud.lazycat.app.budgero/headless \
#     --user <budgero login> --space-id <space uuid> --budget-id <n> [--uid 1001] [--force]
# Writes config.json (readOnly true) and the mode-600 secrets password, space.key, tokens.
# Prints ONLY the read token (for Ambrogio's secret store); write/admin tokens stay in the file.
# Exit: 0 ok · 2 invalid input (nothing written) · 3 secrets exist and no --force.
set -eu
dir= user= space= budget= uid=1001 force=0
while [ $# -gt 0 ]; do
  case $1 in
    --dir) dir=$2; shift 2 ;;
    --user) user=$2; shift 2 ;;
    --space-id) space=$2; shift 2 ;;
    --budget-id) budget=$2; shift 2 ;;
    --uid) uid=$2; shift 2 ;;
    --force) force=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
bad() { echo "provision: $1" >&2; exit 2; }
[ -n "$dir" ] && [ -n "$user" ] && [ -n "$space" ] || bad "--dir, --user, --space-id are required"
case $budget in ''|*[!0-9]*|0*) bad "--budget-id must be a positive integer" ;; esac
case $user$space in *'"'*|*'\'*) bad "user and space id must not contain quotes or backslashes" ;; esac

if [ "$force" -eq 0 ]; then
  for f in password space.key tokens; do
    [ -e "$dir/$f" ] && { echo "provision: $dir/$f exists (use --force to replace)" >&2; exit 3; }
  done
fi

secret() { # prompt, var: read one line without echo when on a terminal
  if [ -t 0 ]; then printf '%s: ' "$1" >&2; stty -echo; fi
  IFS= read -r line || line=
  if [ -t 0 ]; then stty echo; printf '\n' >&2; fi
}
secret "Budgero password"; pw=$line
[ -n "$pw" ] || bad "empty password"
secret "space.key (base64 from Settings → Push API → export)"; key=$(printf '%s' "$line" | tr -d ' \r\n')
printf '%s' "$key" | grep -Eq '^[A-Za-z0-9+/]+={0,2}$' || bad "space.key is not base64"
n=$(printf '%s' "$key" | base64 -d 2>/dev/null | wc -c | tr -d ' ')
[ "$n" = 32 ] || bad "space.key must decode to 32 bytes (got $n)"

hex() { openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
rt=$(hex); wt=$(hex); at=$(hex)

mkdir -p "$dir"
umask 077
put() { # name, content: temp file in the same dir, then rename
  tmp="$dir/.$1.tmp.$$"
  printf '%s\n' "$2" > "$tmp"
  chmod 600 "$tmp"; chown "$uid" "$tmp"
  mv -f "$tmp" "$dir/$1"
}
put config.json "{\"url\":\"http://budgero.cloud.lazycat.app.budgero.lzcapp:3001/api/v1\",\"user\":\"$user\",\"spaceId\":\"$space\",\"budgetId\":$budget,\"readOnly\":true,\"allowDestructive\":false,\"port\":8787}"
put password "$pw"
put space.key "$key"
put tokens "ambrogio:read:$rt
operator:write:$wt
admin:admin:$at"
chown "$uid" "$dir"

echo "provisioned $dir (readOnly: true)."
echo "Read token for Ambrogio — store it in Ambrogio's secret store now, it is not shown again:"
echo "$rt"
