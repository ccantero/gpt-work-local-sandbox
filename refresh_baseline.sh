#!/bin/bash
set -euo pipefail
umask 077
export PATH=/usr/bin:/bin
for variable in ${!PG@}; do unset "$variable"; done
export PGCONNECT_TIMEOUT=5

readonly PG_BIN="/usr/lib/postgresql/17/bin"
readonly PG_SOCKET="/var/run/postgresql"
readonly PG_PORT="5432"
readonly BASELINE="binancebot_work_baseline"
readonly CANDIDATE="binancebot_work_baseline_candidate"
readonly PREVIOUS="binancebot_work_baseline_previous"
readonly WORK="binancebot_work"
readonly OWNER="local-gpt-work"
readonly RESET="/usr/local/sbin/reset-binancebot-work"
readonly SPOOL="/var/tmp/binancebot-refresh-v2"

log() { printf '[%(%FT%T%z)T] refresh: %s\n' -1 "$*"; }
fail() { log "$2" >&2; exit "$1"; }
psql_local() {
    "$PG_BIN/psql" -X -w -h "$PG_SOCKET" -p "$PG_PORT" -U postgres \
        -v ON_ERROR_STOP=1 -At "$@"
}
admin() { psql_local -d postgres "$@"; }
db_marker() {
    admin -c "SELECT shobj_description(oid, 'pg_database') FROM pg_database WHERE datname='$1'"
}
db_exists() {
    local count
    count=$(admin -c "SELECT count(*) FROM pg_database WHERE datname='$1'") ||
        fail 69 "Cannot inspect local PostgreSQL database state."
    [[ $count == 1 ]]
}
protected() {
    [[ $(admin -c "
        SELECT datdba = 'postgres'::regrole AND datconnlimit = 0
           AND NOT has_database_privilege('$OWNER', oid, 'CONNECT')
           AND ('$2' = 'restoring' OR NOT has_database_privilege('$OWNER', oid, 'CREATE'))
          FROM pg_database WHERE datname='$1'") == t ]]
}
idle() {
    [[ $(admin -c "SELECT count(*) FROM pg_stat_activity WHERE datname='$1'") == 0 ]] ||
        fail 75 "Stop sessions on $1 before retrying."
}
objects_ok() {
    [[ $(psql_local -d "$1" -c "
        SELECT count(*) > 0 AND bool_and(pg_get_userbyid(c.relowner) = '$OWNER')
          FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname IN ('bot', 'django') AND c.relkind IN ('r','p','S','v','m','f')") == t ]]
}
work_ok() {
    [[ $(admin -c "
        SELECT pg_get_userbyid(datdba) = '$OWNER' AND datallowconn AND datconnlimit <> 0
           AND has_database_privilege('$OWNER', oid, 'CONNECT')
          FROM pg_database WHERE datname='$WORK'") == t ]] &&
        objects_ok "$WORK"
}

[[ $(/usr/bin/id -un) == postgres ]] ||
    fail 69 "Run only the protected installed helper as the postgres OS user."
jobs=1
expected=""
resume=false
while (( $# > 0 )); do
    case "$1" in
        --jobs) (( $# >= 2 )) || fail 64 "Missing job count."; jobs="$2"; shift 2 ;;
        --sha256) (( $# >= 2 )) || fail 64 "Missing checksum."; expected="$2"; shift 2 ;;
        --resume) resume=true; shift ;;
        --) shift; break ;;
        *) break ;;
    esac
done
(( $# == 1 )) && [[ $jobs =~ ^[1-8]$ ]] &&
    [[ -z $expected || $expected =~ ^[0-9a-f]{64}$ ]] ||
    fail 64 "Usage: refresh-binancebot-baseline [--jobs 1-8] [--sha256 SHA256] [--resume] {--stdin|PATH}"
input="$1"
if [[ $input != --stdin ]]; then
    [[ -f $input && ! -L $input ]] || fail 66 "Use a regular, non-symlink dump."
fi

data_dir=$(admin -c "SHOW data_directory") || fail 69 "Cannot query local PostgreSQL."
[[ -d $data_dir ]] || fail 69 "Cannot access PostgreSQL data directory."
exec 9>"$data_dir/.binancebot-refresh.lock"
flock -n 9 || fail 75 "Another baseline refresh is running."

spool=""
stage="preflight"
started=$SECONDS
cleanup() {
    local status=$?
    if [[ -n $spool ]]; then rm -f -- "$spool"; fi
    if (( status != 0 )); then
        log "$stage stopped (exit $status, elapsed $((SECONDS - started))s)." >&2
    fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[[ $(admin -c "
    SELECT NOT (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)
       AND rolcanlogin AND NOT pg_has_role(rolname, 'postgres', 'MEMBER')
      FROM pg_roles WHERE rolname='$OWNER'") == t ]] ||
    fail 78 "The Work role is missing or has unsafe privileges."
baseline_exists=false
previous_exists=false
candidate_exists=false
if db_exists "$BASELINE"; then
    protected "$BASELINE" ready || fail 78 "Baseline protection failed; obtain administrator review."
    baseline_exists=true
    idle "$BASELINE"
fi
if db_exists "$PREVIOUS"; then
    protected "$PREVIOUS" ready || fail 78 "Previous baseline protection failed."
    previous_exists=true
    idle "$PREVIOUS"
fi
if db_exists "$CANDIDATE"; then
    protected "$CANDIDATE" restoring || fail 78 "Candidate protection failed."
    candidate_exists=true
    idle "$CANDIDATE"
fi
if db_exists "$WORK"; then
    [[ $baseline_exists == true ]] || fail 78 "Work exists without a baseline; obtain administrator review."
    [[ $(admin -c "SELECT pg_get_userbyid(datdba) = '$OWNER' FROM pg_database WHERE datname='$WORK'") == t ]] ||
        fail 78 "Unexpected owner of Work database."
    idle "$WORK"
fi
if [[ $previous_exists == true && ( $baseline_exists == false || $candidate_exists == true ) ]]; then
    fail 78 "Unexpected previous-baseline state; obtain administrator review."
fi

stage="spool verification"
for stale in "$SPOOL".??????????.dump; do
    if [[ -f $stale && ! -L $stale && -O $stale && $(stat -c %a -- "$stale") == 600 ]]; then
        rm -f -- "$stale"
    fi
done
spool=$(mktemp "$SPOOL.XXXXXXXXXX.dump")
log "Receiving archive into protected storage."
if [[ $input == --stdin ]]; then
    digest=$(tee "$spool" | sha256sum) || fail 74 "Could not spool archive."
else
    digest=$(tee "$spool" < "$input" | sha256sum) || fail 74 "Could not spool archive."
fi
sha=${digest%% *}
[[ -z $expected || $sha == "$expected" ]] || fail 65 "Archive checksum mismatch."
"$PG_BIN/pg_restore" --list "$spool" >/dev/null 2>&1 ||
    fail 65 "Archive is unreadable; use a verified PostgreSQL custom dump."
log "Archive verified (bytes=$(stat -c %s -- "$spool"), sha256=$sha, elapsed ${SECONDS}s)."

marker() { printf 'gpt-work baseline refresh v2; state=%s; sha256=%s' "$1" "$sha"; }
baseline_marker=$(db_marker "$BASELINE")
stage="baseline recovery"
if [[ $previous_exists == true ]]; then
    [[ $(db_marker "$PREVIOUS") == "$(marker previous)" &&
        ( $baseline_marker == "$(marker ready)" || $baseline_marker == "$(marker complete)" ) ]] ||
        fail 78 "Unexpected previous baseline or different dump; use the original verified dump or obtain administrator review."
fi

if [[ $candidate_exists == false && ( $baseline_marker == "$(marker ready)" ||
    $baseline_marker == "$(marker complete)" ) ]]; then
    log "Matching baseline already promoted; skipping restore."
else
    [[ $baseline_marker != 'gpt-work baseline refresh v2; state=ready;'* ]] ||
        fail 78 "Promotion awaits completion; retry with its original verified dump."
    stage="candidate restore"
    ready=false
    if [[ $candidate_exists == true ]]; then
        candidate_marker=$(db_marker "$CANDIDATE")
        if [[ $candidate_marker == "$(marker ready)" ||
            $candidate_marker == "gpt-work baseline refresh v1; state=restored; sha256=$sha" ]]; then
            ready=true
            log "Matching completed candidate found; skipping restore."
        elif [[ $candidate_marker == "$(marker restoring)" && $resume == false ]]; then
            log "Removing the marked partial candidate for this archive."
            admin -qc "DROP DATABASE $CANDIDATE"
            candidate_exists=false
        else
            fail 78 "Candidate is unrecognized, incomplete in --resume mode, or belongs to a different dump; inspect it before retrying."
        fi
    elif [[ $resume == true ]]; then
        fail 78 "No matching completed candidate or promoted baseline to resume."
    fi

    if [[ $ready == false ]]; then
        baseline_bytes=$(admin -c "SELECT COALESCE(pg_database_size(
            (SELECT oid FROM pg_database WHERE datname='$BASELINE')), 0)")
        archive_bytes=$(stat -c %s -- "$spool")
        available_bytes=$(df -PB1 -- "$data_dir" | awk 'NR == 2 {print $4}')
        [[ $baseline_bytes =~ ^[0-9]+$ && $available_bytes =~ ^[0-9]+$ ]] ||
            fail 71 "Cannot determine capacity on the PostgreSQL filesystem."
        estimate=$(( baseline_bytes > archive_bytes ? baseline_bytes : archive_bytes ))
        (( available_bytes >= estimate * 5 / 2 )) ||
            fail 71 "Insufficient space for the candidate, Work clone and restore overhead."
        # Initially disallow every connection. Publish ACLs and the recovery marker together.
        admin -qc "CREATE DATABASE $CANDIDATE OWNER postgres TEMPLATE template0 ALLOW_CONNECTIONS false CONNECTION LIMIT 0"
        admin -q <<SQL
BEGIN;
REVOKE CONNECT ON DATABASE $CANDIDATE FROM PUBLIC, "$OWNER";
GRANT CREATE ON DATABASE $CANDIDATE TO "$OWNER";
COMMENT ON DATABASE $CANDIDATE IS '$(marker restoring)';
ALTER DATABASE $CANDIDATE ALLOW_CONNECTIONS true;
COMMIT;
SQL
        psql_local -d "$CANDIDATE" -qc "GRANT CREATE ON SCHEMA public TO \"$OWNER\""
        log "Restoring candidate with $jobs worker(s)."
        restore_start=$SECONDS
        if "$PG_BIN/pg_restore" -w -h "$PG_SOCKET" -p "$PG_PORT" -U postgres \
            --dbname="$CANDIDATE" --no-owner --no-acl --no-tablespaces \
            --role="$OWNER" --exit-on-error --jobs="$jobs" "$spool" >/dev/null 2>&1; then
            log "Restore completed (elapsed $((SECONDS - restore_start))s)."
        else
            fail 72 "pg_restore exited $?. Retry using the same verified dump to rebuild the partial candidate."
        fi
    fi

    stage="candidate validation"
    objects_ok "$CANDIDATE" || fail 73 "Candidate has missing application objects or unexpected owners."
    psql_local -d "$CANDIDATE" -qc "REVOKE CREATE ON SCHEMA public FROM \"$OWNER\""
    admin -qc "REVOKE CREATE ON DATABASE $CANDIDATE FROM \"$OWNER\""
    protected "$CANDIDATE" ready || fail 78 "Candidate protection failed after restore."
    admin -qc "COMMENT ON DATABASE $CANDIDATE IS '$(marker ready)'"

    stage="atomic baseline promotion"
    log "Promoting validated candidate."
    if [[ $baseline_exists == true ]]; then
        admin -q <<SQL
BEGIN;
COMMENT ON DATABASE $BASELINE IS '$(marker previous)';
ALTER DATABASE $BASELINE RENAME TO $PREVIOUS;
ALTER DATABASE $CANDIDATE RENAME TO $BASELINE;
COMMIT;
SQL
        previous_exists=true
    else
        admin -qc "ALTER DATABASE $CANDIDATE RENAME TO $BASELINE"
    fi
    baseline_marker=$(marker ready)
fi

stage="baseline and Work verification"
protected "$BASELINE" ready && objects_ok "$BASELINE" ||
    fail 78 "Promoted baseline validation failed; obtain administrator review."
if [[ $baseline_marker != "$(marker complete)" ]] || ! work_ok; then
    stage="Work reset"
    reset_start=$SECONDS
    log "Recreating Work through the installed reset helper."
    "$RESET" || fail 82 "Work reset failed; retry the original verified dump."
    log "Work reset completed (elapsed $((SECONDS - reset_start))s)."
else
    log "Existing Work database passed validation; skipping reset."
fi
stage="completion"
work_ok || fail 83 "Work validation failed; retry the original verified dump or obtain administrator review."
admin -qc "COMMENT ON DATABASE $BASELINE IS '$(marker complete)'"
if [[ $previous_exists == true ]]; then
    admin -qc "DROP DATABASE $PREVIOUS"
fi
log "Baseline and Work verified (elapsed ${SECONDS}s)."
