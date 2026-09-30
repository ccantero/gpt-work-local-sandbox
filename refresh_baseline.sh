#!/bin/bash
set -euo pipefail

RESUME=false
if [[ "${1:-}" == "--resume" ]]; then
    RESUME=true
    shift
fi

if (( $# != 1 )); then
    echo "Usage: $0 [--resume] <snapshot.dump>" >&2
    exit 64
fi

readonly SNAPSHOT="$1"
readonly CANDIDATE="binancebot_work_baseline_candidate"
readonly BASELINE="binancebot_work_baseline"
readonly PREVIOUS="binancebot_work_baseline_previous"
readonly WORK_OWNER="local-gpt-work"

if [[ ! -f "${SNAPSHOT}" ]]; then
    echo "ERROR: snapshot not found: ${SNAPSHOT}" >&2
    exit 66
fi

sudo -v
(
    while true; do
        sleep 60
        sudo -n -v >/dev/null 2>&1 || true
    done
) &
readonly SUDO_KEEPALIVE_PID=$!
trap 'kill "${SUDO_KEEPALIVE_PID}" 2>/dev/null || true' EXIT

echo "PostgreSQL baseline refresh"
echo "  snapshot:  ${SNAPSHOT}"
echo "  baseline:  ${BASELINE}"
echo "  candidate: ${CANDIDATE}"
echo

echo "Validating snapshot..."

if ! pg_restore --list "${SNAPSHOT}" >/dev/null; then
    echo "ERROR: invalid PostgreSQL custom-format snapshot" >&2
    exit 65
fi

echo "Snapshot OK"
echo

readonly SNAPSHOT_SHA256="$(sha256sum -- "${SNAPSHOT}" | awk '{print $1}')"
readonly RESTORE_MARKER="gpt-work baseline refresh v1; state=restored; sha256=${SNAPSHOT_SHA256}"

echo "Checking database state..."

if ! sudo -n -u postgres psql -d postgres -Atqc \
    "SELECT 1 FROM pg_database WHERE datname='${BASELINE}'" |
    grep -qx 1; then
    echo "ERROR: baseline database does not exist: ${BASELINE}" >&2
    exit 69
fi

if sudo -n -u postgres psql -d postgres -Atqc \
    "SELECT 1 FROM pg_database WHERE datname='${CANDIDATE}'" |
    grep -qx 1; then
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
    readonly CANDIDATE_MARKER="$(
        sudo -n -u postgres psql -d postgres -Atqc "
            SELECT COALESCE(shobj_description(oid, 'pg_database'), '')
            FROM pg_database
            WHERE datname='${CANDIDATE}'
        "
    )"

    if [[ "${CANDIDATE_MARKER}" != "${RESTORE_MARKER}" ]]; then
        echo "ERROR: candidate has no matching completed-restore marker" >&2
        echo "Refusing to resume a partial restore or a candidate from another snapshot." >&2
        exit 70
    fi
fi

if sudo -n -u postgres psql -d postgres -Atqc \
    "SELECT 1 FROM pg_database WHERE datname='${PREVIOUS}'" |
    grep -qx 1; then
    echo "ERROR: previous baseline already exists: ${PREVIOUS}" >&2
    echo "Refusing to overwrite or delete it automatically." >&2
    exit 78
fi

echo "Database state OK"

if [[ "${RESUME}" == true ]]; then
    echo
    echo "Resume mode: keeping existing candidate; restore will not be repeated."
else
    echo
    echo "Checking disk space..."

    readonly PG_DATA="$(
        sudo -n -u postgres psql -d postgres -Atqc 'SHOW data_directory'
    )"

    readonly BASELINE_BYTES="$(
        sudo -n -u postgres psql -d postgres -Atqc \
        "SELECT pg_database_size('${BASELINE}')"
    )"

    readonly AVAILABLE_BYTES="$(
        df -PB1 "${PG_DATA}" | awk 'NR == 2 {print $4}'
    )"

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
    sudo -n -u postgres psql -d postgres -v ON_ERROR_STOP=1 -c \
        "CREATE DATABASE ${CANDIDATE} OWNER postgres CONNECTION LIMIT 0;"

    sudo -n -u postgres psql -d postgres -v ON_ERROR_STOP=1 <<SQL
    REVOKE CONNECT ON DATABASE ${CANDIDATE} FROM PUBLIC;
    GRANT CREATE ON DATABASE ${CANDIDATE} TO "${WORK_OWNER}";
SQL

    sudo -n -u postgres psql -d "${CANDIDATE}" -v ON_ERROR_STOP=1 <<SQL
    GRANT CREATE ON SCHEMA public TO "${WORK_OWNER}";
SQL

    echo "Restoring snapshot into candidate..."
    SECONDS=0

    if ! sudo -n -u postgres pg_restore \
        --dbname="${CANDIDATE}" \
        --no-owner \
        --no-acl \
        --role="${WORK_OWNER}" \
        < "${SNAPSHOT}"; then

        echo "ERROR: restore failed" >&2
        echo "Candidate left intact for inspection: ${CANDIDATE}" >&2
        exit 72
    fi

    sudo -n -u postgres psql -d postgres -v ON_ERROR_STOP=1 -c \
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
    sudo -n -u postgres psql -d "${CANDIDATE}" -Atqc "
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

if (( INVALID_OBJECT_OWNERS != 0 )); then
    echo "ERROR: ${INVALID_OBJECT_OWNERS} application objects have unexpected ownership" >&2
    exit 73
fi

if ! APP_OBJECTS="$(
    sudo -n -u postgres psql -d "${CANDIDATE}" -Atqc "
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
sudo -n -u postgres psql -d "${CANDIDATE}" -v ON_ERROR_STOP=1 -c \
    "REVOKE CREATE ON SCHEMA public FROM \"${WORK_OWNER}\";"

sudo -n -u postgres psql -d postgres -v ON_ERROR_STOP=1 -c \
    "REVOKE CREATE ON DATABASE ${CANDIDATE} FROM \"${WORK_OWNER}\";"

readonly CANDIDATE_OWNER="$(
    sudo -n -u postgres psql -d postgres -Atqc "
        SELECT pg_get_userbyid(datdba)
        FROM pg_database
        WHERE datname='${CANDIDATE}'
    "
)"

readonly WORK_CAN_CONNECT="$(
    sudo -n -u postgres psql -d postgres -Atqc "
        SELECT has_database_privilege(
            '${WORK_OWNER}',
            '${CANDIDATE}',
            'CONNECT'
        )
    "
)"

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
sudo -n -u postgres psql -d postgres -v ON_ERROR_STOP=1 -c \
    "ALTER DATABASE ${BASELINE} RENAME TO ${PREVIOUS};"

if ! sudo -n -u postgres psql -d postgres -v ON_ERROR_STOP=1 -c \
    "ALTER DATABASE ${CANDIDATE} RENAME TO ${BASELINE};"; then

    echo "ERROR: candidate promotion failed; restoring previous baseline name" >&2

    if sudo -n -u postgres psql -d postgres -v ON_ERROR_STOP=1 -c \
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

readonly BASELINE_OWNER="$(
    sudo -n -u postgres psql -d postgres -Atqc "
        SELECT pg_get_userbyid(datdba)
        FROM pg_database
        WHERE datname='${BASELINE}'
    "
)"

readonly BASELINE_WORK_CAN_CONNECT="$(
    sudo -n -u postgres psql -d postgres -Atqc "
        SELECT has_database_privilege(
            '${WORK_OWNER}',
            '${BASELINE}',
            'CONNECT'
        )
    "
)"

readonly BASELINE_APP_OBJECTS="$(
    sudo -n -u postgres psql -d "${BASELINE}" -Atqc "
        SELECT count(*)
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname IN ('bot', 'django')
          AND c.relkind IN ('r','p','S','v','m')
    "
)"

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

if ! sudo -n -u postgres /usr/local/sbin/reset-binancebot-work; then
    echo "ERROR: work database reset failed" >&2
    echo "Previous baseline preserved as: ${PREVIOUS}" >&2
    exit 82
fi

echo "Validating work database..."

readonly WORK_DB="binancebot_work"

readonly WORK_APP_OBJECTS="$(
    sudo -n -u "${WORK_OWNER}" psql -d "${WORK_DB}" -Atqc "
        SELECT count(*)
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname IN ('bot', 'django')
          AND c.relkind IN ('r','p','S','v','m')
    "
)"

readonly WORK_INVALID_OBJECT_OWNERS="$(
    sudo -n -u "${WORK_OWNER}" psql -d "${WORK_DB}" -Atqc "
        SELECT count(*)
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname IN ('bot', 'django')
          AND c.relkind IN ('r','p','S','v','m')
          AND pg_get_userbyid(c.relowner) <> '${WORK_OWNER}'
    "
)"

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

sudo -n -u postgres dropdb --if-exists --force "${PREVIOUS}"

echo
echo "Baseline refresh completed successfully"
echo "  baseline: ${BASELINE}"
echo "  work:     ${WORK_DB}"
echo "  previous: removed"
