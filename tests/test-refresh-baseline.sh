#!/bin/bash
set -euo pipefail
umask 077

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_PG=/usr/lib/postgresql/17/bin
FIXTURE=$(mktemp -d /tmp/binancebot-refresh-test.XXXXXXXX)
PORT=6543
cleanup() {
    "$TEST_PG/pg_ctl" -D "$FIXTURE/data" -m immediate -w stop >/dev/null 2>&1 || true
    rm -rf -- "$FIXTURE"
}
trap cleanup EXIT

if [[ $(id -u) == 0 ]]; then
    echo "Run the disposable fixture as an unprivileged user." >&2
    exit 2
fi

"$TEST_PG/initdb" -D "$FIXTURE/data" -U postgres -A trust --no-locale >/dev/null
if ! "$TEST_PG/pg_ctl" -D "$FIXTURE/data" -l "$FIXTURE/server.log" -w start \
        -o "-h '' -k $FIXTURE -p $PORT -c fsync=off" >/dev/null; then
    cat "$FIXTURE/server.log" >&2
    exit 2
fi

export FIXTURE PORT TEST_PG
# All test copies are pinned to the private socket and temp paths before execution.
mkdir "$FIXTURE/bin"
for command in psql dropdb createdb; do
    ln -s "$TEST_PG/$command" "$FIXTURE/bin/$command"
done
for script in refresh_baseline.sh reset-binancebot-work; do
    sed -e "s|/var/run/postgresql|$FIXTURE|g" \
        -e "s|/usr/lib/postgresql/17/bin|$FIXTURE/bin|g" \
        -e "s|PG_PORT=\"5432\"|PG_PORT=\"$PORT\"|g" \
        -e "s|/usr/local/sbin/reset-binancebot-work|$FIXTURE/reset-entry|g" \
        -e "s|/var/tmp/binancebot-refresh-v2|$FIXTURE/spool|g" \
        -e 's|\$(/usr/bin/id -un)|postgres|g' \
        "$ROOT/$script" > "$FIXTURE/$script"
    chmod 700 "$FIXTURE/$script"
    grep -Fq "PG_SOCKET=\"$FIXTURE\"" "$FIXTURE/$script"
    grep -Fq "PG_PORT=\"$PORT\"" "$FIXTURE/$script"
done

cat > "$FIXTURE/bin/pg_restore" <<'STUB'
#!/bin/bash
set -euo pipefail
if [[ -e "$FIXTURE/interrupt" && $1 != --list ]]; then
    "$TEST_PG/psql" -Xw -h "$FIXTURE" -p "$PORT" -U postgres \
        -d binancebot_work_baseline_candidate -v ON_ERROR_STOP=1 -c 'CREATE SCHEMA partial' >/dev/null
    touch "$FIXTURE/restore-started"
    exec sleep 30
fi
if [[ $1 != --list ]]; then
    printf 'restore\n' >> "$FIXTURE/calls"
fi
exec "$TEST_PG/pg_restore" "$@"
STUB
cat > "$FIXTURE/reset-entry" <<'STUB'
#!/bin/bash
set -euo pipefail
printf 'reset\n' >> "$FIXTURE/calls"
if [[ -e "$FIXTURE/fail-reset" ]]; then exit 42; fi
exec "$FIXTURE/reset-binancebot-work" "$@"
STUB
chmod 700 "$FIXTURE/bin/pg_restore" "$FIXTURE/reset-entry"

psql_local() { "$TEST_PG/psql" -XwqAt -v ON_ERROR_STOP=1 -h "$FIXTURE" -p "$PORT" -U postgres "$@"; }
admin() { psql_local -d postgres "$@"; }
snapshot() {
    "$TEST_PG/pg_dump" -w -h "$FIXTURE" -p "$PORT" -U postgres -d synthetic \
        --format=custom --no-owner --no-acl --file="$FIXTURE/$1"
}
refresh() {
    local digest
    digest=$(sha256sum < "$FIXTURE/$1")
    "$FIXTURE/refresh_baseline.sh" --jobs 2 --sha256 "${digest%% *}" --stdin < "$FIXTURE/$1"
}
oid() { admin -c "SELECT oid FROM pg_database WHERE datname='$1'"; }
verify() {
    test "$(admin -c "
        SELECT count(*) FROM pg_database WHERE datname='binancebot_work_baseline'
           AND pg_get_userbyid(datdba)='postgres' AND datconnlimit=0
           AND NOT has_database_privilege('local-gpt-work', oid, 'CONNECT')
           AND NOT has_database_privilege('local-gpt-work', oid, 'CREATE')")" = 1
    if "$TEST_PG/psql" -Xw -h "$FIXTURE" -p "$PORT" -U local-gpt-work \
        -d binancebot_work_baseline -c 'SELECT 1' >/dev/null 2>&1; then
        echo "Work could connect to the protected baseline" >&2
        exit 1
    fi
    test "$("$TEST_PG/psql" -XwAt -h "$FIXTURE" -p "$PORT" -U local-gpt-work \
        -d binancebot_work -c 'SELECT value FROM bot.fixture')" = "$1"
    test -z "$(oid binancebot_work_baseline_previous)"
    test -z "$(oid binancebot_work_baseline_candidate)"
}

admin -c 'CREATE ROLE "local-gpt-work" LOGIN'
admin -c 'CREATE DATABASE synthetic'
psql_local -d synthetic -c "CREATE SCHEMA bot; CREATE TABLE bot.fixture (value int);
    INSERT INTO bot.fixture VALUES (1); CREATE INDEX ON bot.fixture(value)"
snapshot first
refresh first
verify 1
first_baseline=$(oid binancebot_work_baseline)
first_work=$(oid binancebot_work)
refresh first
test "$(oid binancebot_work)" = "$first_work"
test "$(cat "$FIXTURE/calls")" = "$(printf 'restore\nreset')"

psql_local -d synthetic -c 'UPDATE bot.fixture SET value=2'
snapshot second
touch "$FIXTURE/interrupt"
digest=$(sha256sum < "$FIXTURE/second")
setsid "$FIXTURE/refresh_baseline.sh" --sha256 "${digest%% *}" --stdin \
    < "$FIXTURE/second" > "$FIXTURE/interrupted.log" 2>&1 &
runner=$!
for _ in {1..100}; do
    [[ ! -e "$FIXTURE/restore-started" ]] || break
    sleep 0.05
done
if [[ ! -e "$FIXTURE/restore-started" ]]; then
    cat "$FIXTURE/interrupted.log" >&2
    kill -- "-$runner" 2>/dev/null || true
    exit 1
fi
kill -TERM -- "-$runner"
if wait "$runner"; then exit 1; else test "$?" = 143; fi
test "$(oid binancebot_work_baseline)" = "$first_baseline"
test -n "$(oid binancebot_work_baseline_candidate)"
test -z "$(find "$FIXTURE" -name 'spool.*.dump' -print)"
rm -- "$FIXTURE/interrupt"
touch "$FIXTURE/fail-reset"
if refresh second; then exit 1; else test "$?" = 82; fi
test "$(oid binancebot_work_baseline_previous)" = "$first_baseline"
test "$(oid binancebot_work)" = "$first_work"
rm -- "$FIXTURE/fail-reset"
refresh second
verify 2
test "$(grep -c '^restore$' "$FIXTURE/calls")" = 2

psql_local -d binancebot_work -c 'UPDATE bot.fixture SET value=3'
"$FIXTURE/reset-binancebot-work"
verify 2

# Run the operator's exact status and Work-verification queries against the fixture.
SOURCE_ROOT="$ROOT" python3 -B - <<'PY'
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import subprocess

source = Path(os.environ["SOURCE_ROOT"]) / "prepare-codex-env"
loader = importlib.machinery.SourceFileLoader("prepare_codex_env", str(source))
spec = importlib.util.spec_from_loader(loader.name, loader)
env = importlib.util.module_from_spec(spec)
loader.exec_module(env)

def query(sql, *, role="postgres", database="postgres"):
    return subprocess.check_output(
        [Path(os.environ["TEST_PG"]) / "psql", "-XwAt", "-h", os.environ["FIXTURE"],
         "-p", os.environ["PORT"], "-U", role, "-d", database, "-c", sql],
        text=True,
    ).strip()

env.query = query
env.validate_state(env.state(), "check")
env.verify_work()
PY

# An unrelated candidate using the reserved name is never removed automatically.
admin -c 'CREATE DATABASE binancebot_work_baseline_candidate CONNECTION LIMIT 0'
admin -c 'REVOKE CONNECT ON DATABASE binancebot_work_baseline_candidate FROM PUBLIC'
unexpected=$(oid binancebot_work_baseline_candidate)
if refresh second; then exit 1; else test "$?" = 78; fi
test "$(oid binancebot_work_baseline_candidate)" = "$unexpected"
test -z "$(find "$FIXTURE" -name 'spool.*.dump' -print)"

echo "Disposable PostgreSQL refresh, protection, recovery and reset tests passed"
