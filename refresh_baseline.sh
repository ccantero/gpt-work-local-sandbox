#!/bin/bash
set -euo pipefail
umask 077

readonly PG_BIN="/usr/lib/postgresql/17/bin"
readonly PG_SOCKET="/var/run/postgresql"
readonly PG_PORT="5432"
readonly PG_ADMIN="postgres"

# Do not allow libpq environment state to redirect this privileged helper.
unset PGAPPNAME PGCHANNELBINDING PGCLIENTENCODING PGCONNECT_TIMEOUT PGDATABASE
unset PGHOST PGHOSTADDR PGOPTIONS PGPASSFILE PGPASSWORD PGPORT PGREQUIREAUTH
unset PGSERVICE PGSERVICEFILE PGSSLCERT PGSSLCRL PGSSLKEY PGSSLMODE
unset PGSSLROOTCERT PGSSLSNI PGTARGETSESSIONATTRS PGUSER

RUN_AS=""
if ! RUN_AS="$(/usr/bin/id -un)"; then
    echo "ERROR: could not determine execution identity" >&2
    exit 69
fi
if [[ "${RUN_AS}" != "postgres" ]]; then
    echo "ERROR: baseline refresh must run as the postgres OS user" >&2
    echo "Run the protected installed helper; never elevate the repository source." >&2
    exit 69
fi

psql_admin() {
    "${PG_BIN}/psql" -X \
        --host="${PG_SOCKET}" \
        --port="${PG_PORT}" \
        --username="${PG_ADMIN}" \
        --no-password \
        "$@"
}

require_nonnegative_integer() {
    local value="$1"
    local label="$2"
    if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
        echo "ERROR: ${label} was not a non-negative integer" >&2
        exit 90
    fi
}

RESUME=false
if [[ "${1:-}" == "--resume" ]]; then
    RESUME=true
    shift
fi

if (( $# != 1 )); then
    echo "Usage: $0 [--resume] <snapshot.dump>" >&2
    exit 64
fi

readonly SNAPSHOT_INPUT="$1"
readonly CANDIDATE="binancebot_work_baseline_candidate"
readonly BASELINE="binancebot_work_baseline"
readonly PREVIOUS="binancebot_work_baseline_previous"
readonly WORK_OWNER="local-gpt-work"

if [[ ! -f "${SNAPSHOT_INPUT}" || -L "${SNAPSHOT_INPUT}" ]]; then
    echo "ERROR: snapshot must be a regular, non-symlink file: ${SNAPSHOT_INPUT}" >&2
    exit 66
fi

# Every invocation, including --resume, stages a new protected copy. Resume is
# accepted only when that copy hashes to the completed-restore marker, proving
# the supplied original dump is byte-for-byte identical to the restored dump.
SNAPSHOT=""
if ! SNAPSHOT="$(/usr/bin/mktemp /var/tmp/refresh-binancebot-baseline.XXXXXX.dump)"; then
    echo "ERROR: could not create protected temporary snapshot" >&2
    exit 70
fi
readonly SNAPSHOT
/usr/bin/chmod 0600 -- "${SNAPSHOT}"

cleanup() {
    /usr/bin/rm -f -- "${SNAPSHOT}"
}
trap cleanup EXIT

if ! /usr/bin/cp --reflink=never -- "${SNAPSHOT_INPUT}" "${SNAPSHOT}"; then
    echo "ERROR: could not copy snapshot into protected temporary storage" >&2
    exit 74
fi

echo "PostgreSQL baseline refresh"
echo "  snapshot:  ${SNAPSHOT_INPUT}"
echo "  baseline:  ${BASELINE}"
echo "  candidate: ${CANDIDATE}"
echo

echo "Validating snapshot..."

if ! "${PG_BIN}/pg_restore" --list "${SNAPSHOT}" >/dev/null; then
    echo "ERROR: invalid PostgreSQL custom-format snapshot" >&2
    exit 65
fi

echo "Snapshot OK"
echo

SNAPSHOT_SHA256=""
if ! SNAPSHOT_SHA256="$(/usr/bin/sha256sum -- "${SNAPSHOT}")"; then
    echo "ERROR: could not hash protected snapshot copy" >&2
    exit 74
fi
SNAPSHOT_SHA256="${SNAPSHOT_SHA256%%[[:space:]]*}"
if [[ ! "${SNAPSHOT_SHA256}" =~ ^[[:xdigit:]]{64}$ ]]; then
    echo "ERROR: snapshot hash output was invalid" >&2
    exit 74
fi
readonly SNAPSHOT_SHA256
readonly RESTORE_MARKER="gpt-work baseline refresh v1; state=restored; sha256=${SNAPSHOT_SHA256}"

echo "Checking database state..."

if ! psql_admin -d postgres -Atqc \
    "SELECT 1 FROM pg_database WHERE datname='${BASELINE}'" |
    /usr/bin/grep -qx 1; then
    echo "ERROR: baseline database does not exist: ${BASELINE}" >&2
    exit 69
fi

if psql_admin -d postgres -Atqc \
    "SELECT 1 FROM pg_database WHERE datname='${CANDIDATE}'" |
    /usr/bin/grep -qx 1; then
    if [[ "${RESUME}" != true ]]; then
        echo "ERROR: candidate already exists: ${CANDIDATE}" >&2
        echo "Use --resume only after verifying that its restore completed." >&2
        exit 70
    fi
elif [[ "${RESUME}" == true ]]; then
    echo "ERROR: --resume requested but candidate does not exist: ${CANDIDATE}" >&2
    exit 70
fi

if [[ "${RESUME}" == true ]]; then
    CANDIDATE_MARKER=""
    if ! CANDIDATE_MARKER="$(
        psql_admin -d postgres -Atqc "
            SELECT COALESCE(shobj_description(oid, 'pg_database'), '')
            FROM pg_database
            WHERE datname='${CANDIDATE}'
        "
    )"; then
        echo "ERROR: could not read candidate restore marker" >&2
        exit 90
    fi
    readonly CANDIDATE_MARKER

    if [[ "${CANDIDATE_MARKER}" != "${RESTORE_MARKER}" ]]; then
        echo "ERROR: candidate has no matching completed-restore marker" >&2
        echo "The supplied dump is not byte-for-byte identical to the completed restore." >&2
        echo "Refusing to resume a partial restore or a candidate from another dump." >&2
        exit 70
    fi
fi

if psql_admin -d postgres -Atqc \
    "SELECT 1 FROM pg_database WHERE datname='${PREVIOUS}'" |
    /usr/bin/grep -qx 1; then
    echo "ERROR: previous baseline already exists: ${PREVIOUS}" >&2
    echo "Refusing to overwrite or delete it automatically." >&2
    exit 78
fi

echo "Database state OK"

if [[ "${RESUME}" == true ]]; then
    echo
    echo "Resume mode: supplied dump matches the completed-restore marker."
    echo "Keeping existing candidate; restore will not be repeated."
else
    echo
    echo "Checking disk space..."

    PG_DATA=""
    if ! PG_DATA="$(psql_admin -d postgres -Atqc 'SHOW data_directory')" ||
        [[ -z "${PG_DATA}" ]]; then
        echo "ERROR: could not determine PostgreSQL data directory" >&2
        exit 90
    fi
    readonly PG_DATA

    BASELINE_BYTES=""
    if ! BASELINE_BYTES="$(psql_admin -d postgres -Atqc \
        "SELECT pg_database_size('${BASELINE}')")"; then
        echo "ERROR: could not determine baseline size" >&2
        exit 90
    fi
    require_nonnegative_integer "${BASELINE_BYTES}" "baseline size"
    readonly BASELINE_BYTES

    AVAILABLE_BYTES=""
    if ! AVAILABLE_BYTES="$(/usr/bin/df -PB1 -- "${PG_DATA}" | /usr/bin/awk 'NR == 2 {print $4}')"; then
        echo "ERROR: could not determine available space" >&2
        exit 90
    fi
    require_nonnegative_integer "${AVAILABLE_BYTES}" "available space"
    readonly AVAILABLE_BYTES

    # Candidate should be roughly the size of the current baseline.
    # Require an additional 25% safety margin for growth and filesystem overhead.
    readonly REQUIRED_BYTES=$(( BASELINE_BYTES + BASELINE_BYTES / 4 ))

    printf '  baseline size: %d GiB\n' \
        "$(( BASELINE_BYTES / 1024 / 1024 / 1024 ))"

    printf '  required free: %d GiB\n' \
        "$(( REQUIRED_BYTES / 1024 / 1024 / 1024 ))"

    printf '  available:     %d GiB\n' \
        "$(( AVAILABLE_BYTES / 1024 / 1024 / 1024 ))"

    if (( AVAILABLE_BYTES < REQUIRED_BYTES )); then
        echo "ERROR: insufficient disk space for safe restore" >&2
        exit 71
    fi

    echo "Disk space OK"

    echo
    echo "Creating protected candidate database..."

    # Keep the staging database inaccessible to WORK_OWNER throughout the restore.
    # pg_restore connects as postgres and SET ROLEs to WORK_OWNER, so WORK_OWNER
    # needs CREATE on the database but does not need CONNECT.
    psql_admin -d postgres -v ON_ERROR_STOP=1 -c \
        "CREATE DATABASE ${CANDIDATE} OWNER postgres CONNECTION LIMIT 0;"

    psql_admin -d postgres -v ON_ERROR_STOP=1 <<SQL
    REVOKE CONNECT ON DATABASE ${CANDIDATE} FROM PUBLIC;
    GRANT CREATE ON DATABASE ${CANDIDATE} TO "${WORK_OWNER}";
SQL

    psql_admin -d "${CANDIDATE}" -v ON_ERROR_STOP=1 <<SQL
    GRANT CREATE ON SCHEMA public TO "${WORK_OWNER}";
SQL

    echo "Restoring snapshot into candidate..."
    SECONDS=0

    if ! "${PG_BIN}/pg_restore" \
        --host="${PG_SOCKET}" \
        --port="${PG_PORT}" \
        --username="${PG_ADMIN}" \
        --no-password \
        --dbname="${CANDIDATE}" \
        --no-owner \
        --no-acl \
        --role="${WORK_OWNER}" \
        < "${SNAPSHOT}"; then

        echo "ERROR: restore failed" >&2
        echo "Candidate left intact for inspection: ${CANDIDATE}" >&2
        exit 72
    fi

    psql_admin -d postgres -v ON_ERROR_STOP=1 -c \
        "COMMENT ON DATABASE ${CANDIDATE} IS '${RESTORE_MARKER}';"

    ELAPSED="${SECONDS}"

    echo "Restore completed"
    printf '  duration: %02d:%02d:%02d\n' \
        "$(( ELAPSED / 3600 ))" \
        "$(( (ELAPSED % 3600) / 60 ))" \
        "$(( ELAPSED % 60 ))"
fi
echo
echo "Validating candidate..."

if ! INVALID_OBJECT_OWNERS="$(
    psql_admin -d "${CANDIDATE}" -Atqc "
        SELECT count(*)
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname IN ('bot', 'django')
          AND c.relkind IN ('r','p','S','v','m')
          AND pg_get_userbyid(c.relowner) <> '${WORK_OWNER}'
    "
)"; then
    echo "ERROR: could not validate candidate object ownership" >&2
    exit 90
fi
require_nonnegative_integer "${INVALID_OBJECT_OWNERS}" "invalid candidate owner count"

if (( INVALID_OBJECT_OWNERS != 0 )); then
    echo "ERROR: ${INVALID_OBJECT_OWNERS} application objects have unexpected ownership" >&2
    exit 73
fi

if ! APP_OBJECTS="$(
    psql_admin -d "${CANDIDATE}" -Atqc "
        SELECT count(*)
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname IN ('bot', 'django')
          AND c.relkind IN ('r','p','S','v','m')
    "
)"; then
    echo "ERROR: could not count candidate application objects" >&2
    exit 91
fi
require_nonnegative_integer "${APP_OBJECTS}" "candidate application object count"

if (( APP_OBJECTS == 0 )); then
    echo "ERROR: candidate contains no application objects" >&2
    exit 74
fi

echo "Candidate OK"
echo "  application objects: ${APP_OBJECTS}"
echo "  owner:               ${WORK_OWNER}"

echo
echo "Finalizing candidate protection..."

# CREATE privileges were needed only while pg_restore was running as WORK_OWNER.
psql_admin -d "${CANDIDATE}" -v ON_ERROR_STOP=1 -c \
    "REVOKE CREATE ON SCHEMA public FROM \"${WORK_OWNER}\";"

psql_admin -d postgres -v ON_ERROR_STOP=1 -c \
    "REVOKE CREATE ON DATABASE ${CANDIDATE} FROM \"${WORK_OWNER}\";"

CANDIDATE_OWNER=""
if ! CANDIDATE_OWNER="$(
    psql_admin -d postgres -Atqc "
        SELECT pg_get_userbyid(datdba)
        FROM pg_database
        WHERE datname='${CANDIDATE}'
    "
)"; then
    echo "ERROR: could not determine candidate owner" >&2
    exit 90
fi
readonly CANDIDATE_OWNER

WORK_CAN_CONNECT=""
if ! WORK_CAN_CONNECT="$(
    psql_admin -d postgres -Atqc "
        SELECT has_database_privilege(
            '${WORK_OWNER}',
            '${CANDIDATE}',
            'CONNECT'
        )
    "
)"; then
    echo "ERROR: could not determine candidate CONNECT privilege" >&2
    exit 90
fi
readonly WORK_CAN_CONNECT

if [[ "${CANDIDATE_OWNER}" != "postgres" ]]; then
    echo "ERROR: candidate database owner is ${CANDIDATE_OWNER}, expected postgres" >&2
    exit 75
fi

if [[ "${WORK_CAN_CONNECT}" != "f" ]]; then
    echo "ERROR: ${WORK_OWNER} still has CONNECT privilege on candidate" >&2
    exit 76
fi

echo "Candidate protected"
echo "  database owner: postgres"
echo "  ${WORK_OWNER} CONNECT: denied"

echo
echo "Promoting candidate..."

# The current baseline remains available under PREVIOUS until
# the candidate has successfully taken its place.
psql_admin -d postgres -v ON_ERROR_STOP=1 -c \
    "ALTER DATABASE ${BASELINE} RENAME TO ${PREVIOUS};"

if ! psql_admin -d postgres -v ON_ERROR_STOP=1 -c \
    "ALTER DATABASE ${CANDIDATE} RENAME TO ${BASELINE};"; then

    echo "ERROR: candidate promotion failed; restoring previous baseline name" >&2

    if psql_admin -d postgres -v ON_ERROR_STOP=1 -c \
        "ALTER DATABASE ${PREVIOUS} RENAME TO ${BASELINE};"; then
        echo "Previous baseline name restored." >&2
    else
        echo "CRITICAL: automatic baseline-name rollback failed." >&2
        echo "Manual PostgreSQL intervention required." >&2
    fi

    exit 77
fi

echo
echo "Validating promoted baseline..."

BASELINE_OWNER=""
if ! BASELINE_OWNER="$(
    psql_admin -d postgres -Atqc "
        SELECT pg_get_userbyid(datdba)
        FROM pg_database
        WHERE datname='${BASELINE}'
    "
)"; then
    echo "ERROR: could not determine promoted baseline owner" >&2
    exit 90
fi
readonly BASELINE_OWNER

BASELINE_WORK_CAN_CONNECT=""
if ! BASELINE_WORK_CAN_CONNECT="$(
    psql_admin -d postgres -Atqc "
        SELECT has_database_privilege(
            '${WORK_OWNER}',
            '${BASELINE}',
            'CONNECT'
        )
    "
)"; then
    echo "ERROR: could not determine promoted baseline CONNECT privilege" >&2
    exit 90
fi
readonly BASELINE_WORK_CAN_CONNECT

BASELINE_APP_OBJECTS=""
if ! BASELINE_APP_OBJECTS="$(
    psql_admin -d "${BASELINE}" -Atqc "
        SELECT count(*)
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname IN ('bot', 'django')
          AND c.relkind IN ('r','p','S','v','m')
    "
)"; then
    echo "ERROR: could not count promoted baseline application objects" >&2
    exit 90
fi
require_nonnegative_integer "${BASELINE_APP_OBJECTS}" "promoted baseline application object count"
readonly BASELINE_APP_OBJECTS

if [[ "${BASELINE_OWNER}" != "postgres" ]]; then
    echo "ERROR: promoted baseline owner is ${BASELINE_OWNER}, expected postgres" >&2
    exit 79
fi

if [[ "${BASELINE_WORK_CAN_CONNECT}" != "f" ]]; then
    echo "ERROR: ${WORK_OWNER} can CONNECT to promoted baseline" >&2
    exit 80
fi

if (( BASELINE_APP_OBJECTS == 0 )); then
    echo "ERROR: promoted baseline contains no application objects" >&2
    exit 81
fi

echo "Promoted baseline OK"
echo "  database owner:       ${BASELINE_OWNER}"
echo "  application objects:  ${BASELINE_APP_OBJECTS}"
echo "  ${WORK_OWNER} CONNECT: denied"

echo
echo "Resetting work database from promoted baseline..."

if ! /usr/local/sbin/reset-binancebot-work; then
    echo "ERROR: work database reset failed" >&2
    echo "Previous baseline preserved as: ${PREVIOUS}" >&2
    exit 82
fi

echo "Validating work database..."

readonly WORK_DB="binancebot_work"

WORK_APP_OBJECTS=""
if ! WORK_APP_OBJECTS="$(
    psql_admin -d "${WORK_DB}" -Atqc "
        SELECT count(*)
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname IN ('bot', 'django')
          AND c.relkind IN ('r','p','S','v','m')
    "
)"; then
    echo "ERROR: could not count work application objects" >&2
    echo "Previous baseline preserved as: ${PREVIOUS}" >&2
    exit 90
fi
require_nonnegative_integer "${WORK_APP_OBJECTS}" "work application object count"
readonly WORK_APP_OBJECTS

WORK_INVALID_OBJECT_OWNERS=""
if ! WORK_INVALID_OBJECT_OWNERS="$(
    psql_admin -d "${WORK_DB}" -Atqc "
        SELECT count(*)
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname IN ('bot', 'django')
          AND c.relkind IN ('r','p','S','v','m')
          AND pg_get_userbyid(c.relowner) <> '${WORK_OWNER}'
    "
)"; then
    echo "ERROR: could not validate work object ownership" >&2
    echo "Previous baseline preserved as: ${PREVIOUS}" >&2
    exit 90
fi
require_nonnegative_integer "${WORK_INVALID_OBJECT_OWNERS}" "invalid work owner count"
readonly WORK_INVALID_OBJECT_OWNERS

if (( WORK_APP_OBJECTS == 0 )); then
    echo "ERROR: work database contains no application objects" >&2
    echo "Previous baseline preserved as: ${PREVIOUS}" >&2
    exit 83
fi

if (( WORK_INVALID_OBJECT_OWNERS != 0 )); then
    echo "ERROR: ${WORK_INVALID_OBJECT_OWNERS} work objects have unexpected ownership" >&2
    echo "Previous baseline preserved as: ${PREVIOUS}" >&2
    exit 84
fi

echo "Work database OK"
echo "  application objects: ${WORK_APP_OBJECTS}"
echo "  owner:               ${WORK_OWNER}"

echo
echo "Removing previous baseline..."

"${PG_BIN}/dropdb" \
    --host="${PG_SOCKET}" \
    --port="${PG_PORT}" \
    --username="${PG_ADMIN}" \
    --no-password \
    --if-exists \
    --force \
    "${PREVIOUS}"

echo
echo "Baseline refresh completed successfully"
echo "  baseline: ${BASELINE}"
echo "  work:     ${WORK_DB}"
echo "  previous: removed"
