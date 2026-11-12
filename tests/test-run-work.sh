#!/bin/bash
set -euo pipefail
umask 077

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
LAUNCHER="$ROOT/run-work.sh"
bash -n "$LAUNCHER"
test -x "$LAUNCHER"

FIXTURE=$(mktemp -d)
trap 'rm -rf -- "$FIXTURE"' EXIT
cp -- "$LAUNCHER" "$FIXTURE/run-work.sh"
cd -- "$FIXTURE"

cat > id <<'STUB'
#!/bin/bash
set -eu
[[ "$*" == '-u local-gpt-work' ]]
printf '1000\n'
STUB
cat > xhost <<'STUB'
#!/bin/bash
set -eu
printf 'xhost %s\n' "$*" >> "$CALLS"
STUB
cat > sudo <<'STUB'
#!/bin/bash
set -eu
case "$1" in
    iptables)
        [[ "${*:3}" == 'OUTPUT -m owner --uid-owner 1000 -d 192.0.2.1 -j REJECT' ]]
        printf 'iptables %s\n' "$2" >> "$CALLS"
        case "$2" in
            -C) [[ "$RULE_STATUS" == present ]] ;;
            -A) [[ "$RULE_STATUS" == missing ]] ;;
            -D) [[ "$RULE_STATUS" == missing ]] ;;
            *) exit 98 ;;
        esac
        ;;
    -u)
        [[ "$#" == 10 ]]
        [[ "${*:1:8}" == '-u local-gpt-work -H env DISPLAY=:100 XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus /bin/sh' ]]
        [[ "${*:9:1}" == '-c' && "${*:10:1}" == 'cd "$HOME" && exec /usr/bin/chatgpt --ozone-platform=x11' ]]
        printf 'work launch\n' >> "$CALLS"
        ;;
    *) exit 98 ;;
esac
STUB
cat > db_refresh <<'STUB'
#!/bin/bash
printf 'unexpected database operation\n' >> "$CALLS"
exit 99
STUB
for command in pg_dump pg_restore psql prepare-codex-env; do
    cp db_refresh "$command"
done
chmod 700 id xhost sudo db_refresh pg_dump pg_restore psql prepare-codex-env

run_launcher() {
    env -i PATH="$FIXTURE:/usr/bin:/bin" HOME="$FIXTURE" DISPLAY=:100 \
        CALLS="$FIXTURE/calls" RULE_STATUS="$1" "${@:2}" ./run-work.sh > output 2>&1
}

# The normal no-argument launch needs only the existing firewall destination.
run_launcher missing PROD_VPS_IP=192.0.2.1
test "$(cat calls)" = "$(printf '%s\n' 'iptables -C' 'iptables -A' \
    'xhost +SI:localuser:local-gpt-work' 'work launch' 'iptables -D' 'xhost -SI:localuser:local-gpt-work')"

: > calls
run_launcher present PROD_VPS_IP=192.0.2.1
test "$(cat calls)" = "$(printf '%s\n' 'iptables -C' \
    'xhost +SI:localuser:local-gpt-work' 'work launch' 'xhost -SI:localuser:local-gpt-work')"

: > calls
if run_launcher rejected PROD_VPS_IP=192.0.2.1; then exit 1; fi
test "$(cat calls)" = "$(printf '%s\n' 'iptables -C' 'iptables -A')"

: > calls
if run_launcher missing; then exit 1; fi
test ! -s calls
grep -Fq 'PROD_VPS_IP is required' output

echo "Mocked normal Work launch and firewall isolation checks passed"
