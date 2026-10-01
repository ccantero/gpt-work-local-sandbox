#!/bin/bash
set -euo pipefail
umask 077

if (( $# != 1 )); then
    echo "Usage: $0 <postgres-service>" >&2
    exit 64
fi

SERVICE="$1"
readonly SERVICE
if [[ ! "${SERVICE}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] ||
    [[ "${SERVICE}" == *..* ]]; then
    echo "ERROR: invalid PostgreSQL service name" >&2
    exit 64
fi

SCRIPT_DIR=""
if ! SCRIPT_DIR="$(cd -- "$(/usr/bin/dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"; then
    echo "ERROR: could not resolve script directory" >&2
    exit 70
fi
readonly SCRIPT_DIR
readonly SNAPSHOT_DIR="${SCRIPT_DIR}/snapshots"
TIMESTAMP=""
if ! TIMESTAMP="$(/usr/bin/date '+%Y-%m-%d_%H%M%S')"; then
    echo "ERROR: could not determine snapshot timestamp" >&2
    exit 70
fi
readonly TIMESTAMP
readonly OUTPUT="${SNAPSHOT_DIR}/${SERVICE}-${TIMESTAMP}.dump"

if [[ -e "${SNAPSHOT_DIR}" ]]; then
    if [[ ! -d "${SNAPSHOT_DIR}" || -L "${SNAPSHOT_DIR}" ]]; then
        echo "ERROR: snapshot path is not a real directory: ${SNAPSHOT_DIR}" >&2
        exit 73
    fi

    SNAPSHOT_UID=""
    SNAPSHOT_MODE=""
    if ! SNAPSHOT_UID="$(/usr/bin/stat -c '%u' -- "${SNAPSHOT_DIR}")" ||
        ! SNAPSHOT_MODE="$(/usr/bin/stat -c '%a' -- "${SNAPSHOT_DIR}")"; then
        echo "ERROR: could not inspect snapshot directory" >&2
        exit 73
    fi
    if [[ "${SNAPSHOT_UID}" != "${EUID}" || "${SNAPSHOT_MODE}" != "700" ]]; then
        echo "ERROR: snapshot directory must be owned by the current user and mode 0700" >&2
        echo "Refusing to change existing permissions automatically: ${SNAPSHOT_DIR}" >&2
        exit 73
    fi
else
    /usr/bin/mkdir -m 0700 -- "${SNAPSHOT_DIR}"
fi

if [[ -e "${OUTPUT}" ]]; then
    echo "ERROR: refusing to overwrite existing snapshot: ${OUTPUT}" >&2
    exit 73
fi

TEMP=""
if ! TEMP="$(/usr/bin/mktemp "${SNAPSHOT_DIR}/.${SERVICE}-${TIMESTAMP}.XXXXXX.partial")"; then
    echo "ERROR: could not create private temporary snapshot" >&2
    exit 70
fi
readonly TEMP
/usr/bin/chmod 0600 -- "${TEMP}"

cleanup() {
    /usr/bin/rm -f -- "${TEMP}"
}
trap cleanup EXIT

echo "Creating PostgreSQL snapshot"
echo "  service: ${SERVICE}"
echo "  output:  ${OUTPUT}"
echo

SECONDS=0

/usr/bin/env PGSERVICE="${SERVICE}" /usr/lib/postgresql/17/bin/pg_dump \
    --format=custom \
    --file="${TEMP}" \
    --dbname="service=${SERVICE}"

if ! /usr/bin/ln -- "${TEMP}" "${OUTPUT}"; then
    echo "ERROR: refusing to overwrite an existing snapshot" >&2
    exit 73
fi
/usr/bin/rm -- "${TEMP}"

ELAPSED="${SECONDS}"
HOURS=$((ELAPSED / 3600))
MINUTES=$(((ELAPSED % 3600) / 60))
SECONDS_LEFT=$((ELAPSED % 60))

echo
echo "Snapshot completed"
printf '  duration: %02d:%02d:%02d\n' \
    "${HOURS}" "${MINUTES}" "${SECONDS_LEFT}"
echo "  file:     ${OUTPUT}"
OUTPUT_SIZE=""
if ! OUTPUT_SIZE="$(/usr/bin/du -h -- "${OUTPUT}")"; then
    echo "ERROR: snapshot created, but its size could not be reported" >&2
    exit 74
fi
OUTPUT_SIZE="${OUTPUT_SIZE%%[[:space:]]*}"
echo "  size:     ${OUTPUT_SIZE}"
